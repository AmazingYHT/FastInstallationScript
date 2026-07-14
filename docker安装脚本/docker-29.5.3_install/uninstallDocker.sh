#!/bin/bash

echo "停止所有容器服务"
docker stop $(docker ps -a -q)
echo "删除所有容器"
docker rm $(docker ps -a -q)
echo "删除docker所有镜像"
docker rmi -f $(docker images -q)
echo '停止docker服务...'
systemctl stop docker
echo '取消开机自启...'
systemctl disable docker
echo '删除docker相关包...'
cd /usr/bin/ && rm -rf containerd* ctr docker* dockerd runc
echo '取消docker.service注册文件...'
cd /etc/systemd/system/ && rm -rf docker.service

# 获取docker数据目录
DOCKER_WORK_DIR="/mnt/data/dockerWork"
if [ -f "/etc/docker/daemon.json" ]; then
    DATA_ROOT=$(grep -o '"data-root"[[:space:]]*:[[:space:]]*"[^"]*"' /etc/docker/daemon.json | sed 's/"data-root"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
    if [ ! -z "$DATA_ROOT" ]; then
        DOCKER_WORK_DIR="$DATA_ROOT"
    fi
fi

echo "删除docker配置文件...DOCKER_WORK_DIR=$DOCKER_WORK_DIR"
cd /etc/ && rm -rf docker/*
if [ -d "$DOCKER_WORK_DIR" ]; then
    rm -rf "$DOCKER_WORK_DIR"
fi

echo 'yum方式清空docker配置文件...'
yum remove -y docker-ce docker-ce-cli containerd.io
rm -rf /var/lib/docker && rm -rf /var/lib/containerd
echo '重新加载配置文件...'
systemctl daemon-reload
echo 'docker卸载成功！！！'

echo '删除docker-compose...'
rm -rf /usr/local/bin/docker-compose
echo 'docker-compose卸载成功！！！'
