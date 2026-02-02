# Docker 安装操作手册

> 基于离线安装脚本的 Docker 快速部署指南

---

## 📋 目录

1. [环境准备](#环境准备)
2. [安装 Docker](#安装-docker)
3. [配置说明](#配置说明)
4. [卸载 Docker](#卸载-docker)
5. [常用命令](#常用命令)
6. [常见问题](#常见问题)

---

## 🔧 环境准备

### 系统要求

```
要求项        最低配置        推荐配置
─────────────────────────────────────
操作系统      CentOS 7+      CentOS 7/8/Ubuntu 20.04+
内存          2GB            4GB+
磁盘空间      20GB           50GB+
架构          x86_64         x86_64/ARM64
```

### 目录结构准备

```
项目目录/
├── installDocker.sh              # Docker 安装脚本
├── uninstallDocker.sh            # Docker 卸载脚本
├── package/
│   └── docker-*.tar.gz           # Docker 离线安装包
└── conf/
    ├── docker.service            # Docker systemd 服务文件
    └── docker-compose            # Docker Compose 二进制文件
```

---

## 🚀 安装 Docker

### 方式一：脚本自动安装（推荐）

```bash
# 1. 赋予执行权限
chmod +x installDocker.sh

# 2. 执行安装脚本
sudo ./installDocker.sh

# 3. 输入 Docker 数据存储路径
# 直接回车使用默认路径 /mnt/data/dockerWork
# 或输入自定义路径，如：/data/docker
```

### 安装流程

```
┌─────────────────────────────────────────────────────────────┐
│              Docker 安装流程                                 │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ① 解压 tar 包并赋予权限                                     │
│     ↓                                                        │
│  ② 复制二进制文件到 /usr/bin/                               │
│     ↓                                                        │
│  ③ 复制 docker.service 到 /etc/systemd/system/             │
│     ↓                                                        │
│  ④ 设置 Docker 数据存储路径（可自定义）                      │
│     ↓                                                        │
│  ⑤ 创建 /etc/docker/daemon.json 配置文件                    │
│     ↓                                                        │
│  ⑥ 重载 systemd 并启动 Docker 服务                          │
│     ↓                                                        │
│  ⑦ 安装 Docker Compose                                      │
│     ↓                                                        │
│  ⑧ 验证安装结果                                              │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 验证安装

```bash
# 查看 Docker 版本信息
docker info

# 查看 Docker 版本
docker --version

# 查看 Docker Compose 版本
docker-compose --version

# 运行测试容器
docker run --rm hello-world
```

---

## ⚙️ 配置说明

### daemon.json 配置文件

安装完成后，`/etc/docker/daemon.json` 配置如下：

```json
{
    "data-root": "/mnt/data/dockerWork",
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
        "https://registry.docker-cn.com",
        "https://dockerhub.azk8s.cn",
        "https://docker.mirrors.ustc.edu.cn",
        "https://mirror.ccs.tencentyun.com"
    ]
}
```

### 配置项说明

| 配置项 | 说明 | 默认值 |
|-------|------|-------|
| data-root | Docker 数据存储根目录 | /mnt/data/dockerWork |
| insecure-registries | 允许的 HTTP 私有仓库 | registry.cn-shenzhen.aliyuncs.com |
| registry-mirrors | 镜像加速器列表 | 多个国内加速源 |

### 自定义数据目录

```bash
# 方法一：安装时输入
sudo ./installDocker.sh
# 输入自定义路径，如：/data/docker

# 方法二：修改配置文件
sudo vi /etc/docker/daemon.json

# 修改 data-root 字段
{
    "data-root": "/your/custom/path"
}

# 重启 Docker 服务
sudo systemctl daemon-reload
sudo systemctl restart docker
```

### 服务管理

```bash
# 启动 Docker
sudo systemctl start docker

# 停止 Docker
sudo systemctl stop docker

# 重启 Docker
sudo systemctl restart docker

# 查看状态
sudo systemctl status docker

# 开机自启
sudo systemctl enable docker

# 取消自启
sudo systemctl disable docker
```

---

## 🗑️ 卸载 Docker

### 方式一：脚本自动卸载（推荐）

```bash
# 1. 赋予执行权限
chmod +x uninstallDocker.sh

# 2. 执行卸载脚本
sudo ./uninstallDocker.sh
```

### 卸载流程

```
┌─────────────────────────────────────────────────────────────┐
│              Docker 卸载流程                                 │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ① 停止所有运行中的容器                                      │
│     ↓                                                        │
│  ② 删除所有容器                                              │
│     ↓                                                        │
│  ③ 删除所有镜像                                              │
│     ↓                                                        │
│  ④ 停止 Docker 服务                                          │
│     ↓                                                        │
│  ⑤ 取消开机自启                                              │
│     ↓                                                        │
│  ⑥ 删除 Docker 二进制文件                                    │
│     ↓                                                        │
│  ⑦ 删除 systemd 服务文件                                     │
│     ↓                                                        │
│  ⑧ 删除配置文件和数据目录                                    │
│     ↓                                                        │
│  ⑨ 卸载 Docker Compose                                      │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 卸载详情

**将被删除**：
- ❌ 所有容器
- ❌ 所有镜像
- ❌ Docker 二进制文件（/usr/bin/）
- ❌ Docker 服务文件（/etc/systemd/system/docker.service）
- ❌ Docker 配置（/etc/docker/）
- ❌ Docker 数据目录（daemon.json 中的 data-root）
- ❌ Docker Compose

---

## 📚 常用命令

### 镜像操作

```bash
# 拉取镜像
docker pull nginx:latest

# 查看本地镜像
docker images

# 删除镜像
docker rmi nginx:latest

# 强制删除所有镜像
docker rmi -f $(docker images -q)

# 构建镜像
docker build -t myapp:v1.0 .
```

### 容器操作

```bash
# 运行容器
docker run -d --name mynginx -p 80:80 nginx

# 查看运行中的容器
docker ps

# 查看所有容器
docker ps -a

# 停止容器
docker stop mynginx

# 启动容器
docker start mynginx

# 重启容器
docker restart mynginx

# 删除容器
docker rm mynginx

# 强制删除所有容器
docker rm -f $(docker ps -a -q)

# 查看容器日志
docker logs mynginx

# 进入容器
docker exec -it mynginx /bin/bash
```

### Docker Compose

```bash
# 启动服务
docker-compose up -d

# 停止服务
docker-compose down

# 查看服务状态
docker-compose ps

# 查看服务日志
docker-compose logs -f

# 重启服务
docker-compose restart
```

---

## ❓ 常见问题

### Q1: Docker 服务启动失败？

**排查步骤**：

```bash
# 1. 查看 Docker 服务状态
systemctl status docker

# 2. 查看 Docker 日志
journalctl -u docker -n 50

# 3. 检查配置文件语法
cat /etc/docker/daemon.json

# 4. 检查数据目录权限
ls -la /mnt/data/dockerWork

# 5. 手动启动查看详细错误
dockerd --debug
```

**常见原因**：
- 配置文件 JSON 格式错误
- 数据目录权限不足
- 端口被占用
- 系统资源不足

---

### Q2: 镜像拉取速度慢或失败？

**解决方案**：

```bash
# 1. 检查镜像加速器配置
cat /etc/docker/daemon.json

# 2. 修改镜像加速器
sudo vi /etc/docker/daemon.json

# 推荐的国内加速源
{
    "registry-mirrors": [
        "https://docker.1panel.live",
        "https://docker.m.daocloud.io",
        "https://mirror.baidubce.com"
    ]
}

# 3. 重启 Docker
sudo systemctl daemon-reload
sudo systemctl restart docker

# 4. 测试拉取
docker pull hello-world
```

---

### Q3: 修改 Docker 数据存储路径？

**操作步骤**：

```bash
# 1. 停止 Docker
sudo systemctl stop docker

# 2. 修改配置文件
sudo vi /etc/docker/daemon.json
# 修改 "data-root" 为新路径

# 3. 迁移现有数据（可选）
sudo mv /mnt/data/dockerWork /new/path/dockerWork

# 4. 重启 Docker
sudo systemctl daemon-reload
sudo systemctl start docker

# 5. 验证新路径
docker info | grep "Docker Root Dir"
```

---

### Q4: 容器无法访问外网？

**排查步骤**：

```bash
# 1. 检查防火墙
sudo firewall-cmd --list-all

# 2. 检查 Docker 网络配置
docker network ls
docker network inspect bridge

# 3. 重启 Docker 网络
sudo systemctl restart docker

# 4. 使用 host 网络模式测试
docker run --rm --net=host alpine ping -c 3 baidu.com
```

---

### Q5: 如何清理 Docker 占用空间？

```bash
# 清理未使用的镜像
docker image prune -a

# 清理停止的容器
docker container prune

# 清理未使用的卷
docker volume prune

# 清理未使用的网络
docker network prune

# 一键清理所有未使用资源
docker system prune -a --volumes
```

---

### Q6: Docker 命令需要 sudo？

**解决方案**：

```bash
# 1. 创建 docker 组（如果不存在）
sudo groupadd docker

# 2. 将当前用户添加到 docker 组
sudo usermod -aG docker $USER

# 3. 重新登录或执行
newgrp docker

# 4. 验证（无需 sudo）
docker ps
```

---

### Q7: 如何配置私有镜像仓库？

```bash
# 编辑 daemon.json
sudo vi /etc/docker/daemon.json

# 添加私有仓库配置
{
    "insecure-registries": [
        "192.168.1.100:5000",
        "registry.mycompany.com"
    ]
}

# 重启 Docker
sudo systemctl restart docker

# 登录私有仓库
docker login 192.168.1.100:5000

# 推送镜像
docker tag myapp:latest 192.168.1.100:5000/myapp:latest
docker push 192.168.1.100:5000/myapp:latest
```

---

### Q8: 卸载后重新安装注意事项？

```bash
# 1. 确保完全卸载
sudo ./uninstallDocker.sh

# 2. 检查残留文件
ls -la /usr/bin/docker*
ls -la /etc/systemd/system/docker.service
ls -la /etc/docker/
ls -la /mnt/data/dockerWork

# 3. 手动清理残留（如有）
sudo rm -rf /usr/bin/docker*
sudo rm -rf /etc/systemd/system/docker.service
sudo rm -rf /etc/docker/
sudo rm -rf /mnt/data/dockerWork

# 4. 重新加载 systemd
sudo systemctl daemon-reload

# 5. 重新安装
sudo ./installDocker.sh
```

---

## 📖 附录

### 文件路径对照

| 文件/目录 | 说明 |
|----------|------|
| /usr/bin/docker* | Docker 二进制文件 |
| /usr/local/bin/docker-compose | Docker Compose 二进制文件 |
| /etc/systemd/system/docker.service | Docker systemd 服务文件 |
| /etc/docker/daemon.json | Docker 配置文件 |
| /mnt/data/dockerWork | Docker 数据存储目录（默认） |

### 端口说明

| 端口 | 说明 |
|-----|------|
| 2375 | Docker API（非加密）|
| 2376 | Docker API（加密 TLS）|
| 2377 | Docker Swarm 管理 |

### 相关资源

- Docker 官方文档：https://docs.docker.com/
- Docker Hub：https://hub.docker.com/
- Docker Compose 文档：https://docs.docker.com/compose/

---

## 📞 技术支持

如有问题，请检查：
1. Docker 日志：`journalctl -u docker -n 100`
2. Docker 配置：`cat /etc/docker/daemon.json`
3. 系统日志：`tail -f /var/log/messages`

---

> 📅 文档版本：v1.0
> 🔄 更新日期：2025年
> 📧 适用脚本：installDocker.sh / uninstallDocker.sh
