#!/bin/bash
# ============================================================
# Phoenix 批量导入脚本（在 B 机器执行）
# 用法:
#   bash import_tables.sh
# 可选环境变量:
#   ZK=di-zk01
#   DATA_DIR=/mnt/data/di/phoenix/export   (源 CSV 所在目录)
#   WORK=/mnt/data/di/phoenix/work         (中间文件目录)
# 前置:
#   1. 已 source /etc/profile，PHOENIX_HOME 可用
#   2. 已把 A 机器导出的 5 个 csv 放到 DATA_DIR
#   3. Python 2.7（脚本按字节处理，兼容中文文件名）
# 说明:
#   自动完成 清洗杂行/单引号 -> content(hex)转base64 -> 建目标表
#   -> 逐表临时表中转 -> UPSERT SELECT -> 删临时表 -> 行数校验
#   UPSERT 语义，可安全重复执行
# ============================================================
set -e

ZK="${ZK:-di-zk01}"
SCHEMA="p_504"
DATA_DIR="${DATA_DIR:-/mnt/data/di/phoenix/export}"
WORK="${WORK:-/mnt/data/di/phoenix/work}"

if [ -z "$PHOENIX_HOME" ]; then
  echo "请先 source /etc/profile 或 export PHOENIX_HOME"
  exit 1
fi
PSQL="$PHOENIX_HOME/bin/psql.py"
SQLLINE="$PHOENIX_HOME/bin/sqlline.py"

# 待导入的表（顺序/名字需与导出一致）
TABLES=(
  dsrmx2es5hCqt0Xk
  dsaR242QGsnozGhJ
  dsMrFSqbUDcUBevE
  ds2KUqFHFyhlwiPQ
  dsKgUAQsMnBIekl8
)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONVERTER="$SCRIPT_DIR/convert_csv.py"
mkdir -p "$WORK"

# ------------------------------------------------------------
# 1. 生成 CSV 清洗转换脚本 convert_csv.py（Python 2.7）
#    过滤 sqlline 杂行/命令回显、去单引号、content(hex)->base64、
#    表头改大写（临时表列名为大写）
# ------------------------------------------------------------
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
# 2. 建目标表（已存在则跳过）
# ------------------------------------------------------------
DDL="$WORK/create_all.sql"
> "$DDL"
for T in "${TABLES[@]}"; do
  cat >> "$DDL" <<SQLEOF
CREATE TABLE IF NOT EXISTS "$SCHEMA"."$T" (
    "row_key" VARCHAR PRIMARY KEY,
    "file_name" VARCHAR,
    "store_type" TINYINT,
    "content" VARBINARY,
    "insert_time" TIMESTAMP
);
SQLEOF
done
echo "===== 建目标表（IF NOT EXISTS）====="
"$PSQL" "$ZK" "$DDL"

# ------------------------------------------------------------
# 3. 逐表: 转换 -> 临时表 -> 转入目标 -> 删临时表
# ------------------------------------------------------------
i=0
TOTAL=${#TABLES[@]}
for T in "${TABLES[@]}"; do
  i=$((i+1))
  STAGE="DS_STAGE_$i"
  RAW="$DATA_DIR/$T.csv"
  B64="$WORK/$T.b64.csv"

  if [ ! -f "$RAW" ]; then
    echo "缺少文件: $RAW"
    exit 1
  fi

  echo ""
  echo "===== [$i/$TOTAL] $T ====="
  python "$CONVERTER" "$RAW" "$B64"

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

  echo "--- CSV 载入临时表 $STAGE（VARBINARY 按 base64 解码）---"
  "$PSQL" -t "$STAGE" -h in-line "$ZK" "$B64"

  echo "--- 临时表转入 $SCHEMA.$T ---"
  cat > "$WORK/copy_$T.sql" <<SQLEOF
UPSERT INTO "$SCHEMA"."$T"
  ("row_key","file_name","store_type","content","insert_time")
SELECT ROW_KEY, FILE_NAME, STORE_TYPE, CONTENT, INSERT_TIME FROM $STAGE;
SQLEOF
  "$PSQL" "$ZK" "$WORK/copy_$T.sql"

  echo "--- 删除临时表 $STAGE ---"
  "$PSQL" "$ZK" "$DROP_SQL"
done

# ------------------------------------------------------------
# 4. 目标表行数校验
# ------------------------------------------------------------
CHECK="$WORK/count_all.sql"
> "$CHECK"
for T in "${TABLES[@]}"; do
  echo "SELECT '$T' AS TBL, COUNT(*) AS CNT FROM \"$SCHEMA\".\"$T\";" >> "$CHECK"
done
echo "!quit" >> "$CHECK"

echo ""
echo "===== 目标表行数（B 机器）====="
"$SQLLINE" "$ZK" "$CHECK"
echo ""
echo "全部导入完成。请与 A 机器行数/SUM(OCTET_LENGTH(content)) 对比校验。"
