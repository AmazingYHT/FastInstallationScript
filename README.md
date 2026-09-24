# FastInstallationScript

一键安装自用脚本整理。

## 目录结构

```
FastInstallationScript/
├── docker安装脚本/
│   └── docker-29.8.1_install/
│       ├── installDocker.sh           # Docker安装脚本
│       ├── uninstallDocker.sh         # Docker卸载脚本
│       ├── conf/                       # 配置文件（docker-compose、docker.service）
│       └── package/                    # Docker二进制包
├── mysql安装脚本/
│   ├── install_mysql.sh               # MySQL安装脚本（推荐8.4 LTS）
│   ├── setup_mysql_replication.sh     # MySQL主从复制配置
│   ├── uninstall_mysql.sh             # MySQL完全卸载脚本
│   └── MySQL自动化脚本使用手册.md      # 使用手册
├── postgresql安装脚本/
│   ├── install_postgresql.sh          # PostgreSQL安装脚本
│   ├── setup_pgsql_replication.sh     # PostgreSQL主从复制配置
│   ├── postgresql_wal_archive_manager.sh  # WAL归档管理脚本
│   ├── uninstall_postgresql.sh        # PostgreSQL卸载脚本
│   └── PostgreSQL自动化脚本使用手册.md  # 使用手册
├── redis安装脚本/
│   ├── install_redis.sh               # Redis安装脚本（单机/哨兵）
│   ├── setup_redis_sentinel.sh        # Sentinel哨兵模式配置
│   ├── uninstall_redis.sh             # Redis卸载脚本
│   └── Redis自动化脚本使用手册.md      # 使用手册
├── nacos系列安装脚本/
│   ├── lib_common.sh                  # Linux 通用函数库（日志/检测/依赖/校验）
│   ├── lib_common.bat                 # Windows 通用子程序库（架构检测/端口校验）
│   ├── nacos/
│   │   ├── install_nacos.sh           # Nacos安装脚本（Linux，单机/集群，Derby/MySQL）
│   │   ├── install_nacos.bat          # Nacos安装脚本（Windows）
│   │   ├── uninstall_nacos.sh         # Nacos卸载脚本（Linux）
│   │   ├── uninstall_nacos.bat        # Nacos卸载脚本（Windows）
│   │   └── Nacos自动化脚本使用手册.md  # 使用手册
│   └── rnacos/
│       ├── install_rnacos.sh          # rnacos安装脚本（Linux，单机/集群）
│       ├── install_rnacos.bat         # rnacos安装脚本（Windows）
│       ├── uninstall_rnacos.sh        # rnacos卸载脚本（Linux）
│       ├── uninstall_rnacos.bat       # rnacos卸载脚本（Windows）
│       └── rnacos自动化脚本使用手册.md # 使用手册
├── kafka安装脚本/
│   ├── install_kafka.sh               # Kafka安装脚本（Linux，KRaft，单机/集群）
│   ├── uninstall_kafka.sh             # Kafka卸载脚本（Linux）
│   └── Kafka自动化脚本使用手册.md      # 使用手册
└── EasyVoice有声助手/
    ├── clean_novel.py                 # 小说文本处理工具
    ├── docker-compose.yml             # TTS服务配置
    └── requirements.txt               # Python依赖
```

## 详细文档

| 项目 | 说明 | 文档 |
|------|------|------|
| Docker 安装脚本 | Docker 一键安装与卸载 | [Docker安装操作手册](docker安装脚本/Docker安装操作手册.md) |
| MySQL 安装脚本 | MySQL 8.4 LTS 自动化安装与卸载 | [MySQL自动化脚本使用手册](mysql安装脚本/MySQL自动化脚本使用手册.md) |
| PostgreSQL 安装脚本 | PostgreSQL 自动化安装与 WAL 归档管理 | [PostgreSQL自动化脚本使用手册](postgresql安装脚本/PostgreSQL自动化脚本使用手册.md) |
| Redis 安装脚本 | Redis 单机与哨兵高可用自动化安装 | [Redis自动化脚本使用手册](redis安装脚本/Redis自动化脚本使用手册.md) |
| Nacos 安装脚本 | Nacos 单机/集群自动化安装（Linux+Windows，Derby/MySQL） | [Nacos自动化脚本使用手册](nacos系列安装脚本/nacos/Nacos自动化脚本使用手册.md) |
| rnacos 安装脚本 | rnacos（Rust 版 Nacos）单机/集群自动化安装（Linux+Windows） | [rnacos自动化脚本使用手册](nacos系列安装脚本/rnacos/rnacos自动化脚本使用手册.md) |
| Kafka 安装脚本 | Kafka KRaft 模式单机/集群自动化安装（Linux，无需 Zookeeper） | [Kafka自动化脚本使用手册](kafka安装脚本/Kafka自动化脚本使用手册.md) |
| EasyVoice 有声助手 | 小说文本清理与 TTS 有声书生成 | [clean_novel操作指南](EasyVoice有声助手/clean_novel操作指南.md) |

## SELinux 说明（重要）

SELinux 是内核级强制访问控制（MAC）模块。在 **RHEL 系系统（CentOS、RHEL、Rocky Linux、AlmaLinux、Oracle Linux、Fedora）** 上默认开启（Enforcing）。当服务通过 systemd 启动、且数据/安装目录放在非标准路径（如 `/mnt/data`）时，可能被 SELinux 拦截，表现为服务启动失败、`systemctl` 长时间卡住等（MySQL、PostgreSQL、Redis、Kafka、Nacos、Docker 等都可能遇到）。

### 脚本已自动处理

- **本地安装脚本**（`install_*.sh`、`installDocker.sh`）：检测到 SELinux 为 Enforcing 时，会弹窗询问是否关闭（默认 Y），确认后执行 `setenforce 0`（立即生效）并修改 `/etc/selinux/config`（重启后永久生效）。
- **远端集群脚本**（`setup_*replication*.sh`、`setup_*cluster*.sh`、`setup_redis_sentinel.sh`）：本地只询问一次，确认后通过 SSH 在**每台远程节点**上幂等关闭，已关闭/无 SELinux 的节点自动跳过。

如选择不关闭，需自行用 `semanage fcontext` + `restorecon` 给自定义目录打标签，或在 systemd unit 中配置 `SELinuxContext`，否则服务可能无法正常启动。

### 手动操作命令

SELinux 仅存在于 RHEL 系系统，**各版本（CentOS 7/8/9、RHEL 7/8/9、Rocky/AlmaLinux 9、Fedora）命令完全一致**。

```bash
# 1. 查看当前状态（Enforcing=开启 / Permissive=只记录不拦截 / Disabled=关闭）
getenforce
sestatus                      # 查看更详细信息（含配置文件中的开机状态）

# 2. 临时关闭（立即生效，重启后恢复）
setenforce 0

# 3. 永久关闭（修改配置，需重启生效；也可与第 2 步同时执行免去本次重启）
sed -i 's/^SELINUX=enforcing/SELINUX=disabled/I' /etc/selinux/config

# 4. 重启后验证（应输出 Disabled）
getenforce
```

> Debian / Ubuntu / openSUSE 等系统**默认不使用 SELinux**，默认访问控制模块是 **AppArmor**，上述命令不适用，通常也无需处理。如需查看 AppArmor 状态：

```bash
# Debian / Ubuntu（AppArmor，仅在确有拦截问题时操作）
sudo aa-status                # 查看状态
sudo systemctl stop apparmor  # 临时停止（重启恢复，不建议随意关闭）
```