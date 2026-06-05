#!/bin/bash

# MySQL 完全卸载脚本
# 支持 CentOS 7/8/9、Ubuntu 20/22/24

# 检查是否使用bash执行
if [ -z "$BASH_VERSION" ]; then
    echo "错误: 请使用bash执行此脚本，而不是sh"
    echo "正确用法: bash uninstall_mysql.sh 或 ./uninstall_mysql.sh"
    exit 1
fi

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 参数解析
SKIP_CONFIRM=false
if [ "$1" = "-y" ] || [ "$1" = "--yes" ]; then
    SKIP_CONFIRM=true
fi

# 检查root权限
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}此脚本需要以root权限运行${NC}"
    exit 1
fi

# ======================== 搜索安装信息 ========================

search_mysql() {
    echo -e "${CYAN}============ 搜索MySQL安装信息 ============${NC}"
    echo ""

    FOUND_INSTALLS=()
    FOUND_DATADIRS=()
    FOUND_CONFIGS=()
    FOUND_SERVICES=()
    FOUND_SYMLINKS=()

    # 1. 搜索 mysqld 二进制文件
    echo -e "${YELLOW}搜索 mysqld ...${NC}"
    local mysqld_paths=$(find /usr/local /opt /mnt -name "mysqld" -type f 2>/dev/null)
    for p in $mysqld_paths; do
        local install_dir=$(dirname $(dirname "$p"))
        FOUND_INSTALLS+=("$install_dir")
        echo -e "  ${GREEN}安装目录: $install_dir${NC}"
    done

    # 2. 搜索数据目录
    echo -e "${YELLOW}搜索数据目录 ...${NC}"
    for d in /mnt/data/mysql/data /usr/local/mysql/data /opt/mysql/data /var/lib/mysql; do
        if [ -d "$d" ] && [ -f "$d/ibdata1" ]; then
            FOUND_DATADIRS+=("$d")
            echo -e "  ${GREEN}数据目录: $d${NC}"
        fi
    done

    # 3. 搜索配置文件
    echo -e "${YELLOW}搜索配置文件 ...${NC}"
    for f in /etc/my.cnf /etc/mysql/my.cnf /root/.my.cnf; do
        if [ -f "$f" ]; then
            FOUND_CONFIGS+=("$f")
            echo -e "  ${GREEN}配置文件: $f${NC}"
        fi
    done

    # 4. 搜索服务文件
    echo -e "${YELLOW}搜索服务 ...${NC}"
    # systemd服务
    for f in /etc/systemd/system/mysql*.service /usr/lib/systemd/system/mysql*.service; do
        if [ -f "$f" ]; then
            FOUND_SERVICES+=("$f")
            echo -e "  ${GREEN}服务文件: $f${NC}"
        fi
    done
    # init.d服务
    if [ -f "/etc/init.d/mysql" ]; then
        FOUND_SERVICES+=("/etc/init.d/mysql")
        echo -e "  ${GREEN}服务文件: /etc/init.d/mysql${NC}"
    fi
    # systemd中运行的服务
    local active_services=$(systemctl list-units --all --type=service --no-legend 2>/dev/null | grep -i mysql | awk '{print $1}')
    for s in $active_services; do
        echo -e "  ${GREEN}运行服务: $s${NC}"
    done

    # 5. 搜索软链接
    echo -e "${YELLOW}搜索软链接 ...${NC}"
    for link in /usr/bin/mysql /usr/bin/mysqld /usr/bin/mysqladmin; do
        if [ -L "$link" ]; then
            FOUND_SYMLINKS+=("$link")
            local target=$(readlink -f "$link" 2>/dev/null)
            echo -e "  ${GREEN}软链接: $link -> $target${NC}"
        fi
    done

    # 6. 检查用户和组
    echo -e "${YELLOW}检查用户和组 ...${NC}"
    if id -u mysql &>/dev/null; then
        echo -e "  ${GREEN}用户: mysql (uid=$(id -u mysql))${NC}"
    fi
    if getent group mysql &>/dev/null; then
        echo -e "  ${GREEN}组: mysql (gid=$(getent group mysql | cut -d: -f3))${NC}"
    fi

    # 7. 检查环境变量
    echo -e "${YELLOW}检查环境变量 ...${NC}"
    if grep -q "MySQL\|MYSQL" /etc/profile 2>/dev/null; then
        echo -e "  ${GREEN}/etc/profile 中存在MySQL环境变量配置${NC}"
    fi
    if [ -f "/etc/profile.d/mysql.sh" ]; then
        echo -e "  ${GREEN}/etc/profile.d/mysql.sh 存在${NC}"
        FOUND_CONFIGS+=("/etc/profile.d/mysql.sh")
    fi

    # 8. 检查libncurses软链接
    echo -e "${YELLOW}检查库文件软链接 ...${NC}"
    for lib in /usr/lib/*/libncurses.so.5 /usr/lib/*/libtinfo.so.5; do
        if [ -L "$lib" ]; then
            echo -e "  ${GREEN}库软链接: $lib${NC}"
        fi
    done

    # 9. 检查临时文件
    echo -e "${YELLOW}检查临时文件 ...${NC}"
    local tmp_count=$(find /tmp -maxdepth 1 -name "mysql*" 2>/dev/null | wc -l)
    if [ "$tmp_count" -gt 0 ]; then
        echo -e "  ${GREEN}/tmp 下有 $tmp_count 个MySQL相关文件${NC}"
    fi

    echo ""
    local total=$((${#FOUND_INSTALLS[@]} + ${#FOUND_DATADIRS[@]} + ${#FOUND_CONFIGS[@]} + ${#FOUND_SERVICES[@]}))
    if [ $total -eq 0 ]; then
        echo -e "${YELLOW}未找到任何MySQL安装痕迹${NC}"
        return 1
    fi
    return 0
}

# ======================== 确认卸载 ========================

confirm_uninstall() {
    if [ "$SKIP_CONFIRM" = true ]; then
        return 0
    fi

    echo -e "${RED}=============================================${NC}"
    echo -e "${RED}警告: 此操作将完全卸载MySQL，包括所有数据!${NC}"
    echo -e "${RED}=============================================${NC}"
    echo ""
    echo "将执行以下操作:"
    echo "  1. 停止并删除所有MySQL服务"
    echo "  2. 删除所有MySQL进程"
    echo "  3. 删除MySQL安装目录"
    echo "  4. 删除MySQL数据目录（所有数据）"
    echo "  5. 删除MySQL配置文件"
    echo "  6. 删除MySQL用户和组"
    echo "  7. 清理环境变量"
    echo "  8. 删除软链接"
    echo "  9. 清理临时文件"
    echo ""
    echo -e "${YELLOW}请确保已备份重要数据!${NC}"
    echo ""
    read -p "是否继续卸载? [y/N]: " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}卸载已取消${NC}"
        exit 0
    fi
}

# ======================== 停止服务和进程 ========================

stop_all_mysql() {
    echo ""
    echo -e "${CYAN}============ 停止MySQL服务和进程 ============${NC}"

    # 停止init.d服务
    if [ -f "/etc/init.d/mysql" ]; then
        echo -e "${YELLOW}停止 init.d/mysql ...${NC}"
        /etc/init.d/mysql stop 2>/dev/null
        echo -e "${GREEN}  ✓ 已停止${NC}"
    fi

    # 停止所有systemd mysql服务
    local services=$(systemctl list-units --all --type=service --no-legend 2>/dev/null | grep -i mysql | awk '{print $1}')
    for service in $services; do
        echo -e "${YELLOW}停止 $service ...${NC}"
        systemctl stop "$service" 2>/dev/null
        systemctl disable "$service" 2>/dev/null
        echo -e "${GREEN}  ✓ 已停止并禁用${NC}"
    done

    # 终止MySQL服务器进程（只杀mysqld相关，不杀脚本自身）
    echo -e "${YELLOW}终止MySQL进程 ...${NC}"
    local current_pid=$$
    local pids=$(pgrep -x "mysqld" 2>/dev/null; pgrep -x "mysqld_safe" 2>/dev/null)
    # 过滤掉当前脚本进程
    pids=$(echo "$pids" | grep -v "^$" | grep -v "^${current_pid}$" || true)
    if [ -n "$pids" ]; then
        for pid in $pids; do
            kill -9 "$pid" 2>/dev/null
            echo -e "${GREEN}  ✓ 已终止进程: $pid${NC}"
        done
    else
        echo -e "${GREEN}  ✓ 没有运行中的MySQL进程${NC}"
    fi
}

# ======================== 删除服务文件 ========================

remove_services() {
    echo ""
    echo -e "${CYAN}============ 删除服务文件 ============${NC}"

    # systemd服务文件
    for f in "${FOUND_SERVICES[@]}"; do
        if [ -e "$f" ]; then
            rm -f "$f"
            echo -e "${GREEN}  ✓ 已删除: $f${NC}"
        fi
    done

    # 额外搜索删除
    for f in /etc/systemd/system/mysql*.service /usr/lib/systemd/system/mysql*.service /etc/init.d/mysql; do
        if [ -e "$f" ]; then
            rm -f "$f"
            echo -e "${GREEN}  ✓ 已删除: $f${NC}"
        fi
    done

    # 重新加载systemd
    systemctl daemon-reload 2>/dev/null
    systemctl reset-failed 2>/dev/null
    echo -e "${GREEN}  ✓ systemd配置已重新加载${NC}"
}

# ======================== 删除安装和数据目录 ========================

remove_directories() {
    echo ""
    echo -e "${CYAN}============ 删除安装和数据目录 ============${NC}"

    # 删除安装目录
    for dir in "${FOUND_INSTALLS[@]}"; do
        if [ -d "$dir" ]; then
            rm -rf "$dir"
            echo -e "${GREEN}  ✓ 已删除安装目录: $dir${NC}"
        fi
    done

    # 删除安装目录下的已知子目录（tmp、log等）
    for dir in "${FOUND_INSTALLS[@]}"; do
        local parent=$(dirname "$dir")
        for subdir in tmp log binlog archive; do
            if [ -d "$parent/$subdir" ]; then
                rm -rf "$parent/$subdir"
                echo -e "${GREEN}  ✓ 已删除: $parent/$subdir${NC}"
            fi
        done
    done

    # 删除父目录（如 /mnt/data/mysql）
    for dir in "${FOUND_INSTALLS[@]}"; do
        local parent=$(dirname "$dir")
        if [ -d "$parent" ]; then
            local remaining=$(ls -A "$parent" 2>/dev/null | wc -l)
            if [ "$remaining" -eq 0 ]; then
                rm -rf "$parent"
                echo -e "${GREEN}  ✓ 已删除空父目录: $parent${NC}"
            else
                echo -e "${YELLOW}  ⚠ 父目录不为空，强制删除: $parent${NC}"
                rm -rf "$parent"
                echo -e "${GREEN}  ✓ 已删除: $parent${NC}"
            fi
        fi
    done

    # 删除数据目录（如果不在安装目录下）
    for dir in "${FOUND_DATADIRS[@]}"; do
        if [ -d "$dir" ]; then
            rm -rf "$dir"
            echo -e "${GREEN}  ✓ 已删除数据目录: $dir${NC}"
        fi
    done

    # 删除额外的mysql相关目录
    for d in /usr/local/mysql /opt/mysql; do
        if [ -d "$d" ]; then
            rm -rf "$d"
            echo -e "${GREEN}  ✓ 已删除: $d${NC}"
        fi
    done
}

# ======================== 删除配置文件 ========================

remove_configs() {
    echo ""
    echo -e "${CYAN}============ 删除配置文件 ============${NC}"

    for f in "${FOUND_CONFIGS[@]}"; do
        if [ -e "$f" ]; then
            rm -f "$f"
            echo -e "${GREEN}  ✓ 已删除: $f${NC}"
        fi
    done

    # 额外清理
    for f in /etc/my.cnf /etc/mysql/my.cnf /root/.my.cnf /etc/profile.d/mysql.sh; do
        if [ -e "$f" ]; then
            rm -f "$f"
            echo -e "${GREEN}  ✓ 已删除: $f${NC}"
        fi
    done
}

# ======================== 删除用户和组 ========================

remove_user_group() {
    echo ""
    echo -e "${CYAN}============ 删除用户和组 ============${NC}"

    if id -u mysql &>/dev/null; then
        # 先kill该用户的mysqld进程
        pkill -9 -u mysql -x "mysqld" 2>/dev/null
        pkill -9 -u mysql -x "mysqld_safe" 2>/dev/null
        userdel mysql 2>/dev/null
        echo -e "${GREEN}  ✓ 已删除用户: mysql${NC}"
    else
        echo -e "${YELLOW}  mysql用户不存在${NC}"
    fi

    if getent group mysql &>/dev/null; then
        groupdel mysql 2>/dev/null
        echo -e "${GREEN}  ✓ 已删除组: mysql${NC}"
    else
        echo -e "${YELLOW}  mysql组不存在${NC}"
    fi
}

# ======================== 清理环境变量 ========================

cleanup_environment() {
    echo ""
    echo -e "${CYAN}============ 清理环境变量 ============${NC}"

    # 清理 /etc/profile
    if grep -q "MySQL\|MYSQL" /etc/profile 2>/dev/null; then
        cp /etc/profile /etc/profile.backup.$(date +%Y%m%d_%H%M%S)
        sed -i '/# MySQL Environment/,/# End MySQL Environment/d' /etc/profile
        sed -i '/# MySQL Environment Variables/,/^$/d' /etc/profile
        echo -e "${GREEN}  ✓ 已清理 /etc/profile 中的MySQL配置${NC}"
        echo -e "${CYAN}  (已备份到 /etc/profile.backup.*)${NC}"
    fi

    # 清理 /etc/profile.d/
    if [ -f "/etc/profile.d/mysql.sh" ]; then
        rm -f /etc/profile.d/mysql.sh
        echo -e "${GREEN}  ✓ 已删除 /etc/profile.d/mysql.sh${NC}"
    fi

    # 立即生效（清除当前会话中的MySQL相关环境变量）
    unset MYSQL_HOME 2>/dev/null
    source /etc/profile > /dev/null 2>&1
    echo -e "${GREEN}  ✓ 环境变量已立即生效${NC}"
}

# ======================== 删除软链接 ========================

remove_symlinks() {
    echo ""
    echo -e "${CYAN}============ 删除软链接 ============${NC}"

    for link in "${FOUND_SYMLINKS[@]}"; do
        if [ -L "$link" ]; then
            rm -f "$link"
            echo -e "${GREEN}  ✓ 已删除: $link${NC}"
        fi
    done

    # 额外检查
    for link in /usr/bin/mysql /usr/bin/mysqld /usr/bin/mysqladmin /usr/bin/mysqldump; do
        if [ -L "$link" ]; then
            rm -f "$link"
            echo -e "${GREEN}  ✓ 已删除: $link${NC}"
        fi
    done

    # 清理我们创建的libncurses5软链接
    for lib in /usr/lib/*/libncurses.so.5 /usr/lib/*/libtinfo.so.5; do
        if [ -L "$lib" ]; then
            rm -f "$lib"
            echo -e "${GREEN}  ✓ 已删除库软链接: $lib${NC}"
        fi
    done
}

# ======================== 清理临时文件 ========================

cleanup_temp() {
    echo ""
    echo -e "${CYAN}============ 清理临时文件 ============${NC}"

    local count=0
    for f in /tmp/mysql*; do
        if [ -e "$f" ]; then
            rm -rf "$f"
            echo -e "${GREEN}  ✓ 已删除: $f${NC}"
            ((count++))
        fi
    done

    if [ $count -eq 0 ]; then
        echo -e "${YELLOW}  没有需要清理的临时文件${NC}"
    fi
}

# ======================== 最终检查 ========================

final_check() {
    echo ""
    echo -e "${CYAN}============ 最终检查 ============${NC}"

    local issues=0

    # 检查mysqld
    if command -v mysqld &>/dev/null; then
        echo -e "${RED}  ✗ mysqld 仍然存在: $(which mysqld)${NC}"
        ((issues++))
    fi

    # 检查进程（只检查mysqld，不匹配脚本自身）
    if pgrep -x "mysqld" &>/dev/null || pgrep -x "mysqld_safe" &>/dev/null; then
        echo -e "${RED}  ✗ MySQL进程仍在运行${NC}"
        ((issues++))
    fi

    # 检查服务
    if systemctl is-active --quiet mysql 2>/dev/null; then
        echo -e "${RED}  ✗ MySQL服务仍在运行${NC}"
        ((issues++))
    fi

    # 检查mysql用户
    if id -u mysql &>/dev/null; then
        echo -e "${YELLOW}  ⚠ mysql用户仍存在${NC}"
        ((issues++))
    fi

    if [ $issues -eq 0 ]; then
        echo -e "${GREEN}  ✓ MySQL已完全卸载干净${NC}"
    else
        echo -e "${YELLOW}  ⚠ 发现 $issues 个残留项，可能需要手动处理${NC}"
    fi
}

# ======================== 显示摘要 ========================

show_summary() {
    echo ""
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}MySQL 卸载完成!${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo ""
    echo -e "${CYAN}已执行的操作:${NC}"
    echo "  ✓ 停止并删除所有MySQL服务和进程"
    echo "  ✓ 删除服务文件 (systemd / init.d)"
    echo "  ✓ 删除安装目录和数据目录"
    echo "  ✓ 删除配置文件 (/etc/my.cnf)"
    echo "  ✓ 删除mysql用户和组"
    echo "  ✓ 清理环境变量 (/etc/profile)"
    echo "  ✓ 删除软链接 (/usr/bin/mysql)"
    echo "  ✓ 清理临时文件"
    echo ""
    echo -e "${YELLOW}注意事项:${NC}"
    echo "  1. 已备份/etc/profile到 /etc/profile.backup.*"
    echo "  2. 请执行 source /etc/profile 或重新登录使环境变量生效"
    echo "  3. 如使用APT/YUM安装的MySQL，可能需要额外执行:"
    echo "     CentOS: yum remove mysql-community-server"
    echo "     Ubuntu: apt-get remove mysql-server"
    echo ""
}

# ======================== 主函数 ========================

main() {
    echo -e "${GREEN}MySQL 完全卸载脚本${NC}"
    echo -e "${CYAN}系统: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2)${NC}"
    echo ""

    # 搜索安装信息
    if ! search_mysql; then
        echo -e "${YELLOW}未找到MySQL安装，无需卸载${NC}"
        exit 0
    fi

    # 确认卸载
    confirm_uninstall

    echo ""
    echo -e "${RED}开始卸载MySQL...${NC}"

    # 执行卸载步骤
    stop_all_mysql
    remove_services
    remove_directories
    remove_configs
    remove_user_group
    cleanup_environment
    remove_symlinks
    cleanup_temp
    final_check
    show_summary
}

main "$@"
