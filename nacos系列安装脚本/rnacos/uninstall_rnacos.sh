#!/bin/bash

# rnacos 卸载脚本（Linux）
# 停止服务、移除 systemd 服务和安装目录
# 默认保留数据目录，需用 --purge 显式删除

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}此脚本需要以root权限运行${NC}"
   exit 1
fi

RNACOS_INSTALL_DIR="/usr/local/rnacos"
RNACOS_DATA_DIR="/var/lib/rnacos"
FORCE="false"
PURGE="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes) FORCE="true"; shift ;;
        --purge) PURGE="true"; shift ;;
        -h|--help)
            echo "用法: bash uninstall_rnacos.sh [-y|--yes] [--purge]"
            echo "  -y, --yes   跳过确认直接卸载"
            echo "  --purge     同时删除数据目录 $RNACOS_DATA_DIR"
            exit 0 ;;
        *) echo -e "${RED}未知参数: $1${NC}"; exit 1 ;;
    esac
done

echo -e "${CYAN}[INFO] 即将卸载 rnacos${NC}"
echo "  - 停止并移除 systemd 服务 rnacos"
echo "  - 删除安装目录 $RNACOS_INSTALL_DIR"
if [ "$PURGE" = "true" ]; then
    echo -e "${YELLOW}  - 删除数据目录 $RNACOS_DATA_DIR（不可恢复）${NC}"
else
    echo "  - 保留数据目录 $RNACOS_DATA_DIR（如需删除请加 --purge）"
fi

if [ "$FORCE" != "true" ]; then
    read -rp "确认卸载？(y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "已取消"; exit 0; }
fi

echo -e "${CYAN}[INFO] 停止 rnacos 服务...${NC}"
systemctl stop rnacos 2>/dev/null
systemctl disable rnacos 2>/dev/null

if [ -f /etc/systemd/system/rnacos.service ]; then
    rm -f /etc/systemd/system/rnacos.service
    systemctl daemon-reload
    echo -e "${GREEN}[SUCCESS] 已移除 systemd 服务${NC}"
fi

pkill -f "$RNACOS_INSTALL_DIR/rnacos" 2>/dev/null

if [ -d "$RNACOS_INSTALL_DIR" ]; then
    rm -rf "$RNACOS_INSTALL_DIR"
    echo -e "${GREEN}[SUCCESS] 已删除安装目录 $RNACOS_INSTALL_DIR${NC}"
fi

if [ "$PURGE" = "true" ] && [ -d "$RNACOS_DATA_DIR" ]; then
    rm -rf "$RNACOS_DATA_DIR"
    echo -e "${GREEN}[SUCCESS] 已删除数据目录 $RNACOS_DATA_DIR${NC}"
fi

echo -e "${GREEN}[SUCCESS] rnacos 卸载完成${NC}"
