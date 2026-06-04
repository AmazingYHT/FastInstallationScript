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

- **多版本支持**：MySQL 8.0.x ~ 9.0.x
- **多架构支持**：x86_64、ARM64
- **双安装模式**：在线安装、离线安装
- **镜像源选择**：官网镜像、腾讯云镜像、阿里云镜像（国内加速）
- **下载重试机制**：自动重试、文件完整性验证
- **自动配置**：systemd 服务、环境变量、防火墙
- **临时文件清理**：安装完成后自动清理临时文件
- **远程访问**：Navicat 连接配置

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
│  ✅ 在线下载安装 - 从 MySQL 官网下载源码                     │
│  ✅ 镜像源选择 - 官网镜像/腾讯云镜像/阿里云镜像（国内加速）  │
│  ✅ 下载重试机制 - 自动重试、文件完整性验证                  │
│  ✅ 离线安装 - 使用本地 tar.gz 包                            │
│  ✅ 自动配置 - systemd 服务、环境变量                        │
│  ✅ 临时文件清理 - 安装完成后自动清理                        │
│  ✅ 远程访问 - Navicat 连接配置                              │
│  ✅ 防火墙配置 - 自动配置防火墙规则                          │
└─────────────────────────────────────────────────────────────┘
```

#### 安装模式

##### 1️⃣ 在线安装模式

```bash
# 完整在线安装（交互式）
sudo ./install_mysql.sh

# 选择菜单：
# 1. 全新安装MySQL（在线）
# 2. 直接初始化数据库（需要MySQL已编译安装）
# 3. 离线安装MySQL（使用本地tar.gz包）
# m. 选择下载镜像源（当前: 官网镜像）
```

**安装流程**：

```
选择镜像源 → 选择版本 → 下载源码 → 安装依赖 → 编译安装 → 初始化数据库 → 启动服务
```

##### 1️⃣1️⃣ 镜像源选择

```bash
# 在主菜单选择 m 进入镜像源选择
sudo ./install_mysql.sh
# 选择: m

# 可选镜像源：
# 1. 官网镜像 (https://dev.mysql.com)
# 2. 腾讯云镜像 (https://mirrors.cloud.tencent.com) - 国内推荐
# 3. 阿里云镜像 (https://mirrors.aliyun.com) - 国内推荐
```

**镜像源说明**：

| 镜像源 | 地址 | 推荐场景 |
|-------|------|---------|
| 官网镜像 | https://dev.mysql.com | 国外服务器 |
| 腾讯云镜像 | https://mirrors.cloud.tencent.com | 国内服务器（推荐） |
| 阿里云镜像 | https://mirrors.aliyun.com | 国内服务器（推荐） |

> 💡 **提示**：首次安装时会提示选择镜像源，也可在配置确认阶段更换镜像源。

##### 2️⃣ 离线安装模式

```bash
# 准备离线包
# 1. 提前下载 mysql-8.0.35.tar.gz
# 2. 上传到服务器

# 运行离线安装
sudo ./install_mysql.sh

# 选择 "3. 离线安装"
# 输入 tar.gz 包路径
```

#### 默认配置

```
配置项              默认值
─────────────────────────────────
MySQL 版本         8.0.35
用户/组            mysql / mysql
安装目录           /mnt/data/mysql/mysql-8.0.35
数据目录           /mnt/data/mysql/data
临时目录           /mnt/data/mysql/tmp
日志目录           /mnt/data/mysql/log
端口               3306
密码               mysql
Root密码           root
```

#### 常用安装示例

```bash
# 1. 使用默认配置快速安装
sudo ./install_mysql.sh
# 选择: 1 → 1 → 1

# 2. 自定义安装路径
sudo ./install_mysql.sh
# 选择: 1 → 1 → 2
# 自定义: /opt/mysql

# 3. 选择特定版本
sudo ./install_mysql.sh
# 选择: 2 → 查询8.0.x版本

# 4. 离线安装
sudo ./install_mysql.sh
# 选择: 3 → 输入包路径
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
cp /mnt/data/mysql/mysql-8.0.35/etc/my.cnf ./my.cnf.bak
```

---

## 🔧 常见问题

### Q1: 安装时网络连接失败怎么办？

**解决方案**：

1. **切换镜像源**（推荐国内用户）：
   ```bash
   sudo ./install_mysql.sh
   # 在主菜单选择: m
   # 选择: 2. 腾讯云镜像 或 3. 阿里云镜像
   ```

2. **使用代理**：
   ```bash
   export http_proxy=http://proxy_host:port
   export https_proxy=http://proxy_host:port
   sudo ./install_mysql.sh
   ```

3. **使用离线安装**：
   ```bash
   # 提前下载源码包
   wget https://dev.mysql.com/get/Downloads/MySQL-8.0/mysql-8.0.35.tar.gz

   # 上传后运行离线安装
   sudo ./install_mysql.sh
   # 选择: 3. 离线安装
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
sudo -u mysql /mnt/data/mysql/mysql-8.0.35/bin/mysqld_safe \
  --defaults-file=/mnt/data/mysql/mysql-8.0.35/etc/my.cnf &
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
/path/to/bin/mysqld_safe --skip-grant-tables &

# 3. 连接MySQL（无需密码）
/path/to/bin/mysql -u root

# 4. 修改密码
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED BY 'new_password';
FLUSH PRIVILEGES;
EXIT;

# 5. 重启MySQL服务
systemctl restart mysql
```

---

### Q6: 编译安装失败怎么办？

**常见原因及解决方案**：

1. **缺少依赖包**：
   ```bash
   # CentOS/RHEL
   yum install -y cmake gcc gcc-c++ ncurses-devel bison openssl-devel
   
   # Ubuntu/Debian
   apt-get install -y build-essential cmake libncurses5-dev bison libssl-dev
   ```

2. **内存不足**：
   ```bash
   # 减少编译并行数
   # 在安装时选择 "单线程编译" 或 "自定义并行数"
   ```

3. **磁盘空间不足**：
   ```bash
   # 检查磁盘空间
   df -h
   
   # 清理不必要的文件
   yum clean all  # CentOS/RHEL
   apt-get clean  # Ubuntu/Debian
   ```

4. **查看编译日志**：
   ```bash
   cat /tmp/mysql_cmake.log
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
vi /mnt/data/mysql/mysql-8.0.35/etc/my.cnf

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
vi /mnt/data/mysql/mysql-8.0.35/etc/my.cnf

# 根据服务器配置调整以下参数：
[mysqld]
# 缓冲区大小（建议为物理内存的50-80%）
innodb_buffer_pool_size = 4G

# 最大连接数
max_connections = 1000

# 日志文件大小
innodb_log_file_size = 256M

# 查询缓存（MySQL 8.0已移除）
# query_cache_size = 0
# query_cache_type = 0
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
├── mysql-8.0.35/             # 安装目录
│   ├── bin/                  # 可执行文件
│   ├── lib/                  # 库文件
│   ├── share/                # 共享文件
│   ├── include/              # 头文件
│   ├── etc/                  # 配置文件
│   │   └── my.cnf            # 主配置文件
│   └── boost/                # Boost库
├── data/                     # 数据目录
│   ├── ibdata1               # InnoDB数据文件
│   ├── ib_logfile0           # InnoDB日志文件
│   ├── ib_logfile1           # InnoDB日志文件
│   ├── mysql/                # 系统数据库
│   ├── performance_schema/   # 性能数据库
│   ├── sys/                  # 系统数据库
│   └── *.err                 # 错误日志
├── tmp/                      # 临时目录
│   ├── mysql.sock            # Socket文件
│   └── mysql.pid             # PID文件
└── log/                      # 日志目录
    ├── error.log             # 错误日志
    └── slow.log              # 慢查询日志
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
  - 支持从MySQL官网下载源码
  - 支持腾讯云镜像和阿里云镜像（国内加速）
  - 下载失败自动重试机制（最多3次）
  - 下载超时时间延长至600秒
  - 新增文件完整性验证功能

- **离线安装**
  - 支持使用本地tar.gz包安装
  - 自动检测tar.gz包完整性

- **安装配置**
  - 自动检测系统架构（x86_64/ARM64）
  - 自动安装依赖包
  - 自动创建MySQL用户和目录
  - 支持自定义安装路径、端口、密码等
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
  - 安装完成后自动清理源码包、解压目录、配置日志等
