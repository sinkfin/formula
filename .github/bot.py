name: 静态检查

on:
  push:
    branches: [main, master]
  pull_request:
  workflow_dispatch:

permissions:
  contents: read

jobs:
  shell:
    name: Shell 检查
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: 安装 shellcheck
        run: |
          sudo apt-get update -qq
          sudo apt-get install -y --no-install-recommends shellcheck

      - name: 语法检查（bash -n）
        run: |
          set -euo pipefail
          mapfile -t files < <(git ls-files '*.sh')
          if [ "${#files[@]}" -eq 0 ]; then echo "没有 shell 脚本"; exit 0; fi
          for f in "${files[@]}"; do
            echo "== bash -n $f"
            bash -n "$f"
          done

      - name: shellcheck（error 级阻断）
        run: |
          set -euo pipefail
          mapfile -t files < <(git ls-files '*.sh')
          if [ "${#files[@]}" -eq 0 ]; then exit 0; fi
          shellcheck --severity=error --shell=bash "${files[@]}"

      - name: shellcheck（style 级仅提示，不阻断）
        run: |
          set -euo pipefail
          mapfile -t files < <(git ls-files '*.sh')
          if [ "${#files[@]}" -eq 0 ]; then exit 0; fi
          shellcheck --severity=style --shell=bash "${files[@]}" \
            || echo "::warning::shellcheck 有 style 级告警，见上方日志"

      - name: 帮助信息冒烟
        run: |
          chmod +x make-rootfs.sh
          ./make-rootfs.sh --help

      - name: 关键硬件约束自检
        # 这几条来自 initramfs 的 init.c 硬编码，改脚本时别踩碎
        run: |
          set -euo pipefail
          fail=0
          check() { # <文件> <正则> <说明>
            if grep -Eq "$2" "$1"; then echo "OK   $3"; else
              echo "::error::$3 —— 未命中 '$2'"; fail=1; fi
          }
          check make-rootfs.sh 'mkfs\.ext4'        "文件系统必须是 ext4"
          check make-rootfs.sh '/dev/sdc86'        "root 分区默认是 userdata(sdc86)"
          check make-rootfs.sh 'sbin/init'         "必须保证 /sbin/init 存在"
          check make-rootfs.sh '/dev/sdc13|nvdata' "nvdata(sdc13) 用于取 WiFi NVRAM"
          exit "$fail"

  workflow:
    name: 工作流检查
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: actionlint
        run: |
          set -euo pipefail
          ver=1.7.7
          curl -sSL -o /tmp/actionlint.tgz \
            "https://github.com/rhysd/actionlint/releases/download/v${ver}/actionlint_${ver}_linux_amd64.tar.gz"
          tar -xzf /tmp/actionlint.tgz -C /tmp actionlint
          sudo install -m 0755 /tmp/actionlint /usr/local/bin/actionlint
          actionlint -color

      - name: YAML 解析
        run: |
          set -euo pipefail
          python3 - <<'PY'
          import glob, sys
          import yaml
          bad = 0
          for f in sorted(glob.glob('.github/workflows/*.yml')):
              try:
                  yaml.safe_load(open(f, encoding='utf-8'))
                  print(f"OK   {f}")
              except Exception as e:
                  bad = 1
                  print(f"FAIL {f}: {e}")
          sys.exit(bad)
          PY
