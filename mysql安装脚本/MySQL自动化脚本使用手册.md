# MySQL 自动化脚本使用手册

> 一套完整的 MySQL 安装、配置和卸载自动化脚本

---

## 📋 目录

1. [脚本概览](#脚本概览)
2. [快速开始](#快速开始)
3. [安装脚本详解](#安装脚本详解)
4. [卸载脚本](#卸载脚本)
5. [常见问题](#常见问题)

---

## 📌 脚本概览

### 脚本列表

| 脚本名称 | 功能说明 | 权限要求 |
|---------|---------|---------|
| `install_mysql.sh` | MySQL 安装脚本 | root |
| `uninstall_mysql.sh` | MySQL 完全卸载脚本 | root |

### 支持的特性

- **推荐版本**：MySQL 8.4.9 LTS（新系统推荐，支持到2032年）
- **兼容版本**：CentOS 7 / glibc 2.17 自动适配 MySQL 8.4.4 glibc2.17 包
- **多版本支持**：MySQL 8.0.x ~ 8.4.x LTS
- **多架构支持**：x86_64、ARM64
- **双安装模式**：在线安装、离线安装
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
chmod +x install_mysql.sh

# 运行安装脚本
sudo ./install_mysql.sh
```

### 完全卸载

```bash
# 自动搜索并卸载
sudo ./uninstall_mysql.sh
```

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
# 准备离线包
# 1. 从官网下载与系统 glibc/架构匹配的二进制包
#    新系统示例：mysql-8.4.9-linux-glibc2.28-x86_64.tar.xz
#    CentOS 7 示例：mysql-8.4.4-linux-glibc2.17-x86_64.tar.xz
# 2. 上传到服务器

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
│   └── mysql.service         # systemd服务文件
└── init.d/
    └── mysql                 # init.d服务脚本
```

### 服务管理

```bash
# 启动服务
systemctl start mysql

# 停止服务
systemctl stop mysql

# 重启服务
systemctl restart mysql

# 查看状态
systemctl status mysql

# 开机自启
systemctl enable mysql

# 禁用自启
systemctl disable mysql
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
  - 支持从 MySQL 官方 CDN 和归档地址下载二进制包
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
