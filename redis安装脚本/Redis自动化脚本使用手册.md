# Redis 自动化部署脚本使用手册

支持单机模式和哨兵模式（主从+哨兵高可用）部署，兼容多种Linux发行版。

## 脚本说明

| 脚本 | 说明 |
|------|------|
| `install_redis.sh` | Redis 基础安装（交互 + 无人值守 `--batch`） |
| `setup_redis_sentinel.sh` | 主从 + Sentinel：本机配置 / SSH远程安装 / 一键部署 |
| `setup_redis_cluster.sh` | Redis Cluster 分片：SSH远程安装 / 一键 create |
| `uninstall_redis.sh` | Redis 卸载 |

## 使用前提

### 直接使用预编译二进制包

可以使用源码包，或把已编译好的安装目录打包放入 `package/`：

```bash
mkdir -p package
# 源码包: redis-x.x.x.tar.gz
# 或安装目录打包: redis-x.x.x-linux-x86_64.tar.gz（内含 bin/redis-server）
```

默认脚本期望路径：`package/redis-7.2.4.tar.gz`（与 `install_redis.sh` 中 `REDIS_VERSION` 一致）。

### 源码/编译包下载地址

> 源码包命名：`redis-<版本>.tar.gz`  
> 放到 `redis安装脚本/package/` 后，脚本自动解压编译；也可自行编译后打包安装目录。

**官方下载**

| 类型 | 地址 |
|------|------|
| 官方发行包（推荐） | `https://download.redis.io/releases/` |
| GitHub 标签源码 | `https://github.com/redis/redis/archive/refs/tags/<版本>.tar.gz` |
| 版本列表 / Release | https://github.com/redis/redis/releases |

**常用具体文件（已实测可下载）**

| 安装包 | 下载地址 |
|--------|----------|
| redis-7.2.4.tar.gz（脚本默认） | https://download.redis.io/releases/redis-7.2.4.tar.gz |
| redis-7.2.5.tar.gz | https://download.redis.io/releases/redis-7.2.5.tar.gz |
| redis-7.4.2.tar.gz | https://download.redis.io/releases/redis-7.4.2.tar.gz |
| redis-7.4.9.tar.gz（7.x 推荐） | https://download.redis.io/releases/redis-7.4.9.tar.gz |
| redis-8.0.2.tar.gz | https://download.redis.io/releases/redis-8.0.2.tar.gz |
| redis-8.8.3.tar.gz（8.x 推荐） | https://download.redis.io/releases/redis-8.8.3.tar.gz |
| GitHub 7.2.4 源码 | https://github.com/redis/redis/archive/refs/tags/7.2.4.tar.gz |

**国内加速镜像（已实测）**

| 镜像 | 基址 | 说明 |
|------|------|------|
| **中科大 USTC（推荐）** | `https://mirrors.ustc.edu.cn/redis/` | 与官方文件名一致 |
| 华为云 | `https://mirrors.huaweicloud.com/redis/` | 已实测可下 |
| 清华 TUNA | — | 当前无独立 redis 源码镜像（404） |
| 阿里云 / 腾讯云 | — | 当前无 redis 发行包镜像（404） |

**USTC / 华为 具体文件**

| 安装包 | 下载地址 |
|--------|----------|
| redis-7.2.4.tar.gz | https://mirrors.ustc.edu.cn/redis/redis-7.2.4.tar.gz |
| redis-7.2.4.tar.gz | https://mirrors.huaweicloud.com/redis/redis-7.2.4.tar.gz |

**路径规则**

```text
官方:   https://download.redis.io/releases/redis-{X.Y.Z}.tar.gz
GitHub: https://github.com/redis/redis/archive/refs/tags/{X.Y.Z}.tar.gz
USTC:   https://mirrors.ustc.edu.cn/redis/redis-{X.Y.Z}.tar.gz
华为:   https://mirrors.huaweicloud.com/redis/redis-{X.Y.Z}.tar.gz

本地:   package/redis-{X.Y.Z}.tar.gz
```

**下载示例**

```bash
cd redis安装脚本
mkdir -p package

# 推荐：USTC 加速
curl -L -o package/redis-7.2.4.tar.gz \
  https://mirrors.ustc.edu.cn/redis/redis-7.2.4.tar.gz

# 或官方
curl -L -o package/redis-7.2.4.tar.gz \
  https://download.redis.io/releases/redis-7.2.4.tar.gz

# 校验后安装
bash install_redis.sh
```

> 若改用其他 Redis 版本：下载对应 `redis-X.Y.Z.tar.gz` 放到 `package/`，并同步修改 `install_redis.sh`（及哨兵/集群脚本）中的 `REDIS_VERSION`。

### Redis 7 vs 8 版本对比与选型

> 7.4.9 与 8.8.3 是**两条产品线**，不是同一版本号序列的高低。  
> 要稳、只做缓存/哨兵/Cluster → **7.4.9**；要 JSON/搜索/时序/向量 → **8.8.3**。

#### 版本定位

| | **Redis 7.4.9** | **Redis 8.8.3** |
|--|-----------------|-----------------|
| 大版本 | 7.x 维护尾声补丁 | 8.x 当前功能线 |
| 许可 | RSAL / SSPL | **AGPLv3**（更开源） |
| 功能范围 | 核心 Redis（String/Hash/…、Pub/Sub、Lua/Function、Cluster、Sentinel） | **核心 + 原 Stack 模块**（JSON、Search、TimeSeries、Probabilistic/Bloom 等） |
| 适合 | 传统缓存、队列、会话、主从/哨兵/Cluster | 要用模块能力或跟新版生态 |

#### 主要功能差异（8 相对 7）

| 能力 | 7.4.x | 8.x |
|------|-------|-----|
| String / Hash / List / Set / ZSet | ✅ | ✅ |
| Redis Functions / Lua | ✅ | ✅ |
| Cluster / Sentinel | ✅ | ✅（本脚本场景可继续用） |
| Hash 字段过期 `HEXPIRE` | 7.4 起有 | ✅ |
| **JSON**（`JSON.SET` 等） | 需 Redis Stack 插件 | ✅ **开源内置** |
| **Search / 向量检索** | Stack 插件 | ✅ 内置 |
| **TimeSeries / Bloom 等** | Stack 插件 | ✅ 内置 |
| 吞吐/IO 优化 | 基线 | I/O 线程、客户端淘汰等持续优化 |
| 许可与生态 | 老产品线 | 新主线 |

#### 怎么选？

| 场景 | 建议 |
|------|------|
| 纯缓存 / Session / 消息队列 | **7.4.9** |
| 现网已是 7.2 / 7.4，哨兵或 Cluster 已跑稳 | 先升 **7.4.9**，不急上 8 |
| 需要 JSON、全文/向量、时序，不想再装 Stack | **8.8.3** |
| 新项目、可接受大版本差异 | **8.8.3** |
| 对 AGPL 许可敏感 | 先评估 8.x AGPLv3；否则留 7.x |
| 只要安全补丁、最低变更 | **7.4.9** |

#### 对本仓库脚本的适配

- `install_redis.sh` / Sentinel / Cluster：核心 `redis-server` / `redis-cli` / `redis-sentinel` / cluster **7 与 8 通用**
- 8.x 模块已进主包，**不必**再 `loadmodule`
- 换版本步骤：
  1. 下载并放入 `package/redis-7.4.9.tar.gz` 或 `package/redis-8.8.3.tar.gz`
  2. 修改脚本中 `REDIS_VERSION="7.4.9"` 或 `"8.8.3"`（含哨兵/集群脚本若写死了版本）
- **不要** 7 主 8 从长期混跑；同集群用同大版本

#### 7.4.9 / 8.8.3 下载（已实测）

```text
# 7.4.9
https://download.redis.io/releases/redis-7.4.9.tar.gz
https://mirrors.ustc.edu.cn/redis/redis-7.4.9.tar.gz

# 8.8.3
https://download.redis.io/releases/redis-8.8.3.tar.gz
https://mirrors.ustc.edu.cn/redis/redis-8.8.3.tar.gz
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
bash install_redis.sh --batch --standalone --port 6379
```

安装完成后：

```bash
# 查看状态
systemctl status redis

# 连接
/usr/local/redis/bin/redis-cli -p 6379
```

### 2. 一键主从 + Sentinel（推荐）

在**当前机器**（将作为 Master）执行，SSH 到其他机器完成安装与配置：

```bash
chmod +x install_redis.sh setup_redis_sentinel.sh
sudo ./setup_redis_sentinel.sh
# 选择 1. 一键主从+哨兵部署
```

交互会依次询问：

1. 全局 SSH 信息（用户/端口/密码或私钥）
2. **从库列表**：IP + SSH端口 + SSH用户/密码 + Redis端口 + Redis密码（可多台，回车结束）
3. 是否部署 Sentinel；哨兵节点列表（可与从库同机）
4. 本机 Master 端口/密码

确认后自动：

1. 本机安装 Redis 并配置为 Master
2. 打包已编译安装目录到 `package/`
3. `scp` 安装包 + `install_redis.sh` 到各从库/哨兵机
4. SSH 执行 `install_redis.sh --batch --sentinel --tgz ... --skip-start`
5. 从库写入 `replicaof 主库IP 端口`
6. 主库与各节点写入 Sentinel 配置并启动
7. 检查 `role` / `master_link_status` / Sentinel master 信息

命令行入口：

```bash
sudo ./setup_redis_sentinel.sh one      # 一键部署
sudo ./setup_redis_sentinel.sh master   # 仅本机主节点
sudo ./setup_redis_sentinel.sh status   # 查看集群状态
sudo ./setup_redis_sentinel.sh reset    # 重置本机角色配置
sudo ./setup_redis_sentinel.sh install  # 仅本机安装
sudo ./setup_redis_sentinel.sh help     # 帮助
```

依赖：
- 本机 root
- 可 SSH 登录远程 root（密钥，或密码 + `sshpass`）
- 远程具备 systemd

### 3. 一键 Redis Cluster（分片）

适合数据量大、需要水平扩展的场景。最少 **3 主**，生产建议 **3主+3从**（6 节点）。

```bash
chmod +x setup_redis_cluster.sh
sudo ./setup_redis_cluster.sh
# 选择 1. 一键部署 Redis Cluster
```

交互会询问：

1. 全局 SSH 信息
2. 本机是否作为数据节点
3. 各节点：IP + SSH端口/密码 + Redis端口/密码（可多台）
4. 每个主节点的副本数 `replicas`（默认 1）

自动流程：

1. 本机 `install_redis.sh --batch --cluster`（写入 `cluster-enabled yes`）
2. 打包安装目录，scp 到各节点
3. 远程 batch 安装并启动 `redis@端口`
4. 在本机执行 `redis-cli --cluster create ... --cluster-replicas N --cluster-yes`
5. 校验 `cluster_state:ok` 与 slots 覆盖

命令行入口：

```bash
sudo ./setup_redis_cluster.sh one      # 一键部署
sudo ./setup_redis_cluster.sh node     # 仅本机节点
sudo ./setup_redis_cluster.sh status   # 查看集群状态
sudo ./setup_redis_cluster.sh reset    # 重置本机
sudo ./setup_redis_cluster.sh help
```

注意事项：

- **总线端口 = Redis端口 + 10000**（如 6379 → 16379），防火墙需放行
- 客户端连接必须加 `-c`：`redis-cli -c -h IP -p 6379 -a PASS`
- 节点数需满足 `N >= 3 * (1 + replicas)`，否则 create 可能失败

### 4. 仍可按节点手动配置

```bash
# 每台先装基础环境
bash install_redis.sh --batch --sentinel --skip-start
# 或 Cluster：
bash install_redis.sh --batch --cluster --skip-start

# 本机
sudo ./setup_redis_sentinel.sh master
# 或
sudo ./setup_redis_cluster.sh node
```

推荐架构：
- 高可用读写：**1主 + 1从 + 3哨兵**
- 分片扩展：**3主 + 3从 Cluster**

## 无人值守安装参数

```bash
# 本机安装（主从场景先不启动）
bash install_redis.sh --batch --sentinel --port 6379 --password 'xxx' --skip-start

# Cluster 节点
bash install_redis.sh --batch --cluster --port 6379 --password 'xxx' --skip-start

# 远程离线安装（使用打包好的安装目录）
bash install_redis.sh --batch --cluster \
  --tgz /tmp/redis-7.2.4-linux-x86_64.tar.gz \
  --install-dir /usr/local/redis \
  --port 6379 --password 'xxx' --skip-start
```

| 参数 | 说明 |
|------|------|
| `--batch` | 无人值守 |
| `--standalone` / `--sentinel` / `--cluster` | 部署模式 |
| `--tgz` | 指定源码包或已编译目录打包 |
| `--install-dir` | 安装目录 |
| `--port` / `--password` / `--bind` | 实例参数 |
| `--cluster-node-timeout` | 集群节点超时 ms（默认 5000） |
| `--skip-start` | 只安装不启动 |
| `--pack` | 将本机已安装目录打包到 `package/` |

安装状态写入 `/etc/redis_install.conf`。

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

**Q: Redis 该用 7 还是 8？**

A: 见上文「Redis 7 vs 8 版本对比与选型」。传统缓存/哨兵/Cluster 选 **7.4.9**；要 JSON/Search/向量或新项目选 **8.8.3**。

**Q: 源码包从哪里下载？**

A: 见上文「源码/编译包下载地址」。优先 USTC 镜像或 `https://download.redis.io/releases/`，放到 `package/redis-<版本>.tar.gz`。

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
