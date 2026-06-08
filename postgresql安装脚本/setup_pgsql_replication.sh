#!/bin/bash

# PostgreSQL 流复制配置脚本
# 支持配置主库(Primary)和从库(Replica)，可自动调用安装脚本
# 兼容 Ubuntu 22/24、Debian 12、CentOS Stream/Rocky/AlmaLinux 8/9

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 检查是否使用bash执行
if [ -z "$BASH_VERSION" ]; then
    echo "错误: 请使用bash执行此脚本，而不是sh"
    echo "正确用法: bash setup_pgsql_replication.sh 或 ./setup_pgsql_replication.sh"
    exit 1
fi

# 检查是否为root用户
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}此脚本需要以root权限运行${NC}"
   exit 1
fi

# ======================== 全局变量 ========================

# 脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="$SCRIPT_DIR/install_postgresql.sh"

# PostgreSQL配置
PG_INSTALL_DIR=""
PG_DATA_DIR=""
PG_PORT="5432"
PG_USER="postgres"
PG_PASSWORD="postgres"
PG_REPL_USER="repl"
PG_REPL_PASSWORD="repl_password"
PG_VERSION=""

# 主从配置
REPLICATION_ROLE=""  # primary 或 replica
PRIMARY_HOST=""
PRIMARY_PORT="5432"

# 配置文件路径
CONFIG_FILE="/etc/pgsql_replication.conf"

# ======================== 工具函数 ========================

# 打印分隔线
print_separator() {
    echo -e "${CYAN}========================================${NC}"
}

# 打印标题
print_title() {
    local title="$1"
    echo ""
    print_separator
    echo -e "${GREEN}$title${NC}"
    print_separator
    echo ""
}

# 确认操作
confirm_action() {
    local message="$1"
    echo -e "${YELLOW}$message${NC}"
    read -p "是否继续? [y/N]: " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}操作已取消${NC}"
        return 1
    fi
    return 0
}

# 检查服务状态
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

# 查找PostgreSQL服务名
find_pg_service_name() {
    local service_name=""
    local version_short="${PG_VERSION%.*}"
    
    # 尝试常见的服务名
    local possible_names=(
        "postgresql${version_short}"
        "postgresql-${version_short}"
        "postgresql@${version_short}-main"
        "postgresql"
    )
    
    for name in "${possible_names[@]}"; do
        if systemctl list-units --all --type=service --no-legend 2>/dev/null | grep -q "^${name}.service"; then
            service_name="$name"
            break
        fi
    done
    
    echo "$service_name"
}

# ======================== 检测PostgreSQL安装 ========================

detect_postgresql_installation() {
    echo -e "${YELLOW}检测PostgreSQL安装...${NC}"
    
    # 常见的PostgreSQL安装路径
    local pg_paths=(
        "/mnt/data/postgresql"
        "/usr/local/pgsql"
        "/usr/local/postgresql"
        "/opt/pgsql"
        "/opt/postgresql"
        "/var/lib/pgsql"
    )
    
    # 从环境变量中读取
    if [ -n "$PGHOME" ]; then
        pg_paths=("$PGHOME" "${pg_paths[@]}")
    fi
    
    # 查找PostgreSQL安装
    for path in "${pg_paths[@]}"; do
        if [ -d "$path" ] && [ -f "$path/bin/psql" ]; then
            PG_INSTALL_DIR="$path"
            echo -e "${GREEN}找到PostgreSQL安装: $PG_INSTALL_DIR${NC}"
            
            # 获取版本信息
            PG_VERSION=$($PG_INSTALL_DIR/bin/psql --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+')
            echo -e "${GREEN}PostgreSQL版本: $PG_VERSION${NC}"
            
            # 获取数据目录
            if [ -n "$PGDATA" ]; then
                PG_DATA_DIR="$PGDATA"
            else
                PG_DATA_DIR="$path/data"
            fi
            
            PG_PORT=$(grep "^port" "$PG_DATA_DIR/postgresql.conf" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | xargs)
            PG_PORT=${PG_PORT:-5432}
            
            return 0
        fi
    done
    
    # 尝试使用which命令
    if command -v psql &>/dev/null; then
        local psql_path=$(which psql)
        PG_INSTALL_DIR=$(dirname $(dirname "$psql_path"))
        PG_VERSION=$($PG_INSTALL_DIR/bin/psql --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+')
        echo -e "${GREEN}找到PostgreSQL: $PG_INSTALL_DIR${NC}"
        return 0
    fi
    
    echo -e "${RED}未找到PostgreSQL安装${NC}"
    return 1
}

# ======================== 调用安装脚本 ========================

call_install_script() {
    print_title "安装PostgreSQL"
    
    if [ ! -f "$INSTALL_SCRIPT" ]; then
        echo -e "${RED}未找到安装脚本: $INSTALL_SCRIPT${NC}"
        return 1
    fi
    
    echo -e "${YELLOW}即将调用PostgreSQL安装脚本...${NC}"
    echo -e "${CYAN}安装脚本路径: $INSTALL_SCRIPT${NC}"
    echo ""
    
    if ! confirm_action "是否继续安装PostgreSQL?"; then
        return 1
    fi
    
    # 执行安装脚本
    bash "$INSTALL_SCRIPT"
    
    # 检查安装结果
    if detect_postgresql_installation; then
        echo -e "${GREEN}✓ PostgreSQL安装成功${NC}"
        return 0
    else
        echo -e "${RED}✗ PostgreSQL安装失败${NC}"
        return 1
    fi
}

# ======================== 配置主库 ========================

configure_primary() {
    print_title "配置PostgreSQL主库 (Primary)"
    
    # 检测PostgreSQL安装
    if ! detect_postgresql_installation; then
        echo -e "${YELLOW}PostgreSQL未安装，是否先安装PostgreSQL?${NC}"
        echo "1. 安装PostgreSQL"
        echo "2. 退出"
        read -p "请选择 [1/2]: " choice
        
        case $choice in
            "1")
                call_install_script
                if [ $? -ne 0 ]; then
                    return 1
                fi
                ;;
            *)
                return 1
                ;;
        esac
    fi
    
    # 查找服务名
    local service_name=$(find_pg_service_name)
    
    # 检查PostgreSQL服务状态
    if [ -n "$service_name" ]; then
        if ! check_service_status "$service_name"; then
            echo -e "${YELLOW}尝试启动PostgreSQL服务...${NC}"
            systemctl start "$service_name"
            sleep 3
            if ! check_service_status "$service_name"; then
                echo -e "${RED}PostgreSQL服务启动失败${NC}"
                return 1
            fi
        fi
    fi
    
    # 获取配置信息
    echo -e "${CYAN}请输入主库配置信息:${NC}"
    echo ""
    
    read -p "PostgreSQL端口 [$PG_PORT]: " input_port
    PG_PORT=${input_port:-$PG_PORT}
    
    read -p "PostgreSQL用户 [$PG_USER]: " input_user
    PG_USER=${input_user:-$PG_USER}
    
    read -p "PostgreSQL密码 [$PG_PASSWORD]: " input_password
    PG_PASSWORD=${input_password:-$PG_PASSWORD}
    
    # 复制用户配置
    echo ""
    echo -e "${CYAN}配置复制用户:${NC}"
    read -p "复制用户名 [$PG_REPL_USER]: " input_repl_user
    PG_REPL_USER=${input_repl_user:-$PG_REPL_USER}
    
    read -p "复制用户密码 [$PG_REPL_PASSWORD]: " input_repl_pass
    PG_REPL_PASSWORD=${input_repl_pass:-$PG_REPL_PASSWORD}
    
    # 确认配置
    echo ""
    echo -e "${CYAN}主库配置信息:${NC}"
    echo "  数据目录: $PG_DATA_DIR"
    echo "  端口: $PG_PORT"
    echo "  PostgreSQL用户: $PG_USER"
    echo "  复制用户: $PG_REPL_USER"
    echo ""
    
    if ! confirm_action "确认以上配置?"; then
        return 1
    fi
    
    # 备份配置文件
    echo -e "${YELLOW}备份PostgreSQL配置文件...${NC}"
    cp "$PG_DATA_DIR/postgresql.conf" "$PG_DATA_DIR/postgresql.conf.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$PG_DATA_DIR/pg_hba.conf" "$PG_DATA_DIR/pg_hba.conf.backup.$(date +%Y%m%d_%H%M%S)"
    echo -e "${GREEN}✓ 配置文件已备份${NC}"
    
    # 配置postgresql.conf
    echo -e "${YELLOW}配置postgresql.conf...${NC}"
    
    local conf_file="$PG_DATA_DIR/postgresql.conf"
    
    # 移除旧的复制相关配置
    sed -i '/^# Replication Configuration/d' "$conf_file"
    sed -i '/^wal_level/d' "$conf_file"
    sed -i '/^max_wal_senders/d' "$conf_file"
    sed -i '/^wal_keep_size/d' "$conf_file"
    sed -i '/^hot_standby/d' "$conf_file"
    sed -i '/^synchronous_commit/d' "$conf_file"
    sed -i '/^archive_mode/d' "$conf_file"
    sed -i '/^archive_command/d' "$conf_file"
    
    # 添加主库配置
    cat >> "$conf_file" << EOF

# Replication Configuration
wal_level = replica
max_wal_senders = 10
wal_keep_size = 1GB
hot_standby = on
synchronous_commit = on
archive_mode = on
archive_command = 'cp %p $PG_DATA_DIR/archive/%f'
EOF
    
    # 创建归档目录
    mkdir -p "$PG_DATA_DIR/archive"
    chown -R $PG_USER:$(id -gn $PG_USER) "$PG_DATA_DIR/archive"
    
    echo -e "${GREEN}✓ postgresql.conf配置完成${NC}"
    
    # 配置pg_hba.conf
    echo -e "${YELLOW}配置pg_hba.conf...${NC}"
    
    local hba_file="$PG_DATA_DIR/pg_hba.conf"
    
    # 移除旧的复制相关配置
    sed -i '/^# Replication access/d' "$hba_file"
    sed -i "/^host.*replication.*$PG_REPL_USER/d" "$hba_file"
    
    # 添加复制用户访问权限
    echo "" >> "$hba_file"
    echo "# Replication access" >> "$hba_file"
    echo "host    replication     $PG_REPL_USER     0.0.0.0/0               md5" >> "$hba_file"
    
    echo -e "${GREEN}✓ pg_hba.conf配置完成${NC}"
    
    # 创建复制用户
    echo -e "${YELLOW}创建复制用户...${NC}"
    
    sudo -u $PG_USER $PG_INSTALL_DIR/bin/psql -p $PG_PORT -c "
        CREATE USER $PG_REPL_USER WITH REPLICATION ENCRYPTED PASSWORD '$PG_REPL_PASSWORD';
    " 2>/dev/null
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ 复制用户创建成功${NC}"
    else
        echo -e "${YELLOW}复制用户可能已存在，继续...${NC}"
    fi
    
    # 重启PostgreSQL服务
    echo -e "${YELLOW}重启PostgreSQL服务...${NC}"
    if [ -n "$service_name" ]; then
        systemctl restart "$service_name"
    else
        sudo -u $PG_USER $PG_INSTALL_DIR/bin/pg_ctl restart -D "$PG_DATA_DIR"
    fi
    sleep 3
    
    # 检查服务状态
    if [ -n "$service_name" ]; then
        check_service_status "$service_name"
    fi
    
    echo ""
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}PostgreSQL 主库配置完成!${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo ""
    echo -e "${CYAN}主库信息 (请记录以下信息，配置从库时需要):${NC}"
    echo "  主库IP: $(hostname -I | awk '{print $1}')"
    echo "  端口: $PG_PORT"
    echo "  复制用户: $PG_REPL_USER"
    echo "  复制密码: $PG_REPL_PASSWORD"
    echo "  数据目录: $PG_DATA_DIR"
    echo ""
    echo -e "${CYAN}测试复制用户连接:${NC}"
    echo "  PGPASSWORD='$PG_REPL_PASSWORD' psql -h <主库IP> -p $PG_PORT -U $PG_REPL_USER -d postgres -c 'SELECT 1'"
    echo ""
    
    # 保存配置信息
    save_config "primary"
    
    return 0
}

# ======================== 配置从库 ========================

configure_replica() {
    print_title "配置PostgreSQL从库 (Replica)"
    
    # 检测PostgreSQL安装
    if ! detect_postgresql_installation; then
        echo -e "${YELLOW}PostgreSQL未安装，是否先安装PostgreSQL?${NC}"
        echo "1. 安装PostgreSQL"
        echo "2. 退出"
        read -p "请选择 [1/2]: " choice
        
        case $choice in
            "1")
                call_install_script
                if [ $? -ne 0 ]; then
                    return 1
                fi
                ;;
            *)
                return 1
                ;;
        esac
    fi
    
    # 获取主库信息
    echo -e "${CYAN}请输入主库信息:${NC}"
    echo ""
    
    read -p "主库IP地址: " PRIMARY_HOST
    if [ -z "$PRIMARY_HOST" ]; then
        echo -e "${RED}主库IP地址不能为空${NC}"
        return 1
    fi
    
    read -p "主库端口 [$PRIMARY_PORT]: " input_port
    PRIMARY_PORT=${input_port:-$PRIMARY_PORT}
    
    read -p "复制用户名 [$PG_REPL_USER]: " input_user
    PG_REPL_USER=${input_user:-$PG_REPL_USER}
    
    read -p "复制用户密码 [$PG_REPL_PASSWORD]: " input_pass
    PG_REPL_PASSWORD=${input_pass:-$PG_REPL_PASSWORD}
    
    # 获取从库配置
    echo ""
    echo -e "${CYAN}请输入从库配置:${NC}"
    echo ""
    
    read -p "PostgreSQL端口 [$PG_PORT]: " input_local_port
    PG_PORT=${input_local_port:-$PG_PORT}
    
    read -p "PostgreSQL用户 [$PG_USER]: " input_pg_user
    PG_USER=${input_pg_user:-$PG_USER}
    
    # 数据目录配置
    echo ""
    echo -e "${CYAN}从库数据目录配置:${NC}"
    echo "1. 使用pg_basebackup从主库复制 (推荐)"
    echo "2. 手动指定已存在的数据目录"
    echo ""
    read -p "请选择 [1/2]: " data_mode
    
    local replica_data_dir=""
    
    case $data_mode in
        "1")
            read -p "从库数据目录 [$PG_DATA_DIR]: " input_data_dir
            replica_data_dir=${input_data_dir:-$PG_DATA_DIR}
            
            if [ -d "$replica_data_dir" ] && [ "$(ls -A $replica_data_dir 2>/dev/null)" ]; then
                echo -e "${YELLOW}数据目录已存在且非空${NC}"
                echo "1. 清空后重新复制"
                echo "2. 备份后重新复制"
                echo "3. 取消"
                read -p "请选择 [1/2/3]: " dir_choice
                
                case $dir_choice in
                    "1")
                        rm -rf "$replica_data_dir"/*
                        ;;
                    "2")
                        mv "$replica_data_dir" "${replica_data_dir}_backup_$(date +%Y%m%d_%H%M%S)"
                        mkdir -p "$replica_data_dir"
                        ;;
                    *)
                        return 1
                        ;;
                esac
            fi
            
            # 创建目录
            mkdir -p "$replica_data_dir"
            chown -R $PG_USER:$(id -gn $PG_USER) "$replica_data_dir"
            
            # 确认配置
            echo ""
            echo -e "${CYAN}从库配置信息:${NC}"
            echo "  主库地址: $PRIMARY_HOST:$PRIMARY_PORT"
            echo "  本地端口: $PG_PORT"
            echo "  数据目录: $replica_data_dir"
            echo "  复制用户: $PG_REPL_USER"
            echo ""
            
            if ! confirm_action "确认以上配置?"; then
                return 1
            fi
            
            # 停止PostgreSQL服务
            local service_name=$(find_pg_service_name)
            if [ -n "$service_name" ]; then
                systemctl stop "$service_name" 2>/dev/null
            fi
            
            # 使用pg_basebackup复制数据
            echo -e "${YELLOW}使用pg_basebackup从主库复制数据...${NC}"
            echo -e "${CYAN}这可能需要一些时间，取决于数据量大小${NC}"
            echo ""
            
            sudo -u $PG_USER $PG_INSTALL_DIR/bin/pg_basebackup \
                -h $PRIMARY_HOST \
                -p $PRIMARY_PORT \
                -U $PG_REPL_USER \
                -D $replica_data_dir \
                -Fp -Xs -P -R
            
            if [ $? -ne 0 ]; then
                echo -e "${RED}pg_basebackup执行失败${NC}"
                echo -e "${YELLOW}可能的原因:${NC}"
                echo "  1. 主库地址或端口错误"
                echo "  2. 复制用户名或密码错误"
                echo "  3. 主库未配置允许复制连接"
                echo "  4. 网络连接问题"
                return 1
            fi
            
            echo -e "${GREEN}✓ 数据复制完成${NC}"
            PG_DATA_DIR="$replica_data_dir"
            ;;
        "2")
            read -p "从库数据目录: " replica_data_dir
            if [ ! -d "$replica_data_dir" ]; then
                echo -e "${RED}数据目录不存在${NC}"
                return 1
            fi
            PG_DATA_DIR="$replica_data_dir"
            
            # 确认配置
            echo ""
            echo -e "${CYAN}从库配置信息:${NC}"
            echo "  主库地址: $PRIMARY_HOST:$PRIMARY_PORT"
            echo "  本地端口: $PG_PORT"
            echo "  数据目录: $PG_DATA_DIR"
            echo "  复制用户: $PG_REPL_USER"
            echo ""
            
            if ! confirm_action "确认以上配置?"; then
                return 1
            fi
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return 1
            ;;
    esac
    
    # 配置从库参数
    echo -e "${YELLOW}配置从库参数...${NC}"
    
    local conf_file="$PG_DATA_DIR/postgresql.conf"
    
    # 配置端口
    if grep -q "^#port = 5432" "$conf_file"; then
        sed -i "s/^#port = 5432/port = $PG_PORT/" "$conf_file"
    elif grep -q "^port = " "$conf_file"; then
        sed -i "s/^port = .*/port = $PG_PORT/" "$conf_file"
    else
        echo "port = $PG_PORT" >> "$conf_file"
    fi
    
    # 确保standby.signal文件存在
    touch "$PG_DATA_DIR/standby.signal"
    
    # 配置primary_conninfo
    if grep -q "^primary_conninfo" "$conf_file"; then
        sed -i "s|^primary_conninfo.*|primary_conninfo = 'host=$PRIMARY_HOST port=$PRIMARY_PORT user=$PG_REPL_USER password=$PG_REPL_PASSWORD'|" "$conf_file"
    else
        echo "primary_conninfo = 'host=$PRIMARY_HOST port=$PRIMARY_PORT user=$PG_REPL_USER password=$PG_REPL_PASSWORD'" >> "$conf_file"
    fi
    
    # 确保hot_standby开启
    if grep -q "^#hot_standby = on" "$conf_file"; then
        sed -i "s/^#hot_standby = on/hot_standby = on/" "$conf_file"
    elif ! grep -q "^hot_standby = on" "$conf_file"; then
        echo "hot_standby = on" >> "$conf_file"
    fi
    
    # 配置pg_hba.conf允许远程连接
    local hba_file="$PG_DATA_DIR/pg_hba.conf"
    if ! grep -q "host.*all.*all.*0.0.0.0/0.*md5" "$hba_file"; then
        echo "host    all             all             0.0.0.0/0               md5" >> "$hba_file"
    fi
    
    # 设置权限
    chown -R $PG_USER:$(id -gn $PG_USER) "$PG_DATA_DIR"
    
    echo -e "${GREEN}✓ 从库配置完成${NC}"
    
    # 启动从库
    echo -e "${YELLOW}启动从库服务...${NC}"
    
    local service_name=$(find_pg_service_name)
    if [ -n "$service_name" ]; then
        systemctl start "$service_name"
        sleep 3
        check_service_status "$service_name"
    else
        sudo -u $PG_USER $PG_INSTALL_DIR/bin/pg_ctl start -D "$PG_DATA_DIR"
        sleep 3
    fi
    
    # 检查复制状态
    check_replication_status
    
    # 保存配置信息
    save_config "replica"
    
    return 0
}

# ======================== 检查复制状态 ========================

check_replication_status() {
    print_title "检查PostgreSQL复制状态"
    
    # 检测PostgreSQL安装
    if ! detect_postgresql_installation; then
        echo -e "${RED}未找到PostgreSQL安装${NC}"
        return 1
    fi
    
    # 获取配置
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
    
    # 获取密码
    if [ -z "$PG_PASSWORD" ]; then
        read -s -p "请输入PostgreSQL密码: " PG_PASSWORD
        echo ""
    fi
    
    # 检查是否为从库
    local is_recovery=$(sudo -u $PG_USER $PG_INSTALL_DIR/bin/psql -p $PG_PORT -t -c "SELECT pg_is_in_recovery();" 2>/dev/null | xargs)
    
    echo -e "${CYAN}当前角色:${NC}"
    
    if [ "$is_recovery" = "t" ]; then
        echo -e "  ${GREEN}从库 (Replica)${NC}"
        
        echo ""
        echo -e "${CYAN}复制状态:${NC}"
        
        # 获取复制延迟
        local lag=$(sudo -u $PG_USER $PG_INSTALL_DIR/bin/psql -p $PG_PORT -t -c "
            SELECT CASE 
                WHEN pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn() THEN 0
                ELSE EXTRACT(EPOCH FROM now() - pg_last_xact_replay_timestamp())::int
            END AS lag_seconds;
        " 2>/dev/null | xargs)
        
        if [ -n "$lag" ] && [ "$lag" -eq "$lag" ] 2>/dev/null; then
            if [ "$lag" -eq 0 ]; then
                echo -e "  延迟: ${GREEN}无延迟${NC}"
            else
                echo -e "  延迟: ${YELLOW}${lag}秒${NC}"
            fi
        fi
        
        # 获取WAL位置
        local received_lsn=$(sudo -u $PG_USER $PG_INSTALL_DIR/bin/psql -p $PG_PORT -t -c "SELECT pg_last_wal_receive_lsn();" 2>/dev/null | xargs)
        local replay_lsn=$(sudo -u $PG_USER $PG_INSTALL_DIR/bin/psql -p $PG_PORT -t -c "SELECT pg_last_wal_replay_lsn();" 2>/dev/null | xargs)
        
        echo -e "  接收WAL位置: $received_lsn"
        echo -e "  重放WAL位置: $replay_lsn"
        
        # 检查主库连接信息
        local conninfo=$(sudo -u $PG_USER $PG_INSTALL_DIR/bin/psql -p $PG_PORT -t -c "SHOW primary_conninfo;" 2>/dev/null | xargs)
        if [ -n "$conninfo" ]; then
            echo -e "  主库连接: $conninfo"
        fi
        
        echo ""
        echo -e "${GREEN}✓ 流复制运行正常${NC}"
    else
        echo -e "  ${CYAN}主库 (Primary)${NC}"
        
        echo ""
        echo -e "${CYAN}连接的从库:${NC}"
        
        # 显示连接的从库信息
        local replicas=$(sudo -u $PG_USER $PG_INSTALL_DIR/bin/psql -p $PG_PORT -c "
            SELECT client_addr, state, sent_lsn, write_lsn, flush_lsn, replay_lsn 
            FROM pg_stat_replication;
        " 2>/dev/null)
        
        if [ -n "$replicas" ] && ! echo "$replicas" | grep -q "(0 rows)"; then
            echo "$replicas"
        else
            echo -e "  ${YELLOW}暂无从库连接${NC}"
        fi
    fi
    
    return 0
}

# ======================== 重置复制配置 ========================

reset_replication() {
    print_title "重置PostgreSQL复制配置"
    
    # 检测PostgreSQL安装
    if ! detect_postgresql_installation; then
        echo -e "${RED}未找到PostgreSQL安装${NC}"
        return 1
    fi
    
    if ! confirm_action "确认要重置复制配置? 这将停止当前的复制进程。"; then
        return 1
    fi
    
    # 查找服务名
    local service_name=$(find_pg_service_name)
    
    # 停止PostgreSQL服务
    echo -e "${YELLOW}停止PostgreSQL服务...${NC}"
    if [ -n "$service_name" ]; then
        systemctl stop "$service_name"
    else
        sudo -u $PG_USER $PG_INSTALL_DIR/bin/pg_ctl stop -D "$PG_DATA_DIR"
    fi
    
    # 删除standby.signal
    if [ -f "$PG_DATA_DIR/standby.signal" ]; then
        rm -f "$PG_DATA_DIR/standby.signal"
        echo -e "${GREEN}✓ 已删除standby.signal${NC}"
    fi
    
    # 移除复制相关配置
    local conf_file="$PG_DATA_DIR/postgresql.conf"
    if [ -f "$conf_file" ]; then
        echo -e "${YELLOW}清理配置文件...${NC}"
        sed -i '/^# Replication Configuration/d' "$conf_file"
        sed -i '/^primary_conninfo/d' "$conf_file"
        sed -i '/^wal_level/d' "$conf_file"
        sed -i '/^max_wal_senders/d' "$conf_file"
        sed -i '/^wal_keep_size/d' "$conf_file"
        sed -i '/^archive_mode/d' "$conf_file"
        sed -i '/^archive_command/d' "$conf_file"
        echo -e "${GREEN}✓ 配置文件已清理${NC}"
    fi
    
    # 清理pg_hba.conf中的复制配置
    local hba_file="$PG_DATA_DIR/pg_hba.conf"
    if [ -f "$hba_file" ]; then
        sed -i '/^# Replication access/d' "$hba_file"
        sed -i '/^host.*replication/d' "$hba_file"
    fi
    
    # 删除配置文件
    if [ -f "$CONFIG_FILE" ]; then
        rm -f "$CONFIG_FILE"
        echo -e "${GREEN}✓ 复制配置文件已删除${NC}"
    fi
    
    # 删除归档目录
    if [ -d "$PG_DATA_DIR/archive" ]; then
        rm -rf "$PG_DATA_DIR/archive"
        echo -e "${GREEN}✓ 归档目录已删除${NC}"
    fi
    
    echo ""
    echo -e "${GREEN}✓ 复制配置已重置${NC}"
    echo -e "${YELLOW}注意: 请手动启动PostgreSQL服务${NC}"
    
    if [ -n "$service_name" ]; then
        echo -e "${CYAN}启动命令: systemctl start $service_name${NC}"
    else
        echo -e "${CYAN}启动命令: sudo -u $PG_USER $PG_INSTALL_DIR/bin/pg_ctl start -D $PG_DATA_DIR${NC}"
    fi
}

# ======================== 配置保存和加载 ========================

save_config() {
    local role="$1"
    
    cat > "$CONFIG_FILE" << EOF
# PostgreSQL Replication Configuration
# Generated: $(date)

REPLICATION_ROLE=$role
PG_INSTALL_DIR=$PG_INSTALL_DIR
PG_DATA_DIR=$PG_DATA_DIR
PG_PORT=$PG_PORT
PG_USER=$PG_USER
PG_VERSION=$PG_VERSION
PRIMARY_HOST=$PRIMARY_HOST
PRIMARY_PORT=$PRIMARY_PORT
PG_REPL_USER=$PG_REPL_USER
EOF
    
    echo -e "${GREEN}✓ 配置已保存到 $CONFIG_FILE${NC}"
}

# ======================== 显示帮助信息 ========================

show_help() {
    print_title "PostgreSQL 流复制配置脚本帮助"
    
    echo -e "${CYAN}用法:${NC}"
    echo "  bash setup_pgsql_replication.sh [选项]"
    echo ""
    echo -e "${CYAN}选项:${NC}"
    echo "  primary   配置当前服务器为主库"
    echo "  replica   配置当前服务器为从库"
    echo "  status    检查复制状态"
    echo "  reset     重置复制配置"
    echo "  help      显示帮助信息"
    echo ""
    echo -e "${CYAN}交互式菜单:${NC}"
    echo "  直接运行脚本即可进入交互式菜单"
    echo ""
    echo -e "${CYAN}配置说明:${NC}"
    echo "  主库配置:"
    echo "    - 设置wal_level = replica"
    echo "    - 配置max_wal_senders"
    echo "    - 创建复制用户"
    echo "    - 配置pg_hba.conf允许复制连接"
    echo ""
    echo "  从库配置:"
    echo "    - 使用pg_basebackup创建基础备份"
    echo "    - 创建standby.signal文件"
    echo "    - 配置primary_conninfo"
    echo "    - 启用hot_standby"
    echo ""
    echo -e "${CYAN}常用命令:${NC}"
    echo "  SELECT pg_is_in_recovery();           -- 检查是否为从库"
    echo "  SELECT * FROM pg_stat_replication;    -- 查看复制状态"
    echo "  SELECT pg_last_wal_receive_lsn();     -- 查看接收的WAL位置"
    echo "  SELECT pg_last_wal_replay_lsn();      -- 查看重放的WAL位置"
    echo ""
    echo -e "${CYAN}配置文件位置:${NC}"
    echo "  本脚本配置: $CONFIG_FILE"
    echo "  PostgreSQL配置: \$PG_DATA_DIR/postgresql.conf"
    echo "  认证配置: \$PG_DATA_DIR/pg_hba.conf"
    echo ""
}

# ======================== 主菜单 ========================

show_main_menu() {
    print_title "PostgreSQL 流复制配置工具"
    
    echo "请选择操作:"
    echo ""
    echo "1. 配置主库 (Primary)"
    echo "2. 配置从库 (Replica)"
    echo "3. 检查复制状态"
    echo "4. 重置复制配置"
    echo "5. 安装PostgreSQL"
    echo "6. 显示帮助信息"
    echo "q. 退出"
    echo ""
    
    read -p "请选择 [1-6/q]: " main_choice
    
    case $main_choice in
        "1")
            configure_primary
            ;;
        "2")
            configure_replica
            ;;
        "3")
            check_replication_status
            ;;
        "4")
            reset_replication
            ;;
        "5")
            call_install_script
            ;;
        "6")
            show_help
            ;;
        "q"|"Q")
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
    # 检查是否有命令行参数
    if [ $# -gt 0 ]; then
        case "$1" in
            "primary")
                configure_primary
                ;;
            "replica")
                configure_replica
                ;;
            "status")
                check_replication_status
                ;;
            "reset")
                reset_replication
                ;;
            "help"|"-h"|"--help")
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
    
    # 交互式菜单
    while true; do
        show_main_menu
        echo ""
        read -p "按回车返回主菜单... " -r
    done
}

# 执行主程序
main "$@"
