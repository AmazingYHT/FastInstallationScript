# PostgreSQL 自动化脚本使用手册

> 一套完整的 PostgreSQL 安装、配置、WAL归档管理和卸载自动化脚本

---

## 📋 目录

1. [脚本概览](#脚本概览)
2. [快速开始](#快速开始)
3. [安装脚本详解](#安装脚本详解)
4. [WAL归档管理](#wal归档管理)
5. [卸载脚本](#卸载脚本)
6. [常见问题](#常见问题)

---

## 📌 脚本概览

### 脚本列表

| 脚本名称 | 功能说明 | 权限要求 |
|---------|---------|---------|
| `install_postgresql.sh` | PostgreSQL 安装脚本 | root |
| `postgresql_wal_archive_manager.sh` | WAL归档管理脚本 | root (setup/cron模式) |
| `uninstall_postgresql.sh` | PostgreSQL 完全卸载脚本 | root |

### 支持的特性

- **多版本支持**：PostgreSQL 12.x ~ 18.x
- **多架构支持**：x86_64、ARM64
- **双安装模式**：在线安装、离线安装
- **插件系统**：openssl、perl、python、tcl、uuid、xml、icu、ldap、pam、systemd
- **WAL归档**：完整归档配置、自动清理、定时清理、智能清理

---

## 🚀 快速开始

### 一键安装 PostgreSQL

```bash
# 赋予执行权限
chmod +x install_postgresql.sh

# 运行安装脚本
sudo ./install_postgresql.sh
```

### 配置 WAL 归档

```bash
# 完整配置WAL归档（推荐）
sudo ./postgresql_wal_archive_manager.sh setup

# 快速配置定时清理
sudo ./postgresql_wal_archive_manager.sh cron -d 7
```

### 完全卸载

```bash
# 自动搜索并卸载
sudo ./uninstall_postgresql.sh

# 跳过确认直接卸载
sudo ./uninstall_postgresql.sh -y
```

---

## 📥 安装脚本详解

### install_postgresql.sh

#### 功能特点

```
┌─────────────────────────────────────────────────────────────┐
│              PostgreSQL 安装向导                             │
├─────────────────────────────────────────────────────────────┤
│  ✅ 在线下载安装 - 从 PostgreSQL FTP 下载源码               │
│  ✅ 离线安装 - 使用本地 tar.gz 包                            │
│  ✅ 插件选择 - 10+ 可选插件                                  │
│  ✅ 自动配置 - systemd 服务、环境变量                        │
│  ✅ 远程访问 - Navicat 连接配置                              │
└─────────────────────────────────────────────────────────────┘
```

#### 安装模式

##### 1️⃣ 在线安装模式

```bash
# 完整在线安装（交互式）
sudo ./install_postgresql.sh

# 选择菜单：
# 1. 完整在线安装
# 2. 直接初始化数据库（已编译）
# 3. 安装 contrib 扩展
# 4. 离线安装
```

**安装流程**：

```
选择版本 → 下载源码 → 安装依赖 → 编译安装 → 初始化数据库 → 启动服务
```

##### 2️⃣ 离线安装模式

```bash
# 准备离线包
# 1. 提前下载 postgresql-18.1.tar.gz
# 2. 上传到服务器

# 运行离线安装
sudo ./install_postgresql.sh

# 选择 "4. 离线安装"
# 输入 tar.gz 包路径
```

#### 可选插件

| 插件 | 说明 | 依赖 |
|-----|------|------|
| openssl | SSL/TLS 加密 | openssl-devel |
| perl | Perl 存储过程 | perl-devel |
| python | Python 存储过程 | python3-devel |
| tcl | Tcl 存储过程 | tcl-devel |
| uuid | UUID 生成 | libossp-uuid-devel |
| xml | XML 数据类型 | libxml2-devel |
| icu | 国际化支持 | libicu-devel |
| ldap | LDAP 认证 | openldap-devel |
| pam | PAM 认证 | pam-devel |
| systemd | systemd 集成 | systemd-devel |

#### 默认配置

```
配置项              默认值
─────────────────────────────────
PostgreSQL 版本    18.1
用户/组            postgres / postgres
安装目录           /mnt/data/postgresql/postgresql-18.1
数据目录           /mnt/data/postgresql/data
端口               5432
密码               postgres
```

#### 常用安装示例

```bash
# 1. 使用默认配置快速安装
sudo ./install_postgresql.sh
# 选择: 1 → 1 → 1

# 2. 自定义安装路径
sudo ./install_postgresql.sh
# 选择: 1 → 1 → 2
# 自定义: /opt/pgsql

# 3. 选择特定版本
sudo ./install_postgresql.sh
# 选择: 2 → 8 (查询18.x版本)

# 4. 离线安装
sudo ./install_postgresql.sh
# 选择: 4 → 输入包路径
```

---

## 🗄️ WAL归档管理

### postgresql_wal_archive_manager.sh

#### 工作模式

```
┌────────────────────────────────────────────────────────────┐
│           WAL 归档管理脚本 v2.0.0                          │
├────────────────────────────────────────────────────────────┤
│  模式          功能说明                                    │
│  ───────────────────────────────────────────────────────  │
│  setup         完整WAL归档配置（推荐）                     │
│  manual        手动清理旧WAL文件                           │
│  auto          配置archive_cleanup_command自动清理         │
│  cron          设置cron定时清理任务                        │
│  smart         智能清理（基于pg_controldata）              │
│  status        显示当前归档状态                            │
│  test          测试归档配置                                │
└────────────────────────────────────────────────────────────┘
```

#### 模式详解

##### 1️⃣ setup 模式（推荐）

完整配置 WAL 归档，包含所有必要设置。

```bash
sudo ./postgresql_wal_archive_manager.sh setup
```

**配置内容**：
- ✅ 创建归档目录
- ✅ 配置 wal_level、archive_mode、archive_command
- ✅ 优化 WAL 参数
- ✅ 创建清理脚本
- ✅ 设置定时任务
- ✅ 重启服务并验证

##### 2️⃣ cron 模式

仅设置定时清理任务。

```bash
# 设置保留7天的归档
sudo ./postgresql_wal_archive_manager.sh cron -d 7

# 设置保留15天的归档
sudo ./postgresql_wal_archive_manager.sh cron -d 15
```

**定时任务说明**：

```bash
# cron 任务被安装到 postgres 用户的 crontab
# 每周日凌晨 2 点执行

# 查看任务（注意用户）
sudo -u postgres crontab -l

# 任务内容：
0 2 * * 0 LC_ALL=C LANG=C /path/to/wal_cleanup.sh >> /path/to/wal_cleanup.log 2>&1
```

> ⚠️ **重要**：cron 任务安装在 postgres 用户下，不是 root 用户！

##### 3️⃣ manual 模式

手动触发清理。

```bash
# 清理7天前的归档
sudo ./postgresql_wal_archive_manager.sh manual -d 7

# 强制清理（不确认）
sudo ./postgresql_wal_archive_manager.sh manual -d 7 -f
```

##### 4️⃣ status 模式

查看当前归档状态。

```bash
sudo ./postgresql_wal_archive_manager.sh status
```

**输出示例**：

```
=== PostgreSQL WAL归档状态 ===
PostgreSQL服务状态: 运行中
WAL级别: replica
归档模式: on
归档命令: cp %p /mnt/data/postgresql/archive/%f
清理命令: /mnt/data/postgresql/postgresql-18.1/bin/pg_archivecleanup
归档目录: /mnt/data/postgresql/archive
归档文件数量: 152
归档目录大小: 2.3G
定时清理任务: 0 2 * * 0 /path/to/wal_cleanup.sh
```

##### 5️⃣ test 模式

测试归档配置是否正确。

```bash
sudo ./postgresql_wal_archive_manager.sh test
```

#### WAL 参数说明

| 参数 | 默认值 | 说明 |
|-----|-------|------|
| wal_level | replica | WAL 级别（minimal/replica/logical） |
| archive_mode | on | 归档模式 |
| archive_command | cp %p ... | 归档命令 |
| max_wal_size | 1GB | 最大 WAL 大小 |
| min_wal_size | 80MB | 最小 WAL 大小 |
| checkpoint_completion_target | 0.9 | 检查点完成目标 |
| wal_buffers | 16MB | WAL 缓冲区 |
| wal_writer_delay | 200ms | WAL 写入延迟 |

---

## 🗑️ 卸载脚本

### uninstall_postgresql.sh

#### 功能特点

```
┌────────────────────────────────────────────────────────────┐
│              PostgreSQL 完全卸载脚本                       │
├────────────────────────────────────────────────────────────┤
│  ✅ 自动搜索 - 自动查找系统中的PostgreSQL安装             │
│  ✅ 智能清理 - 多种方法确保彻底删除                        │
│  ✅ 干运行模式 --dry-run 预览删除内容                     │
│  ✅ 残留检查 - 最终验证确保完全清理                        │
└────────────────────────────────────────────────────────────┘
```

#### 卸载流程

```
搜索安装 → 停止服务 → 删除服务文件 → 删除文件目录 →
删除配置 → 删除用户组 → 系统清理 → 残留检查
```

#### 使用示例

##### 1️⃣ 自动搜索卸载（推荐）

```bash
sudo ./uninstall_postgresql.sh
```

**交互流程**：
```
1. 选择自动搜索
2. 脚本列出找到的安装
3. 选择要卸载的安装
4. 确认卸载
```

##### 2️⃣ 指定路径卸载

```bash
# 指定安装目录和数据目录
sudo ./uninstall_postgresql.sh \
  -i /mnt/data/postgresql/postgresql-18.1 \
  -d /mnt/data/postgresql/data
```

##### 3️⃣ 干运行模式（预览）

```bash
# 预览将要删除的内容，不实际删除
sudo ./uninstall_postgresql.sh --dry-run
```

##### 4️⃣ 跳过确认

```bash
# 跳过所有确认提示
sudo ./uninstall_postgresql.sh -y
```

#### 命令行参数

| 参数 | 说明 |
|-----|------|
| `-u, --user USER` | PostgreSQL 用户名 |
| `-i, --install-dir DIR` | 安装目录 |
| `-d, --data-dir DIR` | 数据目录 |
| `-h, --home DIR` | 主目录 |
| `-y, --yes` | 跳过确认提示 |
| `--dry-run` | 预览模式 |
| `--help` | 显示帮助 |

#### 卸载内容清单

**将被删除**：
- ❌ PostgreSQL 用户和组
- ❌ 安装目录
- ❌ 数据目录（包含所有数据！）
- ❌ systemd 服务文件
- ❌ 配置文件

**不会被删除**：
- ⚠️ 主目录（如 /mnt/data/postgresql）
  - 用于保留可能的配置文件
  - 需手动删除

#### 备份建议

```bash
# 卸载前务必备份数据！

# 1. 使用 pg_dumpall 备份
sudo -u postgres /path/to/bin/pg_dumpall > postgresql_backup.sql

# 2. 备份数据目录
tar -czf postgresql_data_backup.tar.gz /mnt/data/postgresql/data

# 3. 备份配置文件
cp /mnt/data/postgresql/data/postgresql.conf ./postgresql.conf.bak
```

---

## 🔧 常见问题

### Q1: 为什么 crontab -e 看不到定时任务？

**原因**：cron 任务被安装到 **postgres 用户**的 crontab，不是 root 用户。

**查看方法**：

```bash
# 查看postgres用户的cron任务
sudo -u postgres crontab -l

# 或切换到postgres用户
su - postgres -c "crontab -l"
```

---

### Q2: 安装时网络连接失败怎么办？

**解决方案**：

1. **使用代理**：
   ```bash
   export http_proxy=http://proxy_host:port
   export https_proxy=http://proxy_host:port
   sudo ./install_postgresql.sh
   ```

2. **使用离线安装**：
   ```bash
   # 提前下载源码包
   wget https://ftp.postgresql.org/pub/source/v18.1/postgresql-18.1.tar.gz
   
   # 上传后运行离线安装
   sudo ./install_postgresql.sh
   # 选择: 4. 离线安装
   ```

---

### Q3: 如何修改默认安装路径？

**方法一**：安装时选择自定义
```bash
sudo ./install_postgresql.sh
# 选择: 1 → 1 → 2
# 输入自定义路径
```

**方法二**：使用环境变量
```bash
export PG_HOME=/custom/path
sudo ./install_postgresql.sh
```

---

### Q4: 服务启动失败怎么办？

**排查步骤**：

```bash
# 1. 查看服务状态
systemctl status postgresql18

# 2. 查看详细日志
journalctl -u postgresql18 -n 50

# 3. 检查数据目录权限
ls -la /mnt/data/postgresql/data

# 4. 手动启动查看错误
sudo -u postgres /mnt/data/postgresql/postgresql-18.1/bin/pg_ctl \
  -D /mnt/data/postgresql/data start
```

---

### Q5: 如何开启远程连接？

**修改配置文件**：

```bash
# 1. 编辑 postgresql.conf
vi /mnt/data/postgresql/data/postgresql.conf

# 添加或修改：
listen_addresses = '*'
port = 5432

# 2. 编辑 pg_hba.conf
vi /mnt/data/postgresql/data/pg_hba.conf

# 添加允许连接的网段：
host    all             all             0.0.0.0/0               md5
# 或指定网段：
host    all             all             192.168.1.0/24          md5

# 3. 重启服务
systemctl restart postgresql18

# 4. 开放防火墙端口
firewall-cmd --permanent --add-port=5432/tcp
firewall-cmd --reload
```

---

### Q6: WAL 归档目录占用空间过大？

**解决方案**：

```bash
# 方法1: 手动清理
sudo ./postgresql_wal_archive_manager.sh manual -d 7

# 方法2: 调整保留天数
sudo ./postgresql_wal_archive_manager.sh cron -d 3

# 方法3: 手动删除特定文件
sudo -u postgres /mnt/data/postgresql/postgresql-18.1/bin/pg_archivecleanup \
  /mnt/data/postgresql/archive 000000010000000000000001
```

---

### Q7: 卸载后残留文件无法删除？

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
/mnt/data/postgresql/
├── postgresql-18.1/          # 安装目录
│   ├── bin/                  # 可执行文件
│   ├── lib/                  # 库文件
│   ├── share/                # 共享文件
│   └── include/              # 头文件
├── data/                     # 数据目录
│   ├── base/                 # 数据库文件
│   ├── global/               # 全局数据
│   ├── pg_wal/               # WAL文件
│   ├── postgresql.conf       # 主配置
│   ├── pg_hba.conf           # 认证配置
│   └── postmaster.opts       # 启动选项
├── archive/                  # WAL归档目录
├── cleanup_wal.sh            # WAL清理脚本
└── cleanup_wal.log           # 清理日志
```

### 服务管理

```bash
# 启动服务
systemctl start postgresql18

# 停止服务
systemctl stop postgresql18

# 重启服务
systemctl restart postgresql18

# 查看状态
systemctl status postgresql18

# 开机自启
systemctl enable postgresql18

# 禁用自启
systemctl disable postgresql18
```

### 数据库连接

```bash
# 命令行连接
psql -U postgres -h localhost -p 5432

# 连接指定数据库
psql -U postgres -d mydb -W

# 执行SQL命令
psql -U postgres -c "SELECT version();"
```

### SQL常用命令

```sql
-- 列出所有数据库
\l

-- 切换数据库
\c database_name

-- 列出所有表
\dt

-- 查看表结构
\d table_name

-- 退出
\q
```

---

## 📞 技术支持

如有问题，请检查：
1. 系统日志：`journalctl -u postgresql18 -n 100`
2. PostgreSQL 日志：`/mnt/data/postgresql/data/log/`
3. 清理日志：`/mnt/data/postgresql/cleanup_wal.log`

