# MySQL 自动化脚本使用手册

> 一套完整的 MySQL 安装、配置和卸载自动化脚本

---

## 📋 目录

1. [脚本概览](#脚本概览)
2. [快速开始](#快速开始)
3. [离线包下载资源](#离线包下载资源)
4. [安装脚本详解](#安装脚本详解)
5. [卸载脚本](#卸载脚本)
6. [常见问题](#常见问题)

---

## 📌 脚本概览

### 脚本列表

| 脚本名称 | 功能说明 | 权限要求 |
|---------|---------|---------|
| `install_mysql.sh` | MySQL 安装脚本（交互 + 无人值守；含离线包查找） | root |
| `setup_mysql_replication.sh` | 主从复制：本机配置 / SSH远程安装 / 一键部署 | root |
| `uninstall_mysql.sh` | MySQL 完全卸载脚本 | root |

### 支持的特性

- **推荐版本**：MySQL 8.4.9 LTS（新系统推荐，支持到2032年）
- **兼容版本**：CentOS 7 / glibc 2.17 自动适配 MySQL 8.4.4 glibc2.17 包
- **多版本支持**：MySQL 8.0.x ~ 8.4.x LTS
- **多架构支持**：x86_64、ARM64
- **双安装模式**：在线安装、离线安装
- **无人值守安装**：`--batch` 参数，供主从脚本 SSH 远程调用
- **主从复制编排**：一键本机主库 + SSH 远程安装/配置从库（GTID）
- **二进制包安装**：无需编译，解压即用
- **安装前环境检测**：自动检测 glibc、systemd、包管理器、SELinux 等
- **智能包选择**：根据系统 glibc 自动选择可运行的 MySQL 二进制包
- **下载重试机制**：IPv4 下载、断点续传、低速超时、自动重试
- **自动配置**：systemd 服务、环境变量、防火墙
- **运行文件归位**：mysql.sock、mysql.pid、mysqlx.sock 位于安装目录
- **远程访问**：Navicat 连接配置
- **bash兼容性检查**：避免Ubuntu上用sh执行报错

---

## 🚀 快速开始

### 一键安装 MySQL

```bash
# 赋予执行权限
chmod +x install_mysql.sh setup_mysql_replication.sh

# 运行安装脚本
sudo ./install_mysql.sh
```

### 一键主从部署（本机主库 + SSH 远程从库）

```bash
sudo ./setup_mysql_replication.sh
# 选择 1. 一键主从部署
```

流程：
1. 本机无人值守安装 MySQL 并配置为主库（GTID）
2. 自动保留 `tar.xz` 安装包
3. `scp` 安装包 + `install_mysql.sh` 到各从库
4. SSH 在从库执行 `install_mysql.sh --batch --offline ...`
5. 自动写入主从参数并 `START REPLICA`
6. 校验 IO/SQL 线程

命令行入口：

```bash
sudo ./setup_mysql_replication.sh one      # 一键部署
sudo ./setup_mysql_replication.sh master   # 仅本机主库
sudo ./setup_mysql_replication.sh slave    # 仅本机从库
sudo ./setup_mysql_replication.sh remote   # 仅远程安装/配置从库
sudo ./setup_mysql_replication.sh status   # 查看复制状态（含远程）
sudo ./setup_mysql_replication.sh reset    # 重置本机复制
sudo ./setup_mysql_replication.sh help     # 帮助
```

依赖：
- 本机 root
- 可 SSH 登录从库 root（密钥，或密码 + `sshpass`）
- 从库具备 systemd

### 无人值守安装（供脚本/SSH 调用）

```bash
# 在线安装
bash install_mysql.sh --batch --version 8.4.9 \
  --home /mnt/data/mysql --port 3306 --password root --keep-tarball

# 离线安装（从库常用）
bash install_mysql.sh --batch --offline /tmp/mysql-8.4.9-linux-glibc2.28-x86_64.tar.xz \
  --home /mnt/data/mysql --port 3306 --password root --force-init-data
```

参数说明：
- `--batch`：跳过交互菜单
- `--keep-tarball`：保留 `/tmp` 下安装包，便于 scp 到从库
- `--force-init-data`：数据目录非空时清空并重新初始化（从库建议开启）
- 安装状态写入 `/etc/mysql_install_state.conf`

### 完全卸载

```bash
# 自动搜索并卸载
sudo ./uninstall_mysql.sh
```

---

## 📦 离线包下载资源

> 二进制包命名：`mysql-<版本>-linux-glibc<包版本>-<架构>.tar.xz`  
> 本地放置：任意路径均可，安装时指定；推荐 `/tmp/` 或 `/opt/packages/`  
> 脚本在线下载会优先走**中科大加速镜像**，失败后回退官网 CDN / 归档。

### 官方下载地址

| 类型 | 地址 |
|------|------|
| 当前版本 CDN（推荐） | `https://cdn.mysql.com/Downloads/MySQL-<主次版本>/` |
| 历史版本归档 | `https://cdn.mysql.com/archives/mysql-<主次版本>/` |
| 下载页（浏览器选包） | https://dev.mysql.com/downloads/mysql/ |
| 历史归档页 | https://downloads.mysql.com/archives/community/ |

**常用具体文件（已实测可下载）**

| 安装包 | 下载地址 |
|--------|----------|
| mysql-8.4.9-linux-glibc2.28-x86_64.tar.xz（新系统推荐） | https://cdn.mysql.com/Downloads/MySQL-8.4/mysql-8.4.9-linux-glibc2.28-x86_64.tar.xz |
| mysql-8.4.9-linux-glibc2.28-aarch64.tar.xz | https://cdn.mysql.com/Downloads/MySQL-8.4/mysql-8.4.9-linux-glibc2.28-aarch64.tar.xz |
| mysql-8.4.4-linux-glibc2.17-x86_64.tar.xz（CentOS 7） | https://cdn.mysql.com/archives/mysql-8.4/mysql-8.4.4-linux-glibc2.17-x86_64.tar.xz |
| mysql-8.0.40-linux-glibc2.17-x86_64.tar.xz（旧系统 8.0） | https://cdn.mysql.com/archives/mysql-8.0/mysql-8.0.40-linux-glibc2.17-x86_64.tar.xz |

### 国内加速镜像

| 镜像 | 基址 | 说明 |
|------|------|------|
| **中科大 USTC（推荐）** | `https://mirrors.ustc.edu.cn/mysql/downloads/` | 与官方同结构，已实测可下 8.4/8.0 包 |
| 清华 TUNA | 无独立 MySQL 二进制镜像 | 仅 yum/apt 仓库场景参考 |
| 腾讯云 | `https://mirrors.cloud.tencent.com/mysql/` | 仅 apt/yum，**无** tar.xz 离线包 |
| 华为云 | `https://mirrors.huaweicloud.com/mysql/` | 目录较旧，不保证含 8.4.9 |

**USTC 加速具体文件（与官网文件名一致）**

| 安装包 | 下载地址 |
|--------|----------|
| mysql-8.4.9-linux-glibc2.28-x86_64.tar.xz | https://mirrors.ustc.edu.cn/mysql/downloads/MySQL-8.4/mysql-8.4.9-linux-glibc2.28-x86_64.tar.xz |
| mysql-8.4.9-linux-glibc2.28-aarch64.tar.xz | https://mirrors.ustc.edu.cn/mysql/downloads/MySQL-8.4/mysql-8.4.9-linux-glibc2.28-aarch64.tar.xz |
| mysql-8.4.4-linux-glibc2.17-x86_64.tar.xz | https://mirrors.ustc.edu.cn/mysql/downloads/MySQL-8.4/mysql-8.4.4-linux-glibc2.17-x86_64.tar.xz |
| mysql-8.0.40-linux-glibc2.17-x86_64.tar.xz | https://mirrors.ustc.edu.cn/mysql/downloads/MySQL-8.0/mysql-8.0.40-linux-glibc2.17-x86_64.tar.xz |

### 路径规则（自行拼 URL 时）

```
官网 CDN:   https://cdn.mysql.com/Downloads/MySQL-{X.Y}/{文件名}
官网归档:   https://cdn.mysql.com/archives/mysql-{X.Y}/{文件名}
USTC 镜像:  https://mirrors.ustc.edu.cn/mysql/downloads/MySQL-{X.Y}/{文件名}

文件名:     mysql-{X.Y.Z}-linux-glibc{2.17|2.28}-{x86_64|aarch64}.tar.xz
```

示例：

```bash
# 在线机下载（推荐 USTC 加速）
mkdir -p /opt/packages && cd /opt/packages

# 新系统（Rocky/Alma 8+、Ubuntu 22+）
curl -L -o mysql-8.4.9-linux-glibc2.28-x86_64.tar.xz \
  https://mirrors.ustc.edu.cn/mysql/downloads/MySQL-8.4/mysql-8.4.9-linux-glibc2.28-x86_64.tar.xz

# CentOS 7
curl -L -o mysql-8.4.4-linux-glibc2.17-x86_64.tar.xz \
  https://mirrors.ustc.edu.cn/mysql/downloads/MySQL-8.4/mysql-8.4.4-linux-glibc2.17-x86_64.tar.xz

# 拷贝到离线服务器后安装
sudo ./install_mysql.sh
# 选择 2. 离线安装 → 输入 /opt/packages/mysql-8.4.9-linux-glibc2.28-x86_64.tar.xz
```

### 包选择速查

| 系统 | 架构 | 推荐安装包 |
|------|------|------------|
| Rocky/Alma/CentOS Stream 8+、Ubuntu 22+、Debian 12 | x86_64 | `mysql-8.4.9-linux-glibc2.28-x86_64.tar.xz` |
| 同上 | aarch64 | `mysql-8.4.9-linux-glibc2.28-aarch64.tar.xz` |
| CentOS 7 / glibc 2.17 | x86_64 | `mysql-8.4.4-linux-glibc2.17-x86_64.tar.xz` |

> 脚本在线下载顺序：**USTC 镜像 → 官网 CDN → 官网归档**；离线模式请手动下载后用 `--offline /path/to/xxx.tar.xz`。

---

## 📥 安装脚本详解

### install_mysql.sh

#### 功能特点

```
┌─────────────────────────────────────────────────────────────┐
│              MySQL 安装向导                                  │
├─────────────────────────────────────────────────────────────┤
│  ✅ 二进制包安装 - 从 MySQL 官网下载，无需编译               │
│  ✅ 推荐版本 - MySQL 8.4.9 LTS（新系统推荐）                 │
│  ✅ 兼容适配 - CentOS 7 自动使用 8.4.4 glibc2.17 包          │
│  ✅ 环境检测 - glibc、systemd、SELinux、包管理器检测         │
│  ✅ 下载重试机制 - IPv4、断点续传、低速超时                  │
│  ✅ 离线安装 - 使用本地 tar.xz 包                            │
│  ✅ 自动配置 - systemd 服务、环境变量                        │
│  ✅ 远程访问 - Navicat 连接配置                              │
│  ✅ 防火墙配置 - 自动配置防火墙规则                          │
│  ✅ bash兼容性 - 自动检查并提示                              │
└─────────────────────────────────────────────────────────────┘
```

#### 安装模式

##### 1️⃣ 在线安装模式

```bash
# 完整在线安装（交互式）
sudo ./install_mysql.sh

# 选择菜单：
# 1. 全新安装MySQL（在线下载二进制包）
# 2. 离线安装MySQL（使用本地tar.xz包）
# 3. 直接初始化数据库（MySQL已安装）
# q. 退出
```

**安装流程**：

```
选择版本 → 安装前环境检测 → 自动匹配二进制包 → 下载二进制包 → 安装依赖 → 解压安装 → 配置环境 → 初始化数据库 → 启动服务
```

##### 2️⃣ 离线安装模式

```bash
# 准备离线包（推荐从 USTC 加速镜像下载，见「离线包下载资源」）
# 新系统示例：mysql-8.4.9-linux-glibc2.28-x86_64.tar.xz
# CentOS 7 示例：mysql-8.4.4-linux-glibc2.17-x86_64.tar.xz
# 上传到服务器任意路径（如 /opt/packages/）

# 运行离线安装
sudo ./install_mysql.sh

# 选择 "2. 离线安装MySQL（使用本地tar.xz包）"
# 输入 tar.xz 包路径
```

#### 默认配置

```
配置项              默认值
─────────────────────────────────
MySQL 版本         8.4.9 LTS [新系统推荐]
用户/组            mysql / mysql
安装目录           /mnt/data/mysql/mysql-8.4.9
数据目录           /mnt/data/mysql/data
Socket文件         /mnt/data/mysql/mysql-8.4.9/mysql.sock
PID文件            /mnt/data/mysql/mysql-8.4.9/mysql.pid
MySQL X Socket     /mnt/data/mysql/mysql-8.4.9/mysqlx.sock
日志目录           /mnt/data/mysql/log
端口               3306
Root密码           root
```

**版本说明**：
- MySQL 8.4 LTS：标准支持到2029年，扩展支持到2032年，生产首选
- MySQL 8.0：2026年4月已停止维护，不推荐新装

#### 安装前环境检测与版本适配

脚本会在正式安装前自动检测：

- 操作系统发行版与版本
- CPU 架构：`x86_64` / `aarch64`
- glibc 版本
- systemd 是否可用
- 包管理器：`apt-get` / `dnf` / `yum`
- SELinux 状态（CentOS/RHEL/Rocky/Alma 系）

二进制包选择规则：

| 系统环境 | 自动选择/建议安装包 |
|---------|--------------------|
| Ubuntu 22/24、Debian 12、CentOS Stream 8/9、Rocky/AlmaLinux 8/9 | `mysql-8.4.9-linux-glibc2.28-x86_64.tar.xz` |
| CentOS 7 / glibc 2.17 / x86_64 | 自动切换为 `mysql-8.4.4-linux-glibc2.17-x86_64.tar.xz` |
| ARM64 / aarch64 | 通常需要 `glibc2.28` 包，不建议用于 CentOS 7 |

说明：CentOS 7 不是不能安装 MySQL 8.4，而是只能安装 `glibc2.17` 编译的二进制包。在线安装时，如果系统是 glibc 2.17 且选择了需要 glibc2.28 的 8.4 版本，脚本会自动切换到 MySQL 8.4.4 glibc2.17 包。离线安装不会自动切换包，只会按你提供的文件名解析并检测兼容性。

#### 常用安装示例

```bash
# 1. 使用默认配置快速安装（推荐）
sudo ./install_mysql.sh
# 选择: 1 → 1 (MySQL 8.4.9 LTS) → 1 (默认配置)

# 2. 自定义安装路径
sudo ./install_mysql.sh
# 选择: 1 → 1 → 2
# 自定义: /opt/mysql

# 3. 选择特定版本
sudo ./install_mysql.sh
# 选择: 1 → 2 (MySQL 8.4.5 LTS) 或其他版本

# 4. 离线安装
sudo ./install_mysql.sh
# 选择: 2 → 输入 tar.xz 包路径
```

---

## 🗑️ 卸载脚本

### uninstall_mysql.sh

#### 功能特点

```
┌────────────────────────────────────────────────────────────┐
│              MySQL 完全卸载脚本                             │
├────────────────────────────────────────────────────────────┤
│  ✅ 自动搜索 - 自动查找系统中的MySQL安装                    │
│  ✅ 智能清理 - 多种方法确保彻底删除                         │
│  ✅ 交互式确认 - 逐项确认删除内容                           │
│  ✅ 残留检查 - 最终验证确保完全清理                         │
└────────────────────────────────────────────────────────────┘
```

#### 卸载流程

```
搜索安装 → 停止服务 → 删除服务文件 → 删除文件目录 →
删除用户组 → 清理环境变量 → 清理配置文件 → 清理临时文件
```

#### 使用示例

##### 1️⃣ 自动搜索卸载（推荐）

```bash
sudo ./uninstall_mysql.sh
```

**交互流程**：
```
1. 脚本自动搜索MySQL安装
2. 确认卸载
3. 停止服务
4. 删除服务文件
5. 删除安装目录（可选）
6. 删除用户和组（可选）
7. 清理环境变量（可选）
8. 清理配置文件（可选）
9. 清理临时文件
```

#### 卸载内容清单

**将被删除**：
- ❌ MySQL 用户和组（可选）
- ❌ 安装目录（可选）
- ❌ 数据目录（包含所有数据！）
- ❌ systemd 服务文件
- ❌ 配置文件（可选）
- ❌ 环境变量配置（可选）
- ❌ 临时文件

#### 备份建议

```bash
# 卸载前务必备份数据！

# 1. 使用 mysqldump 备份
/path/to/bin/mysqldump -u root -p --all-databases > mysql_backup.sql

# 2. 备份数据目录
tar -czf mysql_data_backup.tar.gz /mnt/data/mysql/data

# 3. 备份配置文件
cp /etc/my.cnf ./my.cnf.bak
```

---

## 🔧 常见问题

**Q: Rocky/Alma/RHEL 9 安装时报 `cp: 无法创建普通文件 '/etc/init.d/mysql'`，服务启动失败？**

A: 新系统无 SysV `/etc/init.d`，旧逻辑会失败。脚本已改为**原生 systemd 直接启动 mysqld**（Type=notify，失败自动回退 mysqld_safe）。若手工修复：

```bash
cat > /etc/systemd/system/mysql.service << 'EOF'
[Unit]
Description=MySQL Server
After=network-online.target

[Service]
Type=notify
User=mysql
Group=mysql
PIDFile=/mnt/data/mysql/mysql-8.4.11/mysql.pid
ExecStart=/mnt/data/mysql/mysql-8.4.11/bin/mysqld --defaults-file=/etc/my.cnf
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl start mysql
systemctl enable mysql

# 用初始化临时密码改 root 密码（日志里的 temporary password）
mysql -u root -p'临时密码' --connect-expired-password \
  -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '你的密码'; FLUSH PRIVILEGES;"
```

**Q: Root 密码要多强？不够强怎么办？**

A: 对齐 MySQL 8 默认 **MEDIUM** 策略：

| 要求 | 说明 |
|------|------|
| 长度 | ≥ 8 |
| 大写 | 至少 1 个 A-Z |
| 小写 | 至少 1 个 a-z |
| 数字 | 至少 1 个 0-9 |
| 特殊字符 | 至少 1 个（如 `!@#%^&*`） |

示例：`MyPass@2026`  
不满足时脚本会**列出缺项**并提示重新输入（交互可反复改）。  
`--batch --password xxx` 若太弱，`ALTER USER` 失败会打印 `validate_password` 相关原因。  
确需弱密码（不推荐生产）：`ALLOW_WEAK_PASSWORD=1`。

**Q: 如何查找/选择离线安装包？**

A: 与 PostgreSQL 相同，逻辑在 `install_mysql.sh` 的 `find_offline_tarball`（离线安装流程内）：

```bash
sudo ./install_mysql.sh
# 选择 2. 离线安装MySQL（使用本地tar.xz包）
```

交互提示：

```text
查找MySQL离线安装包...

请输入MySQL tar.xz包的路径或目录:
  - 完整路径: /path/to/mysql-8.4.9-linux-glibc2.28-x86_64.tar.xz
  - 目录路径: /path/to/ (会自动查找目录中的tar.xz包)
  - 直接回车: 默认使用脚本所在目录 ...
b. 返回主菜单
```

无人值守：`--offline /path/to/mysql-xxx.tar.xz`。

**Q: 我输入了 Root 密码（或 `--password`），为什么登录还是要临时密码？**

A: 多半不是没读到输入，而是 **MySQL 8.x `validate_password` 策略拒绝了弱口令**（如 `root`、纯数字），`ALTER USER` 失败后仍停在临时密码。脚本已会自动：放宽 `validate_password.policy` → 失败则卸载 `component_validate_password` 再改密，并校验正式密码可登录。若仍失败：

```bash
mysql -u root -p'临时密码' --connect-expired-password
SET GLOBAL validate_password.policy=LOW;
ALTER USER 'root'@'localhost' IDENTIFIED BY '你的正式密码';
FLUSH PRIVILEGES;
```

生产环境建议使用符合策略的强密码，而不是卸掉校验组件。

**Q: 脚本会按系统版本区分服务创建方式吗？**

A: 会。`detect_sys_pkg` 识别 `OS_ID`/`OS_MAJOR`：
- **EL7 及更老**（或无 systemd）：写 `/etc/init.d/mysql`（SysV），必要时 `mkdir -p /etc/init.d`
- **EL8/EL9、Ubuntu 22+ 等**：原生 `mysql.service` 直接 `ExecStart=mysqld`，`Type=notify` 失败再回退 `mysqld_safe`

**Q: 提示 `未找到匹配的参数: ncurses-compat-libs` 要紧吗？**

A: 一般**不影响**。el9 可用 `ncurses-libs`；确需 compat 时启用 CRB：`dnf config-manager --set-enabled crb && dnf install -y ncurses-compat-libs`。

**Q: error.log 里只有 initialization 日志，没有启动失败原因？**

A: 初始化成功后启动失败要看 systemd：`journalctl -u mysql -n 50 --no-pager`。

### Q1: 安装时网络连接失败怎么办？

**解决方案**：

1. **使用代理**：
   ```bash
   export http_proxy=http://proxy_host:port
   export https_proxy=http://proxy_host:port
   sudo ./install_mysql.sh
   ```

2. **使用离线安装**：
   ```bash
   # 提前从官网下载二进制包
   # https://downloads.mysql.com/archives/community/
   # 新系统选择 MySQL 8.4.9 LTS glibc2.28 包
   # CentOS 7 选择 MySQL 8.4.4 glibc2.17 x86_64 包

   # 上传后运行离线安装
   sudo ./install_mysql.sh
   # 选择: 2. 离线安装MySQL（使用本地tar.xz包）
   ```

3. **手动下载**：
   ```bash
   # 访问 MySQL 官网归档下载
   # https://downloads.mysql.com/archives/community/
   # 选择对应版本和架构的二进制包
   ```

---

### Q2: 如何修改默认安装路径？

**方法一**：安装时选择自定义
```bash
sudo ./install_mysql.sh
# 选择: 1 → 1 → 2
# 输入自定义路径
```

**方法二**：使用环境变量
```bash
export MYSQL_HOME=/custom/path
sudo ./install_mysql.sh
```

---

### Q3: 服务启动失败怎么办？

**排查步骤**：

```bash
# 1. 查看服务状态
systemctl status mysql

# 2. 查看详细日志
journalctl -u mysql -n 50

# 3. 检查数据目录权限
ls -la /mnt/data/mysql/data

# 4. 查看错误日志
cat /mnt/data/mysql/log/error.log

# 5. 手动启动查看错误
sudo -u mysql /mnt/data/mysql/mysql-8.4.9/bin/mysqld_safe \
  --defaults-file=/etc/my.cnf &
```

---

### Q4: 如何开启远程连接？

**方法一**：安装时自动配置

安装脚本会自动配置远程访问，包括：
- 创建 root@% 用户
- 授予所有权限
- 配置防火墙规则

**方法二**：手动配置

```bash
# 1. 登录MySQL
/path/to/bin/mysql -u root -p

# 2. 创建远程用户
CREATE USER 'root'@'%' IDENTIFIED BY 'your_password';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EXIT;

# 3. 开放防火墙端口
firewall-cmd --permanent --add-port=3306/tcp
firewall-cmd --reload
```

---

### Q5: 忘记Root密码怎么办？

**重置密码步骤**：

```bash
# 1. 停止MySQL服务
systemctl stop mysql

# 2. 以安全模式启动MySQL
/path/to/bin/mysqld_safe \
  --defaults-file=/etc/my.cnf \
  --skip-grant-tables \
  --skip-networking \
  >/mnt/data/mysql/log/mysql_skip_grant.log 2>&1 &

# 3. 连接MySQL（无需密码）
/path/to/bin/mysql --socket=/path/to/mysql.sock -u root

# 4. 修改密码
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED BY 'new_password';
FLUSH PRIVILEGES;
EXIT;

# 5. 重启MySQL服务
systemctl restart mysql
```

---

### Q6: CentOS 7 为什么不能安装 MySQL 8.4.9？

CentOS 7 默认 glibc 是 `2.17`，而 MySQL 8.4.9 当前二进制包通常是 `glibc2.28`，直接运行会失败。

**解决方案**：

1. **在线安装**：脚本会自动切换到 CentOS 7 可用的 MySQL 8.4.4 glibc2.17 x86_64 包。
2. **离线安装**：请准备以下类型的包：
   ```bash
   mysql-8.4.4-linux-glibc2.17-x86_64.tar.xz
   ```
3. **不建议做法**：不要在 CentOS 7 上强行升级系统 glibc，容易影响系统稳定性。

可用以下命令查看当前 glibc：

```bash
ldd --version
```

---

### Q7: 如何查看MySQL版本？

```bash
# 方法1: 使用mysql命令
/path/to/bin/mysql --version

# 方法2: 登录MySQL后查询
/path/to/bin/mysql -u root -p -e "SELECT version();"

# 方法3: 查看服务状态
systemctl status mysql
```

---

### Q8: 如何修改MySQL端口？

**修改配置文件**：

```bash
# 1. 编辑配置文件
vi /etc/my.cnf

# 2. 修改端口
port = 3307

# 3. 重启服务
systemctl restart mysql

# 4. 开放新端口
firewall-cmd --permanent --add-port=3307/tcp
firewall-cmd --reload
```

---

### Q9: 如何优化MySQL性能？

**配置文件优化**：

```bash
# 编辑配置文件
vi /etc/my.cnf

# 根据服务器配置调整以下参数：
[mysqld]
# 缓冲区大小（建议为物理内存的50-80%）
innodb_buffer_pool_size = 4G

# 最大连接数
max_connections = 1000

# 日志文件大小
innodb_log_file_size = 256M
```

---

### Q10: 卸载后残留文件无法删除？

**强制删除方法**：

```bash
# 修改权限后删除
sudo chown -R root:root /path/to/dir
sudo chmod -R 777 /path/to/dir
sudo rm -rf /path/to/dir

# 或使用 --no-preserve-root
sudo rm -rf --no-preserve-root /path/to/dir
```

---

## 📝 附录

### 目录结构

```
/mnt/data/mysql/
├── mysql-8.4.9/              # 安装目录
│   ├── bin/                  # 可执行文件
│   ├── lib/                  # 库文件
│   ├── share/                # 共享文件
│   ├── include/              # 头文件
│   ├── support-files/        # 服务脚本
│   ├── mysql.sock            # MySQL Socket文件
│   ├── mysql.pid             # MySQL PID文件
│   └── mysqlx.sock           # MySQL X Plugin Socket文件
├── data/                     # 数据目录
│   ├── ibdata1               # InnoDB数据文件
│   ├── mysql/                # 系统数据库
│   ├── performance_schema/   # 性能数据库
│   └── sys/                  # 系统数据库
└── log/                      # 日志目录
    ├── error.log             # 错误日志
    ├── slow.log              # 慢查询日志
    └── mysql_skip_grant.log  # 安全模式改密日志

/etc/
├── my.cnf                    # MySQL主配置文件
├── systemd/system/
│   └── mysql.service         # systemd服务文件（原生 ExecStart=mysqld）
└── init.d/
    └── mysql                 # SysV 兼容脚本（仅当系统存在 /etc/init.d 时写入）
```

### 服务管理

> ✅ 脚本安装完成后已自动执行 `systemctl start mysql` + `systemctl enable mysql`，**默认已开机自启**（非 systemd 的老系统如 CentOS 6 使用 `chkconfig mysql on` 注册）。

```bash
# 启动服务
systemctl start mysql

# 停止服务
systemctl stop mysql

# 重启服务
systemctl restart mysql

# 查看状态
systemctl status mysql

# 开机自启（安装时已自动执行，仅在被禁用后手动恢复时需要）
systemctl enable mysql

# 禁用自启
systemctl disable mysql

# 验证是否已开机自启（输出 enabled 即已注册开机自启）
systemctl is-enabled mysql

# 验证当前是否正在运行（输出 active 即运行中）
systemctl is-active mysql
```

```bash
# 重启服务器后复查自启是否生效
systemctl list-unit-files --type=service | grep '^mysql'
# 或重启后直接查看运行状态
systemctl status mysql
```

### 数据库连接

```bash
# 命令行连接
/path/to/bin/mysql -u root -p

# 连接指定数据库
/path/to/bin/mysql -u root -p -D mydb

# 执行SQL命令
/path/to/bin/mysql -u root -p -e "SELECT version();"

# 指定端口连接
/path/to/bin/mysql -u root -p -P 3307

# 指定主机连接
/path/to/bin/mysql -u root -p -h 192.168.1.100
```

### SQL常用命令

```sql
-- 显示所有数据库
SHOW DATABASES;

-- 切换数据库
USE database_name;

-- 显示所有表
SHOW TABLES;

-- 查看表结构
DESC table_name;

-- 显示表的创建语句
SHOW CREATE TABLE table_name;

-- 显示当前用户
SELECT USER();

-- 显示MySQL版本
SELECT VERSION();

-- 退出
EXIT;
```

---

## 📞 技术支持

如有问题，请检查：
1. 系统日志：`journalctl -u mysql -n 100`
2. MySQL 错误日志：`/mnt/data/mysql/log/error.log`
3. MySQL 慢查询日志：`/mnt/data/mysql/log/slow.log`

---

## 📌 版本更新信息

### v1.0.0 (最新)

#### 新增功能

- **在线安装**
  - 支持从 USTC 加速镜像、MySQL 官方 CDN 和归档地址下载二进制包
  - 根据系统 glibc 自动选择兼容二进制包
  - CentOS 7 / glibc 2.17 自动适配 MySQL 8.4.4 glibc2.17 x86_64 包
  - 下载失败自动重试，支持 IPv4、断点续传、低速超时
  - 新增文件完整性验证功能

- **离线安装**
  - 支持使用本地 tar.xz 二进制包安装
  - 自动从文件名解析 MySQL 版本和 glibc 包类型
  - 自动检测 tar.xz 包完整性

- **安装配置**
  - 自动检测系统架构（x86_64/ARM64）
  - 自动检测 glibc、systemd、包管理器、SELinux
  - 自动安装依赖包
  - 自动创建MySQL用户和目录
  - 支持自定义安装路径、端口、密码等
  - mysql.sock、mysql.pid、mysqlx.sock 统一放在安装目录
  - 自动初始化数据库
  - 自动创建systemd服务
  - 自动配置环境变量
  - 自动配置防火墙规则
  - 自动配置远程访问

- **卸载功能**
  - 自动搜索MySQL安装
  - 停止服务
  - 删除服务文件
  - 删除安装目录（可选）
  - 删除用户和组（可选）
  - 清理环境变量（可选）
  - 清理配置文件（可选）
  - 清理临时文件

- **临时文件清理**
  - 安装完成后自动清理解压目录和临时文件
  - 下载中的二进制包支持断点续传，失败时不会删除半包
