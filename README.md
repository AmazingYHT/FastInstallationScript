# FastInstallationScript

一键安装自用脚本整理

## 目录结构

```
FastInstallationScript/
├── docker安装脚本/
│   └── docker-28.3.3_install/
│       ├── installDocker.sh           # Docker安装脚本
│       ├── uninstallDocker.sh         # Docker卸载脚本
│       ├── conf/
│       │   ├── docker.service         # systemd服务配置
│       │   └── docker-compose-linux-x86_64-2.39.2
│       └── package/
│           └── docker-28.3.3.tgz      # Docker二进制包
└── postgresql安装脚本/
    ├── install_postgresql.sh          # PostgreSQL安装脚本
    ├── uninstall_postgresql.sh        # PostgreSQL卸载脚本
    └── postgresql_wal_archive_manager.sh  # WAL归档管理脚本
```

## Docker 安装脚本

### 功能特性

- 支持Docker 28.3.3版本
- 支持Docker Compose安装
- 自定义数据存储路径
- 内置多个国内镜像源加速

### 安装步骤

1. 进入安装目录：
```bash
cd docker安装脚本/docker-28.3.3_install/
```

2. 执行安装脚本：
```bash
bash installDocker.sh
```

3. 根据提示输入Docker数据存储路径（默认为 `/mnt/data/dockerWork`）

### 配置说明

安装后 `/etc/docker/daemon.json` 配置：

```json
{
    "data-root": "/mnt/data/dockerWork",
    "insecure-registries": [
        "registry.cn-shenzhen.aliyuncs.com"
    ],
    "registry-mirrors": [
        "https://docker.1panel.live",
        "https://hub-mirror.c.163.com",
        "https://docker.m.daocloud.io"
        // ... 更多镜像源
    ]
}
```

### 卸载Docker

```bash
cd docker安装脚本/docker-28.3.3_install/
bash uninstallDocker.sh
```

卸载脚本会：
- 停止所有容器
- 删除所有容器和镜像
- 删除Docker二进制文件
- 清理配置文件和数据目录

---

## PostgreSQL 安装脚本

### 功能特性

- 支持PostgreSQL 18.1版本（可在线查询其他版本）
- 支持x86和ARM架构
- 自动配置systemd服务
- 可选插件安装（uuid-ossp、postgis-3等）
- 支持离线安装模式

### 安装步骤

1. 进入安装目录：
```bash
cd postgresql安装脚本/
```

2. 执行安装脚本：
```bash
bash install_postgresql.sh
```

3. 按照交互式提示完成配置：
   - 选择PostgreSQL版本（默认18.1）
   - 配置安装路径（默认`/mnt/data/postgresql`）
   - 设置端口（默认5432）
   - 设置数据库密码

### 默认配置

| 配置项 | 默认值 |
|--------|--------|
| 版本 | 18.1 |
| 安装目录 | /mnt/data/postgresql |
| 数据目录 | /mnt/data/postgresql/data |
| 端口 | 5432 |
| 用户 | postgres |
| 密码 | postgres |

### 服务管理

```bash
# 启动服务
systemctl start postgresql-18

# 停止服务
systemctl stop postgresql-18

# 查看状态
systemctl status postgresql-18

# 开机自启
systemctl enable postgresql-18
```

### 卸载PostgreSQL

```bash
cd postgresql安装脚本/
bash uninstall_postgresql.sh
```

卸载脚本支持：
- 自动搜索系统中的PostgreSQL安装
- 手动指定安装路径
- 干运行模式（预览删除内容）
- 完整清理服务、用户、配置和数据

---

## EasyVoice 有声助手

### 功能特性

- **文本清理与切分**: 清理小说文本中的多余符号，按章节自动切分
- **生成有声**: 调用 TTS API 为章节生成音频
- 图形界面操作，简单易用
- 支持自定义清理字符和语音参数

### 安装步骤

1. 确保已安装 Python 3.7+
2. 安装依赖：
```bash
pip install -r requirements.txt
```

### 启动程序

```bash
python clean_novel.py
```

### 功能说明

#### 文本清理与切分
- 清理小说文本中的多余符号和分隔符
- 按章节自动切分小说
- 自定义清理字符（特殊符号、广告词等）
- 自动检测章节标题格式

#### 生成有声
- 调用 TTS API 为章节生成音频
- 支持文件夹批量处理或多选文件处理
- 可调节语速、音调、音量参数
- 支持暂停/继续/停止控制

### Docker 部署 TTS 服务

使用提供的 docker-compose.yml 快速启动 TTS 服务：

```bash
cd EasyVoice有声助手/
docker-compose up -d
```

服务将在 `http://localhost:3110` 启动。

详细使用说明请查看 [clean_novel操作指南.md](EasyVoice有声助手/clean_novel操作指南.md)

---

## PostgreSQL WAL归档管理脚本

### 功能特性

- 支持多种清理模式（手动、自动、定时、智能）
- 完整的WAL归档配置
- 归档状态查看
- 归档功能测试

### 使用模式

#### 1. 完整配置模式 (setup)
```bash
bash postgresql_wal_archive_manager.sh setup
```
交互式配置WAL归档，包括：
- WAL参数调优
- 创建归档目录
- 配置清理任务

#### 2. 手动清理模式 (manual)
```bash
bash postgresql_wal_archive_manager.sh manual -d 15
```
手动清理15天前的归档文件

#### 3. 自动清理模式 (auto)
```bash
bash postgresql_wal_archive_manager.sh auto
```
使用 `archive_cleanup_command` 实现自动清理

#### 4. 定时清理模式 (cron)
```bash
bash postgresql_wal_archive_manager.sh cron -d 7
```
设置每周定时清理7天前的归档

#### 5. 智能清理模式 (smart)
```bash
bash postgresql_wal_archive_manager.sh smart
```
基于 `pg_controldata` 的智能清理

#### 6. 状态查看 (status)
```bash
bash postgresql_wal_archive_manager.sh status
```
查看当前归档配置和状态

#### 7. 测试模式 (test)
```bash
bash postgresql_wal_archive_manager.sh test
```
测试WAL归档功能是否正常

### 命令行参数

```
-h, --help              显示帮助信息
-v, --version           显示版本信息
-d, --days DAYS         设置归档保留天数（默认: 7）
-u, --user USER         设置PostgreSQL用户（默认: postgres）
-p, --path PATH         设置PostgreSQL安装路径
-a, --archive PATH      设置归档目录路径
-D, --data PATH         设置数据目录路径
-f, --force             强制执行，跳过确认
-q, --quiet             静默模式，减少输出
```

### WAL参数配置

脚本可配置以下WAL参数：
- `max_wal_size` - WAL最大大小（默认: 1GB）
- `min_wal_size` - WAL最小大小（默认: 80MB）
- `checkpoint_completion_target` - 检查点完成目标（默认: 0.9）
- `wal_buffers` - WAL缓冲区大小（默认: 16MB）
- `wal_writer_delay` - WAL写入延迟（默认: 200ms）
- `commit_delay` - 提交延迟（默认: 0）
- `commit_siblings` - 提交兄弟数（默认: 5）

---

## 系统要求

- 操作系统：CentOS 7+ / Rocky Linux 8+ / Ubuntu 18.04+
- 权限：root或sudo权限
- 架构：x86_64 或 ARM64

## 注意事项

1. 所有脚本均需要root权限执行
2. 安装前请确认端口未被占用
3. 建议在生产环境使用前先在测试环境验证
4. PostgreSQL卸载前请备份重要数据
5. Docker卸载会删除所有容器和镜像，请谨慎操作

## 许可证

MIT License
