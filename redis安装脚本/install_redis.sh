#!/bin/bash

# Redis 自动化安装脚本
# 支持编译好的 Redis 二进制包部署，支持单机模式和哨兵模式
# 兼容 Ubuntu 22/24、Debian 12、CentOS Stream/Rocky/AlmaLinux 8/9

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 检查是否使用bash执行
if [ -z "$BASH_VERSION" ]; then
    echo -e "${RED}错误: 请使用bash执行此脚本，而不是sh${NC}"
    echo "正确用法: bash install_redis.sh 或 ./install_redis.sh"
    exit 1
fi

# 检查是否为root用户
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}此脚本需要以root权限运行${NC}"
   exit 1
fi

# ======================== 全局变量 ========================

# 脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 默认配置
REDIS_VERSION="7.2.4"
REDIS_TGZ="$SCRIPT_DIR/package/redis-${REDIS_VERSION}.tar.gz"
REDIS_INSTALL_DIR="/usr/local/redis"
REDIS_DATA_DIR="/var/lib/redis"
REDIS_LOG_DIR="/var/log/redis"
REDIS_CONF_DIR="/etc/redis"
REDIS_RUN_DIR="/run/redis"

# 默认端口和绑定地址
REDIS_PORT="6379"
REDIS_BIND="0.0.0.0"
REDIS_PASSWORD=""

# 部署模式：standalone 或 sentinel
DEPLOY_MODE="standalone"

# 开启保护模式
PROTECTED_MODE="yes"

# 日志级别
LOG_LEVEL="notice"

# 配置文件
CONFIG_FILE="/etc/redis_install.conf"

# ======================== 函数定义 ========================

info() {
    echo -e "${CYAN}[INFO] $1${NC}"
}

success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

# 检测操作系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION_ID=$VERSION_ID
    else
        error "无法检测操作系统版本"
    fi
    info "检测到操作系统: $OS $VERSIONION_ID"
}

# 安装依赖
install_dependencies() {
    info "安装基础依赖..."
    case $OS in
        ubuntu|debian)
            apt-get update -y
            apt-get install -y wget tar gcc make
            ;;
        centos|rhel|rocky|almalinux)
            dnf install -y wget tar gcc make
            ;;
        *)
            warn "未识别的操作系统，跳过依赖安装"
            ;;
    esac
}

# 创建用户和目录
create_user_and_dirs() {
    info "创建 redis 用户..."
    if ! id -u redis > /dev/null 2>&1; then
        useradd -r -s /sbin/nologin redis
    fi

    info "创建目录结构..."
    mkdir -p $REDIS_INSTALL_DIR
    mkdir -p $REDIS_DATA_DIR
    mkdir -p $REDIS_LOG_DIR
    mkdir -p $REDIS_CONF_DIR
    mkdir -p $REDIS_RUN_DIR

    chown -R redis:redis $REDIS_DATA_DIR $REDIS_LOG_DIR $REDIS_RUN_DIR $REDIS_INSTALL_DIR
}

# 部署Redis二进制文件
deploy_redis() {
    info "部署 Redis 二进制文件..."

    if [ -f "$REDIS_TGZ" ]; then
        info "使用本地压缩包: $REDIS_TGZ"
        tar zxf "$REDIS_TGZ" -C "$REDIS_INSTALL_DIR" --strip-components=1
    else
        info "本地压缩包不存在，从官网下载..."
        cd "$SCRIPT_DIR"
        mkdir -p package
        wget "http://download.redis.io/releases/redis-${REDIS_VERSION}.tar.gz" -O "$REDIS_TGZ"
        tar zxf "$REDIS_TGZ" -C "$REDIS_INSTALL_DIR" --strip-components=1
        cd "$REDIS_INSTALL_DIR"
        make
    fi

    if [ ! -f "$REDIS_INSTALL_DIR/bin/redis-server" ]; then
        error "Redis 二进制部署失败，请检查压缩包"
    fi

    chown -R redis:redis "$REDIS_INSTALL_DIR"
    success "Redis 二进制部署完成"
}

# 生成单机模式配置文件
generate_standalone_config() {
    info "生成单机模式配置文件..."

    local conf_file="$REDIS_CONF_DIR/redis.conf"
    cat > "$conf_file" << EOF
# Redis 单机配置 - 由 install_redis.sh 自动生成
port $REDIS_PORT
bind $REDIS_BIND
protected-mode $PROTECTED_MODE
daemonize yes
pidfile $REDIS_RUN_DIR/redis_$REDIS_PORT.pid
loglevel $LOG_LEVEL
logfile $REDIS_LOG_DIR/redis_$REDIS_PORT.log
dir $REDIS_DATA_DIR
EOF

    # 如果设置了密码
    if [ -n "$REDIS_PASSWORD" ]; then
        echo "requirepass $REDIS_PASSWORD" >> "$conf_file"
    fi

    chown redis:redis "$conf_file"
    success "配置文件生成: $conf_file"
}

# 生成systemd服务文件
generate_systemd_service() {
    info "生成 systemd 服务文件..."

    local service_file="/etc/systemd/system/redis@.service"
    cat > "$service_file" << EOF
[Unit]
Description=Redis In-Memory Data Store (port %i)
After=network.target

[Service]
Type=forking
User=redis
Group=redis
PIDFile=$REDIS_RUN_DIR/redis_%i.pid
ExecStart=$REDIS_INSTALL_DIR/bin/redis-server $REDIS_CONF_DIR/redis_%i.conf
ExecStop=$REDIS_INSTALL_DIR/bin/redis-cli -p %i shutdown
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    # 如果是单机模式，创建默认服务
    if [ "$DEPLOY_MODE" = "standalone" ]; then
        cat > /etc/systemd/system/redis.service << EOF
[Unit]
Description=Redis In-Memory Data Store
After=network.target

[Service]
Type=forking
User=redis
Group=redis
PIDFile=$REDIS_RUN_DIR/redis_$REDIS_PORT.pid
ExecStart=$REDIS_INSTALL_DIR/bin/redis-server $REDIS_CONF_DIR/redis.conf
ExecStop=$REDIS_INSTALL_DIR/bin/redis-cli -p $REDIS_PORT shutdown
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    fi

    systemctl daemon-reload
    success "systemd 服务文件生成完成"
}

# 启动服务
start_standalone_service() {
    info "启动 Redis 服务..."
    if [ "$DEPLOY_MODE" = "standalone" ]; then
        systemctl enable --now redis
        sleep 2
        if systemctl is-active --quiet redis; then
            success "Redis 服务启动成功"
            info "监听端口: $REDIS_PORT"
            if [ -n "$REDIS_PASSWORD" ]; then
                info "连接命令: $REDIS_INSTALL_DIR/bin/redis-cli -p $REDIS_PORT -a $REDIS_PASSWORD"
            else
                info "连接命令: $REDIS_INSTALL_DIR/bin/redis-cli -p $REDIS_PORT"
            fi
        else
            error "Redis 服务启动失败，请查看日志: journalctl -u redis"
        fi
    fi
}

# 交互式配置
interactive_config() {
    echo
    echo "=== Redis 安装配置 ==="
    echo

    read -p "请输入部署模式 (1=单机模式, 2=哨兵模式多实例) [默认: 1-单机模式]: " mode_choice
    case "$mode_choice" in
        2)
            DEPLOY_MODE="sentinel"
            ;;
        *)
            DEPLOY_MODE="standalone"
            ;;
    esac

    read -p "请输入 Redis 安装目录 [默认: $REDIS_INSTALL_DIR]: " input
    if [ -n "$input" ]; then REDIS_INSTALL_DIR=$input; fi

    read -p "请输入 Redis 数据目录 [默认: $REDIS_DATA_DIR]: " input
    if [ -n "$input" ]; then REDIS_DATA_DIR=$input; fi

    read -p "请输入 Redis 端口 [默认: $REDIS_PORT]: " input
    if [ -n "$input" ]; then REDIS_PORT=$input; fi

    read -p "请输入 Redis 密码 (留空表示不设置): " input
    if [ -n "$input" ]; then REDIS_PASSWORD=$input; fi

    echo
    info "配置汇总:"
    info "  部署模式: $DEPLOY_MODE"
    info "  安装目录: $REDIS_INSTALL_DIR"
    info "  数据目录: $REDIS_DATA_DIR"
    info "  端口: $REDIS_PORT"
    info "  密码: ${REDIS_PASSWORD:-(未设置)}"
    echo
    read -p "确认开始安装? [y/N]: " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        info "用户取消安装"
        exit 0
    fi
}

# 保存配置
save_config() {
    cat > "$CONFIG_FILE" << EOF
# Redis 安装配置 - 由 install_redis.sh 生成
REDIS_VERSION=$REDIS_VERSION
REDIS_INSTALL_DIR=$REDIS_INSTALL_DIR
REDIS_DATA_DIR=$REDIS_DATA_DIR
REDIS_LOG_DIR=$REDIS_LOG_DIR
REDIS_CONF_DIR=$REDIS_CONF_DIR
REDIS_RUN_DIR=$REDIS_RUN_DIR
REDIS_PORT=$REDIS_PORT
REDIS_BIND=$REDIS_BIND
REDIS_PASSWORD=$REDIS_PASSWORD
DEPLOY_MODE=$DEPLOY_MODE
EOF
}

# 主安装流程
main() {
    detect_os
    interactive_config
    install_dependencies
    create_user_and_dirs
    deploy_redis
    if [ "$DEPLOY_MODE" = "standalone" ]; then
        generate_standalone_config
    fi
    generate_systemd_service
    start_standalone_service
    save_config

    echo
    success "============================================"
    success "Redis $DEPLOY_MODE 模式安装完成!"
    success "安装目录: $REDIS_INSTALL_DIR"
    success "配置目录: $REDIS_CONF_DIR"
    success "数据目录: $REDIS_DATA_DIR"
    if [ "$DEPLOY_MODE" = "standalone" ]; then
        success "服务名称: redis"
        success "管理命令: systemctl {start|stop|restart|status} redis"
    else
        success "多实例管理: systemctl {start|stop|restart} redis@端口"
        success "哨兵配置请运行: bash $SCRIPT_DIR/setup_redis_sentinel.sh"
    fi
    success "============================================"
    echo
}

# 启动安装
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "Redis 自动化安装脚本"
    echo "用法: bash install_redis.sh [选项]"
    echo
    echo "选项:"
    echo "  --help, -h    显示帮助信息"
    echo "  --standalone  非交互式单机模式安装"
    echo "  --sentinel    非交互式哨兵模式基础安装"
    echo
    exit 0
elif [ "$1" = "--standalone" ]; then
    DEPLOY_MODE="standalone"
    main
elif [ "$1" = "--sentinel" ]; then
    DEPLOY_MODE="sentinel"
    main
else
    main
fi
