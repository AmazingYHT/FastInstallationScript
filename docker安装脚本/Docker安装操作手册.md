# Docker 安装操作手册

> 基于离线安装脚本的 Docker 快速部署指南

---

## 📋 目录

1. [环境准备](#环境准备)
2. [离线包下载](#离线包下载)
3. [版本兼容对照](#版本兼容对照)
4. [安装 Docker](#安装-docker)
5. [配置说明](#配置说明)
6. [Docker 代理配置（docker-proxy-manager.sh）](#-docker-代理配置docker-proxy-managersh)
7. [卸载 Docker](#卸载-docker)
8. [常用命令](#常用命令)
9. [常见问题](#常见问题)

---

## 🔧 环境准备

### 系统要求

```
要求项        最低配置        推荐配置
─────────────────────────────────────
内核          3.10+          5.14+（RHEL/Rocky 9.x）
内存          2GB            4GB+
磁盘空间      20GB           50GB+
架构          x86_64         x86_64/ARM64
```

**支持的操作系统**（静态二进制方案，不依赖发行版 RPM 源）：

| 系统 | 版本 | 支持情况 | 说明 |
|------|------|----------|------|
| **Rocky Linux** | **9.8** | ✅ 已验证 | 内核 5.14+；注意 firewalld/nftables、SELinux |
| Rocky Linux | 9.x | ✅ 支持 | 与 RHEL 9 对齐 |
| Rocky Linux | 8.x | ✅ 支持 | |
| AlmaLinux | 8.x / 9.x | ✅ 支持 | 与 Rocky 同源 |
| CentOS | 7 / 8 / Stream | ✅ 支持 | CentOS 7 内核偏旧，建议仅用 Docker 20.x–25.x |
| RHEL / Oracle Linux | 8.x / 9.x | ✅ 支持 | |
| Ubuntu | 20.04 / 22.04 / 24.04 | ✅ 支持 | |
| Debian | 11 / 12 | ✅ 支持 | |
| WSL2 | Windows 10/11 | ✅ 支持 | 脚本自动适配；数据目录勿放 `/mnt/` |

> **Rocky Linux 9.8 补充**：安装一般不会因系统版本失败；若容器端口映射不通，优先检查 firewalld（nftables 后端）与 SELinux。

### 目录结构准备

```
项目目录/
├── installDocker.sh              # Docker 安装脚本
├── uninstallDocker.sh            # Docker 卸载脚本
├── package/
│   └── docker-*.tgz              # Docker 离线安装包（静态二进制）
└── conf/
    ├── docker.service            # Docker systemd 服务文件
    └── docker-compose-linux-x86_64-*  # Docker Compose 二进制文件
```

### 文件放置路径

> 当前版本：**Docker Engine 29.8.1** + **Docker Compose 5.5.1**

| 文件 | 本地路径 | 说明 |
|------|----------|------|
| Docker Engine | `package/docker-29.8.1.tgz` | 引擎 + CLI + containerd + runc |
| Docker Compose | `conf/docker-compose-linux-x86_64-5.5.1` | Compose v5 独立二进制（当前） |
| Docker Compose（旧） | `conf/docker-compose-linux-x86_64-2.40.3` | Compose v2 旧版，可选保留 |
| systemd 服务 | `conf/docker.service` | 随仓库提供，无需下载 |

> ⚠️ **安装脚本注意**：`installDocker.sh` 使用 `cp ./conf/docker-compose*` 复制 Compose。  
> **conf 目录下请只保留一个** Compose 二进制（推荐 `docker-compose-linux-x86_64-5.5.1`），避免多个文件被一起拷贝导致覆盖异常。

---

## 📦 离线包下载

> 适用于 `docker-29.9.1_install/`。Rocky Linux 9.x / CentOS 8+ / Ubuntu 均可使用静态二进制方案。  
> 当前推荐组合：**Docker 29.8.1 + Compose 5.5.1**

### 官方下载地址（可离线下载后拷贝到服务器）

**x86_64**

| 资源 | 下载地址 |
|------|----------|
| Docker Engine 29.8.1（当前） | https://download.docker.com/linux/static/stable/x86_64/docker-29.8.1.tgz |
| Docker Engine 29.5.3（旧） | https://download.docker.com/linux/static/stable/x86_64/docker-29.5.3.tgz |
| Docker Compose v5.5.1（当前） | https://github.com/docker/compose/releases/download/v5.5.1/docker-compose-linux-x86_64 |
| Docker Compose v2.40.3（旧） | https://github.com/docker/compose/releases/download/v2.40.3/docker-compose-linux-x86_64 |
| 全部静态包列表 | https://download.docker.com/linux/static/stable/x86_64/ |

**aarch64 / ARM64**

| 资源 | 下载地址 |
|------|----------|
| Docker Engine 29.8.1 | https://download.docker.com/linux/static/stable/aarch64/docker-29.8.1.tgz |
| Docker Engine 29.5.3 | https://download.docker.com/linux/static/stable/aarch64/docker-29.5.3.tgz |
| 全部静态包列表 | https://download.docker.com/linux/static/stable/aarch64/ |

### 在线机下载示例

```bash
# 进入安装目录
cd docker-29.9.1_install

# 下载 Docker Engine 29.8.1（x86_64）
curl -L -o package/docker-29.8.1.tgz \
  https://download.docker.com/linux/static/stable/x86_64/docker-29.8.1.tgz

# 下载 Docker Compose 5.5.1
curl -L -o conf/docker-compose-linux-x86_64-5.5.1 \
  https://github.com/docker/compose/releases/download/v5.5.1/docker-compose-linux-x86_64

# 清理旧版 Compose（避免 installDocker.sh 同时匹配到多个文件）
rm -f conf/docker-compose-linux-x86_64-2.40.3

# （可选）校验文件完整性后，拷贝整个目录到离线服务器
```

### 可选：EL9 RPM 包（适合 dnf/rpm 离线安装）

基址：https://download.docker.com/linux/centos/9/x86_64/stable/Packages/

| 资源 | 文件名 |
|------|--------|
| containerd | `containerd.io-2.3.5-1.el9.x86_64.rpm` |
| Docker CE | `docker-ce-29.8.1-1.el9.x86_64.rpm` |
| Docker CE CLI | `docker-ce-cli-29.8.1-1.el9.x86_64.rpm` |
| Buildx 插件 | `docker-buildx-plugin-0.37.1-1.el9.x86_64.rpm` |
| Compose 插件 | `docker-compose-plugin-5.5.1-1.el9.x86_64.rpm` |

```bash
# 离线安装示例
sudo dnf localinstall -y \
  containerd.io-*.rpm \
  docker-ce-cli-*.rpm \
  docker-ce-*.rpm \
  docker-buildx-plugin-*.rpm \
  docker-compose-plugin-*.rpm
```

> **建议**：优先使用仓库自带的静态二进制脚本（`installDocker.sh`），避免与系统 podman 冲突。RPM 方式仅在需要 dnf 管理升级时使用。

### Rocky Linux 9.8 注意事项

- 内核 5.14+，兼容 Docker 29.x，**安装不会因系统版本失败**
- firewalld 使用 nftables 后端，端口映射不通时检查防火墙/forwarding
- SELinux enforcing 下挂载卷建议加 `:Z`，或临时 `setenforce 0` 验证
- 安装后验证：`docker info` 与 `docker run --rm hello-world`

---

## 🧩 版本兼容对照

> Compose **没有**官方「Compose 小版本 ↔ Engine 小版本」一一对应表。  
> 兼容靠 **Docker API 版本协商**。以下对照用于选型与排障。

### Engine ↔ API 兼容矩阵（官方）

来源：https://docs.docker.com/engine/api/#api-version-matrix

| Docker Engine | 最高 API | 最低 API | 说明 |
|---------------|----------|----------|------|
| **29.8** | 1.56 | **1.40** | 当前离线包 docker-29.8.1 |
| **29.5** | 1.54 | **1.40** | 旧离线包 docker-29.5.3 |
| 29.3–29.4 | 1.54 | 1.40 | |
| 29.0–29.2 | 1.52–1.53 | 1.44 | 29 初代最低 API 更严 |
| 28.x | 1.48–1.51 | 1.24 | |
| 27.x | 1.46–1.47 | 1.24 | |
| 25–26.x | 1.44–1.45 | 1.24 | |
| 23–24.x | 1.42–1.43 | 1.12 | |
| 20.10 | 1.41 | 1.12 | Compose v2 实用下限 |
| 19.03 | 1.40 | 1.12 | 很旧 |
| ≤18.09 | ≤1.39 | 1.12 | 已废弃，现代 Compose 不保证 |

**读法**：客户端/Compose 与 Engine 协商到双方都支持的 API；兼容是 best-effort，极老 Engine 可能缺新特性。  
现场自检：`docker version` 查看 Client/Server 的 API version。

### Compose CLI ↔ Docker Engine（实用对照）

| Compose CLI | 建议 Engine | 说明 |
|-------------|-------------|------|
| **v5.5.x（当前 5.5.1）** | **Docker 29.x**（推荐 29.3+） | 构建依赖 docker/cli 29.x；功能 ≈ v2，另含 Go SDK |
| v2.40.x | Docker 20.10+（推荐 25+/28+/29） | 旧离线包 2.40.3 |
| v2.x 通用 | Engine 20.10+ | 低于此不保证 |
| v1.x（Python，已停） | 老 Engine 1.13–20.x | 不要用在新环境 |

### 本仓库离线包组合建议

| 组合 | 兼容性 |
|------|--------|
| Docker **29.8.1** + Compose **5.5.1** | ✅ **当前推荐** |
| Docker 29.8.1 + Compose 2.40.3 | ✅ OK |
| Docker 29.5.3 + Compose 5.5.1 | ✅ OK |
| Docker 29.5.3 + Compose 2.40.3 | ✅ OK（旧组合） |
| Docker 20.10 + Compose 5.5.1 | ⚠️ 能跑，新 API 特性受限 |
| Docker 18.x + Compose 5.x | ❌ 不建议 |

### 遗留：compose.yml `version:` 字段 ↔ Engine 最低版

（旧文档已归档；Compose Spec / v2 / v5 会忽略顶层 `version`）

| 文件格式 `version` | 建议最低 Docker Engine |
|--------------------|------------------------|
| 2.0 | 1.10.0+ |
| 2.1 | 1.12.0+ |
| 2.2 | 1.13.0+ |
| 2.3–2.4 | 17.06.0+ |
| 3.0–3.1 | 1.13.x |
| 3.2 | 17.04.0+ |
| 3.3 | 17.06.0+ |
| 3.4 | 17.09.0+ |
| 3.5–3.8 | 18.06.0+ |
| Compose Spec（无 version） | 随 Compose v2/v5 + 现代 Engine |

### 相关查表入口

| 内容 | 地址 |
|------|------|
| Engine ↔ API 兼容矩阵 | https://docs.docker.com/engine/api/#api-version-matrix |
| API 变更史 | https://docs.docker.com/reference/api/engine/version-history/ |
| Compose 版本演进（v1/v2/v5） | https://docs.docker.com/compose/intro/history/ |
| Compose 各版本 Release | https://github.com/docker/compose/releases |

---

## 🚀 安装 Docker

### 执行方式说明

> ⚠️ **重要提示**：本脚本必须使用 `bash` 执行，不能使用 `sh` 执行。
> 
> **原因**：Ubuntu/Debian 系统的默认 `/bin/sh` 是 `dash`，对某些语法支持不完整。
> 
> **正确用法**：
> ```bash
> # 方式1：直接执行（推荐）
> chmod +x installDocker.sh
> ./installDocker.sh
> 
> # 方式2：使用bash执行
> bash installDocker.sh
> ```
> 
> **错误用法**（会导致语法错误）：
> ```bash
> sh installDocker.sh  # ❌ 不要用sh执行
> ```

### 方式一：脚本自动安装（推荐）

```bash
# 1. 赋予执行权限
chmod +x installDocker.sh

# 2. 执行安装脚本（使用bash）
sudo ./installDocker.sh

# 3. 输入 Docker 数据存储路径
# 直接回车使用默认路径 /mnt/data/dockerWork
# 或输入自定义路径，如：/data/docker
```

### 安装流程

```
┌─────────────────────────────────────────────────────────────┐
│              Docker 安装流程                                 │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ① 解压 tar 包并赋予权限                                     │
│     ↓                                                        │
│  ② 复制二进制文件到 /usr/bin/                               │
│     ↓                                                        │
│  ③ 复制 docker.service 到 /etc/systemd/system/             │
│     ↓                                                        │
│  ④ 设置 Docker 数据存储路径（可自定义）                      │
│     ↓                                                        │
│  ⑤ 创建 /etc/docker/daemon.json 配置文件                    │
│     ↓                                                        │
│  ⑥ 重载 systemd 并启动 Docker 服务                          │
│     ↓                                                        │
│  ⑦ 安装 Docker Compose                                      │
│     ↓                                                        │
│  ⑧ 验证安装结果                                              │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 验证安装

```bash
# 查看 Docker 版本信息
docker info

# 查看 Docker 版本
docker --version

# 查看 Docker Compose 版本
docker-compose --version

# 运行测试容器
docker run --rm hello-world
```

---

## ⚙️ 配置说明

### daemon.json 配置文件

安装完成后，`/etc/docker/daemon.json` 配置如下：

```json
{
    "data-root": "/mnt/data/dockerWork",
    "insecure-registries": [
        "registry.cn-shenzhen.aliyuncs.com"
    ],
    "registry-mirrors": [
        "https://docker.1panel.live",
        "https://hub-mirror.c.163.com",
        "https://docker.m.daocloud.io",
        "https://ghcr.io",
        "https://mirror.baidubce.com",
        "https://docker.nju.edu.cn",
        "https://registry.docker-cn.com",
        "https://dockerhub.azk8s.cn",
        "https://docker.mirrors.ustc.edu.cn",
        "https://mirror.ccs.tencentyun.com"
    ]
}
```

### 配置项说明

| 配置项 | 说明 | 默认值 |
|-------|------|-------|
| data-root | Docker 数据存储根目录 | /mnt/data/dockerWork |
| insecure-registries | 允许的 HTTP 私有仓库 | registry.cn-shenzhen.aliyuncs.com |
| registry-mirrors | 镜像加速器列表 | 多个国内加速源 |

### 自定义数据目录

```bash
# 方法一：安装时输入
sudo ./installDocker.sh
# 输入自定义路径，如：/data/docker

# 方法二：修改配置文件
sudo vi /etc/docker/daemon.json

# 修改 data-root 字段
{
    "data-root": "/your/custom/path"
}

# 重启 Docker 服务
sudo systemctl daemon-reload
sudo systemctl restart docker
```

### 服务管理

```bash
# 启动 Docker
sudo systemctl start docker

# 停止 Docker
sudo systemctl stop docker

# 重启 Docker
sudo systemctl restart docker

# 查看状态
sudo systemctl status docker

# 开机自启
sudo systemctl enable docker

# 取消自启
sudo systemctl disable docker
```

---

## � Docker 代理配置（docker-proxy-manager.sh）

> 在国内网络环境下，拉取 Docker Hub / gcr.io / quay.io 等海外镜像常常失败或速度极慢。
> 本脚本支持**交互式配置代理 IP 和端口**，一键管理 Docker 守护进程（拉镜像）和 Docker 客户端（容器内/构建）的代理。

### 脚本文件位置

```
docker-29.9.1_install/
└── docker-proxy-manager.sh   # Docker 代理一键管理脚本
```

### 第一步：准备脚本

将 `docker-proxy-manager.sh` 上传至 Linux 服务器任意目录（例如与 installDocker.sh 同级）。

> ⚠️ **重要**：如果脚本是在 Windows 下创建/编辑的，文件会带有 Windows 风格的换行符（`\r\n`），Linux bash 会报语法错误。
> 执行以下命令修复换行符：

```bash
sed -i 's/\r$//' docker-proxy-manager.sh
```

### 第二步：赋予执行权限

```bash
chmod +x docker-proxy-manager.sh
```

### 第三步：运行脚本（使用 bash）

```bash
bash docker-proxy-manager.sh
```

运行后会看到如下菜单：

```
=====================================
       Docker 代理一键管理工具
=====================================
1. 仅开启Docker守护进程代理（拉镜像专用，不影响容器内部）
2. 开启完整全局代理（拉镜像+容器内+构建全走代理）
-------------------------------------
3. 仅清理 守护进程拉镜像代理配置
4. 清理 全部全局代理配置（守护进程+客户端）
5. 退出脚本
=====================================
请输入你要执行的操作序号:
```

### 选项说明

| 选项 | 名称 | 作用范围 | 典型场景 |
|------|------|----------|----------|
| 1 | 守护进程代理 | 仅 Docker daemon 拉镜像 | 机器本身已经能上网，只需要 `docker pull` 走代理 |
| 2 | 完整全局代理 | 守护进程 + 容器内 + docker build | 需要在容器内 `apt-get/yum/pip/npm` 下载依赖 |
| 3 | 清理守护进程代理 | 仅移除 daemon 代理 | 要关闭拉镜像代理但保留容器内代理 |
| 4 | 清理全部代理 | 移除 daemon + 客户端代理 | 完全恢复默认，不留任何代理配置 |
| 5 | 退出脚本 | - | 不执行任何操作退出 |

### 交互示例（选项 2：完整全局代理）

```
请输入你要执行的操作序号: 2
正在配置Docker完整全局代理...
请输入代理 IP (回车默认 127.0.0.1): 192.168.1.100
请输入代理端口 (回车默认 7890): 7891
请输入 NO_PROXY 规则 (回车使用默认):
ℹ️  当前代理地址：http://192.168.1.100:7891
ℹ️  NO_PROXY 规则：localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16
✅ 全局代理配置完成
守护进程代理状态：
Environment=HTTP_PROXY=http://192.168.1.100:7891 HTTPS_PROXY=http://192.168.1.100:7891 NO_PROXY=localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16
客户端代理配置：
{
  "proxies": {
    "default": {
      "httpProxy": "http://192.168.1.100:7891",
      "httpsProxy": "http://192.168.1.100:7891",
      "noProxy": "localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
    }
  }
}
```

### 关键概念：什么是 NO_PROXY？

NO_PROXY 是代理"白名单"——匹配到的地址**不走代理**，直接通过本地/内网连接。

脚本默认值已覆盖常见内网网段：

```
localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16
```

**为什么必须配置 NO_PROXY？**

- Docker 容器默认使用 `172.17.0.0/16`、`172.18.0.0/16` 等 B 类内网网段互相通信；如果这些地址走代理，容器互联、服务发现会直接失败。
- 访问宿主机本地服务（localhost/127.0.0.1）不应绕代理。
- 公司内网镜像仓库、内网 API 本就直连可达。

如果你的内网还有额外网段（例如 `100.64.0.0/10` 或 `.corp.com` 域），可在交互提示时追加到默认规则后面。

### 手动验证代理是否生效

```bash
# 验证守护进程代理（拉镜像代理）
systemctl show docker --property=Environment
# 或
systemctl show docker | grep -i proxy

# 验证客户端代理（容器内代理）
cat ~/.docker/config.json

# 实际拉一个海外镜像测试
docker pull hello-world
```

### 常见注意事项

**Q1: 代理地址填宿主机的 127.0.0.1，为什么容器里访问不到？**
> 容器内的 `127.0.0.1` 指容器自己，不是宿主机。
> **解决方法**：代理 IP 必须填宿主机的**真实内网 IP**（例如 `192.168.1.100`），并且代理软件需要开启"允许局域网访问"。
> 或者 Docker Desktop / Linux 使用 `host.docker.internal`（需要 Docker 新版本支持）。

**Q2: 脚本里为什么要重启 Docker？**
> 守护进程代理是写到 `docker.service.d/http-proxy.conf` 里的 systemd Environment 变量，
> 必须 `systemctl daemon-reload` + `systemctl restart docker` 才能生效。

**Q3: 我只想临时让一次 docker build 走代理，不想改全局配置？**
```bash
docker build --build-arg HTTP_PROXY=http://192.168.1.100:7890 \
             --build-arg HTTPS_PROXY=http://192.168.1.100:7890 \
             -t myimg .
```

**Q4: 运行脚本提示 `command not found` 或语法错误？**
> 大概率是 Windows 换行符（`\r\n`）没清理，重新执行：
> ```bash
> sed -i 's/\r$//' docker-proxy-manager.sh
> bash docker-proxy-manager.sh
> ```

---

## ��️ 卸载 Docker

### 方式一：脚本自动卸载（推荐）

```bash
# 1. 赋予执行权限
chmod +x uninstallDocker.sh

# 2. 执行卸载脚本
sudo ./uninstallDocker.sh
```

### 卸载流程

```
┌─────────────────────────────────────────────────────────────┐
│              Docker 卸载流程                                 │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ① 停止所有运行中的容器                                      │
│     ↓                                                        │
│  ② 删除所有容器                                              │
│     ↓                                                        │
│  ③ 删除所有镜像                                              │
│     ↓                                                        │
│  ④ 停止 Docker 服务                                          │
│     ↓                                                        │
│  ⑤ 取消开机自启                                              │
│     ↓                                                        │
│  ⑥ 删除 Docker 二进制文件                                    │
│     ↓                                                        │
│  ⑦ 删除 systemd 服务文件                                     │
│     ↓                                                        │
│  ⑧ 删除配置文件和数据目录                                    │
│     ↓                                                        │
│  ⑨ 卸载 Docker Compose                                      │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 卸载详情

**将被删除**：
- ❌ 所有容器
- ❌ 所有镜像
- ❌ Docker 二进制文件（/usr/bin/）
- ❌ Docker 服务文件（/etc/systemd/system/docker.service）
- ❌ Docker 配置（/etc/docker/）
- ❌ Docker 数据目录（daemon.json 中的 data-root）
- ❌ Docker Compose

---

## 📚 常用命令

### 镜像操作

```bash
# 拉取镜像
docker pull nginx:latest

# 查看本地镜像
docker images

# 删除镜像
docker rmi nginx:latest

# 强制删除所有镜像
docker rmi -f $(docker images -q)

# 构建镜像
docker build -t myapp:v1.0 .
```

### 容器操作

```bash
# 运行容器
docker run -d --name mynginx -p 80:80 nginx

# 查看运行中的容器
docker ps

# 查看所有容器
docker ps -a

# 停止容器
docker stop mynginx

# 启动容器
docker start mynginx

# 重启容器
docker restart mynginx

# 删除容器
docker rm mynginx

# 强制删除所有容器
docker rm -f $(docker ps -a -q)

# 查看容器日志
docker logs mynginx

# 进入容器
docker exec -it mynginx /bin/bash
```

### Docker Compose

```bash
# 启动服务
docker-compose up -d

# 停止服务
docker-compose down

# 查看服务状态
docker-compose ps

# 查看服务日志
docker-compose logs -f

# 重启服务
docker-compose restart
```

---

## ❓ 常见问题

### Q1: Docker 服务启动失败？

**排查步骤**：

```bash
# 1. 查看 Docker 服务状态
systemctl status docker

# 2. 查看 Docker 日志
journalctl -u docker -n 50

# 3. 检查配置文件语法
cat /etc/docker/daemon.json

# 4. 检查数据目录权限
ls -la /mnt/data/dockerWork

# 5. 手动启动查看详细错误
dockerd --debug
```

**常见原因**：
- 配置文件 JSON 格式错误
- 数据目录权限不足
- 端口被占用
- 系统资源不足

---

### Q2: 镜像拉取速度慢或失败？

**解决方案**：

```bash
# 1. 检查镜像加速器配置
cat /etc/docker/daemon.json

# 2. 修改镜像加速器
sudo vi /etc/docker/daemon.json

# 推荐的国内加速源
{
    "registry-mirrors": [
        "https://docker.1panel.live",
        "https://docker.m.daocloud.io",
        "https://mirror.baidubce.com"
    ]
}

# 3. 重启 Docker
sudo systemctl daemon-reload
sudo systemctl restart docker

# 4. 测试拉取
docker pull hello-world
```

---

### Q3: 修改 Docker 数据存储路径？

**操作步骤**：

```bash
# 1. 停止 Docker
sudo systemctl stop docker

# 2. 修改配置文件
sudo vi /etc/docker/daemon.json
# 修改 "data-root" 为新路径

# 3. 迁移现有数据（可选）
sudo mv /mnt/data/dockerWork /new/path/dockerWork

# 4. 重启 Docker
sudo systemctl daemon-reload
sudo systemctl start docker

# 5. 验证新路径
docker info | grep "Docker Root Dir"
```

---

### Q4: 容器无法访问外网？

**排查步骤**：

```bash
# 1. 检查防火墙
sudo firewall-cmd --list-all

# 2. 检查 Docker 网络配置
docker network ls
docker network inspect bridge

# 3. 重启 Docker 网络
sudo systemctl restart docker

# 4. 使用 host 网络模式测试
docker run --rm --net=host alpine ping -c 3 baidu.com
```

---

### Q5: 如何清理 Docker 占用空间？

```bash
# 清理未使用的镜像
docker image prune -a

# 清理停止的容器
docker container prune

# 清理未使用的卷
docker volume prune

# 清理未使用的网络
docker network prune

# 一键清理所有未使用资源
docker system prune -a --volumes
```

---

### Q6: Docker 命令需要 sudo？

**解决方案**：

```bash
# 1. 创建 docker 组（如果不存在）
sudo groupadd docker

# 2. 将当前用户添加到 docker 组
sudo usermod -aG docker $USER

# 3. 重新登录或执行
newgrp docker

# 4. 验证（无需 sudo）
docker ps
```

---

### Q7: 如何配置私有镜像仓库？

```bash
# 编辑 daemon.json
sudo vi /etc/docker/daemon.json

# 添加私有仓库配置
{
    "insecure-registries": [
        "192.168.1.100:5000",
        "registry.mycompany.com"
    ]
}

# 重启 Docker
sudo systemctl restart docker

# 登录私有仓库
docker login 192.168.1.100:5000

# 推送镜像
docker tag myapp:latest 192.168.1.100:5000/myapp:latest
docker push 192.168.1.100:5000/myapp:latest
```

---

### Q8: 卸载后重新安装注意事项？

```bash
# 1. 确保完全卸载
sudo ./uninstallDocker.sh

# 2. 检查残留文件
ls -la /usr/bin/docker*
ls -la /etc/systemd/system/docker.service
ls -la /etc/docker/
ls -la /mnt/data/dockerWork

# 3. 手动清理残留（如有）
sudo rm -rf /usr/bin/docker*
sudo rm -rf /etc/systemd/system/docker.service
sudo rm -rf /etc/docker/
sudo rm -rf /mnt/data/dockerWork

# 4. 重新加载 systemd
sudo systemctl daemon-reload

# 5. 重新安装
sudo ./installDocker.sh
```

---

### Q9: 使用 sh 执行脚本报错？

**错误信息**：
```
installDocker.sh: 103: exit: Illegal number: -1
```

**原因**：
- Ubuntu/Debian 系统的默认 `/bin/sh` 是 `dash`
- `dash` 对 `exit -1` 这种非标准语法不支持
- CentOS 的默认 `/bin/sh` 是 `bash`，语法更宽松

**解决方案**：

```bash
# 方式1：使用bash执行（推荐）
bash installDocker.sh

# 方式2：赋予执行权限后直接运行
chmod +x installDocker.sh
./installDocker.sh

# 方式3：使用sudo执行
sudo bash installDocker.sh
```

**验证当前shell**：
```bash
# 查看当前使用的shell
echo $SHELL

# 查看/bin/sh指向的shell
ls -la /bin/sh
```

---

## 📖 附录

### 文件路径对照

| 文件/目录 | 说明 |
|----------|------|
| /usr/bin/docker* | Docker 二进制文件 |
| /usr/local/bin/docker-compose | Docker Compose 二进制文件 |
| /etc/systemd/system/docker.service | Docker systemd 服务文件 |
| /etc/docker/daemon.json | Docker 配置文件 |
| /mnt/data/dockerWork | Docker 数据存储目录（默认） |

### 端口说明

| 端口 | 说明 |
|-----|------|
| 2375 | Docker API（非加密）|
| 2376 | Docker API（加密 TLS）|
| 2377 | Docker Swarm 管理 |

### 版本对照（当前离线包）

| 组件 | 版本 | 本地文件 |
|------|------|----------|
| Docker Engine | 29.8.1 | `package/docker-29.8.1.tgz` |
| Docker Compose | 5.5.1 | `conf/docker-compose-linux-x86_64-5.5.1` |
| Docker API | 1.56（min 1.40） | 由 Engine 29.8 提供 |

### 相关资源

- Docker 官方文档：https://docs.docker.com/
- Docker Hub：https://hub.docker.com/
- Docker Compose 文档：https://docs.docker.com/compose/
- Docker Engine API 兼容矩阵：https://docs.docker.com/engine/api/#api-version-matrix
- Compose Release（含 5.5.1）：https://github.com/docker/compose/releases

---

## 📞 技术支持

如有问题，请检查：
1. Docker 日志：`journalctl -u docker -n 100`
2. Docker 配置：`cat /etc/docker/daemon.json`
3. 系统日志：`tail -f /var/log/messages`

---

> 📅 文档版本：v1.1
> 🔄 更新日期：2026年
> 📦 适用版本：Docker Engine 29.8.1 + Docker Compose 5.5.1
> 📧 适用脚本：installDocker.sh / uninstallDocker.sh
