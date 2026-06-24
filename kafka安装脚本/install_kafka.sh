#!/bin/bash

# Kafka 自动化安装脚本（Linux）
# 支持 KRaft 模式（无需 Zookeeper）与 Zookeeper 模式两种协调方式
# 支持单机与集群部署
# 本地 package/ 目录优先，缺失时自动从 Apache 官方下载
# 兼容 Ubuntu 22/24、Debian 12、CentOS Stream/Rocky/AlmaLinux 8/9

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 检查是否使用 bash 执行
if [ -z "$BASH_VERSION" ]; then
    echo -e "${RED}错误: 请使用 bash 执行此脚本，而不是 sh${NC}"
    exit 1
fi

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}此脚本需要以 root 权限运行${NC}"
    exit 1
fi

# ======================== 全局变量 ========================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 默认配置（可通过命令行参数或交互覆盖）
KAFKA_VERSION="${KAFKA_VERSION:-3.9.0}"
SCALA_VERSION="${SCALA_VERSION:-2.13}"
KAFKA_INSTALL_DIR="/usr/local/kafka"
KAFKA_DATA_DIR="/var/lib/kafka"
KAFKA_PACKAGE_DIR="$SCRIPT_DIR/package"

# 部署模式：standalone 或 cluster
DEPLOY_MODE=""

# 协调模式：kraft 或 zookeeper
COORD_MODE=""

# 端口配置
BROKER_PORT="9092"        # 客户端连接端口（PLAINTEXT）
CONTROLLER_PORT="9093"    # KRaft controller 通信端口
ZK_PORT="2181"            # Zookeeper 客户端端口（zookeeper 模式）

# 节点信息
NODE_ID="1"               # 当前节点的唯一 ID（整数）
ADVERTISED_HOST=""        # 对外发布的地址，默认取本机 IP
# 集群所有 controller 节点列表，格式 nodeId@host:controllerPort，逗号分隔
# 例如: 1@192.168.1.10:9093,2@192.168.1.11:9093,3@192.168.1.12:9093
CONTROLLER_QUORUM=""
CLUSTER_UUID=""           # 集群唯一标识，集群所有节点必须一致

# Zookeeper 模式相关
# 客户端连接串，格式 host:port,host:port,...；单机默认本机
ZK_CONNECT=""
# Zookeeper 集群所有节点列表（用于生成 zoo.cfg 的 server.N 行），格式 host,host,...
ZK_SERVERS=""
ZK_DATA_DIR="/var/lib/zookeeper"

NON_INTERACTIVE="false"

DOWNLOAD_BASE="https://downloads.apache.org/kafka"

# ======================== 函数定义 ========================

info()    { echo -e "${CYAN}[INFO] $1${NC}"; }
success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }
warn()    { echo -e "${YELLOW}[WARN] $1${NC}"; }
error()   { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

usage() {
    cat <<EOF
Kafka 自动化安装脚本（Linux，支持 KRaft / Zookeeper 两种模式）

用法: bash install_kafka.sh [选项]

选项:
  --standalone               单机模式部署
  --cluster                  集群模式部署
  --coord <kraft|zookeeper>  协调模式（默认 kraft）
  --version <版本号>         Kafka 版本（默认 ${KAFKA_VERSION}）
  --scala <版本号>           Scala 版本（默认 ${SCALA_VERSION}）
  --node-id <id>             本节点 ID（整数，集群内唯一，默认 ${NODE_ID}）
  --broker-port <端口>       客户端连接端口（默认 ${BROKER_PORT}）
  --controller-port <端口>   KRaft controller 通信端口（默认 ${CONTROLLER_PORT}）
  --advertised-host <host>   对外发布地址（默认本机 IP）
  --quorum <列表>            [KRaft] 集群 controller 列表（KRaft 集群必填）
                             格式: id@host:port,id@host:port,...
  --cluster-uuid <uuid>      [KRaft] 集群唯一标识（KRaft 集群所有节点须一致）
  --zk-port <端口>           [ZK] Zookeeper 客户端端口（默认 ${ZK_PORT}）
  --zk-connect <连接串>      [ZK] Zookeeper 连接串 host:port,...（ZK 模式 broker 连接用）
  --zk-servers <列表>        [ZK] Zookeeper 集群节点列表 host,host,...（ZK 集群必填）
  -h, --help                 显示此帮助

示例:
  # 交互式安装（会询问协调模式）
  bash install_kafka.sh

  # KRaft 单机
  bash install_kafka.sh --standalone --coord kraft

  # Zookeeper 单机（单机内同时起 ZK 与 Kafka）
  bash install_kafka.sh --standalone --coord zookeeper

  # KRaft 集群首节点
  bash install_kafka.sh --cluster --coord kraft --node-id 1 --advertised-host 192.168.1.10 \\
    --quorum 1@192.168.1.10:9093,2@192.168.1.11:9093,3@192.168.1.12:9093

  # Zookeeper 集群节点（各节点 node-id 唯一，zk-servers 一致）
  bash install_kafka.sh --cluster --coord zookeeper --node-id 1 --advertised-host 192.168.1.10 \\
    --zk-servers 192.168.1.10,192.168.1.11,192.168.1.12
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --standalone) DEPLOY_MODE="standalone"; NON_INTERACTIVE="true"; shift ;;
            --cluster) DEPLOY_MODE="cluster"; NON_INTERACTIVE="true"; shift ;;
            --coord) COORD_MODE="$2"; shift 2 ;;
            --version) KAFKA_VERSION="$2"; shift 2 ;;
            --scala) SCALA_VERSION="$2"; shift 2 ;;
            --node-id) NODE_ID="$2"; shift 2 ;;
            --broker-port) BROKER_PORT="$2"; validate_port "$BROKER_PORT" "Broker"; shift 2 ;;
            --controller-port) CONTROLLER_PORT="$2"; validate_port "$CONTROLLER_PORT" "Controller"; shift 2 ;;
            --advertised-host) ADVERTISED_HOST="$2"; shift 2 ;;
            --quorum) CONTROLLER_QUORUM="$2"; shift 2 ;;
            --cluster-uuid) CLUSTER_UUID="$2"; shift 2 ;;
            --zk-port) ZK_PORT="$2"; validate_port "$ZK_PORT" "Zookeeper"; shift 2 ;;
            --zk-connect) ZK_CONNECT="$2"; shift 2 ;;
            --zk-servers) ZK_SERVERS="$2"; shift 2 ;;
            -h|--help) usage ;;
            *) error "未知参数: $1（使用 --help 查看帮助）" ;;
        esac
    done
}

# 检测操作系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    else
        error "无法检测操作系统版本"
    fi
    info "检测到操作系统: $OS $OS_VERSION"
}

# 安装基础依赖
install_dependencies() {
    info "检查并安装基础依赖..."
    case $OS in
        ubuntu|debian)
            apt-get update -y || error "apt-get update 失败，请检查网络或软件源配置"
            apt-get install -y wget tar || error "安装依赖失败，请检查网络或软件源配置"
            ;;
        centos|rhel|rocky|almalinux)
            dnf install -y wget tar || error "安装依赖失败，请检查网络或软件源配置"
            ;;
        *)
            warn "未识别的操作系统，跳过依赖安装"
            ;;
    esac
}

# 检查 Java 环境（Kafka 需要 JDK 11 及以上）
check_java() {
    info "检查 Java 环境..."
    if ! command -v java > /dev/null 2>&1; then
        error "未检测到 Java 环境，Kafka 需要 JDK 11 及以上。请先安装 JDK 并配置 JAVA_HOME"
    fi
    local java_ver
    java_ver=$(java -version 2>&1 | head -n1)
    info "Java 版本: $java_ver"
}

# 校验端口是否为有效数字（1-65535）
validate_port() {
    local port="$1" name="$2"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        error "${name} 端口无效: '$port'，请输入 1-65535 之间的数字"
    fi
}

# 交互式收集基础信息
collect_basic_info() {
    if [ "$NON_INTERACTIVE" = "true" ]; then
        return
    fi
    echo ""
    info "基础配置（直接回车使用默认值）"
    read -rp "Kafka 版本 (默认 $KAFKA_VERSION): " input; KAFKA_VERSION="${input:-$KAFKA_VERSION}"
    read -rp "Scala 版本 (默认 $SCALA_VERSION): " input; SCALA_VERSION="${input:-$SCALA_VERSION}"
    read -rp "Broker 客户端端口 (默认 $BROKER_PORT): " input; BROKER_PORT="${input:-$BROKER_PORT}"
    validate_port "$BROKER_PORT" "Broker"
    read -rp "Controller 端口 (默认 $CONTROLLER_PORT): " input; CONTROLLER_PORT="${input:-$CONTROLLER_PORT}"
    validate_port "$CONTROLLER_PORT" "Controller"
    info "版本: $KAFKA_VERSION (Scala $SCALA_VERSION)  Broker: $BROKER_PORT  Controller: $CONTROLLER_PORT"
}

# 交互式选择部署模式
choose_mode() {
    if [ -n "$DEPLOY_MODE" ]; then
        return
    fi
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

# 交互式选择协调模式（KRaft / Zookeeper）
choose_coord() {
    if [ -n "$COORD_MODE" ]; then
        return
    fi
    echo ""
    echo "请选择协调模式:"
    echo "  1) KRaft      (无需 Zookeeper，官方推荐)"
    echo "  2) Zookeeper  (传统模式，使用 Kafka 自带的 Zookeeper)"
    read -rp "请输入选项 [1-2] (默认 1): " choice
    case "$choice" in
        2) COORD_MODE="zookeeper" ;;
        *) COORD_MODE="kraft" ;;
    esac
    info "已选择协调模式: $COORD_MODE"
}

# 校验协调模式合法性，并对 Kafka 4.x + zookeeper 组合给出错误
validate_coord() {
    case "$COORD_MODE" in
        kraft|zookeeper) ;;
        *) error "协调模式无效: '$COORD_MODE'，仅支持 kraft 或 zookeeper" ;;
    esac
    if [ "$COORD_MODE" = "zookeeper" ]; then
        local major
        major=$(echo "$KAFKA_VERSION" | cut -d. -f1)
        if [[ "$major" =~ ^[0-9]+$ ]] && [ "$major" -ge 4 ]; then
            error "Kafka ${KAFKA_VERSION} 已移除 Zookeeper，无法使用 zookeeper 模式。请改用 KRaft，或选择 Kafka 3.x 版本"
        fi
    fi
}

# 收集节点与集群信息
collect_node_info() {
    # 确定对外发布地址
    if [ -z "$ADVERTISED_HOST" ]; then
        ADVERTISED_HOST=$(hostname -I 2>/dev/null | awk '{print $1}')
        [ -z "$ADVERTISED_HOST" ] && ADVERTISED_HOST="127.0.0.1"
    fi

    if [ "$COORD_MODE" = "zookeeper" ]; then
        collect_zk_info
    else
        collect_kraft_info
    fi
}

# 收集 KRaft 协调信息
collect_kraft_info() {
    if [ "$DEPLOY_MODE" = "standalone" ]; then
        # 单机：节点既是 controller 也是 broker
        NODE_ID="${NODE_ID:-1}"
        CONTROLLER_QUORUM="${NODE_ID}@${ADVERTISED_HOST}:${CONTROLLER_PORT}"
        return
    fi

    # 集群模式
    if [ "$NON_INTERACTIVE" != "true" ]; then
        echo ""
        info "配置 KRaft 集群节点信息"
        read -rp "本节点 ID (整数，集群内唯一，默认 $NODE_ID): " input; NODE_ID="${input:-$NODE_ID}"
        read -rp "本节点对外发布地址 (默认 $ADVERTISED_HOST): " input; ADVERTISED_HOST="${input:-$ADVERTISED_HOST}"
        echo "请输入集群所有 controller 节点列表"
        echo "格式: id@host:controllerPort，逗号分隔"
        echo "例如: 1@192.168.1.10:9093,2@192.168.1.11:9093,3@192.168.1.12:9093"
        read -rp "controller 列表: " input; CONTROLLER_QUORUM="${input:-$CONTROLLER_QUORUM}"
        echo ""
        echo "集群 UUID（所有节点必须使用同一个）:"
        echo "  - 首个节点请直接回车，脚本会自动生成并打印"
        echo "  - 其他节点请填入首节点生成的 UUID"
        read -rp "集群 UUID (留空则自动生成): " input; CLUSTER_UUID="${input:-$CLUSTER_UUID}"
    fi

    [ -z "$CONTROLLER_QUORUM" ] && error "KRaft 集群模式必须提供 controller 列表（--quorum）"
    if ! [[ "$NODE_ID" =~ ^[0-9]+$ ]]; then
        error "节点 ID 无效: '$NODE_ID'，必须为整数"
    fi
}

# 收集 Zookeeper 协调信息
collect_zk_info() {
    if [ "$DEPLOY_MODE" = "standalone" ]; then
        # 单机：本机同时运行 Zookeeper 与 Kafka
        NODE_ID="${NODE_ID:-1}"
        [ -z "$ZK_CONNECT" ] && ZK_CONNECT="localhost:${ZK_PORT}"
        return
    fi

    # 集群模式
    if [ "$NON_INTERACTIVE" != "true" ]; then
        echo ""
        info "配置 Zookeeper 集群节点信息"
        read -rp "本节点 broker ID (整数，集群内唯一，默认 $NODE_ID): " input; NODE_ID="${input:-$NODE_ID}"
        read -rp "本节点对外发布地址 (默认 $ADVERTISED_HOST): " input; ADVERTISED_HOST="${input:-$ADVERTISED_HOST}"
        echo "请输入 Zookeeper 集群所有节点（仅主机/IP，逗号分隔，端口统一为 $ZK_PORT）"
        echo "例如: 192.168.1.10,192.168.1.11,192.168.1.12"
        read -rp "Zookeeper 节点列表: " input; ZK_SERVERS="${input:-$ZK_SERVERS}"
    fi

    [ -z "$ZK_SERVERS" ] && error "Zookeeper 集群模式必须提供节点列表（--zk-servers）"
    if ! [[ "$NODE_ID" =~ ^[0-9]+$ ]]; then
        error "节点 ID 无效: '$NODE_ID'，必须为整数"
    fi

    # 由 ZK_SERVERS 生成 broker 连接串（host:port,host:port,...）
    if [ -z "$ZK_CONNECT" ]; then
        ZK_CONNECT=$(echo "$ZK_SERVERS" | awk -F',' -v p="$ZK_PORT" '{for(i=1;i<=NF;i++){printf "%s%s:%s",(i>1?",":""),$i,p}}')
    fi
}

# 准备安装包（本地优先，否则下载）
prepare_package() {
    local pkg_name="kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz"
    local local_pkg="$KAFKA_PACKAGE_DIR/$pkg_name"
    KAFKA_TGZ="$local_pkg"

    mkdir -p "$KAFKA_PACKAGE_DIR"

    if [ -f "$local_pkg" ]; then
        info "使用本地安装包: $local_pkg"
        return
    fi

    local url="${DOWNLOAD_BASE}/${KAFKA_VERSION}/${pkg_name}"
    info "本地未找到安装包，从 Apache 官方下载: $url"
    if ! wget --timeout=60 --tries=3 -O "$local_pkg" "$url"; then
        rm -f "$local_pkg"
        error "下载 Kafka 失败（网络超时或版本不存在），请检查网络或手动将 $pkg_name 放入 $KAFKA_PACKAGE_DIR"
    fi
    # 校验下载文件大小（< 10MB 视为无效，如 404 页面）
    local file_size
    file_size=$(stat -c%s "$local_pkg" 2>/dev/null || echo 0)
    if [ "$file_size" -lt 10485760 ]; then
        rm -f "$local_pkg"
        error "下载的文件大小异常（${file_size}B），版本号可能不存在，请确认 Kafka/Scala 版本后重试"
    fi
    success "下载完成: $local_pkg（$(numfmt --to=iec "$file_size")）"
}

# 解压部署
deploy_kafka() {
    if [ -d "$KAFKA_INSTALL_DIR" ]; then
        warn "检测到已存在安装目录: $KAFKA_INSTALL_DIR"
        if [ "$NON_INTERACTIVE" != "true" ]; then
            read -rp "是否覆盖安装？(y/N): " confirm
            [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && error "已取消安装"
        fi
        rm -rf "$KAFKA_INSTALL_DIR"
    fi

    info "解压安装包到 /usr/local ..."
    local tmp_dir="/usr/local"
    if ! tar -zxf "$KAFKA_TGZ" -C "$tmp_dir"; then
        error "解压失败，安装包可能已损坏。请重新下载或手动验证 $KAFKA_TGZ"
    fi
    # 解压后目录形如 kafka_2.13-3.9.0，统一重命名为 kafka
    local extracted
    extracted=$(find "$tmp_dir" -maxdepth 1 -type d -name "kafka_${SCALA_VERSION}-${KAFKA_VERSION}" | head -n1)
    [ -z "$extracted" ] && error "解压后未找到 Kafka 目录，安装包结构异常"
    mv "$extracted" "$KAFKA_INSTALL_DIR" || error "重命名安装目录失败，请检查 /usr/local 权限"

    mkdir -p "$KAFKA_DATA_DIR"
    success "Kafka 已部署到 $KAFKA_INSTALL_DIR"
}

# 生成 Kafka 配置（按协调模式分发）
configure_kafka() {
    if [ "$COORD_MODE" = "zookeeper" ]; then
        configure_zookeeper
        configure_kafka_zk
    else
        configure_kraft
    fi
}

# 生成 KRaft server.properties
configure_kraft() {
    local conf="$KAFKA_INSTALL_DIR/config/kraft/server.properties"
    if [ ! -f "$conf" ]; then
        # 某些版本路径为 config/server.properties
        conf="$KAFKA_INSTALL_DIR/config/server.properties"
    fi
    [ ! -f "$conf" ] && error "未找到 server.properties 模板，安装包结构异常"

    info "生成 KRaft 配置 $conf ..."

    local listeners advertised roles
    if [ "$DEPLOY_MODE" = "standalone" ]; then
        roles="broker,controller"
        listeners="PLAINTEXT://:${BROKER_PORT},CONTROLLER://:${CONTROLLER_PORT}"
        advertised="PLAINTEXT://${ADVERTISED_HOST}:${BROKER_PORT}"
    else
        roles="broker,controller"
        listeners="PLAINTEXT://:${BROKER_PORT},CONTROLLER://:${CONTROLLER_PORT}"
        advertised="PLAINTEXT://${ADVERTISED_HOST}:${BROKER_PORT}"
    fi

    cat > "$conf" <<EOF
# Kafka KRaft 配置（由自动化脚本生成）
process.roles=${roles}
node.id=${NODE_ID}
controller.quorum.voters=${CONTROLLER_QUORUM}

listeners=${listeners}
advertised.listeners=${advertised}
controller.listener.names=CONTROLLER
listener.security.protocol.map=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT,SSL:SSL,SASL_PLAINTEXT:SASL_PLAINTEXT,SASL_SSL:SASL_SSL
inter.broker.listener.name=PLAINTEXT

log.dirs=${KAFKA_DATA_DIR}
num.partitions=3
default.replication.factor=1
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1

num.network.threads=3
num.io.threads=8
socket.send.buffer.bytes=102400
socket.receive.buffer.bytes=102400
socket.request.max.bytes=104857600
log.retention.hours=168
log.segment.bytes=1073741824
log.retention.check.interval.ms=300000
EOF

    # 集群模式调整副本因子建议值
    if [ "$DEPLOY_MODE" = "cluster" ]; then
        local node_count
        node_count=$(echo "$CONTROLLER_QUORUM" | awk -F',' '{print NF}')
        local rf=$node_count
        [ "$rf" -gt 3 ] && rf=3
        sed -i "s/^default.replication.factor=.*/default.replication.factor=${rf}/" "$conf"
        sed -i "s/^offsets.topic.replication.factor=.*/offsets.topic.replication.factor=${rf}/" "$conf"
        sed -i "s/^transaction.state.log.replication.factor=.*/transaction.state.log.replication.factor=${rf}/" "$conf"
        local min_isr=$(( rf > 1 ? rf - 1 : 1 ))
        sed -i "s/^transaction.state.log.min.isr=.*/transaction.state.log.min.isr=${min_isr}/" "$conf"
    fi

    KAFKA_CONF="$conf"
    success "KRaft 配置生成完成"
}

# 生成 Zookeeper 配置 zoo.cfg + myid
configure_zookeeper() {
    local zk_conf="$KAFKA_INSTALL_DIR/config/zookeeper.properties"
    [ ! -f "$zk_conf" ] && error "未找到 zookeeper.properties 模板，安装包结构异常（该 Kafka 版本可能不含 Zookeeper）"

    info "生成 Zookeeper 配置 $zk_conf ..."
    mkdir -p "$ZK_DATA_DIR"

    cat > "$zk_conf" <<EOF
# Zookeeper 配置（由自动化脚本生成）
dataDir=${ZK_DATA_DIR}
clientPort=${ZK_PORT}
maxClientCnxns=60
admin.enableServer=false
tickTime=2000
initLimit=10
syncLimit=5
EOF

    if [ "$DEPLOY_MODE" = "cluster" ]; then
        # 生成 server.N 行；其中本节点对应一个 myid
        local idx=1 my_zk_id=1
        local IFS=','
        for host in $ZK_SERVERS; do
            host=$(echo "$host" | xargs)  # 去除空白
            echo "server.${idx}=${host}:2888:3888" >> "$zk_conf"
            # 判断本机：advertised-host 匹配则记录 myid
            if [ "$host" = "$ADVERTISED_HOST" ]; then
                my_zk_id=$idx
            fi
            idx=$((idx + 1))
        done
        unset IFS
        echo "$my_zk_id" > "$ZK_DATA_DIR/myid"
        info "本节点 Zookeeper myid: $my_zk_id"
    fi

    ZK_CONF="$zk_conf"
    success "Zookeeper 配置生成完成"
}

# 生成 Zookeeper 模式下的 server.properties
configure_kafka_zk() {
    local conf="$KAFKA_INSTALL_DIR/config/server.properties"
    [ ! -f "$conf" ] && error "未找到 server.properties 模板，安装包结构异常"

    info "生成 Kafka（Zookeeper 模式）配置 $conf ..."

    local rf=1 min_isr=1
    if [ "$DEPLOY_MODE" = "cluster" ]; then
        local node_count
        node_count=$(echo "$ZK_SERVERS" | awk -F',' '{print NF}')
        rf=$node_count
        [ "$rf" -gt 3 ] && rf=3
        min_isr=$(( rf > 1 ? rf - 1 : 1 ))
    fi

    cat > "$conf" <<EOF
# Kafka（Zookeeper 模式）配置（由自动化脚本生成）
broker.id=${NODE_ID}
listeners=PLAINTEXT://:${BROKER_PORT}
advertised.listeners=PLAINTEXT://${ADVERTISED_HOST}:${BROKER_PORT}
inter.broker.listener.name=PLAINTEXT

zookeeper.connect=${ZK_CONNECT}
zookeeper.connection.timeout.ms=18000

log.dirs=${KAFKA_DATA_DIR}
num.partitions=3
default.replication.factor=${rf}
offsets.topic.replication.factor=${rf}
transaction.state.log.replication.factor=${rf}
transaction.state.log.min.isr=${min_isr}

num.network.threads=3
num.io.threads=8
socket.send.buffer.bytes=102400
socket.receive.buffer.bytes=102400
socket.request.max.bytes=104857600
log.retention.hours=168
log.segment.bytes=1073741824
log.retention.check.interval.ms=300000
EOF

    KAFKA_CONF="$conf"
    success "Kafka（Zookeeper 模式）配置生成完成"
}

# 格式化存储目录（KRaft 必需）
format_storage() {
    # Zookeeper 模式无需格式化存储
    if [ "$COORD_MODE" = "zookeeper" ]; then
        return
    fi
    # 集群所有节点必须使用同一个 cluster UUID
    if [ -z "$CLUSTER_UUID" ]; then
        CLUSTER_UUID=$("$KAFKA_INSTALL_DIR/bin/kafka-storage.sh" random-uuid)
        info "已自动生成集群 UUID: $CLUSTER_UUID"
        if [ "$DEPLOY_MODE" = "cluster" ]; then
            warn "请记录此 UUID，集群其他节点安装时必须使用 --cluster-uuid $CLUSTER_UUID"
        fi
    fi

    info "格式化 KRaft 存储目录..."
    if ! "$KAFKA_INSTALL_DIR/bin/kafka-storage.sh" format \
        -t "$CLUSTER_UUID" \
        -c "$KAFKA_CONF" --ignore-formatted; then
        error "存储格式化失败，请检查配置 $KAFKA_CONF 与 UUID 是否正确"
    fi
    success "存储目录格式化完成"
}

# 创建 systemd 服务
create_systemd_service() {
    info "创建 systemd 服务..."
    local java_home
    java_home=$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")

    local kafka_after="network.target"
    local kafka_desc="Apache Kafka Server (KRaft mode)"

    # Zookeeper 模式：额外创建 zookeeper.service，并让 kafka 依赖它
    if [ "$COORD_MODE" = "zookeeper" ]; then
        kafka_after="network.target zookeeper.service"
        kafka_desc="Apache Kafka Server (Zookeeper mode)"
        cat > /etc/systemd/system/zookeeper.service <<EOF
[Unit]
Description=Apache Zookeeper Server (for Kafka)
Documentation=https://kafka.apache.org/documentation/
Requires=network.target
After=network.target

[Service]
Type=simple
Environment="JAVA_HOME=${java_home}"
ExecStart=${KAFKA_INSTALL_DIR}/bin/zookeeper-server-start.sh ${ZK_CONF}
ExecStop=${KAFKA_INSTALL_DIR}/bin/zookeeper-server-stop.sh
Restart=on-failure
RestartSec=5
LimitNOFILE=100000
WorkingDirectory=${KAFKA_INSTALL_DIR}

[Install]
WantedBy=multi-user.target
EOF
    fi

    cat > /etc/systemd/system/kafka.service <<EOF
[Unit]
Description=${kafka_desc}
Documentation=https://kafka.apache.org/documentation/
After=${kafka_after}
EOF
    if [ "$COORD_MODE" = "zookeeper" ]; then
        echo "Requires=zookeeper.service" >> /etc/systemd/system/kafka.service
    fi
    cat >> /etc/systemd/system/kafka.service <<EOF

[Service]
Type=simple
Environment="JAVA_HOME=${java_home}"
ExecStart=${KAFKA_INSTALL_DIR}/bin/kafka-server-start.sh ${KAFKA_CONF}
ExecStop=${KAFKA_INSTALL_DIR}/bin/kafka-server-stop.sh
Restart=on-failure
RestartSec=5
LimitNOFILE=100000
WorkingDirectory=${KAFKA_INSTALL_DIR}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    if [ "$COORD_MODE" = "zookeeper" ]; then
        systemctl enable zookeeper 2>/dev/null || warn "zookeeper 服务启用失败"
    fi
    if ! systemctl enable kafka; then
        warn "systemd 服务启用失败，可能 systemd 未正确初始化，但服务文件已写入"
    fi
    success "systemd 服务创建完成（服务名: kafka${COORD_MODE:+$([ "$COORD_MODE" = zookeeper ] && echo ' + zookeeper')}）"
}

# 启动并验证
start_and_verify() {
    # Zookeeper 模式先启动 ZK
    if [ "$COORD_MODE" = "zookeeper" ]; then
        info "启动 Zookeeper 服务..."
        systemctl start zookeeper
        sleep 5
        if systemctl is-active --quiet zookeeper; then
            success "Zookeeper 服务已启动"
        else
            warn "Zookeeper 服务可能未正常启动，请查看: journalctl -u zookeeper -n 50 --no-pager"
        fi
    fi

    info "启动 Kafka 服务..."
    systemctl start kafka
    local retries=0
    local max_retries=4
    while [ $retries -lt $max_retries ]; do
        sleep 5
        if systemctl is-active --quiet kafka; then
            success "Kafka 服务已启动"
            return
        fi
        retries=$((retries + 1))
        [ $retries -lt $max_retries ] && info "等待 Kafka 启动中...（${retries}/${max_retries}）"
    done
    warn "Kafka 服务启动超时或未正常运行"
    warn "诊断命令:"
    warn "  systemctl status kafka"
    warn "  journalctl -u kafka -n 50 --no-pager"
    warn "  tail -n 100 ${KAFKA_INSTALL_DIR}/logs/server.log"
}

print_summary() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}        Kafka 安装完成${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "版本:        ${CYAN}${KAFKA_VERSION} (Scala ${SCALA_VERSION})${NC}"
    echo -e "部署模式:    ${CYAN}${DEPLOY_MODE}${NC}"
    echo -e "协调模式:    ${CYAN}${COORD_MODE}${NC}"
    echo -e "节点 ID:     ${CYAN}${NODE_ID}${NC}"
    echo -e "安装目录:    ${CYAN}${KAFKA_INSTALL_DIR}${NC}"
    echo -e "数据目录:    ${CYAN}${KAFKA_DATA_DIR}${NC}"
    echo -e "Broker 地址: ${CYAN}${ADVERTISED_HOST}:${BROKER_PORT}${NC}"
    if [ "$COORD_MODE" = "zookeeper" ]; then
        echo -e "Zookeeper:   ${CYAN}${ZK_CONNECT}${NC}"
    else
        echo -e "集群 UUID:   ${CYAN}${CLUSTER_UUID}${NC}"
    fi
    echo ""
    echo -e "常用命令:"
    echo -e "  启动: ${CYAN}systemctl start kafka${NC}"
    echo -e "  停止: ${CYAN}systemctl stop kafka${NC}"
    echo -e "  状态: ${CYAN}systemctl status kafka${NC}"
    echo -e "  日志: ${CYAN}journalctl -u kafka -f${NC}"
    if [ "$COORD_MODE" = "zookeeper" ]; then
        echo -e "  Zookeeper: ${CYAN}systemctl status zookeeper${NC}"
    fi
    echo ""
    echo -e "测试命令:"
    echo -e "  创建主题: ${CYAN}${KAFKA_INSTALL_DIR}/bin/kafka-topics.sh --create --topic test --bootstrap-server ${ADVERTISED_HOST}:${BROKER_PORT}${NC}"
    echo -e "  查看主题: ${CYAN}${KAFKA_INSTALL_DIR}/bin/kafka-topics.sh --list --bootstrap-server ${ADVERTISED_HOST}:${BROKER_PORT}${NC}"
    if [ "$DEPLOY_MODE" = "cluster" ]; then
        echo ""
        warn "集群模式部署要点:"
        if [ "$COORD_MODE" = "zookeeper" ]; then
            warn "  1) 所有节点必须使用相同的 --zk-servers 列表"
            warn "  2) 每个节点的 --node-id（broker.id）必须唯一"
            warn "  3) 在每个节点上分别执行本脚本（脚本据 advertised-host 自动分配 zk myid）"
        else
            warn "  1) 所有节点必须使用相同的 --quorum 列表和 --cluster-uuid"
            warn "  2) 每个节点的 --node-id 必须唯一，且与 quorum 中的 id 对应"
            warn "  3) 在每个节点上分别执行本脚本"
        fi
    fi
    echo -e "${GREEN}========================================${NC}"
}

main() {
    parse_args "$@"
    detect_os
    install_dependencies
    check_java
    collect_basic_info
    choose_mode
    choose_coord
    validate_coord
    info "开始安装 Kafka ${KAFKA_VERSION}（${COORD_MODE} 模式）..."
    collect_node_info
    prepare_package
    deploy_kafka
    configure_kafka
    format_storage
    create_systemd_service
    start_and_verify
    print_summary
}

main "$@"
