#!/bin/bash

# Redis 主从 + Sentinel 一键部署脚本
# 支持：本机主节点、SSH 远程安装从节点/哨兵、SCP 同步安装包与配置
# 兼容 Ubuntu 22/24、Debian 12、CentOS Stream/Rocky/AlmaLinux 8/9

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

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

# 检查bash
if [ -z "$BASH_VERSION" ]; then
    echo -e "${RED}错误: 请使用bash执行此脚本${NC}"
    echo "正确用法: bash setup_redis_sentinel.sh"
    exit 1
fi

# root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}此脚本需要以root权限运行${NC}"
   exit 1
fi

# ======================== 全局变量 ========================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="$SCRIPT_DIR/install_redis.sh"
INSTALL_CONFIG="/etc/redis_install.conf"
CLUSTER_STATE_FILE="/etc/redis_cluster_state.conf"

# 加载本机安装配置
if [ -f "$INSTALL_CONFIG" ]; then
    # shellcheck source=/dev/null
    . "$INSTALL_CONFIG"
fi

# 默认目录规划与 install_redis.sh 一致：根目录 /mnt/data/redis，
# 二进制在 <根目录>/redis-<版本>，数据在 <根目录>/data（/etc/redis_install.conf 中已有值则优先使用）
: "${REDIS_HOME:=/mnt/data/redis}"
: "${REDIS_VERSION:=7.2.4}"
: "${REDIS_INSTALL_DIR:=${REDIS_HOME}/redis-${REDIS_VERSION}}"
: "${REDIS_DATA_DIR:=${REDIS_HOME}/data}"
: "${REDIS_LOG_DIR:=/var/log/redis}"
: "${REDIS_CONF_DIR:=/etc/redis}"
: "${REDIS_RUN_DIR:=/run/redis}"
: "${REDIS_PORT:=6379}"
: "${REDIS_PASSWORD:=}"
: "${REDIS_BIND:=0.0.0.0}"

# 集群角色
REDIS_ROLE=""          # master | slave
MASTER_HOST=""
MASTER_PORT="6379"
MASTER_PASSWORD=""

# Sentinel
SENTINEL_PORT="26379"
SENTINEL_QUORUM="2"
SENTINEL_DOWN_AFTER="30000"
SENTINEL_FAILOVER_TIMEOUT="180000"
SENTINEL_PARALLEL_SYNC="1"
SENTINEL_PASSWORD=""
ENABLE_SENTINEL="yes"

# SSH
SSH_USER="root"
SSH_PORT="22"
SSH_PASSWORD=""
SSH_KEY=""
SSH_OPTS=""

# 节点列表: host|ssh_port|ssh_user|ssh_pass|redis_port|redis_password
SLAVE_NODES=()
SENTINEL_NODES=()

# 打包
REDIS_PACK_TGZ=""

# ======================== 工具函数 ========================

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

# ======================== SSH 工具 ========================

ensure_ssh_tools() {
    if ! command -v ssh >/dev/null 2>&1 || ! command -v scp >/dev/null 2>&1; then
        error "未找到 ssh/scp，请先安装 openssh-clients"
    fi
    if [ -n "$SSH_PASSWORD" ] && ! command -v sshpass >/dev/null 2>&1; then
        warn "检测到使用 SSH 密码，尝试安装 sshpass..."
        detect_sys_pkg
        sys_pkg_install "sshpass" >/dev/null 2>&1 || true
        if ! command -v sshpass >/dev/null 2>&1; then
            error "sshpass 安装失败。请配置 SSH 免密，或手动安装 sshpass"
        fi
    fi
    return 0
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
    local remote_cmd="$*"
    build_ssh_opts
    if [ -n "$SSH_PASSWORD" ]; then
        SSHPASS="$SSH_PASSWORD" sshpass -e ssh $SSH_OPTS "${SSH_USER}@${host}" "$remote_cmd"
    else
        ssh $SSH_OPTS "${SSH_USER}@${host}" "$remote_cmd"
    fi
}

scp_to_remote() {
    local src="$1"
    local host="$2"
    local dest="$3"
    build_ssh_opts
    if [ -n "$SSH_PASSWORD" ]; then
        SSHPASS="$SSH_PASSWORD" sshpass -e scp $SSH_OPTS "$src" "${SSH_USER}@${host}:${dest}"
    else
        scp $SSH_OPTS "$src" "${SSH_USER}@${host}:${dest}"
    fi
}

test_ssh_connection() {
    local host="$1"
    info "测试 SSH ${SSH_USER}@${host}:${SSH_PORT} ..."
    if ssh_cmd "$host" "echo SSH_OK && hostname && uname -m"; then
        success "SSH 连接成功"
        return 0
    fi
    error "SSH 连接失败: $host" 
}

# 从节点条目切换 SSH 上下文
with_node_ssh() {
    # $1 host $2 sport $3 suser $4 spass
    SSH_PORT="$2"
    SSH_USER="$3"
    SSH_PASSWORD="$4"
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

# ======================== 检测/打包 ========================

check_redis_installed() {
    if [ -f "$INSTALL_CONFIG" ]; then
        # shellcheck source=/dev/null
        . "$INSTALL_CONFIG"
    fi
    if [ -f "$REDIS_INSTALL_DIR/bin/redis-server" ]; then
        info "找到 Redis: $REDIS_INSTALL_DIR (port ${REDIS_PORT})"
        return 0
    fi
    warn "本机未找到 Redis 安装"
    return 1
}

ensure_package_tgz() {
    # 优先使用已有编译包；否则打包本机安装目录
    local pack_dir="$SCRIPT_DIR/package"
    mkdir -p "$pack_dir"

    # 已有源码/编译包
    local existing
    existing=$(find "$pack_dir" -maxdepth 1 -type f \( -name 'redis-*.tar.gz' -o -name 'redis-*.tgz' \) 2>/dev/null | head -1)
    if [ -n "$existing" ] && [ -f "$existing" ]; then
        REDIS_PACK_TGZ="$existing"
        info "使用已有安装包: $REDIS_PACK_TGZ"
        return 0
    fi

    if [ ! -f "$REDIS_INSTALL_DIR/bin/redis-server" ]; then
        warn "本机无已安装 Redis，且 package/ 下无可用包"
        return 1
    fi

    local pack_name="redis-${REDIS_VERSION}-linux-$(uname -m).tar.gz"
    info "打包本机安装目录用于分发..."
    tar zcf "${pack_dir}/${pack_name}" -C "$(dirname "$REDIS_INSTALL_DIR")" "$(basename "$REDIS_INSTALL_DIR")"
    REDIS_PACK_TGZ="${pack_dir}/${pack_name}"
    success "打包完成: $REDIS_PACK_TGZ"
    return 0
}

# ======================== 本机安装 ========================

install_local_redis() {
    print_title "本机安装 Redis"

    if [ ! -f "$INSTALL_SCRIPT" ]; then
        error "未找到安装脚本: $INSTALL_SCRIPT"
    fi

    if check_redis_installed; then
        if confirm_action "本机已安装 Redis，是否跳过安装直接配置角色?" "Y"; then
            return 0
        fi
    fi

    local port="${REDIS_PORT:-6379}"
    local pass="${REDIS_PASSWORD}"
    local install_dir="${REDIS_INSTALL_DIR}"

    read -p "Redis 端口 [$port]: " input
    port=${input:-$port}
    read -p "安装目录 [$install_dir]: " input
    install_dir=${input:-$install_dir}
    read -s -p "Redis 密码 (留空不设置) [${pass}]: " input
    echo ""
    if [ -n "$input" ]; then
        pass="$input"
    fi

    REDIS_PORT="$port"
    REDIS_INSTALL_DIR="$install_dir"
    REDIS_PASSWORD="$pass"

    # 哨兵集群场景先不启动单机服务，后面按角色配置
    local cmd=(bash "$INSTALL_SCRIPT" --batch --sentinel \
        --install-dir "$REDIS_INSTALL_DIR" \
        --data-dir "$REDIS_DATA_DIR" \
        --port "$REDIS_PORT" \
        --skip-start)

    if [ -n "$REDIS_PASSWORD" ]; then
        cmd+=(--password "$REDIS_PASSWORD")
    fi

    # 扫描脚本根目录与 package/ 下的安装包（与 install_redis.sh 的检测位置一致），多版本取最高
    local local_tgz
    local_tgz=$( {
        find "$SCRIPT_DIR" -maxdepth 1 -type f -name 'redis-*.tar.gz' 2>/dev/null
        find "$SCRIPT_DIR/package" -maxdepth 1 -type f -name 'redis-*.tar.gz' 2>/dev/null
    } | sort -u -V 2>/dev/null | tail -1)
    if [ -n "$local_tgz" ]; then
        cmd+=(--tgz "$local_tgz")
    fi

    info "执行: ${cmd[*]}"
    "${cmd[@]}" || error "本机 Redis 安装失败"

    # 重新加载配置
    if [ -f "$INSTALL_CONFIG" ]; then
        # shellcheck source=/dev/null
        . "$INSTALL_CONFIG"
    fi
    check_redis_installed || error "安装后仍未找到 redis-server"
    return 0
}

# ======================== 角色配置（本机） ========================

ensure_redis_dirs() {
    mkdir -p "$REDIS_DATA_DIR" "$REDIS_LOG_DIR" "$REDIS_CONF_DIR" "$REDIS_RUN_DIR"
    mkdir -p "$REDIS_DATA_DIR/redis_${REDIS_PORT}"
    mkdir -p "$REDIS_DATA_DIR/sentinel_${SENTINEL_PORT}"
    chown -R redis:redis "$REDIS_DATA_DIR" "$REDIS_LOG_DIR" "$REDIS_RUN_DIR" "$REDIS_CONF_DIR" 2>/dev/null || true
}

write_redis_instance_service() {
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

    local sentinel_service="/etc/systemd/system/redis-sentinel@.service"
    cat > "$sentinel_service" << EOF
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
}

generate_redis_conf() {
    local role="$1"  # master|slave
    local conf_file="$REDIS_CONF_DIR/redis_${REDIS_PORT}.conf"

    cat > "$conf_file" << EOF
# Redis $role 配置 - 由 setup_redis_sentinel.sh 自动生成
port $REDIS_PORT
bind $REDIS_BIND
protected-mode yes
daemonize yes
pidfile $REDIS_RUN_DIR/redis_$REDIS_PORT.pid
loglevel notice
logfile $REDIS_LOG_DIR/redis_$REDIS_PORT.log
dir $REDIS_DATA_DIR/redis_$REDIS_PORT

# RDB
save 900 1
save 300 10
save 60 10000
rdbcompression yes
dbfilename dump_$REDIS_PORT.rdb

# 主从复制基础
repl-diskless-sync yes
repl-diskless-sync-delay 5
min-replicas-to-write 0
min-replicas-max-lag 10
EOF

    if [ -n "$REDIS_PASSWORD" ]; then
        echo "requirepass $REDIS_PASSWORD" >> "$conf_file"
        # 主从/哨兵互联需要 masterauth
        echo "masterauth $REDIS_PASSWORD" >> "$conf_file"
    fi

    if [ "$role" = "slave" ]; then
        echo "replicaof $MASTER_HOST $MASTER_PORT" >> "$conf_file"
        if [ -n "$MASTER_PASSWORD" ]; then
            # 覆盖 masterauth 为主库密码
            sed -i '/^masterauth /d' "$conf_file"
            echo "masterauth $MASTER_PASSWORD" >> "$conf_file"
        fi
        echo "replica-read-only yes" >> "$conf_file"
    fi

    chown redis:redis "$conf_file"
    success "Redis 配置生成: $conf_file"
}

generate_sentinel_conf() {
    local conf_file="$REDIS_CONF_DIR/sentinel_${SENTINEL_PORT}.conf"
    local monitor_host="${MASTER_HOST:-$(get_local_ip)}"
    local monitor_port="${MASTER_PORT:-$REDIS_PORT}"
    local auth_pass="${MASTER_PASSWORD:-$REDIS_PASSWORD}"

    mkdir -p "$REDIS_DATA_DIR/sentinel_${SENTINEL_PORT}"

    cat > "$conf_file" << EOF
# Redis Sentinel 配置 - 由 setup_redis_sentinel.sh 自动生成
port $SENTINEL_PORT
bind $REDIS_BIND
protected-mode no
daemonize yes
pidfile $REDIS_RUN_DIR/sentinel_$SENTINEL_PORT.pid
loglevel notice
logfile $REDIS_LOG_DIR/sentinel_$SENTINEL_PORT.log
dir $REDIS_DATA_DIR/sentinel_$SENTINEL_PORT

sentinel monitor mymaster $monitor_host $monitor_port $SENTINEL_QUORUM
sentinel down-after-milliseconds mymaster $SENTINEL_DOWN_AFTER
sentinel failover-timeout mymaster $SENTINEL_FAILOVER_TIMEOUT
sentinel parallel-syncs mymaster $SENTINEL_PARALLEL_SYNC
EOF

    if [ -n "$auth_pass" ]; then
        echo "sentinel auth-pass mymaster $auth_pass" >> "$conf_file"
    fi
    if [ -n "$SENTINEL_PASSWORD" ]; then
        echo "requirepass $SENTINEL_PASSWORD" >> "$conf_file"
    fi

    # 避免 sentinel 重写时丢配置
    echo "sentinel config-epoch mymaster 0" >> "$conf_file"

    chown redis:redis "$conf_file"
    success "Sentinel 配置生成: $conf_file"
}

start_redis_instance() {
    local port="$1"
    write_redis_instance_service
    systemctl enable --now "redis@${port}" >/dev/null 2>&1
    sleep 2
    if systemctl is-active --quiet "redis@${port}"; then
        success "redis@${port} 启动成功"
        return 0
    fi
    warn "redis@${port} 启动失败，查看: journalctl -u redis@${port} -n 30"
    return 1
}

start_sentinel_instance() {
    local port="$1"
    write_redis_instance_service
    systemctl enable --now "redis-sentinel@${port}" >/dev/null 2>&1
    sleep 2
    if systemctl is-active --quiet "redis-sentinel@${port}"; then
        success "redis-sentinel@${port} 启动成功"
        return 0
    fi
    warn "redis-sentinel@${port} 启动失败，查看: journalctl -u redis-sentinel@${port} -n 30"
    return 1
}

configure_local_master() {
    print_title "配置本机为 Redis 主节点"

    check_redis_installed || {
        warn "需要先安装 Redis"
        install_local_redis || return 1
    }

    local local_ip
    local_ip=$(get_local_ip)
    MASTER_HOST="$local_ip"
    MASTER_PORT="$REDIS_PORT"
    MASTER_PASSWORD="$REDIS_PASSWORD"

    read -p "本机 Redis 端口 [${REDIS_PORT}]: " input
    REDIS_PORT=${input:-$REDIS_PORT}
    MASTER_PORT="$REDIS_PORT"

    if [ -n "$REDIS_PASSWORD" ]; then
        info "当前密码已设置"
        read -p "是否修改密码? [y/N]: " chg
        if [[ "$chg" =~ ^[Yy]$ ]]; then
            read -s -p "新密码: " REDIS_PASSWORD
            echo ""
        fi
    else
        read -s -p "设置 Redis 密码 (留空不设置): " REDIS_PASSWORD
        echo ""
    fi
    MASTER_PASSWORD="$REDIS_PASSWORD"

    read -p "从库连接主库使用的 IP [${local_ip}]: " input
    MASTER_HOST=${input:-$local_ip}

    echo ""
    info "主节点配置:"
    info "  IP: $MASTER_HOST"
    info "  端口: $REDIS_PORT"
    info "  密码: ${REDIS_PASSWORD:-(未设置)}"
    confirm_action "确认配置本机为主节点?" || return 1

    ensure_redis_dirs
    generate_redis_conf "master"
    start_redis_instance "$REDIS_PORT" || return 1

    # 更新安装状态中的密码
    if [ -f "$INSTALL_CONFIG" ]; then
        sed -i "s|^REDIS_PORT=.*|REDIS_PORT=$REDIS_PORT|" "$INSTALL_CONFIG"
        sed -i "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=$REDIS_PASSWORD|" "$INSTALL_CONFIG"
        sed -i "s|^REDIS_INSTALL_DIR=.*|REDIS_INSTALL_DIR=$REDIS_INSTALL_DIR|" "$INSTALL_CONFIG"
    fi

    REDIS_ROLE="master"
    success "本机主节点配置完成"
    return 0
}

# ======================== 收集节点 ========================

collect_ssh_info() {
    print_title "SSH 远程连接信息"

    read -p "SSH 用户名 [root]: " input
    SSH_USER=${input:-root}
    read -p "SSH 端口 [22]: " input
    SSH_PORT=${input:-22}

    echo "认证方式:"
    echo "1. SSH 密码（自动使用 sshpass）"
    echo "2. SSH 私钥免密"
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
    return 0
}

collect_node_list() {
    local list_name="$1"   # SLAVE 或 SENTINEL
    local -n arr=$2

    print_title "添加 ${list_name} 节点"
    echo -e "${CYAN}输入节点 SSH 信息（可多台，IP 留空结束）${NC}"
    echo "格式提示: IP → SSH端口 → SSH用户 → SSH密码 → Redis端口 → Redis密码"
    echo ""

    local idx=1
    while true; do
        read -p "${list_name} #${idx} IP/主机名 (空结束): " host
        [ -z "$host" ] && break

        local sport="$SSH_PORT"
        local suser="$SSH_USER"
        local spass="$SSH_PASSWORD"
        local rport="${REDIS_PORT:-6379}"
        local rpass="${REDIS_PASSWORD}"
        local custom

        read -p "  SSH端口 [$SSH_PORT]: " custom
        sport=${custom:-$sport}
        read -p "  SSH用户 [$SSH_USER]: " custom
        suser=${custom:-$suser}

        if [ -n "$SSH_PASSWORD" ]; then
            read -p "  使用全局SSH密码? [Y/n]: " use_global
            if [[ "$use_global" =~ ^[Nn]$ ]]; then
                read -s -p "  SSH密码: " spass
                echo ""
            fi
        else
            read -p "  使用全局SSH密钥? [Y/n]: " use_key
            if [[ "$use_key" =~ ^[Nn]$ ]]; then
                read -s -p "  SSH密码: " spass
                echo ""
            else
                spass=""
            fi
        fi

        if [ "$list_name" != "哨兵" ]; then
            read -p "  Redis端口 [${rport}]: " custom
            rport=${custom:-$rport}
            read -s -p "  Redis密码 (回车用全局 ${REDIS_PASSWORD:-空}): " custom
            echo ""
            rpass=${custom:-$rpass}
        else
            read -p "  Sentinel端口 [${SENTINEL_PORT}]: " custom
            local sport_sent=${custom:-$SENTINEL_PORT}
        fi

        if [ "$list_name" != "哨兵" ]; then
            arr+=("${host}|${sport}|${suser}|${spass}|${rport}|${rpass}")
        else
            arr+=("${host}|${sport}|${suser}|${spass}|${sport_sent}|")
        fi

        success "已添加: $host (ssh ${suser}@${host}:${sport})"
        idx=$((idx+1))
    done

    if [ ${#arr[@]} -eq 0 ]; then
        warn "未添加任何 ${list_name} 节点"
        return 1
    fi

    echo ""
    info "${list_name} 列表:"
    local n=1
    for item in "${arr[@]}"; do
        IFS='|' read -r h p u _ rp _ <<< "$item"
        echo "  $n. $h  ssh=${u}@${h}:${p}  redis/sentinel_port=${rp}"
        n=$((n+1))
    done
    return 0
}

save_cluster_state() {
    {
        echo "# Redis cluster state - $(date)"
        echo "MASTER_HOST=${MASTER_HOST}"
        echo "MASTER_PORT=${MASTER_PORT}"
        echo "MASTER_PASSWORD=${MASTER_PASSWORD}"
        echo "REDIS_PASSWORD=${REDIS_PASSWORD}"
        echo "REDIS_PORT=${REDIS_PORT}"
        echo "REDIS_INSTALL_DIR=${REDIS_INSTALL_DIR}"
        echo "SENTINEL_PORT=${SENTINEL_PORT}"
        echo "SENTINEL_QUORUM=${SENTINEL_QUORUM}"
        echo "SENTINEL_PASSWORD=${SENTINEL_PASSWORD}"
        echo "SSH_USER=${SSH_USER}"
        echo "SSH_PORT=${SSH_PORT}"
        echo "SSH_KEY=${SSH_KEY}"
        echo "REDIS_PACK_TGZ=${REDIS_PACK_TGZ}"
        # 节点用 | 分隔
        echo "SLAVE_NODES_STR=${SLAVE_NODES[*]}"
        echo "SENTINEL_NODES_STR=${SENTINEL_NODES[*]}"
    } > "$CLUSTER_STATE_FILE"
    chmod 600 "$CLUSTER_STATE_FILE"
    success "集群状态已保存: $CLUSTER_STATE_FILE"
}

load_cluster_state() {
    if [ -f "$CLUSTER_STATE_FILE" ]; then
        # shellcheck source=/dev/null
        . "$CLUSTER_STATE_FILE"
        # 还原数组
        if [ -n "$SLAVE_NODES_STR" ]; then
            read -r -a SLAVE_NODES <<< "$SLAVE_NODES_STR"
        fi
        if [ -n "$SENTINEL_NODES_STR" ]; then
            read -r -a SENTINEL_NODES <<< "$SENTINEL_NODES_STR"
        fi
        return 0
    fi
    return 1
}

# ======================== 远程安装与配置 ========================

remote_install_redis() {
    local host="$1" sport="$2" suser="$3" spass="$4" rport="$5" rpass="$6"

    print_title "远程安装 Redis → ${host}"

    local old_port="$SSH_PORT" old_user="$SSH_USER" old_pass="$SSH_PASSWORD"
    with_node_ssh "$host" "$sport" "$suser" "$spass"

    test_ssh_connection "$host" || {
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 1
    }

    local remote_info
    remote_info=$(ssh_cmd "$host" 'echo ARCH=$(uname -m); command -v systemctl >/dev/null && echo HAS_SYSTEMD=1 || echo HAS_SYSTEMD=0')
    info "远程环境: $remote_info"
    if ! echo "$remote_info" | grep -q "HAS_SYSTEMD=1"; then
        warn "远程缺少 systemd"
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 1
    fi

    if ! disable_remote_selinux "$host"; then
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 1
    fi

    if [ -z "$REDIS_PACK_TGZ" ] || [ ! -f "$REDIS_PACK_TGZ" ]; then
        ensure_package_tgz || {
            warn "无法准备 Redis 安装包"
            SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
            return 1
        }
    fi

    local tgz_name
    tgz_name=$(basename "$REDIS_PACK_TGZ")
    local remote_install_dir="${REDIS_INSTALL_DIR}"
    local remote_data_dir="${REDIS_DATA_DIR}"

    info "[1/3] 上传安装脚本..."
    ssh_cmd "$host" "mkdir -p /tmp/redis_remote_install" || true
    scp_to_remote "$INSTALL_SCRIPT" "$host" "/tmp/redis_remote_install/install_redis.sh" || {
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 1
    }

    info "[2/3] 上传 Redis 安装包（可能需要一段时间）..."
    scp_to_remote "$REDIS_PACK_TGZ" "$host" "/tmp/${tgz_name}" || {
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 1
    }

    info "[3/3] 远程无人值守安装..."
    local remote_cmd="bash /tmp/redis_remote_install/install_redis.sh --batch --sentinel --tgz /tmp/${tgz_name} --install-dir '${remote_install_dir}' --data-dir '${remote_data_dir}' --port '${rport}' --skip-start"
    if [ -n "$rpass" ]; then
        remote_cmd="${remote_cmd} --password '${rpass}'"
    fi

    if ssh_cmd "$host" "$remote_cmd"; then
        success "${host} Redis 安装完成"
        # 保留包缓存可清理大文件
        ssh_cmd "$host" "rm -f /tmp/${tgz_name}" >/dev/null 2>&1 || true
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 0
    fi

    warn "${host} Redis 安装失败"
    SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
    return 1
}

# 生成远程配置并应用
apply_remote_role() {
    local host="$1" sport="$2" suser="$3" spass="$4"
    local role="$5"          # slave | sentinel
    local rport="$6"
    local rpass="$7"
    local sentinel_port="${8:-$SENTINEL_PORT}"

    print_title "配置远程${role} → ${host}"

    local old_port="$SSH_PORT" old_user="$SSH_USER" old_pass="$SSH_PASSWORD"
    with_node_ssh "$host" "$sport" "$suser" "$spass"

    # 读取远程安装路径
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

    local master_host="${MASTER_HOST}"
    local master_port="${MASTER_PORT}"
    local master_pass="${MASTER_PASSWORD:-$REDIS_PASSWORD}"
    local quorum="${SENTINEL_QUORUM}"

    local workdir="/tmp/redis_cluster_apply"
    ssh_cmd "$host" "mkdir -p $workdir" || true

    if [ "$role" = "slave" ]; then
        local conf_name="redis_${rport}.conf"
        local conf_local="/tmp/${conf_name}"
        cat > "$conf_local" << EOF
# Redis slave - generated by setup_redis_sentinel.sh
port ${rport}
bind ${REDIS_BIND}
protected-mode yes
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

replicaof ${master_host} ${master_port}
repl-diskless-sync yes
replica-read-only yes
EOF
        if [ -n "$rpass" ]; then
            echo "requirepass ${rpass}" >> "$conf_local"
        fi
        if [ -n "$master_pass" ]; then
            echo "masterauth ${master_pass}" >> "$conf_local"
        fi

        scp_to_remote "$conf_local" "$host" "${workdir}/${conf_name}" || {
            SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
            return 1
        }

        ssh_cmd "$host" "bash -s" << REMOTE
set -e
mkdir -p '${remote_conf_dir}' '${remote_data_dir}/redis_${rport}' '${remote_log_dir}' '${remote_run_dir}'
cp '${workdir}/${conf_name}' '${remote_conf_dir}/${conf_name}'
id redis >/dev/null 2>&1 || useradd -r -s /sbin/nologin redis
chown -R redis:redis '${remote_data_dir}' '${remote_log_dir}' '${remote_run_dir}' '${remote_conf_dir}'

# systemd 模板
cat > /etc/systemd/system/redis@.service << 'SVC'
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

# 修正模板中的路径变量
sed -i "s|PIDFile=.*|PIDFile=${remote_run_dir}/redis_%i.pid|" /etc/systemd/system/redis@.service
sed -i "s|ExecStart=.*|ExecStart=${remote_install_dir}/bin/redis-server ${remote_conf_dir}/redis_%i.conf|" /etc/systemd/system/redis@.service
sed -i "s|ExecStop=.*|ExecStop=${remote_install_dir}/bin/redis-cli -p %i shutdown|" /etc/systemd/system/redis@.service

systemctl daemon-reload
systemctl enable --now redis@${rport}
sleep 2
systemctl is-active --quiet redis@${rport}
REMOTE

        if [ $? -ne 0 ]; then
            warn "远程 slave 启动失败"
            SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
            return 1
        fi
        success "远程 slave ${host}:${rport} 配置完成"

    elif [ "$role" = "sentinel" ]; then
        local sconf_name="sentinel_${sentinel_port}.conf"
        local sconf_local="/tmp/${sconf_name}"
        cat > "$sconf_local" << EOF
# Redis Sentinel - generated by setup_redis_sentinel.sh
port ${sentinel_port}
bind ${REDIS_BIND}
protected-mode no
daemonize yes
pidfile ${remote_run_dir}/sentinel_${sentinel_port}.pid
loglevel notice
logfile ${remote_log_dir}/sentinel_${sentinel_port}.log
dir ${remote_data_dir}/sentinel_${sentinel_port}

sentinel monitor mymaster ${master_host} ${master_port} ${quorum}
sentinel down-after-milliseconds mymaster ${SENTINEL_DOWN_AFTER}
sentinel failover-timeout mymaster ${SENTINEL_FAILOVER_TIMEOUT}
sentinel parallel-syncs mymaster ${SENTINEL_PARALLEL_SYNC}
EOF
        if [ -n "$master_pass" ]; then
            echo "sentinel auth-pass mymaster ${master_pass}" >> "$sconf_local"
        fi
        if [ -n "$SENTINEL_PASSWORD" ]; then
            echo "requirepass ${SENTINEL_PASSWORD}" >> "$sconf_local"
        fi

        scp_to_remote "$sconf_local" "$host" "${workdir}/${sconf_name}" || {
            SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
            return 1
        }

        ssh_cmd "$host" "bash -s" << REMOTE
set -e
mkdir -p '${remote_conf_dir}' '${remote_data_dir}/sentinel_${sentinel_port}' '${remote_log_dir}' '${remote_run_dir}'
cp '${workdir}/${sconf_name}' '${remote_conf_dir}/${sconf_name}'
id redis >/dev/null 2>&1 || useradd -r -s /sbin/nologin redis
chown -R redis:redis '${remote_data_dir}' '${remote_log_dir}' '${remote_run_dir}' '${remote_conf_dir}'

cat > /etc/systemd/system/redis-sentinel@.service << SVC
[Unit]
Description=Redis Sentinel (port %i)
After=network.target

[Service]
Type=forking
User=redis
Group=redis
PIDFile=${remote_run_dir}/sentinel_%i.pid
ExecStart=${remote_install_dir}/bin/redis-sentinel ${remote_conf_dir}/sentinel_%i.conf
ExecStop=${remote_install_dir}/bin/redis-cli -p %i shutdown
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable --now redis-sentinel@${sentinel_port}
sleep 2
systemctl is-active --quiet redis-sentinel@${sentinel_port}
REMOTE

        if [ $? -ne 0 ]; then
            warn "远程 sentinel 启动失败"
            SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
            return 1
        fi
        success "远程 sentinel ${host}:${sentinel_port} 配置完成"
    fi

    SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
    return 0
}

# ======================== 一键部署 ========================

one_click_deploy() {
    print_title "一键 Redis 主从 + Sentinel 部署"

    echo -e "${CYAN}流程:${NC}"
    echo "  1. 本机安装 Redis 并配置为主节点"
    echo "  2. 打包已编译安装目录，scp 到从库/哨兵机器"
    echo "  3. SSH 无人值守安装 Redis"
    echo "  4. 配置从库 replicaof 主库"
    echo "  5. 在主库与各节点部署 Sentinel"
    echo "  6. 检查复制与哨兵状态"
    echo ""

    confirm_action "开始一键部署?" || return 1

    collect_ssh_info || return 1

    echo ""
    echo -e "${YELLOW}--- 从节点（可多台）---${NC}"
    if ! collect_node_list "从库" SLAVE_NODES; then
        warn "至少需要 1 个从库才能构成主从"
        if ! confirm_action "是否仍继续（仅主库 + 哨兵）?"; then
            return 1
        fi
    fi

    echo ""
    read -p "是否部署 Sentinel 哨兵? [Y/n]: " en_sent
    if [[ "$en_sent" =~ ^[Nn]$ ]]; then
        ENABLE_SENTINEL="no"
    else
        ENABLE_SENTINEL="yes"
        echo ""
        echo -e "${YELLOW}--- 哨兵节点（推荐 3 台；可与从库同机）---${NC}"
        info "若哨兵与从库同机，请输入相同 IP，脚本会复用 SSH 信息"
        collect_node_list "哨兵" SENTINEL_NODES || true

        read -p "Sentinel 端口 [${SENTINEL_PORT}]: " input
        SENTINEL_PORT=${input:-$SENTINEL_PORT}
        read -p "Sentinel quorum [默认自动: 节点数/2+1，至少2]: " input
        if [ -n "$input" ]; then
            SENTINEL_QUORUM="$input"
        else
            local sn=${#SENTINEL_NODES[@]}
            if [ "$sn" -lt 1 ]; then sn=1; fi
            SENTINEL_QUORUM=$(( sn / 2 + 1 ))
            if [ "$SENTINEL_QUORUM" -lt 2 ]; then SENTINEL_QUORUM=2; fi
        fi
        read -s -p "Sentinel 连接密码 (回车使用 Redis 密码): " input
        echo ""
        SENTINEL_PASSWORD=${input:-$REDIS_PASSWORD}
        info "Sentinel quorum=$SENTINEL_QUORUM port=$SENTINEL_PORT"
    fi

    # A. 本机主节点
    echo ""
    echo -e "${YELLOW}===== 步骤 A: 本机主节点 =====${NC}"
    install_local_redis || return 1
    configure_local_master || return 1

    # 打包
    echo ""
    echo -e "${YELLOW}===== 步骤 B: 打包分发 =====${NC}"
    ensure_package_tgz || {
        warn "打包失败，远程将无法离线安装"
        confirm_action "是否继续?" || return 1
    }

    # C. 从库
    local failed=0
    local idx=1
    for item in "${SLAVE_NODES[@]}"; do
        IFS='|' read -r h p u pw rp rpw <<< "$item"
        echo ""
        echo -e "${YELLOW}===== 步骤 C.${idx}: 从库 ${h} =====${NC}"
        rp=${rp:-$REDIS_PORT}
        rpw=${rpw:-$REDIS_PASSWORD}
        if remote_install_redis "$h" "$p" "$u" "$pw" "$rp" "$rpw"; then
            apply_remote_role "$h" "$p" "$u" "$pw" "slave" "$rp" "$rpw" || failed=$((failed+1))
        else
            failed=$((failed+1))
        fi
        idx=$((idx+1))
    done

    # D. 本机哨兵
    if [ "$ENABLE_SENTINEL" = "yes" ]; then
        echo ""
        echo -e "${YELLOW}===== 步骤 D: 本机 Sentinel =====${NC}"
        ensure_redis_dirs
        generate_sentinel_conf
        start_sentinel_instance "$SENTINEL_PORT" || warn "本机 sentinel 启动失败"

        idx=1
        for item in "${SENTINEL_NODES[@]}"; do
            IFS='|' read -r h p u pw sp _ <<< "$item"
            # 跳过本机 IP
            local lip
            lip=$(get_local_ip)
            if [ "$h" = "$lip" ] || [ "$h" = "127.0.0.1" ] || [ "$h" = "localhost" ]; then
                info "跳过本机哨兵节点 $h（已配置）"
                continue
            fi
            echo ""
            echo -e "${YELLOW}===== 步骤 D.${idx}: Sentinel ${h} =====${NC}"
            sp=${sp:-$SENTINEL_PORT}

            # 若该机器尚未安装 redis（哨兵专用机），先安装
            local old_port="$SSH_PORT" old_user="$SSH_USER" old_pass="$SSH_PASSWORD"
            with_node_ssh "$h" "$p" "$u" "$pw"
            local has_redis
            has_redis=$(ssh_cmd "$h" "test -x '${REDIS_INSTALL_DIR}/bin/redis-server' && echo YES || echo NO")
            SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"

            if [ "$has_redis" != "YES" ]; then
                remote_install_redis "$h" "$p" "$u" "$pw" "$REDIS_PORT" "$REDIS_PASSWORD" || true
            fi
            apply_remote_role "$h" "$p" "$u" "$pw" "sentinel" "$REDIS_PORT" "$REDIS_PASSWORD" "$sp" || failed=$((failed+1))
            idx=$((idx+1))
        done
    fi

    save_cluster_state

    echo ""
    print_title "部署结果"
    info "主库: ${MASTER_HOST}:${MASTER_PORT}"
    info "从库数量: ${#SLAVE_NODES[@]}  失败步骤: ${failed}"
    if [ "$ENABLE_SENTINEL" = "yes" ]; then
        info "Sentinel: 本机 + ${#SENTINEL_NODES[@]} 远程  port=$SENTINEL_PORT quorum=$SENTINEL_QUORUM"
    fi
    echo ""
    info "后续命令:"
    echo "  bash $0 status"
    echo "  bash $0 one"
    echo ""

    check_cluster_status
    return 0
}

# ======================== 状态检查 ========================

redis_cli_cmd() {
    local host="${1:-127.0.0.1}"
    local port="$2"
    local pass="$3"
    shift 3
    local args=("$@")
    if [ -n "$pass" ]; then
        "$REDIS_INSTALL_DIR/bin/redis-cli" -h "$host" -p "$port" -a "$pass" --no-auth-warning "${args[@]}"
    else
        "$REDIS_INSTALL_DIR/bin/redis-cli" -h "$host" -p "$port" "${args[@]}"
    fi
}

check_local_redis_role() {
    local out
    if [ -n "$REDIS_PASSWORD" ]; then
        out=$("$REDIS_INSTALL_DIR/bin/redis-cli" -p "$REDIS_PORT" -a "$REDIS_PASSWORD" --no-auth-warning info replication 2>/dev/null)
    else
        out=$("$REDIS_INSTALL_DIR/bin/redis-cli" -p "$REDIS_PORT" info replication 2>/dev/null)
    fi
    if [ -z "$out" ]; then
        warn "无法连接本机 Redis :$REDIS_PORT"
        return 1
    fi
    echo "$out" | grep -E "role:|master_host:|master_port:|connected_slaves:|slave[0-9]:" | sed 's/^/  /'
}

check_cluster_status() {
    print_title "检查 Redis 集群状态"

    load_cluster_state || true
    if [ -f "$INSTALL_CONFIG" ]; then
        # shellcheck source=/dev/null
        . "$INSTALL_CONFIG"
    fi

    echo -e "${CYAN}===== 本机 Redis =====${NC}"
    check_local_redis_role

    if [ -n "$REDIS_PASSWORD" ]; then
        "$REDIS_INSTALL_DIR/bin/redis-cli" -p "$REDIS_PORT" -a "$REDIS_PASSWORD" --no-auth-warning ping 2>/dev/null | sed 's/^/  PING: /'
    else
        "$REDIS_INSTALL_DIR/bin/redis-cli" -p "$REDIS_PORT" ping 2>/dev/null | sed 's/^/  PING: /'
    fi

    # 本机 sentinel
    if systemctl is-active --quiet "redis-sentinel@${SENTINEL_PORT}" 2>/dev/null; then
        echo -e "${CYAN}===== 本机 Sentinel :$SENTINEL_PORT =====${NC}"
        if [ -n "$SENTINEL_PASSWORD" ]; then
            "$REDIS_INSTALL_DIR/bin/redis-cli" -p "$SENTINEL_PORT" -a "$SENTINEL_PASSWORD" --no-auth-warning sentinel master mymaster 2>/dev/null | sed 's/^/  /'
        else
            "$REDIS_INSTALL_DIR/bin/redis-cli" -p "$SENTINEL_PORT" sentinel master mymaster 2>/dev/null | sed 's/^/  /'
        fi
    fi

    # 远程从库
    if [ ${#SLAVE_NODES[@]} -gt 0 ]; then
        echo ""
        echo -e "${CYAN}===== 远程从库 =====${NC}"
        for item in "${SLAVE_NODES[@]}"; do
            IFS='|' read -r h p u pw rp rpw <<< "$item"
            rp=${rp:-6379}
            rpw=${rpw:-$REDIS_PASSWORD}
            echo -e "${YELLOW}-> ${h}:${rp}${NC}"
            local old_port="$SSH_PORT" old_user="$SSH_USER" old_pass="$SSH_PASSWORD"
            with_node_ssh "$h" "$p" "$u" "$pw"
            local remote_dir
            remote_dir=$(ssh_cmd "$h" "grep '^REDIS_INSTALL_DIR=' /etc/redis_install.conf 2>/dev/null | cut -d= -f2-")
            remote_dir=${remote_dir:-/usr/local/redis}
            if [ -n "$rpw" ]; then
                ssh_cmd "$h" "'${remote_dir}/bin/redis-cli' -p ${rp} -a '${rpw}' --no-auth-warning info replication 2>/dev/null | grep -E 'role:|master_host:|master_link_status:|connected_slaves:'"
            else
                ssh_cmd "$h" "'${remote_dir}/bin/redis-cli' -p ${rp} info replication 2>/dev/null | grep -E 'role:|master_host:|master_link_status:|connected_slaves:'"
            fi
            SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        done
    fi

    # 远程哨兵
    if [ ${#SENTINEL_NODES[@]} -gt 0 ]; then
        echo ""
        echo -e "${CYAN}===== 远程 Sentinel =====${NC}"
        for item in "${SENTINEL_NODES[@]}"; do
            IFS='|' read -r h p u pw sp _ <<< "$item"
            sp=${sp:-$SENTINEL_PORT}
            echo -e "${YELLOW}-> ${h}:${sp}${NC}"
            local old_port="$SSH_PORT" old_user="$SSH_USER" old_pass="$SSH_PASSWORD"
            with_node_ssh "$h" "$p" "$u" "$pw"
            local remote_dir
            remote_dir=$(ssh_cmd "$h" "grep '^REDIS_INSTALL_DIR=' /etc/redis_install.conf 2>/dev/null | cut -d= -f2-")
            remote_dir=${remote_dir:-/usr/local/redis}
            local spass_cmd=""
            if [ -n "$SENTINEL_PASSWORD" ]; then
                ssh_cmd "$h" "'${remote_dir}/bin/redis-cli' -p ${sp} -a '${SENTINEL_PASSWORD}' --no-auth-warning sentinel master mymaster 2>/dev/null | head -20"
            else
                ssh_cmd "$h" "'${remote_dir}/bin/redis-cli' -p ${sp} sentinel master mymaster 2>/dev/null | head -20"
            fi
            SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        done
    fi
}

# ======================== 重置 ========================

reset_local_cluster() {
    print_title "重置本机 Redis 主从/哨兵配置"

    confirm_action "将停止本机 redis@* 与 redis-sentinel@* 并清理实例配置，确认?" || return 1

    # 停止实例
    systemctl stop 'redis@*' 2>/dev/null || true
    systemctl stop 'redis-sentinel@*' 2>/dev/null || true
    systemctl disable 'redis@*' 2>/dev/null || true
    systemctl disable 'redis-sentinel@*' 2>/dev/null || true

    rm -f "$REDIS_CONF_DIR"/redis_*.conf "$REDIS_CONF_DIR"/sentinel_*.conf 2>/dev/null || true
    rm -f "$CLUSTER_STATE_FILE"
    success "本机角色配置已清理（二进制仍保留在 $REDIS_INSTALL_DIR）"
    info "如需完全卸载请运行 uninstall_redis.sh"
}

# ======================== 帮助 ========================

show_help() {
    print_title "Redis 主从 + Sentinel 部署脚本"
    echo "用法: bash setup_redis_sentinel.sh [命令]"
    echo ""
    echo "命令:"
    echo "  one       一键部署：本机主库 + SSH远程从库 + Sentinel"
    echo "  master    仅配置本机为主节点"
    echo "  status    检查集群状态（本机 + 已知远程节点）"
    echo "  reset     重置本机角色配置"
    echo "  install   仅本机安装 Redis"
    echo "  help      显示帮助"
    echo ""
    echo "交互菜单直接运行脚本即可。"
    echo ""
    echo "一键部署会:"
    echo "  1. 本机安装并配置 Redis Master"
    echo "  2. 打包编译产物到 package/"
    echo "  3. scp 到从库/哨兵机并 batch 安装"
    echo "  4. 从库写 replicaof，哨兵写 sentinel monitor"
    echo ""
    echo "依赖: 本机 root；SSH 可登远程 root（密钥或 sshpass）；远程 systemd"
}

# ======================== 主菜单 ========================

show_main_menu() {
    print_title "Redis 主从 + Sentinel 配置工具"

    local lip
    lip=$(get_local_ip)
    echo -e "${CYAN}本机IP: ${lip:-未知}${NC}"
    if [ -f "$INSTALL_CONFIG" ]; then
        echo -e "${CYAN}已检测到 Redis 安装状态${NC}"
    fi
    if [ -f "$CLUSTER_STATE_FILE" ]; then
        echo -e "${CYAN}已存在集群状态文件${NC}"
    fi
    echo ""
    echo "请选择操作:"
    echo ""
    echo -e "  ${GREEN}1. 一键主从+哨兵部署${NC}（本机Master + SSH远程从库/哨兵）"
    echo "  2. 配置本机为主节点"
    echo "  3. 仅远程安装/配置从库或哨兵"
    echo "  4. 检查集群状态"
    echo "  5. 重置本机角色配置"
    echo "  6. 本机安装 Redis"
    echo "  7. 帮助"
    echo "  q. 退出"
    echo ""
    read -p "请选择 [1-7/q]: " choice

    case "$choice" in
        1) one_click_deploy ;;
        2) configure_local_master ;;
        3)
            load_cluster_state || true
            collect_ssh_info || return 1
            collect_node_list "从库" SLAVE_NODES || true
            if [ ${#SLAVE_NODES[@]} -gt 0 ]; then
                ensure_package_tgz || true
                for item in "${SLAVE_NODES[@]}"; do
                    IFS='|' read -r h p u pw rp rpw <<< "$item"
                    remote_install_redis "$h" "$p" "$u" "$pw" "${rp:-6379}" "${rpw:-$REDIS_PASSWORD}" && \
                        apply_remote_role "$h" "$p" "$u" "$pw" "slave" "${rp:-6379}" "${rpw:-$REDIS_PASSWORD}"
                done
            fi
            collect_node_list "哨兵" SENTINEL_NODES || true
            for item in "${SENTINEL_NODES[@]}"; do
                IFS='|' read -r h p u pw sp _ <<< "$item"
                apply_remote_role "$h" "$p" "$u" "$pw" "sentinel" "$REDIS_PORT" "$REDIS_PASSWORD" "${sp:-$SENTINEL_PORT}"
            done
            save_cluster_state
            ;;
        4) check_cluster_status ;;
        5) reset_local_cluster ;;
        6) install_local_redis ;;
        7) show_help ;;
        q|Q) exit 0 ;;
        *) warn "无效选择" ;;
    esac
}

# ======================== 入口 ========================

main() {
    if [ $# -gt 0 ]; then
        case "$1" in
            one|deploy|cluster) one_click_deploy ;;
            master) configure_local_master ;;
            status) check_cluster_status ;;
            reset)  reset_local_cluster ;;
            install) install_local_redis ;;
            help|-h|--help) show_help ;;
            *)
                echo "未知参数: $1"
                echo "使用 '$0 help' 查看帮助"
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
