#!/usr/bin/env bash
#
# build-xaga.sh — Redmi Note 11T Pro (xaga / MT6895 / Dimensity 8100)
#                 Linux mainline 7.2 全链路 Clang 构建 + boot.img 打包
#
# 目标机器: Armbian / Ubuntu / Debian x86_64
# 产物:     $OUT/boot.img  $OUT/Image.gz  $OUT/initramfs.cpio.gz  $OUT/modules.tar.gz
#
# 用法:
#   chmod +x build-xaga.sh && ./build-xaga.sh
#   USE_RUST=1 BOOT_PARTITION=/dev/sdc86 ./build-xaga.sh
#
# 注意: xaga 内核树把 DTB 通过 objcopy 链进 vmlinux, 且构建 DTB 的递归 make
#       硬编码了 LLVM=1 —— 所以 Clang (>=17.0.1) 是硬性要求, 且不要加 O= 出树构建。
#
set -euo pipefail

# ───────────────────────────── 配置区(可用环境变量覆盖) ─────────────────────────────
TOP="${TOP:-$HOME/xaga}"
KERNEL_REPO="${KERNEL_REPO:-https://github.com/MT6895-Mainline/linux}"
KERNEL_BRANCH="${KERNEL_BRANCH:-7.2-mt6895-xiaomi-xaga}"
INITRAMFS_REPO="${INITRAMFS_REPO:-https://github.com/MT6895-Mainline/initramfs}"
INITRAMFS_BRANCH="${INITRAMFS_BRANCH:-xaga-mt6895}"

BOOT_PARTITION="${BOOT_PARTITION:-/dev/sdc86}"     # xaga: userdata
NVDATA_PARTITION="${NVDATA_PARTITION:-/dev/sdc13}" # xaga: nvdata
HEADER_VERSION="${HEADER_VERSION:-4}"
PAGE_SIZE="${PAGE_SIZE:-4096}"

USE_RUST="${USE_RUST:-0}"        # 0 = 关闭 Rust(推荐首次); 1 = 需要 rustc>=1.85
SKIP_APT="${SKIP_APT:-0}"        # 1 = 跳过 apt 安装依赖
JOBS="${JOBS:-$(nproc)}"

LINUX_DIR="$TOP/linux"
INITRAMFS_DIR="$TOP/initramfs"
TOOLS_DIR="$TOP/tools"
OUT="$TOP/out"

R="\033[31m"; G="\033[32m"; Y="\033[33m"; C="\033[36m"; N="\033[0m"
step() { echo -e "\n${C}==>${N} ${G}$*${N}"; }
warn() { echo -e "${Y}[warn]${N} $*"; }
die()  { echo -e "${R}[fatal]${N} $*" >&2; exit 1; }

# ───────────────────────────── 1. 依赖 ─────────────────────────────
if [[ "$SKIP_APT" != "1" ]]; then
  step "安装构建依赖"
  sudo apt-get update -qq
  sudo apt-get install -y -qq \
    git bc bison flex libssl-dev libelf-dev libncurses-dev \
    cpio lz4 zstd gzip xz-utils kmod rsync python3 device-tree-compiler \
    build-essential gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu
  # lz4 是硬需求：initramfs 仓库的 Makefile 用 `lz4 -l -9` 打 legacy 格式，
  # 而 xaga 原厂 boot.img 的 RAMDISK_FMT 也正是 lz4_legacy。
fi

# ───────────────────────────── 2. 定位 Clang (>= 17.0.1) ─────────────────────────────
step "检查 Clang 工具链 (最低 17.0.1)"
clang_ver() { "$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true; }
ver_ge() { # ver_ge a b  -> a >= b
  [[ "$(printf '%s\n%s' "$2" "$1" | sort -V | head -1)" == "$2" ]]
}

CLANG_BIN=""
for c in clang clang-20 clang-19 clang-18 clang-17 \
         /usr/lib/llvm-20/bin/clang /usr/lib/llvm-19/bin/clang \
         /usr/lib/llvm-18/bin/clang /usr/lib/llvm-17/bin/clang; do
  if command -v "$c" >/dev/null 2>&1 || [[ -x "$c" ]]; then
    v="$(clang_ver "$c")"
    if [[ -n "$v" ]] && ver_ge "$v" "17.0.1"; then CLANG_BIN="$(command -v "$c" || echo "$c")"; break; fi
  fi
done

if [[ -z "$CLANG_BIN" ]]; then
  warn "未找到 >= 17.0.1 的 clang，尝试安装 LLVM 18 (apt.llvm.org)…"
  sudo apt-get install -y -qq lsb-release wget software-properties-common gnupg
  wget -q https://apt.llvm.org/llvm.sh -O /tmp/llvm.sh && chmod +x /tmp/llvm.sh
  sudo /tmp/llvm.sh 18 all
  CLANG_BIN="/usr/lib/llvm-18/bin/clang"
fi

LLVM_BIN_DIR="$(dirname "$CLANG_BIN")"
export PATH="$LLVM_BIN_DIR:$PATH"
echo "  clang        : $CLANG_BIN ($(clang_ver "$CLANG_BIN"))"
command -v ld.lld      >/dev/null || die "缺少 ld.lld，请安装 lld"
command -v llvm-objcopy >/dev/null || die "缺少 llvm-objcopy (DTB 嵌入步骤必需)，请安装 llvm 包"

export ARCH=arm64
export LLVM=1
# 不要设置 O= —— DTB 的递归 make 只在 srctree 里跑

# ───────────────────────────── 3. 拉代码 ─────────────────────────────
step "拉取源码 (shallow)"
mkdir -p "$TOP"
[[ -d "$LINUX_DIR/.git"     ]] || git clone --depth=1 -b "$KERNEL_BRANCH" "$KERNEL_REPO" "$LINUX_DIR"
[[ -d "$INITRAMFS_DIR/.git" ]] || git clone --depth=1 -b "$INITRAMFS_BRANCH" "$INITRAMFS_REPO" "$INITRAMFS_DIR"
[[ -d "$TOOLS_DIR/.git"     ]] || git clone --depth=1 https://android.googlesource.com/platform/system/tools/mkbootimg "$TOOLS_DIR"

# ───────────────────────────── 4. 构建 initramfs (gz) ─────────────────────────────
# init.c 的作用: 挂载 nvdata -> 把 /nvdata/APCFG/APRDEB/WIFI 拷到 rootfs 的
#                /lib/firmware/mediatek/mt6895/WIFI, 再把会延迟加载的固件镜像到 rootfs,
#                最后 pivot_root 到 BOOT_PARTITION 并 exec /sbin/init
step "构建 initramfs (BOOT_PARTITION=$BOOT_PARTITION, NVDATA_PARTITION=$NVDATA_PARTITION)"
make -C "$INITRAMFS_DIR" clean
# ⚠️ 不要写 `make initramfs.cpio` —— 该 Makefile 的目标是**绝对路径**
#    TMP_CPIO := $(CURDIR)/initramfs.cpio，make 匹配不到相对名字，会报
#    "No rule to make target 'initramfs.cpio'"。
#    直接跑默认目标 all（= initramfs.cpio.lz4），它会先生成 initramfs.cpio 再 lz4。
# ⚠️ NVDATA_PARTITION 不是 Makefile 变量（Makefile 只有 BOOT_PARTITION），
#    init.c 里的默认值 /dev/sdc13 就是 xaga 的 nvdata，一般无需改。
make -C "$INITRAMFS_DIR" \
     BOOT_PARTITION="$BOOT_PARTITION" \
     CROSS=aarch64-linux-gnu-
# 仓库用 `lz4 -l -9` 产出 legacy 格式，正好匹配原厂 boot.img 的 RAMDISK_FMT
# [lz4_legacy]；内核侧 CONFIG_RD_LZ4=y 已开，无需再自己 gzip。
echo "  initramfs.cpio     : $(du -h "$INITRAMFS_DIR/initramfs.cpio" | cut -f1)"
echo "  initramfs.cpio.lz4 : $(du -h "$INITRAMFS_DIR/initramfs.cpio.lz4" | cut -f1)"

# ───────────────────────────── 5. 生成 .config ─────────────────────────────
step "生成 .config (defconfig + xaga.config fragment)"
cd "$LINUX_DIR"
scripts/kconfig/merge_config.sh \
  arch/arm64/configs/defconfig \
  arch/arm64/configs/xaga.config

if [[ "$USE_RUST" != "1" ]]; then
  warn "关闭 Rust (CONFIG_RUST=n, panic 画面改用 kmsg)"
  scripts/config --disable CONFIG_RUST
  scripts/config --disable CONFIG_DRM_PANIC_SCREEN_QR_CODE
  scripts/config --set-str CONFIG_DRM_PANIC_SCREEN "kmsg"
else
  warn "USE_RUST=1：请确保 rustc>=1.85(作者 pin 1.88) 与 bindgen>=0.71.1 已就绪"
fi

# ── 关掉与 xaga (MT6895) 无关的联发科 ASoC 驱动 ─────────────────────────────
# 这棵树的 defconfig 默认打开了 MT8183/MT8188/MT8192/MT8195/MT8365 + SOF MT8186/8195。
# 其中 mt8183-afe-pcm.c 在文件内自己定义了 MTK_AFE_RATE_8K / MTK_AFE_DAI_MEMIF_RATE_8K
# 枚举，而 common/mtk-base-afe.h 里已经有一份同名且取值不同的定义(MT8183 用
# MTK_AFE_RATE_130K=7，common 头用 MTK_AFE_RATE_352K=7)，Clang 直接判 redefinition：
#   sound/soc/mediatek/mt8183/mt8183-afe-pcm.c:26:2: error: redefinition of
#   enumerator 'MTK_AFE_RATE_8K'
# 这些 SoC 都是 Chromebook/电视盒方案，xaga 用不到，关掉即可（顺带省编译时间）。
warn "关闭无关联发科 ASoC 驱动 (仅保留 MT6895)"
scripts/config \
  --disable CONFIG_SND_SOC_MT8183 \
  --disable CONFIG_SND_SOC_MT8183_MT6358_TS3A227E_MAX98357A \
  --disable CONFIG_SND_SOC_MT8183_DA7219_MAX98357A \
  --disable CONFIG_SND_SOC_MT8188 \
  --disable CONFIG_SND_SOC_MT8188_MT6359 \
  --disable CONFIG_SND_SOC_MT8192 \
  --disable CONFIG_SND_SOC_MT8192_MT6359_RT1015_RT5682 \
  --disable CONFIG_SND_SOC_MT8195 \
  --disable CONFIG_SND_SOC_MT8195_MT6359 \
  --disable CONFIG_SND_SOC_MT8365 \
  --disable CONFIG_SND_SOC_MT8365_MT6357 \
  --disable CONFIG_SND_SOC_SOF_MT8186 \
  --disable CONFIG_SND_SOC_SOF_MT8195

make LLVM=1 ARCH=arm64 olddefconfig

# 注意: arm64 没有 CONFIG_KERNEL_GZIP —— 压缩是 make target 决定的, 不是 Kconfig
for k in CONFIG_RD_GZIP CONFIG_BLK_DEV_INITRD CONFIG_OF CONFIG_MODULES; do
  printf '  %-24s %s\n' "$k" "$(grep -m1 "^${k}=" .config || echo "${k} (unset)")"
done
grep -q '^CONFIG_OF=y' .config || die "CONFIG_OF 必须为 y —— DTB 嵌入依赖它"

# ───────────────────────────── 6. 编译内核 ─────────────────────────────
step "编译内核 (Image.gz + modules, -j$JOBS)"
make -j"$JOBS" LLVM=1 ARCH=arm64 Image.gz modules 2>&1 | tee "$TOP/build.log"

IMAGE_GZ="$LINUX_DIR/arch/arm64/boot/Image.gz"
DTB="$LINUX_DIR/arch/arm64/boot/dts/mediatek/mt6895-xiaomi-xaga.dtb"
[[ -f "$IMAGE_GZ" ]] || die "Image.gz 未生成，检查 $TOP/build.log"
[[ -f "$DTB" ]]     || die "xaga DTB 未生成，检查 $TOP/build.log"

step "校验 DTB 已嵌入 vmlinux"
if nm "$LINUX_DIR/vmlinux" | grep -q mt6895_xiaomi_xaga_dtb_start; then
  echo -e "  ${G}OK${N}: _binary_arch_arm64_boot_dts_mediatek_mt6895_xiaomi_xaga_dtb_start 存在"
else
  die "DTB 未链入 vmlinux —— 开机必挂。检查 clang 是否在 PATH 且 >= 17.0.1"
fi

# ───────────────────────────── 7. 打包 boot.img ─────────────────────────────
step "打包 boot.img"
mkdir -p "$OUT"
cp "$IMAGE_GZ" "$OUT/Image.gz"
cp "$INITRAMFS_DIR/initramfs.cpio"     "$OUT/"   # 原始 cpio（给 magiskboot repack 用）
cp "$INITRAMFS_DIR/initramfs.cpio.lz4" "$OUT/"   # legacy lz4（给 mkbootimg 用）

# 注意: 不要加 --dtb，DTB 已经嵌在内核里了
python3 "$TOOLS_DIR/mkbootimg.py" \
  --header_version "$HEADER_VERSION" \
  --pagesize "$PAGE_SIZE" \
  --kernel "$OUT/Image.gz" \
  --ramdisk "$OUT/initramfs.cpio.lz4" \
  -o "$OUT/boot.img"

# 模块打成 tar，方便塞进 rootfs 的 /lib/modules
make -j"$JOBS" LLVM=1 ARCH=arm64 modules_install INSTALL_MOD_PATH="$OUT/mods" INSTALL_MOD_STRIP=1 >/dev/null
tar -czf "$OUT/modules.tar.gz" -C "$OUT/mods" lib
rm -rf "$OUT/mods"

step "完成"
ls -lh "$OUT"
echo
echo -e "${Y}刷机:${N}"
echo "  adb reboot bootloader"
echo "  fastboot flash userdata rootfs.img      # 会清空手机内置存储!"
echo "  fastboot boot $OUT/boot.img             # 临时启动验证，不写盘"
echo "  fastboot flash boot_a $OUT/boot.img     # 验证 OK 后再落盘"
echo -e "${Y}回滚:${N} fastboot flash boot_a stock_boot.img"
