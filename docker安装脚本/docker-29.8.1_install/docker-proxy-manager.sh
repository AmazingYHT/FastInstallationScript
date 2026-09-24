#!/bin/bash

# 固定配置
DEFAULT_PROXY_IP="127.0.0.1"
DEFAULT_PROXY_PORT="7890"
NO_PROXY_RULE="localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
SYSTEMD_PROXY_DIR="/etc/systemd/system/docker.service.d"
DOCKER_CLIENT_CONFIG_DIR="$HOME/.docker"

# 校验端口号是否为合法数字（1-65535）
validate_port() {
    local port="$1"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        return 1
    fi
    return 0
}

# 校验 IP 地址合法性（支持 IPv4）
validate_ip() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS=.
        read -ra octets <<< "$ip"
        for octet in "${octets[@]}"; do
            if [ "$octet" -gt 255 ]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

# 交互式读取代理 IP 和端口
read_proxy_input() {
    local default_ip="$1"
    local default_port="$2"

    # 读取 IP
    while true; do
        read -p "请输入代理 IP (回车默认 ${default_ip}): " input_ip
        input_ip="${input_ip:-$default_ip}"
        if validate_ip "$input_ip"; then
            break
        else
            echo "❌ IP 格式非法，请重新输入（例如 127.0.0.1）"
        fi
    done

    # 读取端口
    while true; do
        read -p "请输入代理端口 (回车默认 ${default_port}): " input_port
        input_port="${input_port:-$default_port}"
        if validate_port "$input_port"; then
            break
        else
            echo "❌ 端口非法，请输入 1-65535 之间的数字"
        fi
    done

    # 允许用户自定义 NO_PROXY 规则
    read -p "请输入 NO_PROXY 规则 (回车使用默认): " input_no_proxy
    input_no_proxy="${input_no_proxy:-$NO_PROXY_RULE}"

    # 拼接最终代理地址
    PROXY_ADDR="http://${input_ip}:${input_port}"
    echo "ℹ️  当前代理地址：$PROXY_ADDR"
    echo "ℹ️  NO_PROXY 规则：$input_no_proxy"
}

echo "====================================="
echo "       Docker 代理一键管理工具"
echo "====================================="
echo "1. 仅开启Docker守护进程代理（拉镜像专用，不影响容器内部）"
echo "2. 开启完整全局代理（拉镜像+容器内+构建全走代理）"
echo "-------------------------------------"
echo "3. 仅清理 守护进程拉镜像代理配置"
echo "4. 清理 全部全局代理配置（守护进程+客户端）"
echo "5. 退出脚本"
echo "====================================="

read -p "请输入你要执行的操作序号: " CHOICE

case $CHOICE in
    1)
        echo "正在配置Docker守护进程拉镜像专用代理..."
        read_proxy_input "$DEFAULT_PROXY_IP" "$DEFAULT_PROXY_PORT"
        mkdir -p $SYSTEMD_PROXY_DIR
        cat > $SYSTEMD_PROXY_DIR/http-proxy.conf << INNEREOF
[Service]
Environment="HTTP_PROXY=$PROXY_ADDR"
Environment="HTTPS_PROXY=$PROXY_ADDR"
Environment="NO_PROXY=$input_no_proxy"
INNEREOF
        systemctl daemon-reload
        systemctl restart docker
        echo "✅ 守护进程代理配置完成"
        systemctl show docker | grep -i proxy | grep Environment
        ;;

    2)
        echo "正在配置Docker完整全局代理..."
        read_proxy_input "$DEFAULT_PROXY_IP" "$DEFAULT_PROXY_PORT"
        mkdir -p $SYSTEMD_PROXY_DIR
        cat > $SYSTEMD_PROXY_DIR/http-proxy.conf << INNEREOF
[Service]
Environment="HTTP_PROXY=$PROXY_ADDR"
Environment="HTTPS_PROXY=$PROXY_ADDR"
Environment="NO_PROXY=$input_no_proxy"
INNEREOF
        mkdir -p $DOCKER_CLIENT_CONFIG_DIR
        cat > $DOCKER_CLIENT_CONFIG_DIR/config.json << INNEREOF
{
  "proxies": {
    "default": {
      "httpProxy": "$PROXY_ADDR",
      "httpsProxy": "$PROXY_ADDR",
      "noProxy": "$input_no_proxy"
    }
  }
}
INNEREOF
        systemctl daemon-reload
        systemctl restart docker
        echo "✅ 全局代理配置完成"
        echo "守护进程代理状态："
        systemctl show docker | grep -i proxy | grep Environment
        echo "客户端代理配置："
        cat $DOCKER_CLIENT_CONFIG_DIR/config.json
        ;;

    3)
        echo "正在清理守护进程拉镜像专用代理..."
        rm -f $SYSTEMD_PROXY_DIR/http-proxy.conf
        systemctl daemon-reload
        systemctl restart docker
        echo "✅ 守护进程代理已清理，客户端全局代理保留"
        echo "当前守护进程代理状态："
        systemctl show docker | grep -i proxy | grep Environment || echo "无拉镜像代理残留，清理完成"
        ;;

    4)
        echo "正在清理全部全局代理配置..."
        rm -rf $SYSTEMD_PROXY_DIR/http-proxy.conf
        rm -rf $DOCKER_CLIENT_CONFIG_DIR/config.json
        systemctl daemon-reload
        systemctl restart docker
        echo "✅ 所有Docker代理配置已完全清除"
        echo "当前Docker代理状态："
        systemctl show docker | grep -i proxy | grep Environment || echo "无任何代理残留，完全恢复默认状态"
        ;;

    5)
        echo "退出脚本"
        exit 0
        ;;

    *)
        echo "❌ 输入无效，请输入1-5之间的数字"
        exit 1
        ;;
esac
