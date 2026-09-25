#!/bin/bash

# Redis 自动化安装脚本
# 支持编译好的 Redis 二进制包部署，支持单机 / 哨兵 / Cluster 模式
# 兼容 Ubuntu 22/24、Debian 12、CentOS Stream/Rocky/AlmaLinux 8/9

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ======================== 系统版本检测与包管理统一封装 ========================
# EL8/9(Rocky/AlmaLinux/CentOS/RHEL) 用 dnf，EL7 用 yum，Debian 系用 apt-get
SYS_PKG=""; SYS_FAMILY=""; OS_ID=""; OS_MAJOR=""

detect_sys_pkg() {
    if [ -r /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"; OS_MAJOR="${VERSION_ID%%.*}"
    fi
    if command -v dnf &>/dev/null && [[ "$OS_MAJOR" =~ ^[0-9]+$ ]] && [ "$OS_MAJOR" -ge 8 ]; then
        SYS_PKG=dnf; SYS_FAMILY=el
    elif command -v yum &>/dev/null; then
        SYS_PKG=yum; SYS_FAMILY=el
    elif command -v apt-get &>/dev/null; then
        SYS_PKG=apt-get; SYS_FAMILY=debian
    fi
}

# 静默安装软件包。用法：sys_pkg_install "<el系包名>" "<debian系包名>"
sys_pkg_install() {
    local el_pkg="$1" deb_pkg="${2:-$1}"
    case "$SYS_PKG" in
        dnf) dnf install -y $el_pkg ;;
        yum) yum install -y $el_pkg ;;
        apt-get) apt-get install -y $deb_pkg ;;
        *) return 1 ;;
    esac
}

# 检查是否使用bash执行
if [ -z "$BASH_VERSION" ]; then
    echo -e "${RED}错误: 请使用bash执行此脚本，而不是sh${NC}"
    echo "正确用法: bash install_redis.sh 或 ./install_redis.sh"
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

# 默认配置
# 版本选型: 传统缓存/哨兵/Cluster → 7.4.9；JSON/Search/向量 → 8.8.3（详见手册）
# 源码包下载（放入 package/redis-${REDIS_VERSION}.tar.gz）：
#   官方: https://download.redis.io/releases/redis-${REDIS_VERSION}.tar.gz
#   USTC: https://mirrors.ustc.edu.cn/redis/redis-${REDIS_VERSION}.tar.gz
#   华为: https://mirrors.huaweicloud.com/redis/redis-${REDIS_VERSION}.tar.gz
# 示例: 7.4.9 → https://mirrors.ustc.edu.cn/redis/redis-7.4.9.tar.gz
#       8.8.3 → https://mirrors.ustc.edu.cn/redis/redis-8.8.3.tar.gz
REDIS_VERSION="7.2.4"
REDIS_TGZ="$SCRIPT_DIR/package/redis-${REDIS_VERSION}.tar.gz"

# 安装根目录（与 install_mysql.sh 的 MYSQL_HOME 规划一致）：
#   二进制安装目录 = $REDIS_HOME/redis-$REDIS_VERSION（如 /mnt/data/redis/redis-7.2.4）
#   数据目录       = $REDIS_HOME/data（如 /mnt/data/redis/data）
# REDIS_INSTALL_DIR / REDIS_DATA_DIR 默认由 finalize_paths 按根目录+版本派生；
# 也可用 --install-dir / --data-dir 显式指定（显式指定不被派生覆盖）。
DEFAULT_REDIS_HOME="/mnt/data/redis"
REDIS_HOME="$DEFAULT_REDIS_HOME"
REDIS_INSTALL_DIR=""
REDIS_DATA_DIR=""
REDIS_LOG_DIR="/var/log/redis"
REDIS_CONF_DIR="/etc/redis"
REDIS_RUN_DIR="/run/redis"
# 标记 --install-dir / --data-dir / --version 是否被显式指定（避免自动检测/派生覆盖）
REDIS_INSTALL_DIR_EXPLICIT=""
REDIS_DATA_DIR_EXPLICIT=""
REDIS_VERSION_EXPLICIT=""

# 默认端口和绑定地址
REDIS_PORT="6379"
REDIS_BIND="0.0.0.0"
REDIS_PASSWORD=""

# 部署模式：standalone / sentinel / cluster
DEPLOY_MODE="standalone"

# Cluster 配置
CLUSTER_ENABLED="no"
CLUSTER_CONFIG_FILE=""
CLUSTER_NODE_TIMEOUT="5000"
CLUSTER_REQUIRE_FULL_COVERAGE="no"
CLUSTER_MIGRATION_BARRIER="1"

# 开启保护模式
PROTECTED_MODE="yes"

# 日志级别
LOG_LEVEL="notice"

# 配置文件
CONFIG_FILE="/etc/redis_install.conf"

# 无人值守模式（供主从/哨兵脚本 SSH 远程调用）
BATCH_MODE=0
SKIP_START=0
FORCE_REINSTALL=0
KEEP_PACKAGE=1

# ======================== 函数定义 ========================

info() {
    echo -e "${CYAN}[INFO] $1${NC}"
}

success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

# 检测操作系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION_ID=$VERSION_ID
    else
        error "无法检测操作系统版本"
    fi
    info "检测到操作系统: $OS $VERSION_ID"
}

# 安装依赖
install_dependencies() {
    info "安装基础依赖..."
    detect_sys_pkg
    if [ "$SYS_FAMILY" = "debian" ]; then
        apt-get update -y
    fi
    sys_pkg_install "wget tar gcc make"
}

# 从安装包文件名提取 Redis 版本号（与 install_mysql.sh 离线包从文件名取版本同理）：
#   redis-7.2.4.tar.gz、redis-8.8.3.tar.gz                      → 7.2.4 / 8.8.3
#   redis-7.2.4-linux-x86_64.tar.gz（--pack 打包的预编译产物）  → 7.2.4
_redis_ver_from_name() {
    basename "$1" | sed -n -E 's/^redis-([0-9]+\.[0-9]+\.[0-9]+).*\.tar\.gz$/\1/p'
}

# 扫描本地安装包自动确定版本（避免脚本内置默认版本与实际放入的 redis-8.8.3.tar.gz 不一致）。
# 扫描位置：脚本根目录 $SCRIPT_DIR 与 $SCRIPT_DIR/package/（maxdepth 1，用户放哪都能识别）。
# 优先级：--version 显式指定 > --tgz 指定文件的版本 > 本地扫描 > 内置默认版本。
#   - 只检测到一个版本：自动采用；
#   - 交互模式检测到多个版本：列编号让用户选（同 MySQL 离线包选择）；
#   - 非交互（--batch/哨兵/Cluster 远程安装）检测到多个版本：自动取版本号最高者。
detect_local_package() {
    # ① 已通过 --tgz 显式指定包：路径不变，仅按文件名校正版本（--version 优先级更高）
    if [ -n "$REDIS_TGZ_EXPLICIT" ]; then
        if [ -z "$REDIS_VERSION_EXPLICIT" ]; then
            local v
            v=$(_redis_ver_from_name "$REDIS_TGZ")
            if [ -n "$v" ] && [ "$v" != "$REDIS_VERSION" ]; then
                REDIS_VERSION="$v"
                info "根据安装包文件名确定 Redis 版本: $REDIS_VERSION（$(basename "$REDIS_TGZ")）"
            fi
        fi
        return 0
    fi

    # ② 扫描脚本根目录与 package/ 下的 redis-*.tar.gz
    local found
    found=$( {
        find "$SCRIPT_DIR" -maxdepth 1 -type f -name 'redis-*.tar.gz' 2>/dev/null
        find "$SCRIPT_DIR/package" -maxdepth 1 -type f -name 'redis-*.tar.gz' 2>/dev/null
    } | sort -u )
    [ -z "$found" ] && return 0

    # 过滤出文件名含合法 X.Y.Z 版本号的包
    local packs=() vers=() f v
    while IFS= read -r f; do
        v=$(_redis_ver_from_name "$f")
        [ -n "$v" ] || continue
        packs+=("$f"); vers+=("$v")
    done <<< "$found"
    [ ${#packs[@]} -eq 0 ] && return 0

    # ③ --version 显式指定：只挑版本匹配的本地包，挑不到则保持原路径（后续走下载逻辑）
    if [ -n "$REDIS_VERSION_EXPLICIT" ]; then
        local i
        for i in "${!packs[@]}"; do
            if [ "${vers[$i]}" = "$REDIS_VERSION" ]; then
                REDIS_TGZ="${packs[$i]}"
                REDIS_TGZ_EXPLICIT=1
                info "使用本地安装包: $REDIS_TGZ"
                return 0
            fi
        done
        return 0
    fi

    # ④ 汇总去重版本
    local uniq_vers=() seen=" "
    for v in "${vers[@]}"; do
        case "$seen" in
            *" $v "*) ;;
            *) uniq_vers+=("$v"); seen="$seen$v " ;;
        esac
    done

    local chosen_ver
    if [ ${#uniq_vers[@]} -eq 1 ]; then
        chosen_ver="${uniq_vers[0]}"
    elif [ "$BATCH_MODE" != "1" ] && [ -t 0 ]; then
        # 交互模式多版本：编号选择
        echo
        echo -e "${CYAN}检测到多个 Redis 本地安装包，请选择版本：${NC}"
        local idx=1
        for v in "${uniq_vers[@]}"; do
            echo "  $idx) $v"
            idx=$((idx + 1))
        done
        local choice
        read -p "请选择编号 [1-${#uniq_vers[@]}，默认 1]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#uniq_vers[@]} ]; then
            chosen_ver="${uniq_vers[$((choice - 1))]}"
        else
            chosen_ver="${uniq_vers[0]}"
        fi
    else
        # 非交互：取版本号最高者
        chosen_ver=$(printf '%s\n' "${uniq_vers[@]}" | sort -V | tail -1)
    fi

    # 取该版本扫描到的第一个包（顺序：脚本根目录 → package/）
    local i
    for i in "${!packs[@]}"; do
        if [ "${vers[$i]}" = "$chosen_ver" ]; then
            REDIS_VERSION="$chosen_ver"
            REDIS_TGZ="${packs[$i]}"
            info "检测到本地 Redis 安装包，使用版本 $REDIS_VERSION: $REDIS_TGZ"
            return 0
        fi
    done
}

# 按 REDIS_HOME + 版本派生默认路径（MySQL 风格）。
# 必须在版本确定（含 --version 解析）之后、实际安装前调用：
#   REDIS_INSTALL_DIR = $REDIS_HOME/redis-$REDIS_VERSION
#   REDIS_DATA_DIR    = $REDIS_HOME/data
# 通过 --install-dir / --data-dir（或哨兵/Cluster 脚本显式传参）指定的路径不覆盖。
finalize_paths() {
    REDIS_HOME="${REDIS_HOME:-$DEFAULT_REDIS_HOME}"
    if [ -z "$REDIS_INSTALL_DIR_EXPLICIT" ]; then
        REDIS_INSTALL_DIR="${REDIS_HOME}/redis-${REDIS_VERSION}"
    fi
    if [ -z "$REDIS_DATA_DIR_EXPLICIT" ]; then
        REDIS_DATA_DIR="${REDIS_HOME}/data"
    fi
}

# 创建用户和目录
create_user_and_dirs() {
    info "创建 redis 用户..."
    if ! id -u redis > /dev/null 2>&1; then
        useradd -r -s /sbin/nologin redis
    fi

    info "创建目录结构..."
    mkdir -p $REDIS_INSTALL_DIR
    mkdir -p $REDIS_DATA_DIR
    mkdir -p $REDIS_LOG_DIR
    mkdir -p $REDIS_CONF_DIR
    mkdir -p $REDIS_RUN_DIR

    chown -R redis:redis $REDIS_DATA_DIR $REDIS_LOG_DIR $REDIS_RUN_DIR $REDIS_INSTALL_DIR
}

# 部署Redis二进制文件
deploy_redis() {
    info "部署 Redis 二进制文件..."

    if [ -f "$REDIS_TGZ" ]; then
        info "使用本地压缩包: $REDIS_TGZ"
        rm -rf "${REDIS_INSTALL_DIR}.tmp"
        mkdir -p "${REDIS_INSTALL_DIR}.tmp"
        tar zxf "$REDIS_TGZ" -C "${REDIS_INSTALL_DIR}.tmp" --strip-components=1

        # 若是源码包且尚无二进制，则编译
        if [ ! -f "${REDIS_INSTALL_DIR}.tmp/bin/redis-server" ]; then
            info "检测到源码包，开始编译..."
            install_dependencies
            cd "${REDIS_INSTALL_DIR}.tmp" || error "无法进入编译目录"
            make -j"$(nproc 2>/dev/null || echo 2)"
            make PREFIX="$REDIS_INSTALL_DIR" install
            rm -rf "${REDIS_INSTALL_DIR}.tmp"
        else
            # 已是编译产物目录结构
            rm -rf "$REDIS_INSTALL_DIR"
            mkdir -p "$REDIS_INSTALL_DIR"
            cp -a "${REDIS_INSTALL_DIR}.tmp/." "$REDIS_INSTALL_DIR/"
            rm -rf "${REDIS_INSTALL_DIR}.tmp"
        fi
    else
        info "本地压缩包不存在，从官网下载..."
        mkdir -p "$(dirname "$REDIS_TGZ")"
        wget "http://download.redis.io/releases/redis-${REDIS_VERSION}.tar.gz" -O "$REDIS_TGZ" || \
            error "下载 Redis 失败"
        rm -rf "${REDIS_INSTALL_DIR}.tmp"
        mkdir -p "${REDIS_INSTALL_DIR}.tmp"
        tar zxf "$REDIS_TGZ" -C "${REDIS_INSTALL_DIR}.tmp" --strip-components=1
        cd "${REDIS_INSTALL_DIR}.tmp" || error "无法进入编译目录"
        install_dependencies
        make -j"$(nproc 2>/dev/null || echo 2)"
        make PREFIX="$REDIS_INSTALL_DIR" install
        rm -rf "${REDIS_INSTALL_DIR}.tmp"
    fi

    if [ ! -f "$REDIS_INSTALL_DIR/bin/redis-server" ]; then
        # 兼容 make install 到 PREFIX 的布局
        if [ -f "$REDIS_INSTALL_DIR/bin/redis-server" ]; then
            :
        elif [ -f "$REDIS_INSTALL_DIR/redis-server" ]; then
            mkdir -p "$REDIS_INSTALL_DIR/bin"
            mv "$REDIS_INSTALL_DIR"/redis-* "$REDIS_INSTALL_DIR/bin/" 2>/dev/null || true
        else
            error "Redis 二进制部署失败，请检查压缩包"
        fi
    fi

    chown -R redis:redis "$REDIS_INSTALL_DIR"
    success "Redis 二进制部署完成: $REDIS_INSTALL_DIR"

    # 创建全局命令软链接到 /usr/local/bin（该目录默认在所有用户的 PATH 中，
    # 软链接立即生效、无需重新登录；ln -sf 保证多实例/多版本重复执行时幂等，
    # 最终指向最后一次安装的版本）
    mkdir -p /usr/local/bin
    local cmd linked=()
    for cmd in redis-server redis-cli redis-benchmark redis-check-aof redis-check-rdb redis-sentinel; do
        if [ -x "$REDIS_INSTALL_DIR/bin/$cmd" ]; then
            ln -sf "$REDIS_INSTALL_DIR/bin/$cmd" "/usr/local/bin/$cmd"
            linked+=("$cmd")
        fi
    done
    if [ ${#linked[@]} -gt 0 ]; then
        success "已创建全局命令软链接（/usr/local/bin）: ${linked[*]}"
    fi
}

# 环境变量统一写到独立文件 /etc/profile.d/redis.sh（标准 /etc/profile 会自动
# source /etc/profile.d/*.sh），各组件一个文件、安装写入/卸载删除，互不影响；
# 对老版本脚本写进 /etc/profile 的历史段做一次性迁移清理。
REDIS_PROFILE_D="/etc/profile.d/redis.sh"

# 清理 /etc/profile 中的历史 Redis 段/孤儿行（幂等，无残留则不动文件）
_redis_clean_legacy_profile() {
    [ -f /etc/profile ] || return 0
    grep -qE "Redis Environment|REDIS_HOME|^[[:space:]]*export[[:space:]]+[\$/]" /etc/profile 2>/dev/null || return 0
    # 备份文件名含纳秒，避免同一秒内连续安装/卸载多个组件时备份互相覆盖
    cp /etc/profile /etc/profile.backup.$(date +%Y%m%d_%H%M%S_%N)
    sed -i 's/\r$//' /etc/profile
    sed -i -E '/# Redis Environment[[:space:]]*$/,/# End Redis Environment[[:space:]]*$/d' /etc/profile
    # 段外残留的 REDIS_HOME 孤儿行 + 通用畸形 export 行
    sed -i -E '\#(^|[^A-Za-z0-9_])REDIS_HOME#d' /etc/profile
    sed -i -E '\#^[[:space:]]*export[[:space:]]+[\$/]#d' /etc/profile
}

setup_environment() {
    info "配置环境变量..."

    # 1) 迁移清理老版本写入 /etc/profile 的段落（带备份）
    _redis_clean_legacy_profile

    # 2) 原子写入独立 profile.d 文件
    mkdir -p /etc/profile.d
    local tmpf
    tmpf=$(mktemp /etc/profile.d/.redis.XXXXXX 2>/dev/null || echo "/etc/profile.d/.redis.$$")
    cat > "$tmpf" << EOF
# Redis Environment —— 由 install_redis.sh 自动管理，卸载时自动删除，请勿手动编辑
export REDIS_HOME=$REDIS_INSTALL_DIR
# case 守卫：重复加载不重复叠加 PATH
case ":\$PATH:" in *":\$REDIS_HOME/bin:"*) ;; *) export PATH="\$REDIS_HOME/bin:\$PATH" ;; esac
EOF
    mv -f "$tmpf" "$REDIS_PROFILE_D"
    chmod 644 "$REDIS_PROFILE_D"

    # 3) 当前 shell 立即生效（不 source 整个 /etc/profile，避免触发历史坏段）
    export REDIS_HOME="$REDIS_INSTALL_DIR"
    case ":$PATH:" in *":$REDIS_HOME/bin:"*) ;; *) export PATH="$REDIS_INSTALL_DIR/bin:$PATH" ;; esac

    success "环境变量配置完成: $REDIS_PROFILE_D"
    info "  REDIS_HOME=$REDIS_INSTALL_DIR"
    info "  PATH 已包含: $REDIS_INSTALL_DIR/bin（新终端自动生效；当前终端执行 source $REDIS_PROFILE_D）"
}

# 打包已编译安装目录，供 scp 到远程
pack_installed_redis() {
    local pack_dir="$SCRIPT_DIR/package"
    local pack_name="redis-${REDIS_VERSION}-linux-$(uname -m).tar.gz"
    mkdir -p "$pack_dir"
    if [ ! -d "$REDIS_INSTALL_DIR" ] || [ ! -f "$REDIS_INSTALL_DIR/bin/redis-server" ]; then
        warn "未找到已安装的 Redis，无法打包"
        return 1
    fi
    tar zcf "${pack_dir}/${pack_name}" -C "$(dirname "$REDIS_INSTALL_DIR")" "$(basename "$REDIS_INSTALL_DIR")"
    REDIS_TGZ="${pack_dir}/${pack_name}"
    success "已打包安装目录: $REDIS_TGZ"
    return 0
}

# 生成单机模式配置文件
generate_standalone_config() {
    info "生成单机模式配置文件..."

    local conf_file="$REDIS_CONF_DIR/redis.conf"
    cat > "$conf_file" << EOF
# Redis 单机配置 - 由 install_redis.sh 自动生成
port $REDIS_PORT
bind $REDIS_BIND
protected-mode $PROTECTED_MODE
daemonize yes
pidfile $REDIS_RUN_DIR/redis_$REDIS_PORT.pid
loglevel $LOG_LEVEL
logfile $REDIS_LOG_DIR/redis_$REDIS_PORT.log
dir $REDIS_DATA_DIR
EOF

    # 如果设置了密码
    if [ -n "$REDIS_PASSWORD" ]; then
        echo "requirepass $REDIS_PASSWORD" >> "$conf_file"
    fi

    chown redis:redis "$conf_file"
    success "配置文件生成: $conf_file"
}

# 生成 Cluster 模式实例配置（cluster-enabled）
generate_cluster_instance_config() {
    info "生成 Cluster 模式实例配置..."

    local conf_file="$REDIS_CONF_DIR/redis_${REDIS_PORT}.conf"
    CLUSTER_CONFIG_FILE="$REDIS_DATA_DIR/redis_${REDIS_PORT}/nodes-${REDIS_PORT}.conf"

    mkdir -p "$REDIS_DATA_DIR/redis_${REDIS_PORT}"

    cat > "$conf_file" << EOF
# Redis Cluster 实例配置 - 由 install_redis.sh 自动生成
port $REDIS_PORT
bind $REDIS_BIND
protected-mode no
daemonize yes
pidfile $REDIS_RUN_DIR/redis_$REDIS_PORT.pid
loglevel $LOG_LEVEL
logfile $REDIS_LOG_DIR/redis_$REDIS_PORT.log
dir $REDIS_DATA_DIR/redis_$REDIS_PORT

# RDB
save 900 1
save 300 10
save 60 10000
rdbcompression yes
dbfilename dump_$REDIS_PORT.rdb

# Cluster
cluster-enabled yes
cluster-config-file nodes-${REDIS_PORT}.conf
cluster-node-timeout $CLUSTER_NODE_TIMEOUT
cluster-require-full-coverage $CLUSTER_REQUIRE_FULL_COVERAGE
cluster-migration-barrier $CLUSTER_MIGRATION_BARRIER
cluster-announce-ip $REDIS_BIND
cluster-announce-port $REDIS_PORT
cluster-announce-bus-port $((REDIS_PORT + 10000))
EOF

    if [ -n "$REDIS_PASSWORD" ]; then
        echo "requirepass $REDIS_PASSWORD" >> "$conf_file"
        echo "masterauth $REDIS_PASSWORD" >> "$conf_file"
    fi

    chown -R redis:redis "$conf_file" "$REDIS_DATA_DIR/redis_${REDIS_PORT}"
    success "Cluster 实例配置: $conf_file"
}

# 生成systemd服务文件
generate_systemd_service() {
    info "生成 systemd 服务文件..."

    local service_file="/etc/systemd/system/redis@.service"
    cat > "$service_file" << EOF
[Unit]
Description=Redis In-Memory Data Store (port %i)
After=network.target

[Service]
Type=forking
User=redis
Group=redis
PIDFile=$REDIS_RUN_DIR/redis_%i.pid
ExecStart=$REDIS_INSTALL_DIR/bin/redis-server $REDIS_CONF_DIR/redis_%i.conf
ExecStop=$REDIS_INSTALL_DIR/bin/redis-cli -p %i shutdown
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    # 如果是单机模式，创建默认服务
    if [ "$DEPLOY_MODE" = "standalone" ]; then
        cat > /etc/systemd/system/redis.service << EOF
[Unit]
Description=Redis In-Memory Data Store
After=network.target

[Service]
Type=forking
User=redis
Group=redis
PIDFile=$REDIS_RUN_DIR/redis_$REDIS_PORT.pid
ExecStart=$REDIS_INSTALL_DIR/bin/redis-server $REDIS_CONF_DIR/redis.conf
ExecStop=$REDIS_INSTALL_DIR/bin/redis-cli -p $REDIS_PORT shutdown
Restart=always
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    fi

    systemctl daemon-reload
    success "systemd 服务文件生成完成"
}

# 启动服务
start_standalone_service() {
    if [ "$SKIP_START" = "1" ]; then
        info "跳过启动（将由主从/哨兵/Cluster脚本配置后启动）"
        return 0
    fi

    info "启动 Redis 服务..."
    if [ "$DEPLOY_MODE" = "standalone" ]; then
        systemctl enable --now redis
        sleep 2
        if systemctl is-active --quiet redis; then
            success "Redis 服务启动成功"
            info "监听端口: $REDIS_PORT"
            if [ -n "$REDIS_PASSWORD" ]; then
                info "连接命令: $REDIS_INSTALL_DIR/bin/redis-cli -p $REDIS_PORT -a $REDIS_PASSWORD"
            else
                info "连接命令: $REDIS_INSTALL_DIR/bin/redis-cli -p $REDIS_PORT"
            fi
        else
            error "Redis 服务启动失败，请查看日志: journalctl -u redis"
        fi
    elif [ "$DEPLOY_MODE" = "cluster" ]; then
        systemctl enable --now "redis@${REDIS_PORT}"
        sleep 2
        if systemctl is-active --quiet "redis@${REDIS_PORT}"; then
            success "Redis Cluster 实例启动成功: redis@${REDIS_PORT}"
        else
            error "Redis Cluster 实例启动失败: journalctl -u redis@${REDIS_PORT}"
        fi
    fi
}

# 交互式配置
interactive_config() {
    echo
    echo "=== Redis 安装配置 ==="
    echo

    read -p "请输入部署模式 (1=单机, 2=哨兵多实例, 3=Cluster) [默认: 1-单机]: " mode_choice
    case "$mode_choice" in
        2)
            DEPLOY_MODE="sentinel"
            ;;
        3)
            DEPLOY_MODE="cluster"
            ;;
        *)
            DEPLOY_MODE="standalone"
            ;;
    esac

    # 只询问安装根目录（与 MySQL 一致），二进制与数据目录按根目录自动派生：
    #   <根目录>/redis-<版本>  放二进制；<根目录>/data  放数据
    read -p "请输入 Redis 安装根目录 [默认: $REDIS_HOME]: " input
    if [ -n "$input" ]; then REDIS_HOME="$input"; fi

    read -p "请输入 Redis 端口 [默认: $REDIS_PORT]: " input
    if [ -n "$input" ]; then REDIS_PORT=$input; fi

    read -p "请输入 Redis 密码 (留空表示不设置): " input
    if [ -n "$input" ]; then REDIS_PASSWORD=$input; fi

    # 按根目录 + 版本派生最终安装/数据目录
    finalize_paths

    echo
    info "配置汇总:"
    info "  部署模式: $DEPLOY_MODE"
    info "  Redis 版本: $REDIS_VERSION"
    info "  安装包: $REDIS_TGZ"
    info "  安装根目录: $REDIS_HOME"
    info "  安装目录(二进制): $REDIS_INSTALL_DIR"
    info "  数据目录: $REDIS_DATA_DIR"
    info "  端口: $REDIS_PORT"
    info "  密码: ${REDIS_PASSWORD:-(未设置)}"
    echo
    read -p "确认开始安装? [y/N]: " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        info "用户取消安装"
        exit 0
    fi
}

# 保存配置
save_config() {
    cat > "$CONFIG_FILE" << EOF
# Redis 安装配置 - 由 install_redis.sh 生成
# Generated: $(date)
REDIS_VERSION=$REDIS_VERSION
REDIS_HOME=$REDIS_HOME
REDIS_INSTALL_DIR=$REDIS_INSTALL_DIR
REDIS_DATA_DIR=$REDIS_DATA_DIR
REDIS_LOG_DIR=$REDIS_LOG_DIR
REDIS_CONF_DIR=$REDIS_CONF_DIR
REDIS_RUN_DIR=$REDIS_RUN_DIR
REDIS_PORT=$REDIS_PORT
REDIS_BIND=$REDIS_BIND
REDIS_PASSWORD=$REDIS_PASSWORD
DEPLOY_MODE=$DEPLOY_MODE
REDIS_TGZ=$REDIS_TGZ
CLUSTER_ENABLED=$CLUSTER_ENABLED
CLUSTER_NODE_TIMEOUT=$CLUSTER_NODE_TIMEOUT
CLUSTER_REQUIRE_FULL_COVERAGE=$CLUSTER_REQUIRE_FULL_COVERAGE
EOF
    chmod 600 "$CONFIG_FILE"
    success "安装状态已写入 $CONFIG_FILE"
}

check_selinux() {
    if ! command -v getenforce &>/dev/null; then
        return 0
    fi
    if [ "${BATCH_MODE:-0}" = "1" ] || [ ! -t 0 ]; then
        return 0
    fi
    local current_mode
    current_mode="$(getenforce 2>/dev/null)"
    if [ "$current_mode" != "Enforcing" ]; then
        return 0
    fi
    echo ""
    echo -e "\033[0;33m检测到 SELinux 当前为 Enforcing（强制启用）状态\033[0m"
    echo -e "\033[0;36mSELinux 是内核级强制访问控制，可能限制 systemd 服务访问自定义安装/数据目录，\033[0m"
    echo -e "\033[0;36m这是把服务安装到非标准目录后启动失败的常见原因。\033[0m"
    echo ""
    echo -e "\033[0;33m建议:\033[0m" 内网/自建中间件环境通常可关闭 SELinux；若主机暴露公网或有等保合规要求，建议保持开启并自行配置策略。
    echo ""
    echo "请选择:"
    echo "  1. 关闭 SELinux（推荐）：立即设为 Permissive，并写入配置永久禁用（重启后完全生效）"
    echo "  2. 保持开启：继续安装，但服务可能因 SELinux 拦截而启动失败"
    read -p "请选择 [1/2，默认 1]: " selinux_choice
    if [ "$selinux_choice" = "2" ]; then
        echo -e "\033[0;33m已保留 SELinux Enforcing；若服务启动失败，可手动执行 setenforce 0 排查\033[0m"
        return 0
    fi
    setenforce 0 2>/dev/null || true
    if [ -f /etc/selinux/config ]; then
        sed -i 's/^SELINUX=enforcing/SELINUX=disabled/I' /etc/selinux/config
    fi
    echo -e "\033[0;32mSELinux 已临时关闭（Permissive），并已配置重启后永久禁用\033[0m"
}

# ======================== 无人值守安装 ========================

parse_batch_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --batch|-b)
                BATCH_MODE=1
                shift
                ;;
            --standalone)
                BATCH_MODE=1
                DEPLOY_MODE="standalone"
                shift
                ;;
            --sentinel)
                BATCH_MODE=1
                DEPLOY_MODE="sentinel"
                shift
                ;;
            --cluster)
                BATCH_MODE=1
                DEPLOY_MODE="cluster"
                CLUSTER_ENABLED="yes"
                shift
                ;;
            --cluster-node-timeout)
                CLUSTER_NODE_TIMEOUT="${2:-5000}"
                shift 2
                ;;
            --version)
                REDIS_VERSION="${2:-}"
                REDIS_VERSION_EXPLICIT=1
                # 若未显式指定 tgz，则按新版本重算默认包名
                if [[ -z "$REDIS_TGZ_EXPLICIT" ]]; then
                    REDIS_TGZ="$SCRIPT_DIR/package/redis-${REDIS_VERSION}.tar.gz"
                fi
                shift 2
                ;;
            --tgz)
                REDIS_TGZ="${2:-}"
                REDIS_TGZ_EXPLICIT=1
                shift 2
                ;;
            --home)
                # 安装根目录：二进制装到 <home>/redis-<版本>，数据放到 <home>/data
                REDIS_HOME="${2:-}"
                shift 2
                ;;
            --install-dir)
                REDIS_INSTALL_DIR="${2:-}"
                REDIS_INSTALL_DIR_EXPLICIT=1
                shift 2
                ;;
            --data-dir)
                REDIS_DATA_DIR="${2:-}"
                REDIS_DATA_DIR_EXPLICIT=1
                shift 2
                ;;
            --port)
                REDIS_PORT="${2:-}"
                shift 2
                ;;
            --password)
                REDIS_PASSWORD="${2:-}"
                shift 2
                ;;
            --bind)
                REDIS_BIND="${2:-}"
                shift 2
                ;;
            --skip-start)
                SKIP_START=1
                shift
                ;;
            --pack)
                # 仅打包已安装目录
                detect_os
                create_user_and_dirs
                pack_installed_redis
                exit $?
                ;;
            --help|-h)
                cat <<'HELP'
Redis 安装脚本参数

交互模式:
  bash install_redis.sh

无人值守（主从/哨兵/Cluster 脚本 SSH 远程调用）:
  bash install_redis.sh --batch --tgz /tmp/redis-x.x.x.tar.gz \
      --port 6379 --password 'xxx' --skip-start

  bash install_redis.sh --batch --standalone --port 6379

  bash install_redis.sh --batch --cluster --tgz /tmp/redis-x.x.x.tar.gz \
      --port 6379 --password 'xxx' --skip-start

可选:
  --version VER              Redis 版本（默认 7.2.4；脚本目录/package 下有本地
                             redis-*.tar.gz 时自动按包文件名识别版本）
  --home DIR                 安装根目录（默认 /mnt/data/redis），二进制装到
                             <DIR>/redis-<版本>，数据放到 <DIR>/data
  --install-dir DIR          显式指定二进制安装目录（不用则按 --home 派生）
  --data-dir DIR             显式指定数据目录（不用则按 --home 派生为 <home>/data）
  --bind ADDR                绑定地址（默认 0.0.0.0）
  --cluster                  Cluster 模式（cluster-enabled yes）
  --cluster-node-timeout MS  集群节点超时毫秒（默认 5000）
  --skip-start               只安装不启动
  --pack                     将已安装目录打包到 package/ 便于 scp
HELP
                exit 0
                ;;
            *)
                shift
                ;;
        esac
    done
}

batch_install_flow() {
    BATCH_MODE=1
    # 参数解析完毕（版本此时才最终确定），按根目录+版本派生安装/数据目录
    finalize_paths
    info "========== Redis 无人值守安装 =========="
    info "模式: $DEPLOY_MODE"
    info "版本: $REDIS_VERSION"
    info "安装根目录: $REDIS_HOME"
    info "安装目录: $REDIS_INSTALL_DIR"
    info "数据目录: $REDIS_DATA_DIR"
    info "端口: $REDIS_PORT"
    info "包: $REDIS_TGZ"
    info "跳过启动: $SKIP_START"
    echo

    detect_os
    install_dependencies
    create_user_and_dirs

    # 清理旧安装（可选）
    if [ "$FORCE_REINSTALL" = "1" ] && [ -d "$REDIS_INSTALL_DIR" ]; then
        warn "强制重装，清理 $REDIS_INSTALL_DIR"
        rm -rf "$REDIS_INSTALL_DIR"
    fi

    deploy_redis
    setup_environment

    if [ "$DEPLOY_MODE" = "standalone" ]; then
        generate_standalone_config
    elif [ "$DEPLOY_MODE" = "cluster" ]; then
        CLUSTER_ENABLED="yes"
        generate_cluster_instance_config
    fi
    generate_systemd_service
    start_standalone_service
    save_config

    success "无人值守安装完成"
    return 0
}

# 主安装流程
main() {
    parse_batch_args "$@"

    # 参数解析后先扫描本地安装包确定版本（如目录中放入 redis-8.8.3.tar.gz 则自动用 8.8.3），
    # 必须在 finalize_paths（路径派生依赖版本）之前完成
    detect_local_package

    if [ "$BATCH_MODE" = "1" ]; then
        batch_install_flow
        exit $?
    fi

    detect_os
    interactive_config
    install_dependencies
    create_user_and_dirs
    deploy_redis
    setup_environment
    if [ "$DEPLOY_MODE" = "standalone" ]; then
        generate_standalone_config
    elif [ "$DEPLOY_MODE" = "cluster" ]; then
        CLUSTER_ENABLED="yes"
        generate_cluster_instance_config
    fi
    check_selinux
    generate_systemd_service
    start_standalone_service
    save_config

    echo
    success "============================================"
    success "Redis $DEPLOY_MODE 模式安装完成!"
    success "安装目录: $REDIS_INSTALL_DIR"
    success "配置目录: $REDIS_CONF_DIR"
    success "数据目录: $REDIS_DATA_DIR"
    success "环境变量: 已写入 /etc/profile.d/redis.sh（新终端可直接用 redis-cli；当前终端执行 source /etc/profile.d/redis.sh）"
    if [ "$DEPLOY_MODE" = "standalone" ]; then
        success "服务名称: redis"
        success "管理命令: systemctl {start|stop|restart|status} redis"
    elif [ "$DEPLOY_MODE" = "cluster" ]; then
        success "实例服务: systemctl {start|stop|restart} redis@${REDIS_PORT}"
        success "Cluster总线端口: $((REDIS_PORT + 10000))"
        success "一键分片部署: bash $SCRIPT_DIR/setup_redis_cluster.sh"
    else
        success "多实例管理: systemctl {start|stop|restart} redis@端口"
        success "哨兵/主从一键部署: bash $SCRIPT_DIR/setup_redis_sentinel.sh"
    fi
    success "============================================"
    echo
}

# 启动安装
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    main --help
elif [ "$1" = "--standalone" ] && [ -z "$2" ]; then
    # 兼容旧用法：仅 --standalone 进入非交互
    main --batch --standalone
elif [ "$1" = "--sentinel" ] && [ -z "$2" ]; then
    main --batch --sentinel
elif [ "$1" = "--cluster" ] && [ -z "$2" ]; then
    main --batch --cluster
else
    main "$@"
fi
