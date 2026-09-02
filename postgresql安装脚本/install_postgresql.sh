#!/bin/bash

# PostgreSQL 18 自动化安装脚本
# 支持 x86 和 ARM 架构
# 作者: 基于PostgreSQL 12安装文档改编

# 不使用 set -e，避免意外退出
# set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 默认配置变量
DEFAULT_PG_VERSION="18.1"
DEFAULT_PG_USER="postgres"
DEFAULT_PG_GROUP="postgres"
DEFAULT_PG_HOME="/mnt/data/postgresql"
DEFAULT_PG_PORT="5432"
DEFAULT_PG_PASSWORD="postgres"

# UUID库选择
UUID_LIBRARY=""

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

# 脚本所在目录（用户未填写路径时的默认查找目录，离线包通常与脚本放在一起）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 镜像地址配置
PG_MIRROR=""
MIRROR_NAME=""

# 用户输入确认函数
confirm_configuration() {
    while true; do
        echo -e "${YELLOW}请确认PostgreSQL安装配置:${NC}"
        echo -e "PostgreSQL版本: ${GREEN}$PG_VERSION${NC}"
        echo -e "下载镜像: ${GREEN}${MIRROR_NAME:-官网镜像}${NC}"
        echo -e "用户名: ${GREEN}$DEFAULT_PG_USER${NC}"
        echo -e "用户组: ${GREEN}$DEFAULT_PG_GROUP${NC}"
        echo -e "安装目录: ${GREEN}$DEFAULT_PG_HOME${NC}"
        echo -e "端口号: ${GREEN}$DEFAULT_PG_PORT${NC}"
        echo -e "密码: ${GREEN}$DEFAULT_PG_PASSWORD${NC}"
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
                PG_USER=$DEFAULT_PG_USER
                PG_GROUP=$DEFAULT_PG_GROUP
                PG_HOME=$DEFAULT_PG_HOME
                PG_PORT=$DEFAULT_PG_PORT
                PG_PASSWORD=$DEFAULT_PG_PASSWORD
                break
                ;;
            "2")
                read -p "请输入用户名 [$DEFAULT_PG_USER]: " input_user
                PG_USER=${input_user:-$DEFAULT_PG_USER}

                read -p "请输入用户组 [$DEFAULT_PG_GROUP]: " input_group
                PG_GROUP=${input_group:-$DEFAULT_PG_GROUP}

                read -p "请输入安装目录 [$DEFAULT_PG_HOME]: " input_home
                PG_HOME=${input_home:-$DEFAULT_PG_HOME}

                read -p "请输入端口号 [$DEFAULT_PG_PORT]: " input_port
                PG_PORT=${input_port:-$DEFAULT_PG_PORT}

                read -s -p "请输入密码 [默认: postgres]: " input_password
                echo ""
                if [ -z "$input_password" ]; then
                    PG_PASSWORD=$DEFAULT_PG_PASSWORD
                else
                    PG_PASSWORD=$input_password
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
    PG_INSTALL_DIR="${PG_HOME}/postgresql-${PG_VERSION}"
    PG_DATA_DIR="${PG_HOME}/data"
    
    echo ""
    echo -e "${GREEN}最终配置:${NC}"
    echo -e "PostgreSQL版本: $PG_VERSION"
    echo -e "下载镜像: ${MIRROR_NAME:-官网镜像}"
    echo -e "用户名: $PG_USER"
    echo -e "用户组: $PG_GROUP"
    echo -e "安装目录: $PG_INSTALL_DIR"
    echo -e "数据目录: $PG_DATA_DIR"
    echo -e "端口号: $PG_PORT"
    echo -e "密码: $PG_PASSWORD"
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

# 从官网查询PostgreSQL版本
query_postgresql_versions() {
    local major_version="$1"
    
    echo -e "${YELLOW}正在查询PostgreSQL $major_version.x 版本...${NC}"
    
    # 创建临时文件存储版本信息
    local temp_file="/tmp/pg_versions_$$.html"
    
    # 设置超时时间（秒）
    local timeout=15
    
    # 获取版本列表页面
    if command -v curl &> /dev/null; then
        local curl_opts="-s --connect-timeout $timeout --max-time $timeout"
        if [ -n "$http_proxy" ]; then
            curl_opts="$curl_opts --proxy $http_proxy"
        fi
        
        curl $curl_opts "https://www.postgresql.org/versions/" > "$temp_file" 2>/dev/null
        local curl_exit_code=$?
        
        if [ $curl_exit_code -ne 0 ]; then
            echo -e "${RED}连接失败，无法查询版本信息${NC}"
            echo -e "${YELLOW}将使用默认版本: $DEFAULT_PG_VERSION${NC}"
            PG_VERSION=$DEFAULT_PG_VERSION
            rm -f "$temp_file"
            return
        fi
    elif command -v wget &> /dev/null; then
        local wget_opts="-q --timeout=$timeout --tries=1"
        if [ -n "$http_proxy" ]; then
            wget_opts="$wget_opts -e use_proxy=yes -e http_proxy=$http_proxy -e https_proxy=$https_proxy"
        fi
        
        wget $wget_opts -O "$temp_file" "https://www.postgresql.org/versions/" 2>/dev/null
        local wget_exit_code=$?
        
        if [ $wget_exit_code -ne 0 ]; then
            echo -e "${RED}连接失败，无法查询版本信息${NC}"
            echo -e "${YELLOW}将使用默认版本: $DEFAULT_PG_VERSION${NC}"
            PG_VERSION=$DEFAULT_PG_VERSION
            rm -f "$temp_file"
            return
        fi
    else
        echo -e "${RED}需要curl或wget来查询版本信息${NC}"
        echo -e "${YELLOW}将使用默认版本: $DEFAULT_PG_VERSION${NC}"
        PG_VERSION=$DEFAULT_PG_VERSION
        return
    fi
    
    if [ ! -f "$temp_file" ] || [ ! -s "$temp_file" ]; then
        echo -e "${RED}无法获取版本信息${NC}"
        echo -e "${YELLOW}将使用默认版本: $DEFAULT_PG_VERSION${NC}"
        PG_VERSION=$DEFAULT_PG_VERSION
        rm -f "$temp_file"
        return
    fi
    
    # 解析HTML获取版本列表
    echo -e "${GREEN}PostgreSQL $major_version.x 可用版本:${NC}"
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
    pattern = r'$major_version\.\d+'
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
        versions_array=($(grep -o "$major_version\.[0-9]\+" "$temp_file" | sort -u -V -r | head -10))
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
                PG_VERSION="${versions_array[$index]}"
                echo -e "${GREEN}已选择版本: $PG_VERSION${NC}"
            else
                echo -e "${RED}无效选择${NC}"
                echo -e "${YELLOW}1. 重新查询 $major_version.x 版本${NC}"
                echo -e "${YELLOW}2. 返回主菜单${NC}"
                read -p "请选择 [1/2]: " retry_choice
                case $retry_choice in
                    "1")
                        query_postgresql_versions "$major_version"
                        return
                        ;;
                    "2")
                        echo -e "${YELLOW}返回主菜单...${NC}"
                        PG_VERSION=""
                        return
                        ;;
                    *)
                        echo -e "${RED}无效选择${NC}"
                        PG_VERSION=""
                        ;;
                esac
            fi
        elif [[ "$version_choice" =~ ^[bB]$ ]]; then
            echo -e "${YELLOW}返回主菜单...${NC}"
            PG_VERSION=""
            return
        else
            echo -e "${RED}无效输入${NC}"
            echo -e "${YELLOW}1. 重新查询 $major_version.x 版本${NC}"
            echo -e "${YELLOW}2. 返回主菜单${NC}"
            read -p "请选择 [1/2]: " retry_choice
            case $retry_choice in
                "1")
                    query_postgresql_versions "$major_version"
                    return
                    ;;
                "2")
                    select_version
                    return
                    ;;
                *)
                    echo -e "${RED}无效选择${NC}"
                    PG_VERSION=""
                    ;;
            esac
        fi
    else
        echo -e "${RED}未找到 $major_version.x 版本${NC}"
        echo -e "${YELLOW}1. 重新查询 $major_version.x 版本${NC}"
        echo -e "${YELLOW}2. 返回主菜单${NC}"
        echo -e "${YELLOW}3. 使用默认版本 ($DEFAULT_PG_VERSION)${NC}"
        read -p "请选择 [1/2/3]: " no_version_choice
        case $no_version_choice in
            "1")
                query_postgresql_versions "$major_version"
                return
                ;;
            "2")
                select_version
                return
                ;;
            "3")
                PG_VERSION=$DEFAULT_PG_VERSION
                echo -e "${GREEN}使用默认版本: $PG_VERSION${NC}"
                ;;
            *)
                echo -e "${RED}无效选择${NC}"
                PG_VERSION=""
                ;;
        esac
    fi
}

# 验证版本是否存在
verify_version_exists() {
    local version="$1"
    echo -e "${YELLOW}验证PostgreSQL $version 是否存在...${NC}"
    
    # 创建临时文件
    local temp_file="/tmp/pg_verify_$$.html"
    
    # 检查版本URL是否存在
    local version_url="https://ftp.postgresql.org/pub/source/v${version}/"
    
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
            PG_VERSION=$DEFAULT_PG_VERSION
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

# 镜像源选择函数
select_mirror() {
    echo -e "${YELLOW}请选择PostgreSQL下载镜像源:${NC}"
    echo "1. 官网镜像 (https://ftp.postgresql.org)"
    echo "2. 腾讯云镜像 (https://mirrors.cloud.tencent.com)"
    echo "b. 返回上级菜单"
    echo "q. 退出安装"
    echo ""

    read -p "请选择 [1/2/b/q]: " mirror_choice

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
            PG_MIRROR="https://ftp.postgresql.org/pub/source"
            MIRROR_NAME="官网镜像"
            echo -e "${GREEN}已选择官网镜像源${NC}"
            return 0
            ;;
        "2")
            PG_MIRROR="https://mirrors.cloud.tencent.com/postgresql/source"
            MIRROR_NAME="腾讯云镜像"
            echo -e "${GREEN}已选择腾讯云镜像源${NC}"
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
        echo -e "${YELLOW}请选择PostgreSQL版本:${NC}"
        echo "1. 使用默认版本 ($DEFAULT_PG_VERSION)"
        echo "2. 查询12.x版本"
        echo "3. 查询13.x版本"
        echo "4. 查询14.x版本"
        echo "5. 查询15.x版本"
        echo "6. 查询16.x版本"
        echo "7. 查询17.x版本"
        echo "8. 查询18.x版本"
        echo "9. 手动输入版本号"
        echo "b. 返回上级菜单"
        echo "q. 退出安装"
        echo ""
        
        read -p "请选择 [1-9/b/q]: " version_mode
        
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
                PG_VERSION=$DEFAULT_PG_VERSION
                echo -e "${GREEN}使用默认版本: $PG_VERSION${NC}"
                break
                ;;
            "2")
                if [ "$need_proxy" = false ]; then
                    query_postgresql_versions "12"
                    if [ -z "$PG_VERSION" ]; then
                        echo -e "${YELLOW}查询失败，可能需要代理${NC}"
                        if setup_proxy; then
                            need_proxy=true
                            query_postgresql_versions "12"
                        fi
                    fi
                else
                    query_postgresql_versions "12"
                fi
                if [ -n "$PG_VERSION" ]; then
                    break
                fi
                ;;
            "3")
                if [ "$need_proxy" = false ]; then
                    query_postgresql_versions "13"
                    if [ -z "$PG_VERSION" ]; then
                        echo -e "${YELLOW}查询失败，可能需要代理${NC}"
                        if setup_proxy; then
                            need_proxy=true
                            query_postgresql_versions "13"
                        fi
                    fi
                else
                    query_postgresql_versions "13"
                fi
                if [ -n "$PG_VERSION" ]; then
                    break
                fi
                ;;
            "4")
                if [ "$need_proxy" = false ]; then
                    query_postgresql_versions "14"
                    if [ -z "$PG_VERSION" ]; then
                        echo -e "${YELLOW}查询失败，可能需要代理${NC}"
                        if setup_proxy; then
                            need_proxy=true
                            query_postgresql_versions "14"
                        fi
                    fi
                else
                    query_postgresql_versions "14"
                fi
                if [ -n "$PG_VERSION" ]; then
                    break
                fi
                ;;
            "5")
                if [ "$need_proxy" = false ]; then
                    query_postgresql_versions "15"
                    if [ -z "$PG_VERSION" ]; then
                        echo -e "${YELLOW}查询失败，可能需要代理${NC}"
                        if setup_proxy; then
                            need_proxy=true
                            query_postgresql_versions "15"
                        fi
                    fi
                else
                    query_postgresql_versions "15"
                fi
                if [ -n "$PG_VERSION" ]; then
                    break
                fi
                ;;
            "6")
                if [ "$need_proxy" = false ]; then
                    query_postgresql_versions "16"
                    if [ -z "$PG_VERSION" ]; then
                        echo -e "${YELLOW}查询失败，可能需要代理${NC}"
                        if setup_proxy; then
                            need_proxy=true
                            query_postgresql_versions "16"
                        fi
                    fi
                else
                    query_postgresql_versions "16"
                fi
                if [ -n "$PG_VERSION" ]; then
                    break
                fi
                ;;
            "7")
                if [ "$need_proxy" = false ]; then
                    query_postgresql_versions "17"
                    if [ -z "$PG_VERSION" ]; then
                        echo -e "${YELLOW}查询失败，可能需要代理${NC}"
                        if setup_proxy; then
                            need_proxy=true
                            query_postgresql_versions "17"
                        fi
                    fi
                else
                    query_postgresql_versions "17"
                fi
                if [ -n "$PG_VERSION" ]; then
                    break
                fi
                ;;
            "8")
                if [ "$need_proxy" = false ]; then
                    query_postgresql_versions "18"
                    if [ -z "$PG_VERSION" ]; then
                        echo -e "${YELLOW}查询失败，可能需要代理${NC}"
                        if setup_proxy; then
                            need_proxy=true
                            query_postgresql_versions "18"
                        fi
                    fi
                else
                    query_postgresql_versions "18"
                fi
                if [ -n "$PG_VERSION" ]; then
                    break
                fi
                ;;
            "9")
                while true; do
                    read -p "请输入完整的PostgreSQL版本号 (例如: 18.1) 或输入 'b' 返回主菜单: " custom_version
                    if [ "$custom_version" = "b" ] || [ "$custom_version" = "B" ]; then
                        break
                    elif [[ "$custom_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
                        PG_VERSION=$custom_version
                        echo -e "${GREEN}使用自定义版本: $PG_VERSION${NC}"
                        # 验证版本是否存在
                        if verify_version_exists "$PG_VERSION"; then
                            break 2  # 退出两层循环
                        else
                            echo -e "${YELLOW}版本验证失败，请重新输入或返回主菜单${NC}"
                            PG_VERSION=""
                        fi
                    else
                        echo -e "${RED}版本号格式无效，请使用 x.y 或 x.y.z 格式${NC}"
                    fi
                done
                ;;
            *)
                echo -e "${RED}无效选择，请重新输入${NC}"
                ;;
        esac
    done
    
    # 最终验证版本是否存在
    verify_result=0
    if ! verify_version_exists "$PG_VERSION"; then
        verify_result=$?
    fi
    
    if [ $verify_result -ne 0 ]; then
        if [ $verify_result -eq 2 ]; then
            # 网络错误
            echo -e "${YELLOW}网络连接问题，尝试配置代理${NC}"
            if setup_proxy; then
                echo -e "${YELLOW}使用代理重新验证...${NC}"
                if ! verify_version_exists "$PG_VERSION"; then
                    echo -e "${YELLOW}代理验证也失败，请检查网络或代理设置${NC}"
                    echo -e "${YELLOW}是否继续使用版本 $PG_VERSION? [y/N]: " continue_anyway
                    read -p "" continue_anyway
                    if [[ ! $continue_anyway =~ ^[Yy]$ ]]; then
                        PG_VERSION=""
                        select_version
                        return
                    fi
                fi
            else
                echo -e "${YELLOW}是否继续使用版本 $PG_VERSION? [y/N]: " continue_anyway
                read -p "" continue_anyway
                if [[ ! $continue_anyway =~ ^[Yy]$ ]]; then
                    PG_VERSION=""
                    select_version
                    return
                fi
            fi
        else
            # 版本不存在
            echo -e "${YELLOW}版本验证失败，请重新选择版本${NC}"
            PG_VERSION=""
            select_version
            return
        fi
    fi
    
    echo ""
}

# ICU 开发环境的“真实编译+链接”探测（可复用）
# 仅存在头文件（如 CentOS 7 自带 unicode/*.h）不代表能链接成功，
# 必须通过一次真实编译+链接，否则启用 ICU 后 make 阶段会报
# undefined reference to u_xxx_* 链接错误。
# 返回 0 = 可链接（并导出 ICU_CFLAGS/ICU_LIBS）；非 0 = 不可链接。
icu_link_test() {
    local cc_bin=""
    if command -v cc &>/dev/null; then cc_bin="cc"; elif command -v gcc &>/dev/null; then cc_bin="gcc"; fi

    local cflags="" libs=""
    if command -v pkg-config &>/dev/null && pkg-config --exists icu-uc icu-i18n 2>/dev/null; then
        cflags="$(pkg-config --cflags icu-uc icu-i18n 2>/dev/null)"
        libs="$(pkg-config --libs icu-uc icu-i18n 2>/dev/null)"
    fi

    local test_c="/tmp/pg_icu_test.c"
    cat > "$test_c" <<'ICU_TEST_EOF'
#include <unicode/utypes.h>
#include <unicode/ustring.h>
#include <unicode/ucol.h>
int main(void) {
    UErrorCode st = U_ZERO_ERROR;
    UChar s[8] = {0};
    u_strToLower(s, 8, s, 0, NULL, &st);
    ucol_open(NULL, &st);
    return (int)st;
}
ICU_TEST_EOF

    local ok=false
    if [ -n "$cc_bin" ]; then
        if "$cc_bin" "$test_c" $cflags $libs -o /tmp/pg_icu_test_bin 2>/dev/null; then
            ok=true
        elif "$cc_bin" "$test_c" -licui18n -licuuc -licudata -o /tmp/pg_icu_test_bin 2>/dev/null; then
            # 直接链接成功，补上空的 cflags
            cflags=""; libs="-licui18n -licuuc -licudata"
            ok=true
        fi
        rm -f /tmp/pg_icu_test_bin
    else
        # 无编译器时退化为检查“开发库软链 + 头文件”（libicuuc.so 存在才算开发包已装）
        if ls /usr/lib*/libicuuc.so /usr/lib*/*/libicuuc.so /usr/local/lib/libicuuc.so /usr/lib/libicuuc.so &>/dev/null \
           && ls /usr/include/unicode/ucol.h /usr/local/include/unicode/ucol.h &>/dev/null; then
            cflags=""; libs="-licui18n -licuuc -licudata"
            ok=true
        fi
    fi
    rm -f "$test_c"

    if [ "$ok" = true ]; then
        export ICU_CFLAGS="$cflags"
        export ICU_LIBS="$libs"
        return 0
    fi
    return 1
}

# ICU 支持交互选择（PostgreSQL 16+ 默认开启 ICU，需由用户决定）
# 说明：PG 15 及更早默认不启用 ICU；PG 16/17/18 起 configure 默认检测 ICU，
#       若系统无 libicu 开发包会直接报错退出，必须显式 --without-icu 才能关闭。
prompt_icu_support() {
    # 已显式指定 ICU 相关参数则不再询问
    if echo "$CONFIGURE_OPTIONS" | grep -q "\-\-with-icu"; then
        echo -e "${YELLOW}已启用 ICU 支持（需确保已安装 libicu-devel/libicu-dev）${NC}"
        return 0
    fi
    if echo "$CONFIGURE_OPTIONS" | grep -q "\-\-without-icu"; then
        return 0
    fi

    # 取主版本号（如 17.9 -> 17）
    local pg_major
    pg_major="${PG_VERSION%%.*}"

    # PG 15 及更早默认不启用 ICU，无需处理
    if [ -z "$pg_major" ] || ! [[ "$pg_major" =~ ^[0-9]+$ ]] || [ "$pg_major" -lt 16 ]; then
        return 0
    fi

    # 通过真实编译+链接测试判断 ICU 开发环境是否可用（复用 icu_link_test）
    local icu_present=false
    if icu_link_test; then
        icu_present=true
    fi

    echo ""
    echo -e "${CYAN}检测到 PostgreSQL ${pg_major}+：ICU（国际化排序/字符集归类）默认开启。${NC}"
    if [ "$icu_present" = true ]; then
        echo -e "${GREEN}已通过编译链接测试，系统 ICU 开发环境可用，可安全启用 ICU。${NC}"
    else
        echo -e "${YELLOW}未检测到“可链接”的 libicu 开发库（离线/CentOS 7 常见：仅有头文件或缺 libicuuc.so 软链）。${NC}"
        echo -e "${YELLOW}  - 此时若启用 ICU，configure 可能通过，但 make 阶段会报 undefined reference to u_xxx_* 链接错误。${NC}"
        echo -e "${YELLOW}  - 确需启用请先安装完整开发包：libicu-devel(CentOS/RHEL) 或 libicu-dev(Ubuntu/Debian)。${NC}"
        echo -e "${GREEN}  - 不影响数据库核心功能，离线环境建议直接选 2 关闭。${NC}"
    fi
    echo "  1. 启用 ICU（保留国际化排序功能，需已安装 libicu 开发包）"
    echo "  2. 关闭 ICU（追加 --without-icu，不影响数据库核心功能）"
    while true; do
        read -p "请选择是否启用 ICU [1/2，默认 2]: " icu_choice
        icu_choice="${icu_choice:-2}"
        case "$icu_choice" in
            1)
                # ICU 不可链接仍坚持启用时，二次确认，避免 make 阶段链接失败
                if [ "$icu_present" != true ]; then
                    echo -e "${RED}警告：系统 ICU 未通过链接测试，启用后极可能在编译阶段报 undefined reference 链接错误。${NC}"
                    read -p "仍要强制启用 ICU 吗？建议选 n 关闭 [y/N]: " force_icu
                    if [[ ! "$force_icu" =~ ^[Yy]$ ]]; then
                        CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --without-icu"
                        echo -e "${YELLOW}已改为追加 --without-icu，关闭 ICU 支持。${NC}"
                        break
                    fi
                fi
                CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-icu"
                echo -e "${GREEN}已启用 ICU 支持。${NC}"
                break
                ;;
            2)
                CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --without-icu"
                echo -e "${YELLOW}已追加 --without-icu，关闭 ICU 支持。${NC}"
                break
                ;;
            *)
                echo -e "${RED}无效选择，请输入 1 或 2${NC}"
                ;;
        esac
    done
}

# 插件选择函数
select_plugins() {
    # 重置UUID库选择
    UUID_LIBRARY=""
    # 重置选择的插件
    SELECTED_PLUGINS=""
    # 重置 pgvector 标志
    INSTALL_PGVECTOR=""
    PGVECTOR_INSTALLED=""
    
    echo -e "${YELLOW}请选择需要编译安装的插件:${NC}"
    echo ""
    
    # 定义可用插件
    declare -A plugins
    plugins[openssl]="OpenSSL支持 (SSL/TLS连接)"
    plugins[perl]="Perl存储过程支持"
    plugins[python]="Python存储过程支持"
    plugins[tcl]="Tcl存储过程支持"
    plugins[uuid]="UUID支持 (默认ossp，可选e2fs)"
    plugins[xml]="XML支持"
    plugins[icu]="ICU支持"
    plugins[ldap]="LDAP认证支持"
    plugins[pam]="PAM认证支持"
    plugins[bonjour]="Bonjour支持"
    plugins[systemd]="systemd集成支持"
    plugins[pgvector]="pgvector向量扩展 (独立第三方扩展，编译后自动CREATE EXTENSION)"

    # 显示插件选项
    echo "可用插件列表:"
    echo "----------------------------------------"
    for key in "${!plugins[@]}"; do
        printf "%-12s - %s\n" "$key" "${plugins[$key]}"
    done
    echo "----------------------------------------"
    echo ""

    echo -e "${CYAN}选择方式:${NC}"
    echo "1. 从上面的插件列表中选择"
    echo "2. 输入自定义的configure参数"
    echo "3. 混合模式（列表选择 + 自定义参数）"
    echo "4. 查看自定义参数示例"
    echo "b. 返回上一级（重新配置）"
    echo "q. 退出安装"
    echo ""
    
    read -p "请选择输入方式 [1/2/3/4/b/q]: " input_mode
    
    local selected_plugins=""
    local custom_options=""
    
    case $input_mode in
        "b"|"B")
            # 返回上一级（重新配置）
            echo -e "${YELLOW}返回上一级...${NC}"
            return 2  # 返回2表示需要返回版本选择
            ;;
        "q"|"Q")
            # 退出安装
            echo -e "${RED}退出安装${NC}"
            exit 0
            ;;
        "1")
            # 从预定义列表选择
            read -p "请输入需要安装的插件名称，多个插件用空格分隔 (例如: openssl perl python): " selected_plugins
            ;;
        "2")
            # 完全自定义
            read -p "请输入自定义的configure参数 (例如: --with-openssl --with-python --enable-debug): " custom_options
            ;;
        "3")
            # 混合模式
            read -p "请输入需要安装的插件名称，多个插件用空格分隔: " selected_plugins
            read -p "请输入额外的configure参数 (例如: --enable-debug CFLAGS=-O2): " custom_options
            ;;
        "4")
            # 显示自定义选项示例
            show_custom_options_examples
            echo ""
            echo -e "${CYAN}请重新选择输入方式:${NC}"
            select_plugins
            return
            ;;
        *)
            echo -e "${RED}无效选择，请重新输入${NC}"
            select_plugins
            return
            ;;
    esac
    
    # 基础配置选项
    CONFIGURE_OPTIONS="--without-readline --prefix=$PG_INSTALL_DIR --with-pgport=$PG_PORT --enable-thread-safety"
    
    # 处理预定义插件
    if [ -n "$selected_plugins" ]; then
        echo -e "${GREEN}选择的插件: $selected_plugins${NC}"
        
        for plugin in $selected_plugins; do
            case $plugin in
                "openssl")
                    CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-openssl"
                    ;;
                "perl")
                    CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-perl"
                    ;;
                "python")
                    CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-python"
                    ;;
                "tcl")
                    CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-tcl"
                    ;;
                "uuid")
                    echo -e "${YELLOW}请选择UUID实现方式:${NC}"
                    echo "1. ossp (OSSP UUID库 - 功能完整但依赖较多)"
                    echo "2. e2fs (util-linux UUID库 - 轻量级标准实现)"
                    read -p "请选择 [1/2]: " uuid_choice
                    case $uuid_choice in
                        "2")
                            CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-uuid=e2fs"
                            UUID_LIBRARY="e2fs"
                            echo -e "${GREEN}使用e2fs UUID实现${NC}"
                            ;;
                        *)
                            CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-uuid=ossp"
                            UUID_LIBRARY="ossp"
                            echo -e "${GREEN}使用ossp UUID实现${NC}"
                            ;;
                    esac
                    ;;
                "xml")
                    CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-libxml"
                    ;;
                "icu")
                    CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-icu"
                    ;;
                "ldap")
                    CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-ldap"
                    ;;
                "pam")
                    CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-pam"
                    ;;
                "bonjour")
                    CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-bonjour"
                    ;;
                "systemd")
                    CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-systemd"
                    ;;
                "pgvector")
                    # pgvector 是独立第三方扩展，不属于 ./configure 参数，编译后单独安装
                    INSTALL_PGVECTOR="true"
                    echo -e "${GREEN}已选择 pgvector，将在 PostgreSQL 编译安装后单独编译该扩展${NC}"
                    ;;
                
                *)
                    echo -e "${YELLOW}注意: 插件 '$plugin' 不在预定义列表中，将作为自定义参数处理${NC}"
                    CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-$plugin"
                    ;;
            esac
        done
        
        # 存储选择的插件供后续使用
        SELECTED_PLUGINS="$selected_plugins"
        
        # 安装插件依赖
        install_plugin_dependencies "$selected_plugins"
    fi
    
    # 添加自定义选项
    if [ -n "$custom_options" ]; then
        echo -e "${GREEN}自定义参数: $custom_options${NC}"
        CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS $custom_options"
    fi

    # PostgreSQL 16+ 默认开启 ICU，交由用户决定是否启用
    prompt_icu_support

    echo -e "${GREEN}最终编译配置选项: $CONFIGURE_OPTIONS${NC}"
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
    local parallel_jobs=$cpu_cores
    local manual_cores=""
    
    # 显示可用核心数并询问用户
    echo -e "${CYAN}系统信息:${NC}"
    echo "  可用CPU核心数: $cpu_cores"
    read -p "请输入要使用的核心数 (1-$cpu_cores) [默认: $cpu_cores]: " manual_cores

    # 验证输入
    if [ -z "$manual_cores" ]; then
        # 用户直接按回车，使用默认值
        parallel_jobs=$cpu_cores
        echo -e "${YELLOW}使用默认核心数: $parallel_jobs${NC}"
    elif [[ "$manual_cores" =~ ^[0-9]+$ ]] && [ "$manual_cores" -ge 1 ] && [ "$manual_cores" -le $cpu_cores ]; then
        # 用户输入了有效的数字
        parallel_jobs=$manual_cores
        echo -e "${GREEN}使用指定核心数: $parallel_jobs${NC}"
    else
        # 用户输入了无效值
        echo -e "${RED}无效输入，使用默认核心数: $parallel_jobs${NC}"
        parallel_jobs=$cpu_cores
    fi
    
    # 根据模式调整并行数
    case $compile_mode in
        "1")
            # 并行编译模式：使用用户输入的核心数
            echo -e "${GREEN}并行编译模式: 使用 $parallel_jobs 个核心${NC}"
            ;;
        "2")
            # 智能并行模式：根据系统负载调整
            local load_avg=$(cat /proc/loadavg 2>/dev/null | awk '{print $1}' | cut -d. -f1)
            local load_int=${load_avg%.*}
            
            if [ "$load_int" -gt 2 ]; then
                # 系统负载高，使用较少核心
                parallel_jobs=$((parallel_jobs / 2))
                if [ $parallel_jobs -lt 1 ]; then
                    parallel_jobs=1
                fi
            else
                # 系统负载低，可以使用更多核心
                parallel_jobs=$parallel_jobs
            fi
            
            echo -e "${GREEN}智能并行编译: $parallel_jobs 核心 (系统负载: $load_avg)${NC}"
            ;;
        "3")
            # 单线程模式
            parallel_jobs=1
            echo -e "${GREEN}单线程编译模式: 1 个核心${NC}"
            ;;
        "4")
            # 自定义模式
            read -p "请输入并行数 (1-$cpu_cores): " custom_jobs
            if [[ "$custom_jobs" =~ ^[0-9]+$ ]] && [ "$custom_jobs" -ge 1 ] && [ "$custom_jobs" -le $cpu_cores ]; then
                parallel_jobs=$custom_jobs
                echo -e "${GREEN}使用自定义并行数: $parallel_jobs 个核心${NC}"
            else
                echo -e "${RED}无效输入，使用默认核心数: $parallel_jobs${NC}"
            fi
            ;;
        *)
            echo -e "${RED}无效选择，使用智能并行编译${NC}"
            # 智能调整
            local load_avg=$(cat /proc/loadavg 2>/dev/null | awk '{print $1}' | cut -d. -f1)
            local load_int=${load_avg%.*}
            
            if [ "$load_int" -gt 2 ]; then
                parallel_jobs=$((parallel_jobs / 2))
                if [ $parallel_jobs -lt 1 ]; then
                    parallel_jobs=1
                fi
            else
                parallel_jobs=$parallel_jobs
            fi
            echo -e "${GREEN}智能并行编译: $parallel_jobs 核心 (系统负载: $load_avg)${NC}"
            ;;
    esac
    
    # 显示最终配置
    echo ""
    echo -e "${CYAN}最终配置:${NC}"
    echo "  CPU核心数: $cpu_cores"
    echo "  使用核心数: $parallel_jobs"
    echo "  编译模式: $([ "$compile_mode" == "1" ] && echo "并行编译" || [ "$compile_mode" == "2" ] && echo "智能并行" || [ "$compile_mode" == "3" ] && echo "单线程" || echo "自定义")"
    echo ""
    
    # 配置make并行编译
    export MAKE="make -j$parallel_jobs"
    
    # 确认配置
    read -p "是否确认使用这些编译选项? [y/N]: " confirm_compile
    if [[ ! $confirm_compile =~ ^[Yy]$ ]]; then
        echo -e "${RED}编译配置已取消${NC}"
        exit 0
    fi

    return 0
}

# 显示自定义选项示例
show_custom_options_examples() {
    echo -e "${CYAN}常用的自定义configure参数示例:${NC}"
    echo "----------------------------------------"
    echo "性能优化:"
    echo "  --enable-debug              启用调试符号"
    echo "  --enable-profiling          启用性能分析"
    echo "  CFLAGS='-O2 -march=native'  优化编译选项"
    echo ""
    echo "功能选项:"
    echo "  --with-blocksize=8K         设置块大小"
    echo "  --with-segsize=1GB          设置段大小"
    echo "  --with-wal-blocksize=8K     设置WAL块大小"
    echo "  --enable-integer-datetimes  使用整数日期时间"
    echo "  --disable-float4-byval      禁用float4传值"
    echo "  --with-uuid=ossp           使用OSSP UUID库"
    echo "  --with-uuid=e2fs           使用e2fsprogs UUID库"
    echo ""
    echo "开发选项:"
    echo "  --enable-cassert            启用断言检查"
    echo "  --enable-depend             启用依赖跟踪"
    echo "  --with-llvm                 启用LLVM JIT支持"
    echo ""
    echo "目录选项:"
    echo "  --bindir=DIR                设置可执行文件目录"
    echo "  --libdir=DIR                设置库文件目录"
    echo "  --includedir=DIR            设置头文件目录"
    echo "  --datadir=DIR               设置共享数据目录"
    echo "----------------------------------------"
    echo ""
}

# 安装插件依赖
install_plugin_dependencies() {
    local selected_plugins="$1"
    
    if [ -z "$selected_plugins" ]; then
        return
    fi
    
    # 离线模式下，只显示依赖列表，不尝试安装
    if [ "$OFFLINE_MODE" = "true" ]; then
        echo -e "${YELLOW}离线安装模式: 跳过插件依赖在线安装${NC}"
        echo -e "${CYAN}请确保已手动安装以下插件依赖:${NC}"
        
        if command -v yum &> /dev/null; then
            echo "  CentOS/RHEL:"
            for plugin in $selected_plugins; do
                case $plugin in
                    "openssl")
                        echo "    - yum install openssl-devel"
                        ;;
                    "perl")
                        echo "    - yum install perl-devel"
                        ;;
                    "python")
                        echo "    - yum install python3-devel"
                        ;;
                    "tcl")
                        echo "    - yum install tcl-devel"
                        ;;
                    "uuid")
                        if [ "$UUID_LIBRARY" = "ossp" ]; then
                            echo "    - yum install libossp-uuid-devel (可能需要EPEL源)"
                        else
                            echo "    - yum install util-linux-devel libuuid-devel uuid-devel"
                        fi
                        ;;
                    "xml")
                        echo "    - yum install libxml2-devel libxslt-devel"
                        ;;
                    "icu")
                        echo "    - yum install libicu-devel"
                        ;;
                    "ldap")
                        echo "    - yum install openldap-devel"
                        ;;
                    "pam")
                        echo "    - yum install pam-devel"
                        ;;
                    "bonjour")
                        echo "    - yum install avahi-devel"
                        ;;
                    "systemd")
                        echo "    - yum install systemd-devel"
                        ;;
                esac
            done
        elif command -v apt-get &> /dev/null; then
            echo "  Ubuntu/Debian:"
            for plugin in $selected_plugins; do
                case $plugin in
                    "openssl")
                        echo "    - apt-get install libssl-dev"
                        ;;
                    "perl")
                        echo "    - apt-get install perl"
                        ;;
                    "python")
                        echo "    - apt-get install python3-dev"
                        ;;
                    "tcl")
                        echo "    - apt-get install tcl-dev"
                        ;;
                    "uuid")
                        if [ "$UUID_LIBRARY" = "ossp" ]; then
                            echo "    - apt-get install libossp-uuid-dev"
                        else
                            echo "    - apt-get install uuid-dev libuuid-dev"
                        fi
                        ;;
                    "xml")
                        echo "    - apt-get install libxml2-dev libxslt1-dev"
                        ;;
                    "icu")
                        echo "    - apt-get install libicu-dev"
                        ;;
                    "ldap")
                        echo "    - apt-get install libldap-dev"
                        ;;
                    "pam")
                        echo "    - apt-get install libpam-dev"
                        ;;
                    "bonjour")
                        echo "    - apt-get install libavahi-client-dev"
                        ;;
                    "systemd")
                        echo "    - apt-get install libsystemd-dev"
                        ;;
                esac
            done
        fi
        
        echo ""
        read -p "是否继续编译? [y/N]: " continue_install
        if [[ ! $continue_install =~ ^[Yy]$ ]]; then
            exit 1
        fi
        
        return 0
    fi
    
    echo -e "${YELLOW}安装插件依赖...${NC}"
    
    if command -v yum &> /dev/null; then
        # CentOS/RHEL
        for plugin in $selected_plugins; do
            case $plugin in
                "openssl")
                    yum install -y openssl-devel
                    ;;
                "perl")
                    yum install -y perl-devel
                    ;;
                "python")
                    yum install -y python3-devel
                    ;;
                "tcl")
                    yum install -y tcl-devel
                    ;;
                "uuid")
                    if [ "$UUID_LIBRARY" = "ossp" ]; then
                        # OSSP UUID库依赖
                        yum install -y libossp-uuid-devel
                        # 如果ossp包不可用，尝试EPEL
                        if ! rpm -q libossp-uuid-devel &>/dev/null; then
                            yum install -y epel-release
                            yum install -y libossp-uuid-devel
							yum install -y uuid-devel
                        fi
                    else
                        # e2fs UUID库依赖
                        yum install -y util-linux-devel libuuid-devel
                    fi
                    ;;
                "xml")
                    yum install -y libxml2-devel libxslt-devel
                    ;;
                "icu")
                    yum install -y libicu-devel
                    ;;
                "ldap")
                    yum install -y openldap-devel
                    ;;
                "pam")
                    yum install -y pam-devel
                    ;;
                "bonjour")
                    yum install -y avahi-devel
                    ;;
                "systemd")
                    yum install -y systemd-devel
                    ;;
            esac
        done
    elif command -v apt-get &> /dev/null; then
        # Ubuntu/Debian
        for plugin in $selected_plugins; do
            case $plugin in
                "openssl")
                    apt-get install -y libssl-dev
                    ;;
                "perl")
                    apt-get install -y perl
                    ;;
                "python")
                    apt-get install -y python3-dev
                    ;;
                "tcl")
                    apt-get install -y tcl-dev
                    ;;
                "uuid")
                    if [ "$UUID_LIBRARY" = "ossp" ]; then
                        # OSSP UUID库依赖
                        apt-get install -y libossp-uuid-dev
                        # 如果ossp包不可用，尝试添加源
                        if ! dpkg -l libossp-uuid-dev &>/dev/null; then
                            echo -e "${YELLOW}尝试安装uuid-dev作为替代...${NC}"
                            apt-get install -y uuid-dev
                        fi
                    else
                        # e2fs UUID库依赖
                        apt-get install -y uuid-dev libuuid-dev
                    fi
                    ;;
                "xml")
                    apt-get install -y libxml2-dev libxslt1-dev
                    ;;
                "icu")
                    apt-get install -y libicu-dev
                    ;;
                "ldap")
                    apt-get install -y libldap-dev
                    ;;
                "pam")
                    apt-get install -y libpam-dev
                    ;;
                "bonjour")
                    apt-get install -y libavahi-client-dev
                    ;;
                "systemd")
                    apt-get install -y libsystemd-dev
                    ;;
            esac
        done
    fi
    
    echo -e "${GREEN}插件依赖安装完成!${NC}"
}

# 检查和修复ICU依赖（编译前）
# 仅当显式启用 --with-icu 时介入；用真实编译+链接测试判断 ICU 是否可用，
# 避免“只有头文件/伪造 pkg-config”导致 configure 通过但 make 链接失败。
fix_icu_dependencies() {
    # 未启用 ICU 直接通过（--without-icu 或未选择均无需处理）
    if ! echo "$CONFIGURE_OPTIONS" | grep -q "\-\-with-icu"; then
        return 0
    fi

    echo -e "${YELLOW}检查 ICU 依赖（编译链接测试）...${NC}"

    # 第一次链接测试
    if icu_link_test; then
        echo -e "${GREEN}ICU 开发环境可正常编译链接: ICU_CFLAGS='${ICU_CFLAGS}' ICU_LIBS='${ICU_LIBS}'${NC}"
        return 0
    fi

    # 不可链接：在线环境尝试安装开发包后复测
    echo -e "${RED}ICU 未通过链接测试（常见于离线/CentOS 7：仅有头文件或缺 libicuuc.so 开发软链）。${NC}"

    local can_install=false
    if command -v yum &>/dev/null || command -v dnf &>/dev/null || command -v apt-get &>/dev/null; then
        can_install=true
    fi

    if [ "$can_install" = true ]; then
        echo -e "${YELLOW}请选择解决方案:${NC}"
        echo "  1. 在线安装 ICU 开发包后重试（libicu-devel / libicu-dev）"
        echo "  2. 关闭 ICU（追加 --without-icu，不影响数据库核心功能，离线推荐）"
        echo "  3. 返回插件选择"
        echo ""
        read -p "请选择 [1/2/3，默认 2]: " fix_choice
        fix_choice="${fix_choice:-2}"
        case "$fix_choice" in
            1)
                echo -e "${YELLOW}正在安装 ICU 开发包...${NC}"
                if command -v yum &>/dev/null; then
                    yum install -y libicu-devel || { yum install -y epel-release && yum install -y libicu-devel; }
                elif command -v dnf &>/dev/null; then
                    dnf install -y libicu-devel
                elif command -v apt-get &>/dev/null; then
                    apt-get update && apt-get install -y libicu-dev
                fi
                if icu_link_test; then
                    echo -e "${GREEN}ICU 开发包安装后链接测试通过。${NC}"
                    return 0
                fi
                echo -e "${RED}安装后仍未通过链接测试。${NC}"
                read -p "是否改为关闭 ICU（--without-icu）继续？[Y/n]: " disable_icu
                if [[ "$disable_icu" =~ ^[Nn]$ ]]; then
                    echo -e "${YELLOW}返回插件选择...${NC}"
                    return 1
                fi
                CONFIGURE_OPTIONS="$(echo "$CONFIGURE_OPTIONS" | sed 's/--with-icu/--without-icu/')"
                echo -e "${YELLOW}已改为 --without-icu，关闭 ICU。${NC}"
                return 0
                ;;
            2)
                CONFIGURE_OPTIONS="$(echo "$CONFIGURE_OPTIONS" | sed 's/--with-icu/--without-icu/')"
                echo -e "${YELLOW}已追加 --without-icu，关闭 ICU 支持。${NC}"
                return 0
                ;;
            3)
                echo -e "${YELLOW}返回插件选择...${NC}"
                return 1
                ;;
            *)
                CONFIGURE_OPTIONS="$(echo "$CONFIGURE_OPTIONS" | sed 's/--with-icu/--without-icu/')"
                echo -e "${YELLOW}无效选择，默认关闭 ICU（--without-icu）。${NC}"
                return 0
                ;;
        esac
    fi

    # 离线（无包管理器）：给出离线安装指引，并建议关闭 ICU
    echo -e "${YELLOW}离线环境无法自动安装。如需 ICU，请在联网机下载后离线安装：${NC}"
    echo "  CentOS/RHEL: yum install -y --downloadonly --downloaddir=./icu-deps libicu-devel && rpm -ivh ./icu-deps/*.rpm"
    echo "  Ubuntu/Debian: apt-get download libicu-dev 后 dpkg -i 安装"
    echo ""
    read -p "是否关闭 ICU（--without-icu）继续编译？[Y/n]: " disable_icu2
    if [[ "$disable_icu2" =~ ^[Nn]$ ]]; then
        echo -e "${YELLOW}返回插件选择...${NC}"
        return 1
    fi
    CONFIGURE_OPTIONS="$(echo "$CONFIGURE_OPTIONS" | sed 's/--with-icu/--without-icu/')"
    echo -e "${YELLOW}已追加 --without-icu，关闭 ICU 支持。${NC}"
    return 0
}

# 检查UUID库是否正确安装
check_uuid_library() {
    if [ -z "$UUID_LIBRARY" ]; then
        return 0  # 没有选择UUID插件
    fi
    
    echo -e "${YELLOW}检查UUID库 (${UUID_LIBRARY})...${NC}"
    
    if [ "$UUID_LIBRARY" = "ossp" ]; then
        # 检查OSSP UUID库
        if command -v pkg-config &> /dev/null; then
            if pkg-config --exists uuid 2>/dev/null; then
                echo -e "${GREEN}OSSP UUID库检查通过${NC}"
                return 0
            else
                echo -e "${RED}OSSP UUID库pkg-config配置有问题${NC}"
                # 尝试设置常见路径
                local possible_paths=(
                    "/usr/lib64/pkgconfig"
                    "/usr/lib/pkgconfig"
                    "/usr/local/lib64/pkgconfig"
                    "/usr/local/lib/pkgconfig"
                )
                
                for path in "${possible_paths[@]}"; do
                    if [ -f "$path/uuid.pc" ]; then
                        export PKG_CONFIG_PATH="$path:$PKG_CONFIG_PATH"
                        echo -e "${GREEN}找到OSSP UUID pkg-config文件: $path${NC}"
                        return 0
                    fi
                done
                
                echo -e "${RED}未找到OSSP UUID库，请确保已安装libossp-uuid-dev或libossp-uuid-devel${NC}"
                return 1
            fi
        else
            # 检查头文件和库文件
            if [ -f "/usr/include/uuid/uuid.h" ] || [ -f "/usr/local/include/uuid/uuid.h" ]; then
                echo -e "${GREEN}OSSP UUID头文件存在${NC}"
                return 0
            else
                echo -e "${RED}未找到OSSP UUID头文件${NC}"
                return 1
            fi
        fi
    else
        # 检查e2fs UUID库
        if command -v pkg-config &> /dev/null; then
            if pkg-config --exists uuid 2>/dev/null; then
                echo -e "${GREEN}e2fs UUID库检查通过${NC}"
                return 0
            else
                echo -e "${YELLOW}e2fs UUID库pkg-config配置可能有问题，但通常不影响编译${NC}"
                return 0
            fi
        else
            # 检查头文件
            if [ -f "/usr/include/uuid/uuid.h" ] || [ -f "/usr/local/include/uuid/uuid.h" ]; then
                echo -e "${GREEN}UUID头文件存在${NC}"
                return 0
            else
                echo -e "${RED}未找到UUID头文件${NC}"
                return 1
            fi
        fi
    fi
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
            echo "    - yum install readline-devel zlib-devel gcc make bison flex"
        elif command -v apt-get &> /dev/null; then
            echo "  Ubuntu/Debian:"
            echo "    - apt-get install build-essential libreadline-dev zlib1g-dev bison flex"
        fi
        
        # 检查基础依赖是否存在
        echo ""
        echo -e "${CYAN}检查基础依赖...${NC}"
        
        local missing_deps=""
        
        if ! command -v gcc &> /dev/null; then
            missing_deps="$missing_deps gcc"
        fi
        if ! command -v make &> /dev/null; then
            missing_deps="$missing_deps make"
        fi
        # PostgreSQL 编译必需的语法分析工具（configure 缺失即报错中断）
        if ! command -v bison &> /dev/null; then
            missing_deps="$missing_deps bison"
        fi
        if ! command -v flex &> /dev/null; then
            missing_deps="$missing_deps flex"
        fi
        
        if [ -n "$missing_deps" ]; then
            echo -e "${RED}缺少以下基础依赖: $missing_deps${NC}"
            echo -e "${YELLOW}请先手动安装这些依赖（离线环境请用 rpm/dpkg 离线包），或选择退出安装${NC}"
            if command -v yum &> /dev/null; then
                echo -e "${CYAN}在线机下载离线包示例: yum install -y --downloadonly --downloaddir=./pg-deps bison flex${NC}"
            elif command -v apt-get &> /dev/null; then
                echo -e "${CYAN}在线机下载离线包示例: apt-get download bison flex${NC}"
            fi
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
        yum install -y readline-devel zlib-devel gcc make bison flex
    elif command -v apt-get &> /dev/null; then
        # Ubuntu/Debian
        apt-get update
        apt-get install -y build-essential libreadline-dev zlib1g-dev bison flex
    else
        echo -e "${RED}不支持的包管理器，请手动安装依赖: readline-devel, zlib-devel, gcc, make, bison, flex${NC}"
        exit 1
    fi
}

# 创建用户和目录
create_user_and_dirs() {
    echo -e "${YELLOW}创建PostgreSQL用户和目录...${NC}"
    
    # 创建用户组
    if ! getent group $PG_GROUP &>/dev/null; then
        groupadd $PG_GROUP
    fi
    
    # 创建用户
    if ! id -u $PG_USER &>/dev/null; then
        useradd -m -g $PG_GROUP $PG_USER
        echo -e "${GREEN}设置PostgreSQL用户密码...${NC}"
        echo "$PG_USER:$PG_PASSWORD" | chpasswd
    fi
    
    # 创建目录
    mkdir -p $PG_INSTALL_DIR $PG_DATA_DIR
    
    # 授权
    chown -R $PG_USER:$PG_GROUP $PG_HOME
    chmod -R 755 $PG_HOME
    
    # 检查数据目录
    if [ -d "$PG_DATA_DIR" ] && [ "$(ls -A $PG_DATA_DIR 2>/dev/null)" ]; then
        echo -e "${YELLOW}检测到数据目录已存在: $PG_DATA_DIR${NC}"
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
                    backup_dir="${PG_DATA_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
                    echo -e "${YELLOW}备份数据目录到: $backup_dir${NC}"
                    cp -r $PG_DATA_DIR $backup_dir
                    rm -rf ${PG_DATA_DIR}/*
                    echo -e "${GREEN}数据目录已备份并清空${NC}"
                    break
                    ;;
                "3")
                    echo -e "${YELLOW}清空数据目录...${NC}"
                    rm -rf ${PG_DATA_DIR}/*
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

# 检查是否已安装PostgreSQL
check_existing_installation() {
    if [ -d "$PG_INSTALL_DIR" ] && [ "$(ls -A $PG_INSTALL_DIR 2>/dev/null)" ]; then
        echo -e "${YELLOW}检测到PostgreSQL已安装在: $PG_INSTALL_DIR${NC}"
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
                    rm -rf $PG_INSTALL_DIR
                    echo -e "${GREEN}已删除现有安装${NC}"
                    return 0
                    ;;
                "2")
                    echo -e "${GREEN}保留现有文件，直接进入编译${NC}"
                    return 1
                    ;;
                "3")
                    backup_dir="${PG_INSTALL_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
                    echo -e "${YELLOW}备份现有安装到: $backup_dir${NC}"
                    mv $PG_INSTALL_DIR $backup_dir
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

# 离线tar包查找和验证函数
find_offline_tarbll() {
    echo -e "${YELLOW}查找PostgreSQL离线安装包...${NC}"
    echo ""
    
    # 支持输入的路径格式：
    # 1. 直接的tar.gz文件路径
    # 2. 包含tar.gz文件的目录路径
    
    while true; do
        echo -e "${CYAN}请输入PostgreSQL tar.gz包的路径或目录:${NC}"
        echo "  - 完整路径: /path/to/postgresql-xx.x.x.tar.gz"
        echo "  - 目录路径: /path/to/ (会自动查找目录中的tar.gz包)"
        echo -e "  - 直接回车: 默认使用脚本所在目录 ${GREEN}$SCRIPT_DIR${NC}"
        echo "b. 返回主菜单"
        echo ""
        read -p "请输入路径 [回车使用脚本所在目录 / 输入b返回]: " input_path

        # 未手动填写时，默认使用脚本当前所在目录（离线包通常与脚本放在一起）
        if [ -z "$input_path" ]; then
            input_path="$SCRIPT_DIR"
            echo -e "${CYAN}未输入路径，使用脚本所在目录: $input_path${NC}"
        fi

        case "$input_path" in
            "b"|"B")
                return 1
                ;;
        esac

        # 检查路径是否存在
        if [ ! -e "$input_path" ]; then
            echo -e "${RED}路径不存在: $input_path${NC}"
            continue
        fi
        
        # 如果是文件，检查是否是tar.gz
        if [ -f "$input_path" ]; then
            if [[ "$input_path" =~ \.tar\.gz$ ]]; then
                # 验证文件内容是否是PostgreSQL源码
                if tar -tzf "$input_path" 2>/dev/null | grep -q "^postgresql-[0-9]"; then
                    OFFLINE_TARBALL_PATH="$input_path"
                    # 从文件名提取版本号
                    PG_VERSION=$(basename "$input_path" | sed 's/postgresql-//' | sed 's/\.tar\.gz//')
                    echo -e "${GREEN}找到PostgreSQL源码包: $OFFLINE_TARBALL_PATH${NC}"
                    echo -e "${GREEN}版本: $PG_VERSION${NC}"
                    
                    # 确认是否继续
                    read -p "是否使用此包? [y/N]: " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        return 0
                    fi
                else
                    echo -e "${RED}文件不是有效的PostgreSQL源码包${NC}"
                    continue
                fi
            else
                echo -e "${RED}文件必须是.tar.gz格式${NC}"
                continue
            fi
        # 如果是目录，查找tar.gz文件
        elif [ -d "$input_path" ]; then
            # 查找所有tar.gz文件
            local tarballs=($(find "$input_path" -maxdepth 1 -name "postgresql-*.tar.gz" 2>/dev/null))
            
            if [ ${#tarballs[@]} -eq 0 ]; then
                echo -e "${RED}目录中未找到PostgreSQL tar.gz包${NC}"
                continue
            fi
            
            echo -e "${GREEN}找到 ${#tarballs[@]} 个PostgreSQL tar.gz包:${NC}"
            echo ""
            local counter=1
            for tarball in "${tarballs[@]}"; do
                local version=$(basename "$tarball" | sed 's/postgresql-//' | sed 's/\.tar\.gz//')
                echo "$counter. $version ($(basename "$tarball"))"
                ((counter++))
            done
            echo ""
            
            # 用户选择
            read -p "请选择包编号 [1-${#tarballs[@]}]: " choice
            
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#tarballs[@]} ]; then
                local index=$((choice - 1))
                OFFLINE_TARBALL_PATH="${tarballs[$index]}"
                PG_VERSION=$(basename "$OFFLINE_TARBALL_PATH" | sed 's/postgresql-//' | sed 's/\.tar\.gz//')
                echo -e "${GREEN}已选择: $OFFLINE_TARBALL_PATH${NC}"
                echo -e "${GREEN}版本: $PG_VERSION${NC}"
                
                # 确认是否继续
                read -p "是否使用此包? [y/N]: " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    return 0
                fi
            else
                echo -e "${RED}无效选择${NC}"
                continue
            fi
        fi
    done
}

# 离线解压PostgreSQL
extract_offline_tarbll() {
    echo -e "${YELLOW}解压PostgreSQL ${PG_VERSION}...${NC}"
    
    if [ -z "$OFFLINE_TARBALL_PATH" ] || [ ! -f "$OFFLINE_TARBALL_PATH" ]; then
        echo -e "${RED}离线安装包路径无效${NC}"
        return 1
    fi
    
    cd /tmp
    
    # 复制tar.gz包到/tmp
    cp "$OFFLINE_TARBALL_PATH" /tmp/postgresql-${PG_VERSION}.tar.gz
    
    echo -e "${YELLOW}解压PostgreSQL源码...${NC}"
    
    # 检查是否已解压
    if [ -d "postgresql-${PG_VERSION}" ]; then
        echo -e "${YELLOW}发现已解压的源码，删除后重新解压${NC}"
        rm -rf postgresql-${PG_VERSION}
    fi
    
    tar -zvxf postgresql-${PG_VERSION}.tar.gz
    
    # 检查是否需要移动文件
    if [ -d "$PG_INSTALL_DIR" ] && [ "$(ls -A $PG_INSTALL_DIR 2>/dev/null)" ]; then
        echo -e "${YELLOW}目标目录已存在文件，使用cp覆盖${NC}"
        cp -rf postgresql-${PG_VERSION}/* $PG_INSTALL_DIR/
        rm -rf postgresql-${PG_VERSION}
    else
        # 确保安装目录存在
        mkdir -p $PG_INSTALL_DIR
        # 移动到安装目录
        mv postgresql-${PG_VERSION}/* $PG_INSTALL_DIR/
        rm -rf postgresql-${PG_VERSION}
    fi
    
    echo -e "${GREEN}源码准备完成${NC}"
    return 0
}

# 下载和解压PostgreSQL
download_and_extract() {
    echo -e "${YELLOW}下载PostgreSQL ${PG_VERSION}...${NC}"

    cd /tmp

    # 使用选定的镜像源，默认使用官网镜像
    local mirror_base="${PG_MIRROR:-https://ftp.postgresql.org/pub/source}"
    local mirror_display="${MIRROR_NAME:-官网镜像}"

    # 构建下载URL
    DOWNLOAD_URL="${mirror_base}/v${PG_VERSION}/postgresql-${PG_VERSION}.tar.gz"

    # 最大重试次数
    local max_retries=3
    local retry_count=0
    local download_success=0

    while [ $retry_count -lt $max_retries ]; do
        # 检查是否已有源码包，如果是第一次或需要重新下载则删除旧文件
        if [ -f "postgresql-${PG_VERSION}.tar.gz" ] && [ $retry_count -eq 0 ]; then
            echo -e "${YELLOW}发现已有源码包，验证完整性...${NC}"
            # 验证现有文件
            if verify_tar_file "postgresql-${PG_VERSION}.tar.gz"; then
                echo -e "${GREEN}现有源码包完整，跳过下载${NC}"
                download_success=1
                break
            else
                echo -e "${YELLOW}现有源码包损坏，将重新下载${NC}"
                rm -f "postgresql-${PG_VERSION}.tar.gz"
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
                rm -f "postgresql-${PG_VERSION}.tar.gz"
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
                rm -f "postgresql-${PG_VERSION}.tar.gz"
                ((retry_count++))
                continue
            fi
        else
            echo -e "${RED}需要安装wget或curl来下载PostgreSQL${NC}"
            return 1
        fi

        # 验证下载的文件
        if [ ! -f "postgresql-${PG_VERSION}.tar.gz" ]; then
            echo -e "${RED}下载失败：文件不存在${NC}"
            ((retry_count++))
            continue
        fi

        # 检查文件大小（PostgreSQL源码包通常大于20MB）
        local file_size=$(stat -f%z "postgresql-${PG_VERSION}.tar.gz" 2>/dev/null || stat -c%s "postgresql-${PG_VERSION}.tar.gz" 2>/dev/null)
        local min_size=20971520  # 20MB
        if [ "$file_size" -lt "$min_size" ]; then
            echo -e "${RED}下载的文件大小异常 (${file_size} bytes)，可能不完整${NC}"
            rm -f "postgresql-${PG_VERSION}.tar.gz"
            ((retry_count++))
            continue
        fi

        # 验证tar文件完整性
        if verify_tar_file "postgresql-${PG_VERSION}.tar.gz"; then
            echo -e "${GREEN}文件完整性验证通过${NC}"
            download_success=1
            break
        else
            echo -e "${RED}文件完整性验证失败，文件可能已损坏${NC}"
            rm -f "postgresql-${PG_VERSION}.tar.gz"
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

    echo -e "${YELLOW}解压PostgreSQL...${NC}"

    # 检查是否已解压
    if [ -d "postgresql-${PG_VERSION}" ]; then
        echo -e "${YELLOW}发现已解压的源码，删除后重新解压${NC}"
        rm -rf postgresql-${PG_VERSION}
    fi

    # 解压文件
    if ! tar -zxf postgresql-${PG_VERSION}.tar.gz; then
        echo -e "${RED}解压失败${NC}"
        rm -f "postgresql-${PG_VERSION}.tar.gz"
        return 1
    fi

    # 检查解压是否成功
    if [ ! -d "postgresql-${PG_VERSION}" ]; then
        echo -e "${RED}解压后目录不存在，解压可能失败${NC}"
        return 1
    fi

    # 检查是否需要移动文件
    if [ -d "$PG_INSTALL_DIR" ] && [ "$(ls -A $PG_INSTALL_DIR 2>/dev/null)" ]; then
        echo -e "${YELLOW}目标目录已存在文件，使用cp覆盖${NC}"
        cp -rf postgresql-${PG_VERSION}/* $PG_INSTALL_DIR/
        rm -rf postgresql-${PG_VERSION}
    else
        # 确保安装目录存在
        mkdir -p $PG_INSTALL_DIR
        # 移动到安装目录
        mv postgresql-${PG_VERSION}/* $PG_INSTALL_DIR/
        rm -rf postgresql-${PG_VERSION}
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

# 编译安装PostgreSQL
compile_install() {
    echo -e "${YELLOW}编译安装PostgreSQL...${NC}"
    
    cd $PG_INSTALL_DIR
    
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
    
    echo -e "${GREEN}执行命令: ./configure $CONFIGURE_OPTIONS${NC}"
    echo -e "${CYAN}编译命令: make -j$make_jobs && make install${NC}"
    echo ""

    # 若源码目录残留上次 configure 的产物（选项不同），先彻底清理避免混链
    if [ -f Makefile ]; then
        echo -e "${YELLOW}检测到旧的编译配置，执行 make distclean 清理残留产物...${NC}"
        make distclean >/dev/null 2>&1 || true
    fi

    ./configure $CONFIGURE_OPTIONS 2>&1 | tee /tmp/postgres_configure.log
        
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        echo -e "${RED}配置失败，错误日志已保存到 /tmp/postgres_configure.log${NC}"
        
        # 检查常见错误：ICU 相关
        if grep -q "icu-uc icu-i18n\|unicode/ucol.h\|ICU library not found\|Package requirements (icu-uc icu-i18n) were not met" /tmp/postgres_configure.log; then
            echo -e "${RED}检测到 ICU 依赖问题。${NC}"

            # 用真实编译+链接测试判断（而不是只看头文件/伪造 pkg-config）
            if icu_link_test; then
                echo -e "${GREEN}ICU 链接测试通过: ICU_CFLAGS='${ICU_CFLAGS}' ICU_LIBS='${ICU_LIBS}'，重新配置...${NC}"
                ./configure $CONFIGURE_OPTIONS
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}ICU 问题已解决!${NC}"
                else
                    echo -e "${RED}设置 ICU 环境变量后仍配置失败，请查看 /tmp/postgres_configure.log${NC}"
                    return 1
                fi
            else
                echo -e "${YELLOW}ICU 未通过链接测试（离线/CentOS 7 常见：仅有头文件或缺 libicuuc.so 开发软链）。${NC}"
                echo -e "${YELLOW}请选择解决方案:${NC}"
                echo "  1. 在线安装 ICU 开发包后重试（libicu-devel / libicu-dev）"
                echo "  2. 关闭 ICU（--without-icu，不影响数据库核心功能，离线推荐）"
                echo "  3. 终止并返回插件选择"
                echo ""
                read -p "请选择 [1/2/3，默认 2]: " icu_fail_choice
                icu_fail_choice="${icu_fail_choice:-2}"
                case "$icu_fail_choice" in
                    1)
                        echo -e "${YELLOW}正在安装 ICU 开发包...${NC}"
                        if command -v yum &>/dev/null; then
                            yum install -y libicu-devel || { yum install -y epel-release && yum install -y libicu-devel; }
                        elif command -v dnf &>/dev/null; then
                            dnf install -y libicu-devel
                        elif command -v apt-get &>/dev/null; then
                            apt-get update && apt-get install -y libicu-dev
                        else
                            echo -e "${RED}不支持的包管理器（离线环境无法在线安装）。${NC}"
                        fi
                        if icu_link_test; then
                            echo -e "${GREEN}ICU 开发包安装后链接测试通过，重新配置...${NC}"
                            ./configure $CONFIGURE_OPTIONS
                            [ $? -eq 0 ] && echo -e "${GREEN}ICU 问题已解决!${NC}" || { echo -e "${RED}仍然失败，请查看 /tmp/postgres_configure.log${NC}"; return 1; }
                        else
                            echo -e "${RED}安装后仍未通过链接测试。${NC}"
                            read -p "是否改为关闭 ICU（--without-icu）继续？[Y/n]: " d1
                            if [[ "$d1" =~ ^[Nn]$ ]]; then return 1; fi
                            CONFIGURE_OPTIONS="$(echo "$CONFIGURE_OPTIONS" | sed 's/--with-icu/--without-icu/')"
                            echo -e "${YELLOW}已改为 --without-icu，重新配置...${NC}"
                            ./configure $CONFIGURE_OPTIONS
                            [ $? -eq 0 ] && echo -e "${GREEN}已关闭 ICU 并配置成功。${NC}" || { echo -e "${RED}配置失败，请查看 /tmp/postgres_configure.log${NC}"; return 1; }
                        fi
                        ;;
                    2)
                        CONFIGURE_OPTIONS="$(echo "$CONFIGURE_OPTIONS" | sed 's/--with-icu/--without-icu/')"
                        echo -e "${YELLOW}已改为 --without-icu，重新配置...${NC}"
                        ./configure $CONFIGURE_OPTIONS
                        [ $? -eq 0 ] && echo -e "${GREEN}已关闭 ICU 并配置成功。${NC}" || { echo -e "${RED}配置失败，请查看 /tmp/postgres_configure.log${NC}"; return 1; }
                        ;;
                    3|*)
                        echo -e "${YELLOW}返回插件选择...${NC}"
                        return 1
                        ;;
                esac
            fi
        else
            echo -e "${YELLOW}请检查错误日志并安装相应的依赖包${NC}"
            echo -e "${YELLOW}错误日志: /tmp/postgres_configure.log${NC}"
            return 1
        fi
    fi

    echo -e "${YELLOW}开始编译...${NC}"
    make
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}编译失败${NC}"
        exit 1
    fi
    
    echo -e "${YELLOW}开始安装...${NC}"
    echo -e "${CYAN}使用并行编译 (make -j$make_jobs)...${NC}"
    
    # 并行编译
    make -j$make_jobs
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}并行编译失败，尝试单线程编译...${NC}"
        echo -e "${YELLOW}这可能是因为某些编译依赖问题${NC}"
        make
        if [ $? -ne 0 ]; then
            echo -e "${RED}编译失败${NC}"
            exit 1
        fi
    fi
    
    # 并行安装
    echo -e "${CYAN}并行安装...${NC}"
    make -j$make_jobs install
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}并行安装失败，尝试单线程安装...${NC}"
        make install
        if [ $? -ne 0 ]; then
            echo -e "${RED}安装失败${NC}"
            exit 1
        fi
    fi
    
    echo -e "${GREEN}PostgreSQL安装完成!${NC}"

    # 编译安装contrib模块
    echo -e "${YELLOW}编译安装contrib模块...${NC}"

    # 检查contrib目录
    if [ -d "contrib" ]; then
        cd contrib

        # 获取所有contrib模块列表
        local contrib_modules=""
        for module_dir in */; do
            # 移除末尾的斜杠
            module="${module_dir%/}"
            # 跳过非目录或特殊目录
            if [ -d "$module" ] && [ -f "$module/Makefile" ]; then
                if [ -z "$contrib_modules" ]; then
                    contrib_modules="$module"
                else
                    contrib_modules="$contrib_modules $module"
                fi
            fi
        done

        # 编译所有contrib模块
        if [ -n "$contrib_modules" ]; then
            echo -e "${CYAN}发现以下contrib模块: $contrib_modules${NC}"
            echo ""

            # 询问用户是否编译所有contrib模块
            echo "请选择编译方式:"
            echo "1. 编译所有contrib模块（推荐）"
            echo "2. 仅编译常用模块（dblink, fuzzystrmatch, pgcrypto, unaccent, citext, uuid-ossp, pg_trgm）"
            echo "3. 跳过contrib模块编译"
            echo ""
            read -p "请选择 [1/2/3]: " contrib_choice

            local modules_to_compile=""

            case $contrib_choice in
                "1")
                    # 编译所有模块
                    modules_to_compile="$contrib_modules"
                    echo -e "${GREEN}将编译所有contrib模块${NC}"
                    ;;
                "2")
                    # 仅编译常用模块
                    local common_modules="dblink fuzzystrmatch pgcrypto unaccent citext uuid-ossp pg_trgm"
                    for module in $common_modules; do
                        if echo "$contrib_modules" | grep -q "$module"; then
                            if [ -z "$modules_to_compile" ]; then
                                modules_to_compile="$module"
                            else
                                modules_to_compile="$modules_to_compile $module"
                            fi
                        fi
                    done
                    echo -e "${GREEN}将编译常用contrib模块: $modules_to_compile${NC}"
                    ;;
                "3")
                    echo -e "${YELLOW}跳过contrib模块编译${NC}"
                    cd ..
                    echo ""
                    echo -e "${CYAN}编译统计:${NC}"
                    echo "  并行数: $make_jobs"
                    echo "  编译时间: $(date)"
                    echo ""
                    return 0
                    ;;
                *)
                    echo -e "${YELLOW}无效选择，默认编译所有contrib模块${NC}"
                    modules_to_compile="$contrib_modules"
                    ;;
            esac

            echo ""
            echo -e "${CYAN}准备编译以下contrib模块: $modules_to_compile${NC}"

            # 并行编译contrib模块
            echo -e "${YELLOW}开始编译contrib模块 (并行数: $make_jobs)...${NC}"

            # 创建后台编译任务
            local pids=""
            for module in $modules_to_compile; do
                if [ -d "$module" ]; then
                    echo -e "${CYAN}编译模块: $module${NC}"
                    (
                        cd "$module"
                        echo -e "${YELLOW}在 $module 目录执行: make -j$make_jobs && make install${NC}"
                        make -j$make_jobs > /tmp/postgres_contrib_${module}_compile.log 2>&1
                        if [ $? -eq 0 ]; then
                            make install >> /tmp/postgres_contrib_${module}_compile.log 2>&1
                            if [ $? -eq 0 ]; then
                                echo -e "${GREEN}✓ 模块 $module 编译安装成功${NC}"
                            else
                                echo -e "${RED}✗ 模块 $module 安装失败${NC}"
                                exit 1
                            fi
                        else
                            echo -e "${RED}✗ 模块 $module 编译失败${NC}"
                            echo -e "${YELLOW}错误日志: /tmp/postgres_contrib_${module}_compile.log${NC}"
                            exit 1
                        fi
                    ) &
                    pids="$pids $!"
                fi
            done

            # 等待所有后台任务完成
            local compile_failed=false
            for pid in $pids; do
                wait $pid
                if [ $? -ne 0 ]; then
                    compile_failed=true
                fi
            done

            if [ "$compile_failed" = true ]; then
                echo -e "${RED}部分contrib模块编译失败${NC}"
                echo -e "${YELLOW}请检查日志文件: /tmp/postgres_contrib_*_compile.log${NC}"
            else
                echo -e "${GREEN}所有contrib模块编译安装完成!${NC}"
            fi

            # 保存已编译的模块列表供后续使用
            export COMPILED_CONTRIB_MODULES="$modules_to_compile"
        else
            echo -e "${YELLOW}未找到可编译的contrib模块${NC}"
        fi

        cd ..
    else
        echo -e "${YELLOW}未找到contrib目录，跳过contrib模块编译${NC}"
    fi

    # 编译安装 pgvector 扩展（独立第三方扩展，需在主程序 make install 之后）
    if [ "$INSTALL_PGVECTOR" = "true" ]; then
        if install_pgvector; then
            PGVECTOR_INSTALLED="true"
        else
            echo -e "${YELLOW}pgvector 扩展安装未完成，PostgreSQL 主程序不受影响${NC}"
        fi
    fi

    # 显示编译统计
    echo ""
    echo -e "${CYAN}编译统计:${NC}"
    echo "  并行数: $make_jobs"
    echo "  编译时间: $(date)"
    if [ -n "$modules_to_compile" ]; then
        echo "  已编译contrib模块: $modules_to_compile"
    fi
    echo ""
    return 0
}

# 配置环境变量
setup_environment() {
    echo -e "${YELLOW}配置环境变量...${NC}"
    
    # 检查是否已经存在PostgreSQL环境变量配置
    if grep -q "# PostgreSQL Environment Variables" /etc/profile; then
        echo -e "${YELLOW}PostgreSQL环境变量已存在，更新配置...${NC}"
        # 备份原配置
        cp /etc/profile /etc/profile.backup.$(date +%Y%m%d_%H%M%S)
        # 删除旧的PostgreSQL配置
        sed -i '/# PostgreSQL Environment Variables/,/^$/d' /etc/profile
    fi
    
    # 添加新的环境变量配置
    cat >> /etc/profile << EOF

# PostgreSQL Environment Variables
export PGHOME=$PG_INSTALL_DIR
export PGDATA=$PG_DATA_DIR
export PATH=\$PGHOME/bin:\$PATH
export LANG=en_US.utf8
export LD_LIBRARY_PATH=\$PGHOME/lib:\$LD_LIBRARY_PATH
EOF
    
    # 立即在当前会话中生效
    echo -e "${YELLOW}使环境变量在当前会话中生效...${NC}"
    export PGHOME="$PG_INSTALL_DIR"
    export PGDATA="$PG_DATA_DIR"
    export PATH="$PG_INSTALL_DIR/bin:$PATH"
    export LANG="en_US.utf8"
    export LD_LIBRARY_PATH="$PG_INSTALL_DIR/lib:$LD_LIBRARY_PATH"
    
    # 同时source /etc/profile以确保其他环境变量也生效
    source /etc/profile > /dev/null 2>&1
    
    echo -e "${GREEN}环境变量配置完成并已生效${NC}"
    echo -e "${CYAN}当前PostgreSQL环境变量:${NC}"
    echo "  PGHOME: $PGHOME"
    echo "  PGDATA: $PGDATA"
    echo "  PATH已包含: $PG_INSTALL_DIR/bin"
    if [ -n "$LD_LIBRARY_PATH" ]; then
        echo "  LD_LIBRARY_PATH已包含: $PG_INSTALL_DIR/lib"
    fi
}

# 初始化数据库
init_database() {
    echo -e "${YELLOW}初始化数据库...${NC}"
    
    # 检查是否已初始化
    if [ -f "$PG_DATA_DIR/PG_VERSION" ]; then
        local existing_version=$(cat "$PG_DATA_DIR/PG_VERSION" 2>/dev/null)
        if [ "$existing_version" = "${PG_VERSION%.*}" ]; then
            echo -e "${YELLOW}数据库已初始化 (版本: $existing_version)${NC}"
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
                    local backup_dir="${PG_DATA_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
                    echo -e "${YELLOW}备份数据目录到: $backup_dir${NC}"
                    mv "$PG_DATA_DIR" "$backup_dir"
                    mkdir -p "$PG_DATA_DIR"
                    chown -R $PG_USER:$PG_GROUP "$PG_DATA_DIR"
                    chmod 700 "$PG_DATA_DIR"
                    ;;
                "3")
                    rm -rf "$PG_DATA_DIR"/*
                    ;;
                *)
                    echo -e "${YELLOW}跳过初始化${NC}"
                    return 0
                    ;;
            esac
        fi
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
            su - $PG_USER -c "$PG_INSTALL_DIR/bin/initdb -D $PG_DATA_DIR"
            if [ $? -eq 0 ]; then
                init_success=true
            else
                echo -e "${RED}su -初始化失败${NC}"
            fi
            ;;
        "2")
            echo -e "${YELLOW}尝试使用当前用户初始化...${NC}"
            $PG_INSTALL_DIR/bin/initdb -D $PG_DATA_DIR
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
                    chown $PG_USER:$PG_GROUP "$custom_data_dir"
                fi
                su - $PG_USER -c "$PG_INSTALL_DIR/bin/initdb -D $custom_data_dir"
                if [ $? -eq 0 ]; then
                    PG_DATA_DIR="$custom_data_dir"
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
            echo -e "${YELLOW}注意: 需要手动初始化数据库才能使用PostgreSQL${NC}"
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
        chown -R $PG_USER:$PG_GROUP "$PG_DATA_DIR" 2>/dev/null
        chmod 700 "$PG_DATA_DIR" 2>/dev/null
        return 0
    else
        echo -e "${RED}数据库初始化失败!${NC}"
        echo -e "${YELLOW}可能的解决方案:${NC}"
        echo "1. 确保postgres用户存在且有权限"
        echo "2. 确保数据目录存在且为空"
        echo "3. 尝试手动初始化（选项4）"
        echo "4. 检查磁盘空间"
        echo ""
        echo -e "${YELLOW}手动初始化命令:${NC}"
        echo "$PG_INSTALL_DIR/bin/initdb -D $PG_DATA_DIR"
        echo ""
        
        read -p "是否重试初始化? [y/N]: " retry_init
        if [[ $retry_init =~ ^[Yy]$ ]]; then
            return init_database
        else
            return 1
        fi
    fi
}

# 配置PostgreSQL
configure_postgresql() {
    echo -e "${YELLOW}配置PostgreSQL...${NC}"
    
    # 修改postgresql.conf
    sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" $PG_DATA_DIR/postgresql.conf
    sed -i "s/#port = 5432/port = $PG_PORT/" $PG_DATA_DIR/postgresql.conf
    
    # 修改性能配置，直接替换现有配置
    # 时区设置
    if grep -q "^#timezone = " $PG_DATA_DIR/postgresql.conf; then
        sed -i "s/^#timezone = .*/timezone = 'Asia\/Shanghai'/" $PG_DATA_DIR/postgresql.conf
    elif grep -q "^timezone = " $PG_DATA_DIR/postgresql.conf; then
        sed -i "s/^timezone = .*/timezone = 'Asia\/Shanghai'/" $PG_DATA_DIR/postgresql.conf
    else
        echo "timezone = 'Asia/Shanghai'" >> $PG_DATA_DIR/postgresql.conf
    fi
    
    # 最大连接数
    if grep -q "^#max_connections = " $PG_DATA_DIR/postgresql.conf; then
        sed -i "s/^#max_connections = .*/max_connections = 1000/" $PG_DATA_DIR/postgresql.conf
    elif grep -q "^max_connections = " $PG_DATA_DIR/postgresql.conf; then
        sed -i "s/^max_connections = .*/max_connections = 1000/" $PG_DATA_DIR/postgresql.conf
    else
        echo "max_connections = 1000" >> $PG_DATA_DIR/postgresql.conf
    fi
    
    # 超级用户保留连接数
    if grep -q "^#superuser_reserved_connections = " $PG_DATA_DIR/postgresql.conf; then
        sed -i "s/^#superuser_reserved_connections = .*/superuser_reserved_connections = 13/" $PG_DATA_DIR/postgresql.conf
    elif grep -q "^superuser_reserved_connections = " $PG_DATA_DIR/postgresql.conf; then
        sed -i "s/^superuser_reserved_connections = .*/superuser_reserved_connections = 13/" $PG_DATA_DIR/postgresql.conf
    else
        echo "superuser_reserved_connections = 13" >> $PG_DATA_DIR/postgresql.conf
    fi
    
    # 共享缓冲区
    if grep -q "^#shared_buffers = " $PG_DATA_DIR/postgresql.conf; then
        sed -i "s/^#shared_buffers = .*/shared_buffers = 2GB/" $PG_DATA_DIR/postgresql.conf
    elif grep -q "^shared_buffers = " $PG_DATA_DIR/postgresql.conf; then
        sed -i "s/^shared_buffers = .*/shared_buffers = 2GB/" $PG_DATA_DIR/postgresql.conf
    else
        echo "shared_buffers = 2GB" >> $PG_DATA_DIR/postgresql.conf
    fi
    
    # 最大工作进程数
    if grep -q "^#max_worker_processes = " $PG_DATA_DIR/postgresql.conf; then
        sed -i "s/^#max_worker_processes = .*/max_worker_processes = 128/" $PG_DATA_DIR/postgresql.conf
    elif grep -q "^max_worker_processes = " $PG_DATA_DIR/postgresql.conf; then
        sed -i "s/^max_worker_processes = .*/max_worker_processes = 128/" $PG_DATA_DIR/postgresql.conf
    else
        echo "max_worker_processes = 128" >> $PG_DATA_DIR/postgresql.conf
    fi
    
    # 每个gather操作的最大并行工作进程数
    if grep -q "^#max_parallel_workers_per_gather = " $PG_DATA_DIR/postgresql.conf; then
        sed -i "s/^#max_parallel_workers_per_gather = .*/max_parallel_workers_per_gather = 2/" $PG_DATA_DIR/postgresql.conf
    elif grep -q "^max_parallel_workers_per_gather = " $PG_DATA_DIR/postgresql.conf; then
        sed -i "s/^max_parallel_workers_per_gather = .*/max_parallel_workers_per_gather = 2/" $PG_DATA_DIR/postgresql.conf
    else
        echo "max_parallel_workers_per_gather = 2" >> $PG_DATA_DIR/postgresql.conf
    fi
    
    # 最大并行工作进程数
    if grep -q "^#max_parallel_workers = " $PG_DATA_DIR/postgresql.conf; then
        sed -i "s/^#max_parallel_workers = .*/max_parallel_workers = 8/" $PG_DATA_DIR/postgresql.conf
    elif grep -q "^max_parallel_workers = " $PG_DATA_DIR/postgresql.conf; then
        sed -i "s/^max_parallel_workers = .*/max_parallel_workers = 8/" $PG_DATA_DIR/postgresql.conf
    else
        echo "max_parallel_workers = 8" >> $PG_DATA_DIR/postgresql.conf
    fi
    
    # 修改pg_hba.conf
    echo -e "${YELLOW}配置pg_hba.conf认证方式...${NC}"
    
    # 备份原始文件
    cp "$PG_DATA_DIR/pg_hba.conf" "$PG_DATA_DIR/pg_hba.conf.backup"
    echo -e "${GREEN}✓ 已备份pg_hba.conf${NC}"
    
    # 检查并修改local连接的认证方式
    if grep -q "^local   all             all                                     peer" "$PG_DATA_DIR/pg_hba.conf"; then
        sed -i "s/^local   all             all                                     peer/local   all             all                                     trust/" "$PG_DATA_DIR/pg_hba.conf"
        echo -e "${GREEN}✓ 已将local连接从peer改为trust${NC}"
    elif grep -q "^local   all             all                                     md5" "$PG_DATA_DIR/pg_hba.conf"; then
        echo -e "${YELLOW}local连接已经是md5认证，保持不变${NC}"
    elif ! grep -q "^local   all             all                                     trust" "$PG_DATA_DIR/pg_hba.conf"; then
        # 如果没有找到local配置，先删除可能存在的其他local配置，然后添加
        sed -i '/^local.*all.*all.*\(trust\|md5\|peer\|scram-sha-256\)$/d' "$PG_DATA_DIR/pg_hba.conf" 2>/dev/null
        sed -i "1i local   all             all                                     trust" "$PG_DATA_DIR/pg_hba.conf"
        echo -e "${GREEN}✓ 已添加local连接trust认证${NC}"
    else
        echo -e "${GREEN}local连接已经是trust认证${NC}"
    fi
    
    # 检查并添加远程连接配置
    # 先删除已存在的相同配置，避免重复
    sed -i '/^host    all             all             0.0.0.0\/0               md5$/d' "$PG_DATA_DIR/pg_hba.conf" 2>/dev/null

    # 添加远程连接配置
    echo "host    all             all             0.0.0.0/0               md5" >> "$PG_DATA_DIR/pg_hba.conf"
    echo -e "${GREEN}✓ 已添加远程连接md5认证${NC}"
    
    # 显示最终配置
    echo -e "${CYAN}当前pg_hba.conf认证配置:${NC}"
    grep -E "^(local|host).*all.*all" "$PG_DATA_DIR/pg_hba.conf" | head -10
}

# 创建系统服务
create_systemd_service() {
    echo -e "${YELLOW}创建系统服务...${NC}"
    
    cat > /etc/systemd/system/postgresql${PG_VERSION%.*}.service << EOF
[Unit]
Description=PostgreSQL ${PG_VERSION%.*} Server
After=network.target

[Service]
Type=forking
User=$PG_USER
Group=$PG_GROUP
PIDFile=$PG_DATA_DIR/postmaster.pid
ExecStart=$PG_INSTALL_DIR/bin/pg_ctl start -D $PG_DATA_DIR -l $PG_DATA_DIR/postgresql.log
ExecStop=$PG_INSTALL_DIR/bin/pg_ctl stop -D $PG_DATA_DIR
ExecReload=$PG_INSTALL_DIR/bin/pg_ctl reload -D $PG_DATA_DIR
Restart=on-failure
RestartSec=5s
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF
    
    chmod 700 /etc/systemd/system/postgresql${PG_VERSION%.*}.service
    
    # 重新加载systemd配置
    systemctl daemon-reload
    
    # 启动服务
    systemctl start postgresql${PG_VERSION%.*}
    
    # 设置开机自启
    systemctl enable postgresql${PG_VERSION%.*}
    
    echo -e "${GREEN}PostgreSQL服务已创建并启动!${NC}"
}

# 设置密码
set_password() {
    echo -e "${YELLOW}设置PostgreSQL用户密码...${NC}"
    
    # 查找正确的服务名
    local service_name=""
    local postgresql_services=$(systemctl list-units --all --type=service --no-legend | grep -i postgres | awk '{print $1}')
    
    if [ -z "$postgresql_services" ]; then
        # 尝试常见的服务名
        if [ -n "$PG_VERSION" ]; then
            # 尝试基于版本的服务名
            local version_short="${PG_VERSION%.*}"
            local possible_names=(
                "postgresql${version_short}"
                "postgresql-${version_short}"
                "postgresql@${version_short}-main"
                "postgresql"
            )
            for name in "${possible_names[@]}"; do
                if systemctl list-units --all --type=service --no-legend | grep -q "^${name}.service"; then
                    service_name="${name}.service"
                    break
                fi
            done
        else
            # 没有版本信息，尝试默认服务名
            if systemctl list-units --all --type=service --no-legend | grep -q "^postgresql.service"; then
                service_name="postgresql.service"
            fi
        fi
    else
        # 使用找到的第一个服务
        local service_array=($postgresql_services)
        service_name="${service_array[0]}"
    fi
    
    if [ -z "$service_name" ]; then
        echo -e "${YELLOW}警告: 未找到PostgreSQL服务，将跳过服务状态检查${NC}"
    else
        echo -e "${CYAN}使用服务名: $service_name${NC}"
    fi
    
    # 检查服务是否启动
    if [ -n "$service_name" ] && ! systemctl is-active --quiet $service_name; then
        echo -e "${YELLOW}PostgreSQL服务未运行，尝试启动...${NC}"
        systemctl start $service_name
        sleep 3
    fi
    
    # 显示当前密码配置
    echo -e "${CYAN}当前密码配置:${NC}"
    echo "  用户名: $PG_USER"
    echo "  预设密码: $PG_PASSWORD"
    echo ""
    
    # 询问用户是否需要修改密码
    echo -e "${YELLOW}请选择密码设置方式:${NC}"
    echo "1. 使用postgres用户免密登录方式（推荐）"
    echo "2. 使用预设密码 ($PG_PASSWORD)"
    echo "3. 输入新密码（隐藏输入）"
    echo "4. 跳过密码设置"
    echo ""
    read -p "请选择 [1-4]: " password_choice
    
    local new_password="$PG_PASSWORD"
    local password_set=false
    
    case $password_choice in
        "1")
            echo -e "${GREEN}使用postgres用户免密登录方式${NC}"
            echo -e "${CYAN}执行步骤:${NC}"
            echo "  1. 切换到postgres用户"
            echo "  2. 免密登录psql"
            echo "  3. 设置密码"
            echo ""
            
            # 方法1: 使用postgres用户免密登录方式
            echo -e "${YELLOW}步骤1: 检查pg_hba.conf配置...${NC}"
            
            # 检查pg_hba.conf中的认证方式
            local hba_file="$PG_DATA_DIR/pg_hba.conf"
            if [ -f "$hba_file" ]; then
                # 备份原始文件
                cp "$hba_file" "$hba_file.backup"
                
                # 修改本地连接为trust（免密）
                # 先删除可能存在的local配置，避免重复
                sed -i '/^local.*all.*all.*\(trust\|md5\|peer\|scram-sha-256\)$/d' "$hba_file" 2>/dev/null

                if grep -q "^local.*all.*all.*peer" "$hba_file"; then
                    sed -i 's/^local.*all.*all.*peer/local   all             all                                     trust/' "$hba_file"
                    echo -e "${GREEN}✓ 已将peer认证改为trust认证${NC}"
                elif grep -q "^local.*all.*all.*md5" "$hba_file"; then
                    sed -i 's/^local.*all.*all.*md5/local   all             all                                     trust/' "$hba_file"
                    echo -e "${GREEN}✓ 已将md5认证改为trust认证${NC}"
                elif grep -q "^local.*all.*all.*scram-sha-256" "$hba_file"; then
                    sed -i 's/^local.*all.*all.*scram-sha-256/local   all             all                                     trust/' "$hba_file"
                    echo -e "${GREEN}✓ 已将scram-sha-256认证改为trust认证${NC}"
                else
                    # 如果没有找到local配置，添加一条
                    sed -i "1i local   all             all                                     trust" "$hba_file"
                    echo -e "${GREEN}✓ 已添加trust认证配置${NC}"
                fi
                
                # 重启服务使配置生效
                echo -e "${YELLOW}步骤2: 重启服务使配置生效...${NC}"
                systemctl restart $service_name
                sleep 3
                
                # 使用postgres用户免密登录方式设置密码
                echo -e "${YELLOW}步骤3: 设置密码...${NC}"
                
                # 创建临时脚本用于设置密码
                temp_script="/tmp/set_postgres_password.sh"
                cat > "$temp_script" << EOF
#!/bin/bash
# 切换到postgres用户并设置密码
echo "正在设置postgres用户密码..."
psql -c "ALTER USER postgres WITH PASSWORD '$PG_PASSWORD';"
echo "密码设置完成，退出psql"
exit
EOF
                
                # 执行脚本
                if [ "$EUID" -eq 0 ]; then
                    # 以root身份执行
                    chown postgres:postgres "$temp_script"
                    chmod +x "$temp_script"
                    su - postgres -c "bash $temp_script" 2>/dev/null
                    
                    if [ $? -eq 0 ]; then
                        password_set=true
                        echo -e "${GREEN}✓ postgres用户免密登录设置密码成功${NC}"
                    else
                        echo -e "${RED}✗ postgres用户免密登录设置密码失败${NC}"
                    fi
                else
                    # 非root用户执行
                    echo -e "${RED}需要root权限来切换postgres用户${NC}"
                    echo -e "${YELLOW}请手动执行以下命令:${NC}"
                    echo "su - postgres"
                    echo "psql"
                    echo "ALTER USER postgres WITH PASSWORD '$PG_PASSWORD';"
                    echo "\\q"
                    echo "exit"
                fi
                
                # 清理临时文件
                rm -f "$temp_script"
                
                # 恢复pg_hba.conf认证方式
                if [ "$password_set" = true ]; then
                    echo -e "${YELLOW}步骤4: 恢复安全认证方式...${NC}"

                    # 先删除所有 local all all 的配置，避免重复
                    sed -i '/^local.*all.*all.*\(trust\|md5\|peer\|scram-sha-256\)$/d' "$hba_file" 2>/dev/null

                    # 添加一条新的 md5 认证配置
                    sed -i "1i local   all             all                                     md5" "$hba_file"
                    echo -e "${GREEN}✓ 已添加local连接md5认证${NC}"

                    # 再次重启服务
                    systemctl restart $service_name
                    sleep 2
                    echo -e "${GREEN}✓ 服务已重启，密码设置完成${NC}"
                else
                    # 如果设置失败，恢复备份
                    if [ -f "$hba_file.backup" ]; then
                        mv "$hba_file.backup" "$hba_file"
                        systemctl restart $service_name
                        echo -e "${YELLOW}已恢复原始配置${NC}"
                    fi
                fi
            else
                echo -e "${RED}找不到pg_hba.conf文件${NC}"
            fi
            ;;
        "2")
            echo -e "${YELLOW}使用预设密码: $PG_PASSWORD${NC}"
            password_set=true
            ;;
        "3")
            # 隐藏密码输入
            echo -e "${YELLOW}请输入新密码 (输入时不会显示): ${NC}"
            read -s -p "新密码: " new_password
            if [ -z "$new_password" ]; then
                echo -e "${RED}密码不能为空，使用预设密码${NC}"
                new_password="$PG_PASSWORD"
            else
                # 验证密码强度
                if [ ${#new_password} -lt 6 ]; then
                    echo -e "${YELLOW}警告: 密码长度少于6位，建议使用更长的密码${NC}"
                    read -p "是否继续使用此密码? [y/N]: " weak_confirm
                    if [[ ! $weak_confirm =~ ^[Yy]$ ]]; then
                        echo -e "${YELLOW}使用预设密码: $PG_PASSWORD${NC}"
                        new_password="$PG_PASSWORD"
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
            echo -e "${RED}无效选择，使用postgres用户免密登录方式${NC}"
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
        echo -e "${YELLOW}正在设置PostgreSQL密码...${NC}"
        
        # 方法1: 使用sudo -u
        if [ "$EUID" -eq 0 ] && command -v sudo &> /dev/null; then
            echo -e "${CYAN}方法1: 使用sudo -u切换用户${NC}"
            sudo -u $PG_USER psql -c "ALTER USER $PG_USER WITH PASSWORD '$new_password';" 2>/dev/null
            if [ $? -eq 0 ]; then
                password_set=true
                echo -e "${GREEN}✓ sudo -u设置密码成功${NC}"
            else
                echo -e "${RED}✗ sudo -u设置失败${NC}"
            fi
        fi
        
        # 方法2: 使用su -
        if [ "$password_set" = false ] && [ "$EUID" -eq 0 ]; then
            echo -e "${CYAN}方法2: 使用su -切换用户${NC}"
            su - $PG_USER -c "psql -c \"ALTER USER $PG_USER WITH PASSWORD '$new_password';\"" 2>/dev/null
            if [ $? -eq 0 ]; then
                password_set=true
                echo -e "${GREEN}✓ su -设置密码成功${NC}"
            else
                echo -e "${RED}✗ su -设置失败${NC}"
            fi
        fi
        
        # 方法3: 直接使用psql
        if [ "$password_set" = false ]; then
            echo -e "${CYAN}方法3: 直接使用psql连接${NC}"
            PGPASSWORD="$new_password" psql -U $PG_USER -c "ALTER USER $PG_USER WITH PASSWORD '$new_password';" 2>/dev/null
            if [ $? -eq 0 ]; then
                password_set=true
                echo -e "${GREEN}✓ 直接设置密码成功${NC}"
            else
                echo -e "${RED}✗ 直接设置失败${NC}"
            fi
        fi
        
        # 方法4: 手动设置提示
        if [ "$password_set" = false ]; then
            echo -e "${RED}所有自动方法都失败${NC}"
            echo -e "${YELLOW}请手动执行以下命令设置密码:${NC}"
            echo ""
            echo "----------------------------------------"
            echo "# 方法1: 使用postgres用户免密登录（推荐）"
            echo "# 1. 修改pg_hba.conf"
            echo "sed -i 's/^local.*all.*all.*peer/local   all             all                                     trust/' $PG_DATA_DIR/pg_hba.conf"
            echo "# 2. 重启服务"
            echo "systemctl restart $service_name"
            echo "# 3. 切换用户并设置密码"
            echo "su - postgres"
            echo "psql"
            echo "ALTER USER postgres WITH PASSWORD '$new_password';"
            echo "\\q"
            echo "exit"
            echo "# 4. 恢复安全认证"
            echo "sed -i 's/^local.*all.*all.*trust/local   all             all                                     md5/' $PG_DATA_DIR/pg_hba.conf"
            echo "systemctl restart $service_name"
            echo ""
            echo "# 方法2: 直接使用psql"
            echo "PGPASSWORD='$new_password' psql -U $PG_USER -c \"ALTER USER $PG_USER WITH PASSWORD '$new_password';\""
            echo "----------------------------------------"
            echo ""
            
            read -p "设置密码完成后，按回车键继续... " -r
            # 验证是否设置了密码（通过尝试连接）
            echo -e "${YELLOW}验证密码设置...${NC}"
            PGPASSWORD="$new_password" psql -U $PG_USER -c "SELECT 1;" &>/dev/null
            if [ $? -eq 0 ]; then
                password_set=true
                echo -e "${GREEN}✓ 密码验证成功${NC}"
            else
                echo -e "${RED}✗ 密码验证失败，请检查服务状态${NC}"
                echo -e "${YELLOW}请确保PostgreSQL服务正在运行${NC}"
                echo -e "${YELLOW}服务状态: $(systemctl is-active $service_name 2>/dev/null || echo "未运行")"
            fi
        fi
    fi
    
    # 显示密码设置结果
    if [ "$password_set" = true ]; then
        echo ""
        echo -e "${GREEN}密码设置完成!${NC}"
        echo -e "${CYAN}PostgreSQL连接信息:${NC}"
        echo "  用户名: $PG_USER"
        if [ "$password_choice" = "1" ] || [ "$password_choice" = "2" ]; then
            echo "  密码: $PG_PASSWORD"
        else
            echo "  密码: [已设置]"
        fi
        echo "  连接命令: psql -U $PG_USER"
        echo "  连接命令: PGPASSWORD=<密码> psql -U $PG_USER"
        echo ""
        echo -e "${YELLOW}提示: 首次连接可能需要输入密码${NC}"
        echo -e "${CYAN}可以在~/.pgpass文件中保存密码以避免每次输入${NC}"
        echo ""
    else
        echo -e "${RED}密码设置失败${NC}"
        echo -e "${YELLOW}请手动执行以下命令:${NC}"
        echo ""
        echo "# 使用postgres用户免密登录方式（推荐）"
        echo "su - postgres"
        echo "psql"
        echo "ALTER USER postgres WITH PASSWORD '$new_password';"
        echo "\\q"
        echo "exit"
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
    local port="$PG_PORT"
    
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
        echo -e "${CYAN}PostgreSQL端口信息:${NC}"
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

# 配置远程访问（Navicat）
configure_remote_access() {
    echo -e "${YELLOW}配置PostgreSQL远程访问（Navicat连接）...${NC}"
    
    # 查找正确的服务名
    local service_name=""
    local postgresql_services=$(systemctl list-units --all --type=service --no-legend | grep -i postgres | awk '{print $1}')
    
    if [ -z "$postgresql_services" ]; then
        # 尝试常见的服务名
        if [ -n "$PG_VERSION" ]; then
            # 尝试基于版本的服务名
            local version_short="${PG_VERSION%.*}"
            local possible_names=(
                "postgresql${version_short}"
                "postgresql-${version_short}"
                "postgresql@${version_short}-main"
                "postgresql"
            )
            for name in "${possible_names[@]}"; do
                if systemctl list-units --all --type=service --no-legend | grep -q "^${name}.service"; then
                    service_name="${name}.service"
                    break
                fi
            done
        else
            # 没有版本信息，尝试默认服务名
            if systemctl list-units --all --type=service --no-legend | grep -q "^postgresql.service"; then
                service_name="postgresql.service"
            fi
        fi
    else
        # 使用找到的第一个服务
        local service_array=($postgresql_services)
        service_name="${service_array[0]}"
    fi
    
    if [ -z "$service_name" ]; then
        echo -e "${YELLOW}警告: 未找到PostgreSQL服务，将跳过服务状态检查${NC}"
    else
        echo -e "${CYAN}使用服务名: $service_name${NC}"
    fi
    
    # 检查服务是否启动
    if [ -n "$service_name" ] && ! systemctl is-active --quiet $service_name; then
        echo -e "${YELLOW}PostgreSQL服务未运行，尝试启动...${NC}"
        systemctl start $service_name
        sleep 3
    fi
    
    # 配置文件路径
    local hba_file="$PG_DATA_DIR/pg_hba.conf"
    local conf_file="$PG_DATA_DIR/postgresql.conf"
    
    # 备份原始文件
    if [ -f "$hba_file" ]; then
        cp "$hba_file" "$hba_file.backup"
        echo -e "${GREEN}✓ 已备份pg_hba.conf${NC}"
    fi
    
    if [ -f "$conf_file" ]; then
        cp "$conf_file" "$conf_file.backup"
        echo -e "${GREEN}✓ 已备份postgresql.conf${NC}"
    fi
    
    # 1. 配置postgresql.conf允许远程连接
    echo -e "${YELLOW}步骤1: 配置postgresql.conf...${NC}"
    
    # 检查并配置listen_addresses
    if grep -q "^listen_addresses" "$conf_file"; then
        # 注释原有的listen_addresses配置
        sed -i 's/^listen_addresses/#listen_addresses/' "$conf_file"
        echo -e "${GREEN}✓ 已注释原有listen_addresses配置${NC}"
        
        # 在原配置下一行添加新配置
        sed -i "/^#listen_addresses/a listen_addresses = '*'" "$conf_file"
        echo -e "${GREEN}✓ 已在下一行添加新的listen_addresses = '*'${NC}"
    elif grep -q "#listen_addresses" "$conf_file"; then
        # 如果已有注释的配置，在其后添加新配置
        sed -i "/^#listen_addresses/a listen_addresses = '*'" "$conf_file"
        echo -e "${GREEN}✓ 已在注释配置后添加listen_addresses = '*'${NC}"
    else
        # 如果没有找到任何listen_addresses配置，添加新配置
        echo "listen_addresses = '*'" >> "$conf_file"
        echo -e "${GREEN}✓ 已添加listen_addresses = '*'${NC}"
    fi
    
    # 检查并配置端口
    if grep -q "^port" "$conf_file"; then
        # 注释原有的port配置
        sed -i 's/^port/#port/' "$conf_file"
        echo -e "${GREEN}✓ 已注释原有port配置${NC}"
        
        # 在原配置下一行添加新配置
        sed -i "/^#port/a port = $PG_PORT" "$conf_file"
        echo -e "${GREEN}✓ 已在下一行添加新的port = $PG_PORT${NC}"
    elif grep -q "#port" "$conf_file"; then
        # 如果已有注释的配置，在其后添加新配置
        sed -i "/^#port/a port = $PG_PORT" "$conf_file"
        echo -e "${GREEN}✓ 已在注释配置后添加port = $PG_PORT${NC}"
    else
        # 如果没有找到任何port配置，添加新配置
        echo "port = $PG_PORT" >> "$conf_file"
        echo -e "${GREEN}✓ 已添加port = $PG_PORT${NC}"
    fi
    
    # 检查并配置timezone
    if grep -q "^timezone" "$conf_file"; then
        # 注释原有的timezone配置
        sed -i 's/^timezone/#timezone/' "$conf_file"
        echo -e "${GREEN}✓ 已注释原有timezone配置${NC}"
        
        # 在原配置下一行添加新配置
        sed -i "/^#timezone/a timezone = 'Asia/Shanghai'" "$conf_file"
        echo -e "${GREEN}✓ 已在下一行添加新的timezone = 'Asia/Shanghai'${NC}"
    elif grep -q "#timezone" "$conf_file"; then
        # 如果已有注释的配置，在其后添加新配置
        sed -i "/^#timezone/a timezone = 'Asia/Shanghai'" "$conf_file"
        echo -e "${GREEN}✓ 已在注释配置后添加timezone = 'Asia/Shanghai'${NC}"
    else
        # 如果没有找到任何timezone配置，添加新配置
        echo "timezone = 'Asia/Shanghai'" >> "$conf_file"
        echo -e "${GREEN}✓ 已添加timezone = 'Asia/Shanghai'${NC}"
    fi
    
    # 检查并配置max_connections
    if grep -q "^max_connections" "$conf_file"; then
        # 注释原有的max_connections配置
        sed -i 's/^max_connections/#max_connections/' "$conf_file"
        echo -e "${GREEN}✓ 已注释原有max_connections配置${NC}"
        
        # 在原配置下一行添加新配置
        sed -i "/^#max_connections/a max_connections = 1000" "$conf_file"
        echo -e "${GREEN}✓ 已在下一行添加新的max_connections = 1000${NC}"
    elif grep -q "#max_connections" "$conf_file"; then
        # 如果已有注释的配置，在其后添加新配置
        sed -i "/^#max_connections/a max_connections = 1000" "$conf_file"
        echo -e "${GREEN}✓ 已在注释配置后添加max_connections = 1000${NC}"
    else
        # 如果没有找到任何max_connections配置，添加新配置
        echo "max_connections = 1000" >> "$conf_file"
        echo -e "${GREEN}✓ 已添加max_connections = 1000${NC}"
    fi
    
    # 检查并配置superuser_reserved_connections
    if grep -q "^superuser_reserved_connections" "$conf_file"; then
        # 注释原有的superuser_reserved_connections配置
        sed -i 's/^superuser_reserved_connections/#superuser_reserved_connections/' "$conf_file"
        echo -e "${GREEN}✓ 已注释原有superuser_reserved_connections配置${NC}"
        
        # 在原配置下一行添加新配置
        sed -i "/^#superuser_reserved_connections/a superuser_reserved_connections = 13" "$conf_file"
        echo -e "${GREEN}✓ 已在下一行添加新的superuser_reserved_connections = 13${NC}"
    elif grep -q "#superuser_reserved_connections" "$conf_file"; then
        # 如果已有注释的配置，在其后添加新配置
        sed -i "/^#superuser_reserved_connections/a superuser_reserved_connections = 13" "$conf_file"
        echo -e "${GREEN}✓ 已在注释配置后添加superuser_reserved_connections = 13${NC}"
    else
        # 如果没有找到任何superuser_reserved_connections配置，添加新配置
        echo "superuser_reserved_connections = 13" >> "$conf_file"
        echo -e "${GREEN}✓ 已添加superuser_reserved_connections = 13${NC}"
    fi
    
    # 检查并配置shared_buffers
    if grep -q "^shared_buffers" "$conf_file"; then
        # 注释原有的shared_buffers配置
        sed -i 's/^shared_buffers/#shared_buffers/' "$conf_file"
        echo -e "${GREEN}✓ 已注释原有shared_buffers配置${NC}"
        
        # 在原配置下一行添加新配置
        sed -i "/^#shared_buffers/a shared_buffers = 2GB" "$conf_file"
        echo -e "${GREEN}✓ 已在下一行添加新的shared_buffers = 2GB${NC}"
    elif grep -q "#shared_buffers" "$conf_file"; then
        # 如果已有注释的配置，在其后添加新配置
        sed -i "/^#shared_buffers/a shared_buffers = 2GB" "$conf_file"
        echo -e "${GREEN}✓ 已在注释配置后添加shared_buffers = 2GB${NC}"
    else
        # 如果没有找到任何shared_buffers配置，添加新配置
        echo "shared_buffers = 2GB" >> "$conf_file"
        echo -e "${GREEN}✓ 已添加shared_buffers = 2GB${NC}"
    fi
    
    # 检查并配置max_worker_processes
    if grep -q "^max_worker_processes" "$conf_file"; then
        # 注释原有的max_worker_processes配置
        sed -i 's/^max_worker_processes/#max_worker_processes/' "$conf_file"
        echo -e "${GREEN}✓ 已注释原有max_worker_processes配置${NC}"
        
        # 在原配置下一行添加新配置
        sed -i "/^#max_worker_processes/a max_worker_processes = 128" "$conf_file"
        echo -e "${GREEN}✓ 已在下一行添加新的max_worker_processes = 128${NC}"
    elif grep -q "#max_worker_processes" "$conf_file"; then
        # 如果已有注释的配置，在其后添加新配置
        sed -i "/^#max_worker_processes/a max_worker_processes = 128" "$conf_file"
        echo -e "${GREEN}✓ 已在注释配置后添加max_worker_processes = 128${NC}"
    else
        # 如果没有找到任何max_worker_processes配置，添加新配置
        echo "max_worker_processes = 128" >> "$conf_file"
        echo -e "${GREEN}✓ 已添加max_worker_processes = 128${NC}"
    fi
    
    # 检查并配置max_parallel_workers_per_gather
    if grep -q "^max_parallel_workers_per_gather" "$conf_file"; then
        # 注释原有的max_parallel_workers_per_gather配置
        sed -i 's/^max_parallel_workers_per_gather/#max_parallel_workers_per_gather/' "$conf_file"
        echo -e "${GREEN}✓ 已注释原有max_parallel_workers_per_gather配置${NC}"
        
        # 在原配置下一行添加新配置
        sed -i "/^#max_parallel_workers_per_gather/a max_parallel_workers_per_gather = 2" "$conf_file"
        echo -e "${GREEN}✓ 已在下一行添加新的max_parallel_workers_per_gather = 2${NC}"
    elif grep -q "#max_parallel_workers_per_gather" "$conf_file"; then
        # 如果已有注释的配置，在其后添加新配置
        sed -i "/^#max_parallel_workers_per_gather/a max_parallel_workers_per_gather = 2" "$conf_file"
        echo -e "${GREEN}✓ 已在注释配置后添加max_parallel_workers_per_gather = 2${NC}"
    else
        # 如果没有找到任何max_parallel_workers_per_gather配置，添加新配置
        echo "max_parallel_workers_per_gather = 2" >> "$conf_file"
        echo -e "${GREEN}✓ 已添加max_parallel_workers_per_gather = 2${NC}"
    fi
    
    # 检查并配置max_parallel_workers
    if grep -q "^max_parallel_workers" "$conf_file"; then
        # 注释原有的max_parallel_workers配置
        sed -i 's/^max_parallel_workers/#max_parallel_workers/' "$conf_file"
        echo -e "${GREEN}✓ 已注释原有max_parallel_workers配置${NC}"
        
        # 在原配置下一行添加新配置
        sed -i "/^#max_parallel_workers/a max_parallel_workers = 8" "$conf_file"
        echo -e "${GREEN}✓ 已在下一行添加新的max_parallel_workers = 8${NC}"
    elif grep -q "#max_parallel_workers" "$conf_file"; then
        # 如果已有注释的配置，在其后添加新配置
        sed -i "/^#max_parallel_workers/a max_parallel_workers = 8" "$conf_file"
        echo -e "${GREEN}✓ 已在注释配置后添加max_parallel_workers = 8${NC}"
    else
        # 如果没有找到任何max_parallel_workers配置，添加新配置
        echo "max_parallel_workers = 8" >> "$conf_file"
        echo -e "${GREEN}✓ 已添加max_parallel_workers = 8${NC}"
    fi
    
    # 2. 配置pg_hba.conf允许远程连接
    echo -e "${YELLOW}步骤2: 配置pg_hba.conf...${NC}"
    
    # 添加远程连接配置（IPv4）
    # 先删除已存在的相同配置，避免重复
    sed -i '/^host    all             all             0.0.0.0\/0               md5$/d' "$hba_file" 2>/dev/null
    echo "host    all             all             0.0.0.0/0               md5" >> "$hba_file"
    echo -e "${GREEN}✓ 已添加IPv4远程访问配置${NC}"

    # 添加远程连接配置（IPv6）
    # 先删除已存在的相同配置，避免重复
    sed -i '/^host    all             all             ::\/0                    md5$/d' "$hba_file" 2>/dev/null
    echo "host    all             all             ::/0                    md5" >> "$hba_file"
    echo -e "${GREEN}✓ 已添加IPv6远程访问配置${NC}"
    
    # 3. 重启服务使配置生效
    echo -e "${YELLOW}步骤3: 重启PostgreSQL服务...${NC}"
    systemctl restart $service_name
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ PostgreSQL服务重启成功${NC}"
    else
        echo -e "${RED}✗ PostgreSQL服务重启失败${NC}"
        return 1
    fi
    
    # 4. 检查端口监听状态
    echo -e "${YELLOW}步骤4: 检查端口监听状态...${NC}"
    sleep 3
    
    if netstat -tuln | grep ":$PG_PORT " &>/dev/null; then
        echo -e "${GREEN}✓ 端口 $PG_PORT 正在监听${NC}"
    else
        echo -e "${RED}✗ 端口 $PG_PORT 未监听${NC}"
        echo -e "${YELLOW}请检查防火墙配置和网络设置${NC}"
    fi
    
    # 5. 显示Navicat连接信息
    echo ""
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}Navicat远程访问配置完成!${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${CYAN}Navicat连接信息:${NC}"
    echo "  主机名/IP: $(hostname -I | awk '{print $1}')"
    echo "  端口: $PG_PORT"
    echo "  数据库: postgres"
    echo "  用户名: $PG_USER"
    echo "  密码: $PG_PASSWORD"
    echo ""
    echo -e "${CYAN}Navicat连接步骤:${NC}"
    echo "  1. 打开Navicat"
    echo "  2. 新建PostgreSQL连接"
    echo "  3. 填入上述连接信息"
    echo "  4. 点击测试连接"
    echo "  5. 保存连接"
    echo ""
    echo -e "${YELLOW}注意事项:${NC}"
    echo "  1. 确保防火墙已开放端口 $PG_PORT"
    echo "  2. 如果连接失败，请检查:"
    echo "     - 防火墙设置"
    echo "     - 网络连通性"
    echo "     - PostgreSQL服务状态"
    echo "     - 用户权限设置"
    echo ""
    echo -e "${CYAN}防火墙配置命令（如需要）:${NC}"
    if command -v firewall-cmd &>/dev/null; then
        echo "  firewall-cmd --permanent --add-port=$PG_PORT/tcp"
        echo "  firewall-cmd --reload"
    elif command -v ufw &>/dev/null; then
        echo "  ufw allow $PG_PORT/tcp"
    elif command -v iptables &>/dev/null; then
        echo "  iptables -A INPUT -p tcp --dport $PG_PORT -j ACCEPT"
        echo "  service iptables save"
    fi
    echo ""

    return 0
}

# 检查插件依赖是否已安装
check_plugin_dependencies() {
    local selected_plugins="$1"
    local total_failed=0

    echo -e "${CYAN}检查插件依赖...${NC}"
    echo ""

    for plugin in $selected_plugins; do
        echo -e "${CYAN}[$plugin] 检查依赖...${NC}"

        case $plugin in
            "openssl")
                if pkg-config --exists openssl 2>/dev/null || [ -f "/usr/include/openssl/ssl.h" ]; then
                    echo -e "${GREEN}✓ openssl 依赖已安装${NC}"
                else
                    echo -e "${YELLOW}✗ openssl 依赖缺失${NC}"
                    install_package "openssl-devel" "libssl-dev" "openssl"
                fi
                ;;
            "perl")
                if command -v perl &>/dev/null && ([ -d "/usr/lib/perl5" ] || [ -d "/usr/lib64/perl5" ]); then
                    echo -e "${GREEN}✓ perl 依赖已安装${NC}"
                else
                    echo -e "${YELLOW}✗ perl 依赖缺失${NC}"
                    install_package "perl-devel" "perl" "perl"
                fi
                ;;
            "python")
                if pkg-config --exists python3 2>/dev/null || [ -f "/usr/include/python3.9/Python.h" ] || [ -f "/usr/include/python3.11/Python.h" ] || [ -f "/usr/include/python3.12/Python.h" ]; then
                    echo -e "${GREEN}✓ python 依赖已安装${NC}"
                else
                    echo -e "${YELLOW}✗ python 依赖缺失${NC}"
                    install_package "python3-devel" "python3-dev" "python"
                fi
                ;;
            "tcl")
                if pkg-config --exists tcl 2>/dev/null || [ -f "/usr/include/tcl.h" ] || [ -f "/usr/include/tcl8/tcl.h" ] || [ -f "/usr/include/tcl8.6/tcl.h" ] || [ -f "/usr/include/tcl9/tcl.h" ]; then
                    echo -e "${GREEN}✓ tcl 依赖已安装${NC}"
                else
                    echo -e "${YELLOW}✗ tcl 依赖缺失${NC}"
                    install_package "tcl-devel" "tcl-dev" "tcl"
                fi
                ;;
            "uuid")
                # 检查UUID库（多种可能的实现）
                local uuid_found=false
                local uuid_type=""

                # 检查各种UUID实现
                if pkg-config --exists ossp-uuid 2>/dev/null || [ -f "/usr/include/ossp/uuid.h" ]; then
                    uuid_found=true
                    uuid_type="ossp-uuid"
                elif pkg-config --exists uuid 2>/dev/null || [ -f "/usr/include/uuid/uuid.h" ]; then
                    uuid_found=true
                    uuid_type="e2fsprogs"
                elif [ -f "/usr/include/uuid.h" ]; then
                    uuid_found=true
                    uuid_type="system"
                fi

                if $uuid_found; then
                    echo -e "${GREEN}✓ uuid 依赖已安装 ($uuid_type)${NC}"
                else
                    echo -e "${YELLOW}✗ uuid 依赖缺失${NC}"
                    echo ""
                    # 调用专门的UUID库安装函数
                    if ! install_uuid_library "auto"; then
                        echo ""
                        echo -e "${RED}✗ UUID 依赖安装失败${NC}"
                        echo -e "${YELLOW}请手动安装 UUID 库后重试${NC}"
                        return 1
                    fi
                fi
                ;;
            "xml")
                if pkg-config --exists libxml-2.0 2>/dev/null || [ -f "/usr/include/libxml2/libxml/parser.h" ]; then
                    echo -e "${GREEN}✓ xml 依赖已安装${NC}"
                else
                    echo -e "${YELLOW}✗ xml 依赖缺失${NC}"
                    install_package "libxml2-devel" "libxml2-dev" "libxml2"
                fi
                ;;
            "icu")
                # 用真实编译+链接测试判断（仅有头文件不算可用，避免 CentOS 7 误报）
                if icu_link_test; then
                    echo -e "${GREEN}✓ icu 依赖已安装（编译+链接测试通过）${NC}"
                else
                    echo -e "${YELLOW}✗ icu 依赖缺失或不可链接（可能仅有头文件、缺少 libicuuc.so 开发软链）${NC}"
                    install_package "libicu-devel" "libicu-dev" "icu"
                    icu_link_test
                fi
                ;;
            "ldap")
                if pkg-config --exists ldap 2>/dev/null || [ -f "/usr/include/ldap.h" ]; then
                    echo -e "${GREEN}✓ ldap 依赖已安装${NC}"
                else
                    echo -e "${YELLOW}✗ ldap 依赖缺失${NC}"
                    install_package "openldap-devel" "libldap2-dev" "ldap"
                fi
                ;;
            "pam")
                if [ -f "/usr/include/security/pam_appl.h" ]; then
                    echo -e "${GREEN}✓ pam 依赖已安装${NC}"
                else
                    echo -e "${YELLOW}✗ pam 依赖缺失${NC}"
                    install_package "pam-devel" "libpam-dev" "pam"
                fi
                ;;
            "bonjour")
                if pkg-config --exists avahi-client 2>/dev/null || [ -f "/usr/include/avahi-client/client.h" ]; then
                    echo -e "${GREEN}✓ bonjour 依赖已安装${NC}"
                else
                    echo -e "${YELLOW}✗ bonjour 依赖缺失${NC}"
                    install_package "avahi-devel" "libavahi-client-dev" "avahi"
                fi
                ;;
            "systemd")
                if pkg-config --exists libsystemd 2>/dev/null || [ -f "/usr/include/systemd/sd-daemon.h" ]; then
                    echo -e "${GREEN}✓ systemd 依赖已安装${NC}"
                else
                    echo -e "${YELLOW}✗ systemd 依赖缺失${NC}"
                    install_package "systemd-devel" "libsystemd-dev" "systemd"
                fi
                ;;
            "pgvector")
                # pgvector 是独立第三方扩展，无 ./configure 依赖，编译时仅需 gcc/make 与 pg_config
                echo -e "${GREEN}✓ pgvector 为独立扩展，将使用 pg_config 单独编译安装${NC}"
                ;;
            *)
                echo -e "${YELLOW}⚠ 未知插件 '$plugin'，跳过依赖检查${NC}"
                ;;
        esac
        echo ""
    done

    echo -e "${GREEN}依赖检查完成!${NC}"
    return 0
}

# 安装单个包或多个包（逐个尝试）
install_package() {
    local yum_package="$1"
    local apt_package="$2"
    local display_name="$3"
    local show_prompt="${4:-true}"

    if [ "$show_prompt" = "true" ]; then
        read -p "是否安装 $display_name 依赖? [y/N]: " install_choice
        if [[ ! $install_choice =~ ^[Yy]$ ]]; then
            echo -e "${YELLOW}跳过安装${NC}"
            return 1
        fi
    fi

    echo -e "${CYAN}正在安装 $display_name 依赖...${NC}"

    if command -v dnf &>/dev/null; then
        # 使用 dnf (Fedora/RHEL 8+)
        dnf install -y $yum_package 2>/dev/null
        local result=$?
    elif command -v yum &>/dev/null; then
        # 使用 yum (CentOS/RHEL 7及以下)
        yum install -y $yum_package 2>/dev/null
        local result=$?
    elif command -v apt-get &>/dev/null; then
        # 使用 apt-get (Debian/Ubuntu)
        apt-get update -qq && apt-get install -y $apt_package 2>/dev/null
        local result=$?
    else
        echo -e "${RED}无法检测包管理器，请手动安装${NC}"
        return 1
    fi

    if [ $result -eq 0 ]; then
        echo -e "${GREEN}✓ $display_name 依赖安装成功${NC}"
        return 0
    else
        echo -e "${RED}✗ $display_name 依赖安装失败${NC}"
        echo -e "${CYAN}请手动执行: yum install $yum_package 或 apt-get install $apt_package${NC}"
        return 1
    fi
}

# 安装UUID库（支持多种实现）
install_uuid_library() {
    local uuid_mode="${1:-auto}"  # auto, e2fs, ossp

    echo -e "${YELLOW}检测和安装UUID库...${NC}"
    echo ""

    # 检测已安装的UUID库
    local has_e2fs=false
    local has_ossp=false

    # 检查 e2fsprogs UUID
    if pkg-config --exists uuid 2>/dev/null; then
        has_e2fs=true
        echo -e "${GREEN}✓ 检测到 e2fsprogs UUID (pkg-config)${NC}"
    elif [ -f "/usr/include/uuid/uuid.h" ]; then
        has_e2fs=true
        echo -e "${GREEN}✓ 检测到 e2fsprogs UUID (头文件)${NC}"
    elif [ -f "/usr/include/uuid.h" ]; then
        has_e2fs=true
        echo -e "${GREEN}✓ 检测到系统 UUID (头文件)${NC}"
    fi

    # 检查 OSSP UUID
    if pkg-config --exists ossp-uuid 2>/dev/null; then
        has_ossp=true
        echo -e "${GREEN}✓ 检测到 OSSP UUID (pkg-config)${NC}"
    elif [ -f "/usr/include/ossp/uuid.h" ]; then
        has_ossp=true
        echo -e "${GREEN}✓ 检测到 OSSP UUID (头文件)${NC}"
    fi

    echo ""

    # 根据模式决定使用哪种UUID
    if [ "$uuid_mode" = "ossp" ]; then
        if $has_ossp; then
            echo -e "${GREEN}使用 OSSP UUID${NC}"
            UUID_LIBRARY="ossp"
            return 0
        else
            echo -e "${YELLOW}需要安装 OSSP UUID${NC}"
            return 1
        fi
    elif [ "$uuid_mode" = "e2fs" ]; then
        if $has_e2fs; then
            echo -e "${GREEN}使用 e2fsprogs UUID${NC}"
            UUID_LIBRARY="e2fs"
            return 0
        else
            echo -e "${YELLOW}需要安装 e2fsprogs UUID${NC}"
            return 1
        fi
    fi

    # 自动模式：优先使用 e2fsprogs，回退到 OSSP
    if $has_e2fs; then
        echo -e "${GREEN}使用 e2fsprogs UUID${NC}"
        UUID_LIBRARY="e2fs"
        return 0
    elif $has_ossp; then
        echo -e "${GREEN}使用 OSSP UUID${NC}"
        UUID_LIBRARY="ossp"
        return 0
    fi

    # 没有检测到UUID库，尝试安装
    echo -e "${YELLOW}未检测到UUID库，尝试安装...${NC}"
    echo ""

    # 检测系统类型
    if [ -f /etc/redhat-release ]; then
        # RedHat/CentOS/Fedora
        echo -e "${CYAN}检测到 RedHat 系统${NC}"

        # 尝试安装 e2fsprogs UUID
        echo -e "${YELLOW}尝试安装 uuid-devel...${NC}"
        if command -v dnf &>/dev/null; then
            dnf install -y uuid-devel 2>/dev/null
        elif command -v yum &>/dev/null; then
            yum install -y uuid-devel 2>/dev/null
        fi

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ uuid-devel 安装成功${NC}"
            UUID_LIBRARY="e2fs"
            return 0
        fi

        # 尝试从 EPEL 或其他源安装
        echo -e "${YELLOW}尝试安装 util-linux-devel...${NC}"
        if command -v dnf &>/dev/null; then
            dnf install -y util-linux-devel 2>/dev/null
        elif command -v yum &>/dev/null; then
            yum install -y util-linux-devel 2>/dev/null
        fi

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ util-linux-devel 安装成功${NC}"
            UUID_LIBRARY="e2fs"
            return 0
        fi

        echo -e "${RED}✗ UUID 库安装失败${NC}"
        echo -e "${CYAN}请尝试手动安装:${NC}"
        echo "  dnf install uuid-devel"
        echo "  或"
        echo "  yum install uuid-devel"
        echo ""
        echo -e "${CYAN}如果包不存在，可能需要启用 EPEL 或 PowerTools 仓库:${NC}"
        echo "  dnf install epel-release"
        echo "  dnf config-manager --set-enabled crb"
        echo "  dnf install uuid-devel"

    elif [ -f /etc/debian_version ]; then
        # Debian/Ubuntu
        echo -e "${CYAN}检测到 Debian/Ubuntu 系统${NC}"

        # 尝试安装 e2fsprogs UUID
        echo -e "${YELLOW}尝试安装 uuid-dev...${NC}"
        apt-get update -qq && apt-get install -y uuid-dev 2>/dev/null

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ uuid-dev 安装成功${NC}"
            UUID_LIBRARY="e2fs"
            return 0
        fi

        echo -e "${RED}✗ UUID 库安装失败${NC}"
        echo -e "${CYAN}请尝试手动安装:${NC}"
        echo "  apt-get install uuid-dev"
    else
        echo -e "${RED}无法识别系统类型${NC}"
        echo -e "${CYAN}请手动安装 UUID 开发库:${NC}"
        echo "  RedHat/CentOS: uuid-devel 或 util-linux-devel"
        echo "  Debian/Ubuntu: uuid-dev"
    fi

    return 1
}

# 安装外部插件
install_external_plugins() {
    echo -e "${YELLOW}外部插件安装向导${NC}"
    echo ""

    # 尝试多个可能的源码目录位置
    local source_dir=""
    local possible_dirs=(
        "$PG_INSTALL_DIR"  # 安装目录本身就是源码目录（未make install）
        "$PG_INSTALL_DIR/src"  # 源码在src子目录
        "$PG_INSTALL_DIR/../postgresql-${PG_VERSION}"  # 源码在上级目录
        "$PG_INSTALL_DIR/.."  # 源码在上级目录
    )

    # 检查哪个目录存在
    for dir in "${possible_dirs[@]}"; do
        if [ -d "$dir" ] && [ -f "$dir/configure" ]; then
            source_dir="$dir"
            echo -e "${GREEN}找到源码目录: $source_dir${NC}"
            break
        fi
    done

    # 如果没找到，询问用户
    if [ -z "$source_dir" ]; then
        echo -e "${YELLOW}未找到PostgreSQL源码目录${NC}"
        echo -e "${CYAN}请输入PostgreSQL源码目录路径:${NC}"
        read -p "例如: /mnt/data/pgsql/postgresql-18.1: " custom_source_dir
        if [ -z "$custom_source_dir" ]; then
            echo -e "${RED}错误: 未输入源码目录路径${NC}"
            return 1
        fi
        
        if [ ! -d "$custom_source_dir" ]; then
            echo -e "${RED}错误: 目录不存在: $custom_source_dir${NC}"
            return 1
        fi
        
        if [ ! -f "$custom_source_dir/configure" ]; then
            echo -e "${YELLOW}警告: 目录中没有找到configure文件，可能不是源码目录${NC}"
            read -p "是否继续? [y/N]: " continue_choice
            if [[ ! $continue_choice =~ ^[Yy]$ ]]; then
                return 1
            fi
        fi
        
        source_dir="$custom_source_dir"
    fi

    echo -e "${CYAN}可用的外部插件:${NC}"
    echo "----------------------------------------"
    echo "openssl - OpenSSL支持 (SSL/TLS连接)"
    echo "perl - Perl存储过程支持"
    echo "python - Python存储过程支持"
    echo "tcl - Tcl存储过程支持"
    echo "uuid - UUID支持 (ossp或e2fs)"
    echo "xml - XML支持"
    echo "icu - ICU支持"
    echo "ldap - LDAP认证支持"
    echo "pam - PAM认证支持"
    echo "bonjour - Bonjour支持"
    echo "systemd - systemd集成支持"
    echo "pgvector - pgvector向量扩展（独立扩展，用pg_config单独编译，无需重编PostgreSQL）"
    echo "----------------------------------------"
    echo ""

    echo -e "${YELLOW}请选择要安装的插件（多个用空格分隔）:${NC}"
    read -p "例如: openssl python uuid: " selected_plugins

    if [ -z "$selected_plugins" ]; then
        echo -e "${YELLOW}未选择任何插件，跳过安装${NC}"
        return 0
    fi

    echo ""
    echo -e "${CYAN}选择的插件: $selected_plugins${NC}"
    echo ""

    # pgvector 是独立第三方扩展，不走 ./configure，单独用 pg_config 编译安装
    local want_pgvector=false
    local recompile_plugins=""
    for plugin in $selected_plugins; do
        if [ "$plugin" = "pgvector" ]; then
            want_pgvector=true
        else
            recompile_plugins="$recompile_plugins $plugin"
        fi
    done
    recompile_plugins="$(echo "$recompile_plugins" | xargs)"

    # 检查插件依赖
    if ! check_plugin_dependencies "$selected_plugins"; then
        echo -e "${YELLOW}已取消插件安装${NC}"
        return 1
    fi

    echo ""

    # 仅选了 pgvector：无需重编 PostgreSQL，直接编译安装 pgvector
    if [ "$want_pgvector" = true ] && [ -z "$recompile_plugins" ]; then
        echo -e "${YELLOW}仅选择了 pgvector，PostgreSQL 无需重新配置/编译，直接安装 pgvector 扩展...${NC}"
        if install_pgvector; then
            enable_pgvector_extension
        else
            echo -e "${YELLOW}pgvector 安装未完成（PostgreSQL 主程序不受影响）${NC}"
            cd - > /dev/null 2>&1
            return 1
        fi
        rm -rf "/tmp/pgvector_build"
        echo -e "${GREEN}✓ 已清理 pgvector 临时构建目录 /tmp/pgvector_build${NC}"
        cd - > /dev/null 2>&1
        return 0
    fi

    # 生成configure选项（pgvector 不在此列，它单独编译）
    CONFIGURE_OPTIONS="--prefix=$PG_INSTALL_DIR"
    for plugin in $recompile_plugins; do
        case $plugin in
            "openssl")
                CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-openssl"
                ;;
            "perl")
                CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-perl"
                ;;
            "python")
                CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-python"
                ;;
            "tcl")
                CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-tcl"
                ;;
            "uuid")
                # 检测可用的UUID库
                local has_e2fs=false
                local has_ossp=false

                if pkg-config --exists uuid 2>/dev/null || [ -f "/usr/include/uuid/uuid.h" ] || [ -f "/usr/include/uuid.h" ]; then
                    has_e2fs=true
                fi
                if pkg-config --exists ossp-uuid 2>/dev/null || [ -f "/usr/include/ossp/uuid.h" ]; then
                    has_ossp=true
                fi

                echo -e "${YELLOW}请选择UUID实现方式:${NC}"

                # 根据可用库显示选项
                if $has_e2fs && ! $has_ossp; then
                    echo "1. e2fs (util-linux UUID库) [推荐，已安装]"
                    echo "2. ossp (OSSP UUID库) [未安装，需要手动安装]"
                    echo ""
                    echo -e "${GREEN}默认选择: e2fs${NC}"
                    CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-uuid=e2fs"
                    UUID_LIBRARY="e2fs"
                elif ! $has_e2fs && $has_ossp; then
                    echo "1. e2fs (util-linux UUID库) [未安装，需要手动安装]"
                    echo "2. ossp (OSSP UUID库) [已安装]"
                    echo ""
                    echo -e "${GREEN}默认选择: ossp${NC}"
                    CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-uuid=ossp"
                    UUID_LIBRARY="ossp"
                elif $has_e2fs && $has_ossp; then
                    echo "1. e2fs (util-linux UUID库) [已安装]"
                    echo "2. ossp (OSSP UUID库) [已安装]"
                    echo ""
                    read -p "请选择 [1/2，默认: 1]: " uuid_choice
                    case $uuid_choice in
                        "2")
                            CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-uuid=ossp"
                            UUID_LIBRARY="ossp"
                            ;;
                        *)
                            CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-uuid=e2fs"
                            UUID_LIBRARY="e2fs"
                            ;;
                    esac
                else
                    # 两者都没有，尝试安装
                    echo -e "${YELLOW}未检测到UUID库，尝试自动安装...${NC}"
                    if install_uuid_library "auto"; then
                        if [ "$UUID_LIBRARY" = "e2fs" ]; then
                            CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-uuid=e2fs"
                        else
                            CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-uuid=ossp"
                        fi
                    else
                        echo -e "${RED}UUID库安装失败，请手动安装后重试${NC}"
                        echo -e "${CYAN}CentOS/RHEL: yum install uuid-devel${NC}"
                        echo -e "${CYAN}Debian/Ubuntu: apt-get install uuid-dev${NC}"
                        return 1
                    fi
                fi
                ;;
            "xml")
                CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-libxml"
                ;;
            "icu")
                CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-icu"
                ;;
            "ldap")
                CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-ldap"
                ;;
            "pam")
                CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-pam"
                ;;
            "bonjour")
                CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-bonjour"
                ;;
            "systemd")
                CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-systemd"
                ;;
            *)
                echo -e "${YELLOW}注意: 插件 '$plugin' 将作为自定义参数处理${NC}"
                CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-$plugin"
                ;;
        esac
    done

    # PostgreSQL 16+ 默认开启 ICU，交由用户决定是否启用
    prompt_icu_support

    echo ""
    echo -e "${GREEN}将使用以下配置重新编译PostgreSQL:${NC}"
    echo "  $CONFIGURE_OPTIONS"
    echo ""
    read -p "是否继续? [y/N]: " confirm_compile

    if [[ ! $confirm_compile =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}已取消重新编译${NC}"
        return 0
    fi

    # 进入源码目录
    cd "$source_dir" || return 1

    # 清理之前的编译
    echo -e "${YELLOW}清理之前的编译文件...${NC}"
    make clean || true

    # 重新配置
    echo -e "${YELLOW}重新配置...${NC}"
    ./configure $CONFIGURE_OPTIONS

    if [ $? -ne 0 ]; then
        echo -e "${RED}配置失败${NC}"
        cd - > /dev/null
        return 1
    fi

    # 获取CPU核心数
    local cpu_cores=$(nproc 2>/dev/null || echo "1")
    local make_jobs=$cpu_cores
    local manual_cores=""
    
    # 显示可用核心数并询问用户
    echo -e "${CYAN}系统信息:${NC}"
    echo "  可用CPU核心数: $cpu_cores"
    read -p "请输入要使用的核心数 (1-$cpu_cores) [默认: $cpu_cores]: " manual_cores
    
    # 验证输入
    if [ -z "$manual_cores" ]; then
        # 用户未输入，使用默认
        make_jobs=$cpu_cores
        echo -e "${GREEN}使用默认核心数: $make_jobs${NC}"
    elif [[ "$manual_cores" =~ ^[0-9]+$ ]] && [ "$manual_cores" -ge 1 ] && [ "$manual_cores" -le $cpu_cores ]; then
        # 用户输入有效
        make_jobs=$manual_cores
        echo -e "${GREEN}使用指定核心数: $make_jobs${NC}"
    else
        # 用户输入无效
        echo -e "${RED}无效输入，使用默认核心数: $cpu_cores${NC}"
        make_jobs=$cpu_cores
    fi

    # 重新编译
    echo -e "${YELLOW}重新编译PostgreSQL (并行数: $make_jobs)...${NC}"
    make -j$make_jobs

    if [ $? -ne 0 ]; then
        echo -e "${RED}编译失败${NC}"
        cd - > /dev/null
        return 1
    fi

    # 重新安装
    echo -e "${YELLOW}重新安装PostgreSQL...${NC}"
    make install

    if [ $? -ne 0 ]; then
        echo -e "${RED}安装失败${NC}"
        cd - > /dev/null
        return 1
    fi

    # 编译并安装contrib模块（某些外部插件如uuid需要对应的contrib模块）
    if [ -d "contrib" ]; then
        echo -e "${YELLOW}检测到contrib目录，编译contrib模块...${NC}"
        cd contrib
        
        # 获取CPU核心数
        local contrib_cpu_cores=$(nproc 2>/dev/null || echo "1")
        local contrib_make_jobs=$contrib_cpu_cores
        
        # 编译所有contrib模块
        echo -e "${CYAN}编译contrib模块 (并行数: $contrib_make_jobs)...${NC}"
        make -j$contrib_make_jobs
        
        if [ $? -eq 0 ]; then
            # 安装contrib模块
            echo -e "${CYAN}安装contrib模块...${NC}"
            make install
            
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✓ contrib模块编译安装完成${NC}"
            else
                echo -e "${YELLOW}⚠ contrib模块安装失败，但PostgreSQL安装成功${NC}"
            fi
        else
            echo -e "${YELLOW}⚠ contrib模块编译失败，但PostgreSQL安装成功${NC}"
        fi
        
        cd "$source_dir" || cd - > /dev/null
    else
        echo -e "${YELLOW}⚠ 未找到contrib目录，跳过contrib模块编译${NC}"
    fi

    # 同时选择了 pgvector：PostgreSQL 重编译安装完成后，单独编译安装 pgvector
    if [ "$want_pgvector" = true ]; then
        if install_pgvector; then
            enable_pgvector_extension
        else
            echo -e "${YELLOW}pgvector 安装未完成，PostgreSQL 主程序不受影响${NC}"
        fi
    fi

    cd - > /dev/null

    echo -e "${GREEN}外部插件安装完成!${NC}"
    echo -e "${CYAN}提示: 可能需要重启PostgreSQL服务使插件生效${NC}"

    # 询问是否重启服务
    read -p "是否重启PostgreSQL服务? [y/N]: " restart_choice
    if [[ $restart_choice =~ ^[Yy]$ ]]; then
        # 查找所有PostgreSQL相关的服务
        echo -e "${CYAN}正在查找PostgreSQL服务...${NC}"
        local postgresql_services=$(systemctl list-units --all --type=service --no-legend | grep -i postgres | awk '{print $1}')
        
        if [ -z "$postgresql_services" ]; then
            echo -e "${YELLOW}未找到PostgreSQL服务，尝试查找常见服务名...${NC}"
            # 尝试常见的服务名
            local common_services=(
                "postgresql"
                "postgresql-18"
                "postgresql@18-main"
                "pgsql"
                "postgres"
            )
            
            local found_services=()
            for svc in "${common_services[@]}"; do
                if systemctl list-units --all --type=service --no-legend | grep -q "^${svc}.service"; then
                    found_services+=("$svc.service")
                fi
            done
            
            if [ ${#found_services[@]} -eq 0 ]; then
                echo -e "${RED}未找到PostgreSQL服务${NC}"
                echo -e "${YELLOW}请检查PostgreSQL是否使用systemd管理，或使用自定义服务名${NC}"
                read -p "请输入服务名 (例如: postgresql-18): " manual_service
                if [ -n "$manual_service" ]; then
                    echo -e "${CYAN}尝试重启服务: $manual_service${NC}"
                    systemctl restart "$manual_service"
                    if [ $? -eq 0 ]; then
                        echo -e "${GREEN}PostgreSQL服务已重启${NC}"
                    else
                        echo -e "${RED}重启服务失败，请手动重启${NC}"
                    fi
                fi
            elif [ ${#found_services[@]} -eq 1 ]; then
                # 只找到一个服务，直接重启
                local service_name="${found_services[0]}"
                echo -e "${GREEN}找到PostgreSQL服务: $service_name${NC}"
                systemctl restart "$service_name"
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}PostgreSQL服务已重启${NC}"
                else
                    echo -e "${RED}重启服务失败，请手动重启${NC}"
                fi
            else
                # 找到多个服务，让用户选择
                echo -e "${YELLOW}找到多个PostgreSQL服务:${NC}"
                local index=1
                for svc in "${found_services[@]}"; do
                    echo "  $index. $svc"
                    ((index++))
                done
                read -p "请选择要重启的服务编号 [1-${#found_services[@]}]: " service_choice
                if [[ "$service_choice" =~ ^[0-9]+$ ]] && [ "$service_choice" -ge 1 ] && [ "$service_choice" -le ${#found_services[@]} ]; then
                    local service_name="${found_services[$((service_choice-1))]}"
                    echo -e "${CYAN}正在重启服务: $service_name${NC}"
                    systemctl restart "$service_name"
                    if [ $? -eq 0 ]; then
                        echo -e "${GREEN}PostgreSQL服务已重启${NC}"
                    else
                        echo -e "${RED}重启服务失败，请手动重启${NC}"
                    fi
                else
                    echo -e "${RED}无效选择，跳过重启${NC}"
                fi
            fi
        else
            # 找到服务列表
            local service_array=($postgresql_services)
            if [ ${#service_array[@]} -eq 1 ]; then
                # 只有一个服务，直接重启
                local service_name="${service_array[0]}"
                echo -e "${GREEN}找到PostgreSQL服务: $service_name${NC}"
                systemctl restart "$service_name"
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}PostgreSQL服务已重启${NC}"
                else
                    echo -e "${RED}重启服务失败，请手动重启${NC}"
                fi
            else
                # 多个服务，让用户选择
                echo -e "${YELLOW}找到多个PostgreSQL服务:${NC}"
                local index=1
                for svc in "${service_array[@]}"; do
                    echo "  $index. $svc"
                    ((index++))
                done
                read -p "请选择要重启的服务编号 [1-${#service_array[@]}]: " service_choice
                if [[ "$service_choice" =~ ^[0-9]+$ ]] && [ "$service_choice" -ge 1 ] && [ "$service_choice" -le ${#service_array[@]} ]; then
                    local service_name="${service_array[$((service_choice-1))]}"
                    echo -e "${CYAN}正在重启服务: $service_name${NC}"
                    systemctl restart "$service_name"
                    if [ $? -eq 0 ]; then
                        echo -e "${GREEN}PostgreSQL服务已重启${NC}"
                    else
                        echo -e "${RED}重启服务失败，请手动重启${NC}"
                    fi
                else
                    echo -e "${RED}无效选择，跳过重启${NC}"
                fi
            fi
        fi
    fi

    # 清理 pgvector 编译构建临时目录（本向导不经过完整安装流程的 cleanup_temp_files）
    if [ "$want_pgvector" = true ] && [ -d "/tmp/pgvector_build" ]; then
        rm -rf "/tmp/pgvector_build"
        echo -e "${GREEN}✓ 已清理 pgvector 临时构建目录 /tmp/pgvector_build${NC}"
    fi

    # 提示如何使用安装的插件和扩展
    echo ""
    echo -e "${CYAN}=====================================${NC}"
    echo -e "${CYAN}外部插件和contrib模块安装完成!${NC}"
    echo -e "${CYAN}=====================================${NC}"
    echo ""
    echo -e "${YELLOW}安装的插件:${NC}"
    for plugin in $selected_plugins; do
        echo "  - $plugin"
    done
    echo ""
    echo -e "${CYAN}提示: contrib模块已编译安装，您可以使用以下命令在数据库中安装扩展:${NC}"
    echo "  psql -U postgres -d postgres -c \"CREATE EXTENSION extension_name;\""
    echo ""
    echo -e "${CYAN}常用扩展示例:${NC}"
    echo "  psql -U postgres -d postgres -c \"CREATE EXTENSION pg_trgm;\""
    echo "  psql -U postgres -d postgres -c \"CREATE EXTENSION pgcrypto;\""
    echo "  psql -U postgres -d postgres -c \"CREATE EXTENSION uuid-ossp;\""
    echo ""
    echo -e "${YELLOW}注意事项:${NC}"
    echo "  1. 某些插件需要额外的系统库支持"
    echo "  2. 如果扩展安装失败，请检查PostgreSQL日志"
    echo "  3. 使用 'SELECT * FROM pg_extension;' 查看已安装的扩展"
    echo ""

    return 0
}

# 安装内置扩展（新版本）
install_contrib_extensions_new() {
    echo -e "${YELLOW}内置扩展（contrib）安装向导${NC}"
    echo ""

    # 检查contrib目录
    local contrib_dir="$PG_INSTALL_DIR/contrib"
    if [ ! -d "$contrib_dir" ]; then
        echo -e "${RED}错误: contrib目录不存在: $contrib_dir${NC}"
        echo -e "${YELLOW}请确认PostgreSQL已正确编译安装${NC}"
        return 1
    fi

    # 扫描所有contrib模块
    echo -e "${YELLOW}扫描contrib目录...${NC}"
    local contrib_modules=""
    for module_dir in "$contrib_dir"/*/; do
        if [ -d "$module_dir" ]; then
            module=$(basename "$module_dir")
            # 检查是否有Makefile
            if [ -f "$module_dir/Makefile" ]; then
                if [ -z "$contrib_modules" ]; then
                    contrib_modules="$module"
                else
                    contrib_modules="$contrib_modules $module"
                fi
            fi
        fi
    done

    if [ -z "$contrib_modules" ]; then
        echo -e "${RED}错误: 未找到任何contrib模块${NC}"
        return 1
    fi

    echo -e "${GREEN}找到以下contrib模块:${NC}"
    echo "----------------------------------------"
    local module_num=0
    for module in $contrib_modules; do
        module_num=$((module_num + 1))
        printf "%3d. %s\n" "$module_num" "$module"
    done
    echo "----------------------------------------"
    echo ""

    echo -e "${YELLOW}请选择要安装的模块:${NC}"
    echo "1. 安装所有模块"
    echo "2. 选择特定模块（输入编号，多个用空格分隔）"
    echo "3. 输入模块名称（多个用空格分隔）"
    echo ""
    read -p "请选择 [1/2/3]: " module_choice

    local modules_to_compile=""

    case $module_choice in
        "1")
            modules_to_compile="$contrib_modules"
            echo -e "${GREEN}将安装所有contrib模块${NC}"
            ;;
        "2")
            read -p "请输入模块编号: " module_numbers
            for num in $module_numbers; do
                if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le $module_num ]; then
                    local module_name=$(echo "$contrib_modules" | awk -v n=$num '{print $n}')
                    if [ -z "$modules_to_compile" ]; then
                        modules_to_compile="$module_name"
                    else
                        modules_to_compile="$modules_to_compile $module_name"
                    fi
                fi
            done
            echo -e "${GREEN}将安装模块: $modules_to_compile${NC}"
            ;;
        "3")
            read -p "请输入模块名称: " module_names
            modules_to_compile="$module_names"
            echo -e "${GREEN}将安装模块: $modules_to_compile${NC}"
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            return 1
            ;;
    esac

    if [ -z "$modules_to_compile" ]; then
        echo -e "${RED}错误: 未选择任何模块${NC}"
        return 1
    fi

    # 获取CPU核心数
    local cpu_cores=$(nproc 2>/dev/null || echo "1")
    local make_jobs=$cpu_cores
    local manual_cores=""
    
    # 显示可用核心数并询问用户
    echo -e "${CYAN}系统信息:${NC}"
    echo "  可用CPU核心数: $cpu_cores"
    read -p "请输入要使用的核心数 (1-$cpu_cores) [默认: $cpu_cores]: " manual_cores
    
    # 验证输入
    if [ -z "$manual_cores" ]; then
        # 用户未输入，使用默认
        make_jobs=$cpu_cores
        echo -e "${GREEN}使用默认核心数: $make_jobs${NC}"
    elif [[ "$manual_cores" =~ ^[0-9]+$ ]] && [ "$manual_cores" -ge 1 ] && [ "$manual_cores" -le $cpu_cores ]; then
        # 用户输入有效
        make_jobs=$manual_cores
        echo -e "${GREEN}使用指定核心数: $make_jobs${NC}"
    else
        # 用户输入无效
        echo -e "${RED}无效输入，使用默认核心数: $cpu_cores${NC}"
        make_jobs=$cpu_cores
    fi

    echo ""
    echo -e "${YELLOW}开始编译contrib模块 (并行数: $make_jobs)...${NC}"

    # 进入contrib目录
    cd "$contrib_dir" || return 1

    # 编译并安装选定的模块
    local compile_failed=false
    for module in $modules_to_compile; do
        if [ -d "$module" ]; then
            echo -e "${CYAN}编译模块: $module${NC}"
            (
                cd "$module"
                make -j$make_jobs > /tmp/postgres_contrib_${module}_compile.log 2>&1
                if [ $? -eq 0 ]; then
                    make install >> /tmp/postgres_contrib_${module}_compile.log 2>&1
                    if [ $? -eq 0 ]; then
                        echo -e "${GREEN}✓ 模块 $module 编译安装成功${NC}"
                    else
                        echo -e "${RED}✗ 模块 $module 安装失败${NC}"
                        exit 1
                    fi
                else
                    echo -e "${RED}✗ 模块 $module 编译失败${NC}"
                    echo -e "${YELLOW}错误日志: /tmp/postgres_contrib_${module}_compile.log${NC}"
                    exit 1
                fi
            ) &
        fi
    done

    # 等待所有后台任务完成
    for pid in $(jobs -p); do
        wait $pid || compile_failed=true
    done

    cd - > /dev/null

    if [ "$compile_failed" = true ]; then
        echo -e "${RED}部分contrib模块编译失败${NC}"
        echo -e "${YELLOW}请检查日志文件: /tmp/postgres_contrib_*_compile.log${NC}"
    else
        echo -e "${GREEN}所有contrib模块编译安装完成!${NC}"
    fi

    # 提示如何安装扩展
    echo ""
    echo -e "${CYAN}提示: contrib模块已编译安装，您可以使用以下命令安装扩展:${NC}"
    echo "  psql -U postgres -d postgres -c \"CREATE EXTENSION extension_name;\""
    echo ""
    echo -e "${CYAN}常用扩展示例:${NC}"
    echo "  psql -U postgres -d postgres -c \"CREATE EXTENSION pg_trgm;\""
    echo "  psql -U postgres -d postgres -c \"CREATE EXTENSION pgcrypto;\""
    echo "  psql -U postgres -d postgres -c \"CREATE EXTENSION uuid-ossp;\""
    echo ""

    return 0
}

# 安装contrib模块
install_contrib_modules() {
    local contrib_dir="$PG_INSTALL_DIR/contrib"

    echo -e "${YELLOW}检查contrib模块...${NC}"

    # 如果已编译的contrib模块列表存在，使用它
    if [ -n "$COMPILED_CONTRIB_MODULES" ]; then
        echo -e "${GREEN}✓ contrib模块已在编译时安装${NC}"
        echo -e "${CYAN}已编译的模块: $COMPILED_CONTRIB_MODULES${NC}"
        return 0
    fi

    # 检查contrib目录是否存在
    if [ ! -d "$contrib_dir" ]; then
        echo -e "${YELLOW}contrib目录不存在，跳过contrib模块检查${NC}"
        return 0
    fi

    # 检查是否有contrib模块需要编译
    local modules_to_compile=""

    # 获取所有contrib模块
    for module_dir in "$contrib_dir"/*/; do
        # 移除末尾的斜杠
        module=$(basename "$module_dir")
        # 检查是否有Makefile
        if [ -f "$module_dir/Makefile" ]; then
            # 检查是否已安装
            if [ ! -f "$PG_INSTALL_DIR/share/extension/${module}.control" ]; then
                if [ -z "$modules_to_compile" ]; then
                    modules_to_compile="$module"
                else
                    modules_to_compile="$modules_to_compile $module"
                fi
            fi
        fi
    done

    if [ -z "$modules_to_compile" ]; then
        echo -e "${GREEN}✓ 所有contrib模块已安装${NC}"
        return 0
    fi

    echo -e "${YELLOW}发现未安装的contrib模块: $modules_to_compile${NC}"
    echo ""

    # 询问用户是否编译
    read -p "是否编译并安装这些contrib模块? [y/N]: " compile_choice
    if [[ ! $compile_choice =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}跳过contrib模块编译${NC}"
        return 0
    fi

    # 进入contrib目录
    cd "$contrib_dir" || return 1

    # 获取CPU核心数用于并行编译
    local cpu_cores=$(nproc 2>/dev/null || echo "1")
    local make_jobs=$cpu_cores
    local manual_cores=""
    
    # 显示可用核心数并询问用户
    echo -e "${CYAN}系统信息:${NC}"
    echo "  可用CPU核心数: $cpu_cores"
    read -p "请输入要使用的核心数 (1-$cpu_cores) [默认: $cpu_cores]: " manual_cores
    
    # 验证输入
    if [ -z "$manual_cores" ]; then
        # 用户未输入，使用默认
        make_jobs=$cpu_cores
        echo -e "${GREEN}使用默认核心数: $make_jobs${NC}"
    elif [[ "$manual_cores" =~ ^[0-9]+$ ]] && [ "$manual_cores" -ge 1 ] && [ "$manual_cores" -le $cpu_cores ]; then
        # 用户输入有效
        make_jobs=$manual_cores
        echo -e "${GREEN}使用指定核心数: $make_jobs${NC}"
    else
        # 用户输入无效
        echo -e "${RED}无效输入，使用默认核心数: $cpu_cores${NC}"
        make_jobs=$cpu_cores
    fi

    # 编译contrib模块
    echo -e "${YELLOW}开始编译contrib模块 (并行数: $make_jobs)...${NC}"
    make -j$make_jobs

    if [ $? -ne 0 ]; then
        echo -e "${RED}contrib模块编译失败${NC}"
        cd "$PG_INSTALL_DIR"
        return 1
    fi

    # 安装contrib模块
    echo -e "${YELLOW}安装contrib模块...${NC}"
    make install

    if [ $? -ne 0 ]; then
        echo -e "${RED}contrib模块安装失败${NC}"
        cd "$PG_INSTALL_DIR"
        return 1
    fi

    echo -e "${GREEN}✓ contrib模块编译安装完成${NC}"
    echo -e "${CYAN}已安装的模块: $modules_to_compile${NC}"
    echo ""

    # 返回PostgreSQL安装目录
    cd "$PG_INSTALL_DIR"

    # 保存已编译的模块列表
    export COMPILED_CONTRIB_MODULES="$modules_to_compile"

    return 0
}

# 安装 pgvector 向量扩展（独立第三方扩展，非 ./configure 插件）
# 说明：pgvector 不在 PostgreSQL 源码树内，需单独获取源码，
#       使用已安装的 pg_config 执行 make && make install。
install_pgvector() {
    echo ""
    echo -e "${YELLOW}========== 安装 pgvector 向量扩展 ==========${NC}"

    # 前置检查：需要已安装的 pg_config（PostgreSQL 必须先编译安装完成）
    if [ ! -x "$PG_INSTALL_DIR/bin/pg_config" ]; then
        echo -e "${RED}未找到 pg_config：$PG_INSTALL_DIR/bin/pg_config${NC}"
        echo -e "${YELLOW}pgvector 需在 PostgreSQL 主程序编译安装完成后再安装${NC}"
        return 1
    fi

    local pgvector_version="${PGVECTOR_VERSION:-0.8.6}"
    local work_dir="/tmp/pgvector_build"
    local src_dir=""
    local search_roots=("$SCRIPT_DIR" "/tmp" "$(dirname "$OFFLINE_TARBALL_PATH" 2>/dev/null)" "$PWD" "$work_dir")

    rm -rf "$work_dir"
    mkdir -p "$work_dir"

    # 步骤1：定位已解压的 pgvector 源码（源码根目录含 vector.control）
    local root hit
    for root in "${search_roots[@]}"; do
        [ -d "$root" ] || continue
        hit=$(find "$root" -maxdepth 3 -type f -name "vector.control" 2>/dev/null | head -n1)
        if [ -n "$hit" ]; then
            src_dir=$(dirname "$hit")
            echo -e "${GREEN}找到已解压的 pgvector 源码: $src_dir${NC}"
            break
        fi
    done

    # 步骤2：定位本地压缩包（pgvector-*.tar.gz 或 v*.tar.gz）并解压
    local archive=""
    if [ -z "$src_dir" ]; then
        for root in "${search_roots[@]}"; do
            [ -d "$root" ] || continue
            archive=$(find "$root" -maxdepth 2 -type f \( -name "pgvector-*.tar.gz" -o -name "v[0-9]*.tar.gz" \) 2>/dev/null | head -n1)
            if [ -n "$archive" ]; then
                echo -e "${GREEN}找到 pgvector 压缩包: $archive${NC}"
                break
            fi
        done

        if [ -n "$archive" ]; then
            if ! tar -zxf "$archive" -C "$work_dir"; then
                echo -e "${RED}解压失败: $archive${NC}"
                return 1
            fi
            hit=$(find "$work_dir" -maxdepth 2 -type f -name "vector.control" 2>/dev/null | head -n1)
            if [ -z "$hit" ]; then
                echo -e "${RED}压缩包中未找到 pgvector 源码（缺少 vector.control）${NC}"
                return 1
            fi
            src_dir=$(dirname "$hit")
        fi
    fi

    # 步骤3：仍无源码时，在线下载（离线模式直接提示并跳过）
    if [ -z "$src_dir" ]; then
        if [ "$OFFLINE_MODE" = "true" ]; then
            echo -e "${RED}离线模式下未找到 pgvector 源码包${NC}"
            echo -e "${YELLOW}请在联网机下载源码，并与 PostgreSQL tar 包放在同一目录后重试：${NC}"
            echo "  wget https://github.com/pgvector/pgvector/archive/refs/tags/v${pgvector_version}.tar.gz -O pgvector-${pgvector_version}.tar.gz"
            echo -e "${YELLOW}也可解压后把源码目录（含 Makefile 与 vector.control）放到 /tmp 或离线包同级目录${NC}"
            echo -e "${YELLOW}本次跳过 pgvector 安装，不影响 PostgreSQL 主程序${NC}"
            return 1
        fi

        local url="https://github.com/pgvector/pgvector/archive/refs/tags/v${pgvector_version}.tar.gz"
        echo -e "${CYAN}未找到本地源码，尝试在线下载 pgvector v${pgvector_version} ...${NC}"
        echo -e "${CYAN}下载地址: $url${NC}"
        local dl_ok=0
        if command -v wget &>/dev/null; then
            wget --timeout=300 --tries=2 -O "$work_dir/pgvector.tar.gz" "$url" && dl_ok=1
        elif command -v curl &>/dev/null; then
            curl -L --connect-timeout 30 --max-time 600 -f -o "$work_dir/pgvector.tar.gz" "$url" && dl_ok=1
        else
            echo -e "${RED}需要 wget 或 curl 以下载 pgvector${NC}"
        fi

        if [ "$dl_ok" != "1" ] || [ ! -s "$work_dir/pgvector.tar.gz" ]; then
            echo -e "${RED}pgvector 下载失败${NC}"
            echo -e "${YELLOW}可手动下载后放到 /tmp 或离线包同级目录：${NC}"
            echo "  $url"
            echo -e "${YELLOW}本次跳过 pgvector 安装，不影响 PostgreSQL 主程序${NC}"
            return 1
        fi

        if ! tar -zxf "$work_dir/pgvector.tar.gz" -C "$work_dir"; then
            echo -e "${RED}解压下载的 pgvector 失败${NC}"
            return 1
        fi
        hit=$(find "$work_dir" -maxdepth 2 -type f -name "vector.control" 2>/dev/null | head -n1)
        if [ -z "$hit" ]; then
            echo -e "${RED}下载内容中未找到 pgvector 源码${NC}"
            return 1
        fi
        src_dir=$(dirname "$hit")
    fi

    echo -e "${GREEN}使用 pgvector 源码目录: $src_dir${NC}"

    # 步骤4：编译并安装（显式指定 PostgreSQL 的 pg_config）
    cd "$src_dir" || return 1
    local pg_config="$PG_INSTALL_DIR/bin/pg_config"
    local jobs=$(nproc 2>/dev/null || echo "1")

    echo -e "${CYAN}执行: make PG_CONFIG=$pg_config -j$jobs${NC}"
    if ! make PG_CONFIG="$pg_config" -j"$jobs"; then
        echo -e "${RED}pgvector 编译失败${NC}"
        echo -e "${YELLOW}请确认已安装 gcc、make，且 PostgreSQL 开发文件可用（pg_config 正常）${NC}"
        return 1
    fi

    echo -e "${CYAN}执行: make install PG_CONFIG=$pg_config${NC}"
    if ! make install PG_CONFIG="$pg_config"; then
        echo -e "${RED}pgvector 安装失败（make install）${NC}"
        return 1
    fi

    echo -e "${GREEN}✓ pgvector 扩展文件已安装到 PostgreSQL 目录${NC}"
    echo -e "${YELLOW}数据库服务就绪后需执行 CREATE EXTENSION vector;（脚本稍后会自动尝试）${NC}"
    return 0
}

# 在 postgres 数据库中创建 pgvector 扩展（服务启动后调用）
enable_pgvector_extension() {
    echo ""
    echo -e "${YELLOW}在数据库中启用 pgvector 扩展（CREATE EXTENSION vector）...${NC}"

    local psql_bin="$PG_INSTALL_DIR/bin/psql"
    [ -x "$psql_bin" ] || psql_bin="psql"
    local pg_isready_bin="$PG_INSTALL_DIR/bin/pg_isready"
    [ -x "$pg_isready_bin" ] || pg_isready_bin="pg_isready"
    local sql="CREATE EXTENSION IF NOT EXISTS vector;"
    local ok=false

    # 以数据库属主用户本地连接执行
    _pgvector_run_sql() {
        if [ "$EUID" -eq 0 ]; then
            sudo -u "$PG_USER" "$psql_bin" -d postgres -c "$sql" 2>/dev/null && return 0
            su - "$PG_USER" -c "\"$psql_bin\" -d postgres -c \"$sql\"" 2>/dev/null && return 0
        fi
        "$psql_bin" -U "$PG_USER" -d postgres -c "$sql" 2>/dev/null && return 0
        return 1
    }

    # 先快速探测数据库是否在运行（未启动则不做无意义的重试等待）
    local server_up=false
    if [ -x "$PG_INSTALL_DIR/bin/pg_isready" ] || command -v pg_isready &>/dev/null; then
        "$pg_isready_bin" -q 2>/dev/null && server_up=true
    else
        # 无 pg_isready 时用一次连接尝试判断
        _pgvector_run_sql && { server_up=true; ok=true; }
    fi

    if [ "$server_up" != true ]; then
        echo -e "${YELLOW}检测到数据库服务未运行，跳过自动创建扩展。${NC}"
        echo -e "${GREEN}pgvector 扩展文件已安装完成（vector.so / vector.control），无需重新编译。${NC}"
        echo -e "${CYAN}待数据库启动后，在目标库执行一次即可注册扩展：${NC}"
        echo "  $psql_bin -U $PG_USER -d postgres -c \"CREATE EXTENSION vector;\""
        echo -e "${CYAN}其它业务库同理，连到对应库执行 CREATE EXTENSION vector;${NC}"
        return 0
    fi

    # 服务已运行，少量重试以等待就绪
    local i
    for i in 1 2 3; do
        if _pgvector_run_sql; then
            ok=true
            break
        fi
        echo -e "${YELLOW}等待数据库服务就绪... ($i/3)${NC}"
        sleep 2
    done

    if [ "$ok" = true ]; then
        echo -e "${GREEN}✓ 已在 postgres 数据库创建扩展 vector${NC}"
        echo -e "${CYAN}在其它业务库使用时，请在对应库执行: CREATE EXTENSION vector;${NC}"
    else
        echo -e "${YELLOW}⚠ 自动创建扩展未成功，可在服务启动后手动执行：${NC}"
        echo "  $psql_bin -U $PG_USER -d postgres -c \"CREATE EXTENSION vector;\""
    fi
}

# 验证安装
verify_installation() {
    echo -e "${YELLOW}验证安装...${NC}"
    
    # 检查服务状态
    if systemctl is-active --quiet postgresql${PG_VERSION%.*}; then
        echo -e "${GREEN}PostgreSQL服务正在运行${NC}"
    else
        echo -e "${RED}PostgreSQL服务未运行${NC}"
        return 1
    fi
    
    # 测试连接
    echo -e "${CYAN}测试PostgreSQL连接...${NC}"
    
    # 使用密码进行连接测试
    if [ -n "$PG_PASSWORD" ]; then
        # 设置PGPASSWORD环境变量进行连接测试
        export PGPASSWORD="$PG_PASSWORD"
        test_cmd="psql -U $PG_USER -h localhost -p $PG_PORT"
        
        if $test_cmd -c "SELECT version();" > /dev/null 2>&1; then
            echo -e "${GREEN}PostgreSQL连接测试成功（使用密码认证）${NC}"
            unset PGPASSWORD
        else
            echo -e "${RED}PostgreSQL连接测试失败${NC}"
            echo -e "${YELLOW}尝试的连接命令: PGPASSWORD=*** psql -U $PG_USER -h localhost -p $PG_PORT${NC}"
            unset PGPASSWORD
            return 1
        fi
    else
        # 如果没有设置密码，尝试使用信任认证
        if [ "$EUID" -eq 0 ]; then
            test_cmd="sudo -u $PG_USER psql"
        else
            test_cmd="psql -U $PG_USER"
        fi
        
        if $test_cmd -c "SELECT version();" > /dev/null 2>&1; then
            echo -e "${GREEN}PostgreSQL连接测试成功（使用信任认证）${NC}"
        else
            echo -e "${RED}PostgreSQL连接测试失败${NC}"
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
    if [ -n "$PG_VERSION" ]; then
        local tarball="/tmp/postgresql-${PG_VERSION}.tar.gz"
        if [ -f "$tarball" ]; then
            rm -f "$tarball"
            cleaned_files+=("$(basename "$tarball")")
            ((cleaned_count++))
        fi
    fi

    # 清理解压后的源码目录
    if [ -n "$PG_VERSION" ] && [ -d "/tmp/postgresql-${PG_VERSION}" ]; then
        rm -rf "/tmp/postgresql-${PG_VERSION}"
        cleaned_files+=("postgresql-${PG_VERSION}/")
        ((cleaned_count++))
    fi

    # 清理配置日志
    if [ -f "/tmp/postgres_configure.log" ]; then
        rm -f "/tmp/postgres_configure.log"
        cleaned_files+=("postgres_configure.log")
        ((cleaned_count++))
    fi

    # 清理contrib模块编译日志
    for log in /tmp/postgres_contrib_*_compile.log; do
        if [ -f "$log" ]; then
            rm -f "$log"
            cleaned_files+=("$(basename "$log")")
            ((cleaned_count++))
        fi
    done 2>/dev/null

    # 清理版本查询临时文件
    for html in /tmp/pg_versions_*.html /tmp/pg_verify_*.html; do
        if [ -f "$html" ]; then
            rm -f "$html"
            cleaned_files+=("$(basename "$html")")
            ((cleaned_count++))
        fi
    done 2>/dev/null

    # 清理ICU临时目录
    for icu_dir in /tmp/icu_pc_*; do
        if [ -d "$icu_dir" ]; then
            rm -rf "$icu_dir"
            cleaned_files+=("$(basename "$icu_dir")/")
            ((cleaned_count++))
        fi
    done 2>/dev/null

    # 清理 pgvector 编译构建目录（下载/解压的源码与临时压缩包）
    if [ -d "/tmp/pgvector_build" ]; then
        rm -rf "/tmp/pgvector_build"
        cleaned_files+=("pgvector_build/")
        ((cleaned_count++))
    fi

    # 清理临时密码设置脚本
    if [ -f "/tmp/set_postgres_password.sh" ]; then
        rm -f "/tmp/set_postgres_password.sh"
        cleaned_files+=("set_postgres_password.sh")
        ((cleaned_count++))
    fi

    # 清理PostgreSQL临时日志文件
    if [ -n "$PG_DATA_DIR" ] && [ -f "$PG_DATA_DIR/postgresql.log" ]; then
        # 保留日志文件但清空内容（或选择保留）
        # 这里选择保留，不做处理
        :
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
    local pg_version=""
    if [ -f "$PG_DATA_DIR/PG_VERSION" ]; then
        pg_version=$(cat "$PG_DATA_DIR/PG_VERSION")
    fi
    
    echo -e "${GREEN}=====================================${NC}"
    if [ -n "$pg_version" ]; then
        echo -e "${GREEN}PostgreSQL ${pg_version} 配置完成!${NC}"
    else
        echo -e "${GREEN}PostgreSQL 配置完成!${NC}"
    fi
    echo -e "${GREEN}=====================================${NC}"
    echo -e "安装目录: $PG_INSTALL_DIR"
    echo -e "数据目录: $PG_DATA_DIR"
    if [ -n "$PG_PORT" ]; then
        echo -e "端口号: $PG_PORT"
    fi
    echo -e "用户名: $PG_USER"
    if [ -n "$PG_PASSWORD" ]; then
        echo -e "密码: $PG_PASSWORD"
    fi
    echo -e ""
    echo -e "连接命令:"
    echo -e "psql -U $PG_USER -W"
    echo -e ""
    echo -e "若提示 psql 命令不存在（环境变量未生效），可使用完整路径:"
    echo -e "$PG_INSTALL_DIR/bin/psql -h 127.0.0.1 -p ${PG_PORT:-5432} -U $PG_USER -d postgres -W"
    echo -e ""
    echo -e "服务管理命令:"
    # 动态探测实际的 systemd 服务单元名（优先匹配本次安装路径对应的 postgresql*.service），
    # 避免用版本号猜（PG_VERSION 是 17.9 这类完整版本号，服务后缀只用主版本 17）。
    local service_name=""
    local svc
    if command -v systemctl &>/dev/null; then
        for svc in $(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^postgresql.*\.service$'); do
            if systemctl cat "$svc" 2>/dev/null | grep -qF "$PG_INSTALL_DIR"; then
                service_name="${svc%.service}"
                break
            fi
        done
        # 没按路径匹配上，则退而取任意 postgresql*.service 的第一个
        if [ -z "$service_name" ]; then
            svc=$(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^postgresql.*\.service$' | head -n1)
            [ -n "$svc" ] && service_name="${svc%.service}"
        fi
    fi
    # 仍未探测到时，用主版本号兜底（PG_VERSION 形如 17.9，取主版本 17）
    if [ -z "$service_name" ]; then
        local pg_major="${pg_version%%.*}"
        service_name="postgresql${pg_major}"
    fi
    echo -e "启动: systemctl start $service_name"
    echo -e "停止: systemctl stop $service_name"
    echo -e "重启: systemctl restart $service_name"
    echo -e "状态: systemctl status $service_name"
    echo -e ""
    echo -e "手动启动数据库:"
    echo -e "sudo -u $PG_USER $PG_INSTALL_DIR/bin/pg_ctl start -D $PG_DATA_DIR"
    echo -e ""
    
    # 添加PostgreSQL路径到/etc/profile
    echo -e "${YELLOW}配置系统环境变量...${NC}"
    
    # 检查/etc/profile是否已存在PostgreSQL配置
    if grep -q "PostgreSQL" /etc/profile 2>/dev/null; then
        echo -e "${YELLOW}检测到/etc/profile中已存在PostgreSQL配置${NC}"
        
        # 备份原有配置
        cp /etc/profile /etc/profile.backup
        echo -e "${GREEN}✓ 已备份/etc/profile到/etc/profile.backup${NC}"
        
        # 移除旧的PostgreSQL配置
        sed -i '/# PostgreSQL Environment/,/# End PostgreSQL Environment/d' /etc/profile
        echo -e "${GREEN}✓ 已移除旧的PostgreSQL环境配置${NC}"
    fi
    
    # 添加新的PostgreSQL环境配置到/etc/profile
    cat >> /etc/profile << 'EOF'

# PostgreSQL Environment
export PG_HOME=/mnt/data/postgresql
export PGDATA=/mnt/data/postgresql/data
export PATH=$PG_HOME/bin:$PATH
export MANPATH=$PG_HOME/share/man:$MANPATH
# End PostgreSQL Environment
EOF
    
    # 替换为实际的路径
    sed -i "s|export PG_HOME=.*|export PG_HOME=$PG_INSTALL_DIR|g" /etc/profile
    sed -i "s|export PGDATA=.*|export PGDATA=$PG_DATA_DIR|g" /etc/profile
    
    echo -e "${GREEN}✓ 已将PostgreSQL路径添加到/etc/profile${NC}"
    echo -e "${CYAN}添加的环境变量:${NC}"
    echo "  PG_HOME=$PG_INSTALL_DIR"
    echo "  PGDATA=$PG_DATA_DIR"
    echo "  PATH=\$PG_HOME/bin:\$PATH"
    echo "  MANPATH=\$PG_HOME/share/man:\$MANPATH"
    echo ""
    echo -e "${YELLOW}请执行以下命令使环境变量生效:${NC}"
    echo -e "${CYAN}source /etc/profile${NC}"
    echo -e "${YELLOW}或者重新登录系统${NC}"
    echo ""
    
    # 立即使当前会话的环境变量生效
    export PG_HOME="$PG_INSTALL_DIR"
    export PGDATA="$PG_DATA_DIR"
    export PATH="$PG_INSTALL_DIR/bin:$PATH"
    export MANPATH="$PG_INSTALL_DIR/share/man:$MANPATH"
    echo -e "${GREEN}✓ 当前会话环境变量已生效${NC}"

    echo -e "${GREEN}=====================================${NC}"

    # 清理临时文件
    cleanup_temp_files
}

# 离线安装主流程
offline_install_flow() {
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}PostgreSQL 离线安装模式${NC}"
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
    echo -e "${YELLOW}PostgreSQL 离线安装配置${NC}"
    echo "----------------------------------------"
    echo "  版本: $PG_VERSION"
    echo "  Tar包: $OFFLINE_TARBALL_PATH"
    echo "----------------------------------------"
    echo ""

    # 步骤3: 配置安装参数
    echo -e "${YELLOW}请配置PostgreSQL安装参数${NC}"
    echo ""

    # 使用默认配置或自定义配置
    read -p "是否使用默认配置? [y/N]: " use_default

    if [[ ! $use_default =~ ^[Yy]$ ]]; then
        # 自定义配置
        read -p "请输入用户名 [$DEFAULT_PG_USER]: " input_user
        PG_USER=${input_user:-$DEFAULT_PG_USER}
        
        read -p "请输入用户组 [$DEFAULT_PG_GROUP]: " input_group
        PG_GROUP=${input_group:-$DEFAULT_PG_GROUP}
        
        read -p "请输入安装目录 [$DEFAULT_PG_HOME]: " input_home
        PG_HOME=${input_home:-$DEFAULT_PG_HOME}
        
        read -p "请输入端口号 [$DEFAULT_PG_PORT]: " input_port
        PG_PORT=${input_port:-$DEFAULT_PG_PORT}
        
        read -s -p "请输入密码 [默认: postgres]: " input_password
        echo ""
        if [ -z "$input_password" ]; then
            PG_PASSWORD=$DEFAULT_PG_PASSWORD
        else
            PG_PASSWORD=$input_password
        fi
    else
        # 使用默认配置
        PG_USER=$DEFAULT_PG_USER
        PG_GROUP=$DEFAULT_PG_GROUP
        PG_HOME=$DEFAULT_PG_HOME
        PG_PORT=$DEFAULT_PG_PORT
        PG_PASSWORD=$DEFAULT_PG_PASSWORD
    fi

    # 计算派生路径
    PG_INSTALL_DIR="${PG_HOME}/postgresql-${PG_VERSION}"
    PG_DATA_DIR="${PG_HOME}/data"

    echo ""
    echo -e "${CYAN}最终配置:${NC}"
    echo "  PostgreSQL版本: $PG_VERSION"
    echo "  用户名: $PG_USER"
    echo "  用户组: $PG_GROUP"
    echo "  安装目录: $PG_INSTALL_DIR"
    echo "  数据目录: $PG_DATA_DIR"
    echo "  端口号: $PG_PORT"
    echo "  密码: $PG_PASSWORD"
    echo ""

    # 确认配置
    read -p "是否确认使用此配置? [y/N]: " confirm_config
    if [[ ! $confirm_config =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}返回主菜单...${NC}"
        main "$@"
        exit 0
    fi

    echo ""

    # 步骤4: 选择插件
    echo -e "${YELLOW}请选择需要编译安装的插件${NC}"
    echo "  注: 离线模式下，请确保已手动安装插件所需的依赖"
    echo ""

    # 重置UUID库选择
    UUID_LIBRARY=""
    # 重置选择的插件
    SELECTED_PLUGINS=""
    # 重置 pgvector 标志
    INSTALL_PGVECTOR=""
    PGVECTOR_INSTALLED=""

    # 定义可用插件
    declare -A plugins
    plugins[openssl]="OpenSSL支持 (SSL/TLS连接)"
    plugins[perl]="Perl存储过程支持"
    plugins[python]="Python存储过程支持"
    plugins[tcl]="Tcl存储过程支持"
    plugins[uuid]="UUID支持 (默认ossp，可选e2fs)"
    plugins[xml]="XML支持"
    plugins[icu]="ICU支持"
    plugins[ldap]="LDAP认证支持"
    plugins[pam]="PAM认证支持"
    plugins[bonjour]="Bonjour支持"
    plugins[systemd]="systemd集成支持"
    plugins[pgvector]="pgvector向量扩展 (独立第三方扩展，需在离线目录准备其源码包)"

    # 显示插件选项
    echo "可用插件列表:"
    echo "----------------------------------------"
    for key in "${!plugins[@]}"; do
        printf "%-12s - %s\n" "$key" "${plugins[$key]}"
    done
    echo "----------------------------------------"
    echo ""
    read -p "请输入需要安装的插件，多个用空格分隔（或直接回车跳过）: " selected_plugins

    # 基础配置选项
    CONFIGURE_OPTIONS="--without-readline --prefix=$PG_INSTALL_DIR --with-pgport=$PG_PORT --enable-thread-safety"

    # 处理插件
    if [ -n "$selected_plugins" ]; then
        echo -e "${GREEN}选择的插件: $selected_plugins${NC}"
        
        for plugin in $selected_plugins; do
            case $plugin in
                "openssl")
                    CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-openssl"
                    ;;
                "perl")
                    CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-perl"
                    ;;
                "python")
                    CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-python"
                    ;;
                "tcl")
                    CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-tcl"
                    ;;
                "uuid")
                    echo -e "${YELLOW}请选择UUID实现方式:${NC}"
                    echo "1. ossp (OSSP UUID库 - 功能完整但依赖较多)"
                    echo "2. e2fs (util-linux UUID库 - 轻量级标准实现)"
                    read -p "请选择 [1/2]: " uuid_choice
                    case $uuid_choice in
                        "2")
                            CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-uuid=e2fs"
                            UUID_LIBRARY="e2fs"
                            echo -e "${GREEN}使用e2fs UUID实现${NC}"
                            ;;
                        *)
                            CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-uuid=ossp"
                            UUID_LIBRARY="ossp"
                            echo -e "${GREEN}使用ossp UUID实现${NC}"
                            ;;
                    esac
                    ;;
                "xml")
                    CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-libxml"
                    ;;
                "icu")
                    CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-icu"
                    ;;
                "ldap")
                    CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-ldap"
                    ;;
                "pam")
                    CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-pam"
                    ;;
                "bonjour")
                    CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-bonjour"
                    ;;
                "systemd")
                    CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-systemd"
                    ;;
                "pgvector")
                    # pgvector 是独立第三方扩展，不属于 ./configure 参数，编译后单独安装
                    INSTALL_PGVECTOR="true"
                    echo -e "${GREEN}已选择 pgvector，将在 PostgreSQL 编译安装后单独编译该扩展${NC}"
                    ;;
                *)
                    echo -e "${YELLOW}注意: 插件 '$plugin' 不在预定义列表中，将作为自定义参数处理${NC}"
                    CONFIGURE_OPTIONS="$CONFIGURE_OPTIONS --with-$plugin"
                    ;;
            esac
        done
        
        # 存储选择的插件供后续使用
        SELECTED_PLUGINS="$selected_plugins"
    fi

    # PostgreSQL 16+ 默认开启 ICU，交由用户决定是否启用
    prompt_icu_support

    echo -e "${GREEN}最终编译配置选项: $CONFIGURE_OPTIONS${NC}"
    echo ""

    # 步骤5: 安装依赖（离线模式只显示依赖列表）
    install_dependencies
    
    # 步骤6: 安装插件依赖（离线模式只显示依赖列表）
    if [ -n "$SELECTED_PLUGINS" ]; then
        install_plugin_dependencies "$SELECTED_PLUGINS"
    fi

    # 步骤7: 创建用户和目录
    create_user_and_dirs

    # 步骤8: 解压离线tar包
    if ! extract_offline_tarbll; then
        echo -e "${RED}解压离线安装包失败${NC}"
        exit 1
    fi

    # 步骤9: 编译安装PostgreSQL
    echo -e "${YELLOW}开始编译安装PostgreSQL...${NC}"
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

    echo -e "${GREEN}执行命令: ./configure $CONFIGURE_OPTIONS${NC}"
    echo -e "${CYAN}编译命令: make -j$make_jobs && make install${NC}"
    echo ""

    cd $PG_INSTALL_DIR

    # 若该源码目录曾被 configure/编译过（如上次 --with-icu），先彻底清理，
    # 避免旧的目标文件（如引用 ICU 的 .o）与新配置混链导致 undefined reference
    if [ -f Makefile ]; then
        echo -e "${YELLOW}检测到旧的编译配置，执行 make distclean 清理残留产物...${NC}"
        make distclean >/dev/null 2>&1 || true
    fi

    ./configure $CONFIGURE_OPTIONS 2>&1 | tee /tmp/postgres_configure.log
        
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        echo -e "${RED}配置失败，错误日志已保存到 /tmp/postgres_configure.log${NC}"
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
    
    echo -e "${GREEN}PostgreSQL安装完成!${NC}"

    # 编译安装contrib模块
    if [ -d "contrib" ]; then
        echo -e "${YELLOW}编译安装contrib模块...${NC}"
        cd contrib
        
        # 编译所有contrib模块
        make -j$make_jobs
        
        if [ $? -eq 0 ]; then
            make install
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✓ contrib模块编译安装完成${NC}"
            else
                echo -e "${YELLOW}⚠ contrib模块安装失败，但PostgreSQL安装成功${NC}"
            fi
        else
            echo -e "${YELLOW}⚠ contrib模块编译失败，但PostgreSQL安装成功${NC}"
        fi
        
        cd $PG_INSTALL_DIR
    fi

    # 编译安装 pgvector 扩展（独立第三方扩展，需在主程序 make install 之后）
    if [ "$INSTALL_PGVECTOR" = "true" ]; then
        if install_pgvector; then
            PGVECTOR_INSTALLED="true"
        else
            echo -e "${YELLOW}pgvector 扩展安装未完成，PostgreSQL 主程序不受影响${NC}"
        fi
    fi

    # 步骤10: 设置环境变量
    setup_environment

    # 步骤11: 初始化数据库
    if ! init_database; then
        echo -e "${RED}数据库初始化失败${NC}"
        exit 1
    fi

    # 步骤12: 配置PostgreSQL
    configure_postgresql

    # 步骤13: 创建系统服务
    create_systemd_service

    # 步骤14: 设置密码
    set_password

    # 步骤15: 验证安装
    verify_installation

    # pgvector 扩展文件已安装时，在数据库中创建扩展
    if [ "$PGVECTOR_INSTALLED" = "true" ]; then
        enable_pgvector_extension
    fi

    # 步骤16: 显示安装信息
    show_installation_info

    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}PostgreSQL ${PG_VERSION} 离线安装完成!${NC}"
    echo -e "${GREEN}=====================================${NC}"
}

# 主函数
main() {
    echo -e "${GREEN}PostgreSQL 自动化安装脚本${NC}"
    echo -e "${GREEN}支持 x86 和 ARM 架构${NC}"
    echo ""

    echo -e "${YELLOW}请选择操作:${NC}"
    echo "1. 全新安装PostgreSQL（在线）"
    echo "2. 直接初始化数据库（需要PostgreSQL已编译安装）"
    echo "3. 安装内置扩展（contrib）"
    echo "4. 离线安装PostgreSQL（使用本地tar.gz包）"
    echo "m. 选择下载镜像源（当前: ${MIRROR_NAME:-官网镜像}）"
    echo "q. 退出"
    echo ""
    read -p "请选择 [1/2/3/4/m/q]: " main_choice

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
            if [ -z "$PG_MIRROR" ]; then
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
                        # 返回上级，重新选择版本，清空PG_VERSION变量
                        PG_VERSION=""
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
                PG_VERSION=""
                # 重新调用main函数，递归深度有限制但可以工作
                main "$@"
                exit 0
            fi
            ;;
        "2")
            # 直接初始化数据库
            echo -e "${YELLOW}直接初始化数据库模式${NC}"
            echo ""
            
            # 获取PostgreSQL安装路径
            echo -e "${YELLOW}请输入PostgreSQL安装路径:${NC}"
            read -p "例如 /mnt/data/pgsql/postgresql-18.1: " pg_install_path
            if [ -z "$pg_install_path" ]; then
                pg_install_path="/mnt/data/pgsql/postgresql-18.1"
            fi
            
            # 获取数据目录
            echo -e "${YELLOW}请输入数据目录路径:${NC}"
            read -p "例如 /mnt/data/pgsql/data: " pg_data_path
            if [ -z "$pg_data_path" ]; then
                pg_data_path="/mnt/data/pgsql/data"
            fi
            
            # 获取PostgreSQL用户
            echo -e "${YELLOW}请输入PostgreSQL用户名:${NC}"
            read -p "默认 [postgres]: " pg_user
            if [ -z "$pg_user" ]; then
                pg_user="postgres"
            fi
            
            # 设置变量
            PG_INSTALL_DIR="$pg_install_path"
            PG_DATA_DIR="$pg_data_path"
            PG_USER="$pg_user"
            PG_GROUP="$pg_user"
            
            # 检查安装路径是否存在
            if [ ! -d "$PG_INSTALL_DIR" ]; then
                echo -e "${RED}错误: PostgreSQL安装路径不存在: $PG_INSTALL_DIR${NC}"
                echo -e "${YELLOW}请确认PostgreSQL已正确编译安装${NC}"
                exit 1
            fi
            
            # 检查initdb是否存在
            if [ ! -f "$PG_INSTALL_DIR/bin/initdb" ]; then
                echo -e "${RED}错误: 找不到initdb命令${NC}"
                echo -e "${YELLOW}请确认PostgreSQL已正确编译安装${NC}"
                exit 1
            fi
            
            # 创建数据目录（如果不存在）
            if [ ! -d "$PG_DATA_DIR" ]; then
                mkdir -p "$PG_DATA_DIR"
                chown -R $PG_USER:$PG_GROUP "$PG_DATA_DIR"
                chmod 700 "$PG_DATA_DIR"
                echo -e "${GREEN}创建数据目录: $PG_DATA_DIR${NC}"
            fi
            
            # 直接调用初始化函数
            if init_database; then
                echo -e "${GREEN}数据库初始化成功!${NC}"
                # 询问是否继续配置
                read -p "是否继续配置PostgreSQL服务? [y/N]: " continue_config
                if [[ $continue_config =~ ^[Yy]$ ]]; then
                    # 设置环境变量
                    export PGHOME=$PG_INSTALL_DIR
                    export PGDATA=$PG_DATA_DIR
                    export PATH=$PGHOME/bin:$PATH
                    export LANG=en_US.utf8
                    
                    configure_postgresql
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
        "3")
            # 插件和扩展管理
            echo -e "${YELLOW}插件和扩展管理${NC}"
            echo ""

            # 获取PostgreSQL安装路径
            echo -e "${YELLOW}请输入PostgreSQL安装路径:${NC}"
            read -p "例如 /mnt/data/pgsql/postgresql-18.1: " pg_install_path
            if [ -z "$pg_install_path" ]; then
                echo -e "${RED}错误: 请输入PostgreSQL安装路径${NC}"
                exit 1
            fi

            # 设置变量
            PG_INSTALL_DIR="$pg_install_path"

            # 检查PostgreSQL是否已安装
            if [ ! -f "$PG_INSTALL_DIR/bin/psql" ]; then
                echo -e "${RED}错误: PostgreSQL未正确安装在指定路径${NC}"
                exit 1
            fi

            # 显示子菜单
            echo ""
            echo -e "${CYAN}请选择操作:${NC}"
            echo "1. 安装外部插件（需要重新编译，如openssl, python等）"
            echo "2. 安装内置扩展（contrib扩展，如pg_trgm, pgcrypto等）"
            echo "3. 同时安装外部插件和内置扩展"
            echo "b. 返回主菜单"
            echo ""
            read -p "请选择 [1/2/3/b]: " plugin_choice

            case $plugin_choice in
                "b"|"B")
                    echo -e "${YELLOW}返回主菜单...${NC}"
                    main "$@"
                    exit 0
                    ;;
                "1")
                    # 安装外部插件
                    install_external_plugins
                    ;;
                "2")
                    # 安装内置扩展
                    install_contrib_extensions_new
                    ;;
                "3")
                    # 同时安装
                    install_external_plugins
                    install_contrib_extensions_new
                    ;;
                *)
                    echo -e "${RED}无效选择${NC}"
                    exit 1
                    ;;
            esac

            exit 0
            ;;
        "q"|"Q")
            echo -e "${GREEN}退出安装${NC}"
            exit 0
            ;;
        "4")
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
    # 只有当PG_VERSION不为空时才执行主程序循环（说明用户已完成配置）
    if [ -z "$PG_VERSION" ]; then
        return
    fi

    while true; do
        # 版本选择和配置循环（用于重新安装时）
        while [ -z "$PG_VERSION" ]; do
            select_version
            local version_result=$?

            if [ $version_result -eq 0 ]; then
                confirm_configuration
                local config_result=$?

                if [ $config_result -eq 0 ]; then
                    break  # 配置成功，继续安装
                elif [ $config_result -eq 1 ]; then
                    # 返回上级，重新选择版本，清空PG_VERSION变量
                    PG_VERSION=""
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

            # 插件选择循环，直到用户确认

            while true; do

                select_plugins

                local select_result=$?

                if [ $select_result -eq 0 ]; then

                    break  # 插件选择成功

                elif [ $select_result -eq 2 ]; then

                    # 返回值为2表示需要返回版本选择

                    echo -e "${YELLOW}返回版本选择...${NC}"

                    break 2  # 退出主安装循环，返回版本选择

                else

                    # 返回值为1或其他，表示需要重新配置

                    echo -e "${YELLOW}重新配置安装参数...${NC}"

                    confirm_configuration

                    local config_result=$?

                    if [ $config_result -eq 0 ]; then

                        # 配置成功，继续插件选择

                        continue

                    elif [ $config_result -eq 1 ]; then

                        # 返回上级，返回版本选择，清空PG_VERSION变量
                        PG_VERSION=""
                        break 2  # 退出主安装循环，返回版本选择

                    fi

                fi

            done

            # 如果插件选择返回了，继续版本选择循环
            if [ $select_result -eq 2 ]; then
                continue  # 继续版本选择循环
            fi

            echo -e "${GREEN}开始安装PostgreSQL ${PG_VERSION}...${NC}"
            
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
            
            # 检查和修复ICU依赖
            if ! fix_icu_dependencies; then
                # 如果ICU修复失败，返回插件选择
                echo -e "${YELLOW}重新选择插件...${NC}"
                continue
            fi
            
            # 检查UUID库
            if ! check_uuid_library; then
                echo -e "${RED}UUID库检查失败${NC}"
                echo -e "${YELLOW}请确保已安装正确的UUID库:${NC}"
                if [ "$UUID_LIBRARY" = "ossp" ]; then
                    echo "- CentOS/RHEL: yum install libossp-uuid-devel uuid-devel"
                    echo "- Ubuntu/Debian: apt-get install libossp-uuid-dev uuid-devel"
                else
                    echo "- CentOS/RHEL: yum install util-linux-devel libuuid-devel uuid-devel"
                    echo "- Ubuntu/Debian: apt-get install uuid-dev libuuid-dev uuid-devel"
                fi
                echo ""
                read -p "是否继续编译? [y/N]: " continue_compile
                if [[ ! $continue_compile =~ ^[Yy]$ ]]; then
                    echo -e "${YELLOW}返回插件选择...${NC}"
                    continue
                fi
            fi
            
            # 编译安装，如果失败则返回插件选择
            if ! compile_install; then
                echo -e "${YELLOW}编译失败，返回插件选择...${NC}"
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
            
            configure_postgresql
            create_systemd_service
            
            # 安装contrib模块
            install_contrib_modules
            
            set_password
            
            # 验证安装
            if ! verify_installation; then
                echo -e "${YELLOW}安装验证失败，重新开始安装流程...${NC}"
                continue
            fi

            # pgvector 扩展文件已安装时，在数据库中创建扩展
            if [ "$PGVECTOR_INSTALLED" = "true" ]; then
                enable_pgvector_extension
            fi

            show_installation_info

            echo -e "${GREEN}PostgreSQL ${PG_VERSION} 安装完成!${NC}"
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
                PG_VERSION=""
                PG_USER=""
                PG_GROUP=""
                PG_HOME=""
                PG_PORT=""
                PG_PASSWORD=""
                PG_INSTALL_DIR=""
                PG_DATA_DIR=""
                CONFIGURE_OPTIONS=""
                SELECTED_PLUGINS=""
                UUID_LIBRARY=""
                INSTALL_PGVECTOR=""
                PGVECTOR_INSTALLED=""
                continue  # 返回主程序循环开始
                ;;
            *)
                echo -e "${GREEN}退出安装程序${NC}"
                exit 0
                ;;
        esac
    done
}

# 执行主函数
main "$@"
