#!/bin/bash

# MySQL 主从复制配置脚本
# 支持配置主库和从库，可自动调用安装脚本
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
    echo "正确用法: bash setup_mysql_replication.sh 或 ./setup_mysql_replication.sh"
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
INSTALL_SCRIPT="$SCRIPT_DIR/install_mysql.sh"

# MySQL配置
MYSQL_INSTALL_DIR=""
MYSQL_DATA_DIR=""
MYSQL_LOG_DIR=""
MYSQL_PORT="3306"
MYSQL_ROOT_PASSWORD="root"
MYSQL_REPL_USER="repl"
MYSQL_REPL_PASSWORD="repl_password"
MYSQL_SERVER_ID=""
MYSQL_BINLOG_DIR=""

# 主从配置
REPLICATION_ROLE=""  # master 或 slave
MASTER_HOST=""
MASTER_PORT="3306"

# 配置文件路径
CONFIG_FILE="/etc/mysql_replication.conf"

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

# ======================== 检测MySQL安装 ========================

detect_mysql_installation() {
    echo -e "${YELLOW}检测MySQL安装...${NC}"
    
    # 常见的MySQL安装路径
    local mysql_paths=(
        "/mnt/data/mysql"
        "/usr/local/mysql"
        "/opt/mysql"
        "/data/mysql"
    )
    
    # 从配置文件或环境变量中读取
    if [ -f "/etc/my.cnf" ]; then
        local basedir=$(grep "^basedir" /etc/my.cnf 2>/dev/null | head -1 | awk -F'=' '{print $2}' | xargs)
        local datadir=$(grep "^datadir" /etc/my.cnf 2>/dev/null | head -1 | awk -F'=' '{print $2}' | xargs)
        
        if [ -n "$basedir" ]; then
            mysql_paths=("$basedir" "${mysql_paths[@]}")
        fi
    fi
    
    # 查找MySQL安装
    for path in "${mysql_paths[@]}"; do
        if [ -d "$path" ] && [ -f "$path/bin/mysql" ]; then
            MYSQL_INSTALL_DIR="$path"
            echo -e "${GREEN}找到MySQL安装: $MYSQL_INSTALL_DIR${NC}"
            
            # 获取版本信息
            local version=$($MYSQL_INSTALL_DIR/bin/mysql --version 2>/dev/null | grep -oP 'Ver \K[0-9]+\.[0-9]+\.[0-9]+')
            echo -e "${GREEN}MySQL版本: $version${NC}"
            
            # 获取数据目录
            if [ -f "/etc/my.cnf" ]; then
                MYSQL_DATA_DIR=$(grep "^datadir" /etc/my.cnf 2>/dev/null | head -1 | awk -F'=' '{print $2}' | xargs)
            fi
            
            if [ -z "$MYSQL_DATA_DIR" ]; then
                MYSQL_DATA_DIR="$path/data"
            fi
            
            MYSQL_LOG_DIR=$(dirname "$MYSQL_DATA_DIR")/log
            MYSQL_PORT=$(grep "^port" /etc/my.cnf 2>/dev/null | head -1 | awk -F'=' '{print $2}' | xargs)
            MYSQL_PORT=${MYSQL_PORT:-3306}
            
            return 0
        fi
    done
    
    # 尝试使用which命令
    if command -v mysql &>/dev/null; then
        local mysql_path=$(which mysql)
        MYSQL_INSTALL_DIR=$(dirname $(dirname "$mysql_path"))
        echo -e "${GREEN}找到MySQL: $MYSQL_INSTALL_DIR${NC}"
        return 0
    fi
    
    echo -e "${RED}未找到MySQL安装${NC}"
    return 1
}

# ======================== 调用安装脚本 ========================

call_install_script() {
    print_title "安装MySQL"
    
    if [ ! -f "$INSTALL_SCRIPT" ]; then
        echo -e "${RED}未找到安装脚本: $INSTALL_SCRIPT${NC}"
        return 1
    fi
    
    echo -e "${YELLOW}即将调用MySQL安装脚本...${NC}"
    echo -e "${CYAN}安装脚本路径: $INSTALL_SCRIPT${NC}"
    echo ""
    
    if ! confirm_action "是否继续安装MySQL?"; then
        return 1
    fi
    
    # 执行安装脚本
    bash "$INSTALL_SCRIPT"
    
    # 检查安装结果
    if detect_mysql_installation; then
        echo -e "${GREEN}✓ MySQL安装成功${NC}"
        return 0
    else
        echo -e "${RED}✗ MySQL安装失败${NC}"
        return 1
    fi
}

# ======================== 配置主库 ========================

configure_master() {
    print_title "配置MySQL主库"
    
    # 检测MySQL安装
    if ! detect_mysql_installation; then
        echo -e "${YELLOW}MySQL未安装，是否先安装MySQL?${NC}"
        echo "1. 安装MySQL"
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
    
    # 检查MySQL服务状态
    if ! check_service_status "mysql"; then
        echo -e "${YELLOW}尝试启动MySQL服务...${NC}"
        systemctl start mysql
        sleep 3
        if ! check_service_status "mysql"; then
            echo -e "${RED}MySQL服务启动失败${NC}"
            return 1
        fi
    fi
    
    # 获取配置信息
    echo -e "${CYAN}请输入主库配置信息:${NC}"
    echo ""
    
    read -p "MySQL端口 [$MYSQL_PORT]: " input_port
    MYSQL_PORT=${input_port:-$MYSQL_PORT}
    
    read -p "MySQL Root密码 [$MYSQL_ROOT_PASSWORD]: " input_password
    MYSQL_ROOT_PASSWORD=${input_password:-$MYSQL_ROOT_PASSWORD}
    
    # 生成唯一的server-id
    MYSQL_SERVER_ID=$(date +%s | tail -c 6)
    echo -e "${CYAN}生成的Server ID: $MYSQL_SERVER_ID${NC}"
    read -p "是否使用此Server ID? [Y/n]: " confirm_id
    if [[ $confirm_id =~ ^[Nn]$ ]]; then
        read -p "请输入Server ID (1-4294967295): " custom_id
        if [[ "$custom_id" =~ ^[0-9]+$ ]] && [ "$custom_id" -ge 1 ] && [ "$custom_id" -le 4294967295 ]; then
            MYSQL_SERVER_ID="$custom_id"
        else
            echo -e "${RED}无效的Server ID，使用默认值${NC}"
        fi
    fi
    
    # 复制用户配置
    echo ""
    echo -e "${CYAN}配置复制用户:${NC}"
    read -p "复制用户名 [$MYSQL_REPL_USER]: " input_user
    MYSQL_REPL_USER=${input_user:-$MYSQL_REPL_USER}
    
    read -p "复制用户密码 [$MYSQL_REPL_PASSWORD]: " input_pass
    MYSQL_REPL_PASSWORD=${input_pass:-$MYSQL_REPL_PASSWORD}
    
    # 确认配置
    echo ""
    echo -e "${CYAN}主库配置信息:${NC}"
    echo "  Server ID: $MYSQL_SERVER_ID"
    echo "  端口: $MYSQL_PORT"
    echo "  复制用户: $MYSQL_REPL_USER"
    echo "  复制密码: $MYSQL_REPL_PASSWORD"
    echo ""
    
    if ! confirm_action "确认以上配置?"; then
        return 1
    fi
    
    # 备份配置文件
    echo -e "${YELLOW}备份MySQL配置文件...${NC}"
    if [ -f "/etc/my.cnf" ]; then
        cp /etc/my.cnf /etc/my.cnf.backup.$(date +%Y%m%d_%H%M%S)
        echo -e "${GREEN}✓ 配置文件已备份${NC}"
    fi
    
    # 配置主库参数
    echo -e "${YELLOW}配置MySQL主库参数...${NC}"
    
    # 获取binlog目录
    MYSQL_BINLOG_DIR="$MYSQL_DATA_DIR"
    
    # 检查并添加主库配置
    local my_cnf="/etc/my.cnf"
    
    # 检查[mysqld]段是否存在
    if ! grep -q "^\[mysqld\]" "$my_cnf" 2>/dev/null; then
        echo -e "${YELLOW}[mysqld]段不存在，添加配置...${NC}"
        echo "" >> "$my_cnf"
        echo "[mysqld]" >> "$my_cnf"
    fi
    
    # 移除旧的复制相关配置
    sed -i '/^server-id/d' "$my_cnf"
    sed -i '/^log-bin/d' "$my_cnf"
    sed -i '/^binlog_format/d' "$my_cnf"
    sed -i '/^binlog_expire_logs_seconds/d' "$my_cnf"
    sed -i '/^gtid_mode/d' "$my_cnf"
    sed -i '/^enforce_gtid_consistency/d' "$my_cnf"
    sed -i '/^# Replication/d' "$my_cnf"
    
    # 在[mysqld]段后添加主库配置
    sed -i "/^\[mysqld\]/a\\
\\
# Replication Configuration\\
server-id = $MYSQL_SERVER_ID\\
log-bin = $MYSQL_BINLOG_DIR/mysql-bin\\
binlog_format = ROW\\
binlog_expire_logs_seconds = 604800\\
gtid_mode = ON\\
enforce_gtid_consistency = ON" "$my_cnf"
    
    echo -e "${GREEN}✓ 主库配置已添加${NC}"
    
    # 重启MySQL服务
    echo -e "${YELLOW}重启MySQL服务...${NC}"
    systemctl restart mysql
    sleep 3
    
    if ! check_service_status "mysql"; then
        echo -e "${RED}MySQL服务重启失败${NC}"
        echo -e "${YELLOW}请检查配置文件: /etc/my.cnf${NC}"
        return 1
    fi
    
    # 创建复制用户
    echo -e "${YELLOW}创建复制用户...${NC}"
    
    $MYSQL_INSTALL_DIR/bin/mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "
        CREATE USER IF NOT EXISTS '$MYSQL_REPL_USER'@'%' IDENTIFIED BY '$MYSQL_REPL_PASSWORD';
        GRANT REPLICATION SLAVE ON *.* TO '$MYSQL_REPL_USER'@'%';
        FLUSH PRIVILEGES;
    " 2>/dev/null
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ 复制用户创建成功${NC}"
    else
        echo -e "${RED}复制用户创建失败${NC}"
        echo -e "${YELLOW}请手动执行:${NC}"
        echo "  mysql -u root -p -e \"CREATE USER '$MYSQL_REPL_USER'@'%' IDENTIFIED BY '$MYSQL_REPL_PASSWORD';\""
        echo "  mysql -u root -p -e \"GRANT REPLICATION SLAVE ON *.* TO '$MYSQL_REPL_USER'@'%'; FLUSH PRIVILEGES;\""
    fi
    
    # 获取主库状态
    echo -e "${YELLOW}获取主库状态...${NC}"
    
    local master_status=$($MYSQL_INSTALL_DIR/bin/mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "SHOW MASTER STATUS\G" 2>/dev/null)
    local binlog_file=$(echo "$master_status" | grep "File:" | awk '{print $2}')
    local binlog_pos=$(echo "$master_status" | grep "Position:" | awk '{print $2}')
    
    # 获取GTID信息
    local gtid_executed=$($MYSQL_INSTALL_DIR/bin/mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "SELECT @@global.gtid_executed\G" 2>/dev/null | grep "gtid_executed:" | awk '{print $2}')
    
    echo ""
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}MySQL 主库配置完成!${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo ""
    echo -e "${CYAN}主库信息 (请记录以下信息，配置从库时需要):${NC}"
    echo "  主库IP: $(hostname -I | awk '{print $1}')"
    echo "  端口: $MYSQL_PORT"
    echo "  Server ID: $MYSQL_SERVER_ID"
    echo "  Binlog文件: $binlog_file"
    echo "  Binlog位置: $binlog_pos"
    echo "  GTID: $gtid_executed"
    echo "  复制用户: $MYSQL_REPL_USER"
    echo "  复制密码: $MYSQL_REPL_PASSWORD"
    echo ""
    
    # 保存配置信息
    save_config "master"
    
    return 0
}

# ======================== 配置从库 ========================

configure_slave() {
    print_title "配置MySQL从库"
    
    # 检测MySQL安装
    if ! detect_mysql_installation; then
        echo -e "${YELLOW}MySQL未安装，是否先安装MySQL?${NC}"
        echo "1. 安装MySQL"
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
    
    # 检查MySQL服务状态
    if ! check_service_status "mysql"; then
        echo -e "${YELLOW}尝试启动MySQL服务...${NC}"
        systemctl start mysql
        sleep 3
        if ! check_service_status "mysql"; then
            echo -e "${RED}MySQL服务启动失败${NC}"
            return 1
        fi
    fi
    
    # 获取主库信息
    echo -e "${CYAN}请输入主库信息:${NC}"
    echo ""
    
    read -p "主库IP地址: " MASTER_HOST
    if [ -z "$MASTER_HOST" ]; then
        echo -e "${RED}主库IP地址不能为空${NC}"
        return 1
    fi
    
    read -p "主库端口 [$MASTER_PORT]: " input_port
    MASTER_PORT=${input_port:-$MASTER_PORT}
    
    read -p "复制用户名 [$MYSQL_REPL_USER]: " input_user
    MYSQL_REPL_USER=${input_user:-$MYSQL_REPL_USER}
    
    read -p "复制用户密码 [$MYSQL_REPL_PASSWORD]: " input_pass
    MYSQL_REPL_PASSWORD=${input_pass:-$MYSQL_REPL_PASSWORD}
    
    # 获取从库配置
    echo ""
    echo -e "${CYAN}请输入从库配置:${NC}"
    echo ""
    
    read -p "MySQL端口 [$MYSQL_PORT]: " input_local_port
    MYSQL_PORT=${input_local_port:-$MYSQL_PORT}
    
    read -p "MySQL Root密码 [$MYSQL_ROOT_PASSWORD]: " input_password
    MYSQL_ROOT_PASSWORD=${input_password:-$MYSQL_ROOT_PASSWORD}
    
    # 生成唯一的server-id
    MYSQL_SERVER_ID=$(date +%s | tail -c 6)
    echo -e "${CYAN}生成的Server ID: $MYSQL_SERVER_ID${NC}"
    read -p "是否使用此Server ID? [Y/n]: " confirm_id
    if [[ $confirm_id =~ ^[Nn]$ ]]; then
        read -p "请输入Server ID (1-4294967295，必须与主库不同): " custom_id
        if [[ "$custom_id" =~ ^[0-9]+$ ]] && [ "$custom_id" -ge 1 ] && [ "$custom_id" -le 4294967295 ]; then
            MYSQL_SERVER_ID="$custom_id"
        else
            echo -e "${RED}无效的Server ID，使用默认值${NC}"
        fi
    fi
    
    # 选择复制方式
    echo ""
    echo -e "${CYAN}选择复制方式:${NC}"
    echo "1. 基于GTID复制 (推荐，自动定位)"
    echo "2. 基于Binlog位置复制 (需要手动指定文件和位置)"
    echo ""
    read -p "请选择 [1/2]: " repl_mode
    
    local use_gtid=true
    local binlog_file=""
    local binlog_pos=""
    
    case $repl_mode in
        "1")
            use_gtid=true
            echo -e "${GREEN}使用GTID复制${NC}"
            ;;
        "2")
            use_gtid=false
            echo -e "${YELLOW}请输入主库的Binlog信息:${NC}"
            read -p "Binlog文件名 (如 mysql-bin.000001): " binlog_file
            read -p "Binlog位置 (如 154): " binlog_pos
            
            if [ -z "$binlog_file" ] || [ -z "$binlog_pos" ]; then
                echo -e "${RED}Binlog文件名和位置不能为空${NC}"
                return 1
            fi
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return 1
            ;;
    esac
    
    # 确认配置
    echo ""
    echo -e "${CYAN}从库配置信息:${NC}"
    echo "  主库地址: $MASTER_HOST:$MASTER_PORT"
    echo "  本地Server ID: $MYSQL_SERVER_ID"
    echo "  本地端口: $MYSQL_PORT"
    echo "  复制用户: $MYSQL_REPL_USER"
    if [ "$use_gtid" = true ]; then
        echo "  复制方式: GTID"
    else
        echo "  复制方式: Binlog位置 ($binlog_file:$binlog_pos)"
    fi
    echo ""
    
    if ! confirm_action "确认以上配置?"; then
        return 1
    fi
    
    # 备份配置文件
    echo -e "${YELLOW}备份MySQL配置文件...${NC}"
    if [ -f "/etc/my.cnf" ]; then
        cp /etc/my.cnf /etc/my.cnf.backup.$(date +%Y%m%d_%H%M%S)
        echo -e "${GREEN}✓ 配置文件已备份${NC}"
    fi
    
    # 配置从库参数
    echo -e "${YELLOW}配置MySQL从库参数...${NC}"
    
    local my_cnf="/etc/my.cnf"
    
    # 检查[mysqld]段是否存在
    if ! grep -q "^\[mysqld\]" "$my_cnf" 2>/dev/null; then
        echo -e "${YELLOW}[mysqld]段不存在，添加配置...${NC}"
        echo "" >> "$my_cnf"
        echo "[mysqld]" >> "$my_cnf"
    fi
    
    # 移除旧的复制相关配置
    sed -i '/^server-id/d' "$my_cnf"
    sed -i '/^log-bin/d' "$my_cnf"
    sed -i '/^relay-log/d' "$my_cnf"
    sed -i '/^read_only/d' "$my_cnf"
    sed -i '/^super_read_only/d' "$my_cnf"
    sed -i '/^gtid_mode/d' "$my_cnf"
    sed -i '/^enforce_gtid_consistency/d' "$my_cnf"
    sed -i '/^# Replication/d' "$my_cnf"
    
    # 在[mysqld]段后添加从库配置
    sed -i "/^\[mysqld\]/a\\
\\
# Replication Configuration\\
server-id = $MYSQL_SERVER_ID\\
relay-log = $MYSQL_DATA_DIR/relay-bin\\
read_only = ON\\
super_read_only = ON\\
gtid_mode = ON\\
enforce_gtid_consistency = ON" "$my_cnf"
    
    echo -e "${GREEN}✓ 从库配置已添加${NC}"
    
    # 重启MySQL服务
    echo -e "${YELLOW}重启MySQL服务...${NC}"
    systemctl restart mysql
    sleep 3
    
    if ! check_service_status "mysql"; then
        echo -e "${RED}MySQL服务重启失败${NC}"
        echo -e "${YELLOW}请检查配置文件: /etc/my.cnf${NC}"
        return 1
    fi
    
    # 配置主从复制
    echo -e "${YELLOW}配置主从复制...${NC}"
    
    local change_master_sql=""
    
    if [ "$use_gtid" = true ]; then
        change_master_sql="
            CHANGE MASTER TO
            MASTER_HOST='$MASTER_HOST',
            MASTER_PORT=$MASTER_PORT,
            MASTER_USER='$MYSQL_REPL_USER',
            MASTER_PASSWORD='$MYSQL_REPL_PASSWORD',
            MASTER_AUTO_POSITION=1;
        "
    else
        change_master_sql="
            CHANGE MASTER TO
            MASTER_HOST='$MASTER_HOST',
            MASTER_PORT=$MASTER_PORT,
            MASTER_USER='$MYSQL_REPL_USER',
            MASTER_PASSWORD='$MYSQL_REPL_PASSWORD',
            MASTER_LOG_FILE='$binlog_file',
            MASTER_LOG_POS=$binlog_pos;
        "
    fi
    
    $MYSQL_INSTALL_DIR/bin/mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "
        STOP SLAVE;
        $change_master_sql
        START SLAVE;
    " 2>/dev/null
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ 主从复制配置成功${NC}"
    else
        echo -e "${RED}主从复制配置失败${NC}"
        echo -e "${YELLOW}请手动执行以下命令:${NC}"
        echo "  mysql -u root -p"
        echo "  STOP SLAVE;"
        echo "  $change_master_sql"
        echo "  START SLAVE;"
        return 1
    fi
    
    # 检查复制状态
    sleep 3
    check_replication_status
    
    # 保存配置信息
    save_config "slave"
    
    return 0
}

# ======================== 检查复制状态 ========================

check_replication_status() {
    print_title "检查MySQL复制状态"
    
    # 检测MySQL安装
    if ! detect_mysql_installation; then
        echo -e "${RED}未找到MySQL安装${NC}"
        return 1
    fi
    
    # 检查MySQL服务状态
    if ! check_service_status "mysql"; then
        echo -e "${RED}MySQL服务未运行${NC}"
        return 1
    fi
    
    # 获取配置
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    fi
    
    # 获取Root密码
    if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
        read -s -p "请输入MySQL Root密码: " MYSQL_ROOT_PASSWORD
        echo ""
    fi
    
    # 检查主库状态
    echo -e "${CYAN}主库状态:${NC}"
    local master_status=$($MYSQL_INSTALL_DIR/bin/mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "SHOW MASTER STATUS\G" 2>/dev/null)
    if [ -n "$master_status" ]; then
        local binlog_file=$(echo "$master_status" | grep "File:" | awk '{print $2}')
        local binlog_pos=$(echo "$master_status" | grep "Position:" | awk '{print $2}')
        echo -e "  Binlog文件: ${GREEN}$binlog_file${NC}"
        echo -e "  Binlog位置: ${GREEN}$binlog_pos${NC}"
    else
        echo -e "  ${YELLOW}无法获取主库状态${NC}"
    fi
    
    echo ""
    
    # 检查从库状态
    echo -e "${CYAN}从库状态:${NC}"
    local slave_status=$($MYSQL_INSTALL_DIR/bin/mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "SHOW SLAVE STATUS\G" 2>/dev/null)
    
    if [ -z "$slave_status" ]; then
        echo -e "  ${YELLOW}当前服务器未配置为从库${NC}"
        return 0
    fi
    
    local io_running=$(echo "$slave_status" | grep "Slave_IO_Running:" | awk '{print $2}')
    local sql_running=$(echo "$slave_status" | grep "Slave_SQL_Running:" | awk '{print $2}')
    local seconds_behind=$(echo "$slave_status" | grep "Seconds_Behind_Master:" | awk '{print $2}')
    local last_error=$(echo "$slave_status" | grep "Last_Error:" | sed 's/.*Last_Error: //')
    local master_host=$(echo "$slave_status" | grep "Master_Host:" | awk '{print $2}')
    
    echo -e "  主库地址: $master_host"
    
    if [ "$io_running" = "Yes" ] && [ "$sql_running" = "Yes" ]; then
        echo -e "  IO线程: ${GREEN}$io_running${NC}"
        echo -e "  SQL线程: ${GREEN}$sql_running${NC}"
        echo -e "  延迟: ${GREEN}${seconds_behind}秒${NC}"
        echo ""
        echo -e "${GREEN}✓ 主从复制运行正常${NC}"
    else
        echo -e "  IO线程: ${RED}$io_running${NC}"
        echo -e "  SQL线程: ${RED}$sql_running${NC}"
        if [ -n "$last_error" ]; then
            echo -e "  错误信息: ${RED}$last_error${NC}"
        fi
        echo ""
        echo -e "${RED}✗ 主从复制异常${NC}"
        echo -e "${YELLOW}请执行 'SHOW SLAVE STATUS\\G' 查看详细信息${NC}"
    fi
    
    return 0
}

# ======================== 重置复制配置 ========================

reset_replication() {
    print_title "重置MySQL复制配置"
    
    # 检测MySQL安装
    if ! detect_mysql_installation; then
        echo -e "${RED}未找到MySQL安装${NC}"
        return 1
    fi
    
    if ! confirm_action "确认要重置复制配置? 这将停止当前的复制进程。"; then
        return 1
    fi
    
    # 获取Root密码
    if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
        read -s -p "请输入MySQL Root密码: " MYSQL_ROOT_PASSWORD
        echo ""
    fi
    
    # 停止并重置复制
    echo -e "${YELLOW}停止MySQL复制...${NC}"
    $MYSQL_INSTALL_DIR/bin/mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "
        STOP SLAVE;
        RESET SLAVE ALL;
    " 2>/dev/null
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ MySQL复制已重置${NC}"
    else
        echo -e "${YELLOW}重置复制失败或未配置复制${NC}"
    fi
    
    # 移除配置文件中的复制相关配置
    local my_cnf="/etc/my.cnf"
    if [ -f "$my_cnf" ]; then
        echo -e "${YELLOW}清理配置文件...${NC}"
        sed -i '/^# Replication Configuration/d' "$my_cnf"
        sed -i '/^server-id/d' "$my_cnf"
        sed -i '/^log-bin/d' "$my_cnf"
        sed -i '/^relay-log/d' "$my_cnf"
        sed -i '/^read_only/d' "$my_cnf"
        sed -i '/^super_read_only/d' "$my_cnf"
        sed -i '/^gtid_mode/d' "$my_cnf"
        sed -i '/^enforce_gtid_consistency/d' "$my_cnf"
        echo -e "${GREEN}✓ 配置文件已清理${NC}"
    fi
    
    # 删除配置文件
    if [ -f "$CONFIG_FILE" ]; then
        rm -f "$CONFIG_FILE"
        echo -e "${GREEN}✓ 复制配置文件已删除${NC}"
    fi
    
    echo ""
    echo -e "${YELLOW}注意: 重启MySQL服务后配置才会完全生效${NC}"
    echo -e "${CYAN}重启命令: systemctl restart mysql${NC}"
}

# ======================== 配置保存和加载 ========================

save_config() {
    local role="$1"
    
    cat > "$CONFIG_FILE" << EOF
# MySQL Replication Configuration
# Generated: $(date)

REPLICATION_ROLE=$role
MYSQL_INSTALL_DIR=$MYSQL_INSTALL_DIR
MYSQL_DATA_DIR=$MYSQL_DATA_DIR
MYSQL_PORT=$MYSQL_PORT
MYSQL_SERVER_ID=$MYSQL_SERVER_ID
MASTER_HOST=$MASTER_HOST
MASTER_PORT=$MASTER_PORT
MYSQL_REPL_USER=$MYSQL_REPL_USER
EOF
    
    echo -e "${GREEN}✓ 配置已保存到 $CONFIG_FILE${NC}"
}

# ======================== 显示帮助信息 ========================

show_help() {
    print_title "MySQL 主从复制配置脚本帮助"
    
    echo -e "${CYAN}用法:${NC}"
    echo "  bash setup_mysql_replication.sh [选项]"
    echo ""
    echo -e "${CYAN}选项:${NC}"
    echo "  master    配置当前服务器为主库"
    echo "  slave     配置当前服务器为从库"
    echo "  status    检查复制状态"
    echo "  reset     重置复制配置"
    echo "  help      显示帮助信息"
    echo ""
    echo -e "${CYAN}交互式菜单:${NC}"
    echo "  直接运行脚本即可进入交互式菜单"
    echo ""
    echo -e "${CYAN}配置说明:${NC}"
    echo "  主库配置:"
    echo "    - 启用binlog (log-bin)"
    echo "    - 设置唯一的server-id"
    echo "    - 启用GTID模式"
    echo "    - 创建复制用户"
    echo ""
    echo "  从库配置:"
    echo "    - 设置不同的server-id"
    echo "    - 启用relay-log"
    echo "    - 设置read_only模式"
    echo "    - 配置CHANGE MASTER TO语句"
    echo ""
    echo -e "${CYAN}常用命令:${NC}"
    echo "  SHOW MASTER STATUS;          -- 查看主库状态"
    echo "  SHOW SLAVE STATUS\\G          -- 查看从库状态"
    echo "  START SLAVE;                 -- 启动复制"
    echo "  STOP SLAVE;                  -- 停止复制"
    echo ""
    echo -e "${CYAN}配置文件位置:${NC}"
    echo "  本脚本配置: $CONFIG_FILE"
    echo "  MySQL配置: /etc/my.cnf"
    echo ""
}

# ======================== 主菜单 ========================

show_main_menu() {
    print_title "MySQL 主从复制配置工具"
    
    echo "请选择操作:"
    echo ""
    echo "1. 配置主库 (Master)"
    echo "2. 配置从库 (Slave)"
    echo "3. 检查复制状态"
    echo "4. 重置复制配置"
    echo "5. 安装MySQL"
    echo "6. 显示帮助信息"
    echo "q. 退出"
    echo ""
    
    read -p "请选择 [1-6/q]: " main_choice
    
    case $main_choice in
        "1")
            configure_master
            ;;
        "2")
            configure_slave
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
            "master")
                configure_master
                ;;
            "slave")
                configure_slave
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
