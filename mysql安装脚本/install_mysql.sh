#!/bin/bash

# MySQL 自动化安装脚本
# 支持 x86 和 ARM 架构
# 作者: 基于PostgreSQL安装脚本改编

# 不使用 set -e，避免意外退出
# set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 默认配置变量
DEFAULT_MYSQL_VERSION="8.0.35"
DEFAULT_MYSQL_USER="mysql"
DEFAULT_MYSQL_GROUP="mysql"
DEFAULT_MYSQL_HOME="/mnt/data/mysql"
DEFAULT_MYSQL_PORT="3306"
DEFAULT_MYSQL_PASSWORD="mysql"
DEFAULT_MYSQL_ROOT_PASSWORD="root"

# 存储选择的插件
SELECTED_PLUGINS=""

# 代理配置
USE_PROXY=""
PROXY_HOST=""
PROXY_PORT=""
PROXY_USER=""
PROXY_PASS=""

# 离线安装模式
OFFLINE_MODE=""
OFFLINE_TARBALL_PATH=""

# 镜像地址配置
MYSQL_MIRROR=""
MIRROR_NAME=""

# 用户输入确认函数
confirm_configuration() {
    while true; do
        echo -e "${YELLOW}请确认MySQL安装配置:${NC}"
        echo -e "MySQL版本: ${GREEN}$MYSQL_VERSION${NC}"
        echo -e "下载镜像: ${GREEN}${MIRROR_NAME:-官网镜像}${NC}"
        echo -e "用户名: ${GREEN}$DEFAULT_MYSQL_USER${NC}"
        echo -e "用户组: ${GREEN}$DEFAULT_MYSQL_GROUP${NC}"
        echo -e "安装目录: ${GREEN}$DEFAULT_MYSQL_HOME${NC}"
        echo -e "端口号: ${GREEN}$DEFAULT_MYSQL_PORT${NC}"
        echo -e "密码: ${GREEN}$DEFAULT_MYSQL_PASSWORD${NC}"
        echo -e "Root密码: ${GREEN}$DEFAULT_MYSQL_ROOT_PASSWORD${NC}"
        echo ""

        echo "1. 使用默认配置"
        echo "2. 自定义配置"
        echo "3. 重新选择版本"
        echo "4. 更换下载镜像源"
        echo "b. 返回上级菜单"
        echo "q. 退出安装"
        echo ""
        
        read -p "请选择 [1/2/3/4/b/q]: " config_choice

        case $config_choice in
            "b"|"B")
                echo -e "${YELLOW}返回上级菜单...${NC}"
                return 1
                ;;
            "q"|"Q")
                echo -e "${RED}安装已取消${NC}"
                exit 0
                ;;
            "1")
                MYSQL_USER=$DEFAULT_MYSQL_USER
                MYSQL_GROUP=$DEFAULT_MYSQL_GROUP
                MYSQL_HOME=$DEFAULT_MYSQL_HOME
                MYSQL_PORT=$DEFAULT_MYSQL_PORT
                MYSQL_PASSWORD=$DEFAULT_MYSQL_PASSWORD
                MYSQL_ROOT_PASSWORD=$DEFAULT_MYSQL_ROOT_PASSWORD
                break
                ;;
            "2")
                read -p "请输入用户名 [$DEFAULT_MYSQL_USER]: " input_user
                MYSQL_USER=${input_user:-$DEFAULT_MYSQL_USER}

                read -p "请输入用户组 [$DEFAULT_MYSQL_GROUP]: " input_group
                MYSQL_GROUP=${input_group:-$DEFAULT_MYSQL_GROUP}

                read -p "请输入安装目录 [$DEFAULT_MYSQL_HOME]: " input_home
                MYSQL_HOME=${input_home:-$DEFAULT_MYSQL_HOME}

                read -p "请输入端口号 [$DEFAULT_MYSQL_PORT]: " input_port
                MYSQL_PORT=${input_port:-$DEFAULT_MYSQL_PORT}

                read -s -p "请输入密码 [默认: mysql]: " input_password
                echo ""
                if [ -z "$input_password" ]; then
                    MYSQL_PASSWORD=$DEFAULT_MYSQL_PASSWORD
                else
                    MYSQL_PASSWORD=$input_password
                fi

                read -s -p "请输入Root密码 [默认: root]: " input_root_password
                echo ""
                if [ -z "$input_root_password" ]; then
                    MYSQL_ROOT_PASSWORD=$DEFAULT_MYSQL_ROOT_PASSWORD
                else
                    MYSQL_ROOT_PASSWORD=$input_root_password
                fi
                break
                ;;
            "3")
                echo -e "${YELLOW}重新选择版本...${NC}"
                select_version
                continue
                ;;
            "4")
                echo -e "${YELLOW}更换下载镜像源...${NC}"
                select_mirror
                continue
                ;;
            *)
                echo -e "${RED}无效选择，请重新输入${NC}"
                ;;
        esac
    done
    
    # 计算派生路径
    MYSQL_INSTALL_DIR="${MYSQL_HOME}/mysql-${MYSQL_VERSION}"
    MYSQL_DATA_DIR="${MYSQL_HOME}/data"
    MYSQL_TMP_DIR="${MYSQL_HOME}/tmp"
    MYSQL_LOG_DIR="${MYSQL_HOME}/log"
    
    echo ""
    echo -e "${GREEN}最终配置:${NC}"
    echo -e "MySQL版本: $MYSQL_VERSION"
    echo -e "下载镜像: ${MIRROR_NAME:-官网镜像}"
    echo -e "用户名: $MYSQL_USER"
    echo -e "用户组: $MYSQL_GROUP"
    echo -e "安装目录: $MYSQL_INSTALL_DIR"
    echo -e "数据目录: $MYSQL_DATA_DIR"
    echo -e "端口号: $MYSQL_PORT"
    echo -e "密码: $MYSQL_PASSWORD"
    echo -e "Root密码: $MYSQL_ROOT_PASSWORD"
    echo ""

    while true; do
        echo "1. 确认开始安装"
        echo "2. 重新配置"
        echo "3. 重新选择版本"
        echo "4. 更换下载镜像源"
        echo "b. 返回上级菜单"
        echo "q. 退出安装"
        echo ""
        
        read -p "请选择 [1/2/3/4/b/q]: " final_choice

        case $final_choice in
            "b"|"B")
                echo -e "${YELLOW}返回上级菜单...${NC}"
                confirm_configuration
                local result=$?
                return $result
                ;;
            "q"|"Q")
                echo -e "${RED}安装已取消${NC}"
                exit 0
                ;;
            "1")
                echo -e "${GREEN}开始安装...${NC}"
                return 0
                ;;
            "2")
                confirm_configuration
                return
                ;;
            "3")
                echo -e "${YELLOW}重新选择版本...${NC}"
                select_version
                confirm_configuration
                return
                ;;
            "4")
                echo -e "${YELLOW}更换下载镜像源...${NC}"
                select_mirror
                confirm_configuration
                return
                ;;
            *)
                echo -e "${RED}无效选择，请重新输入${NC}"
                ;;
        esac
    done
}

# 镜像源选择函数
select_mirror() {
    echo -e "${YELLOW}请选择MySQL下载镜像源:${NC}"
    echo "1. 官网镜像 (https://dev.mysql.com)"
    echo "2. 腾讯云镜像 (https://mirrors.cloud.tencent.com)"
    echo "3. 阿里云镜像 (https://mirrors.aliyun.com)"
    echo "b. 返回上级菜单"
    echo "q. 退出安装"
    echo ""

    read -p "请选择 [1/2/3/b/q]: " mirror_choice

    case $mirror_choice in
        "b"|"B")
            echo -e "${YELLOW}返回上级菜单...${NC}"
            return 1
            ;;
        "q"|"Q")
            echo -e "${RED}安装已取消${NC}"
            exit 0
            ;;
        "1")
            MYSQL_MIRROR="https://dev.mysql.com/get/Downloads"
            MIRROR_NAME="官网镜像"
            echo -e "${GREEN}已选择官网镜像源${NC}"
            return 0
            ;;
        "2")
            MYSQL_MIRROR="https://mirrors.cloud.tencent.com/mysql"
            MIRROR_NAME="腾讯云镜像"
            echo -e "${GREEN}已选择腾讯云镜像源${NC}"
            return 0
            ;;
        "3")
            MYSQL_MIRROR="https://mirrors.aliyun.com/mysql"
            MIRROR_NAME="阿里云镜像"
            echo -e "${GREEN}已选择阿里云镜像源${NC}"
            return 0
            ;;
        *)
            echo -e "${RED}无效选择，请重新输入${NC}"
            select_mirror
            return $?
            ;;
    esac
}

# 版本选择函数
select_version() {
    # 先尝试配置代理（如果需要）
    local need_proxy=false
    
    while true; do
        echo -e "${YELLOW}请选择MySQL版本:${NC}"
        echo "1. 使用默认版本 ($DEFAULT_MYSQL_VERSION)"
        echo "2. 查询8.0.x版本"
        echo "3. 查询8.4.x版本"
        echo "4. 查询9.0.x版本"
        echo "5. 手动输入版本号"
        echo "b. 返回上级菜单"
        echo "q. 退出安装"
        echo ""
        
        read -p "请选择 [1-5/b/q]: " version_mode
        
        case $version_mode in
            "b"|"B")
                echo -e "${YELLOW}返回上级菜单...${NC}"
                return 1
                ;;
            "q"|"Q")
                echo -e "${RED}安装已取消${NC}"
                exit 0
                ;;
            "1")
                MYSQL_VERSION=$DEFAULT_MYSQL_VERSION
                echo -e "${GREEN}使用默认版本: $MYSQL_VERSION${NC}"
                break
                ;;
            "2")
                if [ "$need_proxy" = false ]; then
                    query_mysql_versions "8.0"
                    if [ -z "$MYSQL_VERSION" ]; then
                        echo -e "${YELLOW}查询失败，可能需要代理${NC}"
                        if setup_proxy; then
                            need_proxy=true
                            query_mysql_versions "8.0"
                        fi
                    fi
                else
                    query_mysql_versions "8.0"
                fi
                if [ -n "$MYSQL_VERSION" ]; then
                    break
                fi
                ;;
            "3")
                if [ "$need_proxy" = false ]; then
                    query_mysql_versions "8.4"
                    if [ -z "$MYSQL_VERSION" ]; then
                        echo -e "${YELLOW}查询失败，可能需要代理${NC}"
                        if setup_proxy; then
                            need_proxy=true
                            query_mysql_versions "8.4"
                        fi
                    fi
                else
                    query_mysql_versions "8.4"
                fi
                if [ -n "$MYSQL_VERSION" ]; then
                    break
                fi
                ;;
            "4")
                if [ "$need_proxy" = false ]; then
                    query_mysql_versions "9.0"
                    if [ -z "$MYSQL_VERSION" ]; then
                        echo -e "${YELLOW}查询失败，可能需要代理${NC}"
                        if setup_proxy; then
                            need_proxy=true
                            query_mysql_versions "9.0"
                        fi
                    fi
                else
                    query_mysql_versions "9.0"
                fi
                if [ -n "$MYSQL_VERSION" ]; then
                    break
                fi
                ;;
            "5")
                while true; do
                    read -p "请输入完整的MySQL版本号 (例如: 8.0.35) 或输入 'b' 返回主菜单: " custom_version
                    if [ "$custom_version" = "b" ] || [ "$custom_version" = "B" ]; then
                        break
                    elif [[ "$custom_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                        MYSQL_VERSION=$custom_version
                        echo -e "${GREEN}使用自定义版本: $MYSQL_VERSION${NC}"
                        # 验证版本是否存在
                        if verify_version_exists "$MYSQL_VERSION"; then
                            break 2  # 退出两层循环
                        else
                            echo -e "${YELLOW}版本验证失败，请重新输入或返回主菜单${NC}"
                            MYSQL_VERSION=""
                        fi
                    else
                        echo -e "${RED}版本号格式无效，请使用 x.y.z 格式${NC}"
                    fi
                done
                ;;
            *)
                echo -e "${RED}无效选择，请重新输入${NC}"
                ;;
        esac
    done
    
    echo ""
}

# 从官网查询MySQL版本
query_mysql_versions() {
    local major_version="$1"
    
    echo -e "${YELLOW}正在查询MySQL $major_version.x 版本...${NC}"
    
    # 创建临时文件存储版本信息
    local temp_file="/tmp/mysql_versions_$$.html"
    
    # 设置超时时间（秒）
    local timeout=15
    
    # 获取版本列表页面
    if command -v curl &> /dev/null; then
        local curl_opts="-s --connect-timeout $timeout --max-time $timeout"
        if [ -n "$http_proxy" ]; then
            curl_opts="$curl_opts --proxy $http_proxy"
        fi
        
        curl $curl_opts "https://dev.mysql.com/downloads/mysql/" > "$temp_file" 2>/dev/null
        local curl_exit_code=$?
        
        if [ $curl_exit_code -ne 0 ]; then
            echo -e "${RED}连接失败，无法查询版本信息${NC}"
            echo -e "${YELLOW}将使用默认版本: $DEFAULT_MYSQL_VERSION${NC}"
            MYSQL_VERSION=$DEFAULT_MYSQL_VERSION
            rm -f "$temp_file"
            return
        fi
    elif command -v wget &> /dev/null; then
        local wget_opts="-q --timeout=$timeout --tries=1"
        if [ -n "$http_proxy" ]; then
            wget_opts="$wget_opts -e use_proxy=yes -e http_proxy=$http_proxy -e https_proxy=$https_proxy"
        fi
        
        wget $wget_opts -O "$temp_file" "https://dev.mysql.com/downloads/mysql/" 2>/dev/null
        local wget_exit_code=$?
        
        if [ $wget_exit_code -ne 0 ]; then
            echo -e "${RED}连接失败，无法查询版本信息${NC}"
            echo -e "${YELLOW}将使用默认版本: $DEFAULT_MYSQL_VERSION${NC}"
            MYSQL_VERSION=$DEFAULT_MYSQL_VERSION
            rm -f "$temp_file"
            return
        fi
    else
        echo -e "${RED}需要curl或wget来查询版本信息${NC}"
        echo -e "${YELLOW}将使用默认版本: $DEFAULT_MYSQL_VERSION${NC}"
        MYSQL_VERSION=$DEFAULT_MYSQL_VERSION
        return
    fi
    
    if [ ! -f "$temp_file" ] || [ ! -s "$temp_file" ]; then
        echo -e "${RED}无法获取版本信息${NC}"
        echo -e "${YELLOW}将使用默认版本: $DEFAULT_MYSQL_VERSION${NC}"
        MYSQL_VERSION=$DEFAULT_MYSQL_VERSION
        rm -f "$temp_file"
        return
    fi
    
    # 解析HTML获取版本列表
    echo -e "${GREEN}MySQL $major_version.x 可用版本:${NC}"
    echo "----------------------------------------"
    
    local versions_array=()
    local counter=1
    
    # 使用grep和sed提取版本信息
    if command -v python3 &> /dev/null; then
        # 使用Python解析HTML
        versions_array=($(python3 -c "
import re
import sys
try:
    with open('$temp_file', 'r') as f:
        content = f.read()
    
    # 查找指定主版本的所有版本
    pattern = r'mysql-($major_version\.\d+)'
    versions = re.findall(pattern, content)
    
    # 去重并排序
    unique_versions = sorted(set(versions), key=lambda x: tuple(map(int, x.split('.'))), reverse=True)
    
    # 显示前10个最新版本
    for i, version in enumerate(unique_versions[:10]):
        print(f'{i+1}. {version}')
        print(version)
    
except Exception as e:
    print(f'Error: {e}', file=sys.stderr)
" 2>/dev/null))
    else
        # 使用grep和sed的简单方法
        versions_array=($(grep -o "mysql-$major_version\.[0-9]\+" "$temp_file" | sed 's/mysql-//' | sort -u -V -r | head -10))
        counter=1
        for version in "${versions_array[@]}"; do
            echo "$counter. $version"
            ((counter++))
        done
    fi
    
    echo "----------------------------------------"
    echo ""
    
    # 清理临时文件
    rm -f "$temp_file"
    
    # 用户选择版本
    if [ ${#versions_array[@]} -gt 0 ]; then
        echo "b. 返回主菜单"
        read -p "请选择要安装的版本 (输入数字1-${#versions_array[@]}或b): " version_choice
        
        # 验证输入
        if [[ "$version_choice" =~ ^[0-9]+$ ]]; then
            if [ "$version_choice" -ge 1 ] && [ "$version_choice" -le ${#versions_array[@]} ]; then
                local index=$((version_choice - 1))
                MYSQL_VERSION="${versions_array[$index]}"
                echo -e "${GREEN}已选择版本: $MYSQL_VERSION${NC}"
            else
                echo -e "${RED}无效选择${NC}"
                echo -e "${YELLOW}1. 重新查询 $major_version.x 版本${NC}"
                echo -e "${YELLOW}2. 返回主菜单${NC}"
                read -p "请选择 [1/2]: " retry_choice
                case $retry_choice in
                    "1")
                        query_mysql_versions "$major_version"
                        return
                        ;;
                    "2")
                        echo -e "${YELLOW}返回主菜单...${NC}"
                        MYSQL_VERSION=""
                        return
                        ;;
                    *)
                        echo -e "${RED}无效选择${NC}"
                        MYSQL_VERSION=""
                        ;;
                esac
            fi
        elif [[ "$version_choice" =~ ^[bB]$ ]]; then
            echo -e "${YELLOW}返回主菜单...${NC}"
            MYSQL_VERSION=""
            return
        else
            echo -e "${RED}无效输入${NC}"
            echo -e "${YELLOW}1. 重新查询 $major_version.x 版本${NC}"
            echo -e "${YELLOW}2. 返回主菜单${NC}"
            read -p "请选择 [1/2]: " retry_choice
            case $retry_choice in
                "1")
                    query_mysql_versions "$major_version"
                    return
                    ;;
                "2")
                    select_version
                    return
                    ;;
                *)
                    echo -e "${RED}无效选择${NC}"
                    MYSQL_VERSION=""
                    ;;
            esac
        fi
    else
        echo -e "${RED}未找到 $major_version.x 版本${NC}"
        echo -e "${YELLOW}1. 重新查询 $major_version.x 版本${NC}"
        echo -e "${YELLOW}2. 返回主菜单${NC}"
        echo -e "${YELLOW}3. 使用默认版本 ($DEFAULT_MYSQL_VERSION)${NC}"
        read -p "请选择 [1/2/3]: " no_version_choice
        case $no_version_choice in
            "1")
                query_mysql_versions "$major_version"
                return
                ;;
            "2")
                select_version
                return
                ;;
            "3")
                MYSQL_VERSION=$DEFAULT_MYSQL_VERSION
                echo -e "${GREEN}使用默认版本: $MYSQL_VERSION${NC}"
                ;;
            *)
                echo -e "${RED}无效选择${NC}"
                MYSQL_VERSION=""
                ;;
        esac
    fi
}

# 验证版本是否存在
verify_version_exists() {
    local version="$1"
    echo -e "${YELLOW}验证MySQL $version 是否存在...${NC}"
    
    # 创建临时文件
    local temp_file="/tmp/mysql_verify_$$.html"
    
    # 检查版本URL是否存在
    local version_url="https://dev.mysql.com/downloads/mysql/${version}.html"
    
    # 设置超时时间（秒）
    local timeout=10
    
    if command -v curl &> /dev/null; then
        # 使用curl，添加超时和代理支持
        local curl_opts="-s --connect-timeout $timeout --max-time $timeout"
        if [ -n "$http_proxy" ]; then
            curl_opts="$curl_opts --proxy $http_proxy"
        fi
        
        http_code=$(curl $curl_opts -o "$temp_file" -w "%{http_code}" "$version_url" 2>/dev/null)
        local curl_exit_code=$?
        
        if [ $curl_exit_code -ne 0 ]; then
            echo -e "${RED}连接失败 (curl错误码: $curl_exit_code)${NC}"
            echo -e "${YELLOW}可能是网络问题或需要代理${NC}"
            rm -f "$temp_file"
            return 2  # 返回2表示网络错误
        fi
    elif command -v wget &> /dev/null; then
        # 使用wget，添加超时和代理支持
        local wget_opts="-q --timeout=$timeout --tries=1"
        if [ -n "$http_proxy" ]; then
            wget_opts="$wget_opts -e use_proxy=yes -e http_proxy=$http_proxy -e https_proxy=$https_proxy"
        fi
        
        wget $wget_opts --spider --server-response "$version_url" 2>&1 | grep "HTTP/" | awk '{print $2}' > "$temp_file"
        http_code=$(cat "$temp_file")
        local wget_exit_code=$?
        
        if [ $wget_exit_code -ne 0 ]; then
            echo -e "${RED}连接失败 (wget错误码: $wget_exit_code)${NC}"
            echo -e "${YELLOW}可能是网络问题或需要代理${NC}"
            rm -f "$temp_file"
            return 2  # 返回2表示网络错误
        fi
    else
        echo -e "${YELLOW}无法验证版本，继续安装...${NC}"
        rm -f "$temp_file"
        return 0
    fi
    
    rm -f "$temp_file"
    
    # 检查HTTP状态码
    if [ "$http_code" = "200" ]; then
        echo -e "${GREEN}版本 $version 存在${NC}"
        return 0
    else
        echo -e "${RED}版本 $version 不存在 (HTTP: $http_code)${NC}"
        return 1
    fi
}

# 配置代理
setup_proxy() {
    echo -e "${YELLOW}检测到网络连接可能需要代理...${NC}"
    echo "1. 不使用代理"
    echo "2. 配置HTTP代理"
    echo "3. 配置SOCKS代理"
    echo "4. 跳过版本验证，直接使用默认版本"
    echo ""
    
    read -p "请选择 [1-4]: " proxy_choice
    
    case $proxy_choice in
        "1")
            echo -e "${GREEN}不使用代理${NC}"
            return 0
            ;;
        "2")
            read -p "请输入代理主机 (例如: 127.0.0.1): " PROXY_HOST
            read -p "请输入代理端口 (例如: 8080): " PROXY_PORT
            read -p "请输入代理用户名 (可选): " PROXY_USER
            if [ -n "$PROXY_USER" ]; then
                read -s -p "请输入代理密码: " PROXY_PASS
                echo ""
            fi
            
            export http_proxy="http://${PROXY_USER:+${PROXY_USER}:}${PROXY_PASS}@${PROXY_HOST}:${PROXY_PORT}"
            export https_proxy="http://${PROXY_USER:+${PROXY_USER}:}${PROXY_PASS}@${PROXY_HOST}:${PROXY_PORT}"
            USE_PROXY="http"
            echo -e "${GREEN}HTTP代理配置完成${NC}"
            ;;
        "3")
            read -p "请输入代理主机 (例如: 127.0.0.1): " PROXY_HOST
            read -p "请输入代理端口 (例如: 1080): " PROXY_PORT
            
            export http_proxy="socks5://${PROXY_HOST}:${PROXY_PORT}"
            export https_proxy="socks5://${PROXY_HOST}:${PROXY_PORT}"
            USE_PROXY="socks5"
            echo -e "${GREEN}SOCKS代理配置完成${NC}"
            ;;
        "4")
            echo -e "${YELLOW}跳过版本验证，使用默认版本${NC}"
            MYSQL_VERSION=$DEFAULT_MYSQL_VERSION
            return 1  # 跳过版本验证
            ;;
        *)
            echo -e "${RED}无效选择，不使用代理${NC}"
            ;;
    esac
    
    return 0
}

# 清理代理环境变量
cleanup_proxy() {
    unset http_proxy
    unset https_proxy
}

# 检测系统架构
ARCH=$(uname -m)
if [[ $ARCH == "x86_64" ]]; then
    ARCH_TYPE="x86_64"
    echo -e "${GREEN}检测到 x86_64 架构${NC}"
elif [[ $ARCH == "aarch64" ]]; then
    ARCH_TYPE="arm64"
    echo -e "${GREEN}检测到 ARM64 架构${NC}"
else
    echo -e "${RED}不支持的架构: $ARCH${NC}"
    exit 1
fi

# 检查是否为root用户
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}此脚本需要以root权限运行${NC}"
   exit 1
fi

# 安装依赖函数
install_dependencies() {
    echo -e "${YELLOW}正在安装依赖包...${NC}"
    
    # 离线模式下，只显示依赖列表，不尝试安装
    if [ "$OFFLINE_MODE" = "true" ]; then
        echo -e "${YELLOW}离线安装模式: 跳过在线依赖安装${NC}"
        echo -e "${CYAN}请确保已手动安装以下依赖包:${NC}"
        
        if command -v yum &> /dev/null; then
            echo "  CentOS/RHEL:"
            echo "    - yum groupinstall \"Development Tools\""
            echo "    - yum install cmake gcc gcc-c++ ncurses-devel bison openssl-devel"
        elif command -v apt-get &> /dev/null; then
            echo "  Ubuntu/Debian:"
            echo "    - apt-get install build-essential cmake libncurses5-dev bison libssl-dev"
        fi
        
        # 检查基础依赖是否存在
        echo ""
        echo -e "${CYAN}检查基础依赖...${NC}"
        
        local missing_deps=""
        
        if ! command -v cmake &> /dev/null; then
            missing_deps="$missing_deps cmake"
        fi
        if ! command -v gcc &> /dev/null; then
            missing_deps="$missing_deps gcc"
        fi
        if ! command -v make &> /dev/null; then
            missing_deps="$missing_deps make"
        fi
        
        if [ -n "$missing_deps" ]; then
            echo -e "${RED}缺少以下基础依赖: $missing_deps${NC}"
            echo -e "${YELLOW}请先手动安装这些依赖，或选择退出安装${NC}"
            read -p "是否继续? [y/N]: " continue_install
            if [[ ! $continue_install =~ ^[Yy]$ ]]; then
                exit 1
            fi
        else
            echo -e "${GREEN}基础依赖检查通过${NC}"
        fi
        
        return 0
    fi
    
    # 在线安装模式
    if command -v yum &> /dev/null; then
        # CentOS/RHEL
        yum update -y
        yum groupinstall -y "Development Tools"
        yum install -y cmake gcc gcc-c++ ncurses-devel bison openssl-devel
    elif command -v apt-get &> /dev/null; then
        # Ubuntu/Debian
        apt-get update
        apt-get install -y build-essential cmake libncurses5-dev bison libssl-dev
    else
        echo -e "${RED}不支持的包管理器，请手动安装依赖: cmake, gcc, gcc-c++, ncurses-devel, bison, openssl-devel${NC}"
        exit 1
    fi
}

# 创建用户和目录
create_user_and_dirs() {
    echo -e "${YELLOW}创建MySQL用户和目录...${NC}"
    
    # 创建用户组
    if ! getent group $MYSQL_GROUP &>/dev/null; then
        groupadd $MYSQL_GROUP
    fi
    
    # 创建用户
    if ! id -u $MYSQL_USER &>/dev/null; then
        useradd -m -g $MYSQL_GROUP -s /bin/bash $MYSQL_USER
        echo -e "${GREEN}设置MySQL用户密码...${NC}"
        echo "$MYSQL_USER:$MYSQL_PASSWORD" | chpasswd
    fi
    
    # 创建目录
    mkdir -p $MYSQL_INSTALL_DIR $MYSQL_DATA_DIR $MYSQL_TMP_DIR $MYSQL_LOG_DIR
    
    # 授权
    chown -R $MYSQL_USER:$MYSQL_GROUP $MYSQL_HOME
    chmod -R 755 $MYSQL_HOME
    
    # 检查数据目录
    if [ -d "$MYSQL_DATA_DIR" ] && [ "$(ls -A $MYSQL_DATA_DIR 2>/dev/null)" ]; then
        echo -e "${YELLOW}检测到数据目录已存在: $MYSQL_DATA_DIR${NC}"
        echo ""
        echo "请选择操作:"
        echo "1. 保留现有数据目录"
        echo "2. 备份数据目录后清空"
        echo "3. 直接清空数据目录"
        echo ""
        
        while true; do
            read -p "请选择 [1-3]: " data_choice
            
            case $data_choice in
                "1")
                    echo -e "${GREEN}保留现有数据目录${NC}"
                    break
                    ;;
                "2")
                    backup_dir="${MYSQL_DATA_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
                    echo -e "${YELLOW}备份数据目录到: $backup_dir${NC}"
                    cp -r $MYSQL_DATA_DIR $backup_dir
                    rm -rf ${MYSQL_DATA_DIR}/*
                    echo -e "${GREEN}数据目录已备份并清空${NC}"
                    break
                    ;;
                "3")
                    echo -e "${YELLOW}清空数据目录...${NC}"
                    rm -rf ${MYSQL_DATA_DIR}/*
                    echo -e "${GREEN}数据目录已清空${NC}"
                    break
                    ;;
                *)
                    echo -e "${RED}无效选择，请重新输入${NC}"
                    ;;
            esac
        done
    fi
}

# 检查是否已安装MySQL
check_existing_installation() {
    if [ -d "$MYSQL_INSTALL_DIR" ] && [ "$(ls -A $MYSQL_INSTALL_DIR 2>/dev/null)" ]; then
        echo -e "${YELLOW}检测到MySQL已安装在: $MYSQL_INSTALL_DIR${NC}"
        echo ""
        echo "请选择操作:"
        echo "1. 覆盖现有安装（删除后重新安装）"
        echo "2. 保留现有文件，直接进入编译"
        echo "3. 备份现有安装后重新安装"
        echo "4. 取消安装"
        echo ""
        
        while true; do
            read -p "请选择 [1-4]: " install_choice
            
            case $install_choice in
                "1")
                    echo -e "${YELLOW}删除现有安装...${NC}"
                    rm -rf $MYSQL_INSTALL_DIR
                    echo -e "${GREEN}已删除现有安装${NC}"
                    return 0
                    ;;
                "2")
                    echo -e "${GREEN}保留现有文件，直接进入编译${NC}"
                    return 1
                    ;;
                "3")
                    backup_dir="${MYSQL_INSTALL_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
                    echo -e "${YELLOW}备份现有安装到: $backup_dir${NC}"
                    mv $MYSQL_INSTALL_DIR $backup_dir
                    echo -e "${GREEN}备份完成${NC}"
                    return 0
                    ;;
                "4")
                    echo -e "${RED}取消安装${NC}"
                    exit 0
                    ;;
                *)
                    echo -e "${RED}无效选择，请重新输入${NC}"
                    ;;
            esac
        done
    fi
    
    return 0
}

# 下载和解压MySQL
download_and_extract() {
    echo -e "${YELLOW}下载MySQL ${MYSQL_VERSION}...${NC}"

    cd /tmp

    # 使用选定的镜像源，默认使用官网镜像
    local mirror_base="${MYSQL_MIRROR:-https://dev.mysql.com/get/Downloads}"
    local mirror_display="${MIRROR_NAME:-官网镜像}"

    # 构建下载URL
    DOWNLOAD_URL="${mirror_base}/MySQL-8.0/mysql-${MYSQL_VERSION}.tar.gz"

    # 最大重试次数
    local max_retries=3
    local retry_count=0
    local download_success=0

    while [ $retry_count -lt $max_retries ]; do
        # 检查是否已有源码包，如果是第一次或需要重新下载则删除旧文件
        if [ -f "mysql-${MYSQL_VERSION}.tar.gz" ] && [ $retry_count -eq 0 ]; then
            echo -e "${YELLOW}发现已有源码包，验证完整性...${NC}"
            # 验证现有文件
            if verify_tar_file "mysql-${MYSQL_VERSION}.tar.gz"; then
                echo -e "${GREEN}现有源码包完整，跳过下载${NC}"
                download_success=1
                break
            else
                echo -e "${YELLOW}现有源码包损坏，将重新下载${NC}"
                rm -f "mysql-${MYSQL_VERSION}.tar.gz"
            fi
        elif [ $retry_count -gt 0 ]; then
            echo -e "${YELLOW}第 $((retry_count + 1)) 次尝试下载...${NC}"
        fi

        echo -e "${CYAN}使用镜像源: ${mirror_display}${NC}"
        echo -e "${CYAN}下载地址: ${DOWNLOAD_URL}${NC}"
        echo ""

        # 设置下载超时时间（秒）
        local download_timeout=600

        if command -v wget &> /dev/null; then
            local wget_opts="--timeout=$download_timeout --tries=1 --progress=bar"
            if [ -n "$http_proxy" ]; then
                wget_opts="$wget_opts -e use_proxy=yes -e http_proxy=$http_proxy -e https_proxy=$https_proxy"
            fi
            wget $wget_opts $DOWNLOAD_URL
            local wget_result=$?
            if [ $wget_result -ne 0 ]; then
                echo -e "${RED}wget下载失败 (错误码: $wget_result)${NC}"
                rm -f "mysql-${MYSQL_VERSION}.tar.gz"
                ((retry_count++))
                continue
            fi
        elif command -v curl &> /dev/null; then
            local curl_opts="-L --connect-timeout $download_timeout --max-time $download_timeout --progress-bar -f"
            if [ -n "$http_proxy" ]; then
                curl_opts="$curl_opts --proxy $http_proxy"
            fi
            curl $curl_opts -O $DOWNLOAD_URL
            local curl_result=$?
            if [ $curl_result -ne 0 ]; then
                echo -e "${RED}curl下载失败 (错误码: $curl_result)${NC}"
                rm -f "mysql-${MYSQL_VERSION}.tar.gz"
                ((retry_count++))
                continue
            fi
        else
            echo -e "${RED}需要安装wget或curl来下载MySQL${NC}"
            return 1
        fi

        # 验证下载的文件
        if [ ! -f "mysql-${MYSQL_VERSION}.tar.gz" ]; then
            echo -e "${RED}下载失败：文件不存在${NC}"
            ((retry_count++))
            continue
        fi

        # 检查文件大小（MySQL源码包通常大于100MB）
        local file_size=$(stat -f%z "mysql-${MYSQL_VERSION}.tar.gz" 2>/dev/null || stat -c%s "mysql-${MYSQL_VERSION}.tar.gz" 2>/dev/null)
        local min_size=104857600  # 100MB
        if [ "$file_size" -lt "$min_size" ]; then
            echo -e "${RED}下载的文件大小异常 (${file_size} bytes)，可能不完整${NC}"
            rm -f "mysql-${MYSQL_VERSION}.tar.gz"
            ((retry_count++))
            continue
        fi

        # 验证tar文件完整性
        if verify_tar_file "mysql-${MYSQL_VERSION}.tar.gz"; then
            echo -e "${GREEN}文件完整性验证通过${NC}"
            download_success=1
            break
        else
            echo -e "${RED}文件完整性验证失败，文件可能已损坏${NC}"
            rm -f "mysql-${MYSQL_VERSION}.tar.gz"
            ((retry_count++))
        fi
    done

    if [ $download_success -ne 1 ]; then
        echo -e "${RED}下载失败，已重试 $max_retries 次${NC}"
        echo -e "${YELLOW}建议:${NC}"
        echo "1. 检查网络连接"
        echo "2. 尝试切换镜像源（选择其他镜像或使用代理）"
        echo "3. 手动下载后放置到 /tmp 目录"
        return 1
    fi

    echo -e "${YELLOW}解压MySQL...${NC}"

    # 检查是否已解压
    if [ -d "mysql-${MYSQL_VERSION}" ]; then
        echo -e "${YELLOW}发现已解压的源码，删除后重新解压${NC}"
        rm -rf mysql-${MYSQL_VERSION}
    fi

    # 解压文件
    if ! tar -zxf mysql-${MYSQL_VERSION}.tar.gz; then
        echo -e "${RED}解压失败${NC}"
        rm -f "mysql-${MYSQL_VERSION}.tar.gz"
        return 1
    fi

    # 检查解压是否成功
    if [ ! -d "mysql-${MYSQL_VERSION}" ]; then
        echo -e "${RED}解压后目录不存在，解压可能失败${NC}"
        return 1
    fi

    # 检查是否需要移动文件
    if [ -d "$MYSQL_INSTALL_DIR" ] && [ "$(ls -A $MYSQL_INSTALL_DIR 2>/dev/null)" ]; then
        echo -e "${YELLOW}目标目录已存在文件，使用cp覆盖${NC}"
        cp -rf mysql-${MYSQL_VERSION}/* $MYSQL_INSTALL_DIR/
        rm -rf mysql-${MYSQL_VERSION}
    else
        # 确保安装目录存在
        mkdir -p $MYSQL_INSTALL_DIR
        # 移动到安装目录
        mv mysql-${MYSQL_VERSION}/* $MYSQL_INSTALL_DIR/
        rm -rf mysql-${MYSQL_VERSION}
    fi

    echo -e "${GREEN}源码准备完成${NC}"
    return 0
}

# 验证tar文件完整性
verify_tar_file() {
    local tar_file="$1"

    if [ ! -f "$tar_file" ]; then
        return 1
    fi

    # 使用tar的 -t 选项测试文件完整性（不解压）
    if tar -tzf "$tar_file" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# 编译安装MySQL
compile_install() {
    echo -e "${YELLOW}编译安装MySQL...${NC}"
    
    cd $MYSQL_INSTALL_DIR
    
    # 配置编译选项
    echo -e "${YELLOW}配置编译选项...${NC}"
    
    # 获取CPU核心数
    local cpu_cores=$(nproc 2>/dev/null || echo "1")
    local make_jobs=$cpu_cores
    
    # 如果是生产环境，可以使用更少的核心数以避免系统负载过高
    if [ $cpu_cores -gt 8 ]; then
        make_jobs=$((cpu_cores - 2))
    fi
    
    echo -e "${CYAN}系统信息:${NC}"
    echo "  CPU核心数: $cpu_cores"
    echo "  编译并行数: $make_jobs"
    echo ""
    
    # 配置make并行编译
    export MAKE="make -j$make_jobs"
    
    # 设置环境变量
    export PKG_CONFIG_PATH="${PKG_CONFIG_PATH}"
    
    # 基础编译选项
    CMAKE_OPTIONS="-DCMAKE_INSTALL_PREFIX=$MYSQL_INSTALL_DIR \
                  -DMYSQL_DATADIR=$MYSQL_DATA_DIR \
                  -DMYSQL_TCP_PORT=$MYSQL_PORT \
                  -DMYSQL_UNIX_ADDR=$MYSQL_TMP_DIR/mysql.sock \
                  -DSYSCONFDIR=$MYSQL_INSTALL_DIR/etc \
                  -DWITH_INNOBASE_STORAGE_ENGINE=1 \
                  -DWITH_PARTITION_STORAGE_ENGINE=1 \
                  -DWITH_FEDERATED_STORAGE_ENGINE=1 \
                  -DWITH_BLACKHOLE_STORAGE_ENGINE=1 \
                  -DWITH_MYISAM_STORAGE_ENGINE=1 \
                  -DWITH_ARCHIVE_STORAGE_ENGINE=1 \
                  -DWITH_READLINE=1 \
                  -DWITH_SSL=system \
                  -DWITH_ZLIB=system \
                  -DWITH_BOOST=$MYSQL_INSTALL_DIR/boost"
    
    echo -e "${GREEN}执行命令: cmake $CMAKE_OPTIONS${NC}"
    echo -e "${CYAN}编译命令: make -j$make_jobs && make install${NC}"
    echo ""
    
    # 创建build目录
    mkdir -p build
    cd build
    
    cmake .. $CMAKE_OPTIONS 2>&1 | tee /tmp/mysql_cmake.log
        
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        echo -e "${RED}配置失败，错误日志已保存到 /tmp/mysql_cmake.log${NC}"
        echo -e "${YELLOW}请检查依赖是否已正确安装${NC}"
        return 1
    fi
    
    echo -e "${YELLOW}开始编译...${NC}"
    make -j$make_jobs
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}编译失败${NC}"
        exit 1
    fi
    
    echo -e "${YELLOW}开始安装...${NC}"
    make install
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}安装失败${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}MySQL安装完成!${NC}"

    # 显示编译统计
    echo ""
    echo -e "${CYAN}编译统计:${NC}"
    echo "  并行数: $make_jobs"
    echo "  编译时间: $(date)"
    echo ""
    return 0
}

# 配置环境变量
setup_environment() {
    echo -e "${YELLOW}配置环境变量...${NC}"
    
    # 检查是否已经存在MySQL环境变量配置
    if grep -q "# MySQL Environment Variables" /etc/profile; then
        echo -e "${YELLOW}MySQL环境变量已存在，更新配置...${NC}"
        # 备份原配置
        cp /etc/profile /etc/profile.backup.$(date +%Y%m%d_%H%M%S)
        # 删除旧的MySQL配置
        sed -i '/# MySQL Environment Variables/,/^$/d' /etc/profile
    fi
    
    # 添加新的环境变量配置
    cat >> /etc/profile << EOF

# MySQL Environment Variables
export MYSQL_HOME=$MYSQL_INSTALL_DIR
export MYSQL_DATA=$MYSQL_DATA_DIR
export PATH=\$MYSQL_HOME/bin:\$PATH
export LANG=en_US.utf8
export LD_LIBRARY_PATH=\$MYSQL_HOME/lib:\$LD_LIBRARY_PATH
EOF
    
    # 立即在当前会话中生效
    echo -e "${YELLOW}使环境变量在当前会话中生效...${NC}"
    export MYSQL_HOME="$MYSQL_INSTALL_DIR"
    export MYSQL_DATA="$MYSQL_DATA_DIR"
    export PATH="$MYSQL_INSTALL_DIR/bin:$PATH"
    export LANG="en_US.utf8"
    export LD_LIBRARY_PATH="$MYSQL_INSTALL_DIR/lib:$LD_LIBRARY_PATH"
    
    # 同时source /etc/profile以确保其他环境变量也生效
    source /etc/profile > /dev/null 2>&1
    
    echo -e "${GREEN}环境变量配置完成并已生效${NC}"
    echo -e "${CYAN}当前MySQL环境变量:${NC}"
    echo "  MYSQL_HOME: $MYSQL_HOME"
    echo "  MYSQL_DATA: $MYSQL_DATA"
    echo "  PATH已包含: $MYSQL_INSTALL_DIR/bin"
    if [ -n "$LD_LIBRARY_PATH" ]; then
        echo "  LD_LIBRARY_PATH已包含: $MYSQL_INSTALL_DIR/lib"
    fi
}

# 初始化数据库
init_database() {
    echo -e "${YELLOW}初始化数据库...${NC}"
    
    # 检查是否已初始化
    if [ -f "$MYSQL_DATA_DIR/ibdata1" ]; then
        echo -e "${YELLOW}数据库已初始化${NC}"
        echo -e "${YELLOW}请选择操作:${NC}"
        echo "1. 跳过初始化，使用现有数据库"
        echo "2. 备份后重新初始化"
        echo "3. 直接重新初始化"
        read -p "请选择 [1-3]: " init_choice
        
        case $init_choice in
            "1")
                echo -e "${GREEN}跳过初始化${NC}"
                return 0
                ;;
            "2")
                local backup_dir="${MYSQL_DATA_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
                echo -e "${YELLOW}备份数据目录到: $backup_dir${NC}"
                mv "$MYSQL_DATA_DIR" "$backup_dir"
                mkdir -p "$MYSQL_DATA_DIR"
                chown -R $MYSQL_USER:$MYSQL_GROUP "$MYSQL_DATA_DIR"
                chmod 750 "$MYSQL_DATA_DIR"
                ;;
            "3")
                rm -rf "$MYSQL_DATA_DIR"/*
                ;;
            *)
                echo -e "${YELLOW}跳过初始化${NC}"
                return 0
                ;;
        esac
    fi
    
    # 尝试多种初始化方式
    local init_success=false
    local init_methods=(
        "使用su -切换用户（推荐）"
        "直接使用当前用户"
        "指定位置手动初始化"
    )
    
    echo -e "${YELLOW}数据库初始化选项:${NC}"
    echo "1. ${init_methods[0]}"
    echo "2. ${init_methods[1]}"
    echo "3. ${init_methods[2]}"
    echo "4. 跳过初始化"
    read -p "请选择初始化方式 [1-4]: " init_method
    
    case $init_method in
        "1")
            echo -e "${YELLOW}尝试使用su -初始化...${NC}"
            su - $MYSQL_USER -c "$MYSQL_INSTALL_DIR/bin/mysqld --initialize --user=$MYSQL_USER --basedir=$MYSQL_INSTALL_DIR --datadir=$MYSQL_DATA_DIR"
            if [ $? -eq 0 ]; then
                init_success=true
            else
                echo -e "${RED}su -初始化失败${NC}"
            fi
            ;;
        "2")
            echo -e "${YELLOW}尝试使用当前用户初始化...${NC}"
            $MYSQL_INSTALL_DIR/bin/mysqld --initialize --user=$MYSQL_USER --basedir=$MYSQL_INSTALL_DIR --datadir=$MYSQL_DATA_DIR
            if [ $? -eq 0 ]; then
                init_success=true
            else
                echo -e "${RED}当前用户初始化失败${NC}"
            fi
            ;;
        "3")
            echo -e "${YELLOW}手动指定初始化位置...${NC}"
            read -p "请输入数据目录路径: " custom_data_dir
            if [ -n "$custom_data_dir" ]; then
                if [ ! -d "$custom_data_dir" ]; then
                    mkdir -p "$custom_data_dir"
                    chown $MYSQL_USER:$MYSQL_GROUP "$custom_data_dir"
                fi
                su - $MYSQL_USER -c "$MYSQL_INSTALL_DIR/bin/mysqld --initialize --user=$MYSQL_USER --basedir=$MYSQL_INSTALL_DIR --datadir=$custom_data_dir"
                if [ $? -eq 0 ]; then
                    MYSQL_DATA_DIR="$custom_data_dir"
                    init_success=true
                else
                    echo -e "${RED}手动初始化失败${NC}"
                fi
            else
                echo -e "${RED}未输入有效路径${NC}"
            fi
            ;;
        "4")
            echo -e "${YELLOW}跳过初始化${NC}"
            echo -e "${YELLOW}注意: 需要手动初始化数据库才能使用MySQL${NC}"
            return 0
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return 1
            ;;
    esac
    
    if [ "$init_success" = true ]; then
        echo -e "${GREEN}数据库初始化成功!${NC}"
        # 确保权限正确
        chown -R $MYSQL_USER:$MYSQL_GROUP "$MYSQL_DATA_DIR" 2>/dev/null
        chmod 750 "$MYSQL_DATA_DIR" 2>/dev/null
        return 0
    else
        echo -e "${RED}数据库初始化失败!${NC}"
        echo -e "${YELLOW}可能的解决方案:${NC}"
        echo "1. 确保mysql用户存在且有权限"
        echo "2. 确保数据目录存在且为空"
        echo "3. 尝试手动初始化（选项4）"
        echo "4. 检查磁盘空间"
        echo ""
        echo -e "${YELLOW}手动初始化命令:${NC}"
        echo "$MYSQL_INSTALL_DIR/bin/mysqld --initialize --user=$MYSQL_USER --basedir=$MYSQL_INSTALL_DIR --datadir=$MYSQL_DATA_DIR"
        echo ""
        
        read -p "是否重试初始化? [y/N]: " retry_init
        if [[ $retry_init =~ ^[Yy]$ ]]; then
            return init_database
        else
            return 1
        fi
    fi
}

# 配置MySQL
configure_mysql() {
    echo -e "${YELLOW}配置MySQL...${NC}"
    
    # 创建配置文件目录
    mkdir -p $MYSQL_INSTALL_DIR/etc
    
    # 创建my.cnf配置文件
    cat > $MYSQL_INSTALL_DIR/etc/my.cnf << EOF
[mysqld]
# 基础配置
user = $MYSQL_USER
basedir = $MYSQL_INSTALL_DIR
datadir = $MYSQL_DATA_DIR
port = $MYSQL_PORT
socket = $MYSQL_TMP_DIR/mysql.sock
pid-file = $MYSQL_TMP_DIR/mysql.pid

# 日志配置
log-error = $MYSQL_LOG_DIR/error.log
slow_query_log = 1
slow_query_log_file = $MYSQL_LOG_DIR/slow.log
long_query_time = 10

# 性能配置
max_connections = 1000
max_connect_errors = 100
wait_timeout = 600
interactive_timeout = 600

# 缓冲区配置
innodb_buffer_pool_size = 2G
innodb_log_file_size = 256M
innodb_flush_log_at_trx_commit = 1
innodb_lock_wait_timeout = 50

# 字符集配置
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

# 安全配置
skip-name-resolve
local-infile = 0

[client]
port = $MYSQL_PORT
socket = $MYSQL_TMP_DIR/mysql.sock
default-character-set = utf8mb4

[mysql]
default-character-set = utf8mb4
EOF
    
    echo -e "${GREEN}MySQL配置文件创建完成${NC}"
}

# 创建系统服务
create_systemd_service() {
    echo -e "${YELLOW}创建系统服务...${NC}"
    
    cat > /etc/systemd/system/mysql${MYSQL_VERSION%.*}.service << EOF
[Unit]
Description=MySQL ${MYSQL_VERSION%.*} Server
After=network.target

[Service]
Type=forking
User=$MYSQL_USER
Group=$MYSQL_GROUP
PIDFile=$MYSQL_TMP_DIR/mysql.pid
ExecStart=$MYSQL_INSTALL_DIR/bin/mysqld_safe --defaults-file=$MYSQL_INSTALL_DIR/etc/my.cnf &
ExecStop=$MYSQL_INSTALL_DIR/bin/mysqladmin -u root shutdown
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF
    
    chmod 700 /etc/systemd/system/mysql${MYSQL_VERSION%.*}.service
    
    # 重新加载systemd配置
    systemctl daemon-reload
    
    # 启动服务
    systemctl start mysql${MYSQL_VERSION%.*}
    
    # 设置开机自启
    systemctl enable mysql${MYSQL_VERSION%.*}
    
    echo -e "${GREEN}MySQL服务已创建并启动!${NC}"
}

# 设置密码
set_password() {
    echo -e "${YELLOW}设置MySQL用户密码...${NC}"
    
    # 查找正确的服务名
    local service_name=""
    local mysql_services=$(systemctl list-units --all --type=service --no-legend | grep -i mysql | awk '{print $1}')
    
    if [ -z "$mysql_services" ]; then
        # 尝试常见的服务名
        if [ -n "$MYSQL_VERSION" ]; then
            # 尝试基于版本的服务名
            local version_short="${MYSQL_VERSION%.*}"
            local possible_names=(
                "mysql${version_short}"
                "mysql-${version_short}"
                "mysql@${version_short}-main"
                "mysql"
            )
            for name in "${possible_names[@]}"; do
                if systemctl list-units --all --type=service --no-legend | grep -q "^${name}.service"; then
                    service_name="${name}.service"
                    break
                fi
            done
        else
            # 没有版本信息，尝试默认服务名
            if systemctl list-units --all --type=service --no-legend | grep -q "^mysql.service"; then
                service_name="mysql.service"
            fi
        fi
    else
        # 使用找到的第一个服务
        local service_array=($mysql_services)
        service_name="${service_array[0]}"
    fi
    
    if [ -z "$service_name" ]; then
        echo -e "${YELLOW}警告: 未找到MySQL服务，将跳过服务状态检查${NC}"
    else
        echo -e "${CYAN}使用服务名: $service_name${CYAN}"
    fi
    
    # 检查服务是否启动
    if [ -n "$service_name" ] && ! systemctl is-active --quiet $service_name; then
        echo -e "${YELLOW}MySQL服务未运行，尝试启动...${NC}"
        systemctl start $service_name
        sleep 3
    fi
    
    # 显示当前密码配置
    echo -e "${CYAN}当前密码配置:${NC}"
    echo "  用户名: $MYSQL_USER"
    echo "  预设密码: $MYSQL_PASSWORD"
    echo "  Root密码: $MYSQL_ROOT_PASSWORD"
    echo ""
    
    # 询问用户是否需要修改密码
    echo -e "${YELLOW}请选择密码设置方式:${NC}"
    echo "1. 使用临时密码登录方式（推荐）"
    echo "2. 使用预设密码 ($MYSQL_PASSWORD)"
    echo "3. 输入新密码（隐藏输入）"
    echo "4. 跳过密码设置"
    echo ""
    read -p "请选择 [1-4]: " password_choice
    
    local new_password="$MYSQL_ROOT_PASSWORD"
    local password_set=false
    
    case $password_choice in
        "1")
            echo -e "${GREEN}使用临时密码登录方式${NC}"
            echo -e "${CYAN}执行步骤:${NC}"
            echo "  1. 查找临时密码"
            echo "  2. 使用临时密码登录"
            echo "  3. 设置新密码"
            echo ""
            
            # 方法1: 使用临时密码登录方式
            echo -e "${YELLOW}步骤1: 查找临时密码...${NC}"
            
            # 从错误日志中查找临时密码
            local temp_password=""
            if [ -f "$MYSQL_LOG_DIR/error.log" ]; then
                temp_password=$(grep "A temporary password is generated for root@localhost" "$MYSQL_LOG_DIR/error.log" | awk '{print $NF}')
            fi
            
            if [ -z "$temp_password" ]; then
                echo -e "${YELLOW}未找到临时密码，尝试其他方式...${NC}"
                # 尝试从初始化输出中获取
                temp_password=$(cat /tmp/mysql_init_output.log 2>/dev/null | grep "A temporary password is generated for root@localhost" | awk '{print $NF}')
            fi
            
            if [ -z "$temp_password" ]; then
                echo -e "${RED}无法找到临时密码${NC}"
                echo -e "${YELLOW}请手动执行以下命令设置密码:${NC}"
                echo ""
                echo "# 1. 停止MySQL服务"
                echo "systemctl stop $service_name"
                echo ""
                echo "# 2. 以安全模式启动MySQL"
                echo "$MYSQL_INSTALL_DIR/bin/mysqld_safe --skip-grant-tables &"
                echo ""
                echo "# 3. 连接MySQL"
                echo "$MYSQL_INSTALL_DIR/bin/mysql -u root"
                echo ""
                echo "# 4. 设置新密码"
                echo "FLUSH PRIVILEGES;"
                echo "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';"
                echo "FLUSH PRIVILEGES;"
                echo "EXIT;"
                echo ""
                echo "# 5. 重启MySQL服务"
                echo "systemctl restart $service_name"
                echo ""
                read -p "设置密码完成后，按回车键继续... " -r
                return 0
            fi
            
            echo -e "${GREEN}找到临时密码: $temp_password${NC}"
            
            # 步骤2: 使用临时密码登录并设置新密码
            echo -e "${YELLOW}步骤2: 设置新密码...${NC}"
            
            # 创建临时脚本用于设置密码
            temp_script="/tmp/set_mysql_password.sh"
            cat > "$temp_script" << EOF
#!/bin/bash
# 使用临时密码登录并设置新密码
echo "正在设置root用户密码..."
$MYSQL_INSTALL_DIR/bin/mysql -u root -p"$temp_password" --connect-expired-password -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';" 2>/dev/null
echo "密码设置完成"
exit
EOF
            
            # 执行脚本
            if [ "$EUID" -eq 0 ]; then
                # 以root身份执行
                chown mysql:mysql "$temp_script"
                chmod +x "$temp_script"
                su - mysql -c "bash $temp_script" 2>/dev/null
                
                if [ $? -eq 0 ]; then
                    password_set=true
                    echo -e "${GREEN}✓ root用户密码设置成功${NC}"
                else
                    echo -e "${RED}✗ root用户密码设置失败${NC}"
                fi
            else
                # 非root用户执行
                echo -e "${RED}需要root权限来切换mysql用户${NC}"
                echo -e "${YELLOW}请手动执行以下命令:${NC}"
                echo "su - mysql"
                echo "$MYSQL_INSTALL_DIR/bin/mysql -u root -p'$temp_password' --connect-expired-password"
                echo "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';"
                echo "EXIT;"
            fi
            
            # 清理临时文件
            rm -f "$temp_script"
            ;;
        "2")
            echo -e "${YELLOW}使用预设密码: $MYSQL_ROOT_PASSWORD${NC}"
            password_set=true
            ;;
        "3")
            # 隐藏密码输入
            echo -e "${YELLOW}请输入新密码 (输入时不会显示): ${NC}"
            read -s -p "新密码: " new_password
            if [ -z "$new_password" ]; then
                echo -e "${RED}密码不能为空，使用预设密码${NC}"
                new_password="$MYSQL_ROOT_PASSWORD"
            else
                # 验证密码强度
                if [ ${#new_password} -lt 6 ]; then
                    echo -e "${YELLOW}警告: 密码长度少于6位，建议使用更长的密码${NC}"
                    read -p "是否继续使用此密码? [y/N]: " weak_confirm
                    if [[ ! $weak_confirm =~ ^[Yy]$ ]]; then
                        echo -e "${YELLOW}使用预设密码: $MYSQL_ROOT_PASSWORD${NC}"
                        new_password="$MYSQL_ROOT_PASSWORD"
                    fi
                fi
            fi
            echo -e "${GREEN}新密码已设置${NC}"
            ;;
        "4")
            echo -e "${YELLOW}跳过密码设置${NC}"
            echo -e "${YELLOW}注意: 无密码访问可能存在安全风险${NC}"
            password_set=true
            ;;
        *)
            echo -e "${RED}无效选择，使用临时密码登录方式${NC}"
            password_choice="1"
            ;;
    esac
    
    # 如果选择跳过密码设置，直接返回
    if [ "$password_choice" = "4" ]; then
        echo -e "${YELLOW}跳过密码设置${NC}"
        return 0
    fi
    
    # 如果不是方法1，使用其他方法设置密码
    if [ "$password_set" = false ]; then
        echo -e "${YELLOW}正在设置MySQL密码...${NC}"
        
        # 方法1: 使用mysqladmin
        if [ "$EUID" -eq 0 ] && command -v mysqladmin &> /dev/null; then
            echo -e "${CYAN}方法1: 使用mysqladmin设置密码${NC}"
            $MYSQL_INSTALL_DIR/bin/mysqladmin -u root password "$new_password" 2>/dev/null
            if [ $? -eq 0 ]; then
                password_set=true
                echo -e "${GREEN}✓ mysqladmin设置密码成功${NC}"
            else
                echo -e "${RED}✗ mysqladmin设置失败${NC}"
            fi
        fi
        
        # 方法2: 使用su -
        if [ "$password_set" = false ] && [ "$EUID" -eq 0 ]; then
            echo -e "${CYAN}方法2: 使用su -切换用户${NC}"
            su - $MYSQL_USER -c "$MYSQL_INSTALL_DIR/bin/mysql -u root -e \"ALTER USER 'root'@'localhost' IDENTIFIED BY '$new_password';\"" 2>/dev/null
            if [ $? -eq 0 ]; then
                password_set=true
                echo -e "${GREEN}✓ su -设置密码成功${NC}"
            else
                echo -e "${RED}✗ su -设置失败${NC}"
            fi
        fi
        
        # 方法3: 手动设置提示
        if [ "$password_set" = false ]; then
            echo -e "${RED}所有自动方法都失败${NC}"
            echo -e "${YELLOW}请手动执行以下命令设置密码:${NC}"
            echo ""
            echo "----------------------------------------"
            echo "# 方法1: 使用mysqladmin"
            echo "$MYSQL_INSTALL_DIR/bin/mysqladmin -u root password '$new_password'"
            echo ""
            echo "# 方法2: 登录MySQL后修改"
            echo "$MYSQL_INSTALL_DIR/bin/mysql -u root"
            echo "ALTER USER 'root'@'localhost' IDENTIFIED BY '$new_password';"
            echo "EXIT;"
            echo "----------------------------------------"
            echo ""
            
            read -p "设置密码完成后，按回车键继续... " -r
            # 验证是否设置了密码（通过尝试连接）
            echo -e "${YELLOW}验证密码设置...${NC}"
            $MYSQL_INSTALL_DIR/bin/mysql -u root -p"$new_password" -e "SELECT 1;" &>/dev/null
            if [ $? -eq 0 ]; then
                password_set=true
                echo -e "${GREEN}✓ 密码验证成功${NC}"
            else
                echo -e "${RED}✗ 密码验证失败，请检查服务状态${NC}"
                echo -e "${YELLOW}请确保MySQL服务正在运行${NC}"
                echo -e "${YELLOW}服务状态: $(systemctl is-active $service_name 2>/dev/null || echo "未运行")"
            fi
        fi
    fi
    
    # 显示密码设置结果
    if [ "$password_set" = true ]; then
        echo ""
        echo -e "${GREEN}密码设置完成!${NC}"
        echo -e "${CYAN}MySQL连接信息:${NC}"
        echo "  用户名: root"
        if [ "$password_choice" = "1" ] || [ "$password_choice" = "2" ]; then
            echo "  密码: $MYSQL_ROOT_PASSWORD"
        else
            echo "  密码: [已设置]"
        fi
        echo "  连接命令: $MYSQL_INSTALL_DIR/bin/mysql -u root -p"
        echo "  连接命令: $MYSQL_INSTALL_DIR/bin/mysql -u root -p$MYSQL_ROOT_PASSWORD"
        echo ""
        echo -e "${YELLOW}提示: 首次连接可能需要输入密码${NC}"
        echo -e "${CYAN}可以在~/.my.cnf文件中保存密码以避免每次输入${NC}"
        echo ""
    else
        echo -e "${RED}密码设置失败${NC}"
        echo -e "${YELLOW}请手动执行以下命令:${NC}"
        echo ""
        echo "# 使用mysqladmin"
        echo "$MYSQL_INSTALL_DIR/bin/mysqladmin -u root password '$MYSQL_ROOT_PASSWORD'"
        echo ""
        echo "然后重启服务: systemctl restart $service_name"
    fi
    
    # 检查和配置防火墙
    configure_firewall
}

# 配置防火墙
configure_firewall() {
    echo -e "${YELLOW}检查和配置防火墙...${NC}"
    
    local firewall_configured=false
    local port="$MYSQL_PORT"
    
    # 检查firewalld状态
    if command -v firewall-cmd &> /dev/null; then
        echo -e "${CYAN}检测到firewalld防火墙${NC}"
        if systemctl is-active --quiet firewalld; then
            echo -e "${GREEN}firewalld正在运行${NC}"
            
            # 检查端口是否已开放
            if firewall-cmd --query-port="${port}/tcp" &> /dev/null; then
                echo -e "${GREEN}端口 ${port} 已开放${NC}"
            else
                echo -e "${YELLOW}开放端口 ${port}...${NC}"
                firewall-cmd --permanent --add-port="${port}/tcp"
                firewall-cmd --reload
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}✓ 端口 ${port} 已成功开放${NC}"
                    firewall_configured=true
                else
                    echo -e "${RED}✗ 端口开放失败${NC}"
                fi
            fi
        else
            echo -e "${YELLOW}firewalld未运行，跳过防火墙配置${NC}"
        fi
    fi
    
    # 检查ufw状态
    if command -v ufw &> /dev/null; then
        echo -e "${CYAN}检测到ufw防火墙${NC}"
        if ufw status | grep -q "Status: active"; then
            echo -e "${GREEN}ufw正在运行${NC}"
            
            # 检查端口是否已开放
            if ufw status | grep -q "${port}/tcp"; then
                echo -e "${GREEN}端口 ${port} 已开放${NC}"
            else
                echo -e "${YELLOW}开放端口 ${port}...${NC}"
                ufw allow "${port}/tcp"
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}✓ 端口 ${port} 已成功开放${NC}"
                    firewall_configured=true
                else
                    echo -e "${RED}✗ 端口开放失败${NC}"
                fi
            fi
        else
            echo -e "${YELLOW}ufw未启用，跳过防火墙配置${NC}"
        fi
    fi
    
    # 检查iptables状态
    if command -v iptables &> /dev/null && ! command -v firewall-cmd &> /dev/null && ! command -v ufw &> /dev/null; then
        echo -e "${CYAN}检测到iptables防火墙${NC}"
        
        # 检查是否有规则允许该端口
        if iptables -L INPUT -n | grep -q "dpt:${port}"; then
            echo -e "${GREEN}端口 ${port} 已开放${NC}"
        else
            echo -e "${YELLOW}开放端口 ${port}...${NC}"
            iptables -I INPUT -p tcp --dport "${port}" -j ACCEPT
            
            # 尝试保存iptables规则
            if command -v iptables-save &> /dev/null; then
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
                iptables-save > /etc/iptables.rules 2>/dev/null || \
                echo -e "${YELLOW}注意: iptables规则可能需要手动保存${NC}"
                
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}✓ 端口 ${port} 已成功开放${NC}"
                    firewall_configured=true
                else
                    echo -e "${RED}✗ 端口开放失败${NC}"
                fi
            fi
        fi
    fi
    
    # 如果没有检测到任何防火墙
    if ! command -v firewall-cmd &> /dev/null && ! command -v ufw &> /dev/null && ! command -v iptables &> /dev/null; then
        echo -e "${YELLOW}未检测到常见的防火墙工具（firewalld/ufw/iptables）${NC}"
        echo -e "${CYAN}请确保端口 ${port} 可以被外部访问${NC}"
    fi
    
    # 显示防火墙配置结果
    if [ "$firewall_configured" = true ]; then
        echo ""
        echo -e "${GREEN}防火墙配置完成!${NC}"
        echo -e "${CYAN}MySQL端口信息:${NC}"
        echo "  端口号: ${port}"
        echo "  协议: TCP"
        echo ""
        echo -e "${YELLOW}测试连接命令:${NC}"
        echo "  telnet <服务器IP> ${port}"
        echo ""
    else
        echo ""
        echo -e "${CYAN}防火墙状态:${NC}"
        echo "  如果无法远程连接，请检查以下项目:"
        echo "  1. 防火墙是否允许端口 ${port}"
        echo "  2. 云服务器安全组是否开放端口 ${port}"
        echo "  3. 网络ACL是否限制访问"
        echo ""
    fi
}

# 配置远程访问
configure_remote_access() {
    echo -e "${YELLOW}配置MySQL远程访问...${NC}"
    
    # 查找正确的服务名
    local service_name=""
    local mysql_services=$(systemctl list-units --all --type=service --no-legend | grep -i mysql | awk '{print $1}')
    
    if [ -z "$mysql_services" ]; then
        # 尝试常见的服务名
        if [ -n "$MYSQL_VERSION" ]; then
            # 尝试基于版本的服务名
            local version_short="${MYSQL_VERSION%.*}"
            local possible_names=(
                "mysql${version_short}"
                "mysql-${version_short}"
                "mysql@${version_short}-main"
                "mysql"
            )
            for name in "${possible_names[@]}"; do
                if systemctl list-units --all --type=service --no-legend | grep -q "^${name}.service"; then
                    service_name="${name}.service"
                    break
                fi
            done
        else
            # 没有版本信息，尝试默认服务名
            if systemctl list-units --all --type=service --no-legend | grep -q "^mysql.service"; then
                service_name="mysql.service"
            fi
        fi
    else
        # 使用找到的第一个服务
        local service_array=($mysql_services)
        service_name="${service_array[0]}"
    fi
    
    if [ -z "$service_name" ]; then
        echo -e "${YELLOW}警告: 未找到MySQL服务，将跳过服务状态检查${NC}"
    else
        echo -e "${CYAN}使用服务名: $service_name${NC}"
    fi
    
    # 检查服务是否启动
    if [ -n "$service_name" ] && ! systemctl is-active --quiet $service_name; then
        echo -e "${YELLOW}MySQL服务未运行，尝试启动...${NC}"
        systemctl start $service_name
        sleep 3
    fi
    
    # 配置远程访问
    echo -e "${YELLOW}配置远程访问权限...${NC}"
    
    # 创建远程访问用户
    $MYSQL_INSTALL_DIR/bin/mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "
        CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';
        GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
        FLUSH PRIVILEGES;
    " 2>/dev/null
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ 远程访问配置成功${NC}"
    else
        echo -e "${RED}✗ 远程访问配置失败${NC}"
        echo -e "${YELLOW}请手动执行以下命令:${NC}"
        echo "$MYSQL_INSTALL_DIR/bin/mysql -u root -p'$MYSQL_ROOT_PASSWORD'"
        echo "CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';"
        echo "GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;"
        echo "FLUSH PRIVILEGES;"
    fi
    
    # 检查端口监听状态
    echo -e "${YELLOW}检查端口监听状态...${NC}"
    sleep 3
    
    if netstat -tuln | grep ":$MYSQL_PORT " &>/dev/null; then
        echo -e "${GREEN}✓ 端口 $MYSQL_PORT 正在监听${NC}"
    else
        echo -e "${RED}✗ 端口 $MYSQL_PORT 未监听${NC}"
        echo -e "${YELLOW}请检查防火墙配置和网络设置${NC}"
    fi
    
    # 显示Navicat连接信息
    echo ""
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}Navicat远程访问配置完成!${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${CYAN}Navicat连接信息:${NC}"
    echo "  主机名/IP: $(hostname -I | awk '{print $1}')"
    echo "  端口: $MYSQL_PORT"
    echo "  用户名: root"
    echo "  密码: $MYSQL_ROOT_PASSWORD"
    echo ""
    echo -e "${CYAN}Navicat连接步骤:${NC}"
    echo "  1. 打开Navicat"
    echo "  2. 新建MySQL连接"
    echo "  3. 填入上述连接信息"
    echo "  4. 点击测试连接"
    echo "  5. 保存连接"
    echo ""
    echo -e "${YELLOW}注意事项:${NC}"
    echo "  1. 确保防火墙已开放端口 $MYSQL_PORT"
    echo "  2. 如果连接失败，请检查:"
    echo "     - 防火墙设置"
    echo "     - 网络连通性"
    echo "     - MySQL服务状态"
    echo "     - 用户权限设置"
    echo ""
    
    echo -e "${CYAN}防火墙配置命令（如需要）:${NC}"
    if command -v firewall-cmd &>/dev/null; then
        echo "  firewall-cmd --permanent --add-port=$MYSQL_PORT/tcp"
        echo "  firewall-cmd --reload"
    elif command -v ufw &>/dev/null; then
        echo "  ufw allow $MYSQL_PORT/tcp"
    elif command -v iptables &>/dev/null; then
        echo "  iptables -A INPUT -p tcp --dport $MYSQL_PORT -j ACCEPT"
        echo "  service iptables save"
    fi
    echo ""

    return 0
}

# 验证安装
verify_installation() {
    echo -e "${YELLOW}验证安装...${NC}"
    
    # 检查服务状态
    if systemctl is-active --quiet mysql${MYSQL_VERSION%.*}; then
        echo -e "${GREEN}MySQL服务正在运行${NC}"
    else
        echo -e "${RED}MySQL服务未运行${NC}"
        return 1
    fi
    
    # 测试连接
    echo -e "${CYAN}测试MySQL连接...${NC}"
    
    # 使用密码进行连接测试
    if [ -n "$MYSQL_ROOT_PASSWORD" ]; then
        # 设置密码进行连接测试
        test_cmd="$MYSQL_INSTALL_DIR/bin/mysql -u root -p$MYSQL_ROOT_PASSWORD"
        
        if $test_cmd -e "SELECT version();" > /dev/null 2>&1; then
            echo -e "${GREEN}MySQL连接测试成功（使用密码认证）${NC}"
        else
            echo -e "${RED}MySQL连接测试失败${NC}"
            echo -e "${YELLOW}尝试的连接命令: $MYSQL_INSTALL_DIR/bin/mysql -u root -p***${NC}"
            return 1
        fi
    else
        # 如果没有设置密码，尝试使用信任认证
        if [ "$EUID" -eq 0 ]; then
            test_cmd="sudo -u $MYSQL_USER $MYSQL_INSTALL_DIR/bin/mysql"
        else
            test_cmd="$MYSQL_INSTALL_DIR/bin/mysql -u root"
        fi
        
        if $test_cmd -e "SELECT version();" > /dev/null 2>&1; then
            echo -e "${GREEN}MySQL连接测试成功（使用信任认证）${NC}"
        else
            echo -e "${RED}MySQL连接测试失败${NC}"
            echo -e "${YELLOW}尝试的连接命令: $test_cmd${NC}"
            return 1
        fi
    fi
}

# 清理安装过程中产生的临时文件
cleanup_temp_files() {
    echo ""
    echo -e "${CYAN}清理安装过程中的临时文件...${NC}"

    local cleaned_count=0
    local cleaned_files=()

    # 清理下载的源码包
    if [ -n "$MYSQL_VERSION" ]; then
        local tarball="/tmp/mysql-${MYSQL_VERSION}.tar.gz"
        if [ -f "$tarball" ]; then
            rm -f "$tarball"
            cleaned_files+=("$(basename "$tarball")")
            ((cleaned_count++))
        fi
    fi

    # 清理解压后的源码目录
    if [ -n "$MYSQL_VERSION" ] && [ -d "/tmp/mysql-${MYSQL_VERSION}" ]; then
        rm -rf "/tmp/mysql-${MYSQL_VERSION}"
        cleaned_files+=("mysql-${MYSQL_VERSION}/")
        ((cleaned_count++))
    fi

    # 清理配置日志
    if [ -f "/tmp/mysql_cmake.log" ]; then
        rm -f "/tmp/mysql_cmake.log"
        cleaned_files+=("mysql_cmake.log")
        ((cleaned_count++))
    fi

    # 清理版本查询临时文件
    for html in /tmp/mysql_versions_*.html /tmp/mysql_verify_*.html; do
        if [ -f "$html" ]; then
            rm -f "$html"
            cleaned_files+=("$(basename "$html")")
            ((cleaned_count++))
        fi
    done 2>/dev/null

    # 清理临时密码设置脚本
    if [ -f "/tmp/set_mysql_password.sh" ]; then
        rm -f "/tmp/set_mysql_password.sh"
        cleaned_files+=("set_mysql_password.sh")
        ((cleaned_count++))
    fi

    if [ $cleaned_count -gt 0 ]; then
        echo -e "${GREEN}✓ 已清理 $cleaned_count 个临时文件${NC}"
        echo -e "${CYAN}已清理的文件:${NC}"
        for file in "${cleaned_files[@]}"; do
            echo "  - $file"
        done
    else
        echo -e "${YELLOW}没有找到需要清理的临时文件${NC}"
    fi

    echo ""
}

# 显示安装信息
show_installation_info() {
    # 获取版本号
    local mysql_version=""
    if [ -f "$MYSQL_INSTALL_DIR/bin/mysql" ]; then
        mysql_version=$($MYSQL_INSTALL_DIR/bin/mysql --version 2>/dev/null | awk '{print $6}')
    fi
    
    echo -e "${GREEN}=====================================${NC}"
    if [ -n "$mysql_version" ]; then
        echo -e "${GREEN}MySQL ${mysql_version} 配置完成!${NC}"
    else
        echo -e "${GREEN}MySQL 配置完成!${NC}"
    fi
    echo -e "${GREEN}=====================================${NC}"
    echo -e "安装目录: $MYSQL_INSTALL_DIR"
    echo -e "数据目录: $MYSQL_DATA_DIR"
    if [ -n "$MYSQL_PORT" ]; then
        echo -e "端口号: $MYSQL_PORT"
    fi
    echo -e "用户名: root"
    if [ -n "$MYSQL_ROOT_PASSWORD" ]; then
        echo -e "密码: $MYSQL_ROOT_PASSWORD"
    fi
    echo -e ""
    echo -e "连接命令:"
    echo -e "$MYSQL_INSTALL_DIR/bin/mysql -u root -p"
    echo -e ""
    echo -e "服务管理命令:"
    local service_name="mysql"
    if [ -n "$mysql_version" ]; then
        service_name="mysql${mysql_version%.*}"
    fi
    echo -e "启动: systemctl start $service_name"
    echo -e "停止: systemctl stop $service_name"
    echo -e "重启: systemctl restart $service_name"
    echo -e "状态: systemctl status $service_name"
    echo -e ""
    echo -e "手动启动数据库:"
    echo -e "sudo -u $MYSQL_USER $MYSQL_INSTALL_DIR/bin/mysqld_safe --defaults-file=$MYSQL_INSTALL_DIR/etc/my.cnf &"
    echo -e ""
    
    # 添加MySQL路径到/etc/profile
    echo -e "${YELLOW}配置系统环境变量...${NC}"
    
    # 检查/etc/profile是否已存在MySQL配置
    if grep -q "MySQL" /etc/profile 2>/dev/null; then
        echo -e "${YELLOW}检测到/etc/profile中已存在MySQL配置${NC}"
        
        # 备份原有配置
        cp /etc/profile /etc/profile.backup
        echo -e "${GREEN}✓ 已备份/etc/profile到/etc/profile.backup${NC}"
        
        # 移除旧的MySQL配置
        sed -i '/# MySQL Environment/,/# End MySQL Environment/d' /etc/profile
        echo -e "${GREEN}✓ 已移除旧的MySQL环境配置${NC}"
    fi
    
    # 添加新的MySQL环境配置到/etc/profile
    cat >> /etc/profile << 'EOF'

# MySQL Environment
export MYSQL_HOME=/mnt/data/mysql
export MYSQL_DATA=/mnt/data/mysql/data
export PATH=$MYSQL_HOME/bin:$PATH
export MANPATH=$MYSQL_HOME/man:$MANPATH
# End MySQL Environment
EOF
    
    # 替换为实际的路径
    sed -i "s|export MYSQL_HOME=.*|export MYSQL_HOME=$MYSQL_INSTALL_DIR|g" /etc/profile
    sed -i "s|export MYSQL_DATA=.*|export MYSQL_DATA=$MYSQL_DATA_DIR|g" /etc/profile
    
    echo -e "${GREEN}✓ 已将MySQL路径添加到/etc/profile${NC}"
    echo -e "${CYAN}添加的环境变量:${NC}"
    echo "  MYSQL_HOME=$MYSQL_INSTALL_DIR"
    echo "  MYSQL_DATA=$MYSQL_DATA_DIR"
    echo "  PATH=\$MYSQL_HOME/bin:\$PATH"
    echo "  MANPATH=\$MYSQL_HOME/man:\$MANPATH"
    echo ""
    echo -e "${YELLOW}请执行以下命令使环境变量生效:${NC}"
    echo -e "${CYAN}source /etc/profile${NC}"
    echo -e "${YELLOW}或者重新登录系统${NC}"
    echo ""
    
    # 立即使当前会话的环境变量生效
    export MYSQL_HOME="$MYSQL_INSTALL_DIR"
    export MYSQL_DATA="$MYSQL_DATA_DIR"
    export PATH="$MYSQL_INSTALL_DIR/bin:$PATH"
    export MANPATH="$MYSQL_INSTALL_DIR/man:$MANPATH"
    echo -e "${GREEN}✓ 当前会话环境变量已生效${NC}"

    echo -e "${GREEN}=====================================${NC}"

    # 清理临时文件
    cleanup_temp_files
}

# 主函数
main() {
    echo -e "${GREEN}MySQL 自动化安装脚本${NC}"
    echo -e "${GREEN}支持 x86 和 ARM 架构${NC}"
    echo ""

    echo -e "${YELLOW}请选择操作:${NC}"
    echo "1. 全新安装MySQL（在线）"
    echo "2. 直接初始化数据库（需要MySQL已编译安装）"
    echo "3. 离线安装MySQL（使用本地tar.gz包）"
    echo "m. 选择下载镜像源（当前: ${MIRROR_NAME:-官网镜像}）"
    echo "q. 退出"
    echo ""
    read -p "请选择 [1/2/3/m/q]: " main_choice

    case $main_choice in
        "m"|"M")
            # 选择镜像源
            select_mirror
            main "$@"
            exit 0
            ;;
        "1")
            # 全新安装流程
            local version_result=""
            local config_result=""

            # 如果未选择镜像源，提示用户选择
            if [ -z "$MYSQL_MIRROR" ]; then
                echo ""
                echo -e "${CYAN}首次使用，请选择下载镜像源:${NC}"
                select_mirror
                echo ""
            fi

            while true; do
                select_version
                version_result=$?
                if [ "$version_result" = "0" ]; then
                    confirm_configuration
                    config_result=$?
                    if [ "$config_result" = "0" ]; then
                        break  # 配置成功，继续安装
                    elif [ "$config_result" = "1" ]; then
                        # 返回上级，重新选择版本，清空MYSQL_VERSION变量
                        MYSQL_VERSION=""
                        continue
                    fi
                elif [ "$version_result" = "1" ]; then
                    # 用户在版本选择中按b返回，退出循环
                    echo -e "${YELLOW}返回主菜单...${NC}"
                    break  # 退出while循环，继续执行case后的代码
                fi
            done

            # 如果用户按b返回，则不执行后续安装流程，直接返回主菜单
            if [ "$version_result" = "1" ]; then
                # 重新显示主菜单
                # 清空版本变量
                MYSQL_VERSION=""
                # 重新调用main函数，递归深度有限制但可以工作
                main "$@"
                exit 0
            fi
            ;;
        "2")
            # 直接初始化数据库
            echo -e "${YELLOW}直接初始化数据库模式${NC}"
            echo ""
            
            # 获取MySQL安装路径
            echo -e "${YELLOW}请输入MySQL安装路径:${NC}"
            read -p "例如 /mnt/data/mysql/mysql-8.0.35: " mysql_install_path
            if [ -z "$mysql_install_path" ]; then
                mysql_install_path="/mnt/data/mysql/mysql-8.0.35"
            fi
            
            # 获取数据目录
            echo -e "${YELLOW}请输入数据目录路径:${NC}"
            read -p "例如 /mnt/data/mysql/data: " mysql_data_path
            if [ -z "$mysql_data_path" ]; then
                mysql_data_path="/mnt/data/mysql/data"
            fi
            
            # 获取MySQL用户
            echo -e "${YELLOW}请输入MySQL用户名:${NC}"
            read -p "默认 [mysql]: " mysql_user
            if [ -z "$mysql_user" ]; then
                mysql_user="mysql"
            fi
            
            # 设置变量
            MYSQL_INSTALL_DIR="$mysql_install_path"
            MYSQL_DATA_DIR="$mysql_data_path"
            MYSQL_USER="$mysql_user"
            MYSQL_GROUP="$mysql_user"
            
            # 检查安装路径是否存在
            if [ ! -d "$MYSQL_INSTALL_DIR" ]; then
                echo -e "${RED}错误: MySQL安装路径不存在: $MYSQL_INSTALL_DIR${NC}"
                echo -e "${YELLOW}请确认MySQL已正确编译安装${NC}"
                exit 1
            fi
            
            # 检查mysqld是否存在
            if [ ! -f "$MYSQL_INSTALL_DIR/bin/mysqld" ]; then
                echo -e "${RED}错误: 找不到mysqld命令${NC}"
                echo -e "${YELLOW}请确认MySQL已正确编译安装${NC}"
                exit 1
            fi
            
            # 创建数据目录（如果不存在）
            if [ ! -d "$MYSQL_DATA_DIR" ]; then
                mkdir -p "$MYSQL_DATA_DIR"
                chown -R $MYSQL_USER:$MYSQL_GROUP "$MYSQL_DATA_DIR"
                chmod 750 "$MYSQL_DATA_DIR"
                echo -e "${GREEN}创建数据目录: $MYSQL_DATA_DIR${NC}"
            fi
            
            # 直接调用初始化函数
            if init_database; then
                echo -e "${GREEN}数据库初始化成功!${NC}"
                # 询问是否继续配置
                read -p "是否继续配置MySQL服务? [y/N]: " continue_config
                if [[ $continue_config =~ ^[Yy]$ ]]; then
                    # 设置环境变量
                    export MYSQL_HOME=$MYSQL_INSTALL_DIR
                    export MYSQL_DATA=$MYSQL_DATA_DIR
                    export PATH=$MYSQL_HOME/bin:$PATH
                    export LANG=en_US.utf8
                    
                    configure_mysql
                    create_systemd_service
                    set_password
                    configure_remote_access
                    verify_installation
                    show_installation_info
                fi
            else
                echo -e "${RED}数据库初始化失败${NC}"
                exit 1
            fi
            exit 0
            ;;
        "q"|"Q")
            echo -e "${GREEN}退出安装${NC}"
            exit 0
            ;;
        "3")
            # 离线安装流程
            offline_install_flow
            exit 0
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            exit 1
            ;;
    esac

    # 主程序循环，允许用户重新开始
    # 只有当MYSQL_VERSION不为空时才执行主程序循环（说明用户已完成配置）
    if [ -z "$MYSQL_VERSION" ]; then
        return
    fi

    while true; do
        # 版本选择和配置循环（用于重新安装时）
        while [ -z "$MYSQL_VERSION" ]; do
            select_version
            local version_result=$?

            if [ $version_result -eq 0 ]; then
                confirm_configuration
                local config_result=$?

                if [ $config_result -eq 0 ]; then
                    break  # 配置成功，继续安装
                elif [ $config_result -eq 1 ]; then
                    # 返回上级，重新选择版本，清空MYSQL_VERSION变量
                    MYSQL_VERSION=""
                    continue
                fi
            elif [ $version_result -eq 1 ]; then
                # 用户在版本选择中按b返回，返回主菜单
                echo -e "${YELLOW}返回主菜单...${NC}"
                main "$@"
                exit 0
            fi
        done

        # 主安装循环

        while true; do

            echo -e "${GREEN}开始安装MySQL ${MYSQL_VERSION}...${NC}"
            
            install_dependencies
            create_user_and_dirs
            
            # 检查现有安装
            if ! check_existing_installation; then
                # 如果选择直接编译，跳过下载解压
                echo -e "${YELLOW}跳过下载和解压，直接进入编译${NC}"
            else
                # 需要重新安装
                download_and_extract
                local download_result=$?
                if [ $download_result -ne 0 ]; then
                    echo -e "${RED}下载解压失败${NC}"
                    echo ""
                    echo -e "${YELLOW}请选择操作:${NC}"
                    echo "1. 重新尝试下载"
                    echo "2. 切换镜像源后重试"
                    echo "3. 返回主菜单"
                    echo "4. 退出安装"
                    read -p "请选择 [1-4]: " download_fail_choice

                    case $download_fail_choice in
                        "1")
                            echo -e "${YELLOW}重新尝试下载...${NC}"
                            continue
                            ;;
                        "2")
                            echo -e "${YELLOW}切换镜像源...${NC}"
                            select_mirror
                            continue
                            ;;
                        "3")
                            echo -e "${YELLOW}返回主菜单...${NC}"
                            main "$@"
                            exit 0
                            ;;
                        "4")
                            echo -e "${RED}退出安装${NC}"
                            exit 1
                            ;;
                        *)
                            echo -e "${YELLOW}重新尝试下载...${NC}"
                            continue
                            ;;
                    esac
                fi
            fi
            
            # 编译安装，如果失败则返回选择
            if ! compile_install; then
                echo -e "${YELLOW}编译失败，重新开始...${NC}"
                continue
            fi
            
            setup_environment
            
            # 初始化数据库
            if ! init_database; then
                echo -e "${YELLOW}数据库初始化失败${NC}"
                echo -e "${YELLOW}请选择操作:${NC}"
                echo "1. 重新开始安装流程"
                echo "2. 仅重新初始化数据库"
                echo "3. 跳过初始化，继续配置"
                echo "4. 退出安装"
                read -p "请选择 [1-4]: " init_fail_choice
                
                case $init_fail_choice in
                    "1")
                        echo -e "${YELLOW}重新开始安装流程...${NC}"
                        continue
                        ;;
                    "2")
                        echo -e "${YELLOW}重新尝试初始化数据库...${NC}"
                        if init_database; then
                            echo -e "${GREEN}数据库初始化成功!${NC}"
                        else
                            echo -e "${RED}再次初始化失败，退出安装${NC}"
                            exit 1
                        fi
                        ;;
                    "3")
                        echo -e "${YELLOW}跳过初始化，继续配置...${NC}"
                        ;;
                    "4")
                        echo -e "${RED}退出安装${NC}"
                        exit 1
                        ;;
                    *)
                        echo -e "${YELLOW}重新开始安装流程...${NC}"
                        continue
                        ;;
                esac
            fi
            
            configure_mysql
            create_systemd_service
            
            set_password
            
            # 验证安装
            if ! verify_installation; then
                echo -e "${YELLOW}安装验证失败，重新开始安装流程...${NC}"
                continue
            fi
            
            show_installation_info

            echo -e "${GREEN}MySQL ${MYSQL_VERSION} 安装完成!${NC}"
            break  # 成功完成，退出主循环
        done
        
        # 安装完成后，询问用户是否重新开始
        echo ""
        echo -e "${CYAN}安装已完成!${NC}"
        echo "1. 退出程序"
        echo "2. 重新安装（选择不同版本或配置）"
        echo ""
        read -p "请选择 [1/2]: " after_install_choice
        
        case $after_install_choice in
            "1")
                echo -e "${GREEN}退出安装程序${NC}"
                exit 0
                ;;
            "2")
                echo -e "${YELLOW}重新开始安装...${NC}"
                # 重置所有变量，重新开始
                MYSQL_VERSION=""
                MYSQL_USER=""
                MYSQL_GROUP=""
                MYSQL_HOME=""
                MYSQL_PORT=""
                MYSQL_PASSWORD=""
                MYSQL_ROOT_PASSWORD=""
                MYSQL_INSTALL_DIR=""
                MYSQL_DATA_DIR=""
                MYSQL_TMP_DIR=""
                MYSQL_LOG_DIR=""
                SELECTED_PLUGINS=""
                continue  # 返回主程序循环开始
                ;;
            *)
                echo -e "${GREEN}退出安装程序${NC}"
                exit 0
                ;;
        esac
    done
}

# 离线安装主流程
offline_install_flow() {
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}MySQL 离线安装模式${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo ""

    # 设置离线模式
    OFFLINE_MODE="true"

    # 步骤1: 查找离线tar包
    if ! find_offline_tarbll; then
        echo -e "${YELLOW}返回主菜单...${NC}"
        main "$@"
        exit 0
    fi

    echo ""
    # 步骤2: 确认安装配置
    echo -e "${YELLOW}MySQL 离线安装配置${NC}"
    echo "----------------------------------------"
    echo "  版本: $MYSQL_VERSION"
    echo "  Tar包: $OFFLINE_TARBALL_PATH"
    echo "----------------------------------------"
    echo ""

    # 步骤3: 配置安装参数
    echo -e "${YELLOW}请配置MySQL安装参数${NC}"
    echo ""

    # 使用默认配置或自定义配置
    read -p "是否使用默认配置? [y/N]: " use_default

    if [[ ! $use_default =~ ^[Yy]$ ]]; then
        # 自定义配置
        read -p "请输入用户名 [$DEFAULT_MYSQL_USER]: " input_user
        MYSQL_USER=${input_user:-$DEFAULT_MYSQL_USER}
        
        read -p "请输入用户组 [$DEFAULT_MYSQL_GROUP]: " input_group
        MYSQL_GROUP=${input_group:-$DEFAULT_MYSQL_GROUP}
        
        read -p "请输入安装目录 [$DEFAULT_MYSQL_HOME]: " input_home
        MYSQL_HOME=${input_home:-$DEFAULT_MYSQL_HOME}
        
        read -p "请输入端口号 [$DEFAULT_MYSQL_PORT]: " input_port
        MYSQL_PORT=${input_port:-$DEFAULT_MYSQL_PORT}
        
        read -s -p "请输入密码 [默认: mysql]: " input_password
        echo ""
        if [ -z "$input_password" ]; then
            MYSQL_PASSWORD=$DEFAULT_MYSQL_PASSWORD
        else
            MYSQL_PASSWORD=$input_password
        fi
        
        read -s -p "请输入Root密码 [默认: root]: " input_root_password
        echo ""
        if [ -z "$input_root_password" ]; then
            MYSQL_ROOT_PASSWORD=$DEFAULT_MYSQL_ROOT_PASSWORD
        else
            MYSQL_ROOT_PASSWORD=$input_root_password
        fi
    else
        # 使用默认配置
        MYSQL_USER=$DEFAULT_MYSQL_USER
        MYSQL_GROUP=$DEFAULT_MYSQL_GROUP
        MYSQL_HOME=$DEFAULT_MYSQL_HOME
        MYSQL_PORT=$DEFAULT_MYSQL_PORT
        MYSQL_PASSWORD=$DEFAULT_MYSQL_PASSWORD
        MYSQL_ROOT_PASSWORD=$DEFAULT_MYSQL_ROOT_PASSWORD
    fi

    # 计算派生路径
    MYSQL_INSTALL_DIR="${MYSQL_HOME}/mysql-${MYSQL_VERSION}"
    MYSQL_DATA_DIR="${MYSQL_HOME}/data"
    MYSQL_TMP_DIR="${MYSQL_HOME}/tmp"
    MYSQL_LOG_DIR="${MYSQL_HOME}/log"

    echo ""
    echo -e "${CYAN}最终配置:${NC}"
    echo "  MySQL版本: $MYSQL_VERSION"
    echo "  用户名: $MYSQL_USER"
    echo "  用户组: $MYSQL_GROUP"
    echo "  安装目录: $MYSQL_INSTALL_DIR"
    echo "  数据目录: $MYSQL_DATA_DIR"
    echo "  端口号: $MYSQL_PORT"
    echo "  密码: $MYSQL_PASSWORD"
    echo "  Root密码: $MYSQL_ROOT_PASSWORD"
    echo ""

    # 确认配置
    read -p "是否确认使用此配置? [y/N]: " confirm_config
    if [[ ! $confirm_config =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}返回主菜单...${NC}"
        main "$@"
        exit 0
    fi

    echo ""

    # 步骤4: 安装依赖（离线模式只显示依赖列表）
    install_dependencies
    
    # 步骤5: 创建用户和目录
    create_user_and_dirs

    # 步骤6: 解压离线tar包
    if ! extract_offline_tarbll; then
        echo -e "${RED}解压离线安装包失败${NC}"
        exit 1
    fi

    # 步骤7: 编译安装MySQL
    echo -e "${YELLOW}开始编译安装MySQL...${NC}"
    echo ""

    # 编译模式选择
    echo -e "${CYAN}请选择编译模式:${NC}"
    echo "1. 并行编译（推荐，使用所有CPU核心）"
    echo "2. 智能并行编译（自动调整核心数）"
    echo "3. 单线程编译（兼容性最好）"
    echo "4. 自定义并行数"
    echo ""
    read -p "请选择 [1-4]: " compile_mode
    
    # 获取CPU核心数
    local cpu_cores=$(nproc 2>/dev/null || echo "1")
    local make_jobs=$cpu_cores
    
    # 根据模式调整并行数
    case $compile_mode in
        "1")
            # 并行编译模式：使用所有CPU核心
            make_jobs=$cpu_cores
            echo -e "${GREEN}并行编译模式: 使用 $make_jobs 个核心${NC}"
            ;;
        "2")
            # 智能并行模式：根据系统负载调整
            local load_avg=$(cat /proc/loadavg 2>/dev/null | awk '{print $1}' | cut -d. -f1)
            local load_int=${load_avg%.*}
            
            if [ -n "$load_avg" ]; then
                if [ "$load_int" -gt 2 ]; then
                    # 系统负载高，使用较少核心
                    make_jobs=$((cpu_cores / 2))
                    if [ $make_jobs -lt 1 ]; then
                        make_jobs=1
                    fi
                else
                    # 系统负载低，可以使用更多核心
                    make_jobs=$cpu_cores
                fi
                
                echo -e "${GREEN}智能并行编译: $make_jobs 核心 (系统负载: $load_avg)${NC}"
            else
                # 无法获取负载，使用默认
                make_jobs=$cpu_cores
                echo -e "${YELLOW}无法获取系统负载，使用默认: $make_jobs 核心${NC}"
            fi
            ;;
        "3")
            # 单线程模式
            make_jobs=1
            echo -e "${GREEN}单线程编译模式: 1 个核心${NC}"
            ;;
        "4")
            # 自定义模式
            echo -e "${CYAN}系统信息:${NC}"
            echo "  可用CPU核心数: $cpu_cores"
            read -p "请输入并行数 (1-$cpu_cores): " custom_jobs
            if [[ "$custom_jobs" =~ ^[0-9]+$ ]] && [ "$custom_jobs" -ge 1 ] && [ "$custom_jobs" -le $cpu_cores ]; then
                make_jobs=$custom_jobs
                echo -e "${GREEN}使用自定义并行数: $make_jobs 个核心${NC}"
            else
                echo -e "${RED}无效输入，使用默认核心数: $cpu_cores${NC}"
                make_jobs=$cpu_cores
            fi
            ;;
        *)
            echo -e "${RED}无效选择，使用智能并行编译${NC}"
            # 智能调整
            local load_avg=$(cat /proc/loadavg 2>/dev/null | awk '{print $1}' | cut -d. -f1)
            local load_int=${load_avg%.*}
            
            if [ -n "$load_avg" ] && [ "$load_int" -gt 2 ]; then
                make_jobs=$((cpu_cores / 2))
                if [ $make_jobs -lt 1 ]; then
                    make_jobs=1
                fi
            else
                make_jobs=$cpu_cores
            fi
            echo -e "${YELLOW}使用智能并行编译: $make_jobs 核心${NC}"
            ;;
    esac
    
    # 显示最终配置
    echo ""
    echo -e "${CYAN}最终编译配置:${NC}"
    echo "  CPU核心数: $cpu_cores"
    echo "  使用核心数: $make_jobs"
    echo "  编译模式: $([ "$compile_mode" == "1" ] && echo "并行编译" || [ "$compile_mode" == "2" ] && echo "智能并行" || [ "$compile_mode" == "3" ] && echo "单线程" || echo "自定义")"
    echo ""

    # 配置make并行编译
    export MAKE="make -j$make_jobs"

    # 设置环境变量
    export PKG_CONFIG_PATH="${PKG_CONFIG_PATH}"

    echo -e "${GREEN}执行命令: cmake $CMAKE_OPTIONS${NC}"
    echo -e "${CYAN}编译命令: make -j$make_jobs && make install${NC}"
    echo ""

    cd $MYSQL_INSTALL_DIR
    
    # 创建build目录
    mkdir -p build
    cd build
    
    cmake .. $CMAKE_OPTIONS 2>&1 | tee /tmp/mysql_cmake.log
        
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        echo -e "${RED}配置失败，错误日志已保存到 /tmp/mysql_cmake.log${NC}"
        echo -e "${YELLOW}请检查依赖是否已正确安装${NC}"
        exit 1
    fi

    echo -e "${YELLOW}开始编译...${NC}"
    make -j$make_jobs

    if [ $? -ne 0 ]; then
        echo -e "${RED}编译失败${NC}"
        exit 1
    fi

    echo -e "${YELLOW}开始安装...${NC}"
    make install

    if [ $? -ne 0 ]; then
        echo -e "${RED}安装失败${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}MySQL安装完成!${NC}"

    # 步骤8: 设置环境变量
    setup_environment

    # 步骤9: 初始化数据库
    if ! init_database; then
        echo -e "${RED}数据库初始化失败${NC}"
        exit 1
    fi

    # 步骤10: 配置MySQL
    configure_mysql

    # 步骤11: 创建系统服务
    create_systemd_service

    # 步骤12: 设置密码
    set_password

    # 步骤13: 验证安装
    verify_installation

    # 步骤14: 显示安装信息
    show_installation_info

    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}MySQL ${MYSQL_VERSION} 离线安装完成!${NC}"
    echo -e "${GREEN}=====================================${NC}"
}

# 执行主函数
main "$@"
