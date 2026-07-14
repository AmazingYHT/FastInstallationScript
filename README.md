# FastInstallationScript

一键安装自用脚本整理。

## 目录结构

```
FastInstallationScript/
├── docker安装脚本/
│   └── docker-29.5.3_install/
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