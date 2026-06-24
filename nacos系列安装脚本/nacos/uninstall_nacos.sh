#!/bin/bash

# Nacos 卸载脚本（Linux）
# 停止服务、移除 systemd 服务和安装目录
# 默认不删除 MySQL 数据，需用 --purge-db 显式确认

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}此脚本需要以root权限运行${NC}"
   exit 1
fi

NACOS_INSTALL_DIR="/usr/local/nacos"
FORCE="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes) FORCE="true"; shift ;;
        -h|--help)
            echo "用法: bash uninstall_nacos.sh [-y|--yes]"
            echo "  -y, --yes   跳过确认直接卸载"
            exit 0 ;;
        *) echo -e "${RED}未知参数: $1${NC}"; exit 1 ;;
    esac
done

echo -e "${CYAN}[INFO] 即将卸载 Nacos${NC}"
echo "  - 停止并移除 systemd 服务 nacos"
echo "  - 删除安装目录 $NACOS_INSTALL_DIR"
echo -e "${YELLOW}注意: 不会删除外部 MySQL 中的数据${NC}"

if [ "$FORCE" != "true" ]; then
    read -rp "确认卸载？(y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "已取消"; exit 0; }
fi

echo -e "${CYAN}[INFO] 停止 Nacos 服务...${NC}"
systemctl stop nacos 2>/dev/null
systemctl disable nacos 2>/dev/null

if [ -f /etc/systemd/system/nacos.service ]; then
    rm -f /etc/systemd/system/nacos.service
    systemctl daemon-reload
    echo -e "${GREEN}[SUCCESS] 已移除 systemd 服务${NC}"
fi

# 兜底：杀掉残留 nacos 进程
pkill -f "nacos.nacos" 2>/dev/null

if [ -d "$NACOS_INSTALL_DIR" ]; then
    rm -rf "$NACOS_INSTALL_DIR"
    echo -e "${GREEN}[SUCCESS] 已删除安装目录 $NACOS_INSTALL_DIR${NC}"
fi

echo -e "${GREEN}[SUCCESS] Nacos 卸载完成${NC}"
