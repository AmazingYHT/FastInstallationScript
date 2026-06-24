#!/bin/bash

# Nacos 自动化安装脚本（Linux）
# 支持单机模式和集群模式部署
# 支持 Derby（内嵌）和 MySQL（外部）存储库选择
# 本地 package/ 目录优先，缺失时自动从官方下载
# 兼容 Ubuntu 22/24、Debian 12、CentOS Stream/Rocky/AlmaLinux 8/9

# ======================== 全局变量 ========================

# 脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 引入通用函数库（颜色、日志、环境检查、detect_os、依赖安装、端口校验）
# shellcheck source=../lib_common.sh
source "$SCRIPT_DIR/../lib_common.sh" || { echo "错误: 未找到通用库 lib_common.sh"; exit 1; }

require_bash
require_root

# 默认配置（可通过命令行参数或交互覆盖）
NACOS_VERSION="${NACOS_VERSION:-2.5.0}"
NACOS_INSTALL_DIR="/usr/local/nacos"
NACOS_PACKAGE_DIR="$SCRIPT_DIR/package"

# 部署模式：standalone 或 cluster
DEPLOY_MODE=""

# 存储库类型：derby 或 mysql
DB_TYPE=""

# Nacos 端口
NACOS_PORT="8848"

# 集群节点列表（逗号分隔的 ip:port）
CLUSTER_NODES=""

# MySQL 连接信息
MYSQL_HOST="127.0.0.1"
MYSQL_PORT="3306"
MYSQL_DB="nacos"
MYSQL_USER="nacos"
MYSQL_PASSWORD=""

# 鉴权配置
AUTH_ENABLED="true"
AUTH_TOKEN=""
AUTH_IDENTITY_KEY="nacos"
AUTH_IDENTITY_VALUE=""

# 非交互模式标记
NON_INTERACTIVE="false"

# GitHub 下载基础地址
DOWNLOAD_BASE="https://github.com/alibaba/nacos/releases/download"

# ======================== 函数定义 ========================

# 显示帮助
usage() {
    cat <<EOF
Nacos 自动化安装脚本（Linux）

用法: bash install_nacos.sh [选项]

选项:
  --standalone              单机模式部署
  --cluster                 集群模式部署
  --db derby|mysql          存储库类型（默认 derby）
  --version <版本号>        指定 Nacos 版本（默认 ${NACOS_VERSION}）
  --port <端口>             Nacos 服务端口（默认 ${NACOS_PORT}）
  --nodes <ip:port,...>     集群节点列表（集群模式必填）
  --mysql-host <host>       MySQL 主机（默认 ${MYSQL_HOST}）
  --mysql-port <port>       MySQL 端口（默认 ${MYSQL_PORT}）
  --mysql-db <dbname>       MySQL 数据库名（默认 ${MYSQL_DB}）
  --mysql-user <user>       MySQL 用户名（默认 ${MYSQL_USER}）
  --mysql-password <pwd>    MySQL 密码
  -h, --help                显示此帮助

示例:
  # 交互式安装
  bash install_nacos.sh

  # 单机 + Derby
  bash install_nacos.sh --standalone --db derby

  # 单机 + MySQL
  bash install_nacos.sh --standalone --db mysql --mysql-host 127.0.0.1 --mysql-password 123456

  # 集群 + MySQL
  bash install_nacos.sh --cluster --db mysql --nodes 192.168.1.10:8848,192.168.1.11:8848,192.168.1.12:8848 --mysql-host 192.168.1.20 --mysql-password 123456
EOF
    exit 0
}

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --standalone) DEPLOY_MODE="standalone"; NON_INTERACTIVE="true"; shift ;;
            --cluster) DEPLOY_MODE="cluster"; NON_INTERACTIVE="true"; shift ;;
            --db) DB_TYPE="$2"; shift 2 ;;
            --version) NACOS_VERSION="$2"; shift 2 ;;
            --port) NACOS_PORT="$2"; validate_port "$NACOS_PORT" "Nacos 服务"; shift 2 ;;
            --nodes) CLUSTER_NODES="$2"; shift 2 ;;
            --mysql-host) MYSQL_HOST="$2"; shift 2 ;;
            --mysql-port) MYSQL_PORT="$2"; shift 2 ;;
            --mysql-db) MYSQL_DB="$2"; shift 2 ;;
            --mysql-user) MYSQL_USER="$2"; shift 2 ;;
            --mysql-password) MYSQL_PASSWORD="$2"; shift 2 ;;
            -h|--help) usage ;;
            *) error "未知参数: $1（使用 --help 查看帮助）" ;;
        esac
    done
}

# 检测操作系统
# detect_os / install_base_deps / validate_port 由 lib_common.sh 提供

# 检查 Java 环境
check_java() {
    info "检查 Java 环境..."
    if ! command -v java > /dev/null 2>&1; then
        error "未检测到 Java 环境，Nacos 需要 JDK 8 及以上。请先安装 JDK 并配置 JAVA_HOME"
    fi
    local java_ver
    java_ver=$(java -version 2>&1 | head -n1)
    info "Java 版本: $java_ver"
}

# 校验端口（validate_port 由 lib_common.sh 提供）

# 交互式收集版本号和端口
collect_basic_info() {
    if [ "$NON_INTERACTIVE" = "true" ]; then
        return
    fi
    echo ""
    info "基础配置（直接回车使用默认值）"
    read -rp "Nacos 版本 (默认 $NACOS_VERSION): " input; NACOS_VERSION="${input:-$NACOS_VERSION}"
    read -rp "服务端口 (默认 $NACOS_PORT): " input; NACOS_PORT="${input:-$NACOS_PORT}"
    validate_port "$NACOS_PORT" "Nacos 服务"
    info "版本: $NACOS_VERSION  端口: $NACOS_PORT"
}

# 交互式选择部署模式
choose_mode() {
    if [ -n "$DEPLOY_MODE" ]; then
        return
    fi
    echo ""
    echo "请选择部署模式:"
    echo "  1) 单机模式 (standalone)"
    echo "  2) 集群模式 (cluster)"
    read -rp "请输入选项 [1-2] (默认 1): " choice
    case "$choice" in
        2) DEPLOY_MODE="cluster" ;;
        *) DEPLOY_MODE="standalone" ;;
    esac
    info "已选择部署模式: $DEPLOY_MODE"
}

# 交互式选择存储库
choose_db() {
    if [ -n "$DB_TYPE" ]; then
        return
    fi
    echo ""
    echo "请选择存储库类型:"
    echo "  1) Derby  (内嵌数据库，适合单机/测试)"
    echo "  2) MySQL  (外部数据库，集群模式推荐)"
    read -rp "请输入选项 [1-2] (默认 1): " choice
    case "$choice" in
        2) DB_TYPE="mysql" ;;
        *) DB_TYPE="derby" ;;
    esac
    info "已选择存储库: $DB_TYPE"
}

# 集群模式下交互收集节点信息
collect_cluster_nodes() {
    if [ "$DEPLOY_MODE" != "cluster" ]; then
        return
    fi
    if [ -z "$CLUSTER_NODES" ] && [ "$NON_INTERACTIVE" != "true" ]; then
        echo ""
        echo "请输入集群所有节点（格式 ip:port，多个用逗号分隔）"
        echo "例如: 192.168.1.10:8848,192.168.1.11:8848,192.168.1.12:8848"
        read -rp "集群节点: " CLUSTER_NODES
    fi
    if [ -z "$CLUSTER_NODES" ]; then
        error "集群模式必须提供节点列表（--nodes 或交互输入）"
    fi
    info "集群节点: $CLUSTER_NODES"
}

# MySQL 模式下交互收集连接信息
collect_mysql_info() {
    if [ "$DB_TYPE" != "mysql" ]; then
        return
    fi
    if [ "$NON_INTERACTIVE" != "true" ]; then
        echo ""
        info "配置 MySQL 连接信息（直接回车使用默认值）"
        read -rp "MySQL 主机 (默认 $MYSQL_HOST): " input; MYSQL_HOST="${input:-$MYSQL_HOST}"
        read -rp "MySQL 端口 (默认 $MYSQL_PORT): " input; MYSQL_PORT="${input:-$MYSQL_PORT}"
        read -rp "数据库名 (默认 $MYSQL_DB): " input; MYSQL_DB="${input:-$MYSQL_DB}"
        read -rp "用户名 (默认 $MYSQL_USER): " input; MYSQL_USER="${input:-$MYSQL_USER}"
        read -rsp "密码: " MYSQL_PASSWORD; echo ""
    fi
    if [ -z "$MYSQL_PASSWORD" ]; then
        warn "MySQL 密码为空，请确认这是预期行为"
    fi
}

# 获取安装包：本地优先，缺失则下载
prepare_package() {
    local pkg_name="nacos-server-${NACOS_VERSION}.tar.gz"
    local local_pkg="$NACOS_PACKAGE_DIR/$pkg_name"
    NACOS_TGZ="$local_pkg"

    mkdir -p "$NACOS_PACKAGE_DIR"

    if [ -f "$local_pkg" ]; then
        info "使用本地安装包: $local_pkg"
        return
    fi

    local url="${DOWNLOAD_BASE}/${NACOS_VERSION}/${pkg_name}"
    info "本地未找到安装包，从官方下载: $url"
    if ! wget --timeout=60 --tries=3 -O "$local_pkg" "$url"; then
        rm -f "$local_pkg"
        error "下载 Nacos 安装包失败（网络超时或版本不存在），请检查网络或手动将 $pkg_name 放入 $NACOS_PACKAGE_DIR 目录"
    fi
    # 校验下载文件大小（< 1MB 视为无效，如 404 页面）
    local file_size
    file_size=$(stat -c%s "$local_pkg" 2>/dev/null || echo 0)
    if [ "$file_size" -lt 1048576 ]; then
        rm -f "$local_pkg"
        error "下载的文件大小异常（${file_size}B），版本号可能不存在，请确认版本后重试"
    fi
    success "下载完成: $local_pkg（$(numfmt --to=iec "$file_size")）"
}

# 解压部署
deploy_nacos() {
    if [ -d "$NACOS_INSTALL_DIR" ]; then
        warn "检测到已存在安装目录: $NACOS_INSTALL_DIR"
        if [ "$NON_INTERACTIVE" != "true" ]; then
            read -rp "是否覆盖安装？(y/N): " confirm
            [[ "$confirm" =~ ^[Yy]$ ]] || error "已取消安装"
        fi
        rm -rf "$NACOS_INSTALL_DIR"
    fi

    info "解压安装包到 /usr/local ..."
    if ! tar -zxf "$NACOS_TGZ" -C /usr/local; then
        error "解压失败，安装包可能已损坏。请重新下载或手动验证 $NACOS_TGZ"
    fi
    # 解压后目录为 nacos
    if [ ! -d "/usr/local/nacos" ]; then
        error "解压后未找到 nacos 目录"
    fi
    success "Nacos 已部署到 $NACOS_INSTALL_DIR"
}

# 配置 application.properties
configure_application() {
    local conf="$NACOS_INSTALL_DIR/conf/application.properties"
    if [ ! -f "$conf" ]; then
        error "未找到配置文件 $conf，安装可能异常，请检查 $NACOS_INSTALL_DIR 目录"
    fi
    info "配置 $conf ..."

    # 端口
    if grep -q "^server.port=" "$conf"; then
        sed -i "s/^server.port=.*/server.port=${NACOS_PORT}/" "$conf"
    else
        echo "server.port=${NACOS_PORT}" >> "$conf"
    fi

    # 存储库配置
    if [ "$DB_TYPE" = "mysql" ]; then
        info "配置 MySQL 存储库..."
        # 移除旧的相关配置后追加
        sed -i '/^spring.datasource.platform=/d' "$conf"
        sed -i '/^spring.sql.init.platform=/d' "$conf"
        sed -i '/^db.num=/d' "$conf"
        sed -i '/^db.url.0=/d' "$conf"
        sed -i '/^db.user.0=/d' "$conf"
        sed -i '/^db.user=/d' "$conf"
        sed -i '/^db.password.0=/d' "$conf"
        sed -i '/^db.password=/d' "$conf"
        cat >> "$conf" <<EOF

# ===== 自动化脚本添加的 MySQL 存储配置 =====
spring.sql.init.platform=mysql
db.num=1
db.url.0=jdbc:mysql://${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DB}?characterEncoding=utf8&connectTimeout=1000&socketTimeout=3000&autoReconnect=true&useUnicode=true&useSSL=false&serverTimezone=UTC
db.user.0=${MYSQL_USER}
db.password.0=${MYSQL_PASSWORD}
EOF
    else
        info "使用 Derby 内嵌存储库（默认）"
    fi

    # 鉴权配置
    if [ -z "$AUTH_TOKEN" ]; then
        AUTH_TOKEN=$(head -c 32 /dev/urandom | base64 | tr -d '\n/+=' | head -c 32)
        AUTH_TOKEN=$(echo -n "$AUTH_TOKEN" | base64)
    fi
    if [ -z "$AUTH_IDENTITY_VALUE" ]; then
        AUTH_IDENTITY_VALUE=$(head -c 16 /dev/urandom | base64 | tr -d '\n/+=' | head -c 16)
    fi
    sed -i '/^nacos.core.auth.enabled=/d' "$conf"
    sed -i '/^nacos.core.auth.server.identity.key=/d' "$conf"
    sed -i '/^nacos.core.auth.server.identity.value=/d' "$conf"
    sed -i '/^nacos.core.auth.plugin.nacos.token.secret.key=/d' "$conf"
    cat >> "$conf" <<EOF

# ===== 自动化脚本添加的鉴权配置 =====
nacos.core.auth.enabled=${AUTH_ENABLED}
nacos.core.auth.server.identity.key=${AUTH_IDENTITY_KEY}
nacos.core.auth.server.identity.value=${AUTH_IDENTITY_VALUE}
nacos.core.auth.plugin.nacos.token.secret.key=${AUTH_TOKEN}
EOF

    success "application.properties 配置完成"
}

# 配置集群 cluster.conf
configure_cluster() {
    if [ "$DEPLOY_MODE" != "cluster" ]; then
        return
    fi
    local cluster_conf="$NACOS_INSTALL_DIR/conf/cluster.conf"
    info "生成集群配置 $cluster_conf ..."
    : > "$cluster_conf"
    echo "# Nacos 集群节点列表（由自动化脚本生成）" >> "$cluster_conf"
    IFS=',' read -ra NODES <<< "$CLUSTER_NODES"
    for node in "${NODES[@]}"; do
        node=$(echo "$node" | xargs)  # trim
        [ -n "$node" ] && echo "$node" >> "$cluster_conf"
    done
    success "集群配置完成，共 ${#NODES[@]} 个节点"

    if [ "$DB_TYPE" != "mysql" ]; then
        warn "集群模式强烈建议使用 MySQL 存储库，当前为 Derby，可能导致数据不一致"
    fi
}

# 初始化 MySQL 数据库表结构
init_mysql_schema() {
    if [ "$DB_TYPE" != "mysql" ]; then
        return
    fi
    local schema_file
    schema_file=$(find "$NACOS_INSTALL_DIR/conf" -name "mysql-schema.sql" | head -n1)
    if [ -z "$schema_file" ]; then
        warn "未找到 mysql-schema.sql，跳过自动初始化，请手动导入表结构"
        return
    fi

    if ! command -v mysql > /dev/null 2>&1; then
        warn "未检测到 mysql 客户端，无法自动初始化数据库"
        warn "请在 MySQL 中创建数据库 ${MYSQL_DB} 并手动导入: $schema_file"
        return
    fi

    if [ "$NON_INTERACTIVE" != "true" ]; then
        read -rp "是否自动创建数据库 ${MYSQL_DB} 并导入表结构？(y/N): " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { warn "跳过数据库初始化"; return; }
    fi

    info "创建数据库 ${MYSQL_DB}（若不存在）..."
    mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" \
        -e "CREATE DATABASE IF NOT EXISTS \`${MYSQL_DB}\` DEFAULT CHARACTER SET utf8mb4;" \
        || { warn "数据库创建失败，请检查 MySQL 连接信息"; return; }

    info "导入表结构 $schema_file ..."
    mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DB" < "$schema_file" \
        && success "MySQL 表结构导入完成" \
        || warn "表结构导入失败，请手动导入: $schema_file"
}

# 创建 systemd 服务
create_systemd_service() {
    info "创建 systemd 服务..."
    local start_mode=""
    if [ "$DEPLOY_MODE" = "standalone" ]; then
        start_mode="-m standalone"
    fi

    cat > /etc/systemd/system/nacos.service <<EOF
[Unit]
Description=Nacos Server
After=network.target

[Service]
Type=forking
Environment="JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/default-java}"
ExecStart=${NACOS_INSTALL_DIR}/bin/startup.sh ${start_mode}
ExecStop=${NACOS_INSTALL_DIR}/bin/shutdown.sh
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    if ! systemctl enable nacos; then
        warn "systemd 服务启用失败，可能 systemd 未正确初始化，但服务文件已写入"
    fi
    success "systemd 服务创建完成（服务名: nacos）"
}

# 启动并验证
start_and_verify() {
    info "启动 Nacos 服务..."
    systemctl start nacos
    # Nacos 是 Java 应用，启动较慢，需等待足够时间
    local retries=0
    local max_retries=3
    while [ $retries -lt $max_retries ]; do
        sleep 10
        if systemctl is-active --quiet nacos; then
            success "Nacos 服务已启动"
            return
        fi
        retries=$((retries + 1))
        [ $retries -lt $max_retries ] && info "等待 Nacos 启动中...（${retries}/${max_retries}）"
    done
    warn "Nacos 服务启动超时或未正常运行"
    warn "诊断命令:"
    warn "  systemctl status nacos"
    warn "  journalctl -u nacos -n 50 --no-pager"
    warn "  cat $NACOS_INSTALL_DIR/logs/start.out"
}

# 打印安装总结
print_summary() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}        Nacos 安装完成${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "版本:        ${CYAN}${NACOS_VERSION}${NC}"
    echo -e "部署模式:    ${CYAN}${DEPLOY_MODE}${NC}"
    echo -e "存储库:      ${CYAN}${DB_TYPE}${NC}"
    echo -e "安装目录:    ${CYAN}${NACOS_INSTALL_DIR}${NC}"
    echo -e "控制台地址:  ${CYAN}http://${ip}:${NACOS_PORT}/nacos${NC}"
    echo -e "默认账号:    ${CYAN}nacos / nacos${NC}（首次登录请尽快修改）"
    echo ""
    echo -e "常用命令:"
    echo -e "  启动: ${CYAN}systemctl start nacos${NC}"
    echo -e "  停止: ${CYAN}systemctl stop nacos${NC}"
    echo -e "  状态: ${CYAN}systemctl status nacos${NC}"
    echo -e "  日志: ${CYAN}journalctl -u nacos -f${NC}"
    if [ "$DEPLOY_MODE" = "cluster" ]; then
        echo ""
        warn "集群模式：请在每个节点上执行本脚本，并保持相同的 --nodes 列表和 MySQL 配置"
    fi
    echo -e "${GREEN}========================================${NC}"
}

# ======================== 主流程 ========================

main() {
    parse_args "$@"
    detect_os
    install_base_deps
    check_java
    collect_basic_info
    info "开始安装 Nacos ${NACOS_VERSION} ..."
    choose_mode
    choose_db
    collect_cluster_nodes
    collect_mysql_info
    prepare_package
    deploy_nacos
    configure_application
    configure_cluster
    init_mysql_schema
    create_systemd_service
    start_and_verify
    print_summary
}

main "$@"
