# Chromium 148 Linux 版交叉构建手册（服务器 + Docker）

在 Linux x86_64 服务器上用 Docker 容器构建 Linux 版指纹 Chromium
（`148.0.7778.215` + 全部 fingerprint patches）。

工作区结构（外置 SSD / 服务器 SSD）：

```
mk_ch/
├── chromium/src/            # 源码（含已应用的 patches）
├── fingerprint-chromium-upstream/
│   └── patches/             # 正式 patch（source of truth）
├── depot_tools/             # Chromium 工具链（Mac 版，服务器上仅脚本可用）
└── tmp/                     # 启动/检测脚本
```

## 1. 前置条件

- Linux x86_64 服务器，Docker 20.10+，建议 32 核 / 64GB 内存
- 磁盘：源码 ~14GB + 工具链 ~8GB + 构建产物 ~30GB + Docker 镜像 ~2GB
- 服务器能访问 `chromium.googlesource.com`、`storage.googleapis.com`、`github.com`
  （拉取工具链与依赖）。国内服务器一般可达（Google 系走公网）。
- 从 macOS 工作区同步源码（见第 3 节）

## 2. 构建镜像与启动容器

```zsh
# 宿主机
docker build -t chromium-linux-build fingerprint-chromium-upstream/docs/linux-build/

docker run -d --name chromium-build \
  -v /path/to/mk_ch:/workspace \
  -w /workspace \
  --network host \
  --shm-size=4g \
  --privileged \
  --device /dev/fuse \
  --cpus 28 \
  chromium-linux-build \
  sleep infinity
```

> **国内服务器拉不到 Docker Hub**：可先在宿主机用
> `debootstrap bullseye /tmp/rootfs http://deb.debian.org/debian/`
> 制作 rootfs 后 `docker import` 成镜像，Dockerfile 的 FROM 改为该镜像。
>
> `--cpus 28` 必须设置：编译满载时若占满全部核，宿主机 SSH 会失联。
> `--privileged --device /dev/fuse` 仅 Windows 交叉编译需要（ciopfs），
> 只编 Linux 可省略。

## 3. 同步源码（macOS → 服务器）

从 Mac 工作区 rsync 到服务器，排除 Mac 构建产物与临时文件：

```zsh
rsync -a \
  --exclude='chromium/src/out/' \
  --exclude='chromium/src/.git/' \
  --exclude='.cache/' \
  --exclude='.tmp/' \
  --exclude='.screen/' \
  --exclude='backup/' \
  --exclude='tmp/chromium-148.0.7778.215/' \
  --exclude='tmp/cdp-venv/' \
  --exclude='tmp/fp-test-*/' \
  --exclude='tmp/detection/results*/' \
  --exclude='tmp/*.png' \
  --exclude='tmp/*.log' \
  /path/to/mk_ch/ user@server:/path/to/mk_ch/
```

> 源码里 `third_party/llvm-build`、`third_party/node/mac`、`third_party/rust-toolchain`、
> `devtools-frontend/.../esbuild` 是 **Mac 版二进制**（Mach-O），
> `build_linux.sh` 会自动检测并替换为 Linux 版，无需手动处理。

## 4. 编译

```zsh
# 容器内
docker exec -it chromium-build bash

# 一键脚本（自动装依赖/工具链 + gn + ninja）
bash /workspace/fingerprint-chromium-upstream/docs/linux-build/build_linux.sh

# 或分步手动执行：
export PATH=/opt/python312/bin:$PATH
cd /workspace/chromium/src

# 4.1 构建依赖（apt 包，首次约 10 分钟）
DEBIAN_FRONTEND=noninteractive ./build/install-build-deps.sh \
  --no-arm --no-chromeos-fonts --no-prompt

# 4.2 工具链（Linux clang + sysroot）
python3 tools/clang/scripts/update.py
python3 build/linux/sysroot_scripts/install-sysroot.py --arch=amd64

# 4.3 GN 配置
mkdir -p out/Linux
cat > out/Linux/args.gn <<'EOF'
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
buildtools/linux64/gn gen out/Linux

# 4.4 编译（32 核约 4-5 小时）
ninja -C out/Linux -j 28 chrome
```

关键配置说明：

- `dcheck_always_on = false`：与官方 Chrome 一致（官方是 official build）。
  不关闭时字体指纹页面（browserleaks.com/fonts）会触发 Blink 布局
  EXPENSIVE_DCHECK 崩溃。**改回 true 会导致全量重编**。
- `use_siso = false`：使用系统 ninja（源码自带的 siso 是 Mac 版）。
- `target_cpu = "x64"`：服务器为 x86_64。

## 5. 验证

```zsh
cd /workspace/chromium/src/out/Linux
LD_LIBRARY_PATH=. ./chrome --version
# Chromium 148.0.7778.215
```

指纹验证（CDP）：

```zsh
# 启动（VNC 显示 :99，CDP 9223）
Xvfb :99 -screen 0 1920x1080x24 &
x11vnc -display :99 -rfbport 5900 -passwd 123456 &
DISPLAY=:99 ./chrome --no-sandbox --remote-debugging-port=9223 \
  --user-data-dir=/tmp/fp-linux \
  --fingerprint=13 --fingerprint-platform=linux \
  --fingerprinting-canvas-image-data-noise \
  --fingerprinting-canvas-measure-text-noise \
  --fingerprinting-client-rects-noise \
  --fingerprint-hardware-concurrency=4 \
  --fingerprint-device-memory=8 \
  --fingerprint-screen-width=1920 --fingerprint-screen-height=1080 \
  --fingerprint-device-scale-factor=1 --timezone=America/New_York &

# 检测站点（容器内装好 websocket-client）
/opt/python312/bin/python3 \
  /workspace/tmp/detection/run_detection.py 9223 linux /workspace/tmp/detection/results
```

> 容器内默认没有 Ubuntu 字体（`fonts-ubuntu` 在 Debian 11 无包）。
> browserleaks fonts 检测数量会比真实 Linux 桌面少，属正常现象；
> 如需要可下载 Google Fonts 的 Ubuntu 变体字体放入 `/usr/share/fonts`。

## 6. 增量编译

修改 patch / 源码后（patch-first：先改
`fingerprint-chromium-upstream/patches` 再应用到源码）：

```zsh
docker exec chromium-build bash -c 'bash /workspace/fingerprint-chromium-upstream/docs/linux-build/build_linux.sh'
```

ninja 只重编受影响文件。**不要删 `out/Linux` 或容器**（产物在挂载的 SSD 上，容器可随时重建）。

## 7. 常见问题

| 问题 | 原因 | 解决 |
|---|---|---|
| SSH 失联 / 服务器不响应 | 编译占满全部核 | 容器加 `--cpus 28`（或更低） |
| `Exec format error`（python/rustc/esbuild/…） | Mac 版二进制 | 重跑 `build_linux.sh`（自动替换 Linux 版） |
| `TypeError: unsupported operand ... '\|'` | Python 3.9 太老 | 用 /opt/python312（镜像已装） |
| install-build-deps 卡在 Keyboard layout | apt 交互 | 加 `DEBIAN_FRONTEND=noninteractive` + `--no-prompt` |
| `vpython3 not found` | Mac depot_tools | 镜像已建 `vpython3` 软链 |
| dpkg 锁 / debconf 锁 | 中断残留进程 | `kill -9` 残留 apt/debconf 进程 + 删锁文件 |
| fonts 页面崩溃（仅未关 DCHECK 时） | Blink EXPENSIVE_DCHECK | `args.gn` 必须含 `dcheck_always_on = false` |
| gsutil 需要 luci-auth | Mac 二进制 | 见下方 Windows 交叉编译说明 |
| 外置 SSD 掉盘 | 供电/连接不稳 | 直连 USB-C，编译中断后重跑 ninja 续编 |

## 8. Windows 交叉编译（现状）

Linux 上交叉编译 Windows 版需要 MSVC STL + Windows SDK 10.0.26100（toolchain hash
`e66617bc68`）。该工具链打包在 Google 私有 bucket（`gs://chrome-wintoolchain`），
**公网 403**。获取途径：

- **推荐**：用 GitHub Actions 的 `voiceofhu/chromium-win-toolchain` workflow
  在 Windows runner 上自动打包（~15 分钟），得到 `<hash>.zip`。
- 或 Windows 机器本地跑 `depot_tools/win_toolchain/package_from_installed.py`
  （VS 2026 Build Tools + SDK 10.0.26100），SOP 见
  <https://gist.github.com/nczz/64883b0992d93e939f5ac2432a5ddf4f>。
- 拿到 zip 后：

```zsh
# 放到本地目录
mkdir -p /mnt/ssd/win-toolchain
mv <hash>.zip /mnt/ssd/win-toolchain/

# 容器内
export DEPOT_TOOLS_WIN_TOOLCHAIN_BASE_URL=/mnt/ssd/win-toolchain
export GYP_MSVS_HASH_e66617bc68=<实际hash>
cd /workspace/chromium/src
python3 build/vs_toolchain.py update --force   # 需要 ciopfs（--privileged + /dev/fuse）

mkdir -p out/Win64 && cat > out/Win64/args.gn <<'EOF'
target_os = "win"
target_cpu = "x64"
is_debug = false
is_component_build = true
symbol_level = 0
dcheck_always_on = false
is_official_build = false
EOF
buildtools/linux64/gn gen out/Win64
ninja -C out/Win64 -j 28 chrome
```

容器内 wine 跑 VS bootstrapper 不可靠（wine 10 在容器内 WoW64 有
kernel32 加载问题），不建议走该路径。

## 9. 参考

- 本机（macOS）构建手册：`mk_ch/CHROMIUM_BUILD.md`
- Patch 规则与工作区约束：`mk_ch/AGENTS.md`
