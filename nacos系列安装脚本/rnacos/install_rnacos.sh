#!/bin/bash

# rnacos 自动化安装脚本（Linux）
# rnacos 是用 Rust 重写的 Nacos 服务，资源占用低、单文件部署
# 支持单机模式和集群模式（基于 Raft）部署
# 本地 package/ 目录优先，缺失时自动从 GitHub 下载
# 兼容 Ubuntu 22/24、Debian 12、CentOS Stream/Rocky/AlmaLinux 8/9

# ======================== 全局变量 ========================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 引入通用函数库（颜色、日志、环境检查、detect_os、依赖安装、端口校验）
# shellcheck source=../lib_common.sh
source "$SCRIPT_DIR/../lib_common.sh" || { echo "错误: 未找到通用库 lib_common.sh"; exit 1; }

require_bash
require_root

# 默认配置
RNACOS_VERSION="${RNACOS_VERSION:-v0.8.3}"
RNACOS_INSTALL_DIR="/usr/local/rnacos"
RNACOS_DATA_DIR="/var/lib/rnacos"
RNACOS_PACKAGE_DIR="$SCRIPT_DIR/package"
# 目标平台：musl 静态包，兼容性最好
RNACOS_TARGET="x86_64-unknown-linux-musl"

# 端口配置
HTTP_PORT="8848"        # 兼容 Nacos 的主端口（API + gRPC 基础）
GRPC_PORT=""            # 默认 HTTP_PORT + 1000
CONSOLE_PORT="10848"    # 独立控制台端口

# 部署模式：standalone 或 cluster
DEPLOY_MODE=""

# 集群相关
RAFT_NODE_ID="1"
RAFT_NODE_ADDR=""       # 本节点地址 ip:grpcport
RAFT_AUTO_INIT="true"   # 集群首个节点设 true，其余设 false
RAFT_JOIN_ADDR=""       # 加入已有集群时填首节点的 ip:grpcport

NON_INTERACTIVE="false"

DOWNLOAD_BASE="https://github.com/nacos-group/r-nacos/releases/download"

# ======================== 函数定义 ========================

usage() {
    cat <<EOF
rnacos 自动化安装脚本（Linux）

用法: bash install_rnacos.sh [选项]

选项:
  --standalone               单机模式部署
  --cluster                  集群模式部署
  --version <版本号>         指定 rnacos 版本（默认 ${RNACOS_VERSION}）
  --http-port <端口>         HTTP/API 端口（默认 ${HTTP_PORT}）
  --grpc-port <端口>         gRPC 端口（默认 HTTP端口+1000）
  --console-port <端口>      控制台端口（默认 ${CONSOLE_PORT}）
  --node-id <id>             集群节点 ID（集群模式必填，整数）
  --node-addr <ip:port>      本节点 Raft 通信地址 ip:grpc端口（集群模式必填）
  --auto-init                作为集群首个节点初始化（仅首节点使用）
  --join-addr <ip:port>      加入已有集群，填首节点的 ip:grpc端口
  --target <target>          二进制目标平台（默认 ${RNACOS_TARGET}）
  -h, --help                 显示此帮助

示例:
  # 交互式安装
  bash install_rnacos.sh

  # 单机模式
  bash install_rnacos.sh --standalone

  # 集群首节点（自动初始化）
  bash install_rnacos.sh --cluster --node-id 1 --node-addr 192.168.1.10:9848 --auto-init

  # 集群其他节点（加入集群）
  bash install_rnacos.sh --cluster --node-id 2 --node-addr 192.168.1.11:9848 --join-addr 192.168.1.10:9848
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --standalone) DEPLOY_MODE="standalone"; NON_INTERACTIVE="true"; shift ;;
            --cluster) DEPLOY_MODE="cluster"; NON_INTERACTIVE="true"; shift ;;
            --version) RNACOS_VERSION="$2"; shift 2 ;;
            --http-port) HTTP_PORT="$2"; validate_port "$HTTP_PORT" "HTTP/API"; shift 2 ;;
            --grpc-port) GRPC_PORT="$2"; validate_port "$GRPC_PORT" "gRPC"; shift 2 ;;
            --console-port) CONSOLE_PORT="$2"; validate_port "$CONSOLE_PORT" "控制台"; shift 2 ;;
            --node-id) RAFT_NODE_ID="$2"; shift 2 ;;
            --node-addr) RAFT_NODE_ADDR="$2"; shift 2 ;;
            --auto-init) RAFT_AUTO_INIT="true"; shift ;;
            --join-addr) RAFT_JOIN_ADDR="$2"; RAFT_AUTO_INIT="false"; shift 2 ;;
            --target) RNACOS_TARGET="$2"; shift 2 ;;
            -h|--help) usage ;;
            *) error "未知参数: $1（使用 --help 查看帮助）" ;;
        esac
    done
}

# detect_os / install_base_deps / validate_port 由 lib_common.sh 提供

# 交互式收集版本号和端口
collect_basic_info() {
    if [ "$NON_INTERACTIVE" = "true" ]; then
        return
    fi
    echo ""
    info "基础配置（直接回车使用默认值）"
    read -rp "rnacos 版本 (默认 $RNACOS_VERSION): " input; RNACOS_VERSION="${input:-$RNACOS_VERSION}"
    read -rp "HTTP/API 端口 (默认 $HTTP_PORT): " input; HTTP_PORT="${input:-$HTTP_PORT}"
    validate_port "$HTTP_PORT" "HTTP/API"
    local default_grpc=$((HTTP_PORT + 1000))
    read -rp "gRPC 端口 (默认 $default_grpc): " input; GRPC_PORT="${input:-${GRPC_PORT:-$default_grpc}}"
    validate_port "$GRPC_PORT" "gRPC"
    read -rp "控制台端口 (默认 $CONSOLE_PORT): " input; CONSOLE_PORT="${input:-$CONSOLE_PORT}"
    validate_port "$CONSOLE_PORT" "控制台"
    info "版本: $RNACOS_VERSION  HTTP: $HTTP_PORT  gRPC: $GRPC_PORT  控制台: $CONSOLE_PORT"
}

choose_mode() {
    if [ -n "$DEPLOY_MODE" ]; then return; fi
    echo ""
    echo "请选择部署模式:"
    echo "  1) 单机模式 (standalone)"
    echo "  2) 集群模式 (cluster)"
    read -rp "请输入选项 [1-2] (默认 1): " choice
    case "$choice" in
        2) DEPLOY_MODE="cluster" ;;
        *) DEPLOY_MODE="standalone" ;;
    esac
    info "已选择部署模式: $DEPLOY_MODE"
}

# 集群参数交互收集
collect_cluster_info() {
    if [ "$DEPLOY_MODE" != "cluster" ]; then return; fi
    if [ "$NON_INTERACTIVE" != "true" ]; then
        echo ""
        info "配置集群节点信息"
        read -rp "本节点 ID (整数，每个节点唯一，默认 $RAFT_NODE_ID): " input; RAFT_NODE_ID="${input:-$RAFT_NODE_ID}"
        read -rp "本节点 Raft 地址 (ip:grpc端口，如 192.168.1.10:9848): " RAFT_NODE_ADDR
        echo "本节点是否为集群首个节点（首节点需自动初始化）?"
        read -rp "  1) 是，自动初始化  2) 否，加入已有集群 [1-2] (默认 1): " c
        if [ "$c" = "2" ]; then
            RAFT_AUTO_INIT="false"
            read -rp "请输入首节点的 Raft 地址 (ip:grpc端口): " RAFT_JOIN_ADDR
        else
            RAFT_AUTO_INIT="true"
        fi
    fi
    [ -z "$RAFT_NODE_ADDR" ] && error "集群模式必须提供本节点地址（--node-addr）"
    if [ "$RAFT_AUTO_INIT" != "true" ] && [ -z "$RAFT_JOIN_ADDR" ]; then
        error "加入集群的节点必须提供首节点地址（--join-addr）"
    fi
}

prepare_package() {
    local pkg_name="rnacos-${RNACOS_TARGET}-${RNACOS_VERSION}.tar.gz"
    local local_pkg="$RNACOS_PACKAGE_DIR/$pkg_name"
    RNACOS_TGZ="$local_pkg"

    mkdir -p "$RNACOS_PACKAGE_DIR"

    if [ -f "$local_pkg" ]; then
        info "使用本地安装包: $local_pkg"
        return
    fi

    local url="${DOWNLOAD_BASE}/${RNACOS_VERSION}/${pkg_name}"
    info "本地未找到安装包，从 GitHub 下载: $url"
    if ! wget --timeout=60 --tries=3 -O "$local_pkg" "$url"; then
        rm -f "$local_pkg"
        error "下载 rnacos 失败（网络超时或版本不存在），请检查网络或手动将 $pkg_name 放入 $RNACOS_PACKAGE_DIR"
    fi
    # 校验下载文件大小（< 1MB 视为无效，如 404 页面）
    local file_size
    file_size=$(stat -c%s "$local_pkg" 2>/dev/null || echo 0)
    if [ "$file_size" -lt 1048576 ]; then
        rm -f "$local_pkg"
        error "下载的文件大小异常（${file_size}B），版本号可能不存在，请确认版本后重试"
    fi
    success "下载完成: $local_pkg（$(numfmt --to=iec "$file_size")）"
}

deploy_rnacos() {
    info "创建安装与数据目录..."
    mkdir -p "$RNACOS_INSTALL_DIR" "$RNACOS_DATA_DIR"

    info "解压 rnacos 二进制..."
    if ! tar -zxf "$RNACOS_TGZ" -C "$RNACOS_INSTALL_DIR"; then
        error "解压失败，安装包可能已损坏。请重新下载或手动验证 $RNACOS_TGZ"
    fi
    # 解压后通常为 rnacos 可执行文件
    local bin
    bin=$(find "$RNACOS_INSTALL_DIR" -name "rnacos" -type f | head -n1)
    [ -z "$bin" ] && error "解压后未找到 rnacos 可执行文件，请确认包内包含 rnacos 二进制（架构是否匹配：$RNACOS_TARGET）"
    if [ "$bin" != "$RNACOS_INSTALL_DIR/rnacos" ]; then
        mv "$bin" "$RNACOS_INSTALL_DIR/rnacos" || error "移动可执行文件失败，请检查 $RNACOS_INSTALL_DIR 目录权限"
    fi
    chmod +x "$RNACOS_INSTALL_DIR/rnacos"
    # 验证可执行文件是否能正常运行
    if ! "$RNACOS_INSTALL_DIR/rnacos" --version >/dev/null 2>&1 && ! "$RNACOS_INSTALL_DIR/rnacos" --help >/dev/null 2>&1; then
        warn "rnacos 可执行文件无法运行，请确认系统架构是否为 $RNACOS_TARGET"
    fi
    success "rnacos 已部署到 $RNACOS_INSTALL_DIR"
}

# 生成 .env 配置文件
configure_env() {
    [ -z "$GRPC_PORT" ] && GRPC_PORT=$((HTTP_PORT + 1000))
    local env_file="$RNACOS_INSTALL_DIR/rnacos.env"
    info "生成配置文件 $env_file ..."

    cat > "$env_file" <<EOF
# rnacos 配置文件（由自动化脚本生成）
RNACOS_HTTP_PORT=${HTTP_PORT}
RNACOS_GRPC_PORT=${GRPC_PORT}
RNACOS_HTTP_CONSOLE_PORT=${CONSOLE_PORT}
RNACOS_CONFIG_DB_DIR=${RNACOS_DATA_DIR}
RNACOS_HTTP_WORKERS=8
EOF

    if [ "$DEPLOY_MODE" = "cluster" ]; then
        cat >> "$env_file" <<EOF

# ===== 集群配置 =====
RNACOS_RAFT_NODE_ID=${RAFT_NODE_ID}
RNACOS_RAFT_NODE_ADDR=${RAFT_NODE_ADDR}
RNACOS_RAFT_AUTO_INIT=${RAFT_AUTO_INIT}
EOF
        if [ "$RAFT_AUTO_INIT" != "true" ] && [ -n "$RAFT_JOIN_ADDR" ]; then
            echo "RNACOS_RAFT_JOIN_ADDR=${RAFT_JOIN_ADDR}" >> "$env_file"
        fi
    fi
    if [ ! -f "$env_file" ]; then
        error "配置文件写入失败，请检查 $RNACOS_INSTALL_DIR 目录权限"
    fi
    success "配置文件生成完成"
}

create_systemd_service() {
    info "创建 systemd 服务..."
    cat > /etc/systemd/system/rnacos.service <<EOF
[Unit]
Description=rnacos Server (Rust Nacos)
After=network.target

[Service]
Type=simple
EnvironmentFile=${RNACOS_INSTALL_DIR}/rnacos.env
ExecStart=${RNACOS_INSTALL_DIR}/rnacos
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
WorkingDirectory=${RNACOS_INSTALL_DIR}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    if ! systemctl enable rnacos; then
        warn "systemd 服务启用失败，可能 systemd 未正确初始化，但服务文件已写入"
    fi
    success "systemd 服务创建完成（服务名: rnacos）"
}

start_and_verify() {
    info "启动 rnacos 服务..."
    systemctl start rnacos
    local retries=0
    local max_retries=3
    while [ $retries -lt $max_retries ]; do
        sleep 3
        if systemctl is-active --quiet rnacos; then
            success "rnacos 服务已启动"
            return
        fi
        retries=$((retries + 1))
        [ $retries -lt $max_retries ] && info "等待 rnacos 启动中...（${retries}/${max_retries}）"
    done
    warn "rnacos 服务启动超时或未正常运行"
    warn "诊断命令:"
    warn "  systemctl status rnacos"
    warn "  journalctl -u rnacos -n 50 --no-pager"
}

print_summary() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}        rnacos 安装完成${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "版本:        ${CYAN}${RNACOS_VERSION}${NC}"
    echo -e "部署模式:    ${CYAN}${DEPLOY_MODE}${NC}"
    echo -e "安装目录:    ${CYAN}${RNACOS_INSTALL_DIR}${NC}"
    echo -e "数据目录:    ${CYAN}${RNACOS_DATA_DIR}${NC}"
    echo -e "HTTP/API:    ${CYAN}${HTTP_PORT}${NC}   gRPC: ${CYAN}${GRPC_PORT}${NC}"
    echo -e "控制台地址:  ${CYAN}http://${ip}:${CONSOLE_PORT}/rnacos/${NC}"
    echo -e "默认账号:    ${CYAN}admin / admin${NC}（首次登录请尽快修改）"
    echo ""
    echo -e "常用命令:"
    echo -e "  启动: ${CYAN}systemctl start rnacos${NC}"
    echo -e "  停止: ${CYAN}systemctl stop rnacos${NC}"
    echo -e "  状态: ${CYAN}systemctl status rnacos${NC}"
    echo -e "  日志: ${CYAN}journalctl -u rnacos -f${NC}"
    if [ "$DEPLOY_MODE" = "cluster" ]; then
        echo ""
        warn "集群模式：先启动 --auto-init 首节点，再在其他节点用 --join-addr 加入"
    fi
    echo -e "${GREEN}========================================${NC}"
}

main() {
    parse_args "$@"
    detect_os
    install_base_deps
    collect_basic_info
    info "开始安装 rnacos ${RNACOS_VERSION} ..."
    choose_mode
    collect_cluster_info
    prepare_package
    deploy_rnacos
    configure_env
    create_systemd_service
    start_and_verify
    print_summary
}

main "$@"
