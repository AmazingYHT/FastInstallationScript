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
    case "$OS" in
        ubuntu|debian)
            apt-get update -y || error "apt-get update 失败，请检查网络或软件源配置"
            apt-get install -y wget tar $extra || error "安装依赖失败，请检查网络或软件源配置"
            ;;
        centos|rhel|rocky|almalinux)
            dnf install -y wget tar $extra || error "安装依赖失败，请检查网络或软件源配置"
            ;;
        *)
            warn "未识别的操作系统，跳过依赖安装"
            ;;
    esac
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
