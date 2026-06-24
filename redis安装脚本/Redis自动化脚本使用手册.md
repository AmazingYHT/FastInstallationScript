# Redis 自动化部署脚本使用手册

支持单机模式和哨兵模式（主从+哨兵高可用）部署，兼容多种Linux发行版。

## 脚本说明

| 脚本 | 说明 |
|------|------|
| `install_redis.sh` | Redis 基础安装，支持单机和哨兵模式 |
| `setup_redis_sentinel.sh` | Sentinel 哨兵模式交互式配置 |
| `uninstall_redis.sh` | Redis 卸载 |

## 使用前提

### 直接使用预编译二进制包

可以把其他机器编译好的 Redis 包放入 `package/` 目录：

```bash
mkdir -p package
# 将编译好的 redis-x.x.x.tar.gz 放入 package/ 目录
# 脚本会自动解压部署，无需重新编译
```

### 兼容性检查

确保目标服务器 glibc 版本 >= 编译机器的 glibc 版本：

```bash
# 查看glibc版本
ldd --version
```

## 快速开始

### 1. 单机模式安装

```bash
# 交互式安装
bash install_redis.sh

# 或者非交互式单机安装
bash install_redis.sh --standalone
```

安装完成后：

```bash
# 查看状态
systemctl status redis

# 连接
/usr/local/redis/bin/redis-cli -p 6379
```

### 2. 哨兵模式（高可用）部署

推荐架构：**1主 + 1从 + 3哨兵**（3台机器，每台都一个redis + 一个哨兵）

#### 在每个节点上执行：

```bash
# 1. 先完成基础安装
bash install_redis.sh --sentinel
```

#### 然后配置各个节点角色：

**在主节点机器上：**
```bash
bash setup_redis_sentinel.sh
# 选择 1=master，输入端口、密码
```

**在从节点机器上：**
```bash
bash setup_redis_sentinel.sh
# 选择 2=slave，输入本节点信息，然后输入主节点的IP和端口密码
```

**在每个哨兵节点（包括主从节点都可以运行哨兵）：**
```bash
bash setup_redis_sentinel.sh
# 选择 3=sentinel，输入哨兵端口，输入主节点信息
```

## 目录结构

| 路径 | 说明 |
|------|------|
| `/usr/local/redis/` | 安装目录（二进制） |
| `/etc/redis/` | 配置目录 |
| `/var/lib/redis/` | 数据目录 |
| `/var/log/redis/` | 日志目录 |
| `/run/redis/` | PID目录 |

## 服务管理

### 单机模式

```bash
systemctl {start|stop|restart|status|enable|disable} redis
```

### 哨兵模式多实例

```bash
# Redis实例（端口 6379 为例）
systemctl {start|stop|restart} redis@6379

# Sentinel实例（端口 26379 为例）
systemctl {start|stop|restart} redis-sentinel@26379
```

## 配置说明

### 端口规划推荐

| 角色 | 推荐端口 |
|------|----------|
| 主节点 | 6379 |
| 从节点1 | 6380 |
| 从节点2 | 6381 |
| 哨兵1 | 26379 |
| 哨兵2 | 26380 |
| 哨兵3 | 26381 |

### Sentinel 配置参数

| 参数 | 说明 | 默认值 |
|------|------|--------|
| quorum | 法定投票数，判定主节点下线需要多少个哨兵同意 | 2 |
| down-after-milliseconds | 多长时间无响应判定为下线 | 30000（30秒）|
| failover-timeout | 故障转移超时 | 180000（3分钟）|
| parallel-syncs | 故障转移后同时有多少个从节点同步新主节点 | 1 |

## 卸载

```bash
bash uninstall_redis.sh
# 根据提示选择是否保留数据文件
```

## 常见问题

**Q: 提示 `version 'GLIBC_2.xx' not found`**

A: 目标服务器glibc版本低于编译机器，需要在更低版本系统上重新编译，或者静态编译Redis。

**Q: 复制预编译包需要注意什么？**

A: 把整个redis源码编译后的目录打包，放入 `package/redis-x.x.x.tar.gz`，脚本会自动解压。确保 `bin/redis-server`、`bin/redis-cli`、`bin/redis-sentinel` 都在压缩包根目录。

**Q: 哨兵模式客户端怎么连接？**

A: 客户端连接Sentinel节点，自动发现主节点。示例：
```python
# Python redis-py 连接哨兵示例
from redis.sentinel import Sentinel
sentinel = Sentinel([('host1', 26379), ('host2', 26380), ('host3', 26381)], socket_timeout=0.1)
master = sentinel.master_for('mymaster', socket_timeout=0.1)
slave = sentinel.slave_for('mymaster', socket_timeout=0.1)
```

**Q: 可以在一台机器上部署全栈测试吗？**

A: 可以，只要端口不冲突，同一机器可以运行多个redis和多个sentinel。
