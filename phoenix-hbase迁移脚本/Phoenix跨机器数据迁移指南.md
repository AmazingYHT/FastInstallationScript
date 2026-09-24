# Phoenix 跨机器数据迁移指南

## 推荐：统一迁移脚本（整库 / 多库 / 指定表）

`phoenix_migrate.sh` 不再写死表清单，导出/导入均支持以下粒度：

| 能力 | 命令示例 | 说明 |
|---|---|---|
| **导出全部业务库** | `export --all-schemas` | 自动发现所有非系统库并导出全表 |
| **导出指定库** | `export -s p_504` | 该库下全部表 |
| **导出多库** | `export -s db1,db2,db3` | 逗号分隔多个库，每库全表 |
| **导出指定库+表** | `export -s p_504 -t 表1,表2` | 只导出所选表 |
| **导入全部库** | `import --all-schemas` | 导入 `OUT_DIR` 下所有含 `_manifest.txt` 的库 |
| **导入指定库/表** | `import -s db -t 表1,表2` | 同名或 `--dst-schema` |
| 动态 DDL | — | 从 `SYSTEM.CATALOG` 读列类型/主键，兼容 VARBINARY |

### 命令速查（导出）

```bash
source /etc/profile

# 查看有哪些库 / 某库下的表
bash phoenix_migrate.sh list-schemas
bash phoenix_migrate.sh list-tables -s p_504

# 1) 导出全部业务库（全表）
bash phoenix_migrate.sh export --all-schemas

# 2) 导出指定库（全表）
bash phoenix_migrate.sh export -s p_504

# 3) 导出指定库 + 指定表
bash phoenix_migrate.sh export -s p_504 -t dsrmx2es5hCqt0Xk,dsaR242QGsnozGhJ

# 4) 导出多个库（每库全表）
bash phoenix_migrate.sh export -s p_504,p_2340,db3

# 5) 全部库时可追加排除列表（默认已排除 SYSTEM、INFORMATION_SCHEMA）
bash phoenix_migrate.sh export --all-schemas --exclude SYSTEM,INFORMATION_SCHEMA,TEMP
```

### 命令速查（导入）

```bash
# 导入全部库（需先 scp 导出目录/总包到目标机）
bash phoenix_migrate.sh import --all-schemas

# 导入指定库（同名 schema）
bash phoenix_migrate.sh import -s p_504

# 导入多个库
bash phoenix_migrate.sh import -s p_504,p_2340

# 导入指定库 + 表；可改目标 schema（仅单库时可用 --dst-schema）
bash phoenix_migrate.sh import -s p_504 -t 表1,表2 --dst-schema p_2340
```

### 拷贝到目标机

```bash
# 单库目录
scp -r /mnt/data/di/phoenix/export/p_504 <B>:/mnt/data/di/phoenix/export/

# 多库总包（--all-schemas 或 -s 多库 时生成）
scp /mnt/data/di/phoenix/export/multi_export_*.tar.gz <B>:/mnt/data/di/phoenix/export/
# 目标机解压
# tar -xzf multi_export_*.tar.gz -C /mnt/data/di/phoenix/export/
```

环境变量可覆盖默认：

```bash
ZK=di-zk01 \
OUT_DIR=/mnt/data/di/phoenix/export \
WORK=/mnt/data/di/phoenix/work \
bash phoenix_migrate.sh export -s p_504
```

导出目录结构示例：

```
export/p_504/
  _manifest.txt      # schema/表清单/时间
  _columns.csv       # 列元数据（类型、主键）
  表名1.csv
  表名2.csv
  ...
export/p_504_export_时间戳.tar.gz   # 可选打包
```

导入会自动：

1. 读 `_columns.csv` 重建 `CREATE TABLE IF NOT EXISTS`（缺元数据时按 CSV 表头兜底建表）
2. 大字段（VARBINARY）hex→base64
3. 临时表中转 + `UPSERT SELECT`（可重复执行）
4. 打印目标表行数

目标机若无 namespace，导入脚本会尝试通过 `hbase shell create_namespace` **自动创建**；若环境无 hbase CLI，则仍需手动：

```bash
hbase shell
create_namespace 'p_504'
```

### 脚本清单

| 文件 | 机器 | 作用 |
|---|---|---|
| `phoenix_migrate.sh` | A/B | **统一入口**：list / export / import |
| `export_tables.sh` | A | 旧版：固定 5 张表批量导出 |
| `import_tables.sh` | B | 旧版：固定 5 张表导入（硬编码 DDL） |
| `single_export.sh` | A | 单表导出（跨 schema 示例） |
| `single_import.sh` | B | 单表导入（跨 schema 示例） |

> 新项目优先用 `phoenix_migrate.sh`；旧版 5 表脚本仍可按后文使用。

### 环境特性与踩坑记录（脚本已适配）

1. sqlline 只支持 `!outputformat csv`，**不支持 `csv2`**；导出文件含杂行，导入时过滤。
2. sqlline 的 csv 字段带**单引号**，转换时按 `'` 解析并去除。
3. 老版本 psql 对带 schema 的小写表名有 bug：不能直接 CSV loader 写目标表，需**默认 schema 大写临时表中转**。
4. CSV loader 的 VARBINARY 默认 **Base64** 解码；源导出为 **hex**，导入前必须 hex→base64。
5. 老版本 SQL 不支持 `X'hex'` / `TO_BINARY`。
6. 二进制字节长度用 `OCTET_LENGTH()`，不要用 `LENGTH()`。
7. 导入为 **UPSERT**，主键覆盖，可安全重跑。
8. 大字段 UPSERT 建议放大 scanner/rpc/query 超时（导入脚本已自动 overlay `hbase-site.xml`）。
9. 服务器多为 Python 2.7，转换脚本按字节处理。

---

# 旧版：p_504 固定五张表迁移

适用场景：将 A 机器 HBase Phoenix 中 `p_504` schema 下的 5 张表导出，导入 B 机器同构表。数据量小（单表约 7 行起，含 VARBINARY 大字段）。

## 一、迁移对象

- ZK：`di-zk01`
- 表（schema `p_504`，表名大小写敏感，**SQL 中必须带双引号**）：

| 表名 |
|---|
| dsrmx2es5hCqt0Xk |
| dsaR242QGsnozGhJ |
| dsMrFSqbUDcUBevE |
| ds2KUqFHFyhlwiPQ |
| dsKgUAQsMnBIekl8 |

表结构（5 张表一致）：

```sql
CREATE TABLE "p_504"."xxx" (
    "row_key" VARCHAR PRIMARY KEY,
    "file_name" VARCHAR,
    "store_type" TINYINT,
    "content" VARBINARY,
    "insert_time" TIMESTAMP
);
```

## 二、操作步骤（旧版固定表）

### 步骤 1：A 机器批量导出

```bash
source /etc/profile
bash export_tables.sh
# 或: ZK=di-zk01 OUT_DIR=/mnt/data/di/phoenix/export bash export_tables.sh
```

### 步骤 2：拷贝 CSV 到 B 机器

```bash
scp /mnt/data/di/phoenix/export/*.csv <B机器>:/mnt/data/di/phoenix/export/
```

### 步骤 3：B 机器批量导入

```bash
source /etc/profile
bash import_tables.sh
```

### 步骤 4：结果校验

对比两边 `COUNT(*)` 与 `SUM(OCTET_LENGTH("content"))`。

## 三、常见问题

- **建表报 schema/namespace 错误**：先 `create_namespace 'p_504'`，再重跑导入。
- **某张表中途失败**：直接重跑导入，UPSERT 可覆盖。
- **converted rows 为 0**：检查原始 CSV 是否夹杂框线或列数不对。
- **建议**：首次可只放 1 个 CSV 跑通，再放齐批量。

---

# 单表跨 Schema 迁移

示例：`p_504.dsz8y4YfNx4nSLy4` → `p_2340.dsz8y4YfNx4nSLy4`

| 文件 | 机器 | 作用 |
|---|---|---|
| `single_export.sh` | A | 单表导出 |
| `single_import.sh` | B | 单表导入（可改 DST_SCHEMA） |

或直接用统一脚本：

```bash
bash phoenix_migrate.sh export -s p_504 -t dsz8y4YfNx4nSLy4
bash phoenix_migrate.sh import -s p_504 -t dsz8y4YfNx4nSLy4 --dst-schema p_2340
```

手动导出备选（脚本 outputformat 未生效时）：

```sql
!outputformat csv
!record /path/table.csv
SELECT * FROM "p_504"."dsz8y4YfNx4nSLy4";
!record
!quit
```

## 前置条件

1. 源/目标机已安装 Phoenix，`PHOENIX_HOME` 可用（`source /etc/profile`）
2. 目标机有 `python`（兼容 2.7）
3. 导入前目标 schema 对应 HBase namespace 已存在

```bash
hbase shell
create_namespace 'p_504'
# create_namespace 'p_2340'
```

脚本依次执行：

1. `CREATE TABLE IF NOT EXISTS "p_2340"."dsz8y4YfNx4nSLy4"`（若提示 namespace 不存在，先在 hbase shell 执行 `create_namespace 'p_2340'`，再重跑）；
2. 生成并运行 `convert_csv_single.py`：过滤杂行、去单引号、表头大写、content 由 hex 转 base64；
3. CSV 载入临时表 `DS_STAGE_SINGLE`；
4. `UPSERT ... SELECT` 从临时表转入目标表，随后删除临时表；
5. 打印目标表 `COUNT(*)` 与 `SUM(OCTET_LENGTH("content"))`。

## 步骤 4：校验

脚本结尾的 `CNT`（行数）和 `BYTES`（content 总字节数）与 A 机器对比：

```bash
$PHOENIX_HOME/bin/sqlline.py di-zk01
```

```sql
SELECT COUNT(*), SUM(OCTET_LENGTH("content")) FROM "p_504"."dsz8y4YfNx4nSLy4";
!quit
```

A、B 两边行数与字节数一致即迁移成功。脚本为 UPSERT 语义，可安全重复执行。

## 迁移其它单表

复制脚本后只改顶部变量即可：`ZK`、`SRC_SCHEMA`、`DST_SCHEMA`、`TABLE`；若表结构不同，同步修改 `single_import.sh` 中「步骤 2 建目标表」的 DDL 与临时表 DDL（列名/类型保持一致）。
