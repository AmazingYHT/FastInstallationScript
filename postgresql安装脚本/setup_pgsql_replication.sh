#!/bin/bash

# PostgreSQL 流复制一键配置脚本
# 支持：交互配置主/从库、SSH 远程安装配置从库、创建复制账号与业务账号
# 兼容 Ubuntu 22/24、Debian 12、CentOS Stream/Rocky/AlmaLinux 8/9

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ -z "$BASH_VERSION" ]; then
    echo -e "${RED}错误: 请使用bash执行此脚本${NC}"
    echo "正确用法: bash setup_pgsql_replication.sh"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}此脚本需要以root权限运行${NC}"
   exit 1
fi

# ======================== 全局变量 ========================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="$SCRIPT_DIR/install_postgresql.sh"
CONFIG_FILE="/etc/pgsql_replication.conf"
CLUSTER_STATE_FILE="/etc/pgsql_cluster_hosts.conf"

# PostgreSQL
PG_INSTALL_DIR=""
PG_DATA_DIR=""
PG_PORT="5432"
PG_OS_USER="postgres"
PG_SUPER_PASSWORD="postgres"
PG_VERSION=""

# 复制账号
PG_REPL_USER="repl"
PG_REPL_PASSWORD="Repl@$(date +%Y)Pass"

# 业务账号（可选，如 scpdata）
CREATE_APP_USER="no"
APP_DB_NAME="scpdata"
APP_DB_USER="scpdata"
APP_DB_PASSWORD=""

# 主从
REPLICATION_ROLE=""   # primary | replica
PRIMARY_HOST=""
PRIMARY_PORT="5432"
SYNCHRONOUS="off"     # on|off 同步复制

# SSH
SSH_USER="root"
SSH_PORT="22"
SSH_PASSWORD=""
SSH_KEY=""
SSH_OPTS=""

# 远程从库: host|ssh_port|ssh_user|ssh_pass|pg_port
REPLICA_NODES=()

# ======================== 工具 ========================

print_title() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${GREEN}$1${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""
}

info()    { echo -e "${CYAN}[INFO] $1${NC}"; }
success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }
warn()    { echo -e "${YELLOW}[WARN] $1${NC}"; }

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
    fi
    echo -e "${RED}✗ $service_name 服务未运行${NC}"
    return 1
}

get_local_ip() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [ -z "$ip" ]; then
        ip=$(ip -4 addr show 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | head -1)
    fi
    echo "$ip"
}

find_pg_service_name() {
    local service_name=""
    local version_short="${PG_VERSION%.*}"
    local possible_names=(
        "postgresql${version_short}"
        "postgresql-${version_short}"
        "postgresql@${version_short}-main"
        "postgresql"
    )
    # 从安装目录推断（编译安装常见）
    if [ -n "$PG_INSTALL_DIR" ] && [ -f "/etc/systemd/system/postgresql.service" ]; then
        if grep -q "$PG_INSTALL_DIR" /etc/systemd/system/postgresql.service 2>/dev/null; then
            echo "postgresql"
            return 0
        fi
    fi
    for name in "${possible_names[@]}"; do
        if systemctl list-units --all --type=service --no-legend 2>/dev/null | grep -q "^${name}\.service"; then
            service_name="$name"
            break
        fi
    done
    echo "$service_name"
}

# 以 postgres 用户执行 psql
psql_exec() {
    local sql="$1"
    local db="${2:-postgres}"
    if [ -n "$PG_INSTALL_DIR" ] && [ -x "$PG_INSTALL_DIR/bin/psql" ]; then
        sudo -u "$PG_OS_USER" "$PG_INSTALL_DIR/bin/psql" -p "$PG_PORT" -d "$db" -t -A -c "$sql" 2>/dev/null
    else
        sudo -u "$PG_OS_USER" psql -p "$PG_PORT" -d "$db" -t -A -c "$sql" 2>/dev/null
    fi
}

# ======================== SSH ========================

ensure_ssh_tools() {
    if ! command -v ssh >/dev/null 2>&1 || ! command -v scp >/dev/null 2>&1; then
        echo -e "${RED}未找到 ssh/scp${NC}"
        return 1
    fi
    if [ -n "$SSH_PASSWORD" ] && ! command -v sshpass >/dev/null 2>&1; then
        warn "尝试安装 sshpass..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get install -y sshpass 2>/dev/null || true
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y sshpass 2>/dev/null || true
        elif command -v yum >/dev/null 2>&1; then
            yum install -y sshpass 2>/dev/null || true
        fi
        if ! command -v sshpass >/dev/null 2>&1; then
            echo -e "${RED}sshpass 不可用，请配置 SSH 免密${NC}"
            return 1
        fi
    fi
    return 0
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

# ======================== 检测安装 ========================

detect_postgresql_installation() {
    echo -e "${YELLOW}检测PostgreSQL安装...${NC}"

    # 优先读复制状态文件
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        if [ -n "$PG_INSTALL_DIR" ] && [ -f "$PG_INSTALL_DIR/bin/psql" ]; then
            echo -e "${GREEN}从配置加载: $PG_INSTALL_DIR${NC}"
            return 0
        fi
    fi

    local pg_paths=(
        "/mnt/data/postgresql"
        "/usr/local/pgsql"
        "/usr/local/postgresql"
        "/opt/pgsql"
        "/opt/postgresql"
        "/var/lib/pgsql"
        "/usr/pgsql-18"
        "/usr/pgsql-17"
        "/usr/pgsql-16"
    )
    [ -n "$PGHOME" ] && pg_paths=("$PGHOME" "${pg_paths[@]}")

    # 常见布局: PG_HOME/pg18 或 PG_HOME/postgresql-x.y
    local base
    for base in /mnt/data/postgresql /usr/local /opt; do
        [ -d "$base" ] || continue
        while IFS= read -r d; do
            pg_paths+=("$d")
        done < <(find "$base" -maxdepth 2 -type f -path '*/bin/psql' 2>/dev/null | sed 's|/bin/psql||')
    done

    for path in "${pg_paths[@]}"; do
        if [ -f "$path/bin/psql" ]; then
            PG_INSTALL_DIR="$path"
            PG_VERSION=$("$PG_INSTALL_DIR/bin/psql" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
            if [ -z "$PG_DATA_DIR" ] || [ ! -d "$PG_DATA_DIR" ]; then
                # 常见: $PG_INSTALL_DIR/data 或 $PG_INSTALL_DIR/../data
                if [ -d "$PG_INSTALL_DIR/data" ]; then
                    PG_DATA_DIR="$PG_INSTALL_DIR/data"
                elif [ -d "$(dirname "$PG_INSTALL_DIR")/data" ]; then
                    PG_DATA_DIR="$(dirname "$PG_INSTALL_DIR")/data"
                elif [ -n "$PGDATA" ] && [ -d "$PGDATA" ]; then
                    PG_DATA_DIR="$PGDATA"
                fi
            fi
            if [ -n "$PG_DATA_DIR" ] && [ -f "$PG_DATA_DIR/postgresql.conf" ]; then
                local p
                p=$(grep -E "^port\s*=" "$PG_DATA_DIR/postgresql.conf" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | tr -d ' ')
                PG_PORT=${p:-$PG_PORT}
            fi
            echo -e "${GREEN}找到PostgreSQL: $PG_INSTALL_DIR (v${PG_VERSION})${NC}"
            [ -n "$PG_DATA_DIR" ] && echo -e "${GREEN}数据目录: $PG_DATA_DIR${NC}"
            return 0
        fi
    done

    if command -v psql >/dev/null 2>&1; then
        local psql_path
        psql_path=$(command -v psql)
        PG_INSTALL_DIR=$(dirname "$(dirname "$psql_path")")
        PG_VERSION=$($PG_INSTALL_DIR/bin/psql --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
        echo -e "${GREEN}找到PostgreSQL: $PG_INSTALL_DIR${NC}"
        return 0
    fi

    echo -e "${RED}未找到PostgreSQL安装${NC}"
    return 1
}

call_install_script() {
    print_title "安装PostgreSQL"
    if [ ! -f "$INSTALL_SCRIPT" ]; then
        echo -e "${RED}未找到安装脚本: $INSTALL_SCRIPT${NC}"
        return 1
    fi
    confirm_action "即将调用交互式安装脚本，是否继续?" || return 1
    bash "$INSTALL_SCRIPT"
    detect_postgresql_installation || return 1
    success "PostgreSQL 安装检测通过"
    return 0
}

ensure_pg_running() {
    local service_name
    service_name=$(find_pg_service_name)
    if [ -n "$service_name" ]; then
        if ! check_service_status "$service_name"; then
            info "尝试启动 $service_name ..."
            systemctl start "$service_name"
            sleep 3
            check_service_status "$service_name" || return 1
        fi
    else
        # pg_ctl 启动
        if [ -n "$PG_DATA_DIR" ] && [ -x "$PG_INSTALL_DIR/bin/pg_ctl" ]; then
            sudo -u "$PG_OS_USER" "$PG_INSTALL_DIR/bin/pg_ctl" -D "$PG_DATA_DIR" status >/dev/null 2>&1 || \
                sudo -u "$PG_OS_USER" "$PG_INSTALL_DIR/bin/pg_ctl" -D "$PG_DATA_DIR" -l "$PG_DATA_DIR/logfile" start
            sleep 2
        fi
    fi
    return 0
}

# ======================== 配置主库 ========================

configure_primary() {
    print_title "配置PostgreSQL主库 (Primary)"

    if ! detect_postgresql_installation; then
        echo "1. 先安装 PostgreSQL"
        echo "2. 退出"
        read -p "请选择 [1/2]: " choice
        [ "$choice" = "1" ] || return 1
        call_install_script || return 1
    fi

    ensure_pg_running || return 1

    local local_ip
    local_ip=$(get_local_ip)

    echo -e "${CYAN}===== 基础配置 =====${NC}"
    read -p "PostgreSQL端口 [$PG_PORT]: " input; PG_PORT=${input:-$PG_PORT}
    read -p "OS用户 [$PG_OS_USER]: " input; PG_OS_USER=${input:-$PG_OS_USER}
    read -p "数据目录 [$PG_DATA_DIR]: " input; PG_DATA_DIR=${input:-$PG_DATA_DIR}
    read -p "超级用户密码 [$PG_SUPER_PASSWORD]: " input; PG_SUPER_PASSWORD=${input:-$PG_SUPER_PASSWORD}

    echo ""
    echo -e "${CYAN}===== 复制账号 =====${NC}"
    read -p "复制用户名 [$PG_REPL_USER]: " input; PG_REPL_USER=${input:-$PG_REPL_USER}
    read -p "复制密码 [$PG_REPL_PASSWORD]: " input; PG_REPL_PASSWORD=${input:-$PG_REPL_PASSWORD}
    read -p "是否启用同步复制 synchronous_commit? [y/N]: " input
    if [[ "$input" =~ ^[Yy]$ ]]; then
        SYNCHRONOUS="on"
    else
        SYNCHRONOUS="off"
    fi

    echo ""
    echo -e "${CYAN}===== 业务账号（可选）=====${NC}"
    read -p "是否创建业务库/账号? [y/N]: " input
    if [[ "$input" =~ ^[Yy]$ ]]; then
        CREATE_APP_USER="yes"
        read -p "业务库名 [$APP_DB_NAME]: " input; APP_DB_NAME=${input:-$APP_DB_NAME}
        read -p "业务用户名 [$APP_DB_USER]: " input; APP_DB_USER=${input:-$APP_DB_USER}
        read -p "业务用户密码 [自动生成]: " input
        if [ -n "$input" ]; then
            APP_DB_PASSWORD="$input"
        else
            APP_DB_PASSWORD=$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)
            echo -e "${GREEN}生成业务密码: $APP_DB_PASSWORD${NC}"
        fi
    fi

    read -p "从库连接主库使用的IP [$local_ip]: " input; PRIMARY_HOST=${input:-$local_ip}

    echo ""
    info "配置汇总:"
    info "  主库IP: $PRIMARY_HOST:$PG_PORT"
    info "  数据目录: $PG_DATA_DIR"
    info "  复制账号: $PG_REPL_USER"
    info "  同步复制: $SYNCHRONOUS"
    if [ "$CREATE_APP_USER" = "yes" ]; then
        info "  业务库: $APP_DB_NAME  用户: $APP_DB_USER"
    fi
    confirm_action "确认配置本机为主库?" || return 1

    # 备份配置
    [ -f "$PG_DATA_DIR/postgresql.conf" ] && cp "$PG_DATA_DIR/postgresql.conf" "$PG_DATA_DIR/postgresql.conf.backup.$(date +%Y%m%d_%H%M%S)"
    [ -f "$PG_DATA_DIR/pg_hba.conf" ] && cp "$PG_DATA_DIR/pg_hba.conf" "$PG_DATA_DIR/pg_hba.conf.backup.$(date +%Y%m%d_%H%M%S)"

    # postgresql.conf
    info "写入 postgresql.conf 复制参数..."
    local conf="$PG_DATA_DIR/postgresql.conf"
    sed -i '/^# ===== Replication (setup_pgsql_replication)/d' "$conf"
    sed -i '/^wal_level\s*=/d' "$conf"
    sed -i '/^max_wal_senders\s*=/d' "$conf"
    sed -i '/^wal_keep_size\s*=/d' "$conf"
    sed -i '/^hot_standby\s*=/d' "$conf"
    sed -i '/^synchronous_commit\s*=/d' "$conf"
    sed -i '/^archive_mode\s*=/d' "$conf"
    sed -i '/^archive_command\s*=/d' "$conf"
    sed -i '/^listen_addresses\s*=/d' "$conf"
    sed -i '/^#listen_addresses\s*=/d' "$conf"

    # 确保 listen 可远程
    if grep -q "^#listen_addresses = 'localhost'" "$conf"; then
        sed -i "s/^#listen_addresses = 'localhost'/listen_addresses = '*'/" "$conf"
    fi

    cat >> "$conf" << EOF

# ===== Replication (setup_pgsql_replication) =====
listen_addresses = '*'
wal_level = replica
max_wal_senders = 10
wal_keep_size = 1GB
hot_standby = on
synchronous_commit = $SYNCHRONOUS
archive_mode = on
archive_command = 'cp %p $PG_DATA_DIR/archive/%f'
EOF

    mkdir -p "$PG_DATA_DIR/archive"
    chown -R "$PG_OS_USER:$(id -gn "$PG_OS_USER")" "$PG_DATA_DIR/archive"
    success "postgresql.conf 完成"

    # pg_hba.conf
    info "配置 pg_hba.conf ..."
    local hba="$PG_DATA_DIR/pg_hba.conf"
    sed -i '/^# Replication access/d' "$hba"
    sed -i "/host[[:space:]]\+replication[[:space:]]\+$PG_REPL_USER/d" "$hba"
    # 业务/复制允许网段（默认 0.0.0.0/0，生产请收紧）
    if ! grep -q "host.*replication.*$PG_REPL_USER" "$hba"; then
        {
            echo ""
            echo "# Replication access"
            echo "host    replication     $PG_REPL_USER     0.0.0.0/0               scram-sha-256"
            echo "host    all             $PG_REPL_USER     0.0.0.0/0               scram-sha-256"
        } >> "$hba"
    fi
    if [ "$CREATE_APP_USER" = "yes" ] && ! grep -q "host.*$APP_DB_NAME.*$APP_DB_USER" "$hba"; then
        echo "host    $APP_DB_NAME    $APP_DB_USER     0.0.0.0/0               scram-sha-256" >> "$hba"
    fi
    success "pg_hba.conf 完成"

    # 重启生效
    info "重启 PostgreSQL..."
    local service_name
    service_name=$(find_pg_service_name)
    if [ -n "$service_name" ]; then
        systemctl restart "$service_name"
    else
        sudo -u "$PG_OS_USER" "$PG_INSTALL_DIR/bin/pg_ctl" -D "$PG_DATA_DIR" restart -m fast
    fi
    sleep 3
    ensure_pg_running || return 1

    # 创建复制用户
    info "创建/更新复制账号 $PG_REPL_USER ..."
    psql_exec "DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='$PG_REPL_USER') THEN
    CREATE ROLE $PG_REPL_USER WITH LOGIN REPLICATION ENCRYPTED PASSWORD '$PG_REPL_PASSWORD';
  ELSE
    ALTER ROLE $PG_REPL_USER WITH LOGIN REPLICATION ENCRYPTED PASSWORD '$PG_REPL_PASSWORD';
  END IF;
END \$\$;" || warn "复制账号创建可能失败，请手动检查"

    # 业务库与账号
    if [ "$CREATE_APP_USER" = "yes" ]; then
        info "创建业务库 $APP_DB_NAME 与账号 $APP_DB_USER ..."
        psql_exec "SELECT 1 FROM pg_database WHERE datname='$APP_DB_NAME'" | grep -q 1 || \
            psql_exec "CREATE DATABASE $APP_DB_NAME OWNER $PG_OS_USER;"
        psql_exec "DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='$APP_DB_USER') THEN
    CREATE ROLE $APP_DB_USER WITH LOGIN ENCRYPTED PASSWORD '$APP_DB_PASSWORD';
  ELSE
    ALTER ROLE $APP_DB_USER WITH LOGIN ENCRYPTED PASSWORD '$APP_DB_PASSWORD';
  END IF;
END \$\$;"
        psql_exec "ALTER DATABASE $APP_DB_NAME OWNER TO $APP_DB_USER;"
        psql_exec "GRANT ALL PRIVILEGES ON DATABASE $APP_DB_NAME TO $APP_DB_USER;"
        # PG15+ 需要 schema 权限
        psql_exec "GRANT ALL ON SCHEMA public TO $APP_DB_USER;" "$APP_DB_NAME" 2>/dev/null || true
        success "业务账号配置完成"
    fi

    # 设置超级用户密码
    psql_exec "ALTER USER $PG_OS_USER WITH ENCRYPTED PASSWORD '$PG_SUPER_PASSWORD';" || true

    REPLICATION_ROLE="primary"
    save_config "primary"

    echo ""
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}PostgreSQL 主库配置完成!${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo -e "  主库IP:   ${GREEN}$PRIMARY_HOST${NC}"
    echo -e "  端口:     ${GREEN}$PG_PORT${NC}"
    echo -e "  复制账号: ${GREEN}$PG_REPL_USER / $PG_REPL_PASSWORD${NC}"
    if [ "$CREATE_APP_USER" = "yes" ]; then
        echo -e "  业务库:   ${GREEN}$APP_DB_NAME${NC}"
        echo -e "  业务账号: ${GREEN}$APP_DB_USER / $APP_DB_PASSWORD${NC}"
    fi
    echo ""
    echo -e "${CYAN}测试复制账号:${NC}"
    echo "  PGPASSWORD='$PG_REPL_PASSWORD' psql -h $PRIMARY_HOST -p $PG_PORT -U $PG_REPL_USER -d postgres -c 'SELECT 1'"
    echo ""
    return 0
}

# ======================== 配置本机从库 ========================

configure_replica_local() {
    print_title "配置PostgreSQL从库（本机）"

    if ! detect_postgresql_installation; then
        echo "1. 先安装 PostgreSQL"
        echo "2. 退出"
        read -p "请选择 [1/2]: " choice
        [ "$choice" = "1" ] || return 1
        call_install_script || return 1
    fi

    echo -e "${CYAN}主库信息:${NC}"
    read -p "主库IP: " PRIMARY_HOST
    [ -z "$PRIMARY_HOST" ] && { echo -e "${RED}主库IP不能为空${NC}"; return 1; }
    read -p "主库端口 [$PRIMARY_PORT]: " input; PRIMARY_PORT=${input:-$PRIMARY_PORT}
    read -p "复制用户名 [$PG_REPL_USER]: " input; PG_REPL_USER=${input:-$PG_REPL_USER}
    read -p "复制密码 [$PG_REPL_PASSWORD]: " input; PG_REPL_PASSWORD=${input:-$PG_REPL_PASSWORD}

    echo ""
    read -p "本机端口 [$PG_PORT]: " input; PG_PORT=${input:-$PG_PORT}
    read -p "OS用户 [$PG_OS_USER]: " input; PG_OS_USER=${input:-$PG_OS_USER}

    echo ""
    echo "数据初始化方式:"
    echo "1. pg_basebackup 从主库复制（推荐）"
    echo "2. 使用已有数据目录（仅配置 standby）"
    read -p "请选择 [1/2]: " data_mode

    local replica_data_dir="$PG_DATA_DIR"

    if [ "$data_mode" = "1" ]; then
        read -p "从库数据目录 [$PG_DATA_DIR]: " input; replica_data_dir=${input:-$PG_DATA_DIR}

        if [ -d "$replica_data_dir" ] && [ "$(ls -A "$replica_data_dir" 2>/dev/null)" ]; then
            warn "数据目录非空: $replica_data_dir"
            echo "1. 备份后清空重建"
            echo "2. 直接清空"
            echo "3. 取消"
            read -p "请选择 [1/2/3]: " dir_choice
            case $dir_choice in
                1) mv "$replica_data_dir" "${replica_data_dir}_backup_$(date +%Y%m%d_%H%M%S)"; mkdir -p "$replica_data_dir" ;;
                2) rm -rf "${replica_data_dir:?}/"* ;;
                *) return 1 ;;
            esac
        fi

        mkdir -p "$replica_data_dir"
        chown -R "$PG_OS_USER:$(id -gn "$PG_OS_USER")" "$replica_data_dir"

        confirm_action "开始 pg_basebackup（耗时取决于数据量）?" || return 1

        local service_name
        service_name=$(find_pg_service_name)
        [ -n "$service_name" ] && systemctl stop "$service_name" 2>/dev/null

        info "执行 pg_basebackup ..."
        export PGPASSWORD="$PG_REPL_PASSWORD"
        if ! sudo -u "$PG_OS_USER" "$PG_INSTALL_DIR/bin/pg_basebackup" \
            -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U "$PG_REPL_USER" \
            -D "$replica_data_dir" -Fp -Xs -P -R; then
            unset PGPASSWORD
            echo -e "${RED}pg_basebackup 失败${NC}"
            echo "排查: 主库地址/端口/复制账号/pg_hba/网络"
            return 1
        fi
        unset PGPASSWORD
        success "基础备份完成"
        PG_DATA_DIR="$replica_data_dir"
    else
        read -p "已有数据目录: " replica_data_dir
        [ -d "$replica_data_dir" ] || { echo -e "${RED}目录不存在${NC}"; return 1; }
        PG_DATA_DIR="$replica_data_dir"
    fi

    # 端口与 hot_standby
    local conf="$PG_DATA_DIR/postgresql.conf"
    if grep -qE "^#?port\s*=" "$conf"; then
        sed -i "s/^#\?port\s*=.*/port = $PG_PORT/" "$conf"
    else
        echo "port = $PG_PORT" >> "$conf"
    fi
    if grep -qE "^#?hot_standby\s*=" "$conf"; then
        sed -i "s/^#\?hot_standby\s*=.*/hot_standby = on/" "$conf"
    else
        echo "hot_standby = on" >> "$conf"
    fi
    if grep -qE "^#?listen_addresses\s*=" "$conf"; then
        sed -i "s/^#\?listen_addresses\s*=.*/listen_addresses = '*'/" "$conf"
    else
        echo "listen_addresses = '*'" >> "$conf"
    fi

    # primary_conninfo（-R 已写 standby.signal；无则补）
    [ -f "$PG_DATA_DIR/standby.signal" ] || touch "$PG_DATA_DIR/standby.signal"
    if grep -qE "^primary_conninfo\s*=" "$conf"; then
        sed -i "s|^primary_conninfo\s*=.*|primary_conninfo = 'host=$PRIMARY_HOST port=$PRIMARY_PORT user=$PG_REPL_USER password=$PG_REPL_PASSWORD'|" "$conf"
    else
        echo "primary_conninfo = 'host=$PRIMARY_HOST port=$PRIMARY_PORT user=$PG_REPL_USER password=$PG_REPL_PASSWORD'" >> "$conf"
    fi

    local hba="$PG_DATA_DIR/pg_hba.conf"
    grep -q "host.*all.*all.*0.0.0.0/0" "$hba" 2>/dev/null || \
        echo "host    all             all             0.0.0.0/0               scram-sha-256" >> "$hba"

    chown -R "$PG_OS_USER:$(id -gn "$PG_OS_USER")" "$PG_DATA_DIR"

    info "启动从库..."
    local service_name
    service_name=$(find_pg_service_name)
    if [ -n "$service_name" ]; then
        systemctl start "$service_name"
    else
        sudo -u "$PG_OS_USER" "$PG_INSTALL_DIR/bin/pg_ctl" -D "$PG_DATA_DIR" -l "$PG_DATA_DIR/logfile" start
    fi
    sleep 3

    REPLICATION_ROLE="replica"
    save_config "replica"
    check_replication_status
    return 0
}

# ======================== SSH 一键部署 ========================

collect_ssh_info() {
    print_title "SSH 远程连接信息"
    read -p "SSH 用户名 [root]: " input; SSH_USER=${input:-root}
    read -p "SSH 端口 [22]: " input; SSH_PORT=${input:-22}
    echo "认证方式: 1) SSH密码  2) SSH私钥"
    read -p "请选择 [1/2]: " auth_choice
    case "$auth_choice" in
        2)
            read -p "私钥路径 [~/.ssh/id_rsa]: " input
            SSH_KEY=${input:-$HOME/.ssh/id_rsa}
            SSH_KEY="${SSH_KEY/#\~/$HOME}"
            SSH_PASSWORD=""
            ;;
        *)
            read -s -p "SSH 密码: " SSH_PASSWORD; echo ""
            SSH_KEY=""
            ;;
    esac
    ensure_ssh_tools || return 1
}

collect_replica_list() {
    print_title "添加远程从库（可多台，IP 留空结束）"
    REPLICA_NODES=()
    local idx=1
    while true; do
        read -p "从库 #${idx} IP/主机名 (空结束): " host
        [ -z "$host" ] && break
        local sport="$SSH_PORT" suser="$SSH_USER" spass="$SSH_PASSWORD" rport="$PG_PORT" custom
        read -p "  SSH端口 [$SSH_PORT]: " custom; sport=${custom:-$sport}
        read -p "  SSH用户 [$SSH_USER]: " custom; suser=${custom:-$suser}
        if [ -n "$SSH_PASSWORD" ]; then
            read -p "  使用全局SSH密码? [Y/n]: " ug
            if [[ "$ug" =~ ^[Nn]$ ]]; then
                read -s -p "  SSH密码: " spass; echo ""
            fi
        else
            read -p "  使用全局SSH密钥? [Y/n]: " ug
            if [[ "$ug" =~ ^[Nn]$ ]]; then
                read -s -p "  SSH密码: " spass; echo ""
            else
                spass=""
            fi
        fi
        read -p "  PostgreSQL端口 [$PG_PORT]: " custom; rport=${custom:-$rport}
        REPLICA_NODES+=("${host}|${sport}|${suser}|${spass}|${rport}")
        success "已添加: $host (ssh $suser@$host:$sport pg=$rport)"
        idx=$((idx+1))
    done
    [ ${#REPLICA_NODES[@]} -eq 0 ] && { warn "未添加从库"; return 1; }
    return 0
}

save_cluster_hosts() {
    {
        echo "# PG cluster hosts - $(date)"
        echo "PRIMARY_HOST=$PRIMARY_HOST"
        echo "PRIMARY_PORT=$PG_PORT"
        echo "PG_REPL_USER=$PG_REPL_USER"
        echo "PG_REPL_PASSWORD=$PG_REPL_PASSWORD"
        echo "PG_SUPER_PASSWORD=$PG_SUPER_PASSWORD"
        echo "PG_INSTALL_DIR=$PG_INSTALL_DIR"
        echo "PG_DATA_DIR=$PG_DATA_DIR"
        echo "PG_OS_USER=$PG_OS_USER"
        echo "PG_VERSION=$PG_VERSION"
        echo "CREATE_APP_USER=$CREATE_APP_USER"
        echo "APP_DB_NAME=$APP_DB_NAME"
        echo "APP_DB_USER=$APP_DB_USER"
        echo "APP_DB_PASSWORD=$APP_DB_PASSWORD"
        echo "REPLICA_NODES_STR=${REPLICA_NODES[*]}"
        echo "SSH_USER=$SSH_USER"
        echo "SSH_PORT=$SSH_PORT"
        echo "SSH_KEY=$SSH_KEY"
    } > "$CLUSTER_STATE_FILE"
    chmod 600 "$CLUSTER_STATE_FILE"
    success "集群节点信息: $CLUSTER_STATE_FILE"
}

remote_setup_replica() {
    local host="$1" sport="$2" suser="$3" spass="$4" rport="$5"

    print_title "远程配置从库 → ${host}:${rport}"

    local old_port="$SSH_PORT" old_user="$SSH_USER" old_pass="$SSH_PASSWORD"
    with_node_ssh "$host" "$sport" "$suser" "$spass"

    ssh_cmd "$host" "echo SSH_OK && command -v systemctl >/dev/null && echo HAS_SYSTEMD=1" || {
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"; return 1
    }

    # 探测远程 PG
    local remote_pg remote_data remote_ver
    remote_pg=$(ssh_cmd "$host" "ls -d /mnt/data/postgresql/*/bin/psql /usr/local/pgsql/bin/psql /usr/local/postgresql/bin/psql /usr/pgsql-*/bin/psql 2>/dev/null | head -1 | sed 's|/bin/psql||'")
    if [ -z "$remote_pg" ]; then
        remote_pg=$(ssh_cmd "$host" "command -v psql >/dev/null && dirname \$(dirname \$(command -v psql)) || true")
    fi

    if [ -z "$remote_pg" ] || ! ssh_cmd "$host" "test -x '$remote_pg/bin/psql'"; then
        warn "远程未检测到 PostgreSQL"
        echo "1. 上传并调用 install_postgresql.sh（交互，需你在远程完成）"
        echo "2. 跳过该节点"
        read -p "请选择 [1/2]: " ch
        if [ "$ch" = "1" ]; then
            ssh_cmd "$host" "mkdir -p /tmp/pg_repl_install" || true
            scp_to_remote "$INSTALL_SCRIPT" "$host" "/tmp/pg_repl_install/install_postgresql.sh" || true
            info "请在远程完成安装后重新执行本节点配置"
            info "远程执行: bash /tmp/pg_repl_install/install_postgresql.sh"
            SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
            return 1
        fi
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 1
    fi

    remote_data=$(ssh_cmd "$host" "if [ -d '$remote_pg/data' ]; then echo '$remote_pg/data'; else ls -d $(dirname '$remote_pg')/data 2>/dev/null | head -1; fi")
    remote_ver=$(ssh_cmd "$host" "'$remote_pg/bin/psql' --version 2>/dev/null | grep -oE '[0-9]+\\.[0-9]+' | head -1")

    info "远程 PG: $remote_pg v${remote_ver:-?} data=${remote_data:-?}"

    # 停服务、pg_basebackup
    info "停止远程 PG 并执行 pg_basebackup ..."
    ssh_cmd "$host" "systemctl stop postgresql* 2>/dev/null; pkill -u postgres 2>/dev/null; true"

    # 数据目录处理
    local remote_home
    remote_home=$(dirname "$remote_pg")
    local target_data="${remote_data:-$remote_home/data}"

    ssh_cmd "$host" "bash -s" << REMOTE
set -e
PGUSER=postgres
if id "\$PGUSER" >/dev/null 2>&1; then :; else useradd -r -m -s /bin/bash \$PGUSER; fi
if [ -d "$target_data" ] && [ "\$(ls -A $target_data 2>/dev/null)" ]; then
  mv "$target_data" "${target_data}_backup_\$(date +%Y%m%d_%H%M%S)"
fi
mkdir -p "$target_data"
chown -R \$PGUSER:\$PGUSER "$target_data"
REMOTE

    local remote_basebackup
    remote_basebackup="PGPASSWORD='$PG_REPL_PASSWORD' sudo -u postgres '$remote_pg/bin/pg_basebackup' -h '$PRIMARY_HOST' -p '$PG_PORT' -U '$PG_REPL_USER' -D '$target_data' -Fp -Xs -P -R"
    if ! ssh_cmd "$host" "$remote_basebackup"; then
        warn "远程 pg_basebackup 失败"
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 1
    fi
    success "远程数据同步完成"

    # 写从库配置
    info "写入远程从库配置..."
    ssh_cmd "$host" "bash -s" << REMOTE
set -e
CONF="$target_data/postgresql.conf"
HBA="$target_data/pg_hba.conf"

# port
if grep -qE '^#?port\s*=' "\$CONF"; then
  sed -i "s/^#\?port\s*=.*/port = $rport/" "\$CONF"
else
  echo "port = $rport" >> "\$CONF"
fi
# listen
if grep -qE '^#?listen_addresses\s*=' "\$CONF"; then
  sed -i "s/^#\?listen_addresses\s*=.*/listen_addresses = '*'/" "\$CONF"
else
  echo "listen_addresses = '*'" >> "\$CONF"
fi
# hot_standby
if grep -qE '^#?hot_standby\s*=' "\$CONF"; then
  sed -i "s/^#\?hot_standby\s*=.*/hot_standby = on/" "\$CONF"
else
  echo "hot_standby = on" >> "\$CONF"
fi
# primary_conninfo
if grep -qE '^primary_conninfo\s*=' "\$CONF"; then
  sed -i "s|^primary_conninfo\s*=.*|primary_conninfo = 'host=$PRIMARY_HOST port=$PG_PORT user=$PG_REPL_USER password=$PG_REPL_PASSWORD'|" "\$CONF"
else
  echo "primary_conninfo = 'host=$PRIMARY_HOST port=$PG_PORT user=$PG_REPL_USER password=$PG_REPL_PASSWORD'" >> "\$CONF"
fi

touch "$target_data/standby.signal"
grep -q 'host.*all.*all.*0.0.0.0/0' "\$HBA" 2>/dev/null || echo "host    all             all             0.0.0.0/0               scram-sha-256" >> "\$HBA"
chown -R postgres:postgres "$target_data"

# systemd 或 pg_ctl 启动
if systemctl list-units --all --type=service 2>/dev/null | grep -q postgresql; then
  systemctl start postgresql 2>/dev/null || systemctl start postgresql* 2>/dev/null || true
fi
if ! sudo -u postgres '$remote_pg/bin/pg_ctl' -D '$target_data' status >/dev/null 2>&1; then
  sudo -u postgres '$remote_pg/bin/pg_ctl' -D '$target_data' -l '$target_data/standby.log' start
fi
sleep 2
sudo -u postgres '$remote_pg/bin/psql' -p $rport -t -A -c 'SELECT pg_is_in_recovery();'
REMOTE

    if [ $? -eq 0 ]; then
        success "远程从库 ${host}:${rport} 配置完成"
        SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        return 0
    fi
    warn "远程从库启动/验证可能失败，请登录检查"
    SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
    return 1
}

one_click_deploy() {
    print_title "一键 PostgreSQL 主从部署（本机主库 + SSH远程从库）"

    echo -e "${CYAN}流程:${NC}"
    echo "  1. 本机配置 Primary（复制账号 + 可选业务库 scpdata）"
    echo "  2. SSH 到从库执行 pg_basebackup"
    echo "  3. 写入 standby 配置并启动"
    echo "  4. 校验 pg_is_in_recovery / 延迟"
    echo ""
    confirm_action "开始一键部署?" || return 1

    collect_ssh_info || return 1
    collect_replica_list || return 1

    # 本机主库
    echo ""
    info "===== 步骤 A: 本机主库 ====="
    if detect_postgresql_installation; then
        read -p "本机已有 PostgreSQL，是否直接配置为 Primary? [Y/n]: " c
        if [[ ! "$c" =~ ^[Nn]$ ]]; then
            configure_primary || return 1
        fi
    else
        echo "1. 交互式安装后再配置主库"
        read -p "请选择 [1]: " ch
        call_install_script || return 1
        configure_primary || return 1
    fi

    # 远程从库
    local failed=0 idx=1
    for item in "${REPLICA_NODES[@]}"; do
        IFS='|' read -r h p u pw rp <<< "$item"
        echo ""
        info "===== 步骤 B.${idx}: 从库 ${h} ====="
        remote_setup_replica "$h" "$p" "$u" "$pw" "$rp" || failed=$((failed+1))
        idx=$((idx+1))
    done

    save_cluster_hosts

    echo ""
    print_title "一键部署结果"
    info "主库: ${PRIMARY_HOST}:${PG_PORT}"
    info "从库数: ${#REPLICA_NODES[@]}  失败: $failed"
    info "复制账号: $PG_REPL_USER"
    [ "$CREATE_APP_USER" = "yes" ] && info "业务库: $APP_DB_NAME / $APP_DB_USER"
    echo ""
    info "后续: bash $0 status"
    echo ""
    check_replication_status
    return 0
}

# ======================== 状态 ========================

check_replication_status() {
    print_title "检查PostgreSQL复制状态"

    if [ -f "$CLUSTER_STATE_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CLUSTER_STATE_FILE"
    fi
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

    detect_postgresql_installation || return 1

    local is_recovery
    is_recovery=$(psql_exec "SELECT pg_is_in_recovery();")
    echo -e "${CYAN}当前角色:${NC}"
    if [ "$is_recovery" = "t" ]; then
        echo -e "  ${GREEN}从库 (Replica)${NC}"
        local lag recv replay
        lag=$(psql_exec "SELECT CASE WHEN pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn() THEN 0 ELSE COALESCE(EXTRACT(EPOCH FROM now() - pg_last_xact_replay_timestamp())::int,0) END;")
        recv=$(psql_exec "SELECT pg_last_wal_receive_lsn();")
        replay=$(psql_exec "SELECT pg_last_wal_replay_lsn();")
        echo -e "  延迟: ${lag:-0} 秒"
        echo -e "  接收LSN: $recv"
        echo -e "  重放LSN: $replay"
        psql_exec "SHOW primary_conninfo;" | sed 's/^/  conninfo: /'
    else
        echo -e "  ${CYAN}主库 (Primary)${NC}"
        echo ""
        echo -e "${CYAN}已连接从库:${NC}"
        local replicas
        replicas=$(sudo -u "$PG_OS_USER" "${PG_INSTALL_DIR:-/usr}/bin/psql" -p "$PG_PORT" -c "SELECT client_addr, state, sync_state, sent_lsn, replay_lsn FROM pg_stat_replication;" 2>/dev/null)
        if [ -n "$replicas" ] && ! echo "$replicas" | grep -q "(0 rows)"; then
            echo "$replicas"
        else
            echo -e "  ${YELLOW}暂无从库连接${NC}"
        fi
        # 业务库
        if [ "$CREATE_APP_USER" = "yes" ] || [ -n "$APP_DB_NAME" ]; then
            echo ""
            echo -e "${CYAN}业务库检查:${NC}"
            local appdb
            appdb=$(psql_exec "SELECT datname FROM pg_database WHERE datname='${APP_DB_NAME:-scpdata}';")
            echo "  ${APP_DB_NAME:-scpdata}: ${appdb:-不存在}"
        fi
    fi

    # 远程从库状态
    if [ ${#REPLICA_NODES[@]} -gt 0 ]; then
        echo ""
        echo -e "${CYAN}远程从库:${NC}"
        for item in "${REPLICA_NODES[@]}"; do
            IFS='|' read -r h p u pw rp <<< "$item"
            local old_port="$SSH_PORT" old_user="$SSH_USER" old_pass="$SSH_PASSWORD"
            with_node_ssh "$h" "$p" "$u" "$pw"
            echo -n "  $h:$rp → "
            local st
            st=$(ssh_cmd "$h" "pgrep -u postgres >/dev/null && echo running || echo down")
            echo "$st"
            ssh_cmd "$h" "sudo -u postgres psql -p $rp -t -A -c \"SELECT pg_is_in_recovery();\" 2>/dev/null" | sed 's/^/    recovery=/'
            SSH_PORT="$old_port"; SSH_USER="$old_user"; SSH_PASSWORD="$old_pass"
        done
    fi
    return 0
}

# ======================== 重置 ========================

reset_replication() {
    print_title "重置本机复制配置"
    detect_postgresql_installation || return 1
    confirm_action "将停止服务、删除 standby.signal 并清理复制参数，确认?" || return 1

    local service_name
    service_name=$(find_pg_service_name)
    [ -n "$service_name" ] && systemctl stop "$service_name"
    [ -x "$PG_INSTALL_DIR/bin/pg_ctl" ] && sudo -u "$PG_OS_USER" "$PG_INSTALL_DIR/bin/pg_ctl" -D "$PG_DATA_DIR" stop 2>/dev/null

    rm -f "$PG_DATA_DIR/standby.signal"
    local conf="$PG_DATA_DIR/postgresql.conf"
    if [ -f "$conf" ]; then
        sed -i '/^# ===== Replication (setup_pgsql_replication)/d' "$conf"
        sed -i '/^primary_conninfo/d' "$conf"
        sed -i '/^wal_level\s*=/d' "$conf"
        sed -i '/^max_wal_senders\s*=/d' "$conf"
        sed -i '/^wal_keep_size\s*=/d' "$conf"
        sed -i '/^archive_mode\s*=/d' "$conf"
        sed -i '/^archive_command\s*=/d' "$conf"
    fi
    local hba="$PG_DATA_DIR/pg_hba.conf"
    [ -f "$hba" ] && sed -i '/^# Replication access/d;/host.*replication/d' "$hba"
    rm -f "$CONFIG_FILE" "$CLUSTER_STATE_FILE"
    success "已重置（请手动启动服务）"
}

# ======================== 配置保存 ========================

save_config() {
    local role="$1"
    cat > "$CONFIG_FILE" << EOF
# PostgreSQL Replication Configuration
# Generated: $(date)

REPLICATION_ROLE=$role
PG_INSTALL_DIR=$PG_INSTALL_DIR
PG_DATA_DIR=$PG_DATA_DIR
PG_PORT=$PG_PORT
PG_OS_USER=$PG_OS_USER
PG_SUPER_PASSWORD=$PG_SUPER_PASSWORD
PG_VERSION=$PG_VERSION
PRIMARY_HOST=$PRIMARY_HOST
PRIMARY_PORT=$PRIMARY_PORT
PG_REPL_USER=$PG_REPL_USER
PG_REPL_PASSWORD=$PG_REPL_PASSWORD
CREATE_APP_USER=$CREATE_APP_USER
APP_DB_NAME=$APP_DB_NAME
APP_DB_USER=$APP_DB_USER
APP_DB_PASSWORD=$APP_DB_PASSWORD
SYNCHRONOUS=$SYNCHRONOUS
EOF
    chmod 600 "$CONFIG_FILE"
    success "配置已保存: $CONFIG_FILE"
}

# ======================== 帮助/菜单 ========================

show_help() {
    print_title "PostgreSQL 流复制配置脚本"
    echo "用法: bash setup_pgsql_replication.sh [命令]"
    echo ""
    echo "命令:"
    echo "  one       一键部署：本机Primary + SSH远程Replica"
    echo "  primary   仅配置本机为主库"
    echo "  replica   仅配置本机为从库"
    echo "  status    检查复制状态"
    echo "  reset     重置复制配置"
    echo "  install   安装 PostgreSQL"
    echo "  help      帮助"
    echo ""
    echo "说明:"
    echo "  - 主库会创建复制账号（默认 repl）"
    echo "  - 可选创建业务库/账号（如 scpdata）"
    echo "  - 从库使用 pg_basebackup 初始化并写 standby.signal"
    echo "  - 一键模式需 SSH 可登从库 root（密钥或 sshpass）"
    echo "  - 从库需已安装 PostgreSQL 二进制"
}

show_main_menu() {
    print_title "PostgreSQL 流复制配置工具"
    echo -e "${CYAN}本机IP: $(get_local_ip)${NC}"
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        echo -e "${CYAN}已有配置角色: ${REPLICATION_ROLE:-未知}${NC}"
    fi
    echo ""
    echo "请选择操作:"
    echo ""
    echo -e "  ${GREEN}1. 一键主从部署${NC}（本机Primary + SSH远程从库）"
    echo "  2. 配置本机为主库"
    echo "  3. 配置本机为从库"
    echo "  4. 检查复制状态"
    echo "  5. 重置复制配置"
    echo "  6. 安装 PostgreSQL"
    echo "  7. 帮助"
    echo "  q. 退出"
    echo ""
    read -p "请选择 [1-7/q]: " main_choice
    case $main_choice in
        1) one_click_deploy ;;
        2) configure_primary ;;
        3) configure_replica_local ;;
        4) check_replication_status ;;
        5) reset_replication ;;
        6) call_install_script ;;
        7) show_help ;;
        q|Q) echo -e "${GREEN}退出${NC}"; exit 0 ;;
        *) echo -e "${RED}无效选择${NC}" ;;
    esac
}

main() {
    if [ $# -gt 0 ]; then
        case "$1" in
            one|deploy|cluster) one_click_deploy ;;
            primary|master) configure_primary ;;
            replica|slave) configure_replica_local ;;
            status) check_replication_status ;;
            reset) reset_replication ;;
            install) call_install_script ;;
            help|-h|--help) show_help ;;
            *)
                echo -e "${RED}未知参数: $1${NC}"
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
