#!/bin/bash
# ============================================================
# Kafka 多机集群一键部署脚本
# 参考 setup_redis_sentinel / setup_nacos_cluster 编排方式：
#   本机安装首节点 -> 打包同步 -> SSH 远程安装其余节点
# 支持 KRaft（推荐）与 Zookeeper 协调模式
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ -z "$BASH_VERSION" ]; then
    echo -e "${RED}错误: 请使用bash执行此脚本${NC}"
    exit 1
fi
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}此脚本需要以root权限运行${NC}"
    exit 1
fi

# ======================== 全局变量 ========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="$SCRIPT_DIR/install_kafka.sh"
CLUSTER_STATE_FILE="/etc/kafka_cluster_deploy.conf"

KAFKA_VERSION="${KAFKA_VERSION:-3.9.0}"
SCALA_VERSION="${SCALA_VERSION:-2.13}"
KAFKA_INSTALL_DIR="/usr/local/kafka"
KAFKA_DATA_DIR="/var/lib/kafka"
KAFKA_PACKAGE_DIR="$SCRIPT_DIR/package"
KAFKA_TGZ=""

COORD_MODE="kraft"          # kraft | zookeeper
BROKER_PORT="9092"
CONTROLLER_PORT="9093"
ZK_PORT="2181"
INCLUDE_LOCAL_NODE="yes"
LOCAL_NODE_IP=""
CLUSTER_UUID=""
CONTROLLER_QUORUM=""
ZK_SERVERS=""
ZK_CONNECT=""

# SSH
SSH_USER="root"
SSH_PORT="22"
SSH_PASSWORD=""
SSH_KEY=""
SSH_OPTS=""

# 远程节点: ip|ssh_port|ssh_user|ssh_pass|node_id|broker_port|controller_port|zk_port
REMOTE_NODES=()

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
    command -v ssh >/dev/null 2>&1 && command -v scp >/dev/null 2>&1 || error "未找到 ssh/scp"
    if [ -n "$SSH_PASSWORD" ] && ! command -v sshpass >/dev/null 2>&1; then
        warn "尝试安装 sshpass..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get install -y sshpass 2>/dev/null || true
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y sshpass 2>/dev/null || true
        elif command -v yum >/dev/null 2>&1; then
            yum install -y sshpass 2>/dev/null || true
        fi
        command -v sshpass >/dev/null 2>&1 || error "sshpass 不可用，请配置 SSH 免密"
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

test_ssh_connection() {
    local host="$1"
    info "测试 SSH ${SSH_USER}@${host}:${SSH_PORT} ..."
    ssh_cmd "$host" "echo SSH_OK && uname -m && command -v systemctl >/dev/null" || return 1
    success "SSH OK: $host"
}

# ======================== 安装包 ========================
ensure_package_tgz() {
    local pkg="kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz"
    mkdir -p "$KAFKA_PACKAGE_DIR"
    local local_pkg="$KAFKA_PACKAGE_DIR/$pkg"
    if [ -f "$local_pkg" ]; then
        KAFKA_TGZ="$local_pkg"
        info "使用本地安装包: $KAFKA_TGZ"
        return 0
    fi
    local url="https://downloads.apache.org/kafka/${KAFKA_VERSION}/${pkg}"
    info "下载: $url"
    if wget --timeout=60 --tries=3 -O "$local_pkg" "$url"; then
        local sz
        sz=$(stat -c%s "$local_pkg" 2>/dev/null || echo 0)
        if [ "$sz" -gt 10485760 ]; then
            KAFKA_TGZ="$local_pkg"
            success "下载完成: $KAFKA_TGZ"
            return 0
        fi
        rm -f "$local_pkg"
    fi
    warn "安装包准备失败，请手动放入 $local_pkg"
    return 1
}

# ======================== 收集配置 ========================
collect_ssh_info() {
    print_title "SSH 远程连接信息"
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
    print_title "Kafka 集群配置"

    echo "协调模式:"
    echo "  1) KRaft (推荐，无需 Zookeeper)"
    echo "  2) Zookeeper"
    read -rp "请选择 [1/2] (默认 1): " c
    if [ "$c" = "2" ]; then
        COORD_MODE="zookeeper"
    else
        COORD_MODE="kraft"
    fi
    info "协调模式: $COORD_MODE"

    read -rp "Kafka 版本 [${KAFKA_VERSION}]: " input; KAFKA_VERSION=${input:-$KAFKA_VERSION}
    read -rp "Scala 版本 [${SCALA_VERSION}]: " input; SCALA_VERSION=${input:-$SCALA_VERSION}
    read -rp "Broker 端口 [${BROKER_PORT}]: " input; BROKER_PORT=${input:-$BROKER_PORT}
    read -rp "Controller 端口 [${CONTROLLER_PORT}]: " input; CONTROLLER_PORT=${input:-$CONTROLLER_PORT}
    read -rp "Zookeeper 端口 [${ZK_PORT}]: " input; ZK_PORT=${input:-$ZK_PORT}

    LOCAL_NODE_IP=$(get_local_ip)
    read -rp "本机对外 IP [${LOCAL_NODE_IP}]: " input; LOCAL_NODE_IP=${input:-$LOCAL_NODE_IP}

    read -rp "本机是否作为集群节点? [Y/n]: " inc
    if [[ "$inc" =~ ^[Nn]$ ]]; then
        INCLUDE_LOCAL_NODE="no"
    else
        INCLUDE_LOCAL_NODE="yes"
    fi
}

collect_remote_nodes() {
    print_title "添加远程 Kafka 节点（可多台，IP 留空结束）"
    REMOTE_NODES=()
    local next_id=1
    if [ "$INCLUDE_LOCAL_NODE" = "yes" ]; then
        next_id=2
    fi
    local idx=1
    while true; do
        read -rp "节点 #${idx} IP/主机名 (空结束): " host
        [ -z "$host" ] && break

        local sport="$SSH_PORT" suser="$SSH_USER" spass="$SSH_PASSWORD"
        local node_id="$next_id"
        local bport="$BROKER_PORT" cport="$CONTROLLER_PORT" zport="$ZK_PORT"
        local custom

        read -rp "  SSH端口 [$SSH_PORT]: " custom; sport=${custom:-$sport}
        read -rp "  SSH用户 [$SSH_USER]: " custom; suser=${custom:-$suser}
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

        read -rp "  节点ID node-id [${node_id}]: " custom; node_id=${custom:-$node_id}
        read -rp "  Broker端口 [${BROKER_PORT}]: " custom; bport=${custom:-$bport}
        if [ "$COORD_MODE" = "kraft" ]; then
            read -rp "  Controller端口 [${CONTROLLER_PORT}]: " custom; cport=${custom:-$cport}
        else
            read -rp "  Zookeeper端口 [${ZK_PORT}]: " custom; zport=${custom:-$zport}
        fi

        REMOTE_NODES+=("${host}|${sport}|${suser}|${spass}|${node_id}|${bport}|${cport}|${zport}")
        success "已添加: $host id=$node_id broker=$bport"
        NEXT_ID=$((node_id + 1))
        next_id=$((next_id + 1))
        # 避免 next_id 与用户输入冲突
        if [ "$next_id" -le "$node_id" ]; then
            next_id=$((node_id + 1))
        fi
        idx=$((idx+1))
    done

    local total=${#REMOTE_NODES[@]}
    if [ "$INCLUDE_LOCAL_NODE" = "yes" ]; then
        total=$((total + 1))
    fi
    if [ "$total" -lt 3 ]; then
        warn "当前节点数=$total，集群建议至少 3 节点"
        confirm_action "仍继续?" || return 1
    fi

    # 汇总生成 quorum / zk-servers
    build_cluster_topology
    return 0
}

build_cluster_topology() {
    local quorum_parts=()
    local zk_hosts=()
    local nodes_csv=()

    if [ "$INCLUDE_LOCAL_NODE" = "yes" ]; then
        if [ "$COORD_MODE" = "kraft" ]; then
            quorum_parts+=("1@${LOCAL_NODE_IP}:${CONTROLLER_PORT}")
        else
            zk_hosts+=("$LOCAL_NODE_IP")
        fi
        nodes_csv+=("${LOCAL_NODE_IP}")
    fi

    local item h p u pw nid bp cp zp
    for item in "${REMOTE_NODES[@]}"; do
        IFS='|' read -r h p u pw nid bp cp zp <<< "$item"
        if [ "$COORD_MODE" = "kraft" ]; then
            quorum_parts+=("${nid}@${h}:${cp}")
        else
            zk_hosts+=("$h")
        fi
        nodes_csv+=("$h")
    done

    if [ "$COORD_MODE" = "kraft" ]; then
        CONTROLLER_QUORUM=$(IFS=','; echo "${quorum_parts[*]}")
        if [ -z "$CLUSTER_UUID" ]; then
            # kafka-storage random-uuid 若本机已有 kafka 可用，否则生成 UUID
            if [ -x "$KAFKA_INSTALL_DIR/bin/kafka-storage.sh" ]; then
                CLUSTER_UUID=$("$KAFKA_INSTALL_DIR/bin/kafka-storage.sh" random-uuid)
            else
                CLUSTER_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || \
                    python -c 'import uuid; print(uuid.uuid4())' 2>/dev/null || echo "")
            fi
            [ -z "$CLUSTER_UUID" ] && error "无法生成集群 UUID"
        fi
        ZK_SERVERS=""
        ZK_CONNECT=""
        info "KRaft quorum: $CONTROLLER_QUORUM"
        info "集群 UUID:   $CLUSTER_UUID"
    else
        local IFS=','
        ZK_SERVERS="${zk_hosts[*]}"
        unset IFS
        ZK_CONNECT=$(echo "$ZK_SERVERS" | awk -F',' -v p="$ZK_PORT" '{for(i=1;i<=NF;i++){printf "%s%s:%s",(i>1?",":""),$i,p}}')
        CONTROLLER_QUORUM=""
        CLUSTER_UUID=""
        info "ZK servers: $ZK_SERVERS"
        info "ZK connect: $ZK_CONNECT"
    fi
    info "节点数: ${#nodes_csv[@]}"
}

save_cluster_state() {
    {
        echo "# Kafka cluster deploy - $(date)"
        echo "KAFKA_VERSION=$KAFKA_VERSION"
        echo "SCALA_VERSION=$SCALA_VERSION"
        echo "COORD_MODE=$COORD_MODE"
        echo "BROKER_PORT=$BROKER_PORT"
        echo "CONTROLLER_PORT=$CONTROLLER_PORT"
        echo "ZK_PORT=$ZK_PORT"
        echo "LOCAL_NODE_IP=$LOCAL_NODE_IP"
        echo "INCLUDE_LOCAL_NODE=$INCLUDE_LOCAL_NODE"
        echo "CLUSTER_UUID=$CLUSTER_UUID"
        echo "CONTROLLER_QUORUM=$CONTROLLER_QUORUM"
        echo "ZK_SERVERS=$ZK_SERVERS"
        echo "ZK_CONNECT=$ZK_CONNECT"
        echo "SSH_USER=$SSH_USER"
        echo "SSH_PORT=$SSH_PORT"
        echo "SSH_KEY=$SSH_KEY"
        echo "KAFKA_TGZ=$KAFKA_TGZ"
        echo "REMOTE_NODES_STR=${REMOTE_NODES[*]}"
    } > "$CLUSTER_STATE_FILE"
    chmod 600 "$CLUSTER_STATE_FILE"
    success "集群状态: $CLUSTER_STATE_FILE"
}

load_cluster_state() {
    if [ -f "$CLUSTER_STATE_FILE" ]; then
        # shellcheck source=/dev/null
        . "$CLUSTER_STATE_FILE"
        if [ -n "$REMOTE_NODES_STR" ]; then
            read -r -a REMOTE_NODES <<< "$REMOTE_NODES_STR"
        fi
        return 0
    fi
    return 1
}

# ======================== 本机安装 ========================
install_local_kafka() {
    print_title "本机安装 Kafka 节点"
    if [ ! -f "$INSTALL_SCRIPT" ]; then
        error "未找到 $INSTALL_SCRIPT"
    fi

    ensure_package_tgz || confirm_action "无安装包，本机将在线下载。继续?" || return 1

    local local_id=1
    if [ "$INCLUDE_LOCAL_NODE" = "no" ]; then
        info "本机不作为数据节点，仅编排"
        return 0
    fi

    local args=(
        --cluster
        --coord "$COORD_MODE"
        --version "$KAFKA_VERSION"
        --scala "$SCALA_VERSION"
        --node-id 1
        --broker-port "$BROKER_PORT"
        --advertised-host "$LOCAL_NODE_IP"
    )
    if [ "$COORD_MODE" = "kraft" ]; then
        args+=(--controller-port "$CONTROLLER_PORT" --quorum "$CONTROLLER_QUORUM" --cluster-uuid "$CLUSTER_UUID")
    else
        args+=(--zk-port "$ZK_PORT" --zk-servers "$ZK_SERVERS" --zk-connect "$ZK_CONNECT")
    fi

    info "执行: bash install_kafka.sh ${args[*]}"
    bash "$INSTALL_SCRIPT" "${args[@]}" || error "本机 Kafka 安装失败"
    success "本机 Kafka 节点安装完成"
}

# ======================== 远程安装 ========================
remote_install_kafka() {
    local host="$1" sport="$2" suser="$3" spass="$4"
    local nid="$5" bport="$6" cport="$7" zport="$8"

    print_title "远程安装 Kafka → ${host} (id=$nid)"

    local old_port="$SSH_PORT" old_user="$SSH_USER" old_pass="$SSH_PASSWORD"
    with_node_ssh "$host" "$sport" "$suser" "$spass"

    test_ssh_connection "$host" || {
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 1
    }

    # Java 检查/安装
    local has_java
    has_java=$(ssh_cmd "$host" "command -v java >/dev/null && echo YES || echo NO")
    if [ "$has_java" != "YES" ]; then
        warn "远程未检测到 Java，尝试安装..."
        ssh_cmd "$host" "if command -v apt-get >/dev/null; then apt-get update -y && apt-get install -y openjdk-17-jdk; elif command -v dnf >/dev/null; then dnf install -y java-17-openjdk; elif command -v yum >/dev/null; then yum install -y java-17-openjdk; fi" || true
        has_java=$(ssh_cmd "$host" "command -v java >/dev/null && echo YES || echo NO")
        if [ "$has_java" != "YES" ]; then
            warn "远程 Java 安装失败，请手动安装 JDK11+"
            SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
            return 1
        fi
    fi

    if [ -z "$KAFKA_TGZ" ] || [ ! -f "$KAFKA_TGZ" ]; then
        ensure_package_tgz || {
            SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
            return 1
        }
    fi

    local tgz_name
    tgz_name=$(basename "$KAFKA_TGZ")

    info "上传脚本与安装包..."
    ssh_cmd "$host" "mkdir -p /tmp/kafka_cluster_install/package" || true
    scp_to_remote "$INSTALL_SCRIPT" "$host" "/tmp/kafka_cluster_install/install_kafka.sh" || {
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"; return 1
    }
    scp_to_remote "$KAFKA_TGZ" "$host" "/tmp/kafka_cluster_install/package/${tgz_name}" || {
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"; return 1
    }

    local remote_cmd="bash /tmp/kafka_cluster_install/install_kafka.sh --cluster --coord '${COORD_MODE}' --version '${KAFKA_VERSION}' --scala '${SCALA_VERSION}' --node-id '${nid}' --broker-port '${bport}' --advertised-host '${host}'"
    if [ "$COORD_MODE" = "kraft" ]; then
        remote_cmd="${remote_cmd} --controller-port '${cport}' --quorum '${CONTROLLER_QUORUM}' --cluster-uuid '${CLUSTER_UUID}'"
    else
        remote_cmd="${remote_cmd} --zk-port '${zport}' --zk-servers '${ZK_SERVERS}' --zk-connect '${ZK_CONNECT}'"
    fi

    info "远程执行: $remote_cmd"
    if ssh_cmd "$host" "$remote_cmd"; then
        success "${host} Kafka 安装完成"
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 0
    fi
    warn "${host} Kafka 安装失败"
    SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
    return 1
}

# ======================== 状态检查 ========================
check_cluster_status() {
    print_title "Kafka 集群状态"
    load_cluster_state || true

    if [ "$INCLUDE_LOCAL_NODE" = "yes" ]; then
        echo -n "  本机 ${LOCAL_NODE_IP}: "
        if systemctl is-active --quiet kafka 2>/dev/null; then
            echo -e "${GREEN}active${NC}"
        else
            echo -e "${RED}inactive${NC}"
        fi
        # 可选：metadata 查主题
        if [ -x "$KAFKA_INSTALL_DIR/bin/kafka-metadata-shell.sh" ] && [ "$COORD_MODE" = "kraft" ]; then
            info "可选: $KAFKA_INSTALL_DIR/bin/kafka-topics.sh --list --bootstrap-server ${LOCAL_NODE_IP}:${BROKER_PORT}"
        fi
    fi

    local item h p u pw nid bp cp zp
    for item in "${REMOTE_NODES[@]}"; do
        IFS='|' read -r h p u pw nid bp cp zp <<< "$item"
        local old_port="$SSH_PORT" old_user="$SSH_USER" old_pass="$SSH_PASSWORD"
        with_node_ssh "$h" "$p" "$u" "$pw"
        echo -n "  远程 ${h} (id=${nid}): "
        local st
        st=$(ssh_cmd "$h" "systemctl is-active kafka 2>/dev/null || echo inactive")
        if [ "$st" = "active" ]; then
            echo -e "${GREEN}active${NC}"
        else
            echo -e "${YELLOW}${st}${NC}"
        fi
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
    done

    echo ""
    if [ "$COORD_MODE" = "kraft" ]; then
        info "Bootstrap: ${LOCAL_NODE_IP:-<node>}:${BROKER_PORT}"
        info "测试: $KAFKA_INSTALL_DIR/bin/kafka-topics.sh --list --bootstrap-server ${LOCAL_NODE_IP}:${BROKER_PORT}"
    else
        info "Bootstrap: ${LOCAL_NODE_IP:-<node>}:${BROKER_PORT}  ZK: ${ZK_CONNECT}"
    fi
}

# ======================== 一键部署 ========================
one_click_deploy() {
    print_title "一键 Kafka 多机集群部署"
    echo "流程: 收集节点 → 本机安装 → 打包同步 → SSH 远程安装 → 校验"
    echo "要求: JDK11+；节点间端口互通（KRaft: broker+controller；ZK: 2181/2888/3888 + broker）"
    echo ""
    confirm_action "开始一键部署?" || return 1

    collect_ssh_info
    collect_cluster_config
    collect_remote_nodes

    echo ""
    info "部署摘要:"
    info "  协调: $COORD_MODE  版本: $KAFKA_VERSION"
    info "  本机节点: $INCLUDE_LOCAL_NODE  IP=$LOCAL_NODE_IP"
    if [ "$COORD_MODE" = "kraft" ]; then
        info "  quorum: $CONTROLLER_QUORUM"
        info "  uuid: $CLUSTER_UUID"
    else
        info "  zk-servers: $ZK_SERVERS"
    fi
    info "  远程节点数: ${#REMOTE_NODES[@]}"
    confirm_action "确认开始部署?" || return 1

    echo ""
    info "===== 步骤 A: 准备安装包 ====="
    ensure_package_tgz || confirm_action "打包失败，远程将自行下载。继续?" || return 1

    echo ""
    info "===== 步骤 B: 本机节点 ====="
    install_local_kafka

    local failed=0 idx=1
    for item in "${REMOTE_NODES[@]}"; do
        IFS='|' read -r h p u pw nid bp cp zp <<< "$item"
        echo ""
        info "===== 步骤 C.${idx}: ${h} ====="
        remote_install_kafka "$h" "$p" "$u" "$pw" "$nid" "$bp" "$cp" "$zp" || failed=$((failed+1))
        idx=$((idx+1))
    done

    save_cluster_state

    echo ""
    print_title "部署结束"
    info "远程成功: $(( ${#REMOTE_NODES[@]} - failed )) / ${#REMOTE_NODES[@]}"
    [ $failed -gt 0 ] && warn "失败 $failed 个，请检查上方日志"
    info "后续: bash $0 status"
    echo ""
    check_cluster_status
    return 0
}

# ======================== 帮助/菜单 ========================
show_help() {
    cat <<EOF
Kafka 多机集群一键部署脚本

用法: bash setup_kafka_cluster.sh [命令]

命令:
  one       一键部署（本机 + SSH 远程）
  status    查看节点状态
  help      帮助

说明:
  - 支持 KRaft 与 Zookeeper 两种协调模式
  - 自动收集节点列表，生成 quorum / cluster-uuid 或 zk-servers
  - 远程需 JDK11+ 与 systemd（脚本会尝试安装 OpenJDK）
  - 依赖 install_kafka.sh 与 package/kafka_*.tgz
EOF
}

show_main_menu() {
    print_title "Kafka 集群配置工具"
    echo "本机IP: $(get_local_ip)"
    if [ -f "$CLUSTER_STATE_FILE" ]; then
        echo "已存在集群状态文件"
    fi
    echo ""
    echo "请选择操作:"
    echo ""
    echo -e "  ${GREEN}1. 一键部署 Kafka 集群${NC}（SSH远程安装）"
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
