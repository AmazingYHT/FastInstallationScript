# FastInstallationScript

一键安装自用脚本整理。

## 目录结构

```
FastInstallationScript/
├── docker安装脚本/
│   └── docker-28.3.3_install/
│       ├── installDocker.sh           # Docker安装脚本
│       ├── uninstallDocker.sh         # Docker卸载脚本
│       ├── conf/                       # 配置文件
│       └── package/                    # Docker二进制包
├── mysql安装脚本/
│   ├── install_mysql.sh               # MySQL安装脚本（推荐8.4.9 LTS）
│   ├── uninstall_mysql.sh             # MySQL完全卸载脚本
│   └── MySQL自动化脚本使用手册.md      # 使用手册
├── postgresql安装脚本/
│   ├── install_postgresql.sh          # PostgreSQL安装脚本
│   ├── uninstall_postgresql.sh        # PostgreSQL卸载脚本
│   └── postgresql_wal_archive_manager.sh  # WAL归档管理脚本
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
| EasyVoice 有声助手 | 小说文本清理与 TTS 有声书生成 | [clean_novel操作指南](EasyVoice有声助手/clean_novel操作指南.md) |