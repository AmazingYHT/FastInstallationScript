#!/bin/bash

# rnacos 集群一键部署脚本（Raft）
# 本机作为首节点（auto-init），SSH 远程安装其余节点并 join 集群
# 兼容 Ubuntu 22/24、Debian 12、CentOS Stream/Rocky/AlmaLinux 8/9

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck source=../lib_common.sh
source "$PARENT_DIR/lib_common.sh" || { echo "错误: 未找到 lib_common.sh"; exit 1; }

require_bash
require_root

# ======================== 系统版本检测与包管理统一封装 ========================
# EL8/9(Rocky/AlmaLinux/CentOS/RHEL) 用 dnf，EL7 用 yum，Debian 系用 apt-get
SYS_PKG=""; SYS_FAMILY=""; OS_ID=""; OS_MAJOR=""

detect_sys_pkg() {
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"; OS_MAJOR="${VERSION_ID%%.*}"
    fi
    if command -v dnf &>/dev/null && [[ "$OS_MAJOR" =~ ^[0-9]+$ ]] && [ "$OS_MAJOR" -ge 8 ]; then
        SYS_PKG=dnf; SYS_FAMILY=el
    elif command -v yum &>/dev/null; then
        SYS_PKG=yum; SYS_FAMILY=el
    elif command -v apt-get &>/dev/null; then
        SYS_PKG=apt-get; SYS_FAMILY=debian
    fi
}

# 静默安装软件包。用法：sys_pkg_install "<el系包名>" "<debian系包名>"
sys_pkg_install() {
    local el_pkg="$1" deb_pkg="${2:-$1}"
    case "$SYS_PKG" in
        dnf) dnf install -y $el_pkg ;;
        yum) yum install -y $el_pkg ;;
        apt-get) apt-get install -y $deb_pkg ;;
        *) return 1 ;;
    esac
}

# ======================== 全局变量 ========================

INSTALL_SCRIPT="$SCRIPT_DIR/install_rnacos.sh"
CLUSTER_STATE_FILE="/etc/rnacos_cluster_deploy.conf"

RNACOS_VERSION="${RNACOS_VERSION:-v0.8.3}"
RNACOS_INSTALL_DIR="/usr/local/rnacos"
RNACOS_DATA_DIR="/var/lib/rnacos"
RNACOS_TARGET="x86_64-unknown-linux-musl"

HTTP_PORT="8848"
GRPC_PORT=""            # 默认 HTTP+1000
CONSOLE_PORT="10848"

INCLUDE_LOCAL_NODE="yes"
LOCAL_NODE_IP=""
LOCAL_NODE_ID="1"

# 首节点 Raft 地址 ip:grpc
FIRST_NODE_ADDR=""
NEXT_NODE_ID=1

# SSH
SSH_USER="root"
SSH_PORT="22"
SSH_PASSWORD=""
SSH_KEY=""
SSH_OPTS=""

# 远程节点: ip|ssh_port|ssh_user|ssh_pass|http_port|node_id
REMOTE_NODES=()

RNACOS_TGZ=""

# ======================== SSH 工具 ========================

ensure_ssh_tools() {
    if ! command -v ssh >/dev/null 2>&1 || ! command -v scp >/dev/null 2>&1; then
        error "未找到 ssh/scp"
    fi
    if [ -n "$SSH_PASSWORD" ] && ! command -v sshpass >/dev/null 2>&1; then
        warn "尝试安装 sshpass..."
        detect_sys_pkg
        sys_pkg_install "sshpass" 2>/dev/null || true
        command -v sshpass >/dev/null 2>&1 || error "sshpass 不可用"
    fi
}

build_ssh_opts() {
    SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -p $SSH_PORT"
    [ -n "$SSH_KEY" ] && SSH_OPTS="$SSH_OPTS -i $SSH_KEY"
}

ssh_cmd() {
    local host="$1"; shift
    build_ssh_opts
    if [ -n "$SSH_PASSWORD" ]; then
        SSHPASS="$SSH_PASSWORD" sshpass -e ssh $SSH_OPTS "${SSH_USER}@${host}" "$*"
    else
        ssh $SSH_OPTS "${SSH_USER}@${host}" "$*"
    fi
}

scp_to_remote() {
    local src="$1" host="$2" dest="$3"
    build_ssh_opts
    if [ -n "$SSH_PASSWORD" ]; then
        SSHPASS="$SSH_PASSWORD" sshpass -e scp $SSH_OPTS "$src" "${SSH_USER}@${host}:${dest}"
    else
        scp $SSH_OPTS "$src" "${SSH_USER}@${host}:${dest}"
    fi
}

with_node_ssh() {
    SSH_PORT="$2"; SSH_USER="$3"; SSH_PASSWORD="$4"
}

# ======================== 远程节点 SELinux 处理 ========================
# 本地只询问一次；确认后通过 SSH 在每个远程节点幂等关闭
SELINUX_REMOTE_DISABLE_ASKED=0
SELINUX_REMOTE_DISABLE=0

disable_remote_selinux() {
    local host="$1"

    if [ "$SELINUX_REMOTE_DISABLE_ASKED" -eq 0 ]; then
        SELINUX_REMOTE_DISABLE_ASKED=1
        echo ""
        warn "远程节点若开启 SELinux（Enforcing），服务以 systemd 启动时可能被拦截。"
        warn "建议在所有远程节点关闭 SELinux（setenforce 0 立即生效 + 改 /etc/selinux/config 永久生效）。"
        if [ -t 0 ] && [ -t 1 ]; then
            local sel
            read -rp "是否自动关闭所有远程节点的 SELinux? [Y/n]: " sel
            [ -z "$sel" ] && sel="Y"
            [[ "$sel" =~ ^[Yy]$ ]] && SELINUX_REMOTE_DISABLE=1
        else
            SELINUX_REMOTE_DISABLE=1
            info "非交互模式，默认在远程节点关闭 SELinux"
        fi
    fi

    [ "$SELINUX_REMOTE_DISABLE" -ne 1 ] && return 0

    local state
    state=$(ssh_cmd "$host" 'if command -v getenforce >/dev/null 2>&1; then getenforce; else echo NONE; fi')
    case "$state" in
        Enforcing)
            warn "${host} SELinux=Enforcing，正在关闭..."
            ssh_cmd "$host" 'setenforce 0 && sed -i "s/^SELINUX=enforcing/SELINUX=disabled/I" /etc/selinux/config && echo DONE' || {
                warn "${host} 关闭 SELinux 失败，请手动处理"
                return 1
            }
            success "${host} SELinux 已关闭（运行时 Permissive，重启后 Disabled）"
            ;;
        Permissive|Disabled)
            info "${host} SELinux=${state}，无需处理"
            ;;
        *)
            info "${host} 无 SELinux 或状态未知，跳过"
            ;;
    esac
    return 0
}

get_local_ip() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [ -z "$ip" ]; then
        ip=$(ip -4 addr show 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | head -1)
    fi
    echo "$ip"
}

confirm_action() {
    local message="$1" default="${2:-N}"
    local hint="是否继续? [y/N]: "
    [[ "$default" =~ ^[Yy]$ ]] && hint="是否继续? [Y/n]: "
    echo -e "${YELLOW}$message${NC}"
    read -rp "$hint" confirm
    [[ -z "$confirm" ]] && confirm="$default"
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}操作已取消${NC}"
        return 1
    fi
    return 0
}

# ======================== 安装包 ========================

ensure_package_tgz() {
    local pkg_name="rnacos-${RNACOS_TARGET}-${RNACOS_VERSION}.tar.gz"
    local local_pkg="$SCRIPT_DIR/package/$pkg_name"
    mkdir -p "$SCRIPT_DIR/package"

    if [ -f "$local_pkg" ]; then
        RNACOS_TGZ="$local_pkg"
        info "使用本地安装包: $RNACOS_TGZ"
        return 0
    fi

    local url="https://github.com/nacos-group/r-nacos/releases/download/${RNACOS_VERSION}/${pkg_name}"
    info "下载: $url"
    if wget --timeout=60 --tries=3 -O "$local_pkg" "$url"; then
        local sz
        sz=$(stat -c%s "$local_pkg" 2>/dev/null || echo 0)
        if [ "$sz" -gt 1048576 ]; then
            RNACOS_TGZ="$local_pkg"
            success "下载完成: $RNACOS_TGZ"
            return 0
        fi
        rm -f "$local_pkg"
    fi
    warn "安装包准备失败，请手动放入: $local_pkg"
    return 1
}

# ======================== 收集配置 ========================

collect_ssh_info() {
    echo ""
    info "SSH 远程连接信息"
    read -rp "SSH 用户名 [root]: " input; SSH_USER=${input:-root}
    read -rp "SSH 端口 [22]: " input; SSH_PORT=${input:-22}
    echo "认证方式: 1) SSH密码  2) SSH私钥"
    read -rp "请选择 [1/2]: " auth_choice
    case "$auth_choice" in
        2)
            read -rp "私钥路径 [~/.ssh/id_rsa]: " input
            SSH_KEY=${input:-$HOME/.ssh/id_rsa}
            SSH_KEY="${SSH_KEY/#\~/$HOME}"
            SSH_PASSWORD=""
            ;;
        *)
            read -rsp "SSH 密码: " SSH_PASSWORD; echo ""
            SSH_KEY=""
            ;;
    esac
    ensure_ssh_tools
}

collect_cluster_config() {
    echo ""
    info "rnacos 集群配置（Raft，无需外部数据库）"
    read -rp "rnacos 版本 [${RNACOS_VERSION}]: " input; RNACOS_VERSION=${input:-$RNACOS_VERSION}
    read -rp "HTTP/API 端口 [${HTTP_PORT}]: " input; HTTP_PORT=${input:-$HTTP_PORT}
    GRPC_PORT=$((HTTP_PORT + 1000))
    read -rp "gRPC 端口 [${GRPC_PORT}]: " input; GRPC_PORT=${input:-$GRPC_PORT}
    read -rp "控制台端口 [${CONSOLE_PORT}]: " input; CONSOLE_PORT=${input:-$CONSOLE_PORT}

    LOCAL_NODE_IP=$(get_local_ip)
    read -rp "本机对外 IP [${LOCAL_NODE_IP}]: " input; LOCAL_NODE_IP=${input:-$LOCAL_NODE_IP}

    read -rp "本机是否作为集群节点（首节点）? [Y/n]: " inc
    if [[ "$inc" =~ ^[Nn]$ ]]; then
        INCLUDE_LOCAL_NODE="no"
        echo "请稍后指定远程首节点，本机仅编排"
    else
        INCLUDE_LOCAL_NODE="yes"
        LOCAL_NODE_ID=1
        FIRST_NODE_ADDR="${LOCAL_NODE_IP}:${GRPC_PORT}"
        NEXT_NODE_ID=2
        info "本机将作为 Raft 首节点: id=1 addr=$FIRST_NODE_ADDR"
    fi
}

collect_remote_nodes() {
    echo ""
    info "添加远程节点（IP 留空结束）"
    REMOTE_NODES=()
    local idx=1
    while true; do
        read -rp "节点 #${idx} IP/主机名 (空结束): " host
        [ -z "$host" ] && break
        local sport="$SSH_PORT" suser="$SSH_USER" spass="$SSH_PASSWORD"
        local rhttp="$HTTP_PORT" custom
        local node_id="$NEXT_NODE_ID"

        read -rp "  SSH端口 [${SSH_PORT}]: " custom; sport=${custom:-$sport}
        read -rp "  SSH用户 [${SSH_USER}]: " custom; suser=${custom:-$suser}
        if [ -n "$SSH_PASSWORD" ]; then
            read -rp "  使用全局SSH密码? [Y/n]: " ug
            if [[ "$ug" =~ ^[Nn]$ ]]; then
                read -rsp "  SSH密码: " spass; echo ""
            fi
        else
            read -rp "  使用全局SSH密钥? [Y/n]: " ug
            if [[ "$ug" =~ ^[Nn]$ ]]; then
                read -rsp "  SSH密码: " spass; echo ""
            else
                spass=""
            fi
        fi
        read -rp "  HTTP端口 [${HTTP_PORT}]: " custom; rhttp=${custom:-$rhttp}
        read -rp "  节点ID [${node_id}]: " custom; node_id=${custom:-$node_id}

        REMOTE_NODES+=("${host}|${sport}|${suser}|${spass}|${rhttp}|${node_id}")
        success "已添加: ${host}:${rhttp} (id=${node_id})"
        NEXT_NODE_ID=$((node_id + 1))
        idx=$((idx+1))
    done

    # 若本机不是节点，则首个远程作为首节点
    if [ "$INCLUDE_LOCAL_NODE" != "yes" ] && [ ${#REMOTE_NODES[@]} -gt 0 ]; then
        IFS='|' read -r h _ _ _ rp _ <<< "${REMOTE_NODES[0]}"
        local rg=$((rp + 1000))
        FIRST_NODE_ADDR="${h}:${rg}"
        info "首节点设为第一个远程: $FIRST_NODE_ADDR"
    fi

    if [ -z "$FIRST_NODE_ADDR" ]; then
        error "未确定首节点 Raft 地址"
    fi

    local total=${#REMOTE_NODES[@]}
    [ "$INCLUDE_LOCAL_NODE" = "yes" ] && total=$((total + 1))
    if [ "$total" -lt 3 ]; then
        warn "当前节点数=$total，Raft 集群建议至少 3 节点"
        confirm_action "仍继续?" || return 1
    fi
    return 0
}

save_cluster_state() {
    {
        echo "# rnacos cluster deploy - $(date)"
        echo "RNACOS_VERSION=$RNACOS_VERSION"
        echo "HTTP_PORT=$HTTP_PORT"
        echo "GRPC_PORT=$GRPC_PORT"
        echo "CONSOLE_PORT=$CONSOLE_PORT"
        echo "LOCAL_NODE_IP=$LOCAL_NODE_IP"
        echo "INCLUDE_LOCAL_NODE=$INCLUDE_LOCAL_NODE"
        echo "LOCAL_NODE_ID=$LOCAL_NODE_ID"
        echo "FIRST_NODE_ADDR=$FIRST_NODE_ADDR"
        echo "SSH_USER=$SSH_USER"
        echo "SSH_PORT=$SSH_PORT"
        echo "SSH_KEY=$SSH_KEY"
        echo "RNACOS_TGZ=$RNACOS_TGZ"
        echo "REMOTE_NODES_STR=${REMOTE_NODES[*]}"
    } > "$CLUSTER_STATE_FILE"
    chmod 600 "$CLUSTER_STATE_FILE"
    success "集群状态: $CLUSTER_STATE_FILE"
}

# ======================== 本机首节点 ========================

install_local_rnacos() {
    echo ""
    info "===== 本机安装 rnacos 首节点 ====="

    if [ ! -f "$INSTALL_SCRIPT" ]; then
        error "未找到 $INSTALL_SCRIPT"
    fi

    local args=(
        --cluster
        --version "$RNACOS_VERSION"
        --http-port "$HTTP_PORT"
        --grpc-port "$GRPC_PORT"
        --console-port "$CONSOLE_PORT"
        --node-id "$LOCAL_NODE_ID"
        --node-addr "${LOCAL_NODE_IP}:${GRPC_PORT}"
        --auto-init
    )

    info "执行: bash install_rnacos.sh ${args[*]}"
    bash "$INSTALL_SCRIPT" "${args[@]}" || error "本机 rnacos 安装失败"
    success "本机首节点安装完成（auto-init）"
    # 等待 Raft 就绪
    sleep 3
}

# ======================== 远程安装 ========================

remote_install_rnacos() {
    local host="$1" sport="$2" suser="$3" spass="$4" rhttp="$5" node_id="$6"

    echo ""
    info "===== 远程安装 rnacos → ${host}:${rhttp} (id=${node_id}) ====="

    local old_port="$SSH_PORT" old_user="$SSH_USER" old_pass="$SSH_PASSWORD"
    with_node_ssh "$host" "$sport" "$suser" "$spass"

    ssh_cmd "$host" "echo SSH_OK && command -v systemctl >/dev/null && echo HAS_SYSTEMD=1" || {
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 1
    }

    if ! disable_remote_selinux "$host"; then
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 1
    fi

    if [ -z "$RNACOS_TGZ" ] || [ ! -f "$RNACOS_TGZ" ]; then
        ensure_package_tgz || {
            SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
            return 1
        }
    fi

    local tgz_name
    tgz_name=$(basename "$RNACOS_TGZ")
    local rgrpc=$((rhttp + 1000))
    local rconsole=$((rhttp + 2000))

    info "上传脚本与安装包..."
    ssh_cmd "$host" "mkdir -p /tmp/rnacos_cluster_install/rnacos/package" || true
    scp_to_remote "$PARENT_DIR/lib_common.sh" "$host" "/tmp/rnacos_cluster_install/lib_common.sh" || {
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"; return 1
    }
    scp_to_remote "$INSTALL_SCRIPT" "$host" "/tmp/rnacos_cluster_install/rnacos/install_rnacos.sh" || {
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"; return 1
    }
    scp_to_remote "$RNACOS_TGZ" "$host" "/tmp/rnacos_cluster_install/rnacos/package/${tgz_name}" || {
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"; return 1
    }

    info "远程执行无人值守安装（join 首节点）..."
    local remote_cmd="cd /tmp/rnacos_cluster_install/rnacos && bash install_rnacos.sh --cluster --version '${RNACOS_VERSION}' --http-port '${rhttp}' --grpc-port '${rgrpc}' --console-port '${rconsole}' --node-id '${node_id}' --node-addr '${host}:${rgrpc}' --join-addr '${FIRST_NODE_ADDR}'"

    if ssh_cmd "$host" "$remote_cmd"; then
        success "${host} rnacos 安装并加入集群完成"
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 0
    fi

    warn "${host} rnacos 安装失败"
    SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
    return 1
}

# ======================== 状态检查 ========================

check_cluster_status() {
    echo ""
    info "===== rnacos 集群状态 ====="

    if [ -f "$CLUSTER_STATE_FILE" ]; then
        # shellcheck source=/dev/null
        . "$CLUSTER_STATE_FILE"
    fi

    info "首节点 Raft: $FIRST_NODE_ADDR"

    if [ "$INCLUDE_LOCAL_NODE" = "yes" ]; then
        echo -n "  本机 ${LOCAL_NODE_IP} http=${HTTP_PORT}: "
        if systemctl is-active --quiet rnacos 2>/dev/null; then
            echo -e "${GREEN}active${NC}"
        else
            echo -e "${RED}inactive${NC}"
        fi
    fi

    local item h p u pw rp nid
    for item in "${REMOTE_NODES[@]}"; do
        IFS='|' read -r h p u pw rp nid <<< "$item"
        local old_port="$SSH_PORT" old_user="$SSH_USER" old_pass="$SSH_PASSWORD"
        with_node_ssh "$h" "$p" "$u" "$pw"
        echo -n "  远程 ${h}:${rp} (id=${nid}): "
        local st
        st=$(ssh_cmd "$h" "systemctl is-active rnacos 2>/dev/null || echo inactive")
        if [ "$st" = "active" ]; then
            echo -e "${GREEN}active${NC}"
        else
            echo -e "${YELLOW}${st}${NC}"
        fi
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
    done

    echo ""
    info "控制台: http://${LOCAL_NODE_IP:-<节点IP>}:${CONSOLE_PORT}/rnacos/  (admin/admin)"
    info "Raft 通信端口 = gRPC 端口（默认 HTTP+1000），请确保互通"
}

# ======================== 一键部署 ========================

one_click_deploy() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${GREEN}一键 rnacos 集群部署（Raft）${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo "流程: 本机首节点 auto-init → 打包同步 → 远程 join 首节点 → 校验"
    echo "要求: 无 Java、无外部数据库；建议 3 节点；gRPC 端口互通"
    echo ""

    confirm_action "开始一键部署?" || return 1

    collect_ssh_info
    collect_cluster_config
    collect_remote_nodes

    echo ""
    info "部署摘要:"
    info "  版本: $RNACOS_VERSION"
    info "  HTTP/gRPC/控制台: $HTTP_PORT / $GRPC_PORT / $CONSOLE_PORT"
    info "  本机节点: $INCLUDE_LOCAL_NODE  IP=$LOCAL_NODE_IP  id=$LOCAL_NODE_ID"
    info "  首节点 Raft: $FIRST_NODE_ADDR"
    info "  远程节点数: ${#REMOTE_NODES[@]}"
    confirm_action "确认开始部署?" || return 1

    # A. 安装包
    echo ""
    info "===== 步骤 A: 准备安装包 ====="
    ensure_package_tgz || confirm_action "无安装包，远程将自行下载。继续?" || return 1

    # B. 本机首节点
    if [ "$INCLUDE_LOCAL_NODE" = "yes" ]; then
        echo ""
        info "===== 步骤 B: 本机首节点 auto-init ====="
        install_local_rnacos
    fi

    # C. 远程 join
    local failed=0 idx=1
    for item in "${REMOTE_NODES[@]}"; do
        IFS='|' read -r h p u pw rp nid <<< "$item"
        echo ""
        info "===== 步骤 C.${idx}: ${h}:${rp} join ====="
        remote_install_rnacos "$h" "$p" "$u" "$pw" "$rp" "$nid" || failed=$((failed+1))
        idx=$((idx+1))
    done

    save_cluster_state

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}rnacos 集群部署结束${NC}"
    echo -e "${GREEN}========================================${NC}"
    info "成功: $(( ${#REMOTE_NODES[@]} - failed )) / ${#REMOTE_NODES[@]}"
    [ $failed -gt 0 ] && warn "失败 $failed 个"
    echo ""
    info "后续: bash $0 status"
    info "控制台: http://${LOCAL_NODE_IP}:${CONSOLE_PORT}/rnacos/"
    echo ""

    check_cluster_status
    return 0
}

# ======================== 帮助/菜单 ========================

show_help() {
    cat <<EOF
rnacos 集群一键部署脚本（Raft）

用法: bash setup_rnacos_cluster.sh [命令]

命令:
  one       一键部署（本机首节点 + SSH远程 join）
  status    查看节点状态
  help      帮助

说明:
  - 无需 Java / 外部数据库
  - 首节点 --auto-init，其余 --join-addr 指向首节点 gRPC 地址
  - 每个节点 node-id 唯一
  - 节点间 gRPC 端口（默认 HTTP+1000）必须互通
  - 建议 3 节点（Raft 多数派）
EOF
}

show_main_menu() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${GREEN}rnacos 集群配置工具${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo "本机IP: $(get_local_ip)"
    echo ""
    echo "请选择操作:"
    echo ""
    echo -e "  ${GREEN}1. 一键部署 rnacos 集群${NC}（SSH远程）"
    echo "  2. 查看集群状态"
    echo "  3. 帮助"
    echo "  q. 退出"
    echo ""
    read -rp "请选择 [1-3/q]: " choice
    case "$choice" in
        1) one_click_deploy ;;
        2) check_cluster_status ;;
        3) show_help ;;
        q|Q) exit 0 ;;
        *) warn "无效选择" ;;
    esac
}

main() {
    if [ $# -gt 0 ]; then
        case "$1" in
            one|deploy|cluster) one_click_deploy ;;
            status) check_cluster_status ;;
            help|-h|--help) show_help ;;
            *)
                echo "未知参数: $1"
                echo "使用 '$0 help'"
                exit 1
                ;;
        esac
        return
    fi
    while true; do
        show_main_menu
        echo ""
        read -rp "按回车返回主菜单... " -r
    done
}

main "$@"
