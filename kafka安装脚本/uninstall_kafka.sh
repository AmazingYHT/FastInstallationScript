#!/bin/bash

# Kafka 卸载脚本（Linux）
# 停止并移除 Kafka 服务、安装目录与数据目录

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ -z "$BASH_VERSION" ]; then
    echo -e "${RED}错误: 请使用 bash 执行此脚本${NC}"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}此脚本需要以 root 权限运行${NC}"
    exit 1
fi

info()    { echo -e "${CYAN}[INFO] $1${NC}"; }
success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }
warn()    { echo -e "${YELLOW}[WARN] $1${NC}"; }

KAFKA_INSTALL_DIR="/usr/local/kafka"
KAFKA_DATA_DIR="/var/lib/kafka"
ZK_DATA_DIR="/var/lib/zookeeper"
PURGE_DATA="false"

usage() {
    cat <<EOF
Kafka 卸载脚本

用法: bash uninstall_kafka.sh [选项]

选项:
  --purge-data    同时删除数据目录 ${KAFKA_DATA_DIR} 与 ${ZK_DATA_DIR}（默认保留）
  -h, --help      显示此帮助
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge-data) PURGE_DATA="true"; shift ;;
        -h|--help) usage ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
done

# 停止并移除指定 systemd 服务
remove_service() {
    local svc="$1"
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}.service"; then
        systemctl stop "$svc" 2>/dev/null
        systemctl disable "$svc" 2>/dev/null
        rm -f "/etc/systemd/system/${svc}.service"
        success "已移除 systemd 服务: $svc"
    else
        warn "未发现 ${svc} systemd 服务，跳过"
    fi
}

# 先停 kafka 再停 zookeeper（依赖顺序）
info "停止 Kafka 服务..."
remove_service kafka
info "停止 Zookeeper 服务（如有）..."
remove_service zookeeper
systemctl daemon-reload

if [ -d "$KAFKA_INSTALL_DIR" ]; then
    rm -rf "$KAFKA_INSTALL_DIR"
    success "已删除安装目录: $KAFKA_INSTALL_DIR"
else
    warn "安装目录不存在: $KAFKA_INSTALL_DIR"
fi

if [ "$PURGE_DATA" = "true" ]; then
    for d in "$KAFKA_DATA_DIR" "$ZK_DATA_DIR"; do
        if [ -d "$d" ]; then
            rm -rf "$d"
            success "已删除数据目录: $d"
        fi
    done
else
    for d in "$KAFKA_DATA_DIR" "$ZK_DATA_DIR"; do
        if [ -d "$d" ]; then
            warn "保留数据目录: $d（如需删除请加 --purge-data）"
        fi
    done
fi

success "Kafka 卸载完成"
