#!/bin/bash

# MySQL 主从复制配置脚本
# 支持：本机配置主/从库、SSH 一键远程安装从库、SCP 同步安装包与配置
# 兼容 Ubuntu 22/24、Debian 12、CentOS Stream/Rocky/AlmaLinux 8/9

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 检查是否使用bash执行
if [ -z "$BASH_VERSION" ]; then
    echo "错误: 请使用bash执行此脚本，而不是sh"
    echo "正确用法: bash setup_mysql_replication.sh 或 ./setup_mysql_replication.sh"
    exit 1
fi

# 检查是否为root用户
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}此脚本需要以root权限运行${NC}"
   exit 1
fi

# ======================== 全局变量 ========================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="$SCRIPT_DIR/install_mysql.sh"
INSTALL_STATE_FILE="/etc/mysql_install_state.conf"
CONFIG_FILE="/etc/mysql_replication.conf"
CLUSTER_STATE_FILE="/etc/mysql_cluster_hosts.conf"

# MySQL 本机配置
MYSQL_INSTALL_DIR=""
MYSQL_DATA_DIR=""
MYSQL_LOG_DIR=""
MYSQL_HOME=""
MYSQL_VERSION=""
MYSQL_PORT="3306"
MYSQL_ROOT_PASSWORD="root"
MYSQL_REPL_USER="repl"
MYSQL_REPL_PASSWORD="Repl@$(date +%Y)Pass"
MYSQL_SERVER_ID=""
MYSQL_BINLOG_DIR=""

# 主从配置
REPLICATION_ROLE=""
MASTER_HOST=""
MASTER_PORT="3306"
USE_GTID=true

# 远程 SSH
SSH_USER="root"
SSH_PORT="22"
SSH_PASSWORD=""
SSH_KEY=""
SSH_OPTS=""
REMOTE_MYSQL_HOME=""
REMOTE_MYSQL_PORT="3306"
REMOTE_MYSQL_PASSWORD=""
REMOTE_TARBALL_PATH=""
KEEP_LOCAL_TARBALL=1

# 从库列表: host:port:user:password  (user/password 为 SSH 账号)
SLAVE_HOSTS=()

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

# ======================== 工具函数 ========================

print_separator() {
    echo -e "${CYAN}========================================${NC}"
}

print_title() {
    local title="$1"
    echo ""
    print_separator
    echo -e "${GREEN}$title${NC}"
    print_separator
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

check_service_status() {
    local service_name="$1"
    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        echo -e "${GREEN}✓ $service_name 服务正在运行${NC}"
        return 0
    else
        echo -e "${RED}✗ $service_name 服务未运行${NC}"
        return 1
    fi
}

get_local_ip() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [ -z "$ip" ]; then
        ip=$(ip -4 addr show 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | head -1)
    fi
    echo "$ip"
}

generate_server_id() {
    # 基于时间戳 + 随机数，尽量保证集群内唯一
    echo $(( ($(date +%s) % 900000000) + 100000000 + RANDOM % 1000 ))
}

# ======================== SSH 工具 ========================

ensure_ssh_tools() {
    if ! command -v ssh >/dev/null 2>&1 || ! command -v scp >/dev/null 2>&1; then
        echo -e "${RED}未找到 ssh/scp，请先安装 openssh-clients${NC}"
        return 1
    fi

    if [ -n "$SSH_PASSWORD" ] && ! command -v sshpass >/dev/null 2>&1; then
        echo -e "${YELLOW}检测到使用 SSH 密码，但未安装 sshpass${NC}"
        detect_sys_pkg
        sys_pkg_install "sshpass" "sshpass" 2>/dev/null || true

        if ! command -v sshpass >/dev/null 2>&1; then
            echo -e "${RED}sshpass 安装失败。请配置 SSH 免密，或手动安装 sshpass${NC}"
            echo -e "${CYAN}免密示例: ssh-copy-id -p $SSH_PORT ${SSH_USER}@<从库IP>${NC}"
            return 1
        fi
    fi
    return 0
}

build_ssh_opts() {
    SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o BatchMode=no -p $SSH_PORT"
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
    echo -e "${CYAN}测试 SSH 连接 ${SSH_USER}@${host}:${SSH_PORT} ...${NC}"
    if ssh_cmd "$host" "echo SSH_OK && hostname && uname -m"; then
        echo -e "${GREEN}✓ SSH 连接成功${NC}"
        return 0
    else
        echo -e "${RED}✗ SSH 连接失败${NC}"
        return 1
    fi
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
        echo -e "${YELLOW}远程节点若开启 SELinux（Enforcing），服务以 systemd 启动时可能被拦截。${NC}"
        echo -e "${YELLOW}建议在所有远程节点关闭 SELinux（setenforce 0 立即生效 + 改 /etc/selinux/config 永久生效）。${NC}"
        if [ -t 0 ] && [ -t 1 ]; then
            local sel
            read -rp "是否自动关闭所有远程节点的 SELinux? [Y/n]: " sel
            [ -z "$sel" ] && sel="Y"
            [[ "$sel" =~ ^[Yy]$ ]] && SELINUX_REMOTE_DISABLE=1
        else
            SELINUX_REMOTE_DISABLE=1
            echo -e "${CYAN}非交互模式，默认在远程节点关闭 SELinux${NC}"
        fi
    fi

    [ "$SELINUX_REMOTE_DISABLE" -ne 1 ] && return 0

    local state
    state=$(ssh_cmd "$host" 'if command -v getenforce >/dev/null 2>&1; then getenforce; else echo NONE; fi')
    case "$state" in
        Enforcing)
            echo -e "${YELLOW}${host} SELinux=Enforcing，正在关闭...${NC}"
            ssh_cmd "$host" 'setenforce 0 && sed -i "s/^SELINUX=enforcing/SELINUX=disabled/I" /etc/selinux/config && echo DONE' || {
                echo -e "${RED}${host} 关闭 SELinux 失败，请手动处理${NC}"
                return 1
            }
            echo -e "${GREEN}✓ ${host} SELinux 已关闭（运行时 Permissive，重启后 Disabled）${NC}"
            ;;
        Permissive|Disabled)
            echo -e "${CYAN}${host} SELinux=${state}，无需处理${NC}"
            ;;
        *)
            echo -e "${CYAN}${host} 无 SELinux 或状态未知，跳过${NC}"
            ;;
    esac
    return 0
}

# ======================== 检测MySQL安装 ========================

load_install_state() {
    if [ -f "$INSTALL_STATE_FILE" ]; then
        # shellcheck source=/dev/null
        source "$INSTALL_STATE_FILE"
        echo -e "${GREEN}已加载本机安装状态: $INSTALL_STATE_FILE${NC}"
        echo -e "  版本: ${MYSQL_VERSION:-未知}"
        echo -e "  安装目录: ${MYSQL_INSTALL_DIR:-未知}"
        echo -e "  端口: ${MYSQL_PORT:-3306}"
        return 0
    fi
    return 1
}

detect_mysql_installation() {
    echo -e "${YELLOW}检测MySQL安装...${NC}"

    if load_install_state && [ -n "$MYSQL_INSTALL_DIR" ] && [ -f "$MYSQL_INSTALL_DIR/bin/mysql" ]; then
        echo -e "${GREEN}找到MySQL安装: $MYSQL_INSTALL_DIR${NC}"
        local version=$($MYSQL_INSTALL_DIR/bin/mysql --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        echo -e "${GREEN}MySQL版本: $version${NC}"
        return 0
    fi

    local mysql_paths=(
        "/mnt/data/mysql"
        "/usr/local/mysql"
        "/opt/mysql"
        "/data/mysql"
    )

    if [ -f "/etc/my.cnf" ]; then
        local basedir datadir
        basedir=$(grep "^basedir" /etc/my.cnf 2>/dev/null | head -1 | awk -F'=' '{print $2}' | xargs)
        datadir=$(grep "^datadir" /etc/my.cnf 2>/dev/null | head -1 | awk -F'=' '{print $2}' | xargs)
        if [ -n "$basedir" ]; then
            # basedir 可能是 .../mysql-x.y.z
            mysql_paths=("$basedir" "$(dirname "$basedir")" "${mysql_paths[@]}")
        fi
        if [ -n "$datadir" ]; then
            MYSQL_DATA_DIR="$datadir"
        fi
    fi

    for path in "${mysql_paths[@]}"; do
        if [ -f "$path/bin/mysql" ]; then
            MYSQL_INSTALL_DIR="$path"
            break
        fi
        # 查找 path 下的 mysql-* 安装目录
        local found
        found=$(find "$path" -maxdepth 2 -type f -path '*/bin/mysql' 2>/dev/null | head -1)
        if [ -n "$found" ]; then
            MYSQL_INSTALL_DIR=$(dirname "$(dirname "$found")")
            break
        fi
    done

    if [ -z "$MYSQL_INSTALL_DIR" ] && command -v mysql >/dev/null 2>&1; then
        local mysql_path
        mysql_path=$(command -v mysql)
        MYSQL_INSTALL_DIR=$(dirname "$(dirname "$mysql_path")")
    fi

    if [ -z "$MYSQL_INSTALL_DIR" ] || [ ! -f "$MYSQL_INSTALL_DIR/bin/mysql" ]; then
        echo -e "${RED}未找到MySQL安装${NC}"
        return 1
    fi

    echo -e "${GREEN}找到MySQL安装: $MYSQL_INSTALL_DIR${NC}"
    local version=$($MYSQL_INSTALL_DIR/bin/mysql --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    echo -e "${GREEN}MySQL版本: $version${NC}"

    MYSQL_HOME=$(dirname "$MYSQL_INSTALL_DIR")
    if [ -z "$MYSQL_DATA_DIR" ]; then
        if [ -f "/etc/my.cnf" ]; then
            MYSQL_DATA_DIR=$(grep "^datadir" /etc/my.cnf 2>/dev/null | head -1 | awk -F'=' '{print $2}' | xargs)
        fi
    fi
    MYSQL_DATA_DIR="${MYSQL_DATA_DIR:-$MYSQL_HOME/data}"
    MYSQL_LOG_DIR="${MYSQL_LOG_DIR:-$(dirname "$MYSQL_DATA_DIR")/log}"
    if [ -f "/etc/my.cnf" ]; then
        local p
        p=$(grep "^port" /etc/my.cnf 2>/dev/null | head -1 | awk -F'=' '{print $2}' | xargs)
        MYSQL_PORT="${p:-$MYSQL_PORT}"
    fi
    return 0
}

mysql_exec() {
    # mysql_exec "SQL"
    local sql="$1"
    local sock="${2:-}"
    if [ -n "$sock" ] && [ -S "$sock" ]; then
        "$MYSQL_INSTALL_DIR/bin/mysql" --socket="$sock" -u root -p"$MYSQL_ROOT_PASSWORD" -N -B -e "$sql" 2>/dev/null
    else
        "$MYSQL_INSTALL_DIR/bin/mysql" -u root -p"$MYSQL_ROOT_PASSWORD" -h 127.0.0.1 -P "$MYSQL_PORT" -N -B -e "$sql" 2>/dev/null
    fi
}

# ======================== 安装相关 ========================

find_local_tarball() {
    # 优先使用安装状态里保留的包
    if [ -n "$TARBALL_NAME" ] && [ -f "/tmp/${TARBALL_NAME}" ]; then
        REMOTE_TARBALL_PATH="/tmp/${TARBALL_NAME}"
        return 0
    fi
    if [ -n "$OFFLINE_TARBALL_PATH" ] && [ -f "$OFFLINE_TARBALL_PATH" ]; then
        REMOTE_TARBALL_PATH="$OFFLINE_TARBALL_PATH"
        return 0
    fi

    local candidates
    candidates=$(find /tmp /root /opt -maxdepth 2 -type f -name 'mysql-*.tar.xz' 2>/dev/null | head -5)
    if [ -n "$candidates" ]; then
        echo -e "${CYAN}发现本地安装包:${NC}"
        local i=1
        local arr=()
        while IFS= read -r line; do
            arr+=("$line")
            echo "  $i. $line"
            i=$((i+1))
        done <<< "$candidates"
        read -p "请选择编号 [1]: " pick
        pick=${pick:-1}
        if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le ${#arr[@]} ]; then
            REMOTE_TARBALL_PATH="${arr[$((pick-1))]}"
            return 0
        fi
    fi

    echo -e "${YELLOW}未找到可用的 MySQL 安装包${NC}"
    echo -e "${CYAN}可输入 tar.xz 路径，或留空后在线下载安装本机${NC}"
    read -p "安装包路径: " manual_path
    if [ -n "$manual_path" ] && [ -f "$manual_path" ]; then
        REMOTE_TARBALL_PATH="$manual_path"
        return 0
    fi
    return 1
}

call_install_script() {
    print_title "安装MySQL（本机交互）"

    if [ ! -f "$INSTALL_SCRIPT" ]; then
        echo -e "${RED}未找到安装脚本: $INSTALL_SCRIPT${NC}"
        return 1
    fi

    if ! confirm_action "即将调用MySQL安装脚本，是否继续?"; then
        return 1
    fi

    bash "$INSTALL_SCRIPT"

    if detect_mysql_installation; then
        echo -e "${GREEN}✓ MySQL安装成功${NC}"
        return 0
    fi
    echo -e "${RED}✗ MySQL安装失败${NC}"
    return 1
}

install_local_batch() {
    print_title "本机无人值守安装（作为主库）"

    if [ ! -f "$INSTALL_SCRIPT" ]; then
        echo -e "${RED}未找到安装脚本: $INSTALL_SCRIPT${NC}"
        return 1
    fi

    local version="${MYSQL_VERSION:-8.4.9}"
    local home="${MYSQL_HOME:-/mnt/data/mysql}"
    local port="${MYSQL_PORT:-3306}"
    local pass="${MYSQL_ROOT_PASSWORD:-root}"
    local offline=""

    echo -e "${CYAN}本机安装参数${NC}"
    read -p "MySQL版本 [$version]: " input_version
    version=${input_version:-$version}
    read -p "安装目录(Home) [$home]: " input_home
    home=${input_home:-$home}
    read -p "端口 [$port]: " input_port
    port=${input_port:-$port}
    read -s -p "Root密码 [默认: root]: " input_pass
    echo ""
    pass=${input_pass:-$pass}

    echo ""
    echo "安装源:"
    echo "1. 在线下载（保留安装包，便于同步到从库）"
    echo "2. 使用本地 tar.xz 包"
    read -p "请选择 [1/2]: " src_choice
    if [[ "$src_choice" == "2" ]]; then
        if find_local_tarball; then
            offline="$REMOTE_TARBALL_PATH"
        else
            echo -e "${YELLOW}未找到离线包，改为在线安装${NC}"
        fi
    fi

    local cmd=(bash "$INSTALL_SCRIPT" --batch --version "$version" --home "$home" --port "$port" --password "$pass" --keep-tarball)
    if [ -n "$offline" ]; then
        cmd=(bash "$INSTALL_SCRIPT" --batch --offline "$offline" --home "$home" --port "$port" --password "$pass" --keep-tarball)
    fi

    echo -e "${CYAN}执行: ${cmd[*]}${NC}"
    "${cmd[@]}"
    local rc=$?

    if [ $rc -eq 0 ]; then
        MYSQL_VERSION="$version"
        MYSQL_HOME="$home"
        MYSQL_PORT="$port"
        MYSQL_ROOT_PASSWORD="$pass"
        detect_mysql_installation
        find_local_tarball || true
        echo -e "${GREEN}✓ 本机安装完成${NC}"
        return 0
    fi
    echo -e "${RED}✗ 本机安装失败${NC}"
    return 1
}

# ======================== 远程安装从库 ========================

collect_ssh_info() {
    print_title "SSH 远程连接信息"

    read -p "SSH 用户名 [root]: " input_user
    SSH_USER=${input_user:-root}
    read -p "SSH 端口 [22]: " input_ssh_port
    SSH_PORT=${input_ssh_port:-22}

    echo "认证方式:"
    echo "1. SSH 密码（自动安装/使用 sshpass）"
    echo "2. SSH 私钥免密"
    read -p "请选择 [1/2]: " auth_choice
    case "$auth_choice" in
        2)
            read -p "私钥路径 [~/.ssh/id_rsa]: " input_key
            SSH_KEY=${input_key:-$HOME/.ssh/id_rsa}
            if [ ! -f "$SSH_KEY" ]; then
                SSH_KEY="${SSH_KEY/#\~/$HOME}"
            fi
            SSH_PASSWORD=""
            ;;
        *)
            read -s -p "SSH 密码: " SSH_PASSWORD
            echo ""
            SSH_KEY=""
            ;;
    esac

    ensure_ssh_tools || return 1
    build_ssh_opts
    return 0
}

collect_slave_list() {
    print_title "从库节点列表"

    SLAVE_HOSTS=()
    echo -e "${CYAN}请输入从库 SSH 信息（可添加多台，直接回车结束）${NC}"
    echo ""

    local idx=1
    while true; do
        read -p "从库 #${idx} IP/主机名 (空结束): " host
        [ -z "$host" ] && break

        local sport="$SSH_PORT"
        local suser="$SSH_USER"
        local spass="$SSH_PASSWORD"
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

        SLAVE_HOSTS+=("${host}|${sport}|${suser}|${spass}")
        echo -e "${GREEN}  已添加: $host (ssh $suser@$host:$sport)${NC}"
        idx=$((idx+1))
    done

    if [ ${#SLAVE_HOSTS[@]} -eq 0 ]; then
        echo -e "${RED}未添加任何从库${NC}"
        return 1
    fi

    echo ""
    echo -e "${CYAN}从库列表:${NC}"
    local n=1
    for item in "${SLAVE_HOSTS[@]}"; do
        IFS='|' read -r h p u _ <<< "$item"
        echo "  $n. $h (ssh $u@$h:$p)"
        n=$((n+1))
    done
    return 0
}

save_cluster_hosts() {
    {
        echo "# Generated: $(date)"
        echo "MASTER_HOST=${MASTER_HOST}"
        echo "MASTER_PORT=${MYSQL_PORT}"
        echo "MYSQL_REPL_USER=${MYSQL_REPL_USER}"
        echo "MYSQL_REPL_PASSWORD=${MYSQL_REPL_PASSWORD}"
        echo "SLAVE_HOSTS=(${SLAVE_HOSTS[*]})"
        echo "SSH_USER=${SSH_USER}"
        echo "SSH_PORT=${SSH_PORT}"
        echo "SSH_KEY=${SSH_KEY}"
        echo "MYSQL_HOME=${MYSQL_HOME}"
        echo "MYSQL_VERSION=${MYSQL_VERSION}"
        echo "REMOTE_MYSQL_HOME=${REMOTE_MYSQL_HOME}"
        echo "REMOTE_MYSQL_PORT=${REMOTE_MYSQL_PORT}"
    } > "$CLUSTER_STATE_FILE"
    chmod 600 "$CLUSTER_STATE_FILE"
    echo -e "${GREEN}✓ 集群节点信息已保存到 $CLUSTER_STATE_FILE${NC}"
}

remote_install_mysql() {
    local host="$1"
    local sport="$2"
    local suser="$3"
    local spass="$4"

    print_title "远程安装 MySQL → ${host}"

    # 覆盖全局 SSH 变量用于 ssh_cmd/scp
    local old_port="$SSH_PORT" old_user="$SSH_USER" old_pass="$SSH_PASSWORD"
    SSH_PORT="$sport"
    SSH_USER="$suser"
    SSH_PASSWORD="$spass"

    if ! test_ssh_connection "$host"; then
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 1
    fi

    # 远程环境检测
    local remote_info
    remote_info=$(ssh_cmd "$host" 'echo "ARCH=$(uname -m)"; command -v systemctl >/dev/null && echo HAS_SYSTEMD=1 || echo HAS_SYSTEMD=0; ldd --version 2>/dev/null | head -1')
    echo -e "${CYAN}远程环境:${NC}"
    echo "$remote_info"

    if ! echo "$remote_info" | grep -q "HAS_SYSTEMD=1"; then
        echo -e "${RED}远程主机缺少 systemd，无法使用当前安装脚本${NC}"
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 1
    fi

    if ! disable_remote_selinux "$host"; then
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 1
    fi

    # 确保有安装包
    if [ -z "$REMOTE_TARBALL_PATH" ] || [ ! -f "$REMOTE_TARBALL_PATH" ]; then
        echo -e "${YELLOW}本机未找到安装包，尝试定位...${NC}"
        find_local_tarball || {
            echo -e "${RED}无法定位安装包，无法远程离线安装${NC}"
            echo -e "${YELLOW}请先在本机安装一次（保留 tar.xz），或手动指定包路径${NC}"
            SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
            return 1
        }
    fi

    local tarball_name
    tarball_name=$(basename "$REMOTE_TARBALL_PATH")
    local rhome="${REMOTE_MYSQL_HOME:-${MYSQL_HOME:-/mnt/data/mysql}}"
    local rport="${REMOTE_MYSQL_PORT:-$MYSQL_PORT}"
    local rpass="${REMOTE_MYSQL_PASSWORD:-$MYSQL_ROOT_PASSWORD}"

    echo -e "${CYAN}远程安装参数:${NC}"
    echo "  Home: $rhome"
    echo "  Port: $rport"
    echo "  包:   $tarball_name"
    echo ""

    # 确保远程目录
    ssh_cmd "$host" "mkdir -p /tmp/mysql_remote_install && mkdir -p '$rhome'" || true

    echo -e "${YELLOW}[1/3] 上传安装脚本...${NC}"
    scp_to_remote "$INSTALL_SCRIPT" "$host" "/tmp/mysql_remote_install/install_mysql.sh" || {
        echo -e "${RED}上传安装脚本失败${NC}"
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 1
    }

    echo -e "${YELLOW}[2/3] 上传 MySQL 安装包（可能需要一段时间）...${NC}"
    scp_to_remote "$REMOTE_TARBALL_PATH" "$host" "/tmp/${tarball_name}" || {
        echo -e "${RED}上传安装包失败${NC}"
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 1
    }

    echo -e "${YELLOW}[3/3] 远程执行无人值守安装...${NC}"
    # --force-init-data: 从库应是干净实例，便于初始同步
    ssh_cmd "$host" "bash /tmp/mysql_remote_install/install_mysql.sh --batch --offline /tmp/${tarball_name} --home '$rhome' --port '$rport' --password '$rpass' --keep-tarball --force-init-data"
    local rc=$?

    # 读取远程安装状态
    if [ $rc -eq 0 ]; then
        local remote_state
        remote_state=$(ssh_cmd "$host" "cat /etc/mysql_install_state.conf 2>/dev/null")
        if [ -n "$remote_state" ]; then
            echo -e "${GREEN}远程安装状态:${NC}"
            echo "$remote_state"
        fi
        echo -e "${GREEN}✓ ${host} MySQL 安装完成${NC}"
    else
        echo -e "${RED}✗ ${host} MySQL 安装失败${NC}"
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 1
    fi

    # 清理远程上传的大包（可选，保留脚本日志）
    ssh_cmd "$host" "rm -f /tmp/${tarball_name}" >/dev/null 2>&1 || true

    SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
    return 0
}

# ======================== 配置主库 ========================

apply_replication_cnfs_to_file() {
    local my_cnf="$1"
    local role="$2"  # master | slave
    local server_id="$3"
    local binlog_dir="$4"
    local datadir="$5"

    if [ ! -f "$my_cnf" ]; then
        echo "[mysqld]" > "$my_cnf"
    fi

    if ! grep -q "^\[mysqld\]" "$my_cnf" 2>/dev/null; then
        echo "" >> "$my_cnf"
        echo "[mysqld]" >> "$my_cnf"
    fi

    # 清理旧复制配置
    sed -i '/^# MySQL Replication/d' "$my_cnf"
    sed -i '/^server-id/d' "$my_cnf"
    sed -i '/^log-bin/d' "$my_cnf"
    sed -i '/^binlog_format/d' "$my_cnf"
    sed -i '/^binlog_expire_logs_seconds/d' "$my_cnf"
    sed -i '/^relay-log/d' "$my_cnf"
    sed -i '/^read_only/d' "$my_cnf"
    sed -i '/^super_read_only/d' "$my_cnf"
    sed -i '/^gtid_mode/d' "$my_cnf"
    sed -i '/^enforce_gtid_consistency/d' "$my_cnf"
    sed -i '/^log_replica_updates/d' "$my_cnf"
    sed -i '/^log_slave_updates/d' "$my_cnf"

    local block=""
    block+="# MySQL Replication"$'\n'
    block+="server-id = ${server_id}"$'\n'

    if [[ "$role" == "master" ]]; then
        block+="log-bin = ${binlog_dir}/mysql-bin"$'\n'
        block+="binlog_format = ROW"$'\n'
        block+="binlog_expire_logs_seconds = 604800"$'\n'
    else
        block+="relay-log = ${datadir}/relay-bin"$'\n'
        block+="read_only = ON"$'\n'
        block+="super_read_only = ON"$'\n'
        # 从库也可开启 binlog，便于级联复制
        block+="log-bin = ${datadir}/mysql-bin"$'\n'
        block+="log_replica_updates = ON"$'\n'
    fi

    block+="gtid_mode = ON"$'\n'
    block+="enforce_gtid_consistency = ON"$'\n'

    # 插入到 [mysqld] 之后
    local tmp
    tmp=$(mktemp)
    awk -v block="$block" '
        { print }
        /^\[mysqld\]/ && !done { print ""; print block; done=1 }
    ' "$my_cnf" > "$tmp"
    mv "$tmp" "$my_cnf"
    echo -e "${GREEN}✓ 已写入 $my_cnf 的 $role 复制配置${NC}"
}

configure_master() {
    print_title "配置MySQL主库（本机）"

    if ! detect_mysql_installation; then
        echo -e "${YELLOW}MySQL未安装${NC}"
        echo "1. 本机无人值守安装（推荐）"
        echo "2. 交互式安装"
        echo "3. 退出"
        read -p "请选择 [1/2/3]: " choice
        case $choice in
            1) install_local_batch || return 1 ;;
            2) call_install_script || return 1 ;;
            *) return 1 ;;
        esac
    fi

    if ! check_service_status "mysql"; then
        echo -e "${YELLOW}尝试启动MySQL服务...${NC}"
        systemctl start mysql
        sleep 3
        if ! check_service_status "mysql"; then
            echo -e "${RED}MySQL服务启动失败${NC}"
            return 1
        fi
    fi

    # 密码
    if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
        read -s -p "MySQL Root密码 [root]: " input_password
        echo ""
        MYSQL_ROOT_PASSWORD=${input_password:-root}
    else
        echo -e "${CYAN}当前Root密码: $MYSQL_ROOT_PASSWORD${NC}"
        read -p "是否修改? [y/N]: " change_pass
        if [[ "$change_pass" =~ ^[Yy]$ ]]; then
            read -s -p "新的Root密码: " input_password
            echo ""
            MYSQL_ROOT_PASSWORD=${input_password:-$MYSQL_ROOT_PASSWORD}
        fi
    fi

    read -p "MySQL端口 [$MYSQL_PORT]: " input_port
    MYSQL_PORT=${input_port:-$MYSQL_PORT}

    # server-id
    MYSQL_SERVER_ID=$(generate_server_id)
    echo -e "${CYAN}生成 Server ID: $MYSQL_SERVER_ID${NC}"
    read -p "是否使用此Server ID? [Y/n]: " confirm_id
    if [[ $confirm_id =~ ^[Nn]$ ]]; then
        read -p "请输入Server ID (1-4294967295): " custom_id
        if [[ "$custom_id" =~ ^[0-9]+$ ]] && [ "$custom_id" -ge 1 ]; then
            MYSQL_SERVER_ID="$custom_id"
        fi
    fi

    # 复制账号
    echo ""
    echo -e "${CYAN}配置复制用户:${NC}"
    read -p "复制用户名 [$MYSQL_REPL_USER]: " input_user
    MYSQL_REPL_USER=${input_user:-$MYSQL_REPL_USER}
    read -p "复制用户密码 [$MYSQL_REPL_PASSWORD]: " input_pass
    MYSQL_REPL_PASSWORD=${input_pass:-$MYSQL_REPL_PASSWORD}

    # 主库IP
    local local_ip
    local_ip=$(get_local_ip)
    MASTER_HOST="$local_ip"
    echo -e "${CYAN}本机IP: $local_ip${NC}"
    read -p "从库连接主库使用的IP [$local_ip]: " input_master_host
    MASTER_HOST=${input_master_host:-$MASTER_HOST}

    echo ""
    echo -e "${CYAN}主库配置确认:${NC}"
    echo "  主库IP: $MASTER_HOST"
    echo "  Server ID: $MYSQL_SERVER_ID"
    echo "  端口: $MYSQL_PORT"
    echo "  复制用户: $MYSQL_REPL_USER"
    echo "  复制密码: $MYSQL_REPL_PASSWORD"
    echo "  GTID: ON"
    echo ""

    if ! confirm_action "确认以上主库配置?"; then
        return 1
    fi

    # 备份配置
    if [ -f "/etc/my.cnf" ]; then
        cp /etc/my.cnf "/etc/my.cnf.backup.$(date +%Y%m%d_%H%M%S)"
        echo -e "${GREEN}✓ 配置文件已备份${NC}"
    fi

    MYSQL_BINLOG_DIR="${MYSQL_DATA_DIR}"
    apply_replication_cnfs_to_file "/etc/my.cnf" "master" "$MYSQL_SERVER_ID" "$MYSQL_BINLOG_DIR" "$MYSQL_DATA_DIR"

    echo -e "${YELLOW}重启MySQL服务...${NC}"
    systemctl restart mysql
    sleep 3
    if ! check_service_status "mysql"; then
        echo -e "${RED}MySQL服务重启失败，请检查 /etc/my.cnf 与 error.log${NC}"
        return 1
    fi

    echo -e "${YELLOW}创建复制用户...${NC}"
    local create_user_sql="
        CREATE USER IF NOT EXISTS '${MYSQL_REPL_USER}'@'%' IDENTIFIED BY '${MYSQL_REPL_PASSWORD}';
        ALTER USER '${MYSQL_REPL_USER}'@'%' IDENTIFIED BY '${MYSQL_REPL_PASSWORD}';
        GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '${MYSQL_REPL_USER}'@'%';
        FLUSH PRIVILEGES;
    "
    if mysql_exec "$create_user_sql"; then
        echo -e "${GREEN}✓ 复制用户创建成功${NC}"
    else
        # 尝试 socket
        if mysql_exec "$create_user_sql" "$MYSQL_INSTALL_DIR/mysql.sock"; then
            echo -e "${GREEN}✓ 复制用户创建成功 (socket)${NC}"
        else
            echo -e "${RED}复制用户创建失败，请检查 root 密码${NC}"
            return 1
        fi
    fi

    # 获取主库状态
    local binlog_file binlog_pos gtid_executed
    binlog_file=$(mysql_exec "SHOW MASTER STATUS" | awk '{print $1}')
    binlog_pos=$(mysql_exec "SHOW MASTER STATUS" | awk '{print $2}')
    gtid_executed=$(mysql_exec "SELECT @@global.gtid_executed" | tr -d '\n')

    if [ -z "$binlog_file" ]; then
        binlog_file=$(mysql_exec "SHOW BINARY LOG STATUS" 2>/dev/null | awk '{print $1}')
        binlog_pos=$(mysql_exec "SHOW BINARY LOG STATUS" 2>/dev/null | awk '{print $2}')
    fi

    echo ""
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}MySQL 主库配置完成!${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo -e "  主库IP: ${GREEN}$MASTER_HOST${NC}"
    echo -e "  端口: ${GREEN}$MYSQL_PORT${NC}"
    echo -e "  Server ID: ${GREEN}$MYSQL_SERVER_ID${NC}"
    echo -e "  Binlog: ${GREEN}${binlog_file:-N/A}:${binlog_pos:-N/A}${NC}"
    echo -e "  GTID: ${GREEN}${gtid_executed:-N/A}${NC}"
    echo -e "  复制用户: ${GREEN}$MYSQL_REPL_USER${NC}"
    echo -e "  复制密码: ${GREEN}$MYSQL_REPL_PASSWORD${NC}"
    echo ""

    REPLICATION_ROLE="master"
    save_config "master"
    return 0
}

# ======================== 配置从库（本机或远程） ========================

build_slave_change_master_sql() {
    local host="$1"
    local port="$2"
    local user="$3"
    local pass="$4"
    if [[ "$USE_GTID" == true || "$USE_GTID" == "1" ]]; then
        cat <<EOF
STOP REPLICA;
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='${host}',
  SOURCE_PORT=${port},
  SOURCE_USER='${user}',
  SOURCE_PASSWORD='${pass}',
  SOURCE_AUTO_POSITION=1;
START REPLICA;
EOF
    else
        local binlog_file="$5"
        local binlog_pos="$6"
        cat <<EOF
STOP REPLICA;
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='${host}',
  SOURCE_PORT=${port},
  SOURCE_USER='${user}',
  SOURCE_PASSWORD='${pass}',
  SOURCE_LOG_FILE='${binlog_file}',
  SOURCE_LOG_POS=${binlog_pos};
START REPLICA;
EOF
    fi
}

configure_slave_remote() {
    local host="$1"
    local sport="$2"
    local suser="$3"
    local spass="$4"
    local rpass="${REMOTE_MYSQL_PASSWORD:-$MYSQL_ROOT_PASSWORD}"
    local rport="${REMOTE_MYSQL_PORT:-$MYSQL_PORT}"

    print_title "配置远程从库 → ${host}"

    local old_port="$SSH_PORT" old_user="$SSH_USER" old_pass="$SSH_PASSWORD"
    SSH_PORT="$sport"
    SSH_USER="$suser"
    SSH_PASSWORD="$spass"

    # 读取远程安装信息
    local remote_state remote_install_dir remote_datadir remote_home
    remote_state=$(ssh_cmd "$host" "cat /etc/mysql_install_state.conf 2>/dev/null")
    remote_install_dir=$(echo "$remote_state" | grep '^MYSQL_INSTALL_DIR=' | cut -d= -f2-)
    remote_datadir=$(echo "$remote_state" | grep '^MYSQL_DATA_DIR=' | cut -d= -f2-)
    remote_home=$(echo "$remote_state" | grep '^MYSQL_HOME=' | cut -d= -f2-)
    remote_port_state=$(echo "$remote_state" | grep '^MYSQL_PORT=' | cut -d= -f2-)
    rport=${remote_port_state:-$rport}

    if [ -z "$remote_install_dir" ]; then
        # 兜底探测
        remote_install_dir=$(ssh_cmd "$host" "ls -d /mnt/data/mysql/mysql-* /usr/local/mysql /opt/mysql/mysql-* 2>/dev/null | head -1")
        remote_home=$(dirname "$remote_install_dir" 2>/dev/null)
        remote_datadir="${remote_home}/data"
    fi

    if [ -z "$remote_install_dir" ]; then
        echo -e "${RED}无法确定远程 MySQL 安装目录${NC}"
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 1
    fi

    local server_id
    server_id=$(generate_server_id)
    # 尽量避免和主库冲突
    if [ "$server_id" == "$MYSQL_SERVER_ID" ]; then
        server_id=$((server_id + 1))
    fi

    echo -e "${CYAN}远程从库参数:${NC}"
    echo "  安装目录: $remote_install_dir"
    echo "  数据目录: $remote_datadir"
    echo "  端口: $rport"
    echo "  Server ID: $server_id"
    echo "  主库: ${MASTER_HOST}:${MYSQL_PORT}"
    echo "  方式: $( [[ "$USE_GTID" == true || "$USE_GTID" == "1" ]] && echo GTID || echo Binlog )"

    # 生成远程 my.cnf 片段并应用
    local remote_cnf_snippet="/tmp/mysql_repl_slave_${host}.cnf"
    cat > "$remote_cnf_snippet" << EOF
# MySQL Replication
server-id = ${server_id}
relay-log = ${remote_datadir}/relay-bin
read_only = ON
super_read_only = ON
log-bin = ${remote_datadir}/mysql-bin
log_replica_updates = ON
gtid_mode = ON
enforce_gtid_consistency = ON
EOF

    scp_to_remote "$remote_cnf_snippet" "$host" "/tmp/mysql_repl_slave.cnf" || {
        echo -e "${RED}上传从库配置片段失败${NC}"
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 1
    }

    echo -e "${YELLOW}远程合并配置并重启...${NC}"
    # 上传合并脚本，避免依赖 python3
    local merge_script="/tmp/mysql_apply_slave_cnf.sh"
    cat > "$merge_script" << 'MERGE_EOF'
#!/bin/bash
set -e
CNF=/etc/my.cnf
SNIPPET=/tmp/mysql_repl_slave.cnf
if [ -f "$CNF" ]; then
  cp "$CNF" "${CNF}.backup.$(date +%Y%m%d_%H%M%S)"
fi
if [ ! -f "$CNF" ]; then
  echo '[mysqld]' > "$CNF"
fi
if ! grep -q '^\[mysqld\]' "$CNF"; then
  echo '' >> "$CNF"
  echo '[mysqld]' >> "$CNF"
fi
sed -i '/^# MySQL Replication/d' "$CNF"
sed -i '/^server-id/d' "$CNF"
sed -i '/^log-bin/d' "$CNF"
sed -i '/^binlog_format/d' "$CNF"
sed -i '/^binlog_expire_logs_seconds/d' "$CNF"
sed -i '/^relay-log/d' "$CNF"
sed -i '/^read_only/d' "$CNF"
sed -i '/^super_read_only/d' "$CNF"
sed -i '/^gtid_mode/d' "$CNF"
sed -i '/^enforce_gtid_consistency/d' "$CNF"
sed -i '/^log_replica_updates/d' "$CNF"
sed -i '/^log_slave_updates/d' "$CNF"

TMP=$(mktemp)
awk -v snippet="$SNIPPET" '
  BEGIN { while ((getline line < snippet) > 0) buf = buf line "\n" }
  { print }
  /^\[mysqld\]/ && !done { printf "%s", buf; done=1 }
' "$CNF" > "$TMP"
mv "$TMP" "$CNF"

systemctl restart mysql
sleep 3
systemctl is-active --quiet mysql
MERGE_EOF

    scp_to_remote "$merge_script" "$host" "/tmp/mysql_apply_slave_cnf.sh" || {
        echo -e "${RED}上传配置合并脚本失败${NC}"
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 1
    }

    ssh_cmd "$host" "bash /tmp/mysql_apply_slave_cnf.sh" || {
        echo -e "${RED}远程配置/重启失败${NC}"
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 1
    }

    echo -e "${YELLOW}配置主从复制关系...${NC}"
    # 将 SQL 写到本地临时文件后 scp，避免嵌套引号问题
    local remote_mysql="${remote_install_dir}/bin/mysql"
    local sql_file="/tmp/mysql_repl_change_source.sql"
    if [[ "$USE_GTID" == true || "$USE_GTID" == "1" ]]; then
        cat > "$sql_file" << EOF
STOP REPLICA;
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='${MASTER_HOST}',
  SOURCE_PORT=${MYSQL_PORT},
  SOURCE_USER='${MYSQL_REPL_USER}',
  SOURCE_PASSWORD='${MYSQL_REPL_PASSWORD}',
  SOURCE_AUTO_POSITION=1;
START REPLICA;
EOF
    else
        local binlog_file binlog_pos
        binlog_file=$(mysql_exec "SHOW MASTER STATUS" | awk '{print $1}')
        binlog_pos=$(mysql_exec "SHOW MASTER STATUS" | awk '{print $2}')
        cat > "$sql_file" << EOF
STOP REPLICA;
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='${MASTER_HOST}',
  SOURCE_PORT=${MYSQL_PORT},
  SOURCE_USER='${MYSQL_REPL_USER}',
  SOURCE_PASSWORD='${MYSQL_REPL_PASSWORD}',
  SOURCE_LOG_FILE='${binlog_file}',
  SOURCE_LOG_POS=${binlog_pos};
START REPLICA;
EOF
    fi

    # MySQL 8.0.23+ SOURCE/REPLICA；旧版自动回退 MASTER/SLAVE
    local fallback_sql="/tmp/mysql_repl_change_source_fallback.sql"
    cat > "$fallback_sql" << EOF
STOP SLAVE;
CHANGE MASTER TO
  MASTER_HOST='${MASTER_HOST}',
  MASTER_PORT=${MYSQL_PORT},
  MASTER_USER='${MYSQL_REPL_USER}',
  MASTER_PASSWORD='${MYSQL_REPL_PASSWORD}',
  MASTER_AUTO_POSITION=1;
START SLAVE;
EOF

    scp_to_remote "$sql_file" "$host" "/tmp/mysql_repl_change_source.sql" || true
    scp_to_remote "$fallback_sql" "$host" "/tmp/mysql_repl_change_source_fallback.sql" || true

    local apply_sql_cmd
    apply_sql_cmd="${remote_mysql} -u root -p'${rpass}' < /tmp/mysql_repl_change_source.sql"
    local apply_fallback_cmd
    apply_fallback_cmd="${remote_mysql} -u root -p'${rpass}' < /tmp/mysql_repl_change_source_fallback.sql"

    ssh_cmd "$host" "$apply_sql_cmd" || ssh_cmd "$host" "$apply_fallback_cmd"
    if [ $? -ne 0 ]; then
        echo -e "${RED}远程配置复制失败${NC}"
        echo -e "${YELLOW}可登录从库后执行:${NC}"
        cat "$sql_file"
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 1
    fi

    sleep 2
    echo -e "${YELLOW}检查复制状态...${NC}"
    local status_sql="/tmp/mysql_show_replica.sql"
    printf 'SHOW REPLICA STATUS\\G\nSHOW SLAVE STATUS\\G\n' > "$status_sql"
    scp_to_remote "$status_sql" "$host" "/tmp/mysql_show_replica.sql" >/dev/null 2>&1 || true
    ssh_cmd "$host" "${remote_mysql} -u root -p'${rpass}' --table < /tmp/mysql_show_replica.sql 2>/dev/null" \
        | grep -E "Source_Host|Master_Host|Replica_IO_Running|Slave_IO_Running|Replica_SQL_Running|Slave_SQL_Running|Seconds_Behind|Last_IO_Error|Last_SQL_Error|Source_Log_File" \
        | sed 's/^/  /' \
        || echo -e "  ${YELLOW}无法读取复制状态，请手动检查${NC}"

    echo -e "${GREEN}✓ 远程从库 ${host} 配置完成${NC}"
    SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
    return 0
}

configure_slave_local() {
    print_title "配置MySQL从库（本机）"

    if ! detect_mysql_installation; then
        echo -e "${YELLOW}MySQL未安装${NC}"
        echo "1. 本机无人值守安装"
        echo "2. 交互式安装"
        echo "3. 退出"
        read -p "请选择 [1/2/3]: " choice
        case $choice in
            1) install_local_batch || return 1 ;;
            2) call_install_script || return 1 ;;
            *) return 1 ;;
        esac
    fi

    if ! check_service_status "mysql"; then
        systemctl start mysql
        sleep 3
        check_service_status "mysql" || return 1
    fi

    echo -e "${CYAN}请输入主库信息:${NC}"
    read -p "主库IP地址: " MASTER_HOST
    if [ -z "$MASTER_HOST" ]; then
        echo -e "${RED}主库IP不能为空${NC}"
        return 1
    fi
    read -p "主库端口 [$MASTER_PORT]: " input_port
    MASTER_PORT=${input_port:-$MASTER_PORT}
    read -p "复制用户名 [$MYSQL_REPL_USER]: " input_user
    MYSQL_REPL_USER=${input_user:-$MYSQL_REPL_USER}
    read -p "复制用户密码 [$MYSQL_REPL_PASSWORD]: " input_pass
    MYSQL_REPL_PASSWORD=${input_pass:-$MYSQL_REPL_PASSWORD}

    read -p "本机MySQL Root密码 [$MYSQL_ROOT_PASSWORD]: " input_password
    MYSQL_ROOT_PASSWORD=${input_password:-$MYSQL_ROOT_PASSWORD}
    read -p "本机端口 [$MYSQL_PORT]: " input_local_port
    MYSQL_PORT=${input_local_port:-$MYSQL_PORT}

    MYSQL_SERVER_ID=$(generate_server_id)
    echo -e "${CYAN}本机 Server ID: $MYSQL_SERVER_ID${NC}"

    echo ""
    echo "复制方式:"
    echo "1. GTID（推荐）"
    echo "2. Binlog 位置"
    read -p "请选择 [1/2]: " repl_mode
    USE_GTID=true
    local binlog_file="" binlog_pos=""
    if [[ "$repl_mode" == "2" ]]; then
        USE_GTID=false
        read -p "Binlog文件名: " binlog_file
        read -p "Binlog位置: " binlog_pos
    fi

    if ! confirm_action "确认配置本机为从库?"; then
        return 1
    fi

    [ -f /etc/my.cnf ] && cp /etc/my.cnf "/etc/my.cnf.backup.$(date +%Y%m%d_%H%M%S)"
    apply_replication_cnfs_to_file "/etc/my.cnf" "slave" "$MYSQL_SERVER_ID" "$MYSQL_DATA_DIR" "$MYSQL_DATA_DIR"

    systemctl restart mysql
    sleep 3
    check_service_status "mysql" || return 1

    local change_sql
    if [[ "$USE_GTID" == true || "$USE_GTID" == "1" ]]; then
        change_sql="STOP REPLICA;
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='${MASTER_HOST}',
  SOURCE_PORT=${MASTER_PORT},
  SOURCE_USER='${MYSQL_REPL_USER}',
  SOURCE_PASSWORD='${MYSQL_REPL_PASSWORD}',
  SOURCE_AUTO_POSITION=1;
START REPLICA;"
    else
        change_sql="STOP REPLICA;
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='${MASTER_HOST}',
  SOURCE_PORT=${MASTER_PORT},
  SOURCE_USER='${MYSQL_REPL_USER}',
  SOURCE_PASSWORD='${MYSQL_REPL_PASSWORD}',
  SOURCE_LOG_FILE='${binlog_file}',
  SOURCE_LOG_POS=${binlog_pos};
START REPLICA;"
    fi

    if ! mysql_exec "$change_sql"; then
        mysql_exec "STOP SLAVE; CHANGE MASTER TO MASTER_HOST='${MASTER_HOST}', MASTER_PORT=${MASTER_PORT}, MASTER_USER='${MYSQL_REPL_USER}', MASTER_PASSWORD='${MYSQL_REPL_PASSWORD}', MASTER_AUTO_POSITION=1; START SLAVE;"
    fi

    sleep 2
    check_replication_status
    REPLICATION_ROLE="slave"
    save_config "slave"
    return 0
}

# ======================== 一键主从部署 ========================

one_click_deploy() {
    print_title "一键主从集群部署（本机主库 + SSH远程从库）"

    echo -e "${CYAN}流程:${NC}"
    echo "  1. 本机编译/二进制安装 MySQL 并配置为主库"
    echo "  2. 将安装包与安装脚本 scp 到各从库"
    echo "  3. SSH 在从库无人值守安装 MySQL"
    echo "  4. 自动写入主从复制参数并启动复制"
    echo "  5. 校验 IO/SQL 线程状态"
    echo ""

    if ! confirm_action "开始一键部署?"; then
        return 1
    fi

    # SSH 信息
    collect_ssh_info || return 1
    collect_slave_list || return 1

    # 本机主库
    echo ""
    echo -e "${YELLOW}===== 步骤 A: 本机主库 =====${NC}"
    if detect_mysql_installation; then
        echo -e "${GREEN}本机已安装MySQL，跳过安装，直接配置主库${NC}"
        read -p "MySQL Root密码 [root]: " input_pass
        MYSQL_ROOT_PASSWORD=${input_pass:-root}
    else
        echo "1. 本机无人值守安装（推荐，自动保留安装包）"
        echo "2. 交互式安装"
        read -p "请选择 [1/2]: " local_install_choice
        case "$local_install_choice" in
            2) call_install_script || return 1 ;;
            *) install_local_batch || return 1 ;;
        esac
    fi

    configure_master || return 1

    # 确保有安装包
    if [ -z "$REMOTE_TARBALL_PATH" ] || [ ! -f "$REMOTE_TARBALL_PATH" ]; then
        echo -e "${YELLOW}定位本机安装包用于分发...${NC}"
        find_local_tarball || {
            echo -e "${RED}未找到可分发的 tar.xz，远程离线安装将失败${NC}"
            if ! confirm_action "是否继续（从库可能需要你自行安装）?"; then
                return 1
            fi
        }
    fi

    # 远程从库
    local slave_idx=1
    local failed=0
    for item in "${SLAVE_HOSTS[@]}"; do
        IFS='|' read -r h p u pw <<< "$item"
        echo ""
        echo -e "${YELLOW}===== 步骤 B.${slave_idx}: 远程从库 ${h} =====${NC}"

        if remote_install_mysql "$h" "$p" "$u" "$pw"; then
            configure_slave_remote "$h" "$p" "$u" "$pw" || failed=$((failed+1))
        else
            echo -e "${RED}跳过 ${h}（安装失败）${NC}"
            failed=$((failed+1))
        fi
        slave_idx=$((slave_idx+1))
    done

    save_cluster_hosts

    echo ""
    print_title "一键部署结果"
    echo -e "主库: ${GREEN}${MASTER_HOST}:${MYSQL_PORT}${NC}"
    echo -e "Server ID: ${GREEN}${MYSQL_SERVER_ID}${NC}"
    echo -e "从库数量: ${#SLAVE_HOSTS[@]}  失败: ${failed}"
    echo -e "复制用户: ${GREEN}${MYSQL_REPL_USER}${NC}"
    echo ""
    echo -e "${CYAN}后续可随时执行:${NC}"
    echo "  bash $0 status          # 检查复制状态"
    echo "  bash $0 one             # 重新进入一键部署"
    echo ""

    if [ $failed -eq 0 ]; then
        echo -e "${GREEN}✓ 主从集群部署完成${NC}"
    else
        echo -e "${YELLOW}部分节点失败，请检查上方日志${NC}"
    fi
    return 0
}

# ======================== 检查复制状态 ========================

check_local_replica_status() {
    local mysql_bin="${MYSQL_INSTALL_DIR}/bin/mysql"
    [ -x "$mysql_bin" ] || mysql_bin="mysql"

    local status
    status=$($mysql_bin -u root -p"$MYSQL_ROOT_PASSWORD" -h 127.0.0.1 -P "$MYSQL_PORT" -e "SHOW REPLICA STATUS\G" 2>/dev/null)
    if [ -z "$status" ]; then
        status=$($mysql_bin -u root -p"$MYSQL_ROOT_PASSWORD" -h 127.0.0.1 -P "$MYSQL_PORT" -e "SHOW SLAVE STATUS\G" 2>/dev/null)
    fi

    if [ -z "$status" ]; then
        echo -e "  ${YELLOW}本机未配置为从库，或无法连接${NC}"
        return 0
    fi

    local io_running sql_running seconds host
    io_running=$(echo "$status" | grep -E "Replica_IO_Running:|Slave_IO_Running:" | awk '{print $2}' | tail -1)
    sql_running=$(echo "$status" | grep -E "Replica_SQL_Running:|Slave_SQL_Running:" | awk '{print $2}' | tail -1)
    seconds=$(echo "$status" | grep -E "Seconds_Behind_Source:|Seconds_Behind_Master:" | awk '{print $2}' | tail -1)
    host=$(echo "$status" | grep -E "Source_Host:|Master_Host:" | awk '{print $2}' | tail -1)

    echo -e "  主库地址: $host"
    if [ "$io_running" = "Yes" ] && [ "$sql_running" = "Yes" ]; then
        echo -e "  IO线程: ${GREEN}$io_running${NC}  SQL线程: ${GREEN}$sql_running${NC}  延迟: ${GREEN}${seconds:-0}s${NC}"
    else
        echo -e "  IO线程: ${RED}$io_running${NC}  SQL线程: ${RED}$sql_running${NC}"
        echo "$status" | grep -E "Last_IO_Error:|Last_SQL_Error:" | grep -v ": $" | sed 's/^/  /'
    fi
}

check_remote_replica_status() {
    local host="$1"
    local sport="$2"
    local suser="$3"
    local spass="$4"
    local rpass="${REMOTE_MYSQL_PASSWORD:-$MYSQL_ROOT_PASSWORD}"

    local old_port="$SSH_PORT" old_user="$SSH_USER" old_pass="$SSH_PASSWORD"
    SSH_PORT="$sport"; SSH_USER="$suser"; SSH_PASSWORD="$spass"

    local remote_state remote_install_dir rport
    remote_state=$(ssh_cmd "$host" "cat /etc/mysql_install_state.conf 2>/dev/null")
    remote_install_dir=$(echo "$remote_state" | grep '^MYSQL_INSTALL_DIR=' | cut -d= -f2-)
    rport=$(echo "$remote_state" | grep '^MYSQL_PORT=' | cut -d= -f2-)
    rport=${rport:-3306}
    if [ -z "$remote_install_dir" ]; then
        remote_install_dir=$(ssh_cmd "$host" "ls -d /mnt/data/mysql/mysql-* 2>/dev/null | head -1")
    fi

    echo -e "${CYAN}从库 ${host}:${rport}${NC}"
    if [ -z "$remote_install_dir" ]; then
        echo -e "  ${YELLOW}无法定位远程MySQL${NC}"
    else
        local remote_sql="/tmp/mysql_show_replica_status.sql"
        printf 'SHOW REPLICA STATUS\\G\nSHOW SLAVE STATUS\\G\n' > "$remote_sql"
        scp_to_remote "$remote_sql" "$host" "/tmp/mysql_show_replica_status.sql" >/dev/null 2>&1 || true
        ssh_cmd "$host" "'${remote_install_dir}/bin/mysql' -u root -p'${rpass}' < /tmp/mysql_show_replica_status.sql 2>/dev/null" \
          | grep -E "Source_Host|Master_Host|Replica_IO_Running|Slave_IO_Running|Replica_SQL_Running|Slave_SQL_Running|Seconds_Behind|Last_IO_Error|Last_SQL_Error" \
          | sed 's/^/  /' \
          || echo -e "  ${YELLOW}无法读取复制状态${NC}"
    fi

    SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
}

check_replication_status() {
    print_title "检查MySQL复制状态"

    # 尝试加载集群信息
    if [ -f "$CLUSTER_STATE_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CLUSTER_STATE_FILE"
        echo -e "${GREEN}已加载集群节点信息${NC}"
    fi

    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi

    detect_mysql_installation || true

    if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
        read -s -p "请输入MySQL Root密码: " MYSQL_ROOT_PASSWORD
        echo ""
    fi

    echo -e "${CYAN}===== 本机 =====${NC}"
    local master_status
    master_status=$(mysql_exec "SHOW MASTER STATUS")
    if [ -z "$master_status" ]; then
        master_status=$(mysql_exec "SHOW BINARY LOG STATUS")
    fi
    if [ -n "$master_status" ]; then
        echo -e "  主库Binlog: ${GREEN}$(echo "$master_status" | awk '{print $1":"$2}')${NC}"
    else
        echo -e "  ${YELLOW}本机未作为主库或无法读取 binlog 状态${NC}"
    fi
    check_local_replica_status

    # 远程从库
    if [ ${#SLAVE_HOSTS[@]} -gt 0 ]; then
        echo ""
        echo -e "${CYAN}===== 远程从库 =====${NC}"
        for item in "${SLAVE_HOSTS[@]}"; do
            IFS='|' read -r h p u pw <<< "$item"
            check_remote_replica_status "$h" "$p" "$u" "$pw"
            echo ""
        done
    fi

    return 0
}

# ======================== 重置复制配置 ========================

reset_replication() {
    print_title "重置MySQL复制配置（本机）"

    if ! detect_mysql_installation; then
        echo -e "${RED}未找到MySQL安装${NC}"
        return 1
    fi

    if ! confirm_action "确认要重置本机复制配置?"; then
        return 1
    fi

    if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
        read -s -p "请输入MySQL Root密码: " MYSQL_ROOT_PASSWORD
        echo ""
    fi

    mysql_exec "STOP REPLICA; RESET REPLICA ALL;" 2>/dev/null \
      || mysql_exec "STOP SLAVE; RESET SLAVE ALL;" 2>/dev/null

    if [ -f "/etc/my.cnf" ]; then
        sed -i '/^# MySQL Replication/d' /etc/my.cnf
        sed -i '/^server-id/d' /etc/my.cnf
        sed -i '/^log-bin/d' /etc/my.cnf
        sed -i '/^relay-log/d' /etc/my.cnf
        sed -i '/^read_only/d' /etc/my.cnf
        sed -i '/^super_read_only/d' /etc/my.cnf
        sed -i '/^gtid_mode/d' /etc/my.cnf
        sed -i '/^enforce_gtid_consistency/d' /etc/my.cnf
        sed -i '/^log_replica_updates/d' /etc/my.cnf
        echo -e "${GREEN}✓ 配置文件已清理${NC}"
    fi

    rm -f "$CONFIG_FILE"
    echo -e "${YELLOW}注意: 需重启 MySQL 后完全生效: systemctl restart mysql${NC}"
}

# ======================== 保存配置 ========================

save_config() {
    local role="$1"
    cat > "$CONFIG_FILE" << EOF
# MySQL Replication Configuration
# Generated: $(date)

REPLICATION_ROLE=$role
MYSQL_INSTALL_DIR=$MYSQL_INSTALL_DIR
MYSQL_DATA_DIR=$MYSQL_DATA_DIR
MYSQL_HOME=$MYSQL_HOME
MYSQL_PORT=$MYSQL_PORT
MYSQL_VERSION=$MYSQL_VERSION
MYSQL_SERVER_ID=$MYSQL_SERVER_ID
MASTER_HOST=$MASTER_HOST
MASTER_PORT=$MASTER_PORT
MYSQL_REPL_USER=$MYSQL_REPL_USER
MYSQL_REPL_PASSWORD=$MYSQL_REPL_PASSWORD
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
USE_GTID=$USE_GTID
REMOTE_MYSQL_HOME=$REMOTE_MYSQL_HOME
REMOTE_MYSQL_PORT=$REMOTE_MYSQL_PORT
REMOTE_MYSQL_PASSWORD=$REMOTE_MYSQL_PASSWORD
REMOTE_TARBALL_PATH=$REMOTE_TARBALL_PATH
EOF
    chmod 600 "$CONFIG_FILE"
    echo -e "${GREEN}✓ 配置已保存到 $CONFIG_FILE${NC}"
}

# ======================== 帮助 ========================

show_help() {
    print_title "MySQL 主从复制配置脚本帮助"

    echo -e "${CYAN}用法:${NC}"
    echo "  bash setup_mysql_replication.sh [选项]"
    echo ""
    echo -e "${CYAN}选项:${NC}"
    echo "  one       一键部署：本机主库 + SSH远程安装/配置从库"
    echo "  master    仅配置本机为主库"
    echo "  slave     仅配置本机为从库"
    echo "  remote    仅远程安装并配置从库（需本机已是主库）"
    echo "  status    检查本机 + 已知远程从库复制状态"
    echo "  reset     重置本机复制配置"
    echo "  install   仅本机安装 MySQL"
    echo "  help      显示帮助"
    echo ""
    echo -e "${CYAN}一键部署会:${NC}"
    echo "  1. 本机安装 MySQL（可选）并配置主库"
    echo "  2. scp 安装包 install_mysql.sh 到从库"
    echo "  3. SSH 执行 install_mysql.sh --batch --offline ..."
    echo "  4. 自动写入 GTID 主从参数并 START REPLICA"
    echo ""
    echo -e "${CYAN}依赖:${NC}"
    echo "  - 本机 root"
    echo "  - SSH 可登录从库 root（密钥或 sshpass+密码）"
    echo "  - 从库具备 systemd"
    echo ""
    echo -e "${CYAN}安装脚本无人值守参数:${NC}"
    echo "  bash install_mysql.sh --batch --version 8.4.9 \\"
    echo "      --home /mnt/data/mysql --port 3306 --password root --keep-tarball"
    echo "  bash install_mysql.sh --batch --offline /tmp/mysql-xxx.tar.xz \\"
    echo "      --home /mnt/data/mysql --port 3306 --password root --force-init-data"
}

# ======================== 远程单独入口 ========================

remote_only_flow() {
    print_title "远程从库安装与配置"

    if ! detect_mysql_installation; then
        echo -e "${RED}本机未检测到 MySQL，建议先配置主库${NC}"
    fi

    # 加载已有主库信息
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        echo -e "${GREEN}已加载主库配置: ${MASTER_HOST}:${MYSQL_PORT}${NC}"
    fi

    if [ -z "$MASTER_HOST" ]; then
        read -p "主库IP: " MASTER_HOST
    fi
    if [ -z "$MYSQL_REPL_USER" ]; then
        read -p "复制用户 [repl]: " MYSQL_REPL_USER
        MYSQL_REPL_USER=${MYSQL_REPL_USER:-repl}
    fi
    if [ -z "$MYSQL_REPL_PASSWORD" ]; then
        read -p "复制密码 [$MYSQL_REPL_PASSWORD]: " input
        MYSQL_REPL_PASSWORD=${input:-$MYSQL_REPL_PASSWORD}
    fi
    read -p "主库Root密码(用于读取binlog可选) [$MYSQL_ROOT_PASSWORD]: " input
    MYSQL_ROOT_PASSWORD=${input:-$MYSQL_ROOT_PASSWORD}

    collect_ssh_info || return 1
    collect_slave_list || return 1

    find_local_tarball || true

    local failed=0
    for item in "${SLAVE_HOSTS[@]}"; do
        IFS='|' read -r h p u pw <<< "$item"
        remote_install_mysql "$h" "$p" "$u" "$pw" || { failed=$((failed+1)); continue; }
        configure_slave_remote "$h" "$p" "$u" "$pw" || failed=$((failed+1))
    done

    save_cluster_hosts
    if [ $failed -eq 0 ]; then
        echo -e "${GREEN}✓ 远程从库配置完成${NC}"
    else
        echo -e "${YELLOW}存在失败节点: $failed${NC}"
    fi
}

# ======================== 主菜单 ========================

show_main_menu() {
    print_title "MySQL 主从复制配置工具"

    local local_ip
    local_ip=$(get_local_ip)
    echo -e "${CYAN}本机IP: ${local_ip:-未知}${NC}"
    if [ -f "$INSTALL_STATE_FILE" ]; then
        echo -e "${CYAN}已检测到本机安装状态${NC}"
    fi
    echo ""
    echo "请选择操作:"
    echo ""
    echo -e "  ${GREEN}1. 一键主从部署${NC}（本机主库 + SSH远程安装从库）"
    echo "  2. 配置本机为主库 (Master)"
    echo "  3. 配置本机为从库 (Slave)"
    echo "  4. 远程安装/配置从库"
    echo "  5. 检查复制状态（含远程）"
    echo "  6. 重置本机复制配置"
    echo "  7. 本机安装MySQL"
    echo "  8. 显示帮助信息"
    echo "  q. 退出"
    echo ""

    read -p "请选择 [1-8/q]: " main_choice

    case $main_choice in
        1) one_click_deploy ;;
        2) configure_master ;;
        3) configure_slave_local ;;
        4) remote_only_flow ;;
        5) check_replication_status ;;
        6) reset_replication ;;
        7) call_install_script ;;
        8) show_help ;;
        q|Q)
            echo -e "${GREEN}退出脚本${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            ;;
    esac
}

# ======================== 主程序入口 ========================

main() {
    if [ $# -gt 0 ]; then
        case "$1" in
            one|deploy|cluster)
                one_click_deploy
                ;;
            master)
                configure_master
                ;;
            slave)
                configure_slave_local
                ;;
            remote)
                remote_only_flow
                ;;
            status)
                check_replication_status
                ;;
            reset)
                reset_replication
                ;;
            install)
                call_install_script
                ;;
            help|-h|--help)
                show_help
                ;;
            *)
                echo -e "${RED}未知参数: $1${NC}"
                echo "使用 '$0 help' 查看帮助信息"
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

# 执行主程序
main "$@"
