#!/bin/bash

# MySQL 自动化卸载脚本
# 支持 x86 和 ARM 架构
# 作者: 基于PostgreSQL卸载脚本改编

# 不使用 set -e，避免意外退出
# set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 检查是否为root用户
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}此脚本需要以root权限运行${NC}"
   exit 1
fi

# 查找MySQL安装信息
find_mysql_installation() {
    echo -e "${YELLOW}正在查找MySQL安装信息...${NC}"
    
    # 查找mysqld服务
    local mysql_services=$(systemctl list-units --all --type=service --no-legend | grep -i mysql | awk '{print $1}')
    
    if [ -n "$mysql_services" ]; then
        echo -e "${GREEN}找到MySQL服务:${NC}"
        local index=1
        for service in $mysql_services; do
            echo "  $index. $service"
            ((index++))
        done
    fi
    
    # 查找常见的MySQL安装目录
    local common_dirs=(
        "/usr/local/mysql"
        "/usr/local/mysql*"
        "/opt/mysql"
        "/opt/mysql*"
        "/mnt/data/mysql"
        "/mnt/data/mysql*"
    )
    
    echo ""
    echo -e "${CYAN}查找MySQL安装目录...${NC}"
    
    local found_dirs=()
    for dir_pattern in "${common_dirs[@]}"; do
        for dir in $dir_pattern; do
            if [ -d "$dir" ] && [ -f "$dir/bin/mysqld" ]; then
                found_dirs+=("$dir")
                echo -e "${GREEN}  找到: $dir${NC}"
            fi
        done
    done
    
    # 查找mysql用户
    if id -u mysql &>/dev/null; then
        echo -e "${GREEN}  找到mysql用户${NC}"
    fi
    
    # 查找mysql组
    if getent group mysql &>/dev/null; then
        echo -e "${GREEN}  找到mysql组${NC}"
    fi
    
    # 查找环境变量配置
    if grep -q "MYSQL_HOME\|MYSQL_DATA" /etc/profile 2>/dev/null; then
        echo -e "${GREEN}  找到/etc/profile中的MySQL环境变量配置${NC}"
    fi
    
    echo ""
}

# 停止MySQL服务
stop_mysql_service() {
    echo -e "${YELLOW}停止MySQL服务...${NC}"
    
    # 查找所有MySQL相关的服务
    local mysql_services=$(systemctl list-units --all --type=service --no-legend | grep -i mysql | awk '{print $1}')
    
    if [ -z "$mysql_services" ]; then
        echo -e "${YELLOW}未找到MySQL服务${NC}"
        return 0
    fi
    
    for service in $mysql_services; do
        echo -e "${CYAN}停止服务: $service${NC}"
        systemctl stop "$service" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}  ✓ 服务已停止${NC}"
        else
            echo -e "${YELLOW}  ⚠ 服务停止失败或未运行${NC}"
        fi
        
        # 禁用服务
        systemctl disable "$service" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}  ✓ 服务已禁用${NC}"
        fi
    done
    
    # 检查是否还有MySQL进程在运行
    local mysql_pids=$(pgrep -f "mysql" 2>/dev/null)
    if [ -n "$mysql_pids" ]; then
        echo -e "${YELLOW}发现MySQL进程仍在运行，尝试强制终止...${NC}"
        for pid in $mysql_pids; do
            echo -e "${CYAN}  终止进程: $pid${NC}"
            kill -9 $pid 2>/dev/null
        done
    fi
    
    echo ""
}

# 删除MySQL服务文件
remove_mysql_service() {
    echo -e "${YELLOW}删除MySQL服务文件...${NC}"
    
    # 删除systemd服务文件
    local service_files=(
        "/etc/systemd/system/mysql*.service"
        "/usr/lib/systemd/system/mysql*.service"
    )
    
    for pattern in "${service_files[@]}"; do
        for file in $pattern; do
            if [ -f "$file" ]; then
                echo -e "${CYAN}  删除: $file${NC}"
                rm -f "$file"
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}    ✓ 已删除${NC}"
                else
                    echo -e "${RED}    ✗ 删除失败${NC}"
                fi
            fi
        done
    done
    
    # 重新加载systemd配置
    systemctl daemon-reload
    echo -e "${GREEN}  ✓ systemd配置已重新加载${NC}"
    
    echo ""
}

# 删除MySQL安装目录
remove_mysql_installation() {
    echo -e "${YELLOW}删除MySQL安装目录...${NC}"
    
    # 查找常见的MySQL安装目录
    local common_dirs=(
        "/usr/local/mysql"
        "/usr/local/mysql*"
        "/opt/mysql"
        "/opt/mysql*"
        "/mnt/data/mysql"
        "/mnt/data/mysql*"
    )
    
    local found_dirs=()
    for dir_pattern in "${common_dirs[@]}"; do
        for dir in $dir_pattern; do
            if [ -d "$dir" ]; then
                found_dirs+=("$dir")
            fi
        done
    done
    
    if [ ${#found_dirs[@]} -eq 0 ]; then
        echo -e "${YELLOW}未找到MySQL安装目录${NC}"
        return 0
    fi
    
    echo -e "${CYAN}找到以下MySQL相关目录:${NC}"
    local index=1
    for dir in "${found_dirs[@]}"; do
        echo "  $index. $dir"
        ((index++))
    done
    
    echo ""
    echo -e "${RED}警告: 删除操作不可恢复!${NC}"
    echo "1. 删除所有找到的目录"
    echo "2. 选择性删除"
    echo "3. 跳过删除"
    echo ""
    read -p "请选择 [1/2/3]: " delete_choice
    
    case $delete_choice in
        "1")
            for dir in "${found_dirs[@]}"; do
                echo -e "${CYAN}  删除: $dir${NC}"
                rm -rf "$dir"
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}    ✓ 已删除${NC}"
                else
                    echo -e "${RED}    ✗ 删除失败${NC}"
                fi
            done
            ;;
        "2")
            for dir in "${found_dirs[@]}"; do
                echo ""
                read -p "是否删除 $dir ? [y/N]: " confirm
                if [[ $confirm =~ ^[Yy]$ ]]; then
                    echo -e "${CYAN}  删除: $dir${NC}"
                    rm -rf "$dir"
                    if [ $? -eq 0 ]; then
                        echo -e "${GREEN}    ✓ 已删除${NC}"
                    else
                        echo -e "${RED}    ✗ 删除失败${NC}"
                    fi
                else
                    echo -e "${YELLOW}    跳过${NC}"
                fi
            done
            ;;
        "3")
            echo -e "${YELLOW}跳过删除安装目录${NC}"
            ;;
        *)
            echo -e "${YELLOW}无效选择，跳过删除${NC}"
            ;;
    esac
    
    echo ""
}

# 删除MySQL用户和组
remove_mysql_user() {
    echo -e "${YELLOW}删除MySQL用户和组...${NC}"
    
    # 检查mysql用户是否存在
    if id -u mysql &>/dev/null; then
        echo -e "${CYAN}找到mysql用户${NC}"
        read -p "是否删除mysql用户? [y/N]: " confirm
        if [[ $confirm =~ ^[Yy]$ ]]; then
            # 先删除用户
            userdel mysql 2>/dev/null
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}  ✓ mysql用户已删除${NC}"
            else
                echo -e "${RED}  ✗ mysql用户删除失败${NC}"
            fi
        else
            echo -e "${YELLOW}  跳过删除mysql用户${NC}"
        fi
    else
        echo -e "${YELLOW}未找到mysql用户${NC}"
    fi
    
    # 检查mysql组是否存在
    if getent group mysql &>/dev/null; then
        echo -e "${CYAN}找到mysql组${NC}"
        read -p "是否删除mysql组? [y/N]: " confirm
        if [[ $confirm =~ ^[Yy]$ ]]; then
            # 先删除组
            groupdel mysql 2>/dev/null
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}  ✓ mysql组已删除${NC}"
            else
                echo -e "${RED}  ✗ mysql组删除失败${NC}"
            fi
        else
            echo -e "${YELLOW}  跳过删除mysql组${NC}"
        fi
    else
        echo -e "${YELLOW}未找到mysql组${NC}"
    fi
    
    echo ""
}

# 清理环境变量配置
cleanup_environment() {
    echo -e "${YELLOW}清理环境变量配置...${NC}"
    
    # 检查/etc/profile中是否有MySQL配置
    if grep -q "MYSQL_HOME\|MYSQL_DATA\|MySQL" /etc/profile 2>/dev/null; then
        echo -e "${CYAN}找到/etc/profile中的MySQL配置${NC}"
        read -p "是否清理MySQL环境变量配置? [y/N]: " confirm
        if [[ $confirm =~ ^[Yy]$ ]]; then
            # 备份/etc/profile
            cp /etc/profile /etc/profile.backup.$(date +%Y%m%d_%H%M%S)
            echo -e "${GREEN}  ✓ 已备份/etc/profile${NC}"
            
            # 删除MySQL相关的环境变量配置
            sed -i '/# MySQL Environment/,/# End MySQL Environment/d' /etc/profile
            sed -i '/# MySQL Environment Variables/,/^$/d' /etc/profile
            
            echo -e "${GREEN}  ✓ MySQL环境变量配置已清理${NC}"
        else
            echo -e "${YELLOW}  跳过清理环境变量配置${NC}"
        fi
    else
        echo -e "${YELLOW}未找到MySQL环境变量配置${NC}"
    fi
    
    echo ""
}

# 清理MySQL配置文件
cleanup_mysql_config() {
    echo -e "${YELLOW}清理MySQL配置文件...${NC}"
    
    # 常见的MySQL配置文件位置
    local config_files=(
        "/etc/my.cnf"
        "/etc/mysql/my.cnf"
        "/usr/local/mysql/etc/my.cnf"
        "/root/.my.cnf"
        "/home/*/.my.cnf"
    )
    
    local found_configs=()
    for config_pattern in "${config_files[@]}"; do
        for config in $config_pattern; do
            if [ -f "$config" ]; then
                found_configs+=("$config")
            fi
        done
    done
    
    if [ ${#found_configs[@]} -eq 0 ]; then
        echo -e "${YELLOW}未找到MySQL配置文件${NC}"
        return 0
    fi
    
    echo -e "${CYAN}找到以下MySQL配置文件:${NC}"
    local index=1
    for config in "${found_configs[@]}"; do
        echo "  $index. $config"
        ((index++))
    done
    
    echo ""
    read -p "是否删除这些配置文件? [y/N]: " confirm
    if [[ $confirm =~ ^[Yy]$ ]]; then
        for config in "${found_configs[@]}"; do
            echo -e "${CYAN}  删除: $config${NC}"
            rm -f "$config"
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}    ✓ 已删除${NC}"
            else
                echo -e "${RED}    ✗ 删除失败${NC}"
            fi
        done
    else
        echo -e "${YELLOW}跳过删除配置文件${NC}"
    fi
    
    echo ""
}

# 清理临时文件
cleanup_temp_files() {
    echo -e "${YELLOW}清理临时文件...${NC}"
    
    # 清理MySQL相关的临时文件
    local temp_files=(
        "/tmp/mysql*"
        "/tmp/mysql_versions_*.html"
        "/tmp/mysql_verify_*.html"
        "/tmp/mysql_cmake.log"
        "/tmp/set_mysql_password.sh"
        "/tmp/mysql_init_output.log"
    )
    
    local cleaned_count=0
    for pattern in "${temp_files[@]}"; do
        for file in $pattern; do
            if [ -e "$file" ]; then
                rm -rf "$file"
                echo -e "${GREEN}  ✓ 已删除: $file${NC}"
                ((cleaned_count++))
            fi
        done
    done
    
    if [ $cleaned_count -eq 0 ]; then
        echo -e "${YELLOW}未找到需要清理的临时文件${NC}"
    fi
    
    echo ""
}

# 显示卸载摘要
show_uninstall_summary() {
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}MySQL 卸载完成!${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo ""
    echo -e "${CYAN}已执行的操作:${NC}"
    echo "  1. 停止MySQL服务"
    echo "  2. 删除MySQL服务文件"
    echo "  3. 删除MySQL安装目录"
    echo "  4. 删除MySQL用户和组"
    echo "  5. 清理环境变量配置"
    echo "  6. 清理MySQL配置文件"
    echo "  7. 清理临时文件"
    echo ""
    echo -e "${YELLOW}注意事项:${NC}"
    echo "  1. 如果有重要的数据，请确保已备份"
    echo "  2. 某些操作可能需要重新登录系统才能生效"
    echo "  3. 如果卸载不完全，请手动检查相关文件和目录"
    echo ""
}

# 主函数
main() {
    echo -e "${GREEN}MySQL 自动化卸载脚本${NC}"
    echo -e "${GREEN}支持 x86 和 ARM 架构${NC}"
    echo ""
    
    # 查找MySQL安装信息
    find_mysql_installation
    
    echo -e "${RED}警告: 此操作将完全卸载MySQL，包括所有数据!${NC}"
    echo -e "${YELLOW}请确保已备份重要数据!${NC}"
    echo ""
    read -p "是否继续卸载? [y/N]: " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}卸载已取消${NC}"
        exit 0
    fi
    
    echo ""
    
    # 停止MySQL服务
    stop_mysql_service
    
    # 删除MySQL服务文件
    remove_mysql_service
    
    # 删除MySQL安装目录
    remove_mysql_installation
    
    # 删除MySQL用户和组
    remove_mysql_user
    
    # 清理环境变量配置
    cleanup_environment
    
    # 清理MySQL配置文件
    cleanup_mysql_config
    
    # 清理临时文件
    cleanup_temp_files
    
    # 显示卸载摘要
    show_uninstall_summary
}

# 执行主函数
main "$@"
