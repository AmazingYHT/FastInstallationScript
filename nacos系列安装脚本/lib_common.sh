#!/bin/bash

# ============================================================
# lib_common.sh —— 安装脚本通用函数库（Linux）
#
# 供各安装脚本以 source 方式引入，复用公共逻辑：
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib_common.sh"
#
# 提供：
#   - 颜色变量 RED/GREEN/YELLOW/CYAN/NC
#   - 日志函数 info/success/warn/error
#   - require_bash / require_root 环境前置检查
#   - detect_os 操作系统检测（导出 OS / OS_VERSION）
#   - install_base_deps 安装基础依赖（wget tar）
#   - validate_port 端口合法性校验
#   - detect_arch 架构检测（导出 ARCH，映射常见 target）
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

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

# ---------------------- 日志函数 ----------------------
info()    { echo -e "${CYAN}[INFO] $1${NC}"; }
success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }
warn()    { echo -e "${YELLOW}[WARN] $1${NC}"; }
error()   { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

# ---------------------- 环境前置检查 ----------------------
# 要求使用 bash 执行（非 sh）
require_bash() {
    if [ -z "$BASH_VERSION" ]; then
        echo -e "${RED}错误: 请使用 bash 执行此脚本，而不是 sh${NC}"
        exit 1
    fi
}

# 要求 root 权限
require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}此脚本需要以 root 权限运行${NC}"
        exit 1
    fi
}

# ---------------------- 系统检测 ----------------------
# 检测操作系统，导出 OS 与 OS_VERSION
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    else
        error "无法检测操作系统版本"
    fi
    info "检测到操作系统: ${OS:-unknown} ${OS_VERSION:-}"
}

# 检测 CPU 架构，导出 ARCH（x86_64 / aarch64 等原始值）
detect_arch() {
    ARCH=$(uname -m)
    info "检测到 CPU 架构: $ARCH"
}

# ---------------------- 依赖安装 ----------------------
# 安装基础依赖：wget tar。可传入额外包名作为参数。
install_base_deps() {
    local extra="$*"
    info "检查并安装基础依赖..."
    detect_sys_pkg
    if [ -z "$SYS_PKG" ]; then
        warn "未识别的操作系统，跳过依赖安装"
        return
    fi
    if [ "$SYS_FAMILY" = "debian" ]; then
        apt-get update -y || error "apt-get update 失败，请检查网络或软件源配置"
    fi
    sys_pkg_install "wget tar $extra" "wget tar $extra" || error "安装依赖失败，请检查网络或软件源配置"
}

# ---------------------- 校验 ----------------------
# 校验端口是否为有效数字（1-65535）
# 用法: validate_port <端口> <名称>
validate_port() {
    local port="$1" name="$2"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        error "${name} 端口无效: '$port'，请输入 1-65535 之间的数字"
    fi
}

# ---------------------- SELinux 检测 ----------------------
# 在 Rocky/RHEL 等系统上，SELinux Enforcing 可能拦截 systemd 服务访问
# 非标准安装/数据目录。交互式环境下提示用户选择是否关闭。
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
    echo -e "\033[0;33m建议:\033[0m 内网/自建中间件环境通常可关闭 SELinux；若主机暴露公网或有等保合规要求，建议保持开启并自行配置策略。"
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
