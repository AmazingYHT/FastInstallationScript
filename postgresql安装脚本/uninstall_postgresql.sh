#!/bin/bash

# PostgreSQL 完全卸载脚本
# 删除PostgreSQL服务、数据和配置文件

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 默认配置
PG_USER="postgres"
PG_GROUP="postgres"
PG_HOME="/data/di/postgresql"
PG_INSTALL_DIR="${PG_HOME}/postgresql-18.1"
PG_DATA_DIR="${PG_HOME}/data"

# 搜索PostgreSQL安装
search_postgresql() {
    echo -e "${YELLOW}请选择PostgreSQL卸载方式:${NC}"
    echo "1. 自动搜索系统中的PostgreSQL安装"
    echo "2. 手动输入安装目录和数据目录"
    echo ""
    read -p "请选择 [1/2]: " search_mode
    
    case $search_mode in
        "1")
            auto_search_postgresql
            ;;
        "2")
            manual_input_postgresql
            ;;
        *)
            echo -e "${RED}无效选择，使用自动搜索${NC}"
            auto_search_postgresql
            ;;
    esac
}

# 自动搜索PostgreSQL
auto_search_postgresql() {
    echo -e "${YELLOW}搜索系统中的PostgreSQL安装...${NC}"
    echo ""
    
    # 尝试从 /etc/profile 读取 PostgreSQL 环境变量
    local profile_pghome=""
    local profile_pgdata=""
    
    if [ -f /etc/profile ]; then
        echo -e "${CYAN}从 /etc/profile 读取 PostgreSQL 环境变量...${NC}"
        # 支持 PG_HOME 或 PGHOME 两种命名
        profile_pghome=$(grep -E "^export\s+PG_HOME=|^PG_HOME=|^export\s+PGHOME=|^PGHOME=" /etc/profile 2>/dev/null | head -1 | sed -E 's/^export\s+PG_HOME=|^PG_HOME=|^export\s+PGHOME=|^PGHOME=//' | sed 's/"//g' | sed "s/'//g" | tr -d ' ')
        profile_pgdata=$(grep -E "^export\s+PGDATA=|^PGDATA=" /etc/profile 2>/dev/null | head -1 | sed -E 's/^export\s+PGDATA=|^PGDATA=//' | sed 's/"//g' | sed "s/'//g" | tr -d ' ')
        
        if [ -n "$profile_pghome" ]; then
            echo -e "${GREEN}  找到 PG_HOME: $profile_pghome${NC}"
        fi
        if [ -n "$profile_pgdata" ]; then
            echo -e "${GREEN}  找到 PGDATA: $profile_pgdata${NC}"
        fi
        echo ""
    fi
    
    # 搜索运行中的PostgreSQL进程
    echo -e "${CYAN}运行中的PostgreSQL进程:${NC}"
    
    # 获取当前脚本的PID
    local script_pid=$$
    local script_name=$(basename "$0")
    
    local pg_processes=$(pgrep -f "postgres|postmaster" 2>/dev/null || true)
    if [ -n "$pg_processes" ]; then
        local real_pg_processes=""
        for pid in $pg_processes; do
            # 跳过脚本进程
            if [ "$pid" = "$script_pid" ]; then
                continue
            fi
            
            # 获取进程命令
            local cmd=$(ps -p $pid -o cmd= 2>/dev/null || echo "未知")
            
            # 跳过所有脚本文件（包含.sh的进程）
            if [[ "$cmd" == *".sh"* ]]; then
                continue
            fi
            
            # 跳过包含uninstall_postgresql的进程
            if [[ "$cmd" == *"uninstall_postgresql"* ]]; then
                continue
            fi
            
            # 跳过包含postgresql的脚本进程
            if [[ "$cmd" == *postgresql*".sh"* ]] || [[ "$cmd" == *".sh"*postgresql* ]]; then
                continue
            fi
            
            # 只保留真正的PostgreSQL进程
            if [[ "$cmd" =~ ^postgres: ]] || [[ "$cmd" =~ ^/.*postgres.*-D ]] || [[ "$cmd" =~ ^.*bin/postgres ]]; then
                real_pg_processes="$real_pg_processes $pid"
                echo "  - PID: $pid, 命令: $cmd"
            fi
        done
        
        if [ -z "$real_pg_processes" ]; then
            echo "  (无真正的PostgreSQL进程，只找到脚本相关进程)"
        fi
    else
        echo "  (无)"
    fi
    echo ""
    
    # 搜索PostgreSQL端口
    echo -e "${CYAN}PostgreSQL端口监听:${NC}"
    local pg_ports=$(netstat -tlnp 2>/dev/null | grep ":5432\|:5433" || true)
    if [ -n "$pg_ports" ]; then
        echo "$pg_ports" | while read line; do
            echo "  - $line"
        done
    else
        echo "  (无)"
    fi
    echo ""
    
    local found_installations=()
    
    # 构建搜索路径列表（优先使用从 /etc/profile 读取的路径）
    local search_paths=()
    
    # 如果从 /etc/profile 找到了 PG_HOME（或 PGHOME），优先使用它
    if [ -n "$profile_pghome" ]; then
        search_paths+=("$profile_pghome")
    fi
    
    # 添加其他常见安装位置
    search_paths+=(
        "/data/di/postgresql"
        "/usr/local/pgsql"
        "/usr/local/postgresql"
        "/opt/postgresql"
        "/var/lib/pgsql"
        "/home/postgresql"
        "/usr/lib/postgresql"
    )
    
    # 去重
    local unique_paths=()
    for path in "${search_paths[@]}"; do
        if [[ ! " ${unique_paths[@]} " =~ " ${path} " ]]; then
            unique_paths+=("$path")
        fi
    done
    
    # 搜索包含postgresql的目录
    for path in "${unique_paths[@]}"; do
        if [ -d "$path" ]; then
            # 检查是否包含PostgreSQL文件
            local pg_files=$(find "$path" -name "postgres" -o -name "initdb" -o -name "pg_ctl" 2>/dev/null | head -5)
            if [ -n "$pg_files" ]; then
                # 获取版本信息
                local version=""
                local initdb_path=$(find "$path" -name "initdb" 2>/dev/null | head -1)
                if [ -n "$initdb_path" ]; then
                    version=$("$initdb_path" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
                fi
                
                # 获取数据目录（优先使用从 /etc/profile 读取的 PGDATA）
                local data_dir=""
                if [ -n "$profile_pgdata" ] && [ -d "$profile_pgdata" ]; then
                    data_dir="$profile_pgdata"
                    echo -e "${GREEN}  使用从 /etc/profile 读取的 PGDATA: $data_dir${NC}"
                else
                    local pg_version_dir=$(find "$path" -type d -name "data" 2>/dev/null | head -1)
                    if [ -n "$pg_version_dir" ]; then
                        data_dir="$pg_version_dir"
                    fi
                fi
                
                found_installations+=("$path|$version|$data_dir")
            fi
        fi
    done
    
    # 搜索systemd服务
    echo -e "${CYAN}找到的PostgreSQL服务:${NC}"
    local services=$(systemctl list-unit-files | grep postgresql | awk '{print $1}')
    if [ -n "$services" ]; then
        for service in $services; do
            local status="未知"
            if systemctl is-active --quiet $service 2>/dev/null; then
                status="运行中"
            else
                status="已停止"
            fi
            echo "  - $service ($status)"
        done
    else
        echo "  (无)"
    fi
    echo ""
    
    # 显示找到的安装
    if [ ${#found_installations[@]} -gt 0 ]; then
        echo -e "${CYAN}找到的PostgreSQL安装:${NC}"
        local index=1
        for installation in "${found_installations[@]}"; do
            IFS='|' read -r path version data_dir <<< "$installation"
            echo "  $index. 路径: $path"
            if [ -n "$version" ]; then
                echo "     版本: $version"
            fi
            if [ -n "$data_dir" ]; then
                echo "     数据目录: $data_dir"
            fi
            echo ""
            ((index++))
        done
        
        echo "  0. 手动输入路径"
        echo ""
        
        # 让用户选择
        read -p "请选择要卸载的PostgreSQL安装 [0-${#found_installations[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            if [ "$choice" -eq 0 ]; then
                manual_input_postgresql
                return
            elif [ "$choice" -ge 1 ] && [ "$choice" -le ${#found_installations[@]} ]; then
                local selected="${found_installations[$((choice-1))]}"
                IFS='|' read -r path version data_dir <<< "$selected"
                PG_HOME="$path"
                
                # 检查路径是否已经是安装目录（包含bin/postgres）
                if [ -f "$path/bin/postgres" ]; then
                    # 路径本身就是安装目录
                    PG_INSTALL_DIR="$path"
                    # 如果没有找到版本号，尝试从bin/postgres获取
                    if [ -z "$version" ]; then
                        version=$("$path/bin/postgres" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
                    fi
                elif [ -n "$version" ]; then
                    # 如果有版本号，尝试构建安装目录路径
                    if [ -d "$path/postgresql-$version" ]; then
                        PG_INSTALL_DIR="$path/postgresql-$version"
                    else
                        # 尝试找到包含bin/postgres的目录
                        PG_INSTALL_DIR=$(find "$path" -name "postgres" -executable 2>/dev/null | dirname | head -1)
                    fi
                else
                    # 尝试找到包含bin/postgres的目录
                    PG_INSTALL_DIR=$(find "$path" -name "postgres" -executable 2>/dev/null | dirname | head -1)
                fi
                
                if [ -n "$data_dir" ]; then
                    PG_DATA_DIR="$data_dir"
                fi
                echo -e "${GREEN}已选择: $path${NC}"
            else
                echo -e "${RED}无效选择${NC}"
                exit 1
            fi
        else
            echo -e "${RED}无效输入${NC}"
            exit 1
        fi
    else
        echo -e "${YELLOW}未找到PostgreSQL安装${NC}"
        echo -e "${YELLOW}请手动输入路径${NC}"
        manual_input_postgresql
    fi
}

# 手动输入PostgreSQL路径
manual_input_postgresql() {
    echo -e "${YELLOW}手动输入PostgreSQL路径${NC}"
    echo ""
    
    # 输入安装目录
    echo -e "${CYAN}请输入PostgreSQL安装目录:${NC}"
    echo "例如: /data/di/postgresql/postgresql-18.1"
    echo "或: /usr/local/pgsql"
    read -p "安装目录: " input_install_dir
    
    if [ -z "$input_install_dir" ]; then
        echo -e "${RED}安装目录不能为空${NC}"
        exit 1
    fi
    
    # 验证安装目录
    if [ ! -d "$input_install_dir" ]; then
        echo -e "${YELLOW}警告: 安装目录不存在: $input_install_dir${NC}"
        read -p "是否继续? [y/N]: " continue_install
        if [[ ! $continue_install =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    # 输入数据目录
    echo ""
    echo -e "${CYAN}请输入PostgreSQL数据目录:${NC}"
    echo "例如: /data/di/postgresql/data"
    echo "或: /var/lib/pgsql/data"
    read -p "数据目录: " input_data_dir
    
    if [ -z "$input_data_dir" ]; then
        echo -e "${RED}数据目录不能为空${NC}"
        exit 1
    fi
    
    # 验证数据目录
    if [ ! -d "$input_data_dir" ]; then
        echo -e "${YELLOW}警告: 数据目录不存在: $input_data_dir${NC}"
        read -p "是否继续? [y/N]: " continue_data
        if [[ ! $continue_data =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    # 设置路径
    PG_INSTALL_DIR="$input_install_dir"
    PG_DATA_DIR="$input_data_dir"
    
    # 自动推断主目录（但不会删除）
    if [ -d "$(dirname "$input_install_dir")" ]; then
        PG_HOME="$(dirname "$input_install_dir")"
    else
        PG_HOME="/data/di/postgresql"
    fi
    
    # 显示配置
    echo ""
    echo -e "${GREEN}手动输入的配置:${NC}"
    echo "安装目录: $PG_INSTALL_DIR"
    echo "数据目录: $PG_DATA_DIR"
    echo "主目录: $PG_HOME"
    echo ""
    
    # 确认配置
    read -p "确认使用这些路径? [y/N]: " confirm_paths
    if [[ ! $confirm_paths =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}请重新运行脚本并输入正确的路径${NC}"
        exit 1
    fi
}

# 显示使用说明
show_usage() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -u, --user USER      PostgreSQL用户名 (默认: postgres)"
    echo "  -g, --group GROUP    PostgreSQL用户组 (默认: postgres)"
    echo "  -i, --install-dir DIR PostgreSQL安装目录 (默认: 自动搜索或 /data/di/postgresql/postgresql-18.1)"
    echo "  -d, --data-dir DIR   PostgreSQL数据目录 (默认: 自动搜索或 /data/di/postgresql/data)"
    echo "  -h, --home DIR       PostgreSQL主目录 (默认: 自动搜索或 /data/di/postgresql)"
    echo "  -y, --yes            跳过确认提示"
    echo "  --dry-run            仅显示将要删除的内容，不实际删除"
    echo "  --help               显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0                    # 自动搜索并卸载"
    echo "  $0 -y                 # 跳过确认直接卸载"
    echo "  $0 -u pguser -d /pg/data  # 指定用户和数据目录"
    echo ""
}

# 解析命令行参数
SKIP_CONFIRM=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--user)
            PG_USER="$2"
            shift 2
            ;;
        -g|--group)
            PG_GROUP="$2"
            shift 2
            ;;
        -i|--install-dir)
            PG_INSTALL_DIR="$2"
            shift 2
            ;;
        -d|--data-dir)
            PG_DATA_DIR="$2"
            shift 2
            ;;
        -h|--home)
            PG_HOME="$2"
            shift 2
            ;;
        -y|--yes)
            SKIP_CONFIRM=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help)
            show_usage
            exit 0
            ;;
        *)
            echo -e "${RED}未知选项: $1${NC}"
            show_usage
            exit 1
            ;;
    esac
done

# 检查是否为root用户
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}此脚本需要以root权限运行${NC}"
   exit 1
fi

# 显示将要删除的内容
show_removal_list() {
    echo -e "${YELLOW}⚠️  卸载确认 - 请仔细核对以下内容:${NC}"
    echo "----------------------------------------"
    echo -e "${RED}⚠️  以下内容将被 PERMANENTLY 删除:${NC}"
    echo -e "${RED}✗  PostgreSQL用户:${NC} $PG_USER"
    echo -e "${RED}✗  PostgreSQL用户组:${NC} $PG_GROUP"
    echo -e "${RED}✗  安装目录:${NC} $PG_INSTALL_DIR"
    echo -e "${RED}✗  数据目录:${NC} $PG_DATA_DIR"
    echo ""
    echo -e "${YELLOW}ℹ️  以下内容只显示但不删除:${NC}"
    echo -e "${YELLOW}📁  主目录:${NC} $PG_HOME (不会被自动删除)"
    echo ""
    
    # 查找相关的systemd服务
    local services=$(systemctl list-unit-files | grep postgresql | awk '{print $1}' | tr '\n' ' ')
    if [ -n "$services" ]; then
        echo -e "${RED}相关服务:${NC} $services"
    fi
    
    # 查找相关的配置文件
    local configs=(
        "/etc/profile.d/postgresql.sh"
        "/etc/sysconfig/pgsql"
        "/etc/logrotate.d/postgresql"
        "/etc/init.d/postgresql"
    )
    
    echo -e "${RED}可能存在的配置文件:${NC}"
    for config in "${configs[@]}"; do
        if [ -e "$config" ]; then
            echo "  - $config"
        fi
    done
    
    # 查找环境变量
    if grep -q "PGHOME\|PGDATA" /etc/profile 2>/dev/null; then
        echo -e "${RED}环境变量配置:${NC} /etc/profile (包含PostgreSQL配置)"
    fi
    
    echo "----------------------------------------"
}

# 确认卸载
confirm_removal() {
    if [ "$SKIP_CONFIRM" = true ]; then
        return
    fi
    
    echo -e "${RED}⚠️  危险操作警告${NC}"
    echo -e "${RED}⚠️  此操作将删除以下内容:${NC}"
    echo "----------------------------------------"
    echo -e "${RED}✗  PostgreSQL用户: $PG_USER${NC}"
    echo -e "${RED}✗  PostgreSQL用户组: $PG_GROUP${NC}"
    echo -e "${RED}✗  安装目录: $PG_INSTALL_DIR${NC}"
    echo -e "${RED}✗  数据目录: $PG_DATA_DIR (包含所有数据库数据!)${NC}"
    echo -e "${YELLOW}ℹ️  主目录: $PG_HOME (不会被删除)${NC}"
    echo "----------------------------------------"
    echo -e "${RED}⚠️  重要提示:${NC}"
    echo -e "${YELLOW}  • 数据目录包含所有数据库数据，删除后无法恢复！${NC}"
    echo -e "${YELLOW}  • 建议在卸载前使用 pg_dumpall 备份数据！${NC}"
    echo -e "${YELLOW}  • 主目录不会被删除，可用于保存配置文件！${NC}"
    echo ""
    echo -e "${YELLOW}📝 备份命令示例:${NC}"
    echo -e "${CYAN}  $PG_INSTALL_DIR/bin/pg_dumpall > postgresql_backup.sql${NC}"
    echo -e "${CYAN}  tar -czf postgresql_data_backup.tar.gz $PG_DATA_DIR${NC}"
    echo ""
    echo -e "${RED}⚠️  此操作不可逆，请确认是否继续?${NC}"
    read -p "输入 'yes' 确认卸载: " confirm
    
    if [ "$confirm" != "yes" ]; then
        echo -e "${GREEN}卸载已取消${NC}"
        exit 0
    fi
}

# 停止PostgreSQL服务
stop_services() {
    echo -e "${YELLOW}停止PostgreSQL服务...${NC}"
    
    # 查找并停止所有PostgreSQL相关服务
    local services=$(systemctl list-unit-files | grep postgresql | awk '{print $1}')
    
    if [ -n "$services" ]; then
        for service in $services; do
            if systemctl is-active --quiet $service 2>/dev/null; then
                echo -e "${YELLOW}停止服务: $service${NC}"
                if [ "$DRY_RUN" = false ]; then
                    systemctl stop $service
                    # 等待服务完全停止
                    sleep 2
                fi
            fi
            
            # 禁用服务
            if systemctl is-enabled --quiet $service 2>/dev/null; then
                echo -e "${YELLOW}禁用服务: $service${NC}"
                if [ "$DRY_RUN" = false ]; then
                    systemctl disable $service
                fi
            fi
        done
    fi
    
    # 杀死可能残留的进程（更精确的匹配）
    echo -e "${YELLOW}检查残留的PostgreSQL进程...${NC}"
    
    # 获取当前脚本的PID
    local script_pid=$$
    local script_name=$(basename "$0")
    
    # 查找PostgreSQL相关进程
    local all_pids=$(pgrep -f "postgres|postmaster" 2>/dev/null || true)
    local postgres_pids=""
    
    if [ -n "$all_pids" ]; then
        # 过滤掉脚本相关的进程
        for pid in $all_pids; do
            # 跳过脚本进程
            if [ "$pid" = "$script_pid" ]; then
                continue
            fi
            
            # 获取进程命令
            local cmd=$(ps -p $pid -o cmd= 2>/dev/null || echo "")
            
            # 跳过所有脚本文件（包含.sh的进程）
            if [[ "$cmd" == *".sh"* ]]; then
                continue
            fi
            
            # 跳过包含uninstall_postgresql的进程
            if [[ "$cmd" == *"uninstall_postgresql"* ]]; then
                continue
            fi
            
            # 跳过包含postgresql的脚本进程
            if [[ "$cmd" == *postgresql*".sh"* ]] || [[ "$cmd" == *".sh"*postgresql* ]]; then
                continue
            fi
            
            # 只保留真正的PostgreSQL进程
            if [[ "$cmd" =~ ^postgres: ]] || [[ "$cmd" =~ ^/.*postgres.*-D ]] || [[ "$cmd" =~ ^.*bin/postgres ]]; then
                postgres_pids="$postgres_pids $pid"
            fi
        done
    fi
    
    if [ -n "$postgres_pids" ]; then
        echo -e "${YELLOW}发现以下PostgreSQL残留进程:${NC}"
        for pid in $postgres_pids; do
            local cmd=$(ps -p $pid -o pid,cmd= 2>/dev/null || echo "")
            echo "  PID: $pid"
            echo "  命令: $(echo $cmd | cut -d' ' -f2-)"
        done
        echo ""
        
        if [ "$DRY_RUN" = false ]; then
            echo -e "${YELLOW}正在清理残留进程...${NC}"
            for pid in $postgres_pids; do
                local cmd=$(ps -p $pid -o cmd= 2>/dev/null || echo "")
                echo -e "${YELLOW}  杀死进程 $pid${NC}"
                kill -TERM $pid 2>/dev/null || true
                sleep 1
                
                # 如果进程仍在运行，强制杀死
                if kill -0 $pid 2>/dev/null; then
                    echo -e "${YELLOW}  强制杀死进程 $pid${NC}"
                    kill -9 $pid 2>/dev/null || true
                fi
            done
            
            # 等待进程完全退出
            sleep 2
            
            # 验证清理结果
            local remaining=""
            for pid in $postgres_pids; do
                if kill -0 $pid 2>/dev/null; then
                    remaining="$remaining $pid"
                fi
            done
            
            if [ -n "$remaining" ]; then
                echo -e "${RED}以下进程未能杀死: $remaining${NC}"
                echo -e "${YELLOW}请手动执行: sudo kill -9 $remaining${NC}"
            else
                echo -e "${GREEN}所有PostgreSQL进程已清理${NC}"
            fi
        fi
    else
        echo -e "${GREEN}未发现PostgreSQL残留进程${NC}"
    fi
    
    # 再次检查服务状态
    echo -e "${YELLOW}验证服务状态...${NC}"
    if [ -n "$services" ]; then
        for service in $services; do
            if systemctl is-active --quiet $service 2>/dev/null; then
                echo -e "${RED}警告: 服务 $service 仍在运行${NC}"
            else
                echo -e "${GREEN}服务 $service 已停止${NC}"
            fi
        done
    fi
}

# 删除systemd服务文件
remove_services() {
    echo -e "${YELLOW}删除systemd服务文件...${NC}"
    
    # 查找所有PostgreSQL相关的服务文件
    local service_locations=(
        "/etc/systemd/system"
        "/usr/lib/systemd/system"
        "/run/systemd/system"
        "/etc/init.d"
    )
    
    local found_services=()
    
    # 搜索所有可能的服务文件
    for location in "${service_locations[@]}"; do
        if [ -d "$location" ]; then
            # 查找postgresql相关的服务文件
            local services=$(find "$location" -name "*postgresql*" -o -name "*pgsql*" 2>/dev/null)
            for service in $services; do
                if [ -f "$service" ]; then
                    found_services+=("$service")
                fi
            done
        fi
    done
    
    # 显示找到的服务
    if [ ${#found_services[@]} -gt 0 ]; then
        echo -e "${CYAN}找到以下PostgreSQL服务文件:${NC}"
        for service in "${found_services[@]}"; do
            echo "  - $service"
        done
        echo ""
    else
        echo -e "${YELLOW}未找到PostgreSQL服务文件${NC}"
    fi
    
    # 停用并删除服务
    for service in "${found_services[@]}"; do
        local service_name=$(basename "$service")
        echo -e "${YELLOW}处理服务: $service_name${NC}"
        
        if [ "$DRY_RUN" = false ]; then
            # 获取服务状态
            local is_active=false
            local is_enabled=false
            
            # 检查服务是否在运行
            if systemctl list-unit-files | grep -q "^$service_name" 2>/dev/null; then
                if systemctl is-active --quiet "$service_name" 2>/dev/null; then
                    is_active=true
                    echo -e "${YELLOW}  停止服务: $service_name${NC}"
                    systemctl stop "$service_name" 2>/dev/null || true
                fi
                
                if systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
                    is_enabled=true
                    echo -e "${YELLOW}  禁用服务: $service_name${NC}"
                    systemctl disable "$service_name" 2>/dev/null || true
                fi
                
                # 删除服务文件
                echo -e "${YELLOW}  删除服务文件: $service${NC}"
                rm -f "$service" 2>/dev/null || true
                
                # 掩码服务（如果存在）
                if [ -f "/etc/systemd/system/$service_name" ]; then
                    systemctl mask "$service_name" 2>/dev/null || true
                    systemctl unmask "$service_name" 2>/dev/null || true
                    rm -f "/etc/systemd/system/$service_name" 2>/dev/null || true
                fi
            else
                # 直接删除文件
                echo -e "${YELLOW}  直接删除文件: $service${NC}"
                rm -f "$service" 2>/dev/null || true
            fi
        else
            echo -e "${YELLOW}[预览] 将删除服务文件: $service${NC}"
        fi
    done
    
    # 重新加载systemd
    if [ "$DRY_RUN" = false ]; then
        echo -e "${YELLOW}重新加载systemd配置...${NC}"
        systemctl daemon-reload 2>/dev/null || true
        
        # 重启systemd服务（如果需要）
        if systemctl --version &>/dev/null; then
            systemctl daemon-reexec 2>/dev/null || true
        fi
        
        # 清理systemd缓存
        systemctl daemon-reload 2>/dev/null || true
    fi
    
    # 验证服务是否已删除
    echo -e "${YELLOW}验证服务删除状态...${NC}"
    local remaining_services=()
    
    for service in "${found_services[@]}"; do
        local service_name=$(basename "$service")
        
        # 检查服务是否仍然存在
        if systemctl list-unit-files | grep -q "^$service_name" 2>/dev/null; then
            remaining_services+=("$service_name")
        fi
        
        # 检查文件是否仍然存在
        if [ -f "$service" ]; then
            remaining_services+=("$service")
        fi
    done
    
    if [ ${#remaining_services[@]} -gt 0 ]; then
        echo -e "${RED}以下服务未能完全删除:${NC}"
        for remaining in "${remaining_services[@]}"; do
            echo "  - $remaining"
        done
        echo ""
        echo -e "${YELLOW}请手动执行以下命令:${NC}"
        for remaining in "${remaining_services[@]}"; do
            if [[ "$remaining" == *"/"* ]]; then
                echo "  sudo rm -f $remaining"
            else
                echo "  sudo systemctl stop $remaining"
                echo "  sudo systemctl disable $remaining"
                echo "  sudo rm -f /etc/systemd/system/$remaining"
                echo "  sudo rm -f /usr/lib/systemd/system/$remaining"
            fi
        done
    else
        echo -e "${GREEN}所有PostgreSQL服务已成功删除${NC}"
    fi
}

# 强制删除目录的辅助函数
force_remove_dir() {
    local dir_path="$1"
    local dir_name="$2"
    
    if [ ! -d "$dir_path" ]; then
        echo -e "${YELLOW}$dir_name 不存在: $dir_path${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}删除 $dir_name: $dir_path${NC}"
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[预览] 将删除 $dir_name: $dir_path${NC}"
        return 0
    fi
    
    # 获取目录所有者
    local owner=$(stat -c "%U" "$dir_path" 2>/dev/null || echo "unknown")
    local group=$(stat -c "%G" "$dir_path" 2>/dev/null || echo "unknown")
    
    # 多种方法尝试删除
    local methods=(
        "rm -rf"
        "chmod -R 777 && rm -rf"
        "chown -R root:root && chmod -R 777 && rm -rf"
        "find -type f -delete && find -type d -delete"
        "find . -type d -exec rm -rf {} + 2>/dev/null"
    )
    
    for method in "${methods[@]}"; do
        echo -e "${YELLOW}尝试方法: $method${NC}"
        
        case $method in
            "rm -rf")
                rm -rf "$dir_path" 2>/dev/null
                ;;
            "chmod -R 777 && rm -rf")
                chmod -R 777 "$dir_path" 2>/dev/null || true
                rm -rf "$dir_path" 2>/dev/null
                ;;
            "chown -R root:root && chmod -R 777 && rm -rf")
                chown -R root:root "$dir_path" 2>/dev/null || true
                chmod -R 777 "$dir_path" 2>/dev/null || true
                rm -rf "$dir_path" 2>/dev/null
                ;;
            "find -type f -delete && find -type d -delete")
                cd "$dir_path" 2>/dev/null || continue
                find . -type f -delete 2>/dev/null || true
                cd .. 2>/dev/null || continue
                find "$dir_path" -type d -delete 2>/dev/null || true
                ;;
            "find . -type d -exec rm -rf {} + 2>/dev/null")
                cd "$(dirname "$dir_path")" 2>/dev/null || continue
                find "$(basename "$dir_path")" -type d -exec rm -rf {} + 2>/dev/null || true
                cd - 2>/dev/null || true
                ;;
        esac
        
        # 检查是否删除成功
        if [ ! -d "$dir_path" ]; then
            echo -e "${GREEN}$dir_name 删除成功${NC}"
            return 0
        fi
    done
    
    # 所有方法都失败，显示详细信息
    echo -e "${RED}$dir_name 删除失败${NC}"
    echo -e "${YELLOW}目录信息:${NC}"
    echo "  - 路径: $dir_path"
    echo "  - 所有者: $owner:$group"
    echo "  - 权限: $(stat -c "%a" "$dir_path" 2>/dev/null || echo "unknown")"
    echo "  - 内容: $(ls -la "$dir_path" 2>/dev/null | head -5 || echo "无法列出")"
    
    # 提供手动删除命令
    echo ""
    echo -e "${YELLOW}请手动执行以下命令:${NC}"
    echo "  sudo chown -R root:root $dir_path"
    echo "  sudo chmod -R 777 $dir_path"
    echo "  sudo rm -rf $dir_path"
    echo ""
    echo -e "${YELLOW}或者使用强制删除:${NC}"
    echo "  sudo rm -rf --no-preserve-root $dir_path"
    
    return 1
}

# 删除PostgreSQL文件和目录
remove_files() {
    echo -e "${YELLOW}删除PostgreSQL文件和目录...${NC}"
    
    # 删除安装目录
    force_remove_dir "$PG_INSTALL_DIR" "安装目录"
    
    # 删除数据目录
    force_remove_dir "$PG_DATA_DIR" "数据目录"
    
    # 注意：主目录不会被自动删除
    # 如果需要删除主目录，请手动执行：
    # force_remove_dir "$PG_HOME" "主目录"
    
    # 删除其他可能的PostgreSQL目录
    local other_dirs=(
        "/var/lib/pgsql"
        "/var/run/postgresql"
        "/tmp/.s.PGSQL.*"
        "/usr/local/pgsql"
        "/opt/postgresql"
    )
    
    for dir in "${other_dirs[@]}"; do
        # 处理通配符
        if [[ "$dir" == *"*"* ]]; then
            for matched_dir in $dir; do
                if [ -d "$matched_dir" ]; then
                    force_remove_dir "$matched_dir" "PostgreSQL相关目录"
                fi
            done
        else
            force_remove_dir "$dir" "PostgreSQL相关目录"
        fi
    done
    
    # 删除日志文件
    echo -e "${YELLOW}删除日志文件...${NC}"
    local log_patterns=(
        "/var/log/postgresql*"
        "/var/log/pgsql*"
        "/var/log/postgresql/*.log"
        "/var/log/pgsql/*.log"
    )
    
    for pattern in "${log_patterns[@]}"; do
        for file in $pattern; do
            if [ -e "$file" ]; then
                echo -e "${YELLOW}删除日志文件: $file${NC}"
                if [ "$DRY_RUN" = false ]; then
                    rm -rf "$file" 2>/dev/null || true
                fi
            fi
        done
    done
    
    # 删除日志文件
    local log_patterns=(
        "/var/log/postgresql*"
        "/var/log/pgsql*"
        "$PG_HOME/*.log"
    )
    
    for pattern in "${log_patterns[@]}"; do
        for file in $pattern; do
            if [ -e "$file" ]; then
                echo -e "${YELLOW}删除日志文件: $file${NC}"
                if [ "$DRY_RUN" = false ]; then
                    rm -rf "$file"
                fi
            fi
        done
    done
}

# 删除配置文件
remove_configs() {
    echo -e "${YELLOW}删除配置文件...${NC}"
    
    local config_files=(
        "/etc/profile.d/postgresql.sh"
        "/etc/sysconfig/pgsql"
        "/etc/logrotate.d/postgresql"
        "/etc/init.d/postgresql"
    )
    
    for config in "${config_files[@]}"; do
        if [ -e "$config" ]; then
            echo -e "${YELLOW}删除配置文件: $config${NC}"
            if [ "$DRY_RUN" = false ]; then
                rm -rf "$config"
            fi
        fi
    done
    
    # 清理/etc/profile中的PostgreSQL配置
    if grep -q "PGHOME\|PGDATA" /etc/profile 2>/dev/null; then
        echo -e "${YELLOW}清理/etc/profile中的PostgreSQL配置${NC}"
        if [ "$DRY_RUN" = false ]; then
            # 备份原文件
            cp /etc/profile /etc/profile.bak
            # 删除PostgreSQL相关行
            sed -i '/# PostgreSQL Environment Variables/,/^$/d' /etc/profile
        fi
    fi
}

# 删除用户和组
remove_user_group() {
    echo -e "${YELLOW}删除PostgreSQL用户和组...${NC}"
    
    # 删除用户
    if id -u $PG_USER &>/dev/null; then
        echo -e "${YELLOW}删除用户: $PG_USER${NC}"
        if [ "$DRY_RUN" = false ]; then
            userdel -r $PG_USER 2>/dev/null || true
        fi
    fi
    
    # 删除组
    if getent group $PG_GROUP &>/dev/null; then
        echo -e "${YELLOW}删除用户组: $PG_GROUP${NC}"
        if [ "$DRY_RUN" = false ]; then
            groupdel $PG_GROUP 2>/dev/null || true
        fi
    fi
}

# 清理系统
cleanup_system() {
    echo -e "${YELLOW}清理系统...${NC}"
    
    # 清理临时文件
    local temp_patterns=(
        "/tmp/postgres_*"
        "/tmp/.s.PGSQL.*"
        "/var/tmp/postgres_*"
    )
    
    for pattern in "${temp_patterns[@]}"; do
        for file in $pattern; do
            if [ -e "$file" ]; then
                echo -e "${YELLOW}删除临时文件: $file${NC}"
                if [ "$DRY_RUN" = false ]; then
                    rm -rf "$file"
                fi
            fi
        done
    done
    
    # 更新系统缓存
    if [ "$DRY_RUN" = false ]; then
        ldconfig 2>/dev/null || true
    fi
}

# 最终检查残留文件
final_cleanup_check() {
    echo -e "${YELLOW}最终检查残留文件...${NC}"
    
    local leftovers_found=false
    
    # 要检查的目录列表
    local check_dirs=(
        "$PG_INSTALL_DIR:安装目录"
        "$PG_DATA_DIR:数据目录"
        "/var/lib/pgsql:系统数据目录"
        "/var/run/postgresql:运行目录"
        "/usr/local/pgsql:本地安装目录"
        "/opt/postgresql:可选安装目录"
    )
    
    for dir_info in "${check_dirs[@]}"; do
        IFS=':' read -r dir_path dir_name <<< "$dir_info"
        
        if [ -d "$dir_path" ]; then
            echo -e "${RED}发现残留的$dir_name: $dir_path${NC}"
            leftovers_found=true
            
            if [ "$DRY_RUN" = false ]; then
                echo -e "${YELLOW}尝试强制删除残留目录...${NC}"
                
                # 获取详细信息
                local owner=$(stat -c "%U:%G" "$dir_path" 2>/dev/null || echo "unknown")
                local perms=$(stat -c "%a" "$dir_path" 2>/dev/null || echo "unknown")
                echo -e "${CYAN}  所有者: $owner, 权限: $perms${NC}"
                
                # 尝试多种删除方法
                local delete_success=false
                
                # 方法1: 普通rm -rf
                rm -rf "$dir_path" 2>/dev/null && delete_success=true
                
                # 方法2: 修改权限后删除
                if [ "$delete_success" = false ]; then
                    echo -e "${YELLOW}  修改权限后重试...${NC}"
                    chown -R root:root "$dir_path" 2>/dev/null || true
                    chmod -R 777 "$dir_path" 2>/dev/null || true
                    rm -rf "$dir_path" 2>/dev/null && delete_success=true
                fi
                
                # 方法3: 使用--no-preserve-root
                if [ "$delete_success" = false ]; then
                    echo -e "${YELLOW}  使用强制删除选项...${NC}"
                    rm -rf --no-preserve-root "$dir_path" 2>/dev/null && delete_success=true
                fi
                
                # 方法4: 逐个删除文件
                if [ "$delete_success" = false ]; then
                    echo -e "${YELLOW}  逐个删除文件...${NC}"
                    find "$dir_path" -type f -delete 2>/dev/null || true
                    find "$dir_path" -type d -delete 2>/dev/null || true
                    [ ! -d "$dir_path" ] && delete_success=true
                fi
                
                if [ "$delete_success" = true ]; then
                    echo -e "${GREEN}  残留目录已删除${NC}"
                else
                    echo -e "${RED}  残留目录删除失败${NC}"
                    echo -e "${YELLOW}  请手动执行以下命令:${NC}"
                    echo "    sudo chown -R root:root $dir_path"
                    echo "    sudo chmod -R 777 $dir_path"
                    echo "    sudo rm -rf --no-preserve-root $dir_path"
                fi
            fi
        fi
    done
    
    # 检查通配符目录
    local wildcard_dirs=(
        "/tmp/.s.PGSQL.*"
        "/tmp/postgres_*"
    )
    
    for pattern in "${wildcard_dirs[@]}"; do
        for matched_dir in $pattern; do
            if [ -d "$matched_dir" ]; then
                echo -e "${RED}发现残留的临时目录: $matched_dir${NC}"
                leftovers_found=true
                if [ "$DRY_RUN" = false ]; then
                    rm -rf "$matched_dir" 2>/dev/null || true
                fi
            fi
        done
    done
    
    # 检查PostgreSQL进程
    local script_pid=$$
    local script_name=$(basename "$0")
    local all_processes=$(pgrep -f "postgres|postmaster" 2>/dev/null || true)
    local remaining_processes=""
    
    if [ -n "$all_processes" ]; then
        for pid in $all_processes; do
            # 跳过脚本进程
            if [ "$pid" = "$script_pid" ]; then
                continue
            fi
            
            # 获取进程命令
            local cmd=$(ps -p $pid -o cmd= 2>/dev/null || echo "")
            
            # 跳过所有脚本文件（包含.sh的进程）
            if [[ "$cmd" == *".sh"* ]]; then
                continue
            fi
            
            # 跳过包含uninstall_postgresql的进程
            if [[ "$cmd" == *"uninstall_postgresql"* ]]; then
                continue
            fi
            
            # 跳过包含postgresql的脚本进程
            if [[ "$cmd" == *postgresql*".sh"* ]] || [[ "$cmd" == *".sh"*postgresql* ]]; then
                continue
            fi
            
            # 只保留真正的PostgreSQL进程
            if [[ "$cmd" =~ ^postgres: ]] || [[ "$cmd" =~ ^/.*postgres.*-D ]] || [[ "$cmd" =~ ^.*bin/postgres ]]; then
                remaining_processes="$remaining_processes $pid"
            fi
        done
    fi
    
    if [ -n "$remaining_processes" ]; then
        echo -e "${RED}发现残留的PostgreSQL进程:${NC}"
        for pid in $remaining_processes; do
            local cmd=$(ps -p $pid -o cmd= 2>/dev/null || echo "未知")
            echo "  - PID: $pid, 命令: $cmd"
        done
        leftovers_found=true
        
        if [ "$DRY_RUN" = false ]; then
            echo -e "${YELLOW}尝试杀死残留进程...${NC}"
            for pid in $remaining_processes; do
                kill -TERM $pid 2>/dev/null || true
            done
            sleep 2
            
            # 再次检查
            local still_running=""
            for pid in $remaining_processes; do
                if kill -0 $pid 2>/dev/null; then
                    still_running="$still_running $pid"
                fi
            done
            
            if [ -n "$still_running" ]; then
                echo -e "${RED}仍有进程运行，请手动杀死:${NC}"
                for pid in $still_running; do
                    echo "  sudo kill -9 $pid"
                done
            else
                echo -e "${GREEN}残留进程已清除${NC}"
            fi
        fi
    fi
    
    # 检查端口占用
    local pg_ports=$(netstat -tlnp 2>/dev/null | grep ":5432\|:5433" || true)
    if [ -n "$pg_ports" ]; then
        echo -e "${RED}发现端口仍被占用:${NC}"
        echo "$pg_ports"
        leftovers_found=true
    fi
    
    # 检查systemd服务残留
    echo -e "${YELLOW}检查systemd服务残留...${NC}"
    local systemd_services=(
        "/etc/systemd/system/*postgresql*"
        "/etc/systemd/system/*pgsql*"
        "/usr/lib/systemd/system/*postgresql*"
        "/usr/lib/systemd/system/*pgsql*"
    )
    
    for pattern in "${systemd_services[@]}"; do
        for service_file in $pattern; do
            if [ -f "$service_file" ]; then
                echo -e "${RED}发现残留的systemd服务文件: $service_file${NC}"
                leftovers_found=true
                
                if [ "$DRY_RUN" = false ]; then
                    echo -e "${YELLOW}尝试删除残留服务文件...${NC}"
                    local service_name=$(basename "$service_file")
                    
                    # 停用服务
                    systemctl stop "$service_name" 2>/dev/null || true
                    systemctl disable "$service_name" 2>/dev/null || true
                    
                    # 删除文件
                    rm -f "$service_file" 2>/dev/null || true
                    
                    # 重新加载
                    systemctl daemon-reload 2>/dev/null || true
                    
                    # 再次检查
                    if [ -f "$service_file" ]; then
                        echo -e "${RED}  无法删除，请手动执行: sudo rm -f $service_file${NC}"
                    else
                        echo -e "${GREEN}  残留服务文件已删除${NC}"
                    fi
                fi
            fi
        done
    done
    
    # 检查systemd中注册的服务
    local registered_services=$(systemctl list-unit-files | grep -E "postgresql|pgsql" | awk '{print $1}' || true)
    if [ -n "$registered_services" ]; then
        echo -e "${RED}发现仍注册的systemd服务:${NC}"
        echo "$registered_services"
        leftovers_found=true
        
        if [ "$DRY_RUN" = false ]; then
            echo -e "${YELLOW}尝试清理注册的服务...${NC}"
            for service in $registered_services; do
                systemctl stop "$service" 2>/dev/null || true
                systemctl disable "$service" 2>/dev/null || true
                
                # 尝试删除服务文件
                local service_paths=(
                    "/etc/systemd/system/$service"
                    "/usr/lib/systemd/system/$service"
                )
                
                for path in "${service_paths[@]}"; do
                    if [ -f "$path" ]; then
                        rm -f "$path" 2>/dev/null || true
                    fi
                done
            done
            
            # 重新加载
            systemctl daemon-reload 2>/dev/null || true
            
            # 再次检查
            local still_registered=$(systemctl list-unit-files | grep -E "postgresql|pgsql" | awk '{print $1}' || true)
            if [ -n "$still_registered" ]; then
                echo -e "${RED}以下服务仍需手动清理:${NC}"
                echo "$still_registered"
                echo ""
                echo -e "${YELLOW}手动清理命令:${NC}"
                for service in $still_registered; do
                    echo "  sudo systemctl stop $service"
                    echo "  sudo systemctl disable $service"
                    echo "  sudo rm -f /etc/systemd/system/$service"
                    echo "  sudo rm -f /usr/lib/systemd/system/$service"
                done
            else
                echo -e "${GREEN}所有注册的服务已清理${NC}"
            fi
        fi
    fi
    
    if [ "$leftovers_found" = false ]; then
        echo -e "${GREEN}未发现任何残留文件或进程${NC}"
    else
        echo -e "${YELLOW}请检查上述残留项并手动清理${NC}"
    fi
}

# 显示卸载完成信息
show_completion() {
    echo ""
    echo -e "${GREEN}=====================================${NC}"
    if [ "$DRY_RUN" = true ]; then
        echo -e "${GREEN}PostgreSQL卸载预览完成${NC}"
    else
        echo -e "${GREEN}PostgreSQL卸载完成!${NC}"
    fi
    echo -e "${GREEN}=====================================${NC}"
    
    if [ "$DRY_RUN" = false ]; then
        echo -e "${YELLOW}注意:${NC}"
        echo "1. 如果修改了/etc/profile，请重新加载或重新登录"
        echo "2. 如果有其他应用依赖PostgreSQL，请重新配置"
        echo "3. 备份文件已保存为 /etc/profile.bak（如果存在）"
    fi
}

# 主函数
main() {
    echo -e "${GREEN}PostgreSQL 卸载脚本${NC}"
    echo -e "${GREEN}将完全卸载PostgreSQL及其所有数据${NC}"
    echo ""
    
    # 检查是否需要搜索
    local need_search=true
    if [ -n "$PG_INSTALL_DIR" ] && [ -d "$PG_INSTALL_DIR" ]; then
        need_search=false
    fi
    
    if [ "$need_search" = true ]; then
        search_postgresql
    fi
    
    # 显示将要删除的内容
    show_removal_list
    
    # 确认卸载
    confirm_removal
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}预览模式 - 不会实际删除文件${NC}"
    fi
    
    # 执行卸载步骤
    echo -e "${YELLOW}开始执行卸载步骤...${NC}"
    echo ""
    
    # 步骤1: 停止服务
    echo -e "${CYAN}[1/6] 停止PostgreSQL服务...${NC}"
    stop_services
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ 服务已停止${NC}"
    else
        echo -e "${RED}✗ 停止服务时出现问题${NC}"
    fi
    echo ""
    
    # 步骤2: 删除服务文件
    echo -e "${CYAN}[2/6] 删除systemd服务文件...${NC}"
    remove_services
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ 服务文件已删除${NC}"
    else
        echo -e "${RED}✗ 删除服务文件时出现问题${NC}"
    fi
    echo ""
    
    # 步骤3: 删除文件目录
    echo -e "${CYAN}[3/6] 删除PostgreSQL文件和目录...${NC}"
    remove_files
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ 文件目录已删除${NC}"
    else
        echo -e "${RED}✗ 删除文件目录时出现问题${NC}"
    fi
    echo ""
    
    # 步骤4: 删除配置文件
    echo -e "${CYAN}[4/6] 删除配置文件...${NC}"
    remove_configs
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ 配置文件已删除${NC}"
    else
        echo -e "${RED}✗ 删除配置文件时出现问题${NC}"
    fi
    echo ""
    
    # 步骤5: 删除用户和组
    echo -e "${CYAN}[5/6] 删除PostgreSQL用户和组...${NC}"
    remove_user_group
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ 用户和组已删除${NC}"
    else
        echo -e "${RED}✗ 删除用户和组时出现问题${NC}"
    fi
    echo ""
    
    # 步骤6: 清理系统
    echo -e "${CYAN}[6/6] 清理系统...${NC}"
    cleanup_system
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ 系统清理完成${NC}"
    else
        echo -e "${RED}✗ 系统清理时出现问题${NC}"
    fi
    echo ""
    
    # 最终检查残留文件
    echo -e "${CYAN}最终检查残留文件...${NC}"
    final_cleanup_check
    echo ""
    
    # 显示完成信息
    show_completion
}

# 执行主函数
main "$@"