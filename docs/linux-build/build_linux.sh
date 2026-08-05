#!/bin/bash
# Chromium 148 Linux (x86_64) 一键构建脚本
# 在构建容器内运行：bash /workspace/fingerprint-chromium-upstream/docs/linux-build/build_linux.sh
#
# 依赖：
#   - /workspace/chromium/src 已同步（含全部 patches 的源码）
#   - 容器内已运行过 install-build-deps（脚本会自动补跑）
#
# 用法：
#   bash build_linux.sh              # 增量构建
#   bash build_linux.sh clean        # 全新构建（先删 out/Linux）

set -euo pipefail

export PATH=/opt/python312/bin:$PATH
SRC=/workspace/chromium/src
OUT=$SRC/out/Linux
JOBS=${JOBS:-28}

cd "$SRC"

# ---------- 1. Chromium 构建依赖（apt 包） ----------
if ! dpkg -l libgtk-3-dev >/dev/null 2>&1; then
  echo "==> install-build-deps"
  DEBIAN_FRONTEND=noninteractive ./build/install-build-deps.sh \
    --no-arm --no-chromeos-fonts --no-prompt
fi

# ---------- 2. 工具链 ----------
# clang：源码里的 llvm-build 若为 Mac 版（Mach-O）则替换为 Linux 版
if [ -f third_party/llvm-build/Release+Asserts/bin/clang ] && \
   ! head -c 4 third_party/llvm-build/Release+Asserts/bin/clang | grep -q ELF; then
  echo "==> 下载 Linux clang"
  python3 tools/clang/scripts/update.py
fi

# sysroot（Debian bullseye amd64）
if [ ! -d build/linux/debian_bullseye_amd64-sysroot ]; then
  echo "==> 下载 sysroot"
  python3 build/linux/sysroot_scripts/install-sysroot.py --arch=amd64
fi

# ---------- 3. 平台二进制（Mac 源码 rsync 过来时是 Mac 版） ----------
# node（DEPS.mac-bootstrap 中 src/third_party/node/linux 的 GCS 对象）
NODE_VERSION_FILE=tools/node/chromium.version
NODE_BIN=third_party/node/linux/node-linux-x64/bin/node
if [ ! -x "$NODE_BIN" ] || ! "$NODE_BIN" --version >/dev/null 2>&1; then
  echo "==> 下载 Linux node"
  # 从 DEPS.mac-bootstrap 中提取 node/linux 的 object_name 与下载 URL
  NODE_OBJ=$(python3 - "$SRC/DEPS.mac-bootstrap" <<'PYEOF'
import re, sys
deps = open(sys.argv[1]).read()
m = re.search(r"'src/third_party/node/linux':\s*\{.*?'objects':\s*\[\s*\{\s*'object_name':\s*'([^']+)'", deps, re.S)
print(m.group(1) if m else "")
PYEOF
  )
  mkdir -p third_party/node/linux
  curl -sL -o /tmp/node-linux.tar.gz "https://storage.googleapis.com/chromium-nodejs/$NODE_OBJ"
  tar xzf /tmp/node-linux.tar.gz -C third_party/node/linux
  rm -f /tmp/node-linux.tar.gz
fi

# rust：third_party/rust-toolchain 若为 Mac 版则替换为 Linux 版
if [ -f third_party/rust-toolchain/bin/rustc ] && \
   ! head -c 4 third_party/rust-toolchain/bin/rustc | grep -q ELF; then
  echo "==> 下载 Linux rust"
  RUST_OBJ=$(python3 - "$SRC/DEPS.mac-bootstrap" <<'PYEOF'
import re, sys
deps = open(sys.argv[1]).read()
m = re.search(r"'src/third_party/rust-toolchain':\s*\{.*?'objects':\s*\[\s*\{.*?'object_name':\s*'([^']*Linux_x64/[^']+)'", deps, re.S)
print(m.group(1) if m else "")
PYEOF
  )
  if [ -n "$RUST_OBJ" ]; then
    rm -rf third_party/rust-toolchain/bin third_party/rust-toolchain/etc \
           third_party/rust-toolchain/lib third_party/rust-toolchain/libexec \
           third_party/rust-toolchain/share third_party/rust-toolchain/VERSION
    curl -sL -o /tmp/rust-toolchain.tar.xz "https://storage.googleapis.com/chromium-browser-clang/$RUST_OBJ"
    tar xJf /tmp/rust-toolchain.tar.xz -C third_party/rust-toolchain
    rm -f /tmp/rust-toolchain.tar.xz
  fi
fi

# esbuild：devtools-frontend 的 esbuild 若为 Mac 版则替换为 Linux 版
ESBUILD=third_party/devtools-frontend/src/third_party/esbuild/esbuild
if [ -f "$ESBUILD" ] && ! head -c 4 "$ESBUILD" | grep -q ELF; then
  echo "==> 下载 Linux esbuild"
  ESBUILD_VER=$(python3 -c \
    "import json; print(json.load(open('third_party/devtools-frontend/src/package.json'))['devDependencies']['esbuild'])")
  curl -sL -o /tmp/esbuild-linux.tgz \
    "https://registry.npmjs.org/@esbuild/linux-x64/-/linux-x64-$ESBUILD_VER.tgz"
  mkdir -p /tmp/esb && tar xzf /tmp/esbuild-linux.tgz -C /tmp/esb
  cp /tmp/esb/package/bin/esbuild "$ESBUILD"
  chmod +x "$ESBUILD"
  rm -rf /tmp/esb /tmp/esbuild-linux.tgz
fi

# ---------- 4. GN 配置 ----------
mkdir -p "$OUT"
if [ ! -f "$OUT/args.gn" ]; then
  echo "==> 生成 args.gn"
  cat > "$OUT/args.gn" <<EOF
is_debug = false
is_component_build = true
symbol_level = 0
blink_symbol_level = 0
v8_symbol_level = 0
dcheck_always_on = false
target_cpu = "x64"
use_siso = false
is_official_build = false
enable_updater = false
EOF
fi

if [ "${1:-}" = "clean" ]; then
  echo "==> 清理 out/Linux"
  rm -rf "$OUT"
  mkdir -p "$OUT"
  cat > "$OUT/args.gn" <<EOF
is_debug = false
is_component_build = true
symbol_level = 0
blink_symbol_level = 0
v8_symbol_level = 0
dcheck_always_on = false
target_cpu = "x64"
use_siso = false
is_official_build = false
enable_updater = false
EOF
fi

echo "==> gn gen"
buildtools/linux64/gn gen out/Linux

# ---------- 5. 编译 ----------
echo "==> ninja -C out/Linux -j $JOBS chrome"
ninja -C out/Linux -j "$JOBS" chrome

echo "==> 产物: $OUT/chrome"
"$OUT/chrome" --version
