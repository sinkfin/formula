#!/usr/bin/env bash
# =============================================================================
# make-rootfs.sh — 为 xaga (MT6895 / 天玑8100) mainline 构建可刷入 userdata 的
#                  ext4 rootfs 镜像，支持多种发行版
#
# 不可违背的约束（全部来自 MT6895-Mainline/initramfs 的 init.c，硬编码）:
#   * BOOT_PARTITION 默认 /dev/sdc86 (= userdata)，文件系统 **必须是 ext4**
#   * NVDATA_PARTITION /dev/sdc13 (nvdata)，只读 ext4，用来取 WiFi NVRAM
#   * pivot 之后执行 **/sbin/init**（systemd）
#   * initramfs 会自己挂 proc/sys/dev/run/tmp/devpts，rootfs 不需要 /dev 节点
#   * 不读 cmdline，所以不需要 root= / init=
#
# 刻意 **不使用 loop 设备**（云主机/容器里常常不可用）:
#   bootstrap 到普通目录 -> mkfs.ext4 -d <dir> 直接出镜像
#
# 内核源码树作者本人用的是 8+256 + Arch Linux，复现他的环境: -d arch
#
# 用法:
#   sudo ./make-rootfs.sh -d arch                       # Arch Linux ARM（作者同款）
#   sudo ./make-rootfs.sh -d debian -r bookworm         # Debian 12
#   sudo ./make-rootfs.sh -d ubuntu -r resolute         # Ubuntu 26.04 LTS
#   sudo ./make-rootfs.sh -d ubuntu -r resolute -s 8G -p mypass -n xaga
#   sudo ./make-rootfs.sh --help
# =============================================================================
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 默认值
# ---------------------------------------------------------------------------
DISTRO=debian
RELEASE=""
SIZE=6G
ROOTPW=1234
TARGET_HOSTNAME=xaga
MAKE_SPARSE=1
TOOL=auto
COMPONENTS=""
MIRROR=""
OUT=""

# 内核源码目录:优先用它实际所在的位置
if [ -d /mnt/hdd/Project/xaga-mainline/linux ]; then
  KDIR_DEFAULT=/mnt/hdd/Project/xaga-mainline/linux
else
  KDIR_DEFAULT=$HOME/xaga/linux
fi
KDIR=$KDIR_DEFAULT
WORKDIR=$HOME/xaga/rootfs-dir
IMG=$HOME/xaga/rootfs.img

usage() {
  cat <<'USAGE'
用法: sudo ./make-rootfs.sh [选项]

  -d, --distro <name>   发行版: arch | debian | ubuntu      (默认 debian)
  -r, --release <ver>   版本代号，省略则用该发行版的默认值:
                          arch   -> latest
                          debian -> bookworm   (也可 trixie / sid)
                          ubuntu -> noble      (也可 resolute = 26.04 LTS)
  -s, --size <size>     镜像大小                             (默认 6G)
  -o, --out <path>      输出镜像路径     (默认 ~/xaga/rootfs-<distro>.img)
  -w, --work <dir>      工作目录         (默认 ~/xaga/rootfs-dir)
  -k, --kernel <dir>    内核源码目录     (默认 /mnt/hdd/Project/xaga-mainline/linux)
  -m, --mirror <url>    镜像站           (默认按发行版选国内源)
  -p, --password <pw>   root 密码                            (默认 1234)
  -n, --hostname <name> 主机名                               (默认 xaga)
  -t, --tool <tool>     debootstrap | mmdebstrap  (仅 debian/ubuntu)
      --no-sparse       不生成 sparse 镜像
  -h, --help            显示本帮助

示例:
  sudo ./make-rootfs.sh -d arch
  sudo ./make-rootfs.sh -d ubuntu -r resolute -s 8G
  sudo ./make-rootfs.sh -d debian -r bookworm -p 1234 -n xaga
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    -d|--distro)    DISTRO=${2:?缺少参数}; shift 2;;
    -r|--release)   RELEASE=${2:?缺少参数}; shift 2;;
    -s|--size)      SIZE=${2:?缺少参数}; shift 2;;
    -o|--out)       OUT=${2:?缺少参数}; shift 2;;
    -w|--work)      WORKDIR=${2:?缺少参数}; shift 2;;
    -k|--kernel)    KDIR=${2:?缺少参数}; shift 2;;
    -m|--mirror)    MIRROR=${2:?缺少参数}; shift 2;;
    -p|--password)  ROOTPW=${2:?缺少参数}; shift 2;;
    -n|--hostname)  TARGET_HOSTNAME=${2:?缺少参数}; shift 2;;
    -t|--tool)      TOOL=${2:?缺少参数}; shift 2;;
    --no-sparse)    MAKE_SPARSE=0; shift;;
    -h|--help)      usage; exit 0;;
    *) echo "未知参数: $1" >&2; usage; exit 1;;
  esac
done

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[✗]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 发行版相关默认值
# ---------------------------------------------------------------------------
case "$DISTRO" in
  arch|archlinux|archarm)
    DISTRO=arch
    RELEASE=${RELEASE:-latest}
    MIRROR=${MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/os/}
    ARCH_TARBALL="ArchLinuxARM-aarch64-${RELEASE}.tar.gz"
    ;;
  debian)
    RELEASE=${RELEASE:-bookworm}
    MIRROR=${MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/debian/}
    COMPONENTS=${COMPONENTS:-main}
    [ "$TOOL" = auto ] && TOOL=debootstrap
    ;;
  ubuntu)
    RELEASE=${RELEASE:-noble}
    MIRROR=${MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports/}
    COMPONENTS=${COMPONENTS:-main,universe}
    [ "$TOOL" = auto ] && TOOL=debootstrap
    ;;
  *) die "不支持的发行版: $DISTRO（可选 arch / debian / ubuntu）";;
esac

IMG=${OUT:-$HOME/xaga/rootfs-${DISTRO}.img}

log "发行版 : $DISTRO $RELEASE"
log "镜像站 : $MIRROR"
log "镜像   : $IMG ($SIZE)"
log "工作区 : $WORKDIR"
log "内核树 : $KDIR"

# ---------------------------------------------------------------------------
# 前置检查
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "请用 sudo 运行（bootstrap / chroot / mkfs 都需要 root）"

apt-get install -y -qq --no-install-recommends \
  qemu-user-static e2fsprogs curl ca-certificates 2>/dev/null || true

QEMU=/usr/bin/qemu-aarch64-static
[ -f "$QEMU" ] || die "缺少 $QEMU，请先: apt-get install -y qemu-user-static"

# debootstrap 只认 /usr/share/debootstrap/scripts/ 里存在的 suite 名。
# 在旧主机上装新发行版（如 24.04 上做 26.04 resolute）会报 "no such script"，
# 这里拿机器上一个可用脚本顶替。
ensure_suite_script() {
  local s=$1 dir=/usr/share/debootstrap/scripts cand
  [ -e "$dir/$s" ] && return 0
  for cand in questing plucky oracular mantic resolute noble jammy trixie bookworm sid; do
    if [ -e "$dir/$cand" ]; then
      warn "debootstrap 没有 '$s' 脚本，用 '$cand' 的顶替"
      ln -sf "$dir/$cand" "$dir/$s"
      return 0
    fi
  done
  return 1
}

# chroot 包装：优先 binfmt，没注册就显式调 qemu
setup_chroot_cmd() {
  if [ -d /proc/sys/fs/binfmt_misc ] && [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    log "binfmt 已注册，直接 chroot"
    CHROOT=(chroot "$WORKDIR")
  else
    warn "binfmt 未注册（容器/云主机常见），改用显式 qemu 解释器"
    CHROOT=(chroot "$WORKDIR" /usr/bin/qemu-aarch64-static)
  fi
}

# ---------------------------------------------------------------------------
# 1. bootstrap
# ---------------------------------------------------------------------------
if [ -x "$WORKDIR/bin/sh" ] || [ -x "$WORKDIR/usr/bin/env" ]; then
  log "检测到已存在的 rootfs 目录，跳过 bootstrap（想重来请 rm -rf $WORKDIR）"
else
  mkdir -p "$WORKDIR"

  case "$DISTRO" in
  arch)
    log "下载 Arch Linux ARM aarch64 tarball"
    command -v bsdtar >/dev/null || apt-get install -y -qq libarchive-tools 2>/dev/null || true
    cd "$(dirname "$WORKDIR")"
    if [ ! -f "$ARCH_TARBALL" ]; then
      curl -fL -O "${MIRROR}${ARCH_TARBALL}" \
        || die "下载失败。官方源: http://os.archlinuxarm.org/os/${ARCH_TARBALL}"
    fi
    log "解压 $(basename "$ARCH_TARBALL")"
    if command -v bsdtar >/dev/null; then
      bsdtar -xpf "$ARCH_TARBALL" -C "$WORKDIR"     # 保留 xattr / capabilities
    else
      warn "没装 bsdtar，退回 tar（capabilities 可能丢失）"
      tar -xpf "$ARCH_TARBALL" -C "$WORKDIR"
    fi
    ;;
  debian|ubuntu)
    ensure_suite_script "$RELEASE" || die "找不到 $RELEASE 的 debootstrap 脚本"
    if [ "$TOOL" = mmdebstrap ]; then
      command -v mmdebstrap >/dev/null || die "TOOL=mmdebstrap 但没装: apt-get install -y mmdebstrap"
      log "mmdebstrap $RELEASE/arm64 -> $WORKDIR"
      mmdebstrap --architecture=arm64 --variant=minbase \
                 --components="$COMPONENTS" \
                 "$RELEASE" "$WORKDIR" "$MIRROR"
    else
      log "debootstrap $RELEASE/arm64 -> $WORKDIR"
      debootstrap --arch=arm64 --foreign --components="$COMPONENTS" \
                  "$RELEASE" "$WORKDIR" "$MIRROR"
    fi
    ;;
  esac
fi

# 公共准备：qemu + DNS + proc/sys
cp -f "$QEMU" "$WORKDIR/usr/bin/" 2>/dev/null || true
rm -f "$WORKDIR/etc/resolv.conf"
cp /etc/resolv.conf "$WORKDIR/etc/resolv.conf" 2>/dev/null || true
mkdir -p "$WORKDIR/proc" "$WORKDIR/sys"
mount -t proc  proc  "$WORKDIR/proc" 2>/dev/null || true
mount -t sysfs sysfs "$WORKDIR/sys"  2>/dev/null || true

setup_chroot_cmd

# debootstrap --foreign 需要 second-stage；mmdebstrap 与 Arch 一次到位
if [ -d "$WORKDIR/debootstrap" ] && [ "$TOOL" != mmdebstrap ]; then
  log "second-stage（qemu 下跑，比较慢，耐心等）"
  "${CHROOT[@]}" /bin/sh -c "/debootstrap/debootstrap --second-stage" || {
    warn "second-stage 返回非零，检查 $WORKDIR/debootstrap/ 下的日志"
    [ -n "${STRICT:-}" ] && exit 1
  }
fi

# ---------------------------------------------------------------------------
# 2. 通用配置
# ---------------------------------------------------------------------------
log "写通用配置（hostname / hosts / fstab）"
printf '%s\n' "$TARGET_HOSTNAME" > "$WORKDIR/etc/hostname"
cat > "$WORKDIR/etc/hosts" <<EOF
127.0.0.1       localhost
127.0.1.1       $TARGET_HOSTNAME
::1             localhost ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff00::0         ip6-mcastprefix
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

# root 必须指向 /dev/sdc86，否则 systemd 会认为 rootfs 不匹配
cat > "$WORKDIR/etc/fstab" <<'EOF'
# <device>     <mount>  <type>  <options>                          <dump> <pass>
/dev/sdc86     /        ext4    defaults,noatime,errors=remount-ro  0      1
EOF

# 密码走文件，避免 heredoc 里的引号地狱
printf 'root:%s\n' "$ROOTPW" > "$WORKDIR/rootpw.txt"

log "安装软件包并配置服务（$DISTRO）"
case "$DISTRO" in
arch)
  cat > "$WORKDIR/configure.sh" <<'EOS'
set -e
pacman-key --init
pacman-key --populate archlinuxarm
# 用我们自己编的内核，去掉 tarball 自带的（省 ~100MB，也免得混淆）
pacman -Rdd --noconfirm linux-aarch64 2>/dev/null || true
pacman -Syu --noconfirm
pacman -S --noconfirm --needed \
  networkmanager iwd openssh sudo vim less curl ca-certificates linux-firmware-mediatek \
  2>/dev/null || \
pacman -S --noconfirm --needed \
  networkmanager iwd openssh sudo vim less curl ca-certificates

sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/'   /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
ssh-keygen -A

systemctl enable NetworkManager
systemctl enable sshd
systemctl enable systemd-resolved
systemctl enable getty@tty1

cat /rootpw.txt | chpasswd
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
EOS
  ;;
debian|ubuntu)
  cat > "$WORKDIR/configure.sh" <<'EOS'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  systemd-sysv dbus \
  network-manager iwd wpasupplicant \
  openssh-server sudo \
  ca-certificates curl less vim-tiny

sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/'   /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
ssh-keygen -A

systemctl enable ssh
systemctl enable NetworkManager
systemctl enable systemd-resolved
systemctl enable getty@tty1

cat /rootpw.txt | chpasswd
echo "Asia/Shanghai" > /etc/timezone
rm -f /etc/localtime
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
EOS
  ;;
esac

"${CHROOT[@]}" /bin/sh /configure.sh || warn "配置阶段有命令失败，请人工检查（不致命）"
rm -f "$WORKDIR/configure.sh" "$WORKDIR/rootpw.txt"

# ---------------------------------------------------------------------------
# 3. 内核模块
# ---------------------------------------------------------------------------
if [ -f "$KDIR/vmlinux" ] && [ -d "$KDIR/scripts" ]; then
  log "安装内核模块 -> $WORKDIR"
  KVER=$(make -s -C "$KDIR" ARCH=arm64 kernelrelease)
  log "内核版本: $KVER"
  make -C "$KDIR" ARCH=arm64 LLVM=1 \
       modules_install \
       INSTALL_MOD_PATH="$WORKDIR" \
       INSTALL_MOD_STRIP=1 \
       DEPMOD=true
  # 必须在目标架构下生成 modules.dep（宿主是 x86 的 depmod）
  "${CHROOT[@]}" /bin/sh -c "depmod -a $KVER" 2>/dev/null \
    || warn "chroot 里 depmod 失败;开机后手动跑: depmod -a $KVER"
else
  warn "没找到内核源码树 $KDIR，跳过模块安装（没模块 == 大部分硬件不工作）"
fi

# ---------------------------------------------------------------------------
# 4. /sbin/init 兜底 —— init.c 写死了 execve("/sbin/init")，缺了必黑屏
# ---------------------------------------------------------------------------
if [ ! -e "$WORKDIR/sbin/init" ]; then
  for c in /usr/lib/systemd/systemd /lib/systemd/systemd /usr/bin/systemd; do
    if [ -e "$WORKDIR$c" ]; then
      warn "/sbin/init 不存在，补一个 -> $c"
      mkdir -p "$WORKDIR/sbin"
      ln -sf "$c" "$WORKDIR/sbin/init"
      break
    fi
  done
fi
[ -e "$WORKDIR/sbin/init" ] || die "rootfs 里没有 /sbin/init！init.c 会 exec 失败然后死循环黑屏"

# ---------------------------------------------------------------------------
# 5. 收尾并打包
# ---------------------------------------------------------------------------
log "收尾 -> $IMG"
umount -lf "$WORKDIR/proc" 2>/dev/null || true
umount -lf "$WORKDIR/sys"  2>/dev/null || true
rm -f "$WORKDIR/usr/bin/qemu-aarch64-static"
rm -rf "$WORKDIR/debootstrap" 2>/dev/null || true

mkdir -p "$(dirname "$IMG")"
rm -f "$IMG"
truncate -s "$SIZE" "$IMG"
mkfs.ext4 -F -L xaga-root -d "$WORKDIR" "$IMG"
e2fsck -fy "$IMG" || true

if [ "$MAKE_SPARSE" = "1" ] && command -v img2simg >/dev/null; then
  log "生成 sparse 镜像（fastboot 传输快得多）"
  img2simg "$IMG" "${IMG%.img}-sparse.img"
  ls -lh "$IMG" "${IMG%.img}-sparse.img"
else
  [ "$MAKE_SPARSE" = "1" ] && warn "没装 img2simg，跳过 sparse（apt-get install android-sdk-libsparse-utils）"
  ls -lh "$IMG"
fi

log "完成"
echo
echo "  发行版     : $DISTRO $RELEASE"
echo "  镜像       : $IMG ($SIZE)"
echo "  rootfs 目录: $WORKDIR"
echo "  登录       : root / $ROOTPW"
echo
echo "  开机后扩充分区: resize2fs /dev/sdc86"
echo "  6GB 版先确认  : free -h   （DT memory 节点写死 8GiB，见指南 5.2 节）"
echo
echo "  下一步:"
echo "    adb reboot bootloader"
echo "    fastboot boot <新 boot.img>              # 临时启动，先验证"
echo "    fastboot flash userdata ${IMG%.img}-sparse.img   # ⚠ 清空内置存储"
