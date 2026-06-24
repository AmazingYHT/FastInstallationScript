# Nacos 自动化部署脚本使用手册

支持 **Linux** 和 **Windows** 双平台，支持 **单机/集群** 两种部署模式，支持 **Derby/MySQL** 存储库选择，Nacos 版本可配置。

> Nacos 是阿里巴巴开源的动态服务发现、配置管理和服务管理平台。本脚本基于官方发行包自动化部署。

## 脚本说明

| 脚本 | 平台 | 说明 |
|------|------|------|
| `install_nacos.sh` | Linux | 安装脚本，支持单机/集群、Derby/MySQL |
| `install_nacos.bat` | Windows | 安装脚本，功能与 Linux 对齐 |
| `uninstall_nacos.sh` | Linux | 卸载脚本（移除 systemd 服务和安装目录）|
| `uninstall_nacos.bat` | Windows | 卸载脚本 |

## 使用前提

- **Java 环境**：Nacos 依赖 JDK 8 及以上，请先安装并配置 `JAVA_HOME`。
- **MySQL（可选）**：选择 MySQL 存储库时，需提前准备好可访问的 MySQL 实例（8.0 推荐）。
- **集群模式**：建议 3 个及以上节点，且强烈建议使用 MySQL 存储库以保证数据一致性。

## 安装包获取（本地优先 + 自动下载）

脚本会优先使用 `package/` 目录下的安装包，缺失时自动从官方下载：

- Linux：`package/nacos-server-<版本>.tar.gz`
- Windows：`package\nacos-server-<版本>.zip`

如需离线部署，提前将对应安装包放入 `package/` 目录即可。官方下载地址：
`https://github.com/alibaba/nacos/releases`

## 快速开始（Linux）

```bash
# 交互式安装（引导选择模式与存储库）
bash install_nacos.sh

# 单机 + Derby（最简，适合测试）
bash install_nacos.sh --standalone --db derby

# 单机 + MySQL
bash install_nacos.sh --standalone --db mysql \
  --mysql-host 127.0.0.1 --mysql-user nacos --mysql-password 123456

# 指定版本（默认 2.5.0）
bash install_nacos.sh --standalone --version 2.4.3

# 集群 + MySQL（在每个节点执行，保持相同 --nodes 与 MySQL 配置）
bash install_nacos.sh --cluster --db mysql \
  --nodes 192.168.1.10:8848,192.168.1.11:8848,192.168.1.12:8848 \
  --mysql-host 192.168.1.20 --mysql-password 123456
```

## 快速开始（Windows）

> 以管理员身份运行 CMD。

```bat
REM 交互式安装
install_nacos.bat

REM 单机 + Derby
install_nacos.bat --standalone --db derby

REM 单机 + MySQL
install_nacos.bat --standalone --db mysql --mysql-host 127.0.0.1 --mysql-password 123456

REM 集群 + MySQL
install_nacos.bat --cluster --db mysql --nodes 192.168.1.10:8848,192.168.1.11:8848 --mysql-host 192.168.1.20 --mysql-password 123456
```

## 命令行参数

| 参数 | 说明 |
|------|------|
| `--standalone` | 单机模式 |
| `--cluster` | 集群模式 |
| `--db derby\|mysql` | 存储库类型（默认 derby）|
| `--version <版本>` | Nacos 版本（默认 2.5.0）|
| `--port <端口>` | 服务端口（默认 8848）|
| `--nodes <ip:port,...>` | 集群节点列表（集群模式必填）|
| `--mysql-host/-port/-db/-user/-password` | MySQL 连接信息 |
| `-h, --help` | 帮助 |

## 存储库说明

- **Derby**：Nacos 内嵌数据库，零外部依赖，适合单机/测试环境。
- **MySQL**：外部数据库，集群模式推荐。
  - Linux 脚本会在检测到 `mysql` 客户端时，提示自动创建数据库并导入 `conf/mysql-schema.sql` 表结构。
  - Windows 脚本不自动初始化，需手动导入表结构（脚本会打印导入命令）。

手动导入示例：

```bash
mysql -h<host> -P3306 -unacos -p nacos < /usr/local/nacos/conf/mysql-schema.sql
```

## 部署后信息

- 控制台地址：`http://<IP>:8848/nacos`
- 默认账号：`nacos / nacos`（**首次登录请立即修改密码**）
- 脚本会自动开启鉴权（`nacos.core.auth.enabled=true`）并生成随机密钥。

### 服务管理（Linux / systemd）

```bash
systemctl start nacos      # 启动
systemctl stop nacos       # 停止
systemctl status nacos     # 状态
journalctl -u nacos -f     # 日志
```

### 服务管理（Windows）

```bat
C:\nacos\bin\startup.cmd -m standalone   REM 单机启动
C:\nacos\bin\startup.cmd                  REM 集群启动
C:\nacos\bin\shutdown.cmd                 REM 停止
```

## 卸载

```bash
# Linux
bash uninstall_nacos.sh          # 交互确认
bash uninstall_nacos.sh -y       # 直接卸载
```

```bat
REM Windows
uninstall_nacos.bat
uninstall_nacos.bat -y
```

> 卸载脚本不会删除外部 MySQL 中的数据，如需清理请手动操作。

## 集群部署要点

1. 在**每个节点**上执行安装脚本，`--nodes` 列表和 MySQL 配置必须完全一致。
2. 集群模式务必使用 **MySQL** 存储库。
3. 确保各节点之间 `8848`（主端口）及其衍生端口（gRPC 通常为主端口 +1000）网络互通。
4. 所有节点启动后，访问任一节点控制台即可。

## 默认安装路径

| 平台 | 安装目录 |
|------|---------|
| Linux | `/usr/local/nacos` |
| Windows | `C:\nacos` |
