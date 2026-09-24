#!/bin/bash

# Nacos 集群一键部署脚本
# 本机作为首节点安装，SSH 远程安装其余节点，SCP 同步安装包与脚本
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

INSTALL_SCRIPT="$SCRIPT_DIR/install_nacos.sh"
CLUSTER_STATE_FILE="/etc/nacos_cluster_deploy.conf"

NACOS_VERSION="${NACOS_VERSION:-2.5.0}"
NACOS_PORT="8848"
NACOS_INSTALL_DIR="/usr/local/nacos"
INCLUDE_LOCAL_NODE="yes"
LOCAL_NODE_IP=""

# MySQL（集群强烈推荐）
DB_TYPE="mysql"
MYSQL_HOST="127.0.0.1"
MYSQL_PORT="3306"
MYSQL_DB="nacos"
MYSQL_USER="nacos"
MYSQL_PASSWORD=""

# 鉴权（全集群需一致）
AUTH_ENABLED="true"
AUTH_TOKEN=""
AUTH_IDENTITY_KEY="nacos"
AUTH_IDENTITY_VALUE=""

# SSH
SSH_USER="root"
SSH_PORT="22"
SSH_PASSWORD=""
SSH_KEY=""
SSH_OPTS=""

# 远程节点: ip|ssh_port|ssh_user|ssh_pass|nacos_port
REMOTE_NODES=()

# 安装包
NACOS_TGZ=""

# ======================== SSH 工具 ========================

ensure_ssh_tools() {
    if ! command -v ssh >/dev/null 2>&1 || ! command -v scp >/dev/null 2>&1; then
        error "未找到 ssh/scp，请安装 openssh-clients"
    fi
    if [ -n "$SSH_PASSWORD" ] && ! command -v sshpass >/dev/null 2>&1; then
        warn "尝试安装 sshpass..."
        detect_sys_pkg
        sys_pkg_install "sshpass" 2>/dev/null || true
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
    local pkg_name="nacos-server-${NACOS_VERSION}.tar.gz"
    local local_pkg="$SCRIPT_DIR/package/$pkg_name"
    mkdir -p "$SCRIPT_DIR/package"

    if [ -f "$local_pkg" ]; then
        NACOS_TGZ="$local_pkg"
        info "使用本地安装包: $NACOS_TGZ"
        return 0
    fi

    info "本地无安装包，尝试下载..."
    if bash "$INSTALL_SCRIPT" --standalone --db derby --version "$NACOS_VERSION" --help >/dev/null 2>&1; then
        :
    fi
    # 直接触发安装脚本的下载逻辑成本高，这里手动下载
    local url="https://github.com/alibaba/nacos/releases/download/${NACOS_VERSION}/${pkg_name}"
    if wget --timeout=60 --tries=3 -O "$local_pkg" "$url"; then
        local sz
        sz=$(stat -c%s "$local_pkg" 2>/dev/null || echo 0)
        if [ "$sz" -gt 1048576 ]; then
            NACOS_TGZ="$local_pkg"
            success "下载完成: $NACOS_TGZ"
            return 0
        fi
        rm -f "$local_pkg"
    fi
    warn "安装包准备失败，请手动将 $pkg_name 放入 $SCRIPT_DIR/package/"
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
    info "Nacos 集群配置"
    read -rp "Nacos 版本 [${NACOS_VERSION}]: " input; NACOS_VERSION=${input:-$NACOS_VERSION}
    read -rp "Nacos 端口 [${NACOS_PORT}]: " input; NACOS_PORT=${input:-$NACOS_PORT}

    LOCAL_NODE_IP=$(get_local_ip)
    read -rp "本机对外 IP [${LOCAL_NODE_IP}]: " input; LOCAL_NODE_IP=${input:-$LOCAL_NODE_IP}

    read -rp "本机是否作为集群节点? [Y/n]: " inc
    if [[ "$inc" =~ ^[Nn]$ ]]; then
        INCLUDE_LOCAL_NODE="no"
    else
        INCLUDE_LOCAL_NODE="yes"
    fi

    echo ""
    info "存储库（集群必须 MySQL）"
    read -rp "MySQL 主机 [${MYSQL_HOST}]: " input; MYSQL_HOST=${input:-$MYSQL_HOST}
    read -rp "MySQL 端口 [${MYSQL_PORT}]: " input; MYSQL_PORT=${input:-$MYSQL_PORT}
    read -rp "数据库名 [${MYSQL_DB}]: " input; MYSQL_DB=${input:-$MYSQL_DB}
    read -rp "用户名 [${MYSQL_USER}]: " input; MYSQL_USER=${input:-$MYSQL_USER}
    read -rsp "MySQL 密码: " MYSQL_PASSWORD; echo ""

    # 生成全集群一致的鉴权密钥
    if [ -z "$AUTH_TOKEN" ]; then
        AUTH_TOKEN=$(head -c 32 /dev/urandom | base64 | tr -d '\n/+=' | head -c 32)
        AUTH_TOKEN=$(echo -n "$AUTH_TOKEN" | base64)
    fi
    if [ -z "$AUTH_IDENTITY_VALUE" ]; then
        AUTH_IDENTITY_VALUE=$(head -c 16 /dev/urandom | base64 | tr -d '\n/+=' | head -c 16)
    fi
    info "已生成集群统一鉴权密钥（将同步到所有节点）"
}

collect_remote_nodes() {
    echo ""
    info "添加远程节点（IP 留空结束）"
    echo "格式: IP → SSH端口 → SSH用户/密码 → Nacos端口"
    REMOTE_NODES=()
    local idx=1
    while true; do
        read -rp "节点 #${idx} IP/主机名 (空结束): " host
        [ -z "$host" ] && break
        local sport="$SSH_PORT" suser="$SSH_USER" spass="$SSH_PASSWORD" rport="$NACOS_PORT" custom
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
        read -rp "  Nacos端口 [${NACOS_PORT}]: " custom; rport=${custom:-$rport}
        REMOTE_NODES+=("${host}|${sport}|${suser}|${spass}|${rport}")
        success "已添加: ${host}:${rport}"
        idx=$((idx+1))
    done

    local total=${#REMOTE_NODES[@]}
    [ "$INCLUDE_LOCAL_NODE" = "yes" ] && total=$((total + 1))
    if [ "$total" -lt 3 ]; then
        warn "当前节点数=$total，Nacos 集群建议至少 3 节点"
        confirm_action "仍继续?" || return 1
    fi
    return 0
}

build_nodes_csv() {
    # 所有节点 ip:port，逗号分隔
    local parts=()
    if [ "$INCLUDE_LOCAL_NODE" = "yes" ]; then
        parts+=("${LOCAL_NODE_IP}:${NACOS_PORT}")
    fi
    local item h _ _ _ rp
    for item in "${REMOTE_NODES[@]}"; do
        IFS='|' read -r h _ _ _ rp <<< "$item"
        parts+=("${h}:${rp}")
    done
    local IFS=','
    echo "${parts[*]}"
}

save_cluster_state() {
    {
        echo "# Nacos cluster deploy - $(date)"
        echo "NACOS_VERSION=$NACOS_VERSION"
        echo "NACOS_PORT=$NACOS_PORT"
        echo "LOCAL_NODE_IP=$LOCAL_NODE_IP"
        echo "INCLUDE_LOCAL_NODE=$INCLUDE_LOCAL_NODE"
        echo "DB_TYPE=$DB_TYPE"
        echo "MYSQL_HOST=$MYSQL_HOST"
        echo "MYSQL_PORT=$MYSQL_PORT"
        echo "MYSQL_DB=$MYSQL_DB"
        echo "MYSQL_USER=$MYSQL_USER"
        echo "MYSQL_PASSWORD=$MYSQL_PASSWORD"
        echo "AUTH_TOKEN=$AUTH_TOKEN"
        echo "AUTH_IDENTITY_KEY=$AUTH_IDENTITY_KEY"
        echo "AUTH_IDENTITY_VALUE=$AUTH_IDENTITY_VALUE"
        echo "SSH_USER=$SSH_USER"
        echo "SSH_PORT=$SSH_PORT"
        echo "SSH_KEY=$SSH_KEY"
        echo "NACOS_TGZ=$NACOS_TGZ"
        echo "REMOTE_NODES_STR=${REMOTE_NODES[*]}"
    } > "$CLUSTER_STATE_FILE"
    chmod 600 "$CLUSTER_STATE_FILE"
    success "集群状态: $CLUSTER_STATE_FILE"
}

# ======================== 本机安装 ========================

install_local_nacos() {
    echo ""
    info "===== 本机安装 Nacos 集群节点 ====="

    if [ ! -f "$INSTALL_SCRIPT" ]; then
        error "未找到 $INSTALL_SCRIPT"
    fi

    local nodes_csv
    nodes_csv=$(build_nodes_csv)

    local args=(
        --cluster
        --db mysql
        --version "$NACOS_VERSION"
        --port "$NACOS_PORT"
        --nodes "$nodes_csv"
        --mysql-host "$MYSQL_HOST"
        --mysql-port "$MYSQL_PORT"
        --mysql-db "$MYSQL_DB"
        --mysql-user "$MYSQL_USER"
        --mysql-password "$MYSQL_PASSWORD"
    )

    info "本机执行: bash install_nacos.sh ${args[*]}"
    # 鉴权密钥需通过环境变量注入，install 脚本会在无值时自动生成——这里先写 state，
    # 安装后再统一 patch application.properties 保证集群密钥一致
    bash "$INSTALL_SCRIPT" "${args[@]}" || error "本机 Nacos 安装失败"

    # 统一鉴权配置
    patch_local_auth
    success "本机 Nacos 集群节点安装完成"
}

patch_local_auth() {
    local conf="$NACOS_INSTALL_DIR/conf/application.properties"
    [ -f "$conf" ] || return 0
    info "同步本机鉴权配置..."
    sed -i '/^nacos.core.auth.enabled=/d' "$conf"
    sed -i '/^nacos.core.auth.server.identity.key=/d' "$conf"
    sed -i '/^nacos.core.auth.server.identity.value=/d' "$conf"
    sed -i '/^nacos.core.auth.plugin.nacos.token.secret.key=/d' "$conf"
    cat >> "$conf" <<EOF

# ===== 集群统一鉴权（setup_nacos_cluster.sh）=====
nacos.core.auth.enabled=${AUTH_ENABLED}
nacos.core.auth.server.identity.key=${AUTH_IDENTITY_KEY}
nacos.core.auth.server.identity.value=${AUTH_IDENTITY_VALUE}
nacos.core.auth.plugin.nacos.token.secret.key=${AUTH_TOKEN}
EOF
    systemctl restart nacos 2>/dev/null || true
}

# ======================== 远程安装 ========================

remote_install_nacos() {
    local host="$1" sport="$2" suser="$3" spass="$4" rport="$5"

    echo ""
    info "===== 远程安装 Nacos → ${host}:${rport} ====="

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

    # Java 检查
    local has_java
    has_java=$(ssh_cmd "$host" "command -v java >/dev/null && echo YES || echo NO")
    if [ "$has_java" != "YES" ]; then
        warn "远程未检测到 Java，尝试安装 openjdk..."
        ssh_cmd "$host" "$(declare -f detect_sys_pkg sys_pkg_install); detect_sys_pkg; [ \"\$SYS_FAMILY\" = debian ] && apt-get update -y; sys_pkg_install \"java-17-openjdk\" \"openjdk-17-jdk\"" || true
        has_java=$(ssh_cmd "$host" "command -v java >/dev/null && echo YES || echo NO")
        if [ "$has_java" != "YES" ]; then
            warn "远程 Java 安装失败，请手动安装 JDK8+"
            SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
            return 1
        fi
    fi

    if [ -z "$NACOS_TGZ" ] || [ ! -f "$NACOS_TGZ" ]; then
        ensure_package_tgz || {
            SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
            return 1
        }
    fi

    local tgz_name
    tgz_name=$(basename "$NACOS_TGZ")
    local nodes_csv
    nodes_csv=$(build_nodes_csv)

    info "上传脚本与安装包..."
    ssh_cmd "$host" "mkdir -p /tmp/nacos_cluster_install/package" || true

    # lib_common.sh 在上级目录
    scp_to_remote "$PARENT_DIR/lib_common.sh" "$host" "/tmp/nacos_cluster_install/lib_common.sh" || {
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"; return 1
    }
    # 远程目录结构: /tmp/nacos_cluster_install/nacos/install_nacos.sh
    # install 脚本 source ../lib_common.sh，所以要保持相对路径
    ssh_cmd "$host" "mkdir -p /tmp/nacos_cluster_install/nacos/package" || true
    scp_to_remote "$INSTALL_SCRIPT" "$host" "/tmp/nacos_cluster_install/nacos/install_nacos.sh" || {
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"; return 1
    }
    scp_to_remote "$NACOS_TGZ" "$host" "/tmp/nacos_cluster_install/nacos/package/${tgz_name}" || {
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"; return 1
    }

    info "远程执行无人值守安装..."
    local remote_cmd="cd /tmp/nacos_cluster_install/nacos && bash install_nacos.sh --cluster --db mysql --version '${NACOS_VERSION}' --port '${rport}' --nodes '${nodes_csv}' --mysql-host '${MYSQL_HOST}' --mysql-port '${MYSQL_PORT}' --mysql-db '${MYSQL_DB}' --mysql-user '${MYSQL_USER}' --mysql-password '${MYSQL_PASSWORD}'"

    if ssh_cmd "$host" "$remote_cmd"; then
        # 同步鉴权
        info "同步远程鉴权配置..."
        ssh_cmd "$host" "bash -s" << AUTH_EOF
conf=/usr/local/nacos/conf/application.properties
if [ -f "\$conf" ]; then
  sed -i '/^nacos.core.auth.enabled=/d' "\$conf"
  sed -i '/^nacos.core.auth.server.identity.key=/d' "\$conf"
  sed -i '/^nacos.core.auth.server.identity.value=/d' "\$conf"
  sed -i '/^nacos.core.auth.plugin.nacos.token.secret.key=/d' "\$conf"
  cat >> "\$conf" <<'EOP'

# ===== 集群统一鉴权 =====
EOP
  echo "nacos.core.auth.enabled=${AUTH_ENABLED}" >> "\$conf"
  echo "nacos.core.auth.server.identity.key=${AUTH_IDENTITY_KEY}" >> "\$conf"
  echo "nacos.core.auth.server.identity.value=${AUTH_IDENTITY_VALUE}" >> "\$conf"
  echo "nacos.core.auth.plugin.nacos.token.secret.key=${AUTH_TOKEN}" >> "\$conf"
  systemctl restart nacos 2>/dev/null || true
fi
AUTH_EOF
        success "${host} Nacos 安装完成"
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 0
    fi

    warn "${host} Nacos 安装失败"
    SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
    return 1
}

# ======================== 状态检查 ========================

check_cluster_status() {
    echo ""
    info "===== Nacos 集群状态 ====="

    if [ -f "$CLUSTER_STATE_FILE" ]; then
        # shellcheck source=/dev/null
        . "$CLUSTER_STATE_FILE"
    fi

    local nodes_csv
    nodes_csv=$(build_nodes_csv)
    info "集群节点: $nodes_csv"

    # 本机
    if [ "$INCLUDE_LOCAL_NODE" = "yes" ]; then
        echo -n "  本机 ${LOCAL_NODE_IP}:${NACOS_PORT}: "
        if curl -s --connect-timeout 3 "http://127.0.0.1:${NACOS_PORT}/nacos/v1/console/health/readiness" 2>/dev/null | grep -q .; then
            echo -e "${GREEN}OK${NC}"
        elif systemctl is-active --quiet nacos 2>/dev/null; then
            echo -e "${GREEN}服务运行中${NC}"
        else
            echo -e "${RED}异常${NC}"
        fi
    fi

    # 远程
    local item h p u pw rp
    for item in "${REMOTE_NODES[@]}"; do
        IFS='|' read -r h p u pw rp <<< "$item"
        local old_port="$SSH_PORT" old_user="$SSH_USER" old_pass="$SSH_PASSWORD"
        with_node_ssh "$h" "$p" "$u" "$pw"
        echo -n "  远程 ${h}:${rp}: "
        local st
        st=$(ssh_cmd "$h" "systemctl is-active nacos 2>/dev/null || echo inactive")
        if [ "$st" = "active" ]; then
            echo -e "${GREEN}active${NC}"
        else
            echo -e "${YELLOW}${st}${NC}"
        fi
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
    done

    echo ""
    info "控制台: http://${LOCAL_NODE_IP}:${NACOS_PORT}/nacos  (nacos/nacos)"
    info "集群节点列表应完全一致，可在控制台「集群管理」查看"
}

# ======================== 一键部署 ========================

one_click_deploy() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${GREEN}一键 Nacos 集群部署${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo "流程: 本机首节点安装 → 打包同步 → SSH 远程安装 → 统一鉴权 → 校验"
    echo "要求: 各节点可访问同一 MySQL；建议 3 节点；需 JDK8+"
    echo ""

    confirm_action "开始一键部署?" || return 1

    collect_ssh_info
    collect_cluster_config
    collect_remote_nodes

    echo ""
    info "部署摘要:"
    info "  版本: $NACOS_VERSION  端口: $NACOS_PORT"
    info "  本机节点: $INCLUDE_LOCAL_NODE  IP=$LOCAL_NODE_IP"
    info "  远程节点数: ${#REMOTE_NODES[@]}"
    info "  MySQL: ${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DB}"
    info "  集群节点列表: $(build_nodes_csv)"
    confirm_action "确认开始部署?" || return 1

    # A. 准备安装包
    echo ""
    info "===== 步骤 A: 准备安装包 ====="
    ensure_package_tgz || {
        warn "无安装包时远程无法离线安装"
        confirm_action "继续（远程将自行下载，可能较慢）?" || return 1
    }

    # B. 本机
    if [ "$INCLUDE_LOCAL_NODE" = "yes" ]; then
        echo ""
        info "===== 步骤 B: 本机节点 ====="
        install_local_nacos
    else
        info "本机不作为数据节点，仅用于编排"
    fi

    # C. 远程
    local failed=0 idx=1
    for item in "${REMOTE_NODES[@]}"; do
        IFS='|' read -r h p u pw rp <<< "$item"
        echo ""
        info "===== 步骤 C.${idx}: ${h}:${rp} ====="
        remote_install_nacos "$h" "$p" "$u" "$pw" "$rp" || failed=$((failed+1))
        idx=$((idx+1))
    done

    save_cluster_state

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Nacos 集群部署结束${NC}"
    echo -e "${GREEN}========================================${NC}"
    info "成功远程节点: $(( ${#REMOTE_NODES[@]} - failed )) / ${#REMOTE_NODES[@]}"
    [ $failed -gt 0 ] && warn "失败 $failed 个，请检查上方日志"
    echo ""
    info "后续: bash $0 status"
    info "控制台: http://${LOCAL_NODE_IP}:${NACOS_PORT}/nacos"
    echo ""

    check_cluster_status
    return 0
}

# ======================== 帮助/菜单 ========================

show_help() {
    cat <<EOF
Nacos 集群一键部署脚本

用法: bash setup_nacos_cluster.sh [命令]

命令:
  one       一键部署（本机+SSH远程）
  status    查看集群节点状态
  help      帮助

交互菜单直接运行脚本即可。

说明:
  - 集群必须使用共享 MySQL 存储
  - 所有节点 cluster.conf 节点列表保持一致
  - 鉴权密钥在部署时统一生成并同步
  - 远程需 JDK8+ 与 systemd；脚本会尝试自动装 OpenJDK
EOF
}

show_main_menu() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${GREEN}Nacos 集群配置工具${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo "本机IP: $(get_local_ip)"
    echo ""
    echo "请选择操作:"
    echo ""
    echo -e "  ${GREEN}1. 一键部署 Nacos 集群${NC}（SSH远程安装）"
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
