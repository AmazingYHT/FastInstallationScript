#!/bin/bash

# Redis 卸载脚本
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
    echo "正确用法: bash uninstall_redis.sh 或 ./uninstall_redis.sh"
    exit 1
fi

# 检查是否为root用户
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}此脚本需要以root权限运行${NC}"
   exit 1
fi

# ======================== 全局变量 ========================

# 加载安装配置
INSTALL_CONFIG="/etc/redis_install.conf"
if [ -f "$INSTALL_CONFIG" ]; then
    . "$INSTALL_CONFIG"
else
    # 默认路径
    REDIS_INSTALL_DIR="/usr/local/redis"
    REDIS_DATA_DIR="/var/lib/redis"
    REDIS_CONF_DIR="/etc/redis"
fi

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

# 停止所有Redis服务
stop_all_services() {
    info "停止所有 Redis 服务..."

    # 停止单机服务
    if systemctl list-units --type=service | grep -q redis.service; then
        systemctl stop redis
        systemctl disable redis
        info "已停止 redis.service"
    fi

    # 停止多实例redis
    for service in $(systemctl list-units --type=service | grep 'redis@' | awk '{print $1}'); do
        systemctl stop "$service"
        systemctl disable "$service"
        info "已停止 $service"
    done

    # 停止哨兵服务
    for service in $(systemctl list-units --type=service | grep 'redis-sentinel@' | awk '{print $1}'); do
        systemctl stop "$service"
        systemctl disable "$service"
        info "已停止 $service"
    done

    # 杀掉残留进程
    if pgrep redis-server > /dev/null; then
        pkill redis-server
        info "已杀掉残留 redis-server 进程"
    fi
    if pgrep redis-sentinel > /dev/null; then
        pkill redis-sentinel
        info "已杀掉残留 redis-sentinel 进程"
    fi

    systemctl daemon-reload
}

# 移除systemd文件
remove_systemd() {
    info "移除 systemd 配置..."
    rm -f /etc/systemd/system/redis.service
    rm -f /etc/systemd/system/redis@.service
    rm -f /etc/systemd/system/redis-sentinel@.service
    systemctl daemon-reload
}

# 主卸载流程
main() {
    echo
    echo "=== Redis 卸载 ==="
    echo
    info "安装目录: $REDIS_INSTALL_DIR"
    info "数据目录: $REDIS_DATA_DIR"
    info "配置目录: $REDIS_CONF_DIR"
    echo

    read -p "是否保留数据文件? (y/N) [默认: y-保留]: " keep_data
    echo

    stop_all_services
    remove_systemd

    # 删除安装文件
    if [ -d "$REDIS_INSTALL_DIR" ]; then
        rm -rf "$REDIS_INSTALL_DIR"
        info "已删除安装目录: $REDIS_INSTALL_DIR"
    fi

    # 删除配置
    if [ -d "$REDIS_CONF_DIR" ]; then
        rm -rf "$REDIS_CONF_DIR"
        info "已删除配置目录: $REDIS_CONF_DIR"
    fi

    # 删除安装配置文件
    rm -f /etc/redis_install.conf

    # 删除数据（如果不保留）
    if [ "$keep_data" != "y" ] && [ "$keep_data" != "Y" ] && [ -d "$REDIS_DATA_DIR" ]; then
        rm -rf "$REDIS_DATA_DIR"
        info "已删除数据目录: $REDIS_DATA_DIR"
    else
        info "数据目录已保留: $REDIS_DATA_DIR"
    fi

    # 删除日志
    if [ -d "/var/log/redis" ]; then
        rm -rf "/var/log/redis"
        info "已删除日志目录: /var/log/redis"
    fi

    # 删除运行目录
    if [ -d "/run/redis" ]; then
        rm -rf "/run/redis"
        info "已删除运行目录: /run/redis"
    fi

    echo
    success "============================================"
    success "Redis 卸载完成!"
    success "============================================"
    echo
}

# 帮助
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "Redis 卸载脚本"
    echo "用法: bash uninstall_redis.sh"
    echo
    exit 0
else
    main
fi
