# Kafka 自动化部署脚本使用手册

支持 **KRaft**（无需 Zookeeper）与 **Zookeeper** 两种协调模式的 Kafka 一键安装脚本，均支持 **单机/集群** 部署，Kafka 版本可配置。

> **关于协调模式**：
> - **KRaft**：自 Kafka 3.3 生产可用、3.5+ 推荐。节点同时承担 `broker` 与 `controller` 角色，无需 Zookeeper，部署更简单。
> - **Zookeeper**：传统模式，使用 Kafka 发行包**自带的** Zookeeper（`bin/zookeeper-server-start.sh`），无需单独安装。Kafka 4.0 起已移除 Zookeeper，**仅 Kafka 3.x 及更早版本可用**。脚本会自动校验：在 Kafka ≥ 4.0 上选择 zookeeper 模式会直接报错。

## 脚本说明

| 脚本 | 平台 | 说明 |
|------|------|------|
| `install_kafka.sh` | Linux | 安装脚本，支持 KRaft/Zookeeper × 单机/集群 |
| `uninstall_kafka.sh` | Linux | 卸载脚本（同时清理 kafka 与 zookeeper 服务）|

## 使用前提

- **需要 JDK 11 及以上**（Kafka 3.x 推荐 JDK 11/17）。脚本会检测 `java`，未安装则报错退出。
- **集群模式**：建议 3 个节点（KRaft 奇数个 controller 便于 Raft 选举；Zookeeper 奇数个节点便于过半选举），各节点相关端口需互通。
- 以 **root** 权限运行。

## 安装包获取（本地优先 + 自动下载）

脚本优先使用 `package/` 目录下的安装包，缺失时自动从 Apache 官方下载：

- `package/kafka_<scala版本>-<kafka版本>.tgz`，如 `kafka_2.13-3.9.0.tgz`

官方下载地址：`https://downloads.apache.org/kafka`

> 默认版本 `3.9.0`、Scala `2.13`，可通过 `--version` 与 `--scala` 指定。Zookeeper 模式请保持 3.x 版本。

## 端口说明

| 端口 | 默认值 | 用途 |
|------|--------|------|
| Broker (PLAINTEXT) | 9092 | 客户端连接端口（两种模式通用）|
| Controller | 9093 | KRaft controller 通信端口（仅 KRaft）|
| Zookeeper client | 2181 | Zookeeper 客户端端口（仅 Zookeeper 模式）|

> Zookeeper 集群节点间还会使用 2888（数据同步）与 3888（选举）端口，脚本自动写入 `zoo.cfg`，需保证节点间互通。

## 命令行参数

| 参数 | 说明 |
|------|------|
| `--standalone` | 单机模式部署 |
| `--cluster` | 集群模式部署 |
| `--coord <kraft\|zookeeper>` | 协调模式（默认 kraft）|
| `--version <版本号>` | Kafka 版本（默认 3.9.0）|
| `--scala <版本号>` | Scala 版本（默认 2.13）|
| `--node-id <id>` | 本节点 ID（KRaft 的 node.id / ZK 模式的 broker.id），整数，集群内唯一（默认 1）|
| `--broker-port <端口>` | 客户端连接端口（默认 9092）|
| `--controller-port <端口>` | [KRaft] controller 通信端口（默认 9093）|
| `--advertised-host <host>` | 对外发布地址（默认本机 IP）|
| `--quorum <列表>` | [KRaft] 集群 controller 列表，格式 `id@host:port,...`（KRaft 集群必填）|
| `--cluster-uuid <uuid>` | [KRaft] 集群唯一标识，集群所有节点须一致 |
| `--zk-port <端口>` | [ZK] Zookeeper 客户端端口（默认 2181）|
| `--zk-connect <连接串>` | [ZK] Zookeeper 连接串 `host:port,...`（通常自动生成）|
| `--zk-servers <列表>` | [ZK] Zookeeper 集群节点列表 `host,host,...`（ZK 集群必填）|
| `-h, --help` | 显示帮助 |

> 不带任何参数运行即进入**交互式安装向导**（会依次询问部署模式与协调模式）；带 `--standalone`/`--cluster` 等参数则进入非交互模式，自动跳过所有询问。

## 快速开始（单机）

```bash
# 交互式（会询问协调模式）
bash install_kafka.sh

# 非交互 - KRaft 单机
bash install_kafka.sh --standalone --coord kraft

# 非交互 - Zookeeper 单机（本机同时启动自带 Zookeeper 与 Kafka）
bash install_kafka.sh --standalone --coord zookeeper
```

安装完成后测试：

```bash
# 创建主题
/usr/local/kafka/bin/kafka-topics.sh --create --topic test \
  --bootstrap-server localhost:9092

# 生产消息
/usr/local/kafka/bin/kafka-console-producer.sh --topic test \
  --bootstrap-server localhost:9092

# 消费消息
/usr/local/kafka/bin/kafka-console-consumer.sh --topic test --from-beginning \
  --bootstrap-server localhost:9092
```

## 集群部署 A：KRaft 模式（3 节点示例）

假设三台机器 `192.168.1.10 / .11 / .12`，controller 端口统一 9093。

### 步骤 1：在首节点（node-id=1）安装

```bash
bash install_kafka.sh --cluster --coord kraft --node-id 1 --advertised-host 192.168.1.10 \
  --quorum 1@192.168.1.10:9093,2@192.168.1.11:9093,3@192.168.1.12:9093
```

> 首节点会**自动生成集群 UUID** 并在日志中打印（形如 `已自动生成集群 UUID: xxxxxxxx`）。**请记录这个 UUID**，其余节点必须复用。

### 步骤 2：在其余节点安装（复用 UUID）

```bash
# node 2
bash install_kafka.sh --cluster --coord kraft --node-id 2 --advertised-host 192.168.1.11 \
  --quorum 1@192.168.1.10:9093,2@192.168.1.11:9093,3@192.168.1.12:9093 \
  --cluster-uuid <首节点输出的UUID>

# node 3
bash install_kafka.sh --cluster --coord kraft --node-id 3 --advertised-host 192.168.1.12 \
  --quorum 1@192.168.1.10:9093,2@192.168.1.11:9093,3@192.168.1.12:9093 \
  --cluster-uuid <首节点输出的UUID>
```

### 步骤 3：验证

```bash
# 任意节点执行，查看集群 broker 列表
/usr/local/kafka/bin/kafka-broker-api-versions.sh \
  --bootstrap-server 192.168.1.10:9092 | grep id

# 创建一个 3 副本主题验证集群协同
/usr/local/kafka/bin/kafka-topics.sh --create --topic cluster-test \
  --partitions 3 --replication-factor 3 \
  --bootstrap-server 192.168.1.10:9092
```

### KRaft 集群要点

1. 所有节点必须使用**相同的 `--quorum` 列表**和**相同的 `--cluster-uuid`**。
2. 每个节点的 `--node-id` 必须**唯一**，且与 quorum 列表中的 id 对应。
3. 集群模式下脚本会按节点数自动调整副本因子（`default.replication.factor`、`offsets.topic.replication.factor` 等，上限 3）。
4. 需在**每个节点**上分别执行本脚本。

## 集群部署 B：Zookeeper 模式（3 节点示例）

同样三台机器 `192.168.1.10 / .11 / .12`，Zookeeper 客户端端口统一 2181。脚本会在每个节点上**同时部署该节点的 Zookeeper 与 Kafka broker**。

### 在各节点分别执行（node-id 唯一，zk-servers 一致）

```bash
# node 1（192.168.1.10）
bash install_kafka.sh --cluster --coord zookeeper --node-id 1 \
  --advertised-host 192.168.1.10 \
  --zk-servers 192.168.1.10,192.168.1.11,192.168.1.12

# node 2（192.168.1.11）
bash install_kafka.sh --cluster --coord zookeeper --node-id 2 \
  --advertised-host 192.168.1.11 \
  --zk-servers 192.168.1.10,192.168.1.11,192.168.1.12

# node 3（192.168.1.12）
bash install_kafka.sh --cluster --coord zookeeper --node-id 3 \
  --advertised-host 192.168.1.12 \
  --zk-servers 192.168.1.10,192.168.1.11,192.168.1.12
```

> 脚本根据 `--advertised-host` 在 `--zk-servers` 列表中的位置自动分配 Zookeeper `myid`（写入 `/var/lib/zookeeper/myid`），并生成 `zoo.cfg` 的 `server.N` 行与 broker 的 `zookeeper.connect`。

### 验证

```bash
# 查看 Zookeeper 状态（任意节点）
systemctl status zookeeper

# 查看注册到 ZK 的 broker
echo "ls /brokers/ids" | /usr/local/kafka/bin/zookeeper-shell.sh localhost:2181

# 创建 3 副本主题
/usr/local/kafka/bin/kafka-topics.sh --create --topic cluster-test \
  --partitions 3 --replication-factor 3 \
  --bootstrap-server 192.168.1.10:9092
```

### Zookeeper 集群要点

1. 所有节点必须使用**相同的 `--zk-servers` 列表**（顺序也要一致，以保证 myid 分配正确）。
2. 每个节点的 `--node-id`（即 `broker.id`）必须**唯一**。
3. `--advertised-host` 必须是该节点在 `--zk-servers` 中出现的那个地址，脚本据此匹配 myid。
4. Zookeeper 与 Kafka 均注册为 systemd 服务，kafka 依赖 zookeeper（`After/Requires`），开机自启时顺序正确。
5. 需在**每个节点**上分别执行本脚本。

## 验证与常用命令

下面命令默认使用本脚本的安装路径 `/usr/local/kafka`，连接地址按需替换为实际 `host:9092`。

> **重要：不同 Kafka 版本命令参数有差异**。核心变化是：早期版本主题/消费操作连 **Zookeeper**（`--zookeeper host:2181`），新版本统一改连 **broker**（`--bootstrap-server host:9092`）。下表给出对照，本脚本默认安装 3.9.0，请优先使用 `--bootstrap-server` 写法。

### 版本差异对照

| 操作 | Kafka ≥ 2.2（推荐，含 3.x/4.x） | Kafka < 2.2（老版本，如 2.0/2.1）|
|------|-------------------------------|-------------------------------|
| 创建/删除/查询 topic | `--bootstrap-server host:9092` | `--zookeeper host:2181` |
| 控制台生产者 | `--bootstrap-server host:9092` | `--broker-list host:9092` |
| 控制台消费者 | `--bootstrap-server host:9092` | `--zookeeper host:2181`（0.9 前）|
| 消费者组管理 | `--bootstrap-server host:9092` | `--zookeeper host:2181` |

> - Kafka **2.2~2.4**：`--zookeeper` 与 `--bootstrap-server` 两者都支持（过渡期）。
> - Kafka **3.0+**：彻底移除 `--zookeeper` 选项，只能用 `--bootstrap-server`。
> - 控制台生产者的 `--broker-list` 在 2.5+ 已废弃，统一用 `--bootstrap-server`。

### 1. 创建 Topic

```bash
# Kafka >= 2.2（推荐写法，3.x/4.x 唯一写法）
/usr/local/kafka/bin/kafka-topics.sh --create --topic test \
  --partitions 3 --replication-factor 1 \
  --bootstrap-server localhost:9092

# Kafka < 2.2（老版本，需连 Zookeeper）
/usr/local/kafka/bin/kafka-topics.sh --create --topic test \
  --partitions 3 --replication-factor 1 \
  --zookeeper localhost:2181
```

### 2. 查询 / 查看 Topic

```bash
# 列出所有 topic（Kafka >= 2.2）
/usr/local/kafka/bin/kafka-topics.sh --list --bootstrap-server localhost:9092

# 查看某个 topic 详情（分区、副本、ISR）
/usr/local/kafka/bin/kafka-topics.sh --describe --topic test \
  --bootstrap-server localhost:9092

# Kafka < 2.2 老版本
/usr/local/kafka/bin/kafka-topics.sh --list --zookeeper localhost:2181
/usr/local/kafka/bin/kafka-topics.sh --describe --topic test --zookeeper localhost:2181
```

### 3. 启动生产者（发送消息）

```bash
# Kafka >= 2.5（推荐）
/usr/local/kafka/bin/kafka-console-producer.sh --topic test \
  --bootstrap-server localhost:9092
# 进入交互后逐行输入消息，每行回车即发送，Ctrl+C 退出

# Kafka < 2.5 老版本（旧参数 --broker-list）
/usr/local/kafka/bin/kafka-console-producer.sh --topic test \
  --broker-list localhost:9092
```

### 4. 启动消费者（接收消息）

```bash
# Kafka >= 2.2（推荐），--from-beginning 从最早消息开始消费
/usr/local/kafka/bin/kafka-console-consumer.sh --topic test --from-beginning \
  --bootstrap-server localhost:9092

# 指定消费者组消费
/usr/local/kafka/bin/kafka-console-consumer.sh --topic test \
  --group my-group --bootstrap-server localhost:9092

# Kafka 0.9 之前的老版本（连 Zookeeper，已淘汰）
/usr/local/kafka/bin/kafka-console-consumer.sh --topic test --from-beginning \
  --zookeeper localhost:2181
```

> 验证流程：开两个终端，一个跑生产者输入消息，另一个跑消费者（带 `--from-beginning`），能实时收到即表示集群正常。

### 5. 消费者组管理

```bash
# 列出所有消费者组（Kafka >= 2.2）
/usr/local/kafka/bin/kafka-consumer-groups.sh --list \
  --bootstrap-server localhost:9092

# 查看某个组的消费进度与 Lag（堆积量）
/usr/local/kafka/bin/kafka-consumer-groups.sh --describe --group my-group \
  --bootstrap-server localhost:9092
```

### 6. 删除 Topic

```bash
/usr/local/kafka/bin/kafka-topics.sh --delete --topic test \
  --bootstrap-server localhost:9092
```

### 7. 集群健康检查

```bash
# 查看在线 broker 的 API 版本（间接确认 broker 存活）
/usr/local/kafka/bin/kafka-broker-api-versions.sh \
  --bootstrap-server localhost:9092

# Zookeeper 模式：查看注册到 ZK 的 broker 列表
echo "ls /brokers/ids" | /usr/local/kafka/bin/zookeeper-shell.sh localhost:2181
```

## 目录结构

| 路径 | 说明 |
|------|------|
| `/usr/local/kafka` | 安装目录 |
| `/usr/local/kafka/config/kraft/server.properties` | KRaft 主配置（KRaft 模式）|
| `/usr/local/kafka/config/server.properties` | Kafka 主配置（Zookeeper 模式）|
| `/usr/local/kafka/config/zookeeper.properties` | Zookeeper 配置（Zookeeper 模式）|
| `/var/lib/kafka` | Kafka 数据目录（log.dirs）|
| `/var/lib/zookeeper` | Zookeeper 数据目录（含 myid，Zookeeper 模式）|
| `/etc/systemd/system/kafka.service` | Kafka systemd 服务文件 |
| `/etc/systemd/system/zookeeper.service` | Zookeeper systemd 服务文件（Zookeeper 模式）|

## 服务管理

```bash
systemctl start kafka     # 启动
systemctl stop kafka      # 停止
systemctl restart kafka   # 重启
systemctl status kafka    # 状态
journalctl -u kafka -f    # 实时日志

# Zookeeper 模式额外有 zookeeper 服务
systemctl status zookeeper
journalctl -u zookeeper -f
```

> Zookeeper 模式下 kafka 依赖 zookeeper：`systemctl start kafka` 会自动先拉起 zookeeper；停止时建议先停 kafka 再停 zookeeper。

## 卸载

```bash
bash uninstall_kafka.sh              # 卸载（含 kafka 与 zookeeper 服务），保留数据目录
bash uninstall_kafka.sh --purge-data # 卸载并删除 kafka 与 zookeeper 数据目录
```

## 常见问题

- **启动失败 / `NodeId` 相关报错**：检查 `--node-id` 是否与 `--quorum`（KRaft）中的 id 对应，且各节点不重复。
- **KRaft 集群无法组成 quorum**：确认所有节点 controller 端口（9093）互通，且使用了相同的 cluster UUID。
- **Zookeeper 模式 broker 起不来**：先确认 `systemctl status zookeeper` 正常；集群下检查 `/var/lib/zookeeper/myid` 是否与各节点对应、2888/3888 端口是否互通。
- **Zookeeper myid 分配错误**：确保 `--advertised-host` 是该节点在 `--zk-servers` 列表中的地址，且各节点 `--zk-servers` 列表顺序一致。
- **`zookeeper 模式无法在 Kafka 4.x 使用`**：Kafka 4.0 起已移除 Zookeeper，请改用 KRaft 或指定 3.x 版本（`--version 3.9.0`）。
- **副本因子报错**：单机模式副本因子为 1；集群模式至少需要对应数量的 broker 在线。
- **重新格式化存储（KRaft）**：脚本使用 `--ignore-formatted`，重装时不会因已格式化而报错；若需彻底重置，请先 `uninstall_kafka.sh --purge-data`。
