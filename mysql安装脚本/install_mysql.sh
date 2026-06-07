#!/bin/bash

# MySQL 自动化安装脚本（二进制包安装方式）
# 支持 x86_64 和 ARM64 架构
# 兼容 Ubuntu 22/24、Debian 12、CentOS Stream/Rocky/AlmaLinux 8/9；CentOS 7 需使用 glibc2.17 安装包

# 检查是否使用bash执行（解决Ubuntu/Debian兼容性问题）
if [ -z "$BASH_VERSION" ]; then
    echo "错误: 请使用bash执行此脚本，而不是sh"
    echo "正确用法: bash install_mysql.sh 或 ./install_mysql.sh"
    exit 1
fi

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 默认配置变量（MySQL 8.4 LTS: 标准支持到2029年，扩展支持到2032年，生产首选）
DEFAULT_MYSQL_VERSION="8.4.9"
DEFAULT_MYSQL_USER="mysql"
DEFAULT_MYSQL_GROUP="mysql"
DEFAULT_MYSQL_HOME="/mnt/data/mysql"
DEFAULT_MYSQL_PORT="3306"
DEFAULT_MYSQL_ROOT_PASSWORD="root"

# 代理配置
USE_PROXY=""
PROXY_HOST=""
PROXY_PORT=""
PROXY_USER=""
PROXY_PASS=""

# 离线安装模式
OFFLINE_MODE=""
OFFLINE_TARBALL_PATH=""

# 检测系统架构和glibc版本
detect_system() {
    ARCH=$(uname -m)
    if [[ $ARCH == "x86_64" ]]; then
        ARCH_TYPE="x86_64"
        echo -e "${GREEN}检测到 x86_64 架构${NC}"
    elif [[ $ARCH == "aarch64" ]]; then
        ARCH_TYPE="aarch64"
        echo -e "${GREEN}检测到 ARM64 架构${NC}"
    else
        echo -e "${RED}不支持的架构: $ARCH${NC}"
        exit 1
    fi

    # 检测系统glibc版本
    GLIBC_VERSION=$(ldd --version 2>/dev/null | head -1 | awk '{print $NF}')
    GLIBC_MAJOR=$(echo "$GLIBC_VERSION" | cut -d. -f1)
    GLIBC_MINOR=$(echo "$GLIBC_VERSION" | cut -d. -f2)
    GLIBC_NUM=$(( GLIBC_MAJOR * 100 + GLIBC_MINOR ))
    echo -e "${GREEN}检测到系统 glibc 版本: $GLIBC_VERSION${NC}"

    # MySQL官方二进制包glibc版本选择（依赖MySQL版本，在select_version后调用）：
    # x86_64 部分版本提供 glibc2.17 包，可在 CentOS 7 运行，例如 MySQL 8.4.4
    # 新版本如 MySQL 8.4.9 通常使用 glibc2.28 包，不适合 CentOS 7
    # aarch64 通常使用 glibc2.28 包
    # 此处仅设置默认值，select_version 会根据实际版本更新
    GLIBC_PKG="2.17"
}

# 根据MySQL版本和系统架构更新glibc包版本和tarball文件名
update_tarball_name() {
    local major_minor="${MYSQL_VERSION%.*}"
    if [[ $ARCH_TYPE == "aarch64" ]]; then
        GLIBC_PKG="2.28"
    elif [[ "$MYSQL_VERSION" == "8.4.4" ]]; then
        GLIBC_PKG="2.17"
    elif [[ "$major_minor" == "8.4" ]] || [[ "${MYSQL_VERSION%%.*}" -ge 9 ]]; then
        GLIBC_PKG="2.28"
    else
        GLIBC_PKG="2.17"
    fi
    TARBALL_NAME="mysql-${MYSQL_VERSION}-linux-glibc${GLIBC_PKG}-${ARCH_TYPE}.tar.xz"
}

# 检查是否为root用户
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}此脚本需要以root权限运行${NC}"
   exit 1
fi

# 初始化系统检测
detect_system

# ======================== 安装前环境检测 ========================

parse_tarball_glibc_pkg() {
    local tarball_path="$1"
    local tarball_name=$(basename "$tarball_path")
    if [[ "$tarball_name" =~ glibc([0-9]+\.[0-9]+) ]]; then
        GLIBC_PKG="${BASH_REMATCH[1]}"
        TARBALL_NAME="$tarball_name"
    else
        update_tarball_name
    fi
}

resolve_compatible_mysql_package() {
    update_tarball_name

    if [[ "$OFFLINE_MODE" == "1" ]]; then
        return 0
    fi

    if [[ "$ARCH_TYPE" == "x86_64" && "$GLIBC_NUM" -lt 228 && "$GLIBC_PKG" == "2.28" ]]; then
        local major_minor="${MYSQL_VERSION%.*}"
        if [[ "$major_minor" == "8.4" ]]; then
            echo -e "${YELLOW}当前系统 glibc $GLIBC_VERSION 不支持 $MYSQL_VERSION 的 glibc2.28 包${NC}"
            echo -e "${YELLOW}已自动切换到 CentOS 7 可用的 MySQL 8.4.4 glibc2.17 x86_64 包${NC}"
            MYSQL_VERSION="8.4.4"
            GLIBC_PKG="2.17"
            TARBALL_NAME="mysql-${MYSQL_VERSION}-linux-glibc${GLIBC_PKG}-${ARCH_TYPE}.tar.xz"
            return 0
        fi
    fi

    return 0
}

show_version_advice() {
    echo -e "${CYAN}版本适配建议:${NC}"
    echo "  - CentOS 7: 在线安装会自动把 8.4 glibc2.28 包切换为 8.4.4 glibc2.17 包"
    echo "  - MySQL 8.4.9 LTS / 9.x: 通常需要 glibc >= 2.28，推荐 Ubuntu 22+/Debian 12/CentOS Stream 8+/Rocky 8+/AlmaLinux 8+"
    echo "  - MySQL 8.0 x86_64: 可使用 glibc2.17 包，适合 CentOS 7，但 8.0 已停止维护，不推荐新生产环境使用"
    echo "  - ARM64: 通常需要 glibc >= 2.28，不适合 CentOS 7 这类老系统"
}

pre_install_check() {
    echo -e "${YELLOW}执行安装前环境检测...${NC}"

    local os_name="未知系统"
    local os_id="unknown"
    local os_version="unknown"
    if [ -f /etc/os-release ]; then
        os_name=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d'=' -f2- | tr -d '"')
        os_id=$(grep '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
        os_version=$(grep '^VERSION_ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
    fi

    echo -e "${CYAN}系统: $os_name${NC}"
    echo -e "${CYAN}架构: $ARCH_TYPE${NC}"
    echo -e "${CYAN}glibc: $GLIBC_VERSION${NC}"
    resolve_compatible_mysql_package
    echo -e "${CYAN}MySQL版本: ${MYSQL_VERSION:-未知}${NC}"
    echo -e "${CYAN}安装包: ${TARBALL_NAME:-已安装版本}${NC}"

    local required_glibc_num=217
    local required_glibc_text="2.17"
    if [[ "$GLIBC_PKG" == "2.28" ]]; then
        required_glibc_num=228
        required_glibc_text="2.28"
    fi

    if [ "$GLIBC_NUM" -lt "$required_glibc_num" ]; then
        echo -e "${RED}环境不兼容: 当前 glibc $GLIBC_VERSION，小于所选安装包要求的 glibc $required_glibc_text${NC}"
        show_version_advice
        return 1
    fi
    echo -e "${GREEN}✓ glibc 版本满足要求${NC}"

    if ! command -v systemctl >/dev/null 2>&1; then
        echo -e "${RED}环境不兼容: 未检测到 systemctl，当前脚本依赖 systemd 管理 MySQL 服务${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ systemd 可用${NC}"

    if command -v apt-get >/dev/null 2>&1; then
        echo -e "${GREEN}✓ 包管理器: apt-get${NC}"
    elif command -v dnf >/dev/null 2>&1; then
        echo -e "${GREEN}✓ 包管理器: dnf${NC}"
    elif command -v yum >/dev/null 2>&1; then
        echo -e "${GREEN}✓ 包管理器: yum${NC}"
    else
        echo -e "${YELLOW}警告: 未检测到 apt-get/dnf/yum，请手动确认 libaio、numa、ncurses 兼容库已安装${NC}"
    fi

    if [[ "$os_id" =~ ^(centos|rhel|rocky|almalinux|ol|fedora)$ ]]; then
        if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
            echo -e "${YELLOW}警告: SELinux 当前为 Enforcing，非默认目录 $MYSQL_HOME 可能导致 MySQL 启动被拦截${NC}"
            echo -e "${YELLOW}建议测试时先执行: setenforce 0；生产环境请配置正确的 SELinux 上下文${NC}"
        fi

        local major_version="${os_version%%.*}"
        if [[ "$os_id" == "centos" && "$major_version" == "7" && "$GLIBC_PKG" == "2.28" ]]; then
            echo -e "${RED}CentOS 7 不支持当前 glibc2.28 安装包${NC}"
            show_version_advice
            return 1
        fi
        if [[ "$major_version" == "8" ]]; then
            echo -e "${YELLOW}提示: RHEL/CentOS/Rocky/Alma 8 如缺少 ncurses-compat-libs，可能需要启用 powertools/PowerTools 仓库${NC}"
        elif [[ "$major_version" == "9" ]]; then
            echo -e "${YELLOW}提示: RHEL/CentOS/Rocky/Alma 9 如缺少 ncurses-compat-libs，可能需要启用 crb 仓库${NC}"
        fi
    fi

    echo -e "${GREEN}安装前环境检测通过${NC}"
    echo ""
    return 0
}

# ======================== 版本选择 ========================

select_version() {
    while true; do
        echo -e "${YELLOW}请选择MySQL版本:${NC}"
        echo ""
        echo -e "  ${GREEN}--- LTS 长期支持版（推荐生产使用）---${NC}"
        echo "  1. MySQL 8.4.9 LTS [推荐] （最新，支持到2032年）"
        echo "  2. MySQL 8.4.5 LTS"
        echo "  3. MySQL 8.4.4 LTS"
        echo ""
        echo -e "  ${CYAN}--- 8.0 系列（2026年4月已停止维护）---${NC}"
        echo "  4. MySQL 8.0.39"
        echo "  5. MySQL 8.0.35"
        echo "  6. MySQL 8.0.36"
        echo ""
        echo "  7. 手动输入版本号"
        echo "  b. 返回上级菜单"
        echo "  q. 退出安装"
        echo ""

        read -p "请选择 [1-7/b/q]: " version_mode

        case $version_mode in
            "b"|"B")
                return 1
                ;;
            "q"|"Q")
                echo -e "${RED}安装已取消${NC}"
                exit 0
                ;;
            "1")
                MYSQL_VERSION="8.4.9"
                ;;
            "2")
                MYSQL_VERSION="8.4.5"
                ;;
            "3")
                MYSQL_VERSION="8.4.4"
                ;;
            "4")
                MYSQL_VERSION="8.0.39"
                ;;
            "5")
                MYSQL_VERSION="8.0.35"
                ;;
            "6")
                MYSQL_VERSION="8.0.36"
                ;;
            "7")
                read -p "请输入完整的MySQL版本号 (例如: 8.4.5): " custom_version
                if [[ "$custom_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    MYSQL_VERSION=$custom_version
                else
                    echo -e "${RED}版本号格式无效，请使用 x.y.z 格式${NC}"
                    continue
                fi
                ;;
            *)
                echo -e "${RED}无效选择，请重新输入${NC}"
                continue
                ;;
        esac

        # 根据系统环境和版本更新glibc包版本和tarball文件名
        resolve_compatible_mysql_package
        echo -e "${GREEN}已选择版本: $MYSQL_VERSION${NC}"
        echo -e "${GREEN}安装包: $TARBALL_NAME${NC}"
        echo ""
        return 0
    done
}

# ======================== 配置确认 ========================

confirm_configuration() {
    while true; do
        echo -e "${YELLOW}请确认MySQL安装配置:${NC}"
        resolve_compatible_mysql_package
        echo -e "  MySQL版本:     ${GREEN}$MYSQL_VERSION${NC}"
        echo -e "  安装包:        ${GREEN}$TARBALL_NAME${NC}"
        echo -e "  下载源:        ${GREEN}MySQL官网归档${NC}"
        echo -e "  安装目录:      ${GREEN}$MYSQL_HOME/mysql-${MYSQL_VERSION}${NC}"
        echo -e "  数据目录:      ${GREEN}$MYSQL_HOME/data${NC}"
        echo -e "  端口号:        ${GREEN}$DEFAULT_MYSQL_PORT${NC}"
        echo -e "  Root密码:      ${GREEN}$DEFAULT_MYSQL_ROOT_PASSWORD${NC}"
        echo ""

        echo "1. 使用默认配置"
        echo "2. 自定义配置"
        echo "3. 重新选择版本"
        echo "b. 返回上级菜单"
        echo "q. 退出安装"
        echo ""

        read -p "请选择 [1/2/3/b/q]: " config_choice

        case $config_choice in
            "b"|"B")
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
                MYSQL_ROOT_PASSWORD=$DEFAULT_MYSQL_ROOT_PASSWORD
                break
                ;;
            "2")
                read -p "请输入安装目录 [$DEFAULT_MYSQL_HOME]: " input_home
                MYSQL_HOME=${input_home:-$DEFAULT_MYSQL_HOME}

                read -p "请输入端口号 [$DEFAULT_MYSQL_PORT]: " input_port
                MYSQL_PORT=${input_port:-$DEFAULT_MYSQL_PORT}

                read -s -p "请输入Root密码 [默认: root]: " input_root_password
                echo ""
                MYSQL_ROOT_PASSWORD=${input_root_password:-$DEFAULT_MYSQL_ROOT_PASSWORD}

                MYSQL_USER=$DEFAULT_MYSQL_USER
                MYSQL_GROUP=$DEFAULT_MYSQL_GROUP
                break
                ;;
            "3")
                select_version
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
    MYSQL_LOG_DIR="${MYSQL_HOME}/log"

    echo ""
    echo -e "${GREEN}最终配置:${NC}"
    echo -e "  MySQL版本:  $MYSQL_VERSION"
    echo -e "  下载源:     MySQL官网归档"
    echo -e "  安装目录:   $MYSQL_INSTALL_DIR"
    echo -e "  数据目录:   $MYSQL_DATA_DIR"
    echo -e "  端口号:     $MYSQL_PORT"
    echo -e "  Root密码:   $MYSQL_ROOT_PASSWORD"
    echo ""

    while true; do
        echo "1. 确认开始安装"
        echo "2. 重新配置"
        echo "b. 返回上级菜单"
        echo "q. 退出安装"
        echo ""
        read -p "请选择 [1/2/b/q]: " final_choice

        case $final_choice in
            "1")
                echo -e "${GREEN}开始安装...${NC}"
                return 0
                ;;
            "2")
                confirm_configuration
                return $?
                ;;
            "b"|"B")
                return 1
                ;;
            "q"|"Q")
                echo -e "${RED}安装已取消${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选择，请重新输入${NC}"
                ;;
        esac
    done
}

# ======================== 代理配置 ========================

setup_proxy() {
    echo -e "${YELLOW}是否需要配置代理?${NC}"
    echo "1. 不使用代理"
    echo "2. 配置HTTP代理"
    echo "3. 配置SOCKS代理"
    echo ""
    read -p "请选择 [1-3]: " proxy_choice

    case $proxy_choice in
        "1")
            return 0
            ;;
        "2")
            read -p "请输入代理主机 (例如: 127.0.0.1): " PROXY_HOST
            read -p "请输入代理端口 (例如: 8080): " PROXY_PORT
            export http_proxy="http://${PROXY_HOST}:${PROXY_PORT}"
            export https_proxy="http://${PROXY_HOST}:${PROXY_PORT}"
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
    esac
    return 0
}

# ======================== 下载二进制包 ========================

download_binary() {
    echo -e "${YELLOW}下载MySQL ${MYSQL_VERSION} 二进制包...${NC}"

    cd /tmp

    # 优先使用当前版本下载地址，失败后回退到官网归档地址
    resolve_compatible_mysql_package
    local tarball="$TARBALL_NAME"
    local major_minor="${MYSQL_VERSION%.*}"
    local current_url="https://cdn.mysql.com/Downloads/MySQL-${major_minor}/${tarball}"
    local archive_url="https://downloads.mysql.com/archives/get/p/23/file/${tarball}"
    local download_url=""

    echo -e "${CYAN}下载地址:${NC}"
    echo "  1. $current_url"
    echo "  2. $archive_url"
    echo ""

    # 检查是否已有安装包；未下载完成的文件保留用于断点续传
    local tarball_file="/tmp/${TARBALL_NAME}"
    if [ -f "$tarball_file" ] && [ -s "$tarball_file" ]; then
        echo -e "${YELLOW}发现已有安装包，验证完整性...${NC}"
        if tar -tJf "$tarball_file" > /dev/null 2>&1; then
            echo -e "${GREEN}现有安装包完整，跳过下载${NC}"
            return 0
        else
            echo -e "${YELLOW}现有安装包未完整或校验失败，将尝试断点续传${NC}"
        fi
    fi

    # 最大重试次数
    local max_retries=3
    local urls=("$current_url" "$archive_url")

    for download_url in "${urls[@]}"; do
        echo -e "${CYAN}正在尝试: ${download_url}${NC}"
        local retry_count=0

        while [ $retry_count -lt $max_retries ]; do
            if [ $retry_count -gt 0 ]; then
                echo -e "${YELLOW}第 $retry_count 次重试...${NC}"
            fi

            if command -v wget &> /dev/null; then
                local wget_opts="-4 -c --timeout=60 --read-timeout=60 --tries=1 --progress=bar:force:noscroll"
                if [ -n "$http_proxy" ]; then
                    wget_opts="$wget_opts -e use_proxy=yes -e http_proxy=$http_proxy -e https_proxy=$https_proxy"
                fi
                wget $wget_opts "$download_url"
            elif command -v curl &> /dev/null; then
                local curl_opts="-4 -L -C - --connect-timeout 30 --max-time 0 --speed-limit 10240 --speed-time 60 --progress-bar"
                if [ -n "$http_proxy" ]; then
                    curl_opts="$curl_opts --proxy $http_proxy"
                fi
                curl $curl_opts -o "$tarball_file" "$download_url"
            else
                echo -e "${RED}需要安装wget或curl来下载MySQL${NC}"
                return 1
            fi

            local result=$?

            if [ $result -eq 0 ] && [ -f "$tarball_file" ] && [ -s "$tarball_file" ]; then
                if tar -tJf "$tarball_file" > /dev/null 2>&1; then
                    echo -e "${GREEN}✓ 下载成功${NC}"
                    return 0
                else
                    echo -e "${YELLOW}文件完整性验证失败，将继续尝试断点续传${NC}"
                fi
            else
                echo -e "${YELLOW}下载失败，将保留已下载部分用于断点续传${NC}"
            fi

            ((retry_count++))
        done
    done

    echo ""
    echo -e "${RED}下载失败！${NC}"
    echo -e "${YELLOW}请手动下载以下文件并放到 /tmp/${TARBALL_NAME}${NC}"
    echo ""
    echo -e "${CYAN}手动下载地址:${NC}"
    echo "  $current_url"
    echo "  $archive_url"
    echo ""
    echo -e "${CYAN}也可以在浏览器打开以下页面手动选择下载:${NC}"
    echo "  https://dev.mysql.com/downloads/mysql/"
    echo "  https://downloads.mysql.com/archives/community/"
    echo ""
    return 1
}

# ======================== 解压安装 ========================

extract_and_install() {
    echo -e "${YELLOW}解压MySQL二进制包...${NC}"

    local tarball_file="/tmp/${TARBALL_NAME}"
    local extract_dir="/tmp/mysql-${MYSQL_VERSION}-linux-glibc${GLIBC_PKG}-${ARCH_TYPE}"

    # 清理旧的解压目录
    if [ -d "$extract_dir" ]; then
        rm -rf "$extract_dir"
    fi

    # 解压
    tar -xJf "$tarball_file" -C /tmp
    if [ $? -ne 0 ]; then
        echo -e "${RED}解压失败${NC}"
        return 1
    fi

    # 检查解压结果
    if [ ! -d "$extract_dir" ]; then
        echo -e "${RED}解压后目录不存在${NC}"
        return 1
    fi

    # 移动到安装目录
    if [ -d "$MYSQL_INSTALL_DIR" ] && [ "$(ls -A $MYSQL_INSTALL_DIR 2>/dev/null)" ]; then
        echo -e "${YELLOW}目标目录已存在文件，覆盖安装...${NC}"
        rm -rf "$MYSQL_INSTALL_DIR"
    fi

    mkdir -p "$MYSQL_HOME"
    mv "$extract_dir" "$MYSQL_INSTALL_DIR"

    chown -R $MYSQL_USER:$MYSQL_GROUP "$MYSQL_INSTALL_DIR"
    chmod -R u+rwX,go+rX "$MYSQL_INSTALL_DIR"

    echo -e "${GREEN}解压安装完成${NC}"
    echo -e "${CYAN}安装目录: $MYSQL_INSTALL_DIR${NC}"

    # 清理下载的压缩包
    rm -f "$tarball_file"

    return 0
}

# ======================== 安装依赖 ========================

install_dependencies() {
    echo -e "${YELLOW}安装MySQL运行依赖...${NC}"

    if command -v dnf &> /dev/null; then
        dnf install -y libaio numactl-libs ncurses-compat-libs 2>/dev/null || \
            dnf install -y libaio numactl-libs ncurses-libs 2>/dev/null
    elif command -v yum &> /dev/null; then
        yum install -y libaio numactl-libs ncurses-compat-libs 2>/dev/null || \
            yum install -y libaio numactl-libs ncurses-libs 2>/dev/null
    elif command -v apt-get &> /dev/null; then
        apt-get update -qq
        apt-get install -y libaio1 libnuma1 libncurses5 2>/dev/null

        # Ubuntu 22+/24 可能已移除 libncurses5，尝试创建软链接
        if ! ldconfig -p | grep -q "libncurses.so.5"; then
            echo -e "${YELLOW}libncurses.so.5 未找到，创建软链接...${NC}"
            local ncurses6=$(find /usr/lib -name "libncurses.so.6*" 2>/dev/null | head -1)
            local tinfo6=$(find /usr/lib -name "libtinfo.so.6*" 2>/dev/null | head -1)
            if [ -n "$ncurses6" ]; then
                local ncurses_dir=$(dirname "$ncurses6")
                ln -sf "$ncurses6" "$ncurses_dir/libncurses.so.5"
                echo -e "${GREEN}  ✓ 已创建 libncurses.so.5 软链接${NC}"
            fi
            if [ -n "$tinfo6" ]; then
                local tinfo_dir=$(dirname "$tinfo6")
                ln -sf "$tinfo6" "$tinfo_dir/libtinfo.so.5"
                echo -e "${GREEN}  ✓ 已创建 libtinfo.so.5 软链接${NC}"
            fi
            ldconfig
        fi
    else
        echo -e "${YELLOW}未检测到包管理器，请确保已安装 libaio 和 libnuma${NC}"
    fi

    echo -e "${GREEN}依赖安装完成${NC}"
}

# ======================== 创建用户和目录 ========================

create_user_and_dirs() {
    echo -e "${YELLOW}创建MySQL用户和目录...${NC}"

    # 创建用户组
    if ! getent group $MYSQL_GROUP &>/dev/null; then
        groupadd $MYSQL_GROUP
    fi

    # 创建用户
    if ! id -u $MYSQL_USER &>/dev/null; then
        useradd -r -g $MYSQL_GROUP -s /bin/false $MYSQL_USER
    fi

    # 创建目录
    mkdir -p $MYSQL_DATA_DIR $MYSQL_LOG_DIR

    # 授权
    chown -R $MYSQL_USER:$MYSQL_GROUP $MYSQL_HOME
    chmod -R 755 $MYSQL_HOME

    # 检查数据目录
    if [ -d "$MYSQL_DATA_DIR" ] && [ "$(ls -A $MYSQL_DATA_DIR 2>/dev/null)" ]; then
        echo -e "${YELLOW}检测到数据目录已存在: $MYSQL_DATA_DIR${NC}"
        echo "1. 保留现有数据目录"
        echo "2. 备份后清空"
        echo "3. 直接清空"
        echo ""
        read -p "请选择 [1-3]: " data_choice

        case $data_choice in
            "1")
                echo -e "${GREEN}保留现有数据目录${NC}"
                ;;
            "2")
                backup_dir="${MYSQL_DATA_DIR}_backup_$(date +%Y%m%d_%H%M%S)"
                echo -e "${YELLOW}备份到: $backup_dir${NC}"
                cp -r $MYSQL_DATA_DIR $backup_dir
                rm -rf ${MYSQL_DATA_DIR}/*
                echo -e "${GREEN}已备份并清空${NC}"
                ;;
            "3")
                rm -rf ${MYSQL_DATA_DIR}/*
                echo -e "${GREEN}已清空${NC}"
                ;;
        esac
    fi
}

# ======================== 配置MySQL ========================

configure_mysql() {
    echo -e "${YELLOW}配置MySQL...${NC}"

    # 创建配置文件
    cat > /etc/my.cnf << EOF
[mysqld]
# 基础配置
user = $MYSQL_USER
basedir = $MYSQL_INSTALL_DIR
datadir = $MYSQL_DATA_DIR
port = $MYSQL_PORT
socket = $MYSQL_INSTALL_DIR/mysql.sock
pid-file = $MYSQL_INSTALL_DIR/mysql.pid
mysqlx_socket = $MYSQL_INSTALL_DIR/mysqlx.sock
mysqlx_port = $((MYSQL_PORT + 10000))

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
lower_case_table_names = 1
symbolic-links = 0
sql_mode = STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION

[client]
port = $MYSQL_PORT
socket = $MYSQL_INSTALL_DIR/mysql.sock
default-character-set = utf8mb4

[mysql]
default-character-set = utf8mb4
EOF

    echo -e "${GREEN}配置文件创建完成: /etc/my.cnf${NC}"
}

# ======================== 配置环境变量 ========================

setup_environment() {
    echo -e "${YELLOW}配置环境变量...${NC}"

    # 备份并清理旧配置
    if grep -q "# MySQL Environment" /etc/profile 2>/dev/null; then
        cp /etc/profile /etc/profile.backup.$(date +%Y%m%d_%H%M%S)
        sed -i '/# MySQL Environment/,/# End MySQL Environment/d' /etc/profile
    fi

    # 添加新配置
    cat >> /etc/profile << EOF

# MySQL Environment
export MYSQL_HOME=$MYSQL_INSTALL_DIR
export PATH=\$MYSQL_HOME/bin:\$PATH
# End MySQL Environment
EOF

    # 立即生效
    export MYSQL_HOME="$MYSQL_INSTALL_DIR"
    export PATH="$MYSQL_INSTALL_DIR/bin:$PATH"

    echo -e "${GREEN}环境变量配置完成${NC}"
    echo -e "${CYAN}  MYSQL_HOME=$MYSQL_INSTALL_DIR${NC}"
    echo -e "${CYAN}  PATH已包含: $MYSQL_INSTALL_DIR/bin${NC}"
}

# ======================== 初始化数据库 ========================

init_database() {
    echo -e "${YELLOW}初始化数据库...${NC}"

    # 检查是否已初始化
    if [ -f "$MYSQL_DATA_DIR/ibdata1" ]; then
        echo -e "${YELLOW}数据库已初始化，跳过${NC}"
        return 0
    fi

    # 安装libaio（必需依赖）
    if command -v dnf &> /dev/null; then
        dnf install -y libaio 2>/dev/null
    elif command -v yum &> /dev/null; then
        yum install -y libaio 2>/dev/null
    elif command -v apt-get &> /dev/null; then
        apt-get install -y libaio1 2>/dev/null
    fi

    # 执行初始化（--lower-case-table-names=1 设置表名不区分大小写）
    $MYSQL_INSTALL_DIR/bin/mysqld --initialize --user=$MYSQL_USER \
        --basedir=$MYSQL_INSTALL_DIR --datadir=$MYSQL_DATA_DIR \
        --lower-case-table-names=1 \
        2>&1 | tee /tmp/mysql_init.log

    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        echo -e "${GREEN}数据库初始化成功!${NC}"

        # 提取临时密码
        local temp_password=$(grep "A temporary password is generated" /tmp/mysql_init.log | awk '{print $NF}')
        if [ -n "$temp_password" ]; then
            MYSQL_TEMP_PASSWORD="$temp_password"
            echo -e "${CYAN}临时密码: $temp_password${NC}"
            echo -e "${YELLOW}请妥善保管此临时密码!${NC}"
        fi
        return 0
    else
        echo -e "${RED}数据库初始化失败!${NC}"
        echo -e "${YELLOW}请检查日志: /tmp/mysql_init.log${NC}"
        return 1
    fi
}

# ======================== 创建系统服务 ========================

create_systemd_service() {
    echo -e "${YELLOW}创建系统服务...${NC}"

    # 方式1: 使用support-files中的服务脚本（参考博客推荐方式）
    if [ -f "$MYSQL_INSTALL_DIR/support-files/mysql.server" ]; then
        cp $MYSQL_INSTALL_DIR/support-files/mysql.server /etc/init.d/mysql
        sed -i "s|^basedir=.*|basedir=$MYSQL_INSTALL_DIR|" /etc/init.d/mysql
        sed -i "s|^datadir=.*|datadir=$MYSQL_DATA_DIR|" /etc/init.d/mysql
        chmod +x /etc/init.d/mysql

        # 添加到系统服务
        if command -v chkconfig &> /dev/null; then
            chkconfig --add mysql
            chkconfig mysql on
        fi

        echo -e "${GREEN}✓ 已添加到系统服务 (/etc/init.d/mysql)${NC}"
    fi

    # 方式2: 同时创建systemd服务文件
    cat > /etc/systemd/system/mysql.service << EOF
[Unit]
Description=MySQL Server
After=network.target

[Service]
Type=forking
PIDFile=$MYSQL_INSTALL_DIR/mysql.pid
ExecStart=/etc/init.d/mysql start
ExecStop=/etc/init.d/mysql stop
ExecReload=/etc/init.d/mysql restart
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 /etc/systemd/system/mysql.service
    systemctl daemon-reload

    # 确保运行时文件目录有写权限，并清理异常退出残留文件
    chown -R $MYSQL_USER:$MYSQL_GROUP "$MYSQL_INSTALL_DIR"
    chmod u+rwx "$MYSQL_INSTALL_DIR"
    if [ -f "$MYSQL_INSTALL_DIR/mysql.pid" ] && ! pgrep -F "$MYSQL_INSTALL_DIR/mysql.pid" >/dev/null 2>&1; then
        rm -f "$MYSQL_INSTALL_DIR/mysql.pid"
    fi
    rm -f "$MYSQL_INSTALL_DIR/mysql.sock" "$MYSQL_INSTALL_DIR/mysql.sock.lock" \
        "$MYSQL_INSTALL_DIR/mysqlx.sock" "$MYSQL_INSTALL_DIR/mysqlx.sock.lock"

    # 启动服务
    if ! systemctl start mysql; then
        echo -e "${RED}MySQL服务启动失败${NC}"
        echo -e "${YELLOW}请查看日志: journalctl -u mysql -n 50 --no-pager${NC}"
        echo -e "${YELLOW}或查看错误日志: cat $MYSQL_LOG_DIR/error.log${NC}"
        return 1
    fi

    systemctl enable mysql

    # 等待服务启动
    sleep 3

    if systemctl is-active --quiet mysql; then
        echo -e "${GREEN}MySQL服务已启动并设置为开机自启${NC}"
    else
        echo -e "${RED}MySQL服务启动失败${NC}"
        echo -e "${YELLOW}请查看日志: journalctl -u mysql -n 50 --no-pager${NC}"
        echo -e "${YELLOW}或查看错误日志: cat $MYSQL_LOG_DIR/error.log${NC}"
        return 1
    fi

    # 创建mysql命令软链接（方便全局使用）
    if [ ! -f "/usr/bin/mysql" ]; then
        ln -s $MYSQL_INSTALL_DIR/bin/mysql /usr/bin/mysql
        echo -e "${GREEN}✓ 已创建mysql命令软链接: /usr/bin/mysql${NC}"
    fi
}

# ======================== 等待MySQL就绪 ========================

wait_for_mysql() {
    local max_wait=30
    local count=0
    echo -e "${YELLOW}等待MySQL服务就绪...${NC}"
    while [ $count -lt $max_wait ]; do
        if $MYSQL_INSTALL_DIR/bin/mysqladmin --socket="$MYSQL_INSTALL_DIR/mysql.sock" ping -u root --silent 2>/dev/null; then
            echo -e "${GREEN}MySQL已就绪${NC}"
            return 0
        fi
        # 用临时密码检测
        if [ -n "$MYSQL_TEMP_PASSWORD" ]; then
            if $MYSQL_INSTALL_DIR/bin/mysql -u root -p"$MYSQL_TEMP_PASSWORD" -e "SELECT 1;" > /dev/null 2>&1; then
                echo -e "${GREEN}MySQL已就绪${NC}"
                return 0
            fi
        fi
        sleep 2
        ((count++))
    done
    echo -e "${YELLOW}等待超时，继续尝试...${NC}"
    return 1
}

# ======================== 设置密码 ========================

set_password() {
    echo -e "${YELLOW}设置MySQL Root密码...${NC}"

    # 确保服务正在运行
    if ! service mysql status > /dev/null 2>&1 && ! systemctl is-active --quiet mysql; then
        service mysql start 2>/dev/null || systemctl start mysql
        sleep 5
    fi

    # 等待MySQL完全就绪
    wait_for_mysql

    local password_set=false

    # 方式1: 使用临时密码（重试3次）
    if [ -n "$MYSQL_TEMP_PASSWORD" ]; then
        echo -e "${CYAN}使用临时密码登录并修改密码...${NC}"
        echo -e "${CYAN}  临时密码: $MYSQL_TEMP_PASSWORD${NC}"
        local retry=0
        while [ $retry -lt 3 ]; do
            $MYSQL_INSTALL_DIR/bin/mysql -u root -p"$MYSQL_TEMP_PASSWORD" \
                --connect-expired-password \
                -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD'; FLUSH PRIVILEGES;" 2>&1
            if [ $? -eq 0 ]; then
                password_set=true
                echo -e "${GREEN}✓ 密码设置成功${NC}"
                break
            fi
            echo -e "${YELLOW}  重试中 ($((retry+1))/3)...${NC}"
            sleep 3
            ((retry++))
        done
    fi

    # 方式2: 临时密码在日志中（重新提取）
    if [ "$password_set" = false ]; then
        echo -e "${CYAN}重新从日志中提取临时密码...${NC}"
        local temp_pass=""
        # 从数据目录的错误日志提取
        local err_log=$(find "$MYSQL_DATA_DIR" -name "*.err" 2>/dev/null | head -1)
        if [ -n "$err_log" ]; then
            temp_pass=$(grep "A temporary password is generated" "$err_log" | awk '{print $NF}')
        fi
        # 从初始化日志提取
        if [ -z "$temp_pass" ] && [ -f /tmp/mysql_init.log ]; then
            temp_pass=$(grep "A temporary password is generated" /tmp/mysql_init.log | awk '{print $NF}')
        fi

        if [ -n "$temp_pass" ]; then
            echo -e "${CYAN}  找到临时密码: $temp_pass${NC}"
            MYSQL_TEMP_PASSWORD="$temp_pass"
            local retry=0
            while [ $retry -lt 3 ]; do
                $MYSQL_INSTALL_DIR/bin/mysql -u root -p"$temp_pass" \
                    --connect-expired-password \
                    -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD'; FLUSH PRIVILEGES;" 2>/dev/null
                if [ $? -eq 0 ]; then
                    password_set=true
                    echo -e "${GREEN}✓ 密码设置成功${NC}"
                    break
                fi
                sleep 3
                ((retry++))
            done
        fi
    fi

    # 方式3: skip-grant-tables 模式强制修改密码
    if [ "$password_set" = false ]; then
        echo -e "${YELLOW}自动修改密码失败，使用skip-grant-tables模式...${NC}"

        # 停止服务
        service mysql stop 2>/dev/null || systemctl stop mysql
        sleep 2

        # 以skip-grant-tables模式启动
        $MYSQL_INSTALL_DIR/bin/mysqld_safe --defaults-file=/etc/my.cnf --skip-grant-tables --skip-networking >"$MYSQL_LOG_DIR/mysql_skip_grant.log" 2>&1 &
        local safe_pid=$!

        local wait_count=0
        while [ $wait_count -lt 30 ]; do
            if $MYSQL_INSTALL_DIR/bin/mysqladmin --socket="$MYSQL_INSTALL_DIR/mysql.sock" -u root ping --silent 2>/dev/null; then
                break
            fi
            sleep 1
            ((wait_count++))
        done

        if [ $wait_count -lt 30 ]; then
            # 修改密码
            $MYSQL_INSTALL_DIR/bin/mysql --socket="$MYSQL_INSTALL_DIR/mysql.sock" -u root << EOSQL 2>/dev/null
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';
FLUSH PRIVILEGES;
EOSQL
            if [ $? -eq 0 ]; then
                password_set=true
                echo -e "${GREEN}✓ 密码设置成功${NC}"
            fi
        else
            echo -e "${YELLOW}skip-grant-tables 模式启动超时，跳过自动修改密码${NC}"
            echo -e "${YELLOW}请查看日志: $MYSQL_LOG_DIR/mysql_skip_grant.log 或 $MYSQL_LOG_DIR/error.log${NC}"
        fi

        # 停止安全模式的mysqld_safe
        $MYSQL_INSTALL_DIR/bin/mysqladmin --socket="$MYSQL_INSTALL_DIR/mysql.sock" -u root shutdown 2>/dev/null
        kill $safe_pid 2>/dev/null
        pkill -f "$MYSQL_INSTALL_DIR/bin/mysqld.*skip-grant-tables" 2>/dev/null
        sleep 2

        # 正常重启服务
        service mysql start 2>/dev/null || systemctl start mysql
        sleep 3
    fi

    # 方式4: 提示手动设置
    if [ "$password_set" = false ]; then
        echo ""
        echo -e "${RED}自动设置密码失败！请手动执行以下命令:${NC}"
        echo ""
        echo -e "${CYAN}--- 方法1: 使用临时密码 ---${NC}"
        echo "  $MYSQL_INSTALL_DIR/bin/mysql -u root -p'$MYSQL_TEMP_PASSWORD' --connect-expired-password"
        echo "  ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';"
        echo "  FLUSH PRIVILEGES;"
        echo "  EXIT;"
        echo ""
        echo -e "${CYAN}--- 方法2: 安全模式 ---${NC}"
        echo "  systemctl stop mysql"
        echo "  $MYSQL_INSTALL_DIR/bin/mysqld_safe --skip-grant-tables --skip-networking &"
        echo "  $MYSQL_INSTALL_DIR/bin/mysql -u root"
        echo "  FLUSH PRIVILEGES;"
        echo "  ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';"
        echo "  EXIT;"
        echo "  $MYSQL_INSTALL_DIR/bin/mysqladmin -u root -p'$MYSQL_ROOT_PASSWORD' shutdown"
        echo "  systemctl start mysql"
        echo ""
        read -p "设置完成后按回车继续... " -r
    fi

    # 配置远程访问
    echo -e "${YELLOW}配置远程访问...${NC}"
    $MYSQL_INSTALL_DIR/bin/mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "
        CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD';
        GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
        FLUSH PRIVILEGES;
    " 2>/dev/null

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ 远程访问配置成功${NC}"
    else
        echo -e "${YELLOW}远程访问配置可能需要手动执行:${NC}"
        echo "  $MYSQL_INSTALL_DIR/bin/mysql -u root -p'$MYSQL_ROOT_PASSWORD' -e \"CREATE USER 'root'@'%' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD'; GRANT ALL ON *.* TO 'root'@'%'; FLUSH PRIVILEGES;\""
    fi
}

# ======================== 配置防火墙 ========================

configure_firewall() {
    echo -e "${YELLOW}配置防火墙...${NC}"

    local port="$MYSQL_PORT"

    if command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then
        if ! firewall-cmd --query-port="${port}/tcp" &> /dev/null; then
            firewall-cmd --permanent --add-port="${port}/tcp"
            firewall-cmd --reload
            echo -e "${GREEN}✓ 防火墙已开放端口 ${port}${NC}"
        fi
    elif command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "${port}/tcp"
        echo -e "${GREEN}✓ 防火墙已开放端口 ${port}${NC}"
    fi
}

# ======================== 验证安装 ========================

verify_installation() {
    echo -e "${YELLOW}验证安装...${NC}"

    # 检查二进制文件
    if [ -f "$MYSQL_INSTALL_DIR/bin/mysql" ] && [ -f "$MYSQL_INSTALL_DIR/bin/mysqld" ]; then
        local version=$($MYSQL_INSTALL_DIR/bin/mysql --version 2>/dev/null)
        echo -e "${GREEN}✓ $version${NC}"
    else
        echo -e "${RED}✗ MySQL二进制文件不存在${NC}"
        return 1
    fi

    # 检查服务状态
    if systemctl is-active --quiet mysql; then
        echo -e "${GREEN}✓ MySQL服务正在运行${NC}"
    else
        echo -e "${RED}✗ MySQL服务未运行${NC}"
        return 1
    fi

    # 测试连接
    if $MYSQL_INSTALL_DIR/bin/mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "SELECT 1;" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ MySQL连接测试成功${NC}"
    else
        echo -e "${YELLOW}⚠ MySQL连接测试失败（可能需要手动设置密码）${NC}"
    fi

    return 0
}

# ======================== 显示安装信息 ========================

show_installation_info() {
    local mysql_version=""
    if [ -f "$MYSQL_INSTALL_DIR/bin/mysql" ]; then
        mysql_version=$($MYSQL_INSTALL_DIR/bin/mysql --version 2>/dev/null)
    fi

    # 自动执行 source /etc/profile 使环境变量在当前会话生效
    echo -e "${YELLOW}执行 source /etc/profile 使环境变量生效...${NC}"
    source /etc/profile > /dev/null 2>&1
    # 同时创建 mysql 命令软链接（确保可以直接使用 mysql 命令）
    if [ ! -f "/usr/bin/mysql" ]; then
        ln -sf $MYSQL_INSTALL_DIR/bin/mysql /usr/bin/mysql
    fi
    echo -e "${GREEN}✓ 环境变量已生效，当前会话可直接使用 mysql 命令${NC}"

    # 获取服务器IP
    local server_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [ -z "$server_ip" ]; then
        server_ip=$(ip addr show 2>/dev/null | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1 | head -1)
    fi

    echo ""
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}MySQL 安装完成!${NC}"
    echo -e "${GREEN}=====================================${NC}"
    if [ -n "$mysql_version" ]; then
        echo -e "$mysql_version"
    fi
    echo ""
    echo -e "  安装目录:   $MYSQL_INSTALL_DIR"
    echo -e "  数据目录:   $MYSQL_DATA_DIR"
    echo -e "  配置文件:   /etc/my.cnf"
    echo -e "  端口号:     $MYSQL_PORT"
    echo -e "  Root密码:   $MYSQL_ROOT_PASSWORD"
    echo ""
    echo -e "  连接命令:"
    echo -e "    mysql -u root -p"
    echo ""
    echo -e "  服务管理:"
    echo -e "    启动: systemctl start mysql"
    echo -e "    停止: systemctl stop mysql"
    echo -e "    重启: systemctl restart mysql"
    echo -e "    状态: systemctl status mysql"
    echo ""

    # Navicat 远程连接测试
    echo -e "${CYAN}======== Navicat 远程连接信息 ========${NC}"
    echo ""
    echo -e "  主机名/IP:  ${GREEN}${server_ip:-<服务器IP>}${NC}"
    echo -e "  端口:       ${GREEN}$MYSQL_PORT${NC}"
    echo -e "  用户名:     ${GREEN}root${NC}"
    echo -e "  密码:       ${GREEN}$MYSQL_ROOT_PASSWORD${NC}"
    echo ""

    # 测试远程连接是否可用
    echo -e "${YELLOW}测试远程连接配置...${NC}"

    # 检查端口监听
    if ss -tlnp 2>/dev/null | grep -q ":${MYSQL_PORT} " || netstat -tlnp 2>/dev/null | grep -q ":${MYSQL_PORT} "; then
        echo -e "${GREEN}  ✓ 端口 $MYSQL_PORT 正在监听${NC}"
    else
        echo -e "${YELLOW}  ⚠ 端口 $MYSQL_PORT 未监听，请检查MySQL服务状态${NC}"
    fi

    # 测试本地密码登录
    if $MYSQL_INSTALL_DIR/bin/mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "SELECT 1;" > /dev/null 2>&1; then
        echo -e "${GREEN}  ✓ 本地密码登录成功${NC}"
    else
        echo -e "${YELLOW}  ⚠ 本地密码登录失败，可能需要手动设置密码${NC}"
    fi

    # 测试远程用户是否配置成功
    local remote_check=$($MYSQL_INSTALL_DIR/bin/mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "SELECT user, host FROM mysql.user WHERE user='root' AND host='%';" 2>/dev/null)
    if echo "$remote_check" | grep -q "root.*%"; then
        echo -e "${GREEN}  ✓ 远程访问用户已配置 (root@%)${NC}"
    else
        echo -e "${YELLOW}  ⚠ 远程访问用户未配置，可能需要手动执行:${NC}"
        echo "    mysql -u root -p -e \"CREATE USER 'root'@'%' IDENTIFIED BY '密码';\""
        echo "    mysql -u root -p -e \"GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION; FLUSH PRIVILEGES;\""
    fi

    # 检查防火墙
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        if ufw status | grep -q "${MYSQL_PORT}/tcp.*ALLOW"; then
            echo -e "${GREEN}  ✓ 防火墙已放行端口 $MYSQL_PORT${NC}"
        else
            echo -e "${YELLOW}  ⚠ 防火墙未放行端口 $MYSQL_PORT，请执行:${NC}"
            echo "    ufw allow $MYSQL_PORT/tcp"
        fi
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        if firewall-cmd --query-port="${MYSQL_PORT}/tcp" &>/dev/null; then
            echo -e "${GREEN}  ✓ 防火墙已放行端口 $MYSQL_PORT${NC}"
        else
            echo -e "${YELLOW}  ⚠ 防火墙未放行端口 $MYSQL_PORT，请执行:${NC}"
            echo "    firewall-cmd --permanent --add-port=$MYSQL_PORT/tcp && firewall-cmd --reload"
        fi
    fi

    echo ""
    echo -e "${CYAN}Navicat 连接步骤:${NC}"
    echo -e "  1. 打开 Navicat"
    echo -e "  2. 新建连接 -> MySQL"
    echo -e "  3. 填入上面的主机、端口、用户名、密码"
    echo -e "  4. 点击 测试连接"
    echo -e "  5. 保存连接"
    echo ""
    echo -e "${GREEN}=====================================${NC}"
}

# ======================== 清理临时文件 ========================

cleanup_temp_files() {
    echo ""
    echo -e "${CYAN}清理临时文件...${NC}"
    rm -f /tmp/${TARBALL_NAME}
    rm -f /tmp/mysql_init.log
    rm -rf /tmp/mysql-${MYSQL_VERSION}-linux-glibc${GLIBC_PKG}-${ARCH_TYPE}
    echo -e "${GREEN}清理完成${NC}"
}

# ======================== 离线安装 ========================

find_offline_tarball() {
    echo -e "${YELLOW}查找MySQL离线安装包...${NC}"
    echo ""

    while true; do
        echo -e "${CYAN}请输入MySQL tar.xz包的路径或目录:${NC}"
        echo "  - 完整路径: /path/to/mysql-8.4.9-linux-glibc2.28-x86_64.tar.xz"
        echo "  - 目录路径: /path/to/ (自动查找)"
        echo "b. 返回主菜单"
        echo ""
        read -p "请输入路径: " input_path

        case "$input_path" in
            "b"|"B") return 1 ;;
            "") echo -e "${RED}路径不能为空${NC}"; continue ;;
        esac

        if [ ! -e "$input_path" ]; then
            echo -e "${RED}路径不存在: $input_path${NC}"
            continue
        fi

        if [ -f "$input_path" ]; then
            if [[ "$input_path" =~ \.tar\.xz$ ]]; then
                if tar -tJf "$input_path" > /dev/null 2>&1; then
                    OFFLINE_TARBALL_PATH="$input_path"
                    # 从文件名提取版本号
                    MYSQL_VERSION=$(basename "$input_path" | sed 's/mysql-//' | sed 's/-linux.*//')
                    parse_tarball_glibc_pkg "$input_path"
                    echo -e "${GREEN}找到安装包: $OFFLINE_TARBALL_PATH${NC}"
                    echo -e "${GREEN}版本: $MYSQL_VERSION${NC}"
                    read -p "是否使用此包? [y/N]: " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        return 0
                    fi
                else
                    echo -e "${RED}文件不是有效的MySQL安装包${NC}"
                fi
            else
                echo -e "${RED}文件必须是.tar.xz格式${NC}"
            fi
        elif [ -d "$input_path" ]; then
            local tarballs=($(find "$input_path" -maxdepth 1 -name "mysql-*.tar.xz" 2>/dev/null))
            if [ ${#tarballs[@]} -eq 0 ]; then
                echo -e "${RED}目录中未找到MySQL tar.xz包${NC}"
                continue
            fi

            echo -e "${GREEN}找到 ${#tarballs[@]} 个安装包:${NC}"
            local counter=1
            for tarball in "${tarballs[@]}"; do
                echo "  $counter. $(basename "$tarball")"
                ((counter++))
            done

            read -p "请选择编号 [1-${#tarballs[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#tarballs[@]} ]; then
                local index=$((choice - 1))
                OFFLINE_TARBALL_PATH="${tarballs[$index]}"
                MYSQL_VERSION=$(basename "$OFFLINE_TARBALL_PATH" | sed 's/mysql-//' | sed 's/-linux.*//')
                parse_tarball_glibc_pkg "$OFFLINE_TARBALL_PATH"
                echo -e "${GREEN}已选择: $OFFLINE_TARBALL_PATH${NC}"
                echo -e "${GREEN}版本: $MYSQL_VERSION${NC}"
                read -p "是否使用此包? [y/N]: " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    return 0
                fi
            fi
        fi
    done
}

extract_offline_tarball() {
    echo -e "${YELLOW}解压MySQL离线安装包...${NC}"

    if [ -z "$OFFLINE_TARBALL_PATH" ] || [ ! -f "$OFFLINE_TARBALL_PATH" ]; then
        echo -e "${RED}离线安装包路径无效${NC}"
        return 1
    fi

    # 解压到/tmp
    tar -xJf "$OFFLINE_TARBALL_PATH" -C /tmp
    if [ $? -ne 0 ]; then
        echo -e "${RED}解压失败${NC}"
        return 1
    fi

    # 查找解压后的目录
    local extract_dir=$(find /tmp -maxdepth 1 -type d -name "mysql-${MYSQL_VERSION}-*" 2>/dev/null | head -1)
    if [ -z "$extract_dir" ]; then
        echo -e "${RED}解压后未找到MySQL目录${NC}"
        return 1
    fi

    # 移动到安装目录
    if [ -d "$MYSQL_INSTALL_DIR" ]; then
        rm -rf "$MYSQL_INSTALL_DIR"
    fi
    mkdir -p "$MYSQL_HOME"
    mv "$extract_dir" "$MYSQL_INSTALL_DIR"

    chown -R $MYSQL_USER:$MYSQL_GROUP "$MYSQL_INSTALL_DIR"
    chmod -R u+rwX,go+rX "$MYSQL_INSTALL_DIR"

    echo -e "${GREEN}解压安装完成${NC}"
    return 0
}

# ======================== 离线安装流程 ========================

offline_install_flow() {
    OFFLINE_MODE="1"
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}MySQL 离线安装模式${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo ""

    # 查找离线包
    if ! find_offline_tarball; then
        return
    fi

    # 配置
    read -p "是否使用默认配置? [y/N]: " use_default
    if [[ ! $use_default =~ ^[Yy]$ ]]; then
        read -p "安装目录 [$DEFAULT_MYSQL_HOME]: " input_home
        MYSQL_HOME=${input_home:-$DEFAULT_MYSQL_HOME}
        read -p "端口号 [$DEFAULT_MYSQL_PORT]: " input_port
        MYSQL_PORT=${input_port:-$DEFAULT_MYSQL_PORT}
        read -s -p "Root密码 [默认: root]: " input_pass
        echo ""
        MYSQL_ROOT_PASSWORD=${input_pass:-$DEFAULT_MYSQL_ROOT_PASSWORD}
    else
        MYSQL_HOME=$DEFAULT_MYSQL_HOME
        MYSQL_PORT=$DEFAULT_MYSQL_PORT
        MYSQL_ROOT_PASSWORD=$DEFAULT_MYSQL_ROOT_PASSWORD
    fi

    MYSQL_USER=$DEFAULT_MYSQL_USER
    MYSQL_GROUP=$DEFAULT_MYSQL_GROUP
    MYSQL_INSTALL_DIR="${MYSQL_HOME}/mysql-${MYSQL_VERSION}"
    MYSQL_DATA_DIR="${MYSQL_HOME}/data"
    MYSQL_LOG_DIR="${MYSQL_HOME}/log"

    echo ""
    echo -e "${CYAN}最终配置:${NC}"
    echo "  版本: $MYSQL_VERSION"
    echo "  安装目录: $MYSQL_INSTALL_DIR"
    echo "  端口: $MYSQL_PORT"
    echo ""

    read -p "确认安装? [y/N]: " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        return
    fi

    pre_install_check || return 1
    install_dependencies
    create_user_and_dirs
    extract_offline_tarball
    configure_mysql
    setup_environment
    init_database
    create_systemd_service || return 1
    set_password
    configure_firewall
    verify_installation
    show_installation_info
}

# ======================== 主函数 ========================

main() {
    echo -e "${GREEN}MySQL 自动化安装脚本${NC}"
    echo -e "${GREEN}二进制包安装方式 | 支持 x86_64 和 ARM64${NC}"
    echo -e "${CYAN}系统: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d'"' -f2)${NC}"
    echo -e "${CYAN}架构: $ARCH_TYPE | glibc: $GLIBC_VERSION${NC}"
    echo ""

    echo -e "${YELLOW}请选择操作:${NC}"
    echo "1. 全新安装MySQL（在线下载二进制包）"
    echo "2. 离线安装MySQL（使用本地tar.xz包）"
    echo "3. 直接初始化数据库（MySQL已安装）"
    echo "q. 退出"
    echo ""
    read -p "请选择 [1/2/3/q]: " main_choice

    case $main_choice in
        "1")
            # 选择版本
            select_version
            if [ $? -ne 0 ]; then
                main "$@"
                exit 0
            fi

            # 确认配置
            confirm_configuration
            if [ $? -ne 0 ]; then
                main "$@"
                exit 0
            fi

            # 开始安装
            pre_install_check || exit 1
            install_dependencies
            create_user_and_dirs

            if ! download_binary; then
                echo ""
                echo -e "${YELLOW}请选择操作:${NC}"
                echo "1. 重新尝试下载"
                echo "2. 返回主菜单"
                read -p "请选择 [1-2]: " retry_choice
                case $retry_choice in
                    "1") main "$@"; exit 0 ;;
                    *) main "$@"; exit 0 ;;
                esac
            fi

            extract_and_install
            configure_mysql
            setup_environment
            init_database
            create_systemd_service || exit 1
            set_password
            configure_firewall
            verify_installation
            show_installation_info
            cleanup_temp_files

            echo ""
            echo -e "${GREEN}MySQL ${MYSQL_VERSION} 安装完成!${NC}"
            ;;
        "2")
            offline_install_flow
            ;;
        "3")
            # 直接初始化
            echo -e "${YELLOW}直接初始化数据库模式${NC}"
            read -p "MySQL安装路径: " mysql_install_path
            read -p "数据目录路径: " mysql_data_path
            read -p "MySQL用户名 [mysql]: " mysql_user

            MYSQL_INSTALL_DIR="$mysql_install_path"
            MYSQL_DATA_DIR="${mysql_data_path:-$MYSQL_INSTALL_DIR/../data}"
            MYSQL_USER="${mysql_user:-mysql}"
            MYSQL_GROUP="$MYSQL_USER"
            MYSQL_HOME=$(dirname "$MYSQL_INSTALL_DIR")
            MYSQL_LOG_DIR="$MYSQL_HOME/log"

            if [ ! -f "$MYSQL_INSTALL_DIR/bin/mysqld" ]; then
                echo -e "${RED}错误: 找不到mysqld${NC}"
                exit 1
            fi

            MYSQL_VERSION=$($MYSQL_INSTALL_DIR/bin/mysqld --version | awk '{print $3}' | cut -d- -f1)
            update_tarball_name
            pre_install_check || exit 1

            mkdir -p $MYSQL_DATA_DIR $MYSQL_LOG_DIR
            chown -R $MYSQL_USER:$MYSQL_GROUP $MYSQL_HOME

            configure_mysql
            setup_environment
            init_database
            create_systemd_service || exit 1
            set_password
            configure_firewall
            verify_installation
            show_installation_info
            ;;
        "q"|"Q")
            echo -e "${GREEN}退出安装${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            exit 1
            ;;
    esac
}

# 执行主函数
main "$@"

# 执行主函数
main "$@"
