#!/bin/bash

# Redis Sentinel 哨兵模式自动化配置脚本
# 用于配置Redis主从复制 + 哨兵高可用
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
    echo "正确用法: bash setup_redis_sentinel.sh 或 ./setup_redis_sentinel.sh"
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

# 加载安装配置
INSTALL_CONFIG="/etc/redis_install.conf"
if [ -f "$INSTALL_CONFIG" ]; then
    . "$INSTALL_CONFIG"
fi

# 默认配置
: "${REDIS_INSTALL_DIR:=/usr/local/redis}"
: "${REDIS_DATA_DIR:=/var/lib/redis}"
: "${REDIS_LOG_DIR:=/var/log/redis}"
: "${REDIS_CONF_DIR:=/etc/redis}"
: "${REDIS_RUN_DIR:=/run/redis}"

# 节点配置
REDIS_MASTER_HOST=""
REDIS_MASTER_PORT="6379"
REDIS_MASTER_PASSWORD=""

# 本节点角色：master, slave, sentinel
LOCAL_ROLE=""
LOCAL_REDIS_PORT=""
LOCAL_REDIS_PASSWORD=""

# 哨兵配置
SENTINEL_PORT="26379"
SENTINEL_QUORUM="2"
SENTINEL_DOWN_AFTER="30000"
SENTINEL_FAILOVER_TIMEOUT="180000"
SENTINEL_PARALLEL_SYNC="1"

# 绑定地址
REDIS_BIND="0.0.0.0"
PROTECTED_MODE="yes"
LOG_LEVEL="notice"

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

# 检查Redis已安装
check_redis_installed() {
    if [ ! -f "$REDIS_INSTALL_DIR/bin/redis-server" ]; then
        error "Redis 未安装，请先运行 install_redis.sh"
    fi
}

# 创建目录
ensure_dirs() {
    mkdir -p "$REDIS_DATA_DIR" "$REDIS_LOG_DIR" "$REDIS_CONF_DIR" "$REDIS_RUN_DIR"
    chown -R redis:redis "$REDIS_DATA_DIR" "$REDIS_LOG_DIR" "$REDIS_RUN_DIR" "$REDIS_CONF_DIR"
}

# 配置主节点
configure_master() {
    info "配置 Redis 主节点..."

    local conf_file="$REDIS_CONF_DIR/redis_${LOCAL_REDIS_PORT}.conf"
    cat > "$conf_file" << EOF
# Redis 主节点配置 - 由 setup_redis_sentinel.sh 自动生成
port $LOCAL_REDIS_PORT
bind $REDIS_BIND
protected-mode $PROTECTED_MODE
daemonize yes
pidfile $REDIS_RUN_DIR/redis_$LOCAL_REDIS_PORT.pid
loglevel $LOG_LEVEL
logfile $REDIS_LOG_DIR/redis_$LOCAL_REDIS_PORT.log
dir $REDIS_DATA_DIR/redis_$LOCAL_REDIS_PORT

# 开启RDB持久化
save 60 1
save 900 1
save 300 10
save 15 100
rdbcompression yes
dbfilename dump_$LOCAL_REDIS_PORT.rdb
EOF

    # 密码配置
    if [ -n "$LOCAL_REDIS_PASSWORD" ]; then
        echo "requirepass $LOCAL_REDIS_PASSWORD" >> "$conf_file"
    fi

    chown redis:redis "$conf_file"
    success "主节点配置生成: $conf_file"

    # 启动服务
    info "启动主节点服务..."
    systemctl enable --now "redis@$LOCAL_REDIS_PORT"
    sleep 2
    if systemctl is-active --quiet "redis@$LOCAL_REDIS_PORT"; then
        success "主节点启动成功"
    else
        error "主节点启动失败: journalctl -u redis@$LOCAL_REDIS_PORT"
    fi
}

# 配置从节点
configure_slave() {
    info "配置 Redis 从节点..."

    local conf_file="$REDIS_CONF_DIR/redis_${LOCAL_REDIS_PORT}.conf"
    cat > "$conf_file" << EOF
# Redis 从节点配置 - 由 setup_redis_sentinel.sh 自动生成
port $LOCAL_REDIS_PORT
bind $REDIS_BIND
protected-mode $PROTECTED_MODE
daemonize yes
pidfile $REDIS_RUN_DIR/redis_$LOCAL_REDIS_PORT.pid
loglevel $LOG_LEVEL
logfile $REDIS_LOG_DIR/redis_$LOCAL_REDIS_PORT.log
dir $REDIS_DATA_DIR/redis_$LOCAL_REDIS_PORT

# 主节点信息
replicaof $REDIS_MASTER_HOST $REDIS_MASTER_PORT

# 开启RDB持久化
save 60 1
save 900 1
save 300 10
save 15 100
rdbcompression yes
dbfilename dump_$LOCAL_REDIS_PORT.rdb
EOF

    # 如果主节点有密码
    if [ -n "$REDIS_MASTER_PASSWORD" ]; then
        echo "masterauth $REDIS_MASTER_PASSWORD" >> "$conf_file"
    fi

    # 如果本节点需要密码
    if [ -n "$LOCAL_REDIS_PASSWORD" ]; then
        echo "requirepass $LOCAL_REDIS_PASSWORD" >> "$conf_file"
    fi

    chown redis:redis "$conf_file"
    success "从节点配置生成: $conf_file"

    # 启动服务
    info "启动从节点服务..."
    systemctl enable --now "redis@$LOCAL_REDIS_PORT"
    sleep 2
    if systemctl is-active --quiet "redis@$LOCAL_REDIS_PORT"; then
        success "从节点启动成功"
    else
        error "从节点启动失败: journalctl -u redis@$LOCAL_REDIS_PORT"
    fi
}

# 配置哨兵
configure_sentinel() {
    info "配置 Redis Sentinel..."

    local conf_file="$REDIS_CONF_DIR/sentinel_${SENTINEL_PORT}.conf"
    cat > "$conf_file" << EOF
# Redis Sentinel 配置 - 由 setup_redis_sentinel.sh 自动生成
port $SENTINEL_PORT
bind $REDIS_BIND
protected-mode $PROTECTED_MODE
daemonize yes
pidfile $REDIS_RUN_DIR/sentinel_$SENTINEL_PORT.pid
loglevel $LOG_LEVEL
logfile $REDIS_LOG_DIR/sentinel_$SENTINEL_PORT.log
dir $REDIS_DATA_DIR/sentinel_$SENTINEL_PORT

# 监控主节点
sentinel monitor mymaster $REDIS_MASTER_HOST $REDIS_MASTER_PORT $SENTINEL_QUORUM
sentinel down-after-milliseconds mymaster $SENTINEL_DOWN_AFTER
sentinel failover-timeout mymaster $SENTINEL_FAILOVER_TIMEOUT
sentinel parallel-syncs mymaster $SENTINEL_PARALLEL_SYNC
EOF

    # 如果主节点有密码
    if [ -n "$REDIS_MASTER_PASSWORD" ]; then
        echo "sentinel auth-pass mymaster $REDIS_MASTER_PASSWORD" >> "$conf_file"
    fi

    chown redis:redis "$conf_file"
    success "哨兵配置生成: $conf_file"

    # 生成systemd服务
    local service_file="/etc/systemd/system/redis-sentinel@.service"
    cat > "$service_file" << EOF
[Unit]
Description=Redis Sentinel (port %i)
After=network.target

[Service]
Type=forking
User=redis
Group=redis
PIDFile=$REDIS_RUN_DIR/sentinel_%i.pid
ExecStart=$REDIS_INSTALL_DIR/bin/redis-sentinel $REDIS_CONF_DIR/sentinel_%i.conf
ExecStop=$REDIS_INSTALL_DIR/bin/redis-cli -p %i shutdown
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload

    # 启动哨兵
    info "启动哨兵服务..."
    systemctl enable --now "redis-sentinel@$SENTINEL_PORT"
    sleep 2
    if systemctl is-active --quiet "redis-sentinel@$SENTINEL_PORT"; then
        success "哨兵启动成功"
    else
        error "哨兵启动失败: journalctl -u redis-sentinel@$SENTINEL_PORT"
    fi
}

# 交互式配置
interactive_config() {
    echo
    echo "=== Redis Sentinel 哨兵模式配置 ==="
    echo "架构说明: 需要配置 1主 N从 + 3哨兵（推荐）"
    echo "在每台机器上运行此脚本，根据提示选择本节点角色"
    echo

    read -p "请输入本节点角色 (1=master主节点, 2=slave从节点, 3=sentinel哨兵): " role_choice
    case "$role_choice" in
        1)
            LOCAL_ROLE="master"
            ;;
        2)
            LOCAL_ROLE="slave"
            ;;
        3)
            LOCAL_ROLE="sentinel"
            ;;
        *)
            error "无效的选择，请输入 1、2 或 3"
            ;;
    esac

    read -p "请输入本节点 Redis 端口 [默认: 6379]: " input
    if [ -n "$input" ]; then
        LOCAL_REDIS_PORT=$input
    else
        LOCAL_REDIS_PORT="6379"
    fi

    read -p "请输入本节点 Redis 密码 (留空不设置): " input
    if [ -n "$input" ]; then LOCAL_REDIS_PASSWORD=$input; fi

    # 如果是从节点或哨兵，需要输入主节点信息
    if [ "$LOCAL_ROLE" = "slave" ] || [ "$LOCAL_ROLE" = "sentinel" ]; then
        read -p "请输入主节点 IP/主机名: " input
        if [ -n "$input" ]; then REDIS_MASTER_HOST=$input; fi
        if [ -z "$REDIS_MASTER_HOST" ]; then
            error "必须指定主节点地址"
        fi
        read -p "请输入主节点端口 [默认: 6379]: " input
        if [ -n "$input" ]; then REDIS_MASTER_PORT=$input; fi
        read -p "请输入主节点密码 (如果没有留空): " input
        if [ -n "$input" ]; then REDIS_MASTER_PASSWORD=$input; fi
    fi

    # 如果是哨兵，需要配置哨兵参数
    if [ "$LOCAL_ROLE" = "sentinel" ]; then
        read -p "请输入本节点 Sentinel 端口 [默认: 26379]: " input
        if [ -n "$input" ]; then SENTINEL_PORT=$input; fi
        read -p "请输入法定投票数 quorum [默认: 2]: " input
        if [ -n "$input" ]; then SENTINEL_QUORUM=$input; fi
    fi

    echo
    info "配置汇总:"
    info "  本节点角色: $LOCAL_ROLE"
    info "  Redis端口: $LOCAL_REDIS_PORT"
    info "  Redis密码: ${LOCAL_REDIS_PASSWORD:-(未设置)}"
    if [ "$LOCAL_ROLE" != "master" ]; then
        info "  主节点地址: $REDIS_MASTER_HOST:$REDIS_MASTER_PORT"
        info "  主节点密码: ${REDIS_MASTER_PASSWORD:-(未设置)}"
    fi
    if [ "$LOCAL_ROLE" = "sentinel" ]; then
        info "  哨兵端口: $SENTINEL_PORT"
        info "  法定票数: $SENTINEL_QUORUM"
    fi
    echo
    read -p "确认开始配置? [y/N]: " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        info "用户取消"
        exit 0
    fi
}

# 主流程
main() {
    check_redis_installed
    interactive_config
    ensure_dirs

    case "$LOCAL_ROLE" in
        master)
            configure_master
            ;;
        slave)
            configure_slave
            ;;
        sentinel)
            configure_sentinel
            ;;
    esac

    echo
    success "============================================"
    success "Redis Sentinel 配置完成!"
    success "角色: $LOCAL_ROLE"
    if [ "$LOCAL_ROLE" != "sentinel" ]; then
        success "Redis 端口: $LOCAL_REDIS_PORT"
        success "服务: systemctl status redis@$LOCAL_REDIS_PORT"
    else
        success "Sentinel 端口: $SENTINEL_PORT"
        success "服务: systemctl status redis-sentinel@$SENTINEL_PORT"
    fi
    success "============================================"
    echo
}

# 帮助
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "Redis Sentinel 自动化配置脚本"
    echo "用法: bash setup_redis_sentinel.sh"
    echo
    echo "说明:"
    echo "  需要先运行 install_redis.sh --sentinel 完成基础安装"
    echo "  在每个节点上运行此脚本，选择对应角色进行配置"
    echo "  推荐架构: 1主 + 1-2从 + 3哨兵"
    echo
    exit 0
else
    main
fi
