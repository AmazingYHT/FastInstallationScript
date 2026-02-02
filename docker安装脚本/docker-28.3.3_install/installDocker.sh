#!/bin/bash
# 定义字体颜色
RE='\033[1;31m' # Red color code
GR='\033[1;32m' # Green color code
BL='\033[1;34m' # Blue color code
PU='\033[1;35m' # Purple(紫) color code
SK='\033[1;36m' # SkyBlue(天蓝) color code
NC='\033[0m'    # Reset color to normal

echo -e "${PU}######## 开始安装 Docker ########${NC}"

# =============================
# 解压 Tar 包并授权
# =============================
echo '解压 tar 包并赋予权限...'
tar -xvf ./package/docker* -C ./package && chmod 777 ./package/docker/*

# =============================
# 移动二进制文件到系统路径
# =============================
echo '将 Docker 移到 /usr/bin 目录下...'
cp -r ./package/docker/* /usr/bin/

echo '将 docker.service 移到 /etc/systemd/system/ 目录并授权...' 
cp -r ./conf/docker.service /etc/systemd/system/ && chmod 777 /etc/systemd/system/docker.service

# =============================
# 设置 Docker 工作目录（支持自定义路径）
# =============================
echo -e "${PU}请输入 Docker 数据存储路径（默认为 /mnt/data/dockerWork）：${NC}"
read -p "> " CUSTOM_PATH

# 如果未输入，则使用默认路径
if [ -z "$CUSTOM_PATH" ]; then
    DOCKER_DATA_ROOT="/mnt/data/dockerWork"
else
    DOCKER_DATA_ROOT="$CUSTOM_PATH"
fi

# 确保目录存在
if [ ! -d "$DOCKER_DATA_ROOT" ]; then
    echo -e "${PU}检测到目标路径不存在，正在创建目录...${NC}"
    mkdir -p "$DOCKER_DATA_ROOT"
fi

echo -e "${GR}使用的 Docker 数据根路径为：${DOCKER_DATA_ROOT}${NC}"

# =============================
# 创建必要目录并写入配置文件
# =============================
echo '创建 Docker 相关目录...'
mkdir -p /etc/docker

tee /etc/docker/daemon.json <<-EOF
{
    "data-root": "$DOCKER_DATA_ROOT",
    "insecure-registries": [
        "registry.cn-shenzhen.aliyuncs.com"
    ],
    "registry-mirrors": [
        "https://docker.1panel.live",
        "https://hub-mirror.c.163.com",
        "https://docker.m.daocloud.io",
        "https://ghcr.io",
        "https://mirror.baidubce.com",
        "https://docker.nju.edu.cn",
        "https://mirror.baidubce.com",
        "https://registry.docker-cn.com",
        "http://f1361db2.m.daocloud.io",
        "https://dockerhub.azk8s.cn",
        "https://docker.mirrors.ustc.edu.cn",
        "https://ud6340vz.mirror.aliyuncs.com",
        "https://reg-mirror.qiniu.com",
        "https://hub-mirror.c.163.com",
        "https://mirror.ccs.tencentyun.com"
    ]
}
EOF

# =============================
# 启动服务并设置开机自启
# =============================
echo '重新加载 Systemd 配置并重启 Docker...'
systemctl daemon-reload && systemctl restart docker
echo '设置 Docker 开机自启动...'
systemctl enable docker.service

echo '######## Docker 版本信息 ########'
docker info

# =============================
# 安装 Docker Compose
# =============================
echo '将 docker-compose 移到 /usr/local/bin/ 目录...'
cp ./conf/docker-compose* /usr/local/bin/docker-compose && chmod 777 /usr/local/bin/docker-compose

# =============================
# 验证安装结果
# =============================
echo -e "${PU}######## 验证 Docker 安装结果... ########${NC}"
if ! command -v docker &>/dev/null; then
    echo -e "${RE}❌ Docker 安装失败！${NC}"
    exit -1
fi
echo -e "${GR}✅ Docker 安装成功！！！${NC}"

echo -e "${PU}######## 验证 Docker Compose 安装结果... ########${NC}"
if ! command -v docker-compose &>/dev/null; then
    echo -e "${RE}❌ Docker Compose 安装失败...${NC}"
    echo '尝试将 /usr/local/bin 添加到环境变量中...'
    echo 'export PATH="$PATH:/usr/local/bin"' | sudo tee -a /etc/profile > /dev/null
    source /etc/profile
    if ! command -v docker-compose &>/dev/null; then
        echo -e "${RE}❌ Docker Compose 仍然无法找到！${NC}"
        exit -1
    fi
fi
echo -e "${GR}✅ Docker Compose 安装成功！！！${NC}"

# =============================
# 清理临时文件
# =============================
rm -rf ./package/docker

echo -e "${GR}🎉 所有操作已完成！${NC}"
