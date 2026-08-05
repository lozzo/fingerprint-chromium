# Chromium 148 Linux (x86_64) 构建环境镜像

基于 Debian 11 bullseye 的 Chromium 构建环境。镜像只装系统级环境；
Chromium 源码、构建依赖、工具链通过挂载的 `/workspace`（工作区）在容器启动后准备。

## 构建镜像

```zsh
docker build -t chromium-linux-build .
```

国内服务器拉不到 Docker Hub 时，可先导入本地已有的 `debian:bullseye` 镜像，
或在宿主机用 debootstrap 制作 rootfs 后 `docker import`。

## 启动容器

```zsh
docker run -d --name chromium-build \
  -v /path/to/workspace:/workspace \
  -w /workspace \
  --network host \
  --shm-size=4g \
  --privileged \
  --device /dev/fuse \
  --cpus 28 \
  chromium-linux-build \
  sleep infinity
```

参数说明：

- `--network host`：容器内用宿主网络（拉取 Google/微软资源、暴露 CDP/VNC 端口）。
- `--privileged --device /dev/fuse`：Windows SDK 交叉编译需要 ciopfs（FUSE）时使用。
  只编译 Linux 版可去掉。
- `--cpus 28`：限制容器最多使用 28 核，避免把宿主机负载打满导致 SSH 失联。
  宿主机核心数不同时按需调整。
- `-v /path/to/workspace:/workspace`：挂载整个工作区（含 `chromium/src`、
  `depot_tools`、`fingerprint-chromium-upstream` 等）。

## 容器内环境

- Python 3.12（/opt/python312，Chromium 148 要求 >= 3.10，Debian 11 自带的 3.9 不可用）
- `vpython3` 软链指向 /opt/python312/bin/python3（depot_tools 的 gsutil 需要）
- `websocket-client`（CDP 检测脚本用）
- 基础工具：git、curl、wget、sudo、procps、file、lsb-release、build-essential、
  ninja、p7zip、xvfb、fonts-liberation/fonts-dejavu-core

Chromium 构建依赖（`install-build-deps.sh`）体积大且依赖挂载的源码，
在容器启动后由 `build_linux.sh` 执行。
