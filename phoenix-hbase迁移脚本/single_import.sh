#!/bin/bash
# ============================================================
# 单表导入脚本（在 B 目标机器执行）
# 示例: p_504.dsz8y4YfNx4nSLy4  ->  p_2340.dsz8y4YfNx4nSLy4
# 用法: bash single_import.sh
# ============================================================
set -e

# ===== 按需修改这些变量 =====
ZK="di-zk01"                 # B 机器自己的 zk，若不同请修改
SRC_SCHEMA="p_504"           # 仅用于文件名/注释
DST_SCHEMA="p_2340"          # 目标 schema
TABLE="dsz8y4YfNx4nSLy4"
DATA_DIR="/mnt/data/di/phoenix/export"   # 源 csv 所在目录（A 拷过来的）
WORK="/mnt/data/di/phoenix/work"
# 临时表名（默认 schema，大写，避免小写表名/带 schema 的 psql bug）
STAGE="DS_STAGE_SINGLE"
# ============================

if [ -z "$PHOENIX_HOME" ]; then
  echo "请先 source /etc/profile 或 export PHOENIX_HOME"
  exit 1
fi
PSQL="$PHOENIX_HOME/bin/psql.py"
SQLLINE="$PHOENIX_HOME/bin/sqlline.py"

RAW="$DATA_DIR/$TABLE.csv"
B64="$WORK/$TABLE.b64.csv"
mkdir -p "$WORK"

if [ ! -f "$RAW" ]; then
  echo "缺少源文件: $RAW（请先从 A 机器 scp 过来）"
  exit 1
fi

# ------------------------------------------------------------
# 0. 生成超时放大版 hbase-site.xml，避免大字段 UPSERT SELECT 时
#    Scanner lease expired (UnknownScannerException)
#    scanner 20min / rpc 10min / phoenix 查询 30min
# ------------------------------------------------------------
CONF_OVERLAY="$WORK/hbase-conf"
mkdir -p "$CONF_OVERLAY"
OLD_CONF_DIR="${HBASE_CONF_DIR:-/etc/hbase/conf}"
if [ -f "$OLD_CONF_DIR/hbase-site.xml" ]; then
  cp "$OLD_CONF_DIR/hbase-site.xml" "$CONF_OVERLAY/hbase-site.xml"
fi

python - "$CONF_OVERLAY/hbase-site.xml" <<'PYEOF'
# -*- coding: utf-8 -*-
import sys, os
path = sys.argv[1]
props = [
    ('hbase.client.scanner.timeout.period', '1200000'),
    ('hbase.rpc.timeout', '600000'),
    ('phoenix.query.timeoutMs', '1800000'),
]
xml = ''
if os.path.exists(path):
    with open(path, 'rb') as f:
        xml = f.read()
blocks = ''.join(
    '  <property><name>%s</name><value>%s</value></property>\n' % (k, v)
    for k, v in props)
if '</configuration>' in xml:
    xml = xml.replace('</configuration>', blocks + '</configuration>')
else:
    xml = '<?xml version="1.0"?>\n<configuration>\n' + blocks + '</configuration>\n'
with open(path, 'wb') as f:
    f.write(xml)
print('hbase-site overlay ready: ' + path)
PYEOF

# 后续所有 psql/sqlline 子进程都使用该覆盖配置
export HBASE_CONF_DIR="$CONF_OVERLAY"
echo "===== 0/5 已放大 scanner/rpc/query 超时（HBASE_CONF_DIR=$HBASE_CONF_DIR）====="

# ------------------------------------------------------------
# 1. 生成 convert_csv.py（Python 2.7）
#    过滤杂行/命令回显、去单引号、content(hex)->base64、表头改大写
# ------------------------------------------------------------
CONVERTER="$WORK/convert_csv_single.py"
cat > "$CONVERTER" <<'PYEOF'
# -*- coding: utf-8 -*-
# 入参: 原始csv  输出b64.csv
import csv, sys, base64, re

csv.field_size_limit(sys.maxsize)
src, dst = sys.argv[1], sys.argv[2]

junk = re.compile(r'^\s*(\d+/\d+|Saving all output|Recording stopped)')
sel  = re.compile(r'^\s*\d+\s+rows?\s+selected')

def is_hex(s):
    if not s or len(s) % 2 != 0:
        return False
    try:
        s.decode('hex')
        return True
    except Exception:
        return False

n = 0
with open(src, 'rb') as f, open(dst, 'wb') as o:
    w = csv.writer(o)
    w.writerow(['ROW_KEY', 'FILE_NAME', 'STORE_TYPE', 'CONTENT', 'INSERT_TIME'])
    for line in f:
        if junk.match(line) or sel.match(line):
            continue
        try:
            row = next(csv.reader([line], quotechar="'", skipinitialspace=True))
        except Exception:
            continue
        if len(row) != 5:
            continue
        rk, fn, st, ct, ts = [c.strip() for c in row]
        if rk.lower() == 'row_key':
            continue
        if not is_hex(ct):
            continue
        ct = base64.b64encode(ct.decode('hex'))
        w.writerow([rk, fn, st, ct, ts])
        n += 1
print('converted rows: %d' % n)
PYEOF

# ------------------------------------------------------------
# 2. 建目标表（按需修改 DDL；表已存在则跳过）
# ------------------------------------------------------------
DDL="$WORK/create_target_$TABLE.sql"
cat > "$DDL" <<SQLEOF
CREATE TABLE IF NOT EXISTS "$DST_SCHEMA"."$TABLE" (
    "row_key" VARCHAR PRIMARY KEY,
    "file_name" VARCHAR,
    "store_type" TINYINT,
    "content" VARBINARY,
    "insert_time" TIMESTAMP
);
SQLEOF

echo "===== 1/5 建目标表 $DST_SCHEMA.$TABLE ====="
"$PSQL" "$ZK" "$DDL" || {
  echo "[提示] 若报 namespace/schema 不存在，先在 hbase shell 执行: create_namespace '$DST_SCHEMA'，再重跑本脚本"
  exit 1
}

# ------------------------------------------------------------
# 3. 转换 CSV
# ------------------------------------------------------------
echo "===== 2/5 清洗转换 CSV ====="
python "$CONVERTER" "$RAW" "$B64"
head -2 "$B64" | cut -c1-120

# ------------------------------------------------------------
# 4. 建临时表并载入
# ------------------------------------------------------------
echo "===== 3/5 CSV 载入临时表 $STAGE ====="
DROP_SQL="$WORK/drop_$STAGE.sql"
echo "DROP TABLE IF EXISTS $STAGE;" > "$DROP_SQL"
"$PSQL" "$ZK" "$DROP_SQL" || true

cat > "$WORK/create_$STAGE.sql" <<SQLEOF
CREATE TABLE $STAGE (
    ROW_KEY VARCHAR PRIMARY KEY,
    FILE_NAME VARCHAR,
    STORE_TYPE TINYINT,
    CONTENT VARBINARY,
    INSERT_TIME TIMESTAMP
);
SQLEOF
"$PSQL" "$ZK" "$WORK/create_$STAGE.sql"
"$PSQL" -t "$STAGE" -h in-line "$ZK" "$B64"

# ------------------------------------------------------------
# 5. 转入目标表
# ------------------------------------------------------------
echo "===== 4/5 临时表转入 $DST_SCHEMA.$TABLE ====="
cat > "$WORK/copy_$TABLE.sql" <<SQLEOF
UPSERT INTO "$DST_SCHEMA"."$TABLE"
  ("row_key","file_name","store_type","content","insert_time")
SELECT ROW_KEY, FILE_NAME, STORE_TYPE, CONTENT, INSERT_TIME FROM $STAGE;
SQLEOF
"$PSQL" "$ZK" "$WORK/copy_$TABLE.sql"

echo "--- 删除临时表 ---"
"$PSQL" "$ZK" "$DROP_SQL"

# ------------------------------------------------------------
# 6. 校验
# ------------------------------------------------------------
echo "===== 5/5 校验目标表 ====="
cat > "$WORK/check_$TABLE.sql" <<SQLEOF
SELECT COUNT(*) AS CNT, SUM(OCTET_LENGTH("content")) AS BYTES FROM "$DST_SCHEMA"."$TABLE";
!quit
SQLEOF
"$SQLLINE" "$ZK" "$WORK/check_$TABLE.sql"

echo ""
echo "导入完成: $SRC_SCHEMA.$TABLE -> $DST_SCHEMA.$TABLE"
