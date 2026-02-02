#!/bin/bash

# PostgreSQL WAL归档管理脚本
# 支持多种模式：完整配置、手动清理、自动清理、定时清理、智能清理、状态查看、测试归档
# 基于PostgreSQL安装文档和最佳实践

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 默认配置变量
DEFAULT_PG_VERSION="18.1"
DEFAULT_PG_USER="postgres"
DEFAULT_PG_GROUP="postgres"
DEFAULT_PG_HOME="/data/di/postgresql"  # 修改为与原脚本一致
DEFAULT_DAYS_TO_KEEP=7
DEFAULT_ARCHIVE_DIR=""

# 脚本版本
SCRIPT_VERSION="2.0.0"  # 升级版本号

# 显示帮助信息
show_help() {
    echo -e "${GREEN}PostgreSQL WAL归档管理脚本 v${SCRIPT_VERSION}${NC}"
    echo ""
    echo "用法: $0 [选项] [模式]"
    echo ""
    echo "模式:"
    echo "  setup         配置WAL归档（完整设置）"
    echo "  manual        手动清理模式"
    echo "  auto          自动清理模式（archive_cleanup_command）"
    echo "  cron          定时清理模式（cron任务）"
    echo "  smart         智能清理模式（基于pg_controldata）"
    echo "  status        显示当前归档状态"
    echo "  test          测试归档配置"
    echo ""
    echo "选项:"
    echo "  -h, --help              显示帮助信息"
    echo "  -v, --version           显示版本信息"
    echo "  -d, --days DAYS         设置归档保留天数（默认: $DEFAULT_DAYS_TO_KEEP）"
    echo "  -u, --user USER         设置PostgreSQL用户（默认: $DEFAULT_PG_USER）"
    echo "  -p, --path PATH         设置PostgreSQL安装路径"
    echo "  -a, --archive PATH      设置归档目录路径"
    echo "  -D, --data PATH         设置数据目录路径"
    echo "  -f, --force             强制执行，跳过确认"
    echo "  -q, --quiet             静默模式，减少输出"
    echo ""
    echo "示例:"
    echo "  $0 setup                    # 交互式配置WAL归档"
    echo "  $0 manual -d 15             # 手动清理15天前的归档"
    echo "  $0 auto -a /archive/wal     # 配置自动清理模式"
    echo "  $0 cron -d 7                # 设置每周清理7天前的归档"
    echo "  $0 smart -f                 # 智能清理（强制模式）"
    echo ""
}

# 显示版本信息
show_version() {
    echo -e "${GREEN}PostgreSQL WAL归档管理脚本 v${SCRIPT_VERSION}${NC}"
}

# 定义profile文件列表（全局变量）
PROFILE_FILES=("/etc/profile" "/etc/bashrc" "/home/$DEFAULT_PG_USER/.bash_profile" "/home/$DEFAULT_PG_USER/.bashrc" "/etc/profile.d/postgres.sh" "/etc/profile.d/pgsql.sh")

# 定义常见安装路径列表（全局变量）
COMMON_PATHS=("/usr/local/pgsql" "/usr/local/postgresql" "/opt/pgsql" "/opt/postgresql" "/var/lib/pgsql")

# 从profile文件中读取PostgreSQL信息
read_pg_profile() {
    # 临时设置区域设置以避免警告
    export LC_ALL=C
    
    # 首先尝试从当前环境中读取
    if [[ -n "$PG_HOME" ]]; then
        DEFAULT_PG_HOME="$PG_HOME"
        # 如果PG_HOME包含bin/postgres，则它也是安装目录
        if [[ -f "$PG_HOME/bin/postgres" ]]; then
            DEFAULT_PG_INSTALL_DIR="$PG_HOME"
        fi
        [[ "$QUIET_MODE" != "true" ]] && echo -e "${YELLOW}从环境变量中读取到 PG_HOME: $PG_HOME${NC}"
    fi
    
    if [[ -n "$PGDATA" ]]; then
        DEFAULT_PG_DATA_DIR="$PGDATA"
        [[ "$QUIET_MODE" != "true" ]] && echo -e "${YELLOW}从环境变量中读取到 PGDATA: $PGDATA${NC}"
    fi
    
    # 从profile文件中查找
    for profile_file in "${PROFILE_FILES[@]}"; do
        if [[ -f "$profile_file" ]]; then
            # 查找PostgreSQL相关的环境变量
            if grep -q "PG_HOME\|POSTGRES_HOME\|PGDATA" "$profile_file" 2>/dev/null; then
                [[ "$QUIET_MODE" != "true" ]] && echo -e "${YELLOW}从 $profile_file 中读取PostgreSQL配置信息...${NC}"
                
                # 提取PG_HOME - 改进正则表达式
                local pghome=$(grep -E "export[[:space:]]+PGHOME[[:space:]]*=|export[[:space:]]+PG_HOME[[:space:]]*=|export[[:space:]]+POSTGRES_HOME[[:space:]]*=" "$profile_file" 2>/dev/null | head -1 | sed -E 's/.*=[[:space:]]*([^[:space:]]*).*/\1/' | sed 's/"//g' | sed "s/'//g")
                if [[ -n "$pghome" && -d "$pghome" ]]; then
                    DEFAULT_PG_HOME="$pghome"
                    # 如果PGHOME包含bin/postgres，则它也是安装目录
                    if [[ -f "$pghome/bin/postgres" ]]; then
                        DEFAULT_PG_INSTALL_DIR="$pghome"
                    fi
                    [[ "$QUIET_MODE" != "true" ]] && echo -e "${GREEN}找到有效的 PG_HOME: $pghome${NC}"
                fi
                
                # 提取PGDATA - 改进正则表达式
                local pgdata=$(grep -E "export[[:space:]]+PGDATA[[:space:]]*=" "$profile_file" 2>/dev/null | head -1 | sed -E 's/.*=[[:space:]]*([^[:space:]]*).*/\1/' | sed 's/"//g' | sed "s/'//g")
                if [[ -n "$pgdata" && -d "$pgdata" ]]; then
                    DEFAULT_PG_DATA_DIR="$pgdata"
                    [[ "$QUIET_MODE" != "true" ]] && echo -e "${GREEN}找到有效的 PGDATA: $pgdata${NC}"
                fi
                
                # 提取PATH中的PostgreSQL路径 - 改进逻辑
                local pg_path=$(grep -E "PATH.*postgres|PATH.*pgsql" "$profile_file" 2>/dev/null | head -1)
                if [[ -n "$pg_path" ]]; then
                    local install_dir=$(echo "$pg_path" | grep -oE '/[a-zA-Z0-9/_-]+postgresql[0-9.]*' | head -1)
                    if [[ -n "$install_dir" && -d "$install_dir" ]]; then
                        DEFAULT_PG_INSTALL_DIR="$install_dir"
                        [[ "$QUIET_MODE" != "true" ]] && echo -e "${GREEN}找到有效的安装目录: $install_dir${NC}"
                    fi
                fi
            fi
        fi
    done
    
    # 尝试从常见安装位置查找
    if [[ -z "$DEFAULT_PG_INSTALL_DIR" ]]; then
        for path in "${COMMON_PATHS[@]}"; do
            if [[ -d "$path" && -f "$path/bin/postgres" ]]; then
                DEFAULT_PG_INSTALL_DIR="$path"
                DEFAULT_PG_HOME="$path"
                [[ "$QUIET_MODE" != "true" ]] && echo -e "${GREEN}从常见位置找到PostgreSQL安装: $path${NC}"
                break
            fi
        done
    fi
    
    # 如果没有找到数据目录，设置默认值
    if [[ -z "$DEFAULT_PG_DATA_DIR" ]]; then
        if [[ -n "$DEFAULT_PG_HOME" ]]; then
            DEFAULT_PG_DATA_DIR="${DEFAULT_PG_HOME}/data"
        else
            DEFAULT_PG_DATA_DIR="/var/lib/pgsql/data"
        fi
        [[ "$QUIET_MODE" != "true" ]] && echo -e "${YELLOW}使用默认数据目录: $DEFAULT_PG_DATA_DIR${NC}"
    fi
    
    # 如果没有找到安装目录，设置默认值
    if [[ -z "$DEFAULT_PG_INSTALL_DIR" ]]; then
        if [[ -n "$DEFAULT_PG_HOME" ]]; then
            # 检查PG_HOME是否已经是完整的安装目录（包含bin/postgres）
            if [[ -f "$DEFAULT_PG_HOME/bin/postgres" ]]; then
                DEFAULT_PG_INSTALL_DIR="$DEFAULT_PG_HOME"
                [[ "$QUIET_MODE" != "true" ]] && echo -e "${GREEN}使用PG_HOME作为安装目录: $DEFAULT_PG_INSTALL_DIR${NC}"
            else
                DEFAULT_PG_INSTALL_DIR="${DEFAULT_PG_HOME}/postgresql-${DEFAULT_PG_VERSION}"
                [[ "$QUIET_MODE" != "true" ]] && echo -e "${YELLOW}使用默认安装目录: $DEFAULT_PG_INSTALL_DIR${NC}"
            fi
        else
            DEFAULT_PG_INSTALL_DIR="/usr/local/pgsql"
            [[ "$QUIET_MODE" != "true" ]] && echo -e "${YELLOW}使用默认安装目录: $DEFAULT_PG_INSTALL_DIR${NC}"
        fi
    fi
    
    # 如果没有找到PG_HOME，设置默认值
    if [[ -z "$DEFAULT_PG_HOME" ]]; then
        DEFAULT_PG_HOME="/usr/local/pgsql"
        [[ "$QUIET_MODE" != "true" ]] && echo -e "${YELLOW}使用默认PG_HOME: $DEFAULT_PG_HOME${NC}"
    fi
    
    # 恢复区域设置
    unset LC_ALL
}

# 用户输入确认函数
confirm_configuration() {
    # 初始化WAL参数变量
    MAX_WAL_SIZE="1GB"
    MIN_WAL_SIZE="80MB"
    CHECKPOINT_COMPLETION_TARGET="0.9"
    WAL_BUFFERS="16MB"
    WAL_WRITER_DELAY="200ms"
    COMMIT_DELAY="0"
    COMMIT_SIBLINGS="5"
    
    echo -e "${YELLOW}请确认PostgreSQL WAL归档配置:${NC}"
    echo -e "PostgreSQL版本: ${GREEN}$DEFAULT_PG_VERSION${NC}"
    echo -e "用户名: ${GREEN}$DEFAULT_PG_USER${NC}"
    echo -e "用户组: ${GREEN}$DEFAULT_PG_GROUP${NC}"
    echo -e "编译目录: ${GREEN}$DEFAULT_PG_INSTALL_DIR${NC}"
    echo -e "数据目录: ${GREEN}$DEFAULT_PG_DATA_DIR${NC}"
    echo -e "归档保留天数: ${GREEN}$DEFAULT_DAYS_TO_KEEP${NC}"
    echo ""
    
    read -p "是否使用自动检测的配置? [y/N]: " use_auto
    
    if [[ $use_auto =~ ^[Yy]$ ]]; then
        PG_VERSION=$DEFAULT_PG_VERSION
        PG_USER=$DEFAULT_PG_USER
        PG_GROUP=$DEFAULT_PG_GROUP
        PG_INSTALL_DIR=$DEFAULT_PG_INSTALL_DIR
        PG_DATA_DIR=$DEFAULT_PG_DATA_DIR
        DAYS_TO_KEEP=$DEFAULT_DAYS_TO_KEEP
        
        echo -e "${YELLOW}配置WAL参数（按Enter使用默认值，输入新值后按Enter确认）:${NC}"
        echo ""
        
        echo -e "max_wal_size [默认: 1GB]:"
        read input_max_wal_size
        MAX_WAL_SIZE=${input_max_wal_size:-"1GB"}
        echo -e "设置: ${GREEN}$MAX_WAL_SIZE${NC}"
        echo ""
        
        echo -e "min_wal_size [默认: 80MB]:"
        read input_min_wal_size
        MIN_WAL_SIZE=${input_min_wal_size:-"80MB"}
        echo -e "设置: ${GREEN}$MIN_WAL_SIZE${NC}"
        echo ""
        
        echo -e "checkpoint_completion_target [默认: 0.9]:"
        read input_checkpoint_target
        CHECKPOINT_COMPLETION_TARGET=${input_checkpoint_target:-"0.9"}
        echo -e "设置: ${GREEN}$CHECKPOINT_COMPLETION_TARGET${NC}"
        echo ""
        
        echo -e "wal_buffers [默认: 16MB]:"
        read input_wal_buffers
        WAL_BUFFERS=${input_wal_buffers:-"16MB"}
        echo -e "设置: ${GREEN}$WAL_BUFFERS${NC}"
        echo ""
        
        echo -e "wal_writer_delay [默认: 200ms]:"
        read input_wal_writer_delay
        WAL_WRITER_DELAY=${input_wal_writer_delay:-"200ms"}
        echo -e "设置: ${GREEN}$WAL_WRITER_DELAY${NC}"
        echo ""
        
        echo -e "commit_delay [默认: 0]:"
        read input_commit_delay
        COMMIT_DELAY=${input_commit_delay:-"0"}
        echo -e "设置: ${GREEN}$COMMIT_DELAY${NC}"
        echo ""
        
        echo -e "commit_siblings [默认: 5]:"
        read input_commit_siblings
        COMMIT_SIBLINGS=${input_commit_siblings:-"5"}
        echo -e "设置: ${GREEN}$COMMIT_SIBLINGS${NC}"
        echo ""
    else
        read -p "请输入PostgreSQL版本 [$DEFAULT_PG_VERSION]: " input_version
        PG_VERSION=${input_version:-$DEFAULT_PG_VERSION}
        
        read -p "请输入用户名 [$DEFAULT_PG_USER]: " input_user
        PG_USER=${input_user:-$DEFAULT_PG_USER}
        
        read -p "请输入用户组 [$DEFAULT_PG_GROUP]: " input_group
        PG_GROUP=${input_group:-$DEFAULT_PG_GROUP}
        
        read -p "请输入编译目录 [$DEFAULT_PG_INSTALL_DIR]: " input_install_dir
        PG_INSTALL_DIR=${input_install_dir:-$DEFAULT_PG_INSTALL_DIR}
        
        read -p "请输入数据目录 [$DEFAULT_PG_DATA_DIR]: " input_data_dir
        PG_DATA_DIR=${input_data_dir:-$DEFAULT_PG_DATA_DIR}
        
        read -p "请输入归档保留天数 [$DEFAULT_DAYS_TO_KEEP]: " input_days
        DAYS_TO_KEEP=${input_days:-$DEFAULT_DAYS_TO_KEEP}
        
        echo ""
        echo -e "${YELLOW}WAL参数配置（按Enter使用默认值，输入新值后按Enter确认）:${NC}"
        echo ""
        
        echo -e "max_wal_size [默认: 1GB]:"
        read input_max_wal_size
        MAX_WAL_SIZE=${input_max_wal_size:-"1GB"}
        echo -e "设置: ${GREEN}$MAX_WAL_SIZE${NC}"
        echo ""
        
        echo -e "min_wal_size [默认: 80MB]:"
        read input_min_wal_size
        MIN_WAL_SIZE=${input_min_wal_size:-"80MB"}
        echo -e "设置: ${GREEN}$MIN_WAL_SIZE${NC}"
        echo ""
        
        echo -e "checkpoint_completion_target [默认: 0.9]:"
        read input_checkpoint_target
        CHECKPOINT_COMPLETION_TARGET=${input_checkpoint_target:-"0.9"}
        echo -e "设置: ${GREEN}$CHECKPOINT_COMPLETION_TARGET${NC}"
        echo ""
        
        echo -e "wal_buffers [默认: 16MB]:"
        read input_wal_buffers
        WAL_BUFFERS=${input_wal_buffers:-"16MB"}
        echo -e "设置: ${GREEN}$WAL_BUFFERS${NC}"
        echo ""
        
        echo -e "wal_writer_delay [默认: 200ms]:"
        read input_wal_writer_delay
        WAL_WRITER_DELAY=${input_wal_writer_delay:-"200ms"}
        echo -e "设置: ${GREEN}$WAL_WRITER_DELAY${NC}"
        echo ""
        
        echo -e "commit_delay [默认: 0]:"
        read input_commit_delay
        COMMIT_DELAY=${input_commit_delay:-"0"}
        echo -e "设置: ${GREEN}$COMMIT_DELAY${NC}"
        echo ""
        
        echo -e "commit_siblings [默认: 5]:"
        read input_commit_siblings
        COMMIT_SIBLINGS=${input_commit_siblings:-"5"}
        echo -e "设置: ${GREEN}$COMMIT_SIBLINGS${NC}"
        echo ""
    fi
    
    # 计算归档目录（与数据目录同级）
    PG_ARCHIVE_DIR="$(dirname "$PG_DATA_DIR")/archive"
    
    echo ""
    echo -e "${GREEN}最终配置:${NC}"
    echo -e "PostgreSQL版本: $PG_VERSION"
    echo -e "用户名: $PG_USER"
    echo -e "用户组: $PG_GROUP"
    echo -e "编译目录: $PG_INSTALL_DIR"
    echo -e "数据目录: $PG_DATA_DIR"
    echo -e "归档目录: $PG_ARCHIVE_DIR"
    echo -e "归档保留天数: $DAYS_TO_KEEP"
    echo ""
    echo -e "${YELLOW}WAL参数:${NC}"
    echo -e "max_wal_size: ${GREEN}$MAX_WAL_SIZE${NC}"
    echo -e "min_wal_size: ${GREEN}$MIN_WAL_SIZE${NC}"
    echo -e "checkpoint_completion_target: ${GREEN}$CHECKPOINT_COMPLETION_TARGET${NC}"
    echo -e "wal_buffers: ${GREEN}$WAL_BUFFERS${NC}"
    echo -e "wal_writer_delay: ${GREEN}$WAL_WRITER_DELAY${NC}"
    echo -e "commit_delay: ${GREEN}$COMMIT_DELAY${NC}"
    echo -e "commit_siblings: ${GREEN}$COMMIT_SIBLINGS${NC}"
    echo ""
    
    read -p "确认开始配置? [y/N]: " confirm_config
    if [[ ! $confirm_config =~ ^[Yy]$ ]]; then
        echo -e "${RED}配置已取消${NC}"
        exit 0
    fi
}

# 检查是否为root用户（某些模式需要）
# 注意：这个检查将在main函数中根据具体模式进行

# 创建归档目录
create_archive_dir() {
    echo -e "${YELLOW}创建WAL归档目录...${NC}"
    
    # 验证父目录是否存在
    local parent_dir=$(dirname "$PG_ARCHIVE_DIR")
    if [[ ! -d "$parent_dir" ]]; then
        echo -e "${RED}错误: 父目录 $parent_dir 不存在${NC}"
        echo -e "${YELLOW}尝试创建父目录...${NC}"
        mkdir -p "$parent_dir"
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}无法创建父目录 $parent_dir${NC}"
            exit 1
        fi
    fi
    
    # 创建归档目录
    mkdir -p "$PG_ARCHIVE_DIR"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}无法创建归档目录 $PG_ARCHIVE_DIR${NC}"
        exit 1
    fi
    
    # 设置权限
    chown -R $PG_USER:$PG_GROUP "$PG_ARCHIVE_DIR"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}无法设置归档目录权限${NC}"
        exit 1
    fi
    
    chmod 700 "$PG_ARCHIVE_DIR"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}无法设置归档目录权限${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}WAL归档目录创建完成: $PG_ARCHIVE_DIR${NC}"
}

# 配置WAL归档
configure_wal_archive() {
    echo -e "${YELLOW}配置WAL归档...${NC}"
    
    # 验证数据目录是否存在
    if [[ ! -d "$PG_DATA_DIR" ]]; then
        echo -e "${RED}错误: 数据目录 $PG_DATA_DIR 不存在${NC}"
        exit 1
    fi
    
    # 验证配置文件是否存在
    if [[ ! -f "$PG_DATA_DIR/postgresql.conf" ]]; then
        echo -e "${RED}错误: 配置文件 $PG_DATA_DIR/postgresql.conf 不存在${NC}"
        exit 1
    fi
    
    # 验证归档目录路径是否有效
    if [[ -z "$PG_ARCHIVE_DIR" ]]; then
        echo -e "${RED}错误: 归档目录路径为空${NC}"
        exit 1
    fi
    
    # 验证安装目录中的pg_archivecleanup是否存在
    if [[ ! -f "$PG_INSTALL_DIR/bin/pg_archivecleanup" ]]; then
        echo -e "${RED}警告: $PG_INSTALL_DIR/bin/pg_archivecleanup 不存在，将跳过清理命令配置${NC}"
        PG_ARCHIVECLEANUP_CMD=""
    else
        PG_ARCHIVECLEANUP_CMD="archive_cleanup_command = '$PG_INSTALL_DIR/bin/pg_archivecleanup $PG_ARCHIVE_DIR %r'"
    fi
    
    # 备份原始配置文件
    cp "$PG_DATA_DIR/postgresql.conf" "$PG_DATA_DIR/postgresql.conf.backup.$(date +%Y%m%d_%H%M%S)"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}无法备份配置文件${NC}"
        exit 1
    fi
    
    # 修改postgresql.conf文件
    sed -i.bak "s/#wal_level = minimal/wal_level = replica/" "$PG_DATA_DIR/postgresql.conf"
    sed -i.bak "s/#archive_mode = off/archive_mode = on/" "$PG_DATA_DIR/postgresql.conf"
    sed -i.bak "s|#archive_command = ''|archive_command = 'cp %p $PG_ARCHIVE_DIR/%f'|" "$PG_DATA_DIR/postgresql.conf"
    
    # 如果pg_archivecleanup存在，添加清理命令
    if [[ -n "$PG_ARCHIVECLEANUP_CMD" ]]; then
        sed -i.bak "s|#archive_cleanup_command = ''|$PG_ARCHIVECLEANUP_CMD|" "$PG_DATA_DIR/postgresql.conf"
    fi
    
    echo -e "${YELLOW}正在配置WAL参数...${NC}"
    
    # 替换WAL配置参数
    echo -e "${YELLOW}设置 max_wal_size = $MAX_WAL_SIZE${NC}"
    sed -i.bak "s/^max_wal_size\s*=.*/max_wal_size = $MAX_WAL_SIZE/" "$PG_DATA_DIR/postgresql.conf" || {
        echo -e "${RED}错误: 无法设置 max_wal_size${NC}"
        echo "max_wal_size = $MAX_WAL_SIZE" >> "$PG_DATA_DIR/postgresql.conf"
    }
    
    echo -e "${YELLOW}设置 min_wal_size = $MIN_WAL_SIZE${NC}"
    sed -i.bak "s/^min_wal_size\s*=.*/min_wal_size = $MIN_WAL_SIZE/" "$PG_DATA_DIR/postgresql.conf" || {
        echo -e "${RED}错误: 无法设置 min_wal_size${NC}"
        echo "min_wal_size = $MIN_WAL_SIZE" >> "$PG_DATA_DIR/postgresql.conf"
    }
    
    echo -e "${YELLOW}设置 checkpoint_completion_target = $CHECKPOINT_COMPLETION_TARGET${NC}"
    sed -i.bak "s/^checkpoint_completion_target\s*=.*/checkpoint_completion_target = $CHECKPOINT_COMPLETION_TARGET/" "$PG_DATA_DIR/postgresql.conf" || {
        echo -e "${RED}错误: 无法设置 checkpoint_completion_target${NC}"
        echo "checkpoint_completion_target = $CHECKPOINT_COMPLETION_TARGET" >> "$PG_DATA_DIR/postgresql.conf"
    }
    
    echo -e "${YELLOW}设置 wal_buffers = $WAL_BUFFERS${NC}"
    sed -i.bak "s/^wal_buffers\s*=.*/wal_buffers = $WAL_BUFFERS/" "$PG_DATA_DIR/postgresql.conf" || {
        echo -e "${RED}错误: 无法设置 wal_buffers${NC}"
        echo "wal_buffers = $WAL_BUFFERS" >> "$PG_DATA_DIR/postgresql.conf"
    }
    
    echo -e "${YELLOW}设置 wal_writer_delay = $WAL_WRITER_DELAY${NC}"
    sed -i.bak "s/^wal_writer_delay\s*=.*/wal_writer_delay = $WAL_WRITER_DELAY/" "$PG_DATA_DIR/postgresql.conf" || {
        echo -e "${RED}错误: 无法设置 wal_writer_delay${NC}"
        echo "wal_writer_delay = $WAL_WRITER_DELAY" >> "$PG_DATA_DIR/postgresql.conf"
    }
    
    echo -e "${YELLOW}设置 commit_delay = $COMMIT_DELAY${NC}"
    sed -i.bak "s/^commit_delay\s*=.*/commit_delay = $COMMIT_DELAY/" "$PG_DATA_DIR/postgresql.conf" || {
        echo -e "${RED}错误: 无法设置 commit_delay${NC}"
        echo "commit_delay = $COMMIT_DELAY" >> "$PG_DATA_DIR/postgresql.conf"
    }
    
    echo -e "${YELLOW}设置 commit_siblings = $COMMIT_SIBLINGS${NC}"
    sed -i.bak "s/^commit_siblings\s*=.*/commit_siblings = $COMMIT_SIBLINGS/" "$PG_DATA_DIR/postgresql.conf" || {
        echo -e "${RED}错误: 无法设置 commit_siblings${NC}"
        echo "commit_siblings = $COMMIT_SIBLINGS" >> "$PG_DATA_DIR/postgresql.conf"
    }
    
    echo -e "${YELLOW}验证配置参数...${NC}"
    
    # 验证每个参数是否设置成功
    local verification_errors=0
    
    if grep -q "^max_wal_size\s*=\s*$MAX_WAL_SIZE" "$PG_DATA_DIR/postgresql.conf"; then
        echo -e "${GREEN}✓ max_wal_size 设置正确${NC}"
    else
        echo -e "${RED}✗ max_wal_size 设置失败${NC}"
        verification_errors=$((verification_errors + 1))
    fi
    
    if grep -q "^min_wal_size\s*=\s*$MIN_WAL_SIZE" "$PG_DATA_DIR/postgresql.conf"; then
        echo -e "${GREEN}✓ min_wal_size 设置正确${NC}"
    else
        echo -e "${RED}✗ min_wal_size 设置失败${NC}"
        verification_errors=$((verification_errors + 1))
    fi
    
    if grep -q "^checkpoint_completion_target\s*=\s*$CHECKPOINT_COMPLETION_TARGET" "$PG_DATA_DIR/postgresql.conf"; then
        echo -e "${GREEN}✓ checkpoint_completion_target 设置正确${NC}"
    else
        echo -e "${RED}✗ checkpoint_completion_target 设置失败${NC}"
        verification_errors=$((verification_errors + 1))
    fi
    
    if grep -q "^wal_buffers\s*=\s*$WAL_BUFFERS" "$PG_DATA_DIR/postgresql.conf"; then
        echo -e "${GREEN}✓ wal_buffers 设置正确${NC}"
    else
        echo -e "${RED}✗ wal_buffers 设置失败${NC}"
        verification_errors=$((verification_errors + 1))
    fi
    
    if grep -q "^wal_writer_delay\s*=\s*$WAL_WRITER_DELAY" "$PG_DATA_DIR/postgresql.conf"; then
        echo -e "${GREEN}✓ wal_writer_delay 设置正确${NC}"
    else
        echo -e "${RED}✗ wal_writer_delay 设置失败${NC}"
        verification_errors=$((verification_errors + 1))
    fi
    
    if grep -q "^commit_delay\s*=\s*$COMMIT_DELAY" "$PG_DATA_DIR/postgresql.conf"; then
        echo -e "${GREEN}✓ commit_delay 设置正确${NC}"
    else
        echo -e "${RED}✗ commit_delay 设置失败${NC}"
        verification_errors=$((verification_errors + 1))
    fi
    
    if grep -q "^commit_siblings\s*=\s*$COMMIT_SIBLINGS" "$PG_DATA_DIR/postgresql.conf"; then
        echo -e "${GREEN}✓ commit_siblings 设置正确${NC}"
    else
        echo -e "${RED}✗ commit_siblings 设置失败${NC}"
        verification_errors=$((verification_errors + 1))
    fi
    
    # 添加WAL配置
    cat >> "$PG_DATA_DIR/postgresql.conf" << EOF

# WAL Archive Settings
max_wal_size = 1GB
min_wal_size = 80MB
checkpoint_completion_target = 0.9
wal_buffers = 16MB
wal_writer_delay = 200ms
commit_delay = 0
commit_siblings = 5
EOF
    
    # 验证配置文件语法
    echo -e "${YELLOW}验证配置文件语法...${NC}"
    if [[ -f "$PG_INSTALL_DIR/bin/postgres" ]]; then
        # 使用postgres命令验证配置文件语法
        local syntax_output=$(su - $PG_USER -c "$PG_INSTALL_DIR/bin/postgres -t -c config_file=$PG_DATA_DIR/postgresql.conf" 2>&1)
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}✓ 配置文件语法验证通过${NC}"
        else
            echo -e "${RED}✗ 配置文件语法验证失败${NC}"
            echo -e "${RED}错误信息: $syntax_output${NC}"
            verification_errors=$((verification_errors + 1))
        fi
    else
        echo -e "${YELLOW}警告: 无法找到postgres命令，跳过语法验证${NC}"
    fi
    
    # 显示配置结果
    if [[ $verification_errors -eq 0 ]]; then
        echo -e "${GREEN}=====================================${NC}"
        echo -e "${GREEN}WAL归档配置完成! 所有参数设置成功${NC}"
        echo -e "${GREEN}=====================================${NC}"
    else
        echo -e "${RED}=====================================${NC}"
        echo -e "${RED}WAL归档配置完成，但发现 $verification_errors 个错误${NC}"
        echo -e "${RED}请检查配置文件: $PG_DATA_DIR/postgresql.conf${NC}"
        echo -e "${RED}=====================================${NC}"
    fi
}

# 重启PostgreSQL服务
restart_postgresql() {
    echo -e "${YELLOW}重启PostgreSQL服务...${NC}"
    
    systemctl restart postgresql${PG_VERSION%.*}
    
    # 检查服务状态
    if systemctl is-active --quiet postgresql${PG_VERSION%.*}; then
        echo -e "${GREEN}PostgreSQL服务重启成功!${NC}"
    else
        echo -e "${RED}PostgreSQL服务重启失败!${NC}"
        exit 1
    fi
}

# 验证WAL归档
verify_wal_archive() {
    echo -e "${YELLOW}验证WAL归档配置...${NC}"
    
    # 验证PostgreSQL服务是否运行
    if ! systemctl is-active --quiet postgresql${PG_VERSION%.*} 2>/dev/null; then
        echo -e "${RED}错误: PostgreSQL服务未运行${NC}"
        return 1
    fi
    
    # 验证归档目录是否存在
    if [[ ! -d "$PG_ARCHIVE_DIR" ]]; then
        echo -e "${RED}错误: 归档目录 $PG_ARCHIVE_DIR 不存在${NC}"
        return 1
    fi
    
    # 验证归档配置是否生效
    echo -e "${YELLOW}检查归档配置状态...${NC}"
    
    # 检查postgresql.conf中的归档配置
    local archive_mode=$(grep "^archive_mode\s*=" "$PG_DATA_DIR/postgresql.conf" | awk '{print $3}')
    local archive_command=$(grep "^archive_command\s*=" "$PG_DATA_DIR/postgresql.conf" | sed 's/.*=//' | sed 's/"//g')
    
    if [[ "$archive_mode" == "on" ]]; then
        echo -e "${GREEN}✓ 归档模式已启用${NC}"
    else
        echo -e "${RED}✗ 归档模式未启用${NC}"
        return 1
    fi
    
    if [[ -n "$archive_command" ]]; then
        echo -e "${GREEN}✓ 归档命令已配置${NC}"
    else
        echo -e "${RED}✗ 归档命令未配置${NC}"
        return 1
    fi
    
    # 检查归档目录权限
    local archive_perms=$(stat -c "%a:%U:%G" "$PG_ARCHIVE_DIR" 2>/dev/null)
    if [[ "$archive_perms" == "700:$PG_USER:$PG_GROUP" ]]; then
        echo -e "${GREEN}✓ 归档目录权限正确${NC}"
    else
        echo -e "${YELLOW}警告: 归档目录权限可能不正确${NC}"
    fi
    
    echo -e "${GREEN}归档配置验证完成!${NC}"
    echo -e "${YELLOW}注意: 归档文件将在下次WAL切换时自动生成${NC}"
    echo -e "${YELLOW}如需立即测试归档功能，可运行: $0 test${NC}"
}

# 创建WAL清理脚本
create_cleanup_script() {
    echo -e "${YELLOW}创建WAL清理脚本...${NC}"
    
    cat > $PG_HOME/cleanup_wal.sh << EOF
#!/bin/bash

# WAL归档清理脚本
# 保留最近${DAYS_TO_KEEP}天的WAL文件

# 设置区域环境变量，避免locale警告
export LC_ALL=C
export LANG=C

PG_ARCHIVE_DIR="$PG_ARCHIVE_DIR"
DAYS_TO_KEEP=$DAYS_TO_KEEP

# 删除超过指定天数的WAL文件
find \$PG_ARCHIVE_DIR -name "*.gz" -type f -mtime +\$DAYS_TO_KEEP -delete
find \$PG_ARCHIVE_DIR -name "*.backup" -type f -mtime +\$DAYS_TO_KEEP -delete

echo "WAL清理完成，保留最近 \$DAYS_TO_KEEP 天的文件"
EOF
    
    chmod +x $PG_HOME/cleanup_wal.sh
    chown $PG_USER:$PG_GROUP $PG_HOME/cleanup_wal.sh
    
    echo -e "${GREEN}WAL清理脚本创建完成: $PG_HOME/cleanup_wal.sh${NC}"
}

# 设置定时清理任务
setup_cron_job() {
    echo -e "${YELLOW}设置WAL清理定时任务...${NC}"
    
    # 为postgres用户设置cron任务
    if [[ $EUID -eq 0 ]]; then
        # 如果是root用户，使用su切换到postgres用户
        su - $PG_USER -c "crontab -l" > /tmp/postgres_cron.txt 2>/dev/null || touch /tmp/postgres_cron.txt
    else
        # 如果不是root用户，直接执行
        crontab -l > /tmp/postgres_cron.txt 2>/dev/null || touch /tmp/postgres_cron.txt
    fi
    
    # 检查是否已存在清理任务
    if ! grep -q "cleanup_wal.sh" /tmp/postgres_cron.txt 2>/dev/null; then
        # 添加每天凌晨2点执行清理任务，包含区域设置
        echo "0 2 * * * LC_ALL=C LANG=C $PG_HOME/cleanup_wal.sh >> $PG_HOME/cleanup_wal.log 2>&1" >> /tmp/postgres_cron.txt
        
        # 安装新的crontab
        if [[ $EUID -eq 0 ]]; then
            su - $PG_USER -c "crontab /tmp/postgres_cron.txt"
        else
            crontab /tmp/postgres_cron.txt
        fi
        
        echo -e "${GREEN}WAL清理定时任务设置完成!${NC}"
    else
        echo -e "${YELLOW}WAL清理定时任务已存在${NC}"
    fi
    
    rm -f /tmp/postgres_cron.txt
}

# 显示归档信息
show_archive_info() {
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}WAL归档配置完成!${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo -e "归档目录: $PG_ARCHIVE_DIR"
    echo -e "清理脚本: $PG_HOME/cleanup_wal.sh"
    echo -e "清理日志: $PG_HOME/cleanup_wal.log"
    echo -e ""
    echo -e "手动清理命令:"
    echo -e "sudo -u $PG_USER $PG_HOME/cleanup_wal.sh"
    echo -e ""
    echo -e "查看cron任务:"
    echo -e "sudo -u $PG_USER crontab -l"
    echo -e ""
    echo -e "查看归档文件:"
    echo -e "ls -la $PG_ARCHIVE_DIR"
    echo -e "${GREEN}=====================================${NC}"
}

# 手动清理模式
manual_cleanup() {
    [[ "$QUIET_MODE" != "true" ]] && echo -e "${BLUE}=== 手动清理模式 ===${NC}"
    
    # 验证基本配置
    if ! validate_pg_config; then
        echo -e "${RED}配置验证失败，无法进行清理${NC}"
        exit 1
    fi
    
    # 获取最新的检查点信息
    local redo_wal_file=""
    if [[ -f "$PG_INSTALL_DIR/bin/pg_controldata" ]]; then
        redo_wal_file=$($PG_INSTALL_DIR/bin/pg_controldata "$PG_DATA_DIR" 2>/dev/null | grep "Latest checkpoint's REDO WAL file" | awk '{print $6}')
        [[ "$QUIET_MODE" != "true" ]] && echo -e "${YELLOW}最新检查点WAL文件: $redo_wal_file${NC}"
    fi
    
    # 查找可以删除的文件
    local old_files=""
    if [[ -n "$redo_wal_file" ]]; then
        # 使用pg_archivecleanup清理
        [[ "$QUIET_MODE" != "true" ]] && echo -e "${YELLOW}使用pg_archivecleanup清理旧WAL文件...${NC}"
        
        if [[ -f "$PG_INSTALL_DIR/bin/pg_archivecleanup" ]]; then
            if [[ "$FORCE_MODE" == "true" ]]; then
                $PG_INSTALL_DIR/bin/pg_archivecleanup -d "$PG_ARCHIVE_DIR" "$redo_wal_file"
            else
                echo -e "${YELLOW}将要删除以下文件之前的所有WAL文件: $redo_wal_file${NC}"
                read -p "确认执行? [y/N]: " confirm
                if [[ $confirm =~ ^[Yy]$ ]]; then
                    $PG_INSTALL_DIR/bin/pg_archivecleanup -d "$PG_ARCHIVE_DIR" "$redo_wal_file"
                else
                    echo -e "${YELLOW}操作已取消${NC}"
                    return 0
                fi
            fi
        else
            echo -e "${RED}错误: pg_archivecleanup工具不存在${NC}"
            return 1
        fi
    else
        # 按时间清理
        [[ "$QUIET_MODE" != "true" ]] && echo -e "${YELLOW}按时间清理${DAYS_TO_KEEP}天前的WAL文件...${NC}"
        
        old_files=$(find "$PG_ARCHIVE_DIR" -type f -name "*.gz" -o -name "*.backup" -o -name "000*" -mtime +$DAYS_TO_KEEP 2>/dev/null)
        
        if [[ -n "$old_files" ]]; then
            if [[ "$FORCE_MODE" == "true" ]]; then
                find "$PG_ARCHIVE_DIR" -type f -name "*.gz" -o -name "*.backup" -o -name "000*" -mtime +$DAYS_TO_KEEP -delete 2>/dev/null
            else
                echo -e "${YELLOW}将要删除以下文件:${NC}"
                echo "$old_files"
                read -p "确认删除? [y/N]: " confirm
                if [[ $confirm =~ ^[Yy]$ ]]; then
                    find "$PG_ARCHIVE_DIR" -type f -name "*.gz" -o -name "*.backup" -o -name "000*" -mtime +$DAYS_TO_KEEP -delete 2>/dev/null
                else
                    echo -e "${YELLOW}操作已取消${NC}"
                    return 0
                fi
            fi
        else
            [[ "$QUIET_MODE" != "true" ]] && echo -e "${GREEN}没有找到需要清理的文件${NC}"
        fi
    fi
    
    [[ "$QUIET_MODE" != "true" ]] && echo -e "${GREEN}手动清理完成${NC}"
}

# 自动清理模式配置
auto_cleanup_config() {
    [[ "$QUIET_MODE" != "true" ]] && echo -e "${BLUE}=== 自动清理模式配置 ===${NC}"
    
    # 验证基本配置
    if ! validate_pg_config; then
        echo -e "${RED}配置验证失败，无法进行配置${NC}"
        exit 1
    fi
    
    # 验证pg_archivecleanup
    if [[ ! -f "$PG_INSTALL_DIR/bin/pg_archivecleanup" ]]; then
        echo -e "${RED}错误: pg_archivecleanup工具不存在: $PG_INSTALL_DIR/bin/pg_archivecleanup${NC}"
        return 1
    fi
    
    # 备份配置文件
    cp "$PG_DATA_DIR/postgresql.conf" "$PG_DATA_DIR/postgresql.conf.backup.$(date +%Y%m%d_%H%M%S)"
    
    # 配置归档参数
    sed -i.bak "s/#wal_level = minimal/wal_level = replica/" "$PG_DATA_DIR/postgresql.conf"
    sed -i.bak "s/#archive_mode = off/archive_mode = on/" "$PG_DATA_DIR/postgresql.conf"
    sed -i.bak "s|#archive_command = ''|archive_command = 'cp %p $PG_ARCHIVE_DIR/%f'|" "$PG_DATA_DIR/postgresql.conf"
    sed -i.bak "s|#archive_cleanup_command = ''|archive_cleanup_command = '$PG_INSTALL_DIR/bin/pg_archivecleanup $PG_ARCHIVE_DIR %r'|" "$PG_DATA_DIR/postgresql.conf"
    
    # 添加WAL配置
    cat >> "$PG_DATA_DIR/postgresql.conf" << EOF

# WAL Archive Settings (自动清理模式)
max_wal_size = 1GB
min_wal_size = 80MB
checkpoint_completion_target = 0.9
wal_buffers = 16MB
wal_writer_delay = 200ms
archive_timeout = 30min
EOF
    
    [[ "$QUIET_MODE" != "true" ]] && echo -e "${GREEN}自动清理模式配置完成${NC}"
    
    # 重启PostgreSQL服务
    if [[ "$FORCE_MODE" == "true" ]]; then
        systemctl restart postgresql${PG_VERSION%.*}
        [[ "$QUIET_MODE" != "true" ]] && echo -e "${GREEN}PostgreSQL服务已重启${NC}"
    else
        read -p "是否重启PostgreSQL服务以应用配置? [y/N]: " confirm
        if [[ $confirm =~ ^[Yy]$ ]]; then
            systemctl restart postgresql${PG_VERSION%.*}
            [[ "$QUIET_MODE" != "true" ]] && echo -e "${GREEN}PostgreSQL服务已重启${NC}"
        else
            echo -e "${YELLOW}请手动重启PostgreSQL服务以应用配置${NC}"
        fi
    fi
}

# 定时清理模式配置
cron_cleanup_config() {
    [[ "$QUIET_MODE" != "true" ]] && echo -e "${BLUE}=== 定时清理模式配置 ===${NC}"
    
    # 验证基本配置
    if ! validate_pg_config; then
        echo -e "${RED}配置验证失败，无法进行配置${NC}"
        exit 1
    fi
    
    # 创建清理脚本
    local cleanup_script="$PG_HOME/wal_cleanup.sh"
    
    cat > "$cleanup_script" << EOF
#!/bin/bash

# PostgreSQL WAL归档定时清理脚本
# 保留最近${DAYS_TO_KEEP}天的WAL文件

# 设置区域环境变量，避免locale警告
export LC_ALL=C
export LANG=C

PG_ARCHIVE_DIR="$PG_ARCHIVE_DIR"
DAYS_TO_KEEP=$DAYS_TO_KEEP
TIME="\$(date +%Y-%m-%d-%H-%M)"

echo "开始清理WAL归档文件 - \$TIME"

# 检查归档目录是否存在
if [[ ! -d "\$PG_ARCHIVE_DIR" ]]; then
    echo "错误: 归档目录不存在: \$PG_ARCHIVE_DIR"
    exit 1
fi

# 查找可以删除的文件
old_files=\$(find "\$PG_ARCHIVE_DIR" -type f -name "*.gz" -o -name "*.backup" -o -name "000*" -mtime +\$DAYS_TO_KEEP 2>/dev/null)

if [[ -n "\$old_files" ]]; then
    echo "找到 \$(echo "\$old_files" | wc -l) 个文件需要清理"
    find "\$PG_ARCHIVE_DIR" -type f -name "*.gz" -o -name "*.backup" -o -name "000*" -mtime +\$DAYS_TO_KEEP -delete 2>/dev/null
    echo "清理完成"
else
    echo "没有找到需要清理的文件"
fi

echo "WAL清理完成 - \$TIME"
EOF
    
    chmod +x "$cleanup_script"
    chown $PG_USER:$PG_GROUP "$cleanup_script"
    
    [[ "$QUIET_MODE" != "true" ]] && echo -e "${GREEN}清理脚本创建完成: $cleanup_script${NC}"
    
    # 设置cron任务
    if [[ $EUID -eq 0 ]]; then
        su - $PG_USER -c "crontab -l" > /tmp/postgres_cron.txt 2>/dev/null || touch /tmp/postgres_cron.txt
    else
        crontab -l > /tmp/postgres_cron.txt 2>/dev/null || touch /tmp/postgres_cron.txt
    fi
    
    # 检查是否已存在清理任务
    if ! grep -q "wal_cleanup.sh" /tmp/postgres_cron.txt 2>/dev/null; then
        # 添加每周日凌晨2点执行清理任务
        echo "0 2 * * 0 LC_ALL=C LANG=C $cleanup_script >> $PG_HOME/wal_cleanup.log 2>&1" >> /tmp/postgres_cron.txt
        
        # 安装新的crontab
        if [[ $EUID -eq 0 ]]; then
            su - $PG_USER -c "crontab /tmp/postgres_cron.txt"
        else
            crontab /tmp/postgres_cron.txt
        fi
        
        [[ "$QUIET_MODE" != "true" ]] && echo -e "${GREEN}定时清理任务设置完成（每周日凌晨2点执行）${NC}"
    else
        [[ "$QUIET_MODE" != "true" ]] && echo -e "${YELLOW}定时清理任务已存在${NC}"
    fi
    
    rm -f /tmp/postgres_cron.txt
}

# 智能清理模式
smart_cleanup() {
    [[ "$QUIET_MODE" != "true" ]] && echo -e "${BLUE}=== 智能清理模式 ===${NC}"
    
    # 验证基本配置
    if ! validate_pg_config; then
        echo -e "${RED}配置验证失败，无法进行清理${NC}"
        exit 1
    fi
    
    # 获取最新的检查点信息
    local redo_wal_file=""
    if [[ -f "$PG_INSTALL_DIR/bin/pg_controldata" ]]; then
        redo_wal_file=$($PG_INSTALL_DIR/bin/pg_controldata "$PG_DATA_DIR" 2>/dev/null | grep "Latest checkpoint's REDO WAL file" | awk '{print $6}')
        [[ "$QUIET_MODE" != "true" ]] && echo -e "${YELLOW}最新检查点WAL文件: $redo_wal_file${NC}"
    fi
    
    if [[ -z "$redo_wal_file" ]]; then
        echo -e "${RED}错误: 无法获取最新检查点信息${NC}"
        return 1
    fi
    
    # 查找15天之前的所有日志，判断是否存在未完成归档日志
    local old_files=$(find "$PG_ARCHIVE_DIR" -type f -name "000*" -mtime +15 2>/dev/null | grep "$redo_wal_file")
    
    if [[ -n "$old_files" ]]; then
        echo -e "${RED}存在未完成归档的日志，不能删除${NC}"
        echo "$old_files"
        return 1
    else
        # 清理15天以前的归档日志
        [[ "$QUIET_MODE" != "true" ]] && echo -e "${YELLOW}清理15天前的归档日志...${NC}"
        
        local files_to_delete=$(find "$PG_ARCHIVE_DIR" -type f -name "000*" -mtime +15 2>/dev/null)
        
        if [[ -n "$files_to_delete" ]]; then
            if [[ "$FORCE_MODE" == "true" ]]; then
                find "$PG_ARCHIVE_DIR" -type f -name "000*" -mtime +15 -delete 2>/dev/null
                [[ "$QUIET_MODE" != "true" ]] && echo -e "${GREEN}智能清理完成，删除了$(echo "$files_to_delete" | wc -l)个文件${NC}"
            else
                echo -e "${YELLOW}将要删除以下文件:${NC}"
                echo "$files_to_delete"
                read -p "确认删除? [y/N]: " confirm
                if [[ $confirm =~ ^[Yy]$ ]]; then
                    find "$PG_ARCHIVE_DIR" -type f -name "000*" -mtime +15 -delete 2>/dev/null
                    echo -e "${GREEN}智能清理完成${NC}"
                else
                    echo -e "${YELLOW}操作已取消${NC}"
                    return 0
                fi
            fi
        else
            [[ "$QUIET_MODE" != "true" ]] && echo -e "${GREEN}没有找到需要清理的文件${NC}"
        fi
    fi
    
    [[ "$QUIET_MODE" != "true" ]] && echo -e "${GREEN}智能清理完成${NC}"
}

# 显示当前归档状态
show_archive_status() {
    [[ "$QUIET_MODE" != "true" ]] && echo -e "${BLUE}=== PostgreSQL WAL归档状态 ===${NC}"
    
    # 验证基本配置
    if ! validate_pg_config; then
        echo -e "${RED}配置验证失败${NC}"
        exit 1
    fi
    
    # 检查PostgreSQL服务状态
    if systemctl is-active --quiet postgresql${PG_VERSION%.*} 2>/dev/null; then
        echo -e "PostgreSQL服务状态: ${GREEN}运行中${NC}"
    else
        echo -e "PostgreSQL服务状态: ${RED}未运行${NC}"
    fi
    
    # 检查归档配置
    if [[ -f "$PG_DATA_DIR/postgresql.conf" ]]; then
        local wal_level=$(grep -E "^wal_level\s*=" "$PG_DATA_DIR/postgresql.conf" | awk '{print $3}')
        local archive_mode=$(grep -E "^archive_mode\s*=" "$PG_DATA_DIR/postgresql.conf" | awk '{print $3}')
        local archive_command=$(grep -E "^archive_command\s*=" "$PG_DATA_DIR/postgresql.conf" | cut -d'"' -f2)
        local archive_cleanup_command=$(grep -E "^archive_cleanup_command\s*=" "$PG_DATA_DIR/postgresql.conf" | cut -d'"' -f2)
        
        echo -e "WAL级别: ${GREEN}${wal_level:-未设置}${NC}"
        echo -e "归档模式: ${GREEN}${archive_mode:-未设置}${NC}"
        echo -e "归档命令: ${GREEN}${archive_command:-未设置}${NC}"
        echo -e "清理命令: ${GREEN}${archive_cleanup_command:-未设置}${NC}"
    fi
    
    # 检查归档目录
    if [[ -n "$PG_ARCHIVE_DIR" && -d "$PG_ARCHIVE_DIR" ]]; then
        local file_count=$(find "$PG_ARCHIVE_DIR" -type f 2>/dev/null | wc -l)
        local dir_size=$(du -sh "$PG_ARCHIVE_DIR" 2>/dev/null | awk '{print $1}')
        echo -e "归档目录: ${GREEN}$PG_ARCHIVE_DIR${NC}"
        echo -e "归档文件数量: ${GREEN}$file_count${NC}"
        echo -e "归档目录大小: ${GREEN}$dir_size${NC}"
    else
        echo -e "归档目录: ${RED}未设置或不存在${NC}"
    fi
    
    # 检查最新的检查点信息
    if [[ -f "$PG_INSTALL_DIR/bin/pg_controldata" ]]; then
        local redo_wal_file=$($PG_INSTALL_DIR/bin/pg_controldata "$PG_DATA_DIR" 2>/dev/null | grep "Latest checkpoint's REDO WAL file" | awk '{print $6}')
        if [[ -n "$redo_wal_file" ]]; then
            echo -e "最新检查点WAL文件: ${GREEN}$redo_wal_file${NC}"
        fi
    fi
    
    # 检查cron任务
    if [[ $EUID -eq 0 ]]; then
        local cron_jobs=$(su - $PG_USER -c "crontab -l" 2>/dev/null | grep -v "^#" | grep -v "^$" || echo "无定时任务")
        echo -e "定时清理任务: ${GREEN}$cron_jobs${NC}"
    fi
}

# 测试归档配置
test_archive_config() {
    [[ "$QUIET_MODE" != "true" ]] && echo -e "${BLUE}=== 测试归档配置 ===${NC}"
    
    # 验证基本配置
    if ! validate_pg_config; then
        echo -e "${RED}配置验证失败，无法进行测试${NC}"
        exit 1
    fi
    
    # 验证PostgreSQL服务状态
    if ! systemctl is-active --quiet postgresql${PG_VERSION%.*} 2>/dev/null; then
        echo -e "${RED}错误: PostgreSQL服务未运行${NC}"
        exit 1
    fi
    
    # 验证归档目录是否存在
    if [[ ! -d "$PG_ARCHIVE_DIR" ]]; then
        echo -e "${RED}错误: 归档目录 $PG_ARCHIVE_DIR 不存在${NC}"
        exit 1
    fi
    
    [[ "$QUIET_MODE" != "true" ]] && echo -e "${YELLOW}开始测试WAL归档功能...${NC}"
    
    # 记录测试前的文件数量
    local files_before=$(find "$PG_ARCHIVE_DIR" -type f 2>/dev/null | wc -l)
    [[ "$QUIET_MODE" != "true" ]] && echo -e "${YELLOW}测试前归档文件数量: $files_before${NC}"
    
    # 设置超时时间（秒）
    local timeout=30
    local wal_switch_result=0
    
    # 强制切换WAL文件，使用安全的psql命令
    [[ "$QUIET_MODE" != "true" ]] && echo -e "${YELLOW}尝试切换WAL文件（超时: ${timeout}秒）...${NC}"
    
    # 使用safe_psql函数执行WAL切换
    local switch_result
    switch_result=$(safe_psql "SELECT pg_switch_wal();" $timeout "$QUIET_MODE")
    wal_switch_result=$?
    
    # 检查WAL切换结果
    if [[ $wal_switch_result -eq 124 ]]; then
        echo -e "${RED}WAL切换超时（${timeout}秒），可能是权限问题或PostgreSQL响应缓慢${NC}"
        echo -e "${YELLOW}尝试其他测试方法...${NC}"
        
        # 尝试使用pg_ctl reload代替
        if [[ -f "$PG_INSTALL_DIR/bin/pg_ctl" ]]; then
            [[ "$QUIET_MODE" != "true" ]] && echo -e "${YELLOW}尝试重新加载PostgreSQL配置...${NC}"
            if [[ $EUID -eq 0 ]]; then
                su - $PG_USER -c "$PG_INSTALL_DIR/bin/pg_ctl reload -D $PG_DATA_DIR" 2>/dev/null
            else
                $PG_INSTALL_DIR/bin/pg_ctl reload -D $PG_DATA_DIR 2>/dev/null
            fi
        fi
    elif [[ $wal_switch_result -ne 0 ]]; then
        echo -e "${RED}无法切换WAL文件，错误代码: $wal_switch_result${NC}"
        echo -e "${YELLOW}可能的原因:${NC}"
        echo -e "1. PostgreSQL用户权限不足"
        echo -e "2. 归档配置不正确"
        echo -e "3. 归档目录权限问题"
        
        # 检查PostgreSQL连接
        [[ "$QUIET_MODE" != "true" ]] && echo -e "${YELLOW}检查PostgreSQL连接...${NC}"
        
        local version_result
        version_result=$(safe_psql "SELECT version();" 10 "$QUIET_MODE")
        local version_result_code=$?
        
        if [[ $version_result_code -ne 0 ]]; then
            echo -e "${RED}无法连接到PostgreSQL，请检查服务状态和权限${NC}"
        else
            echo -e "${GREEN}PostgreSQL连接正常，可能是归档配置问题${NC}"
            [[ "$QUIET_MODE" != "true" ]] && echo -e "${YELLOW}PostgreSQL版本: $version_result${NC}"
        fi
        exit 1
    else
        echo -e "${GREEN}WAL文件切换成功${NC}"
    fi
    
    # 等待几秒钟让归档完成
    [[ "$QUIET_MODE" != "true" ]] && echo -e "${YELLOW}等待WAL归档完成...${NC}"
    sleep 10
    
    # 检查归档目录中是否有新文件
    local files_after=$(find "$PG_ARCHIVE_DIR" -type f 2>/dev/null | wc -l)
    local recent_files=$(find "$PG_ARCHIVE_DIR" -type f -mmin -10 2>/dev/null | wc -l)
    
    if [[ $files_after -gt $files_before ]]; then
        local new_files=$((files_after - files_before))
        echo -e "${GREEN}归档测试成功! 找到 $new_files 个新归档文件${NC}"
        echo -e "${GREEN}归档目录: $PG_ARCHIVE_DIR${NC}"
        echo -e "${GREEN}测试前文件数: $files_before, 测试后文件数: $files_after${NC}"
        echo -e "${GREEN}最新归档文件:${NC}"
        ls -lt "$PG_ARCHIVE_DIR" | head -5
    else
        echo -e "${YELLOW}归档测试可能失败，未找到新归档文件${NC}"
        echo -e "${YELLOW}测试前文件数: $files_before, 测试后文件数: $files_after${NC}"
        echo -e "${YELLOW}归档目录: $PG_ARCHIVE_DIR${NC}"
        echo -e "${YELLOW}当前归档文件列表:${NC}"
        ls -la "$PG_ARCHIVE_DIR" 2>/dev/null || echo "目录为空或无法访问"
        
        # 检查PostgreSQL日志以获取更多信息
        [[ "$QUIET_MODE" != "true" ]] && echo -e "${YELLOW}检查PostgreSQL日志以获取更多信息...${NC}"
        local log_file=$(find "$PG_DATA_DIR" -name "*.log" | head -1)
        if [[ -f "$log_file" ]]; then
            echo -e "${YELLOW}最近的日志条目:${NC}"
            tail -20 "$log_file" | grep -i -E "(archive|wal|error)" || echo "未找到归档相关日志"
        fi
        
        # 检查归档配置
        [[ "$QUIET_MODE" != "true" ]] && echo -e "${YELLOW}检查归档配置...${NC}"
        local archive_mode=$(grep -E "^archive_mode\s*=" "$PG_DATA_DIR/postgresql.conf" | awk '{print $3}')
        local archive_command=$(grep -E "^archive_command\s*=" "$PG_DATA_DIR/postgresql.conf" | cut -d"'" -f2)
        
        echo -e "归档模式: ${GREEN}${archive_mode:-未设置}${NC}"
        echo -e "归档命令: ${GREEN}${archive_command:-未设置}${NC}"
        
        # 提供故障排除建议
        echo -e "${YELLOW}故障排除建议:${NC}"
        echo -e "1. 检查archive_mode是否设置为'on'"
        echo -e "2. 检查archive_command是否正确配置"
        echo -e "3. 检查归档目录权限是否正确（700，postgres:postgres）"
        echo -e "4. 检查PostgreSQL服务状态"
        echo -e "5. 尝试手动执行归档命令测试"
    fi
}

# 验证PostgreSQL配置
validate_pg_config() {
    [[ "$QUIET_MODE" != "true" ]] && echo -e "${YELLOW}验证PostgreSQL配置...${NC}"
    
    # 检查PostgreSQL安装目录
    if [[ ! -d "$PG_INSTALL_DIR" ]]; then
        echo -e "${RED}错误: PostgreSQL安装目录不存在: $PG_INSTALL_DIR${NC}"
        return 1
    fi
    
    # 检查PostgreSQL二进制文件
    if [[ ! -f "$PG_INSTALL_DIR/bin/postgres" ]]; then
        echo -e "${RED}错误: PostgreSQL二进制文件不存在: $PG_INSTALL_DIR/bin/postgres${NC}"
        return 1
    fi
    
    # 检查数据目录
    if [[ ! -d "$PG_DATA_DIR" ]]; then
        echo -e "${RED}错误: PostgreSQL数据目录不存在: $PG_DATA_DIR${NC}"
        return 1
    fi
    
    # 检查配置文件
    if [[ ! -f "$PG_DATA_DIR/postgresql.conf" ]]; then
        echo -e "${RED}错误: PostgreSQL配置文件不存在: $PG_DATA_DIR/postgresql.conf${NC}"
        return 1
    fi
    
    # 检查PostgreSQL用户权限
    if [[ $EUID -eq 0 ]]; then
        # 如果是root用户，检查是否能切换到postgres用户
        if ! id -u $PG_USER >/dev/null 2>&1; then
            echo -e "${RED}错误: PostgreSQL用户 $PG_USER 不存在${NC}"
            return 1
        fi
        
        # 测试postgres用户是否能访问数据目录
        if ! su - $PG_USER -c "test -r $PG_DATA_DIR/postgresql.conf" 2>/dev/null; then
            echo -e "${RED}错误: PostgreSQL用户 $PG_USER 无法访问数据目录${NC}"
            return 1
        fi
    fi
    
    # 检查PostgreSQL服务状态
    if ! systemctl is-active --quiet postgresql${PG_VERSION%.*} 2>/dev/null; then
        echo -e "${YELLOW}警告: PostgreSQL服务未运行${NC}"
        # 不返回错误，因为某些测试可能不需要服务运行
    fi
    
    [[ "$QUIET_MODE" != "true" ]] && echo -e "${GREEN}PostgreSQL配置验证通过${NC}"
    return 0
}

# 安全执行psql命令，避免卡住
safe_psql() {
    local sql_command="$1"
    local timeout_duration="${2:-30}"  # 默认超时30秒
    local quiet_mode="$3"
    
    # 构建完整的命令
    local cmd="psql -t -c \"$sql_command\""
    
    # 如果是root用户，需要切换到postgres用户
    if [[ $EUID -eq 0 ]]; then
        cmd="su - $PG_USER -c \"$cmd\""
    fi
    
    # 使用timeout命令限制执行时间
    [[ "$quiet_mode" != "true" ]] && echo -e "${YELLOW}执行SQL命令（超时: ${timeout_duration}秒）...${NC}"
    
    # 执行命令并捕获输出和错误
    local result
    result=$(timeout $timeout_duration bash -c "$cmd" 2>&1)
    local exit_code=$?
    
    # 检查执行结果
    if [[ $exit_code -eq 124 ]]; then
        echo -e "${RED}SQL命令执行超时（${timeout_duration}秒）${NC}" >&2
        return 124
    elif [[ $exit_code -ne 0 ]]; then
        echo -e "${RED}SQL命令执行失败，错误代码: $exit_code${NC}" >&2
        echo -e "${RED}错误信息: $result${NC}" >&2
        return $exit_code
    fi
    
    # 返回结果
    echo "$result"
    return 0
}

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                show_version
                exit 0
                ;;
            -d|--days)
                if [[ -n "$2" ]]; then
                    DAYS_TO_KEEP="$2"
                else
                    echo -e "${RED}错误: --days 参数需要指定天数${NC}"
                    exit 1
                fi
                shift 2
                ;;
            -u|--user)
                if [[ -n "$2" ]]; then
                    PG_USER="$2"
                else
                    echo -e "${RED}错误: --user 参数需要指定用户名${NC}"
                    exit 1
                fi
                shift 2
                ;;
            -p|--path)
                if [[ -n "$2" ]]; then
                    PG_INSTALL_DIR="$2"
                else
                    echo -e "${RED}错误: --path 参数需要指定安装路径${NC}"
                    exit 1
                fi
                shift 2
                ;;
            -a|--archive)
                if [[ -n "$2" ]]; then
                    PG_ARCHIVE_DIR="$2"
                else
                    echo -e "${RED}错误: --archive 参数需要指定归档路径${NC}"
                    exit 1
                fi
                shift 2
                ;;
            -D|--data)
                if [[ -n "$2" ]]; then
                    PG_DATA_DIR="$2"
                else
                    echo -e "${RED}错误: --data 参数需要指定数据目录路径${NC}"
                    exit 1
                fi
                shift 2
                ;;
            -f|--force)
                FORCE_MODE="true"
                shift
                ;;
            -q|--quiet)
                QUIET_MODE="true"
                shift
                ;;
            setup|manual|auto|cron|smart|status|test)
                MODE="$1"
                shift
                ;;
            *)
                echo -e "${RED}错误: 未知参数 $1${NC}"
                show_help
                exit 1
                ;;
        esac
    done
}

# 主函数
main() {
    # 默认值
    MODE=""
    PG_VERSION="$DEFAULT_PG_VERSION"
    PG_USER="$DEFAULT_PG_USER"
    PG_GROUP="$DEFAULT_PG_GROUP"
    PG_INSTALL_DIR=""
    PG_DATA_DIR=""
    PG_ARCHIVE_DIR=""
    DAYS_TO_KEEP="$DEFAULT_DAYS_TO_KEEP"
    FORCE_MODE="false"
    QUIET_MODE="false"
    
    # 解析命令行参数
    parse_args "$@"
    
    # 检查是否为root用户（某些模式需要）
    if [[ "$MODE" == "setup" || "$MODE" == "auto" || "$MODE" == "cron" ]]; then
        if [[ $EUID -ne 0 ]]; then
            echo -e "${RED}此模式需要以root权限运行${NC}"
            exit 1
        fi
    fi
    
    # 检查环境变量是否设置
    if [[ -z "$PG_INSTALL_DIR" && -z "$PG_INSTALL_DIR" && -n "$PG_HOME" ]]; then
        PG_INSTALL_DIR="$PG_HOME"
        [[ "$QUIET_MODE" != "true" ]] && echo -e "${YELLOW}从环境变量 PG_HOME 获取安装目录: $PG_HOME${NC}"
    fi
    
    if [[ -z "$PG_DATA_DIR" && -z "$PG_DATA_DIR" && -n "$PGDATA" ]]; then
        PG_DATA_DIR="$PGDATA"
        [[ "$QUIET_MODE" != "true" ]] && echo -e "${YELLOW}从环境变量 PGDATA 获取数据目录: $PGDATA${NC}"
    fi
    
    # 如果仍然没有找到配置，提示用户设置环境变量
    if [[ -z "$PG_INSTALL_DIR" || -z "$PG_DATA_DIR" ]]; then
        echo -e "${RED}错误: 无法找到PostgreSQL配置${NC}"
        echo -e "${YELLOW}请设置以下环境变量后重试:${NC}"
        echo -e "${BLUE}export PG_HOME=/path/to/postgresql${NC}"
        echo -e "${BLUE}export PGDATA=/path/to/data${NC}"
        echo -e "${YELLOW}或者使用命令行参数指定路径:${NC}"
        echo -e "${BLUE}$0 -p /path/to/postgresql -D /path/to/data${NC}"
        exit 1
    fi
    
    # 设置默认值
    PG_INSTALL_DIR=${PG_INSTALL_DIR:-$DEFAULT_PG_INSTALL_DIR}
    PG_DATA_DIR=${PG_DATA_DIR:-$DEFAULT_PG_DATA_DIR}
    PG_ARCHIVE_DIR=${PG_ARCHIVE_DIR:-$(dirname "$PG_DATA_DIR")/archive}
    PG_HOME=${PG_HOME:-$DEFAULT_PG_HOME}
    
    # 根据模式执行相应操作
    case $MODE in
        setup)
            confirm_configuration
            echo -e "${GREEN}开始配置PostgreSQL WAL归档...${NC}"
            
            create_archive_dir
            configure_wal_archive
            restart_postgresql
            verify_wal_archive
            create_cleanup_script
            setup_cron_job
            show_archive_info
            
            echo -e "${GREEN}PostgreSQL WAL归档配置完成!${NC}"
            ;;
        manual)
            manual_cleanup
            ;;
        auto)
            auto_cleanup_config
            ;;
        cron)
            cron_cleanup_config
            ;;
        smart)
            smart_cleanup
            ;;
        status)
            show_archive_status
            ;;
        test)
            test_archive_config
            ;;
        "")
            echo -e "${RED}错误: 请指定操作模式${NC}"
            show_help
            exit 1
            ;;
        *)
            echo -e "${RED}错误: 未知模式 $MODE${NC}"
            show_help
            exit 1
            ;;
    esac
}

# 执行主函数
main "$@"
