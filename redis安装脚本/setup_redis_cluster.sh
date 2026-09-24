#!/bin/bash

# Redis Cluster 一键部署脚本
# 支持：本机作为集群节点之一，SSH 远程安装其余节点，SCP 分发安装包，最后 redis-cli --cluster create
# 兼容 Ubuntu 22/24、Debian 12、CentOS Stream/Rocky/AlmaLinux 8/9

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

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

if [ -z "$BASH_VERSION" ]; then
    echo -e "${RED}错误: 请使用bash执行此脚本${NC}"
    echo "正确用法: bash setup_redis_cluster.sh"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}此脚本需要以root权限运行${NC}"
   exit 1
fi

# ======================== 全局变量 ========================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="$SCRIPT_DIR/install_redis.sh"
INSTALL_CONFIG="/etc/redis_install.conf"
CLUSTER_STATE_FILE="/etc/redis_cluster_deploy.conf"

if [ -f "$INSTALL_CONFIG" ]; then
    # shellcheck source=/dev/null
    . "$INSTALL_CONFIG"
fi

: "${REDIS_INSTALL_DIR:=/usr/local/redis}"
: "${REDIS_DATA_DIR:=/var/lib/redis}"
: "${REDIS_LOG_DIR:=/var/log/redis}"
: "${REDIS_CONF_DIR:=/etc/redis}"
: "${REDIS_RUN_DIR:=/run/redis}"
: "${REDIS_PORT:=6379}"
: "${REDIS_PASSWORD:=}"
: "${REDIS_VERSION:=7.2.4}"
: "${REDIS_BIND:=0.0.0.0}"

# 集群
CLUSTER_NAME="mycluster"
CLUSTER_REPLICAS=1
CLUSTER_NODE_TIMEOUT="5000"
LOCAL_NODE_PORT="$REDIS_PORT"

# 本机是否作为集群节点
INCLUDE_LOCAL_NODE="yes"

# 节点列表: ip|ssh_port|ssh_user|ssh_pass|redis_port|redis_pass
CLUSTER_NODES=()

# SSH
SSH_USER="root"
SSH_PORT="22"
SSH_PASSWORD=""
SSH_KEY=""
SSH_OPTS=""

REDIS_PACK_TGZ=""

# ======================== 工具 ========================

info()    { echo -e "${CYAN}[INFO] $1${NC}"; }
success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }
warn()    { echo -e "${YELLOW}[WARN] $1${NC}"; }
error()   { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

print_title() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${GREEN}$1${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""
}

confirm_action() {
    local message="$1"
    local default="${2:-N}"
    local hint="是否继续? [y/N]: "
    if [[ "$default" =~ ^[Yy]$ ]]; then
        hint="是否继续? [Y/n]: "
    fi
    echo -e "${YELLOW}$message${NC}"
    read -p "$hint" confirm
    if [[ -z "$confirm" ]]; then
        confirm="$default"
    fi
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}操作已取消${NC}"
        return 1
    fi
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

# ======================== SSH ========================

ensure_ssh_tools() {
    if ! command -v ssh >/dev/null 2>&1 || ! command -v scp >/dev/null 2>&1; then
        error "未找到 ssh/scp"
    fi
    if [ -n "$SSH_PASSWORD" ] && ! command -v sshpass >/dev/null 2>&1; then
        warn "尝试安装 sshpass..."
        detect_sys_pkg
        sys_pkg_install "sshpass" >/dev/null 2>&1 || true
        command -v sshpass >/dev/null 2>&1 || error "sshpass 不可用，请配置 SSH 免密"
    fi
}

build_ssh_opts() {
    SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -p $SSH_PORT"
    if [ -n "$SSH_KEY" ]; then
        SSH_OPTS="$SSH_OPTS -i $SSH_KEY"
    fi
}

ssh_cmd() {
    local host="$1"
    shift
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
    SSH_PORT="$2"
    SSH_USER="$3"
    SSH_PASSWORD="$4"
}

test_ssh_connection() {
    local host="$1"
    info "测试 SSH ${SSH_USER}@${host}:${SSH_PORT} ..."
    ssh_cmd "$host" "echo SSH_OK && uname -m" || return 1
    success "SSH OK: $host"
    return 0
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

# ======================== 安装包 ========================

check_redis_installed() {
    if [ -f "$INSTALL_CONFIG" ]; then
        # shellcheck source=/dev/null
        . "$INSTALL_CONFIG"
    fi
    if [ -f "$REDIS_INSTALL_DIR/bin/redis-server" ] && [ -f "$REDIS_INSTALL_DIR/bin/redis-cli" ]; then
        return 0
    fi
    return 1
}

ensure_package_tgz() {
    local pack_dir="$SCRIPT_DIR/package"
    mkdir -p "$pack_dir"

    local existing
    existing=$(find "$pack_dir" -maxdepth 1 -type f -name 'redis-*.tar.gz' 2>/dev/null | head -1)
    if [ -n "$existing" ] && [ -f "$existing" ]; then
        REDIS_PACK_TGZ="$existing"
        info "使用已有包: $REDIS_PACK_TGZ"
        return 0
    fi

    if [ ! -f "$REDIS_INSTALL_DIR/bin/redis-server" ]; then
        warn "本机无 Redis，package/ 也无可用包"
        return 1
    fi

    local pack_name="redis-${REDIS_VERSION}-linux-$(uname -m).tar.gz"
    info "打包本机安装目录..."
    tar zcf "${pack_dir}/${pack_name}" -C "$(dirname "$REDIS_INSTALL_DIR")" "$(basename "$REDIS_INSTALL_DIR")"
    REDIS_PACK_TGZ="${pack_dir}/${pack_name}"
    success "打包完成: $REDIS_PACK_TGZ"
    return 0
}

install_local_redis() {
    print_title "本机安装 Redis（Cluster 节点）"

    if [ ! -f "$INSTALL_SCRIPT" ]; then
        error "未找到 $INSTALL_SCRIPT"
    fi

    if check_redis_installed; then
        info "本机已安装 Redis"
        if confirm_action "是否跳过安装直接配置 Cluster 实例?" "Y"; then
            return 0
        fi
    fi

    local port="${LOCAL_NODE_PORT}"
    read -p "本机 Cluster 节点端口 [$port]: " input
    port=${input:-$port}
    LOCAL_NODE_PORT="$port"
    REDIS_PORT="$port"

    if [ -n "$REDIS_PASSWORD" ]; then
        info "使用已配置密码"
    else
        read -s -p "Redis 密码 (全集群统一，留空不设置): " REDIS_PASSWORD
        echo ""
    fi

    local cmd=(bash "$INSTALL_SCRIPT" --batch --cluster \
        --install-dir "$REDIS_INSTALL_DIR" \
        --port "$port" \
        --cluster-node-timeout "$CLUSTER_NODE_TIMEOUT" \
        --skip-start)

    if [ -n "$REDIS_PASSWORD" ]; then
        cmd+=(--password "$REDIS_PASSWORD")
    fi
    local local_tgz
    local_tgz=$(find "$SCRIPT_DIR/package" -maxdepth 1 -type f -name 'redis-*.tar.gz' 2>/dev/null | head -1)
    if [ -n "$local_tgz" ]; then
        cmd+=(--tgz "$local_tgz")
    fi

    info "执行: ${cmd[*]}"
    "${cmd[@]}" || error "本机安装失败"

    if [ -f "$INSTALL_CONFIG" ]; then
        # shellcheck source=/dev/null
        . "$INSTALL_CONFIG"
    fi
    check_redis_installed || error "安装后未找到 redis-server"
    return 0
}

# ======================== 本机 Cluster 实例 ========================

write_instance_service() {
    cat > /etc/systemd/system/redis@.service << EOF
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
    systemctl daemon-reload
}

configure_local_cluster_node() {
    print_title "配置本机为 Cluster 节点"

    check_redis_installed || install_local_redis || return 1

    local local_ip
    local_ip=$(get_local_ip)

    read -p "本机节点 Redis 端口 [${LOCAL_NODE_PORT}]: " input
    LOCAL_NODE_PORT=${input:-$LOCAL_NODE_PORT}

    if [ -z "$REDIS_PASSWORD" ]; then
        read -s -p "集群统一密码 (留空不设置): " REDIS_PASSWORD
        echo ""
    fi

    echo ""
    info "本机节点: ${local_ip}:${LOCAL_NODE_PORT}"
    info "密码: ${REDIS_PASSWORD:-(未设置)}"
    confirm_action "确认配置本机 Cluster 节点?" || return 1

    mkdir -p "$REDIS_DATA_DIR/redis_${LOCAL_NODE_PORT}" "$REDIS_LOG_DIR" "$REDIS_RUN_DIR" "$REDIS_CONF_DIR"
    generate_local_cluster_conf "$LOCAL_NODE_PORT" "$local_ip"
    write_instance_service

    systemctl enable --now "redis@${LOCAL_NODE_PORT}" >/dev/null 2>&1
    sleep 2
    if systemctl is-active --quiet "redis@${LOCAL_NODE_PORT}"; then
        success "本机 redis@${LOCAL_NODE_PORT} 已启动（cluster-enabled）"
    else
        warn "启动失败: journalctl -u redis@${LOCAL_NODE_PORT} -n 30"
        return 1
    fi
    return 0
}

generate_local_cluster_conf() {
    local port="$1"
    local announce_ip="$2"
    local conf="$REDIS_CONF_DIR/redis_${port}.conf"

    cat > "$conf" << EOF
# Redis Cluster node - setup_redis_cluster.sh
port $port
bind $REDIS_BIND
protected-mode no
daemonize yes
pidfile $REDIS_RUN_DIR/redis_$port.pid
loglevel notice
logfile $REDIS_LOG_DIR/redis_$port.log
dir $REDIS_DATA_DIR/redis_$port

save 900 1
save 300 10
save 60 10000
rdbcompression yes
dbfilename dump_$port.rdb

cluster-enabled yes
cluster-config-file nodes-$port.conf
cluster-node-timeout $CLUSTER_NODE_TIMEOUT
cluster-require-full-coverage no
cluster-migration-barrier 1
cluster-announce-ip $announce_ip
cluster-announce-port $port
cluster-announce-bus-port $((port + 10000))
EOF

    if [ -n "$REDIS_PASSWORD" ]; then
        echo "requirepass $REDIS_PASSWORD" >> "$conf"
        echo "masterauth $REDIS_PASSWORD" >> "$conf"
    fi

    chown -R redis:redis "$conf" "$REDIS_DATA_DIR/redis_${port}"
    success "生成配置: $conf"
}

# ======================== 收集节点 ========================

collect_ssh_info() {
    print_title "SSH 远程连接信息"

    read -p "SSH 用户名 [root]: " input
    SSH_USER=${input:-root}
    read -p "SSH 端口 [22]: " input
    SSH_PORT=${input:-22}

    echo "认证方式:"
    echo "1. SSH 密码（sshpass）"
    echo "2. SSH 私钥"
    read -p "请选择 [1/2]: " auth_choice
    case "$auth_choice" in
        2)
            read -p "私钥路径 [~/.ssh/id_rsa]: " input
            SSH_KEY=${input:-$HOME/.ssh/id_rsa}
            SSH_KEY="${SSH_KEY/#\~/$HOME}"
            SSH_PASSWORD=""
            ;;
        *)
            read -s -p "SSH 密码: " SSH_PASSWORD
            echo ""
            SSH_KEY=""
            ;;
    esac
    ensure_ssh_tools
}

collect_cluster_nodes() {
    print_title "添加 Cluster 节点"

    echo -e "${CYAN}Redis Cluster 至少 3 主；带副本建议 6 节点（3主+3从）${NC}"
    echo "每台机器一个 Redis 实例（也可同机多端口，用不同 IP:端口）"
    echo ""

    read -p "本机是否也作为集群节点? [Y/n]: " inc_local
    if [[ "$inc_local" =~ ^[Nn]$ ]]; then
        INCLUDE_LOCAL_NODE="no"
    else
        INCLUDE_LOCAL_NODE="yes"
        local lip
        lip=$(get_local_ip)
        info "本机节点: ${lip}:${LOCAL_NODE_PORT}（稍后可改端口）"
    fi

    CLUSTER_NODES=()
    local idx=1
    while true; do
        echo ""
        read -p "节点 #${idx} IP/主机名 (空结束): " host
        [ -z "$host" ] && break

        local sport="$SSH_PORT"
        local suser="$SSH_USER"
        local spass="$SSH_PASSWORD"
        local rport="6379"
        local rpass="$REDIS_PASSWORD"
        local custom

        read -p "  SSH端口 [$SSH_PORT]: " custom
        sport=${custom:-$sport}
        read -p "  SSH用户 [$SSH_USER]: " custom
        suser=${custom:-$suser}

        if [ -n "$SSH_PASSWORD" ]; then
            read -p "  使用全局SSH密码? [Y/n]: " ug
            if [[ "$ug" =~ ^[Nn]$ ]]; then
                read -s -p "  SSH密码: " spass
                echo ""
            fi
        else
            read -p "  使用全局SSH密钥? [Y/n]: " ug
            if [[ "$ug" =~ ^[Nn]$ ]]; then
                read -s -p "  SSH密码: " spass
                echo ""
            else
                spass=""
            fi
        fi

        read -p "  Redis端口 [6379]: " custom
        rport=${custom:-6379}
        if [ -n "$REDIS_PASSWORD" ]; then
            read -p "  使用集群统一密码? [Y/n]: " ug
            if [[ "$ug" =~ ^[Nn]$ ]]; then
                read -s -p "  Redis密码: " rpass
                echo ""
            fi
        else
            read -s -p "  Redis密码 (留空不设置): " rpass
            echo ""
        fi

        CLUSTER_NODES+=("${host}|${sport}|${suser}|${spass}|${rport}|${rpass}")
        success "已添加节点: ${host}:${rport}"
        idx=$((idx+1))
    done

    # 汇总数量
    local total=${#CLUSTER_NODES[@]}
    if [ "$INCLUDE_LOCAL_NODE" = "yes" ]; then
        total=$((total + 1))
    fi

    if [ "$total" -lt 3 ]; then
        warn "当前节点数=$total，Cluster 至少需要 3 个节点"
        confirm_action "仍要继续吗（create 可能失败）?" || return 1
    fi

    read -p "每个主节点的副本数 replicas [默认 1]: " input
    CLUSTER_REPLICAS=${input:-1}

    # 校验: total >= 3 * (1 + replicas)
    local need=$(( 3 * (1 + CLUSTER_REPLICAS) ))
    if [ "$total" -lt "$need" ]; then
        warn "节点数=$total，replicas=$CLUSTER_REPLICAS 时建议至少 $need 个节点"
        confirm_action "仍继续?（Redis 可能自动调整或失败）" || return 1
    fi

    echo ""
    info "Cluster 汇总:"
    info "  本机节点: $INCLUDE_LOCAL_NODE  port=$LOCAL_NODE_PORT"
    info "  远程节点数: ${#CLUSTER_NODES[@]}"
    info "  总节点数: $total"
    info "  replicas: $CLUSTER_REPLICAS"
    local n=1
    if [ "$INCLUDE_LOCAL_NODE" = "yes" ]; then
        echo "  $n. $(get_local_ip):${LOCAL_NODE_PORT} (local)"
        n=$((n+1))
    fi
    for item in "${CLUSTER_NODES[@]}"; do
        IFS='|' read -r h _ _ _ rp _ <<< "$item"
        echo "  $n. $h:$rp"
        n=$((n+1))
    done
    return 0
}

save_cluster_state() {
    {
        echo "# Redis Cluster deploy state - $(date)"
        echo "CLUSTER_NAME=$CLUSTER_NAME"
        echo "CLUSTER_REPLICAS=$CLUSTER_REPLICAS"
        echo "CLUSTER_NODE_TIMEOUT=$CLUSTER_NODE_TIMEOUT"
        echo "REDIS_PASSWORD=$REDIS_PASSWORD"
        echo "REDIS_INSTALL_DIR=$REDIS_INSTALL_DIR"
        echo "LOCAL_NODE_PORT=$LOCAL_NODE_PORT"
        echo "INCLUDE_LOCAL_NODE=$INCLUDE_LOCAL_NODE"
        echo "SSH_USER=$SSH_USER"
        echo "SSH_PORT=$SSH_PORT"
        echo "SSH_KEY=$SSH_KEY"
        echo "REDIS_PACK_TGZ=$REDIS_PACK_TGZ"
        echo "CLUSTER_NODES_STR=${CLUSTER_NODES[*]}"
    } > "$CLUSTER_STATE_FILE"
    chmod 600 "$CLUSTER_STATE_FILE"
    success "部署状态: $CLUSTER_STATE_FILE"
}

load_cluster_state() {
    if [ -f "$CLUSTER_STATE_FILE" ]; then
        # shellcheck source=/dev/null
        . "$CLUSTER_STATE_FILE"
        if [ -n "$CLUSTER_NODES_STR" ]; then
            read -r -a CLUSTER_NODES <<< "$CLUSTER_NODES_STR"
        fi
        return 0
    fi
    return 1
}

# ======================== 远程安装 ========================

remote_install_cluster_node() {
    local host="$1" sport="$2" suser="$3" spass="$4" rport="$5" rpass="$6"

    print_title "远程安装 Cluster 节点 → ${host}:${rport}"

    local old_port="$SSH_PORT" old_user="$SSH_USER" old_pass="$SSH_PASSWORD"
    with_node_ssh "$host" "$sport" "$suser" "$spass"

    test_ssh_connection "$host" || {
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 1
    }

    if ssh_cmd "$host" "command -v systemctl >/dev/null"; then
        :
    else
        warn "远程无 systemd"
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 1
    fi

    if ! disable_remote_selinux "$host"; then
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 1
    fi

    if [ -z "$REDIS_PACK_TGZ" ] || [ ! -f "$REDIS_PACK_TGZ" ]; then
        ensure_package_tgz || {
            SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
            return 1
        }
    fi

    local tgz_name
    tgz_name=$(basename "$REDIS_PACK_TGZ")

    info "上传脚本与安装包..."
    ssh_cmd "$host" "mkdir -p /tmp/redis_cluster_install" || true
    scp_to_remote "$INSTALL_SCRIPT" "$host" "/tmp/redis_cluster_install/install_redis.sh" || {
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 1
    }
    scp_to_remote "$REDIS_PACK_TGZ" "$host" "/tmp/${tgz_name}" || {
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 1
    }

    info "远程执行 batch 安装..."
    local cmd="bash /tmp/redis_cluster_install/install_redis.sh --batch --cluster --tgz /tmp/${tgz_name} --install-dir '${REDIS_INSTALL_DIR}' --port '${rport}' --cluster-node-timeout ${CLUSTER_NODE_TIMEOUT} --skip-start"
    if [ -n "$rpass" ]; then
        cmd="${cmd} --password '${rpass}'"
    fi

    if ssh_cmd "$host" "$cmd"; then
        success "${host} 安装完成"
        ssh_cmd "$host" "rm -f /tmp/${tgz_name}" >/dev/null 2>&1 || true
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 0
    fi

    warn "${host} 安装失败"
    SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
    return 1
}

# 远程生成配置并启动（即使 install 已写配置，这里再确保 announce IP 正确）
remote_start_cluster_node() {
    local host="$1" sport="$2" suser="$3" spass="$4" rport="$5" rpass="$6"

    print_title "启动远程 Cluster 节点 ${host}:${rport}"

    local old_port="$SSH_PORT" old_user="$SSH_USER" old_pass="$SSH_PASSWORD"
    with_node_ssh "$host" "$sport" "$suser" "$spass"

    local remote_state remote_install_dir remote_conf_dir remote_data_dir remote_log_dir remote_run_dir
    remote_state=$(ssh_cmd "$host" "cat /etc/redis_install.conf 2>/dev/null")
    remote_install_dir=$(echo "$remote_state" | grep '^REDIS_INSTALL_DIR=' | cut -d= -f2-)
    remote_conf_dir=$(echo "$remote_state" | grep '^REDIS_CONF_DIR=' | cut -d= -f2-)
    remote_data_dir=$(echo "$remote_state" | grep '^REDIS_DATA_DIR=' | cut -d= -f2-)
    remote_log_dir=$(echo "$remote_state" | grep '^REDIS_LOG_DIR=' | cut -d= -f2-)
    remote_run_dir=$(echo "$remote_state" | grep '^REDIS_RUN_DIR=' | cut -d= -f2-)

    remote_install_dir=${remote_install_dir:-$REDIS_INSTALL_DIR}
    remote_conf_dir=${remote_conf_dir:-/etc/redis}
    remote_data_dir=${remote_data_dir:-/var/lib/redis}
    remote_log_dir=${remote_log_dir:-/var/log/redis}
    remote_run_dir=${remote_run_dir:-/run/redis}

    # announce 使用连接用的 host（若是 IP 则原样；主机名可能需解析）
    local announce_ip="$host"
    local bus_port=$((rport + 10000))

    local conf_local="/tmp/redis_cluster_${host}_${rport}.conf"
    cat > "$conf_local" << EOF
port ${rport}
bind 0.0.0.0
protected-mode no
daemonize yes
pidfile ${remote_run_dir}/redis_${rport}.pid
loglevel notice
logfile ${remote_log_dir}/redis_${rport}.log
dir ${remote_data_dir}/redis_${rport}

save 900 1
save 300 10
save 60 10000
rdbcompression yes
dbfilename dump_${rport}.rdb

cluster-enabled yes
cluster-config-file nodes-${rport}.conf
cluster-node-timeout ${CLUSTER_NODE_TIMEOUT}
cluster-require-full-coverage no
cluster-migration-barrier 1
cluster-announce-ip ${announce_ip}
cluster-announce-port ${rport}
cluster-announce-bus-port ${bus_port}
EOF
    if [ -n "$rpass" ]; then
        echo "requirepass ${rpass}" >> "$conf_local"
        echo "masterauth ${rpass}" >> "$conf_local"
    fi

    scp_to_remote "$conf_local" "$host" "/tmp/redis_cluster_node.conf" || {
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 1
    }

    ssh_cmd "$host" "bash -s" << REMOTE
set -e
mkdir -p '${remote_conf_dir}' '${remote_data_dir}/redis_${rport}' '${remote_log_dir}' '${remote_run_dir}'
# 清理旧 cluster 状态，保证可重新 create
rm -f '${remote_data_dir}/redis_${rport}/nodes-${rport}.conf' \
      '${remote_data_dir}/redis_${rport}/nodes-${rport}.conf.bak' 2>/dev/null || true

cp /tmp/redis_cluster_node.conf '${remote_conf_dir}/redis_${rport}.conf'
id redis >/dev/null 2>&1 || useradd -r -s /sbin/nologin redis
chown -R redis:redis '${remote_data_dir}' '${remote_log_dir}' '${remote_run_dir}' '${remote_conf_dir}'

cat > /etc/systemd/system/redis@.service << SVC
[Unit]
Description=Redis In-Memory Data Store (port %i)
After=network.target

[Service]
Type=forking
User=redis
Group=redis
PIDFile=${remote_run_dir}/redis_%i.pid
ExecStart=${remote_install_dir}/bin/redis-server ${remote_conf_dir}/redis_%i.conf
ExecStop=${remote_install_dir}/bin/redis-cli -p %i shutdown
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable --now redis@${rport}
sleep 2
systemctl is-active --quiet redis@${rport}
REMOTE

    local rc=$?
    if [ $rc -eq 0 ]; then
        success "远程节点 ${host}:${rport} 已启动"
    else
        warn "远程节点 ${host}:${rport} 启动失败"
    fi
    SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
    return $rc
}

# ======================== 创建集群 ========================

build_cluster_endpoints() {
    # 输出 create 用的 ip:port 列表，空格分隔
    local endpoints=()
    if [ "$INCLUDE_LOCAL_NODE" = "yes" ]; then
        local lip
        lip=$(get_local_ip)
        endpoints+=("${lip}:${LOCAL_NODE_PORT}")
    fi
    for item in "${CLUSTER_NODES[@]}"; do
        IFS='|' read -r h _ _ _ rp _ <<< "$item"
        endpoints+=("${h}:${rp}")
    done
    echo "${endpoints[*]}"
}

create_redis_cluster() {
    print_title "创建 Redis Cluster"

    local endpoints
    endpoints=$(build_cluster_endpoints)
    if [ -z "$endpoints" ]; then
        error "没有可用节点端点"
    fi

    local count
    count=$(echo "$endpoints" | wc -w)
    info "节点端点($count): $endpoints"
    info "replicas=$CLUSTER_REPLICAS"

    if [ "$count" -lt 3 ]; then
        error "端点少于 3，无法创建 Cluster"
    fi

    local auth_args=()
    if [ -n "$REDIS_PASSWORD" ]; then
        auth_args=(-a "$REDIS_PASSWORD" --no-auth-warning)
    fi

    local cli="$REDIS_INSTALL_DIR/bin/redis-cli"
    if [ ! -x "$cli" ]; then
        cli="redis-cli"
    fi

    info "等待各节点就绪..."
    local ep
    for ep in $endpoints; do
        local ip=${ep%:*}
        local port=${ep#*:}
        local pass="$REDIS_PASSWORD"
        # 远程节点密码可能不同，尝试从列表匹配
        for item in "${CLUSTER_NODES[@]}"; do
            IFS='|' read -r h _ _ _ rp rpw <<< "$item"
            if [ "$h" = "$ip" ] && [ "$rp" = "$port" ]; then
                pass=${rpw:-$REDIS_PASSWORD}
            fi
        done

        local try=0
        local ok=0
        while [ $try -lt 15 ]; do
            if [ -n "$pass" ]; then
                if $cli -h "$ip" -p "$port" -a "$pass" --no-auth-warning ping 2>/dev/null | grep -q PONG; then
                    ok=1; break
                fi
            else
                if $cli -h "$ip" -p "$port" ping 2>/dev/null | grep -q PONG; then
                    ok=1; break
                fi
            fi
            sleep 1
            try=$((try+1))
        done
        if [ $ok -eq 1 ]; then
            success "就绪: $ep"
        else
            warn "节点无响应: $ep"
        fi
    done

    echo ""
    info "执行 redis-cli --cluster create ..."
    # --cluster-yes 避免交互确认
    local create_out
    if [ -n "$REDIS_PASSWORD" ]; then
        create_out=$($cli ${auth_args[@]} --cluster create $endpoints --cluster-replicas "$CLUSTER_REPLICAS" --cluster-yes 2>&1)
    else
        create_out=$($cli --cluster create $endpoints --cluster-replicas "$CLUSTER_REPLICAS" --cluster-yes 2>&1)
    fi
    echo "$create_out"

    if echo "$create_out" | grep -qiE "\[OK\] All .* slots covered|All 16384 slots covered"; then
        success "Cluster 创建成功"
        return 0
    fi

    # 有时 create 输出含警告但仍成功，再查 cluster info
    sleep 2
    local first_ep=${endpoints%% *}
    local fip=${first_ep%:*}
    local fport=${first_ep#*:}
    local info_out
    if [ -n "$REDIS_PASSWORD" ]; then
        info_out=$($cli -h "$fip" -p "$fport" -a "$REDIS_PASSWORD" --no-auth-warning cluster info 2>/dev/null)
    else
        info_out=$($cli -h "$fip" -p "$fport" cluster info 2>/dev/null)
    fi
    echo "$info_out"
    if echo "$info_out" | grep -q "cluster_state:ok"; then
        success "Cluster 状态 ok"
        return 0
    fi

    warn "Cluster 创建可能失败，请检查上方输出"
    return 1
}

# ======================== 状态检查 ========================

check_cluster_status() {
    print_title "检查 Redis Cluster 状态"

    load_cluster_state || true
    if [ -f "$INSTALL_CONFIG" ]; then
        # shellcheck source=/dev/null
        . "$INSTALL_CONFIG"
    fi

    local cli="$REDIS_INSTALL_DIR/bin/redis-cli"
    [ -x "$cli" ] || cli="redis-cli"

    local endpoints
    endpoints=$(build_cluster_endpoints)

    local first_ep=${endpoints%% *}
    local fip=${first_ep%:*}
    local fport=${first_ep#*:}

    echo -e "${CYAN}探测节点...${NC}"
    local ep pass
    for ep in $endpoints; do
        local ip=${ep%:*}
        local port=${ep#*:}
        pass="$REDIS_PASSWORD"
        for item in "${CLUSTER_NODES[@]}"; do
            IFS='|' read -r h _ _ _ rp rpw <<< "$item"
            if [ "$h" = "$ip" ] && [ "$rp" = "$port" ]; then
                pass=${rpw:-$REDIS_PASSWORD}
            fi
        done
        if [ -n "$pass" ]; then
            $cli -h "$ip" -p "$port" -a "$pass" --no-auth-warning ping 2>/dev/null | sed "s/^/  $ep PING: /"
        else
            $cli -h "$ip" -p "$port" ping 2>/dev/null | sed "s/^/  $ep PING: /"
        fi
    done

    echo ""
    echo -e "${CYAN}Cluster Info (${fip}:${fport})${NC}"
    if [ -n "$REDIS_PASSWORD" ]; then
        $cli -h "$fip" -p "$fport" -a "$REDIS_PASSWORD" --no-auth-warning cluster info 2>/dev/null | sed 's/^/  /'
        echo ""
        echo -e "${CYAN}Cluster Nodes${NC}"
        $cli -h "$fip" -p "$fport" -a "$REDIS_PASSWORD" --no-auth-warning cluster nodes 2>/dev/null | sed 's/^/  /'
    else
        $cli -h "$fip" -p "$fport" cluster info 2>/dev/null | sed 's/^/  /'
        echo ""
        echo -e "${CYAN}Cluster Nodes${NC}"
        $cli -h "$fip" -p "$fport" cluster nodes 2>/dev/null | sed 's/^/  /'
    fi
}

# ======================== 一键部署 ========================

one_click_deploy() {
    print_title "一键 Redis Cluster 部署"

    echo -e "${CYAN}流程:${NC}"
    echo "  1. 本机安装 Redis（cluster-enabled）"
    echo "  2. 打包安装目录并 scp 到各远程节点"
    echo "  3. SSH 无人值守安装并启动各节点"
    echo "  4. redis-cli --cluster create 组成分片集群"
    echo "  5. 校验 cluster_state / slots"
    echo ""
    echo -e "${YELLOW}说明: Cluster 总线端口 = Redis端口 + 10000，请放行防火墙${NC}"
    echo ""

    confirm_action "开始一键部署 Cluster?" || return 1

    collect_ssh_info || return 1
    collect_cluster_nodes || return 1

    read -p "节点故障判定超时 ms [${CLUSTER_NODE_TIMEOUT}]: " input
    CLUSTER_NODE_TIMEOUT=${input:-$CLUSTER_NODE_TIMEOUT}

    # A. 本机
    echo ""
    echo -e "${YELLOW}===== 步骤 A: 本机节点 =====${NC}"
    install_local_redis || return 1
    if [ "$INCLUDE_LOCAL_NODE" = "yes" ]; then
        configure_local_cluster_node || return 1
    else
        info "本机不作为数据节点，仅用于编排"
    fi

    # B. 打包
    echo ""
    echo -e "${YELLOW}===== 步骤 B: 打包分发 =====${NC}"
    ensure_package_tgz || confirm_action "打包失败，远程可能装不上。继续?" || return 1

    # C. 远程节点
    local failed=0
    local idx=1
    for item in "${CLUSTER_NODES[@]}"; do
        IFS='|' read -r h p u pw rp rpw <<< "$item"
        echo ""
        echo -e "${YELLOW}===== 步骤 C.${idx}: 节点 ${h}:${rp} =====${NC}"
        if remote_install_cluster_node "$h" "$p" "$u" "$pw" "$rp" "$rpw"; then
            remote_start_cluster_node "$h" "$p" "$u" "$pw" "$rp" "$rpw" || failed=$((failed+1))
        else
            failed=$((failed+1))
        fi
        idx=$((idx+1))
    done

    if [ $failed -gt 0 ]; then
        warn "有 $failed 个节点安装/启动失败，create 可能不完整"
        confirm_action "是否仍尝试创建 Cluster?" || {
            save_cluster_state
            return 1
        }
    fi

    # D. 创建集群
    echo ""
    echo -e "${YELLOW}===== 步骤 D: 创建 Cluster =====${NC}"
    sleep 2
    create_redis_cluster || true

    save_cluster_state

    echo ""
    print_title "部署完成"
    info "集群节点:"
    build_cluster_endpoints | tr ' ' '\n' | sed 's/^/  /'
    info "replicas=$CLUSTER_REPLICAS"
    echo ""
    info "常用命令:"
    echo "  bash $0 status"
    echo "  $REDIS_INSTALL_DIR/bin/redis-cli -c -h <ip> -p <port> -a <pass> cluster nodes"
    echo "  注意: 客户端连接请加 -c（cluster 模式）"
    echo "  防火墙需放行: <redis_port> 与 <redis_port+10000>"
    echo ""

    check_cluster_status
    return 0
}

# ======================== 重置 ========================

reset_local_cluster() {
    print_title "重置本机 Cluster 实例"

    confirm_action "将停止本机 redis@* 并删除 cluster 配置/数据目录中的 nodes-*.conf，确认?" || return 1

    systemctl stop 'redis@*' 2>/dev/null || true
    systemctl disable 'redis@*' 2>/dev/null || true
    rm -f "$REDIS_CONF_DIR"/redis_*.conf 2>/dev/null || true
    rm -f "$REDIS_DATA_DIR"/redis_*/nodes-*.conf 2>/dev/null || true
    rm -f "$CLUSTER_STATE_FILE"
    success "本机 Cluster 配置已清理（二进制保留）"
}

# ======================== 帮助/菜单 ========================

show_help() {
    print_title "Redis Cluster 一键部署脚本"
    echo "用法: bash setup_redis_cluster.sh [命令]"
    echo ""
    echo "命令:"
    echo "  one       一键部署 Cluster（本机+SSH远程+create）"
    echo "  node      仅配置本机为 Cluster 节点"
    echo "  status    查看 Cluster 状态"
    echo "  reset     重置本机 Cluster 配置"
    echo "  install   仅本机安装 Redis(--cluster)"
    echo "  help      帮助"
    echo ""
    echo "架构:"
    echo "  最少 3 主；生产建议 3主+3从（6 节点，replicas=1）"
    echo "  总线端口 = 数据端口 + 10000"
    echo "  客户端连接: redis-cli -c -h IP -p PORT -a PASS"
}

show_main_menu() {
    print_title "Redis Cluster 配置工具"

    local lip
    lip=$(get_local_ip)
    echo -e "${CYAN}本机IP: ${lip:-未知}${NC}"
    if [ -f "$INSTALL_CONFIG" ]; then
        echo -e "${CYAN}已检测到 Redis 安装状态${NC}"
    fi
    echo ""
    echo "请选择操作:"
    echo ""
    echo -e "  ${GREEN}1. 一键部署 Redis Cluster${NC}（SSH远程安装+create）"
    echo "  2. 仅配置本机为 Cluster 节点"
    echo "  3. 查看 Cluster 状态"
    echo "  4. 重置本机 Cluster 配置"
    echo "  5. 本机安装 Redis(--cluster)"
    echo "  6. 帮助"
    echo "  q. 退出"
    echo ""
    read -p "请选择 [1-6/q]: " choice
    case "$choice" in
        1) one_click_deploy ;;
        2) configure_local_cluster_node ;;
        3) check_cluster_status ;;
        4) reset_local_cluster ;;
        5) install_local_redis ;;
        6) show_help ;;
        q|Q) exit 0 ;;
        *) warn "无效选择" ;;
    esac
}

main() {
    if [ $# -gt 0 ]; then
        case "$1" in
            one|deploy|cluster) one_click_deploy ;;
            node) configure_local_cluster_node ;;
            status) check_cluster_status ;;
            reset) reset_local_cluster ;;
            install) install_local_redis ;;
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
        read -p "按回车返回主菜单... " -r
    done
}

main "$@"
