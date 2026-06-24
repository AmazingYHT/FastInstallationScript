# rnacos 自动化部署脚本使用手册

支持 **Linux** 和 **Windows** 双平台，支持 **单机/集群** 两种部署模式，rnacos 版本可配置。

> rnacos（r-nacos）是用 **Rust** 重写的 Nacos 服务端，单文件部署、资源占用极低（内存约为 Java 版的 1/10），兼容 Nacos 1.x/2.x 客户端。集群基于 **Raft** 协议，无需外部数据库。

## 脚本说明

| 脚本 | 平台 | 说明 |
|------|------|------|
| `install_rnacos.sh` | Linux | 安装脚本，支持单机/集群 |
| `install_rnacos.bat` | Windows | 安装脚本，功能与 Linux 对齐 |
| `uninstall_rnacos.sh` | Linux | 卸载脚本 |
| `uninstall_rnacos.bat` | Windows | 卸载脚本 |

## 使用前提

- **无需 Java、无需外部数据库**。rnacos 为单一可执行文件，数据默认存储在本地嵌入式数据库（sled）。
- **集群模式**：建议 3 个节点，基于 Raft 选举，需各节点 gRPC 端口互通。

## 安装包获取（本地优先 + 自动下载）

脚本优先使用 `package/` 目录下的安装包，缺失时自动从 GitHub 下载：

- Linux：`package/rnacos-x86_64-unknown-linux-musl-<版本>.tar.gz`
- Windows：`package\rnacos-x86_64-pc-windows-msvc-<版本>.zip`

官方下载地址：`https://github.com/nacos-group/r-nacos/releases`

> 默认版本 `v0.8.3`，可通过 `--version` 指定。其他架构（如 ARM64）可通过 `--target` 指定平台标识。

## 端口说明

| 端口 | 默认值 | 用途 |
|------|--------|------|
| HTTP/API | 8848 | 兼容 Nacos 的 HTTP API |
| gRPC | 9848 | 兼容 Nacos 2.x 的 gRPC（默认 = HTTP端口 + 1000）|
| Console | 10848 | rnacos 独立控制台 |

## 快速开始（Linux）

```bash
# 交互式安装
bash install_rnacos.sh

# 单机模式
bash install_rnacos.sh --standalone

# 指定版本
bash install_rnacos.sh --standalone --version v0.8.3

# 集群首节点（自动初始化）
bash install_rnacos.sh --cluster --node-id 1 --node-addr 192.168.1.10:9848 --auto-init

# 集群其他节点（加入已有集群）
bash install_rnacos.sh --cluster --node-id 2 --node-addr 192.168.1.11:9848 --join-addr 192.168.1.10:9848
bash install_rnacos.sh --cluster --node-id 3 --node-addr 192.168.1.12:9848 --join-addr 192.168.1.10:9848
```

## 快速开始（Windows）

```bat
REM 交互式安装
install_rnacos.bat

REM 单机模式
install_rnacos.bat --standalone

REM 集群首节点
install_rnacos.bat --cluster --node-id 1 --node-addr 192.168.1.10:9848 --auto-init

REM 集群其他节点
install_rnacos.bat --cluster --node-id 2 --node-addr 192.168.1.11:9848 --join-addr 192.168.1.10:9848
```

## 命令行参数

| 参数 | 说明 |
|------|------|
| `--standalone` | 单机模式 |
| `--cluster` | 集群模式 |
| `--version <版本>` | rnacos 版本（默认 v0.8.3）|
| `--http-port <端口>` | HTTP/API 端口（默认 8848）|
| `--grpc-port <端口>` | gRPC 端口（默认 HTTP端口+1000）|
| `--console-port <端口>` | 控制台端口（默认 10848）|
| `--node-id <id>` | 集群节点 ID，整数且每节点唯一（集群必填）|
| `--node-addr <ip:port>` | 本节点 Raft 地址 ip:gRPC端口（集群必填）|
| `--auto-init` | 作为集群首节点初始化（仅首节点）|
| `--join-addr <ip:port>` | 加入已有集群，填首节点 Raft 地址 |
| `--target <target>` | 二进制目标平台（默认 x86_64 musl/msvc）|
| `-h, --help` | 帮助 |

## 部署后信息

- 控制台地址：`http://<IP>:10848/rnacos/`
- 默认账号：`admin / admin`（**首次登录请立即修改密码**）
- 配置文件：安装目录下的 `rnacos.env`

### 服务管理（Linux / systemd）

```bash
systemctl start rnacos      # 启动
systemctl stop rnacos       # 停止
systemctl status rnacos     # 状态
journalctl -u rnacos -f     # 日志
```

### 服务管理（Windows）

```bat
REM 启动
cd /d C:\rnacos && rnacos.exe -e rnacos.env
```

> Windows 下如需开机自启，可借助 [nssm](https://nssm.cc/) 等工具将 `rnacos.exe` 注册为系统服务。

## 集群部署要点

1. **先启动首节点**（带 `--auto-init`），完成 Raft 初始化。
2. 再依次启动其他节点（带 `--join-addr` 指向首节点的 gRPC 地址）加入集群。
3. 每个节点的 `--node-id` 必须唯一。
4. 确保各节点之间 **gRPC 端口（默认 9848）** 网络互通（Raft 通信走 gRPC 端口）。
5. 集群无需外部数据库，数据通过 Raft 在节点间复制。

## 卸载

```bash
# Linux
bash uninstall_rnacos.sh           # 交互确认（保留数据）
bash uninstall_rnacos.sh -y        # 直接卸载（保留数据）
bash uninstall_rnacos.sh -y --purge  # 卸载并删除数据目录
```

```bat
REM Windows
uninstall_rnacos.bat
uninstall_rnacos.bat -y
uninstall_rnacos.bat -y --purge
```

## 默认安装路径

| 平台 | 安装目录 | 数据目录 |
|------|---------|---------|
| Linux | `/usr/local/rnacos` | `/var/lib/rnacos` |
| Windows | `C:\rnacos` | `C:\rnacos\data` |

## Nacos vs rnacos 如何选择

| 维度 | Nacos（Java） | rnacos（Rust） |
|------|--------------|----------------|
| 运行依赖 | 需 JDK 8+ | 无依赖，单文件 |
| 内存占用 | 较高（数百 MB+） | 极低（数十 MB） |
| 存储 | Derby / MySQL | 内嵌 sled，集群用 Raft |
| 集群 | 依赖 MySQL 共享存储 | Raft 自包含，无需外部 DB |
| 适用场景 | 已有 Nacos 生态、需丰富插件 | 轻量、低资源、边缘/中小规模 |
