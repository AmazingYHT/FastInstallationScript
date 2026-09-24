#!/bin/bash
# ============================================================
# Phoenix 跨机器数据迁移统一脚本
# 支持：整库(schema)导出/导入、指定表导出/导入、多库全表导出/导入
# 兼容老 Phoenix + Python 2.7 环境
#
# 用法:
#   bash phoenix_migrate.sh list-schemas
#   bash phoenix_migrate.sh list-tables  -s p_504
#   bash phoenix_migrate.sh export       -s p_504
#   bash phoenix_migrate.sh export       -s p_504 -t tbl1,tbl2
#   bash phoenix_migrate.sh export       -s p_504,p_2340,db3          # 多库
#   bash phoenix_migrate.sh export       --all-schemas                # 全部业务库
#   bash phoenix_migrate.sh import       -s p_504
#   bash phoenix_migrate.sh import       -s p_504 -t tbl1,tbl2 --dst-schema p_2340
#   bash phoenix_migrate.sh import       -s p_504,p_2340
#   bash phoenix_migrate.sh import       --all-schemas
#
# 环境变量（可覆盖默认值）:
#   ZK, OUT_DIR, WORK, PHOENIX_HOME
# 前置: source /etc/profile，PHOENIX_HOME 可用；目标机需 Python 2.7
# 说明:
#   导出: 动态发现表/列元数据 -> SELECT * 导出 CSV
#   导入: 读元数据重建 DDL -> 临时表中转 -> UPSERT（可重复执行）
#   多库: OUT_DIR 下每个 schema 一个子目录；--all-schemas 自动排除 SYSTEM
# ============================================================
set -e

# ---------- 默认配置 ----------
ZK="${ZK:-di-zk01}"
OUT_DIR="${OUT_DIR:-/mnt/data/di/phoenix/export}"
WORK="${WORK:-/mnt/data/di/phoenix/work}"
DEST_SCHEMA_OVERRIDE=""
SCHEMA=""
TABLES=""
ACTION=""
STAGE_PREFIX="DS_STAGE"
ALL_SCHEMAS=0
EXCLUDE_SCHEMAS="SYSTEM,INFORMATION_SCHEMA"

# ---------- 工具 ----------
usage() {
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

die() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo -e "\033[0;36m[INFO] $*\033[0m"; }
ok() { echo -e "\033[0;32m[OK] $*\033[0m"; }
warn() { echo -e "\033[1;33m[WARN] $*\033[0m"; }

require_env() {
  [ -n "$PHOENIX_HOME" ] || die "请先 source /etc/profile 或 export PHOENIX_HOME"
  [ -x "$PHOENIX_HOME/bin/sqlline.py" ] || die "找不到 $PHOENIX_HOME/bin/sqlline.py"
  command -v python >/dev/null 2>&1 || die "需要 python（目标机为 Python 2.7）"
}

# 参数解析
parse_args() {
  ACTION="${1:-}"
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--schema) SCHEMA="$2"; shift 2 ;;
      -t|--tables|--table) TABLES="$2"; shift 2 ;;
      -o|--out-dir) OUT_DIR="$2"; shift 2 ;;
      -w|--work) WORK="$2"; shift 2 ;;
      -z|--zk) ZK="$2"; shift 2 ;;
      --dst-schema|--dst) DEST_SCHEMA_OVERRIDE="$2"; shift 2 ;;
      -a|--all-schemas|--all) ALL_SCHEMAS=1; shift ;;
      --exclude) EXCLUDE_SCHEMAS="$2"; shift 2 ;;
      -h|--help) usage ;;
      *) die "未知参数: $1（-h 查看帮助）" ;;
    esac
  done
}

# 拆分逗号分隔的 schema 列表 -> 数组（写入全局 SCHEMA_ARR）
# 若 ALL_SCHEMAS=1，则从元数据动态获取并排除 EXCLUDE_SCHEMAS
build_schema_list() {
  SCHEMA_ARR=()
  if [ "$ALL_SCHEMAS" = "1" ]; then
    require_env
    local sql="$WORK/_all_schemas.sql"
    mkdir -p "$WORK"
    cat > "$sql" <<'EOF'
!outputformat csv
SELECT DISTINCT TABLE_SCHEM FROM SYSTEM.CATALOG
WHERE TABLE_SCHEM IS NOT NULL
  AND TABLE_SCHEM NOT IN ('SYSTEM','INFORMATION_SCHEMA')
ORDER BY 1;
!quit
EOF
    local line
    while IFS= read -r line; do
      line=$(echo "$line" | tr -d '\r' | sed "s/^['\"]//;s/['\"]\$//")
      [ -z "$line" ] && continue
      case ",${EXCLUDE_SCHEMAS}," in
        *",${line},"*) continue ;;
      esac
      SCHEMA_ARR+=("$line")
    done < <(run_sqlline "$sql" 2>/dev/null | grep -v -E '^(Saving|Recording|Scanning|^[0-9]+/[0-9]+|N rows selected|\s*$)')
    [ ${#SCHEMA_ARR[@]} -gt 0 ] || die "--all-schemas 未发现可导出的 schema"
    info "将处理全部业务库 (${#SCHEMA_ARR[@]}): ${SCHEMA_ARR[*]}"
    return 0
  fi

  [ -n "$SCHEMA" ] || die "需要 -s schema（逗号分隔多库）或 --all-schemas"
  local IFS=','
  local s
  for s in $SCHEMA; do
    s=$(echo "$s" | tr -d ' ')
    [ -n "$s" ] && SCHEMA_ARR+=("$s")
  done
  [ ${#SCHEMA_ARR[@]} -gt 0 ] || die "schema 列表为空"
}

# 跑 sqlline 脚本文件
run_sqlline() {
  local sqlfile="$1"
  "$PHOENIX_HOME/bin/sqlline.py" "$ZK" "$sqlfile"
}

run_psql() {
  # 兼容: psql.py 可能吃 -t table
  "$PHOENIX_HOME/bin/psql.py" "$@"
}

# ============================================================
# 元数据：列出 schema
# ============================================================
list_schemas() {
  require_env
  local sql="$WORK/list_schemas.sql"
  mkdir -p "$WORK"
  cat > "$sql" <<'EOF'
!outputformat csv
SELECT DISTINCT TABLE_SCHEM FROM SYSTEM.CATALOG
WHERE TABLE_SCHEM IS NOT NULL
  AND TABLE_SCHEM NOT IN ('SYSTEM','INFORMATION_SCHEMA')
ORDER BY 1;
!quit
EOF
  info "查询 schema 列表..."
  run_sqlline "$sql" | grep -v -E '^(Saving|Recording|Scanning|\s*$)' || true
}

# ============================================================
# 元数据：列出某 schema 下的表
# ============================================================
list_tables() {
  require_env
  [ -n "$SCHEMA" ] || die "list-tables 需要 -s schema"
  mkdir -p "$WORK"
  local sql="$WORK/list_tables_${SCHEMA}.sql"
  cat > "$sql" <<EOF
!outputformat csv
SELECT DISTINCT TABLE_NAME FROM SYSTEM.CATALOG
WHERE TABLE_SCHEM = '$SCHEMA'
ORDER BY 1;
!quit
EOF
  info "查询 $SCHEMA 下表列表..."
  run_sqlline "$sql" | grep -v -E '^(Saving|Recording|Scanning|\s*$)' || true
}

# 用 sqlline 输出表名，过滤杂行，输出到 stdout（逐行）
fetch_table_names() {
  local schema="$1"
  local sql="$WORK/_list_${schema}.sql"
  # DISTINCT TABLE_NAME：兼容老 Phoenix（不依赖 COLUMN_NAME IS NULL / TABLE_TYPE）
  cat > "$sql" <<EOF
!outputformat csv
SELECT DISTINCT TABLE_NAME
FROM SYSTEM.CATALOG
WHERE TABLE_SCHEM = '$schema'
ORDER BY 1;
!quit
EOF
  run_sqlline "$sql" 2>/dev/null \
    | grep -v -E '^(Saving|Recording|Scanning|^[0-9]+/[0-9]+|N rows selected|\s*$)' \
    | tr -d '\r' \
    | sed "s/^['\"]//;s/['\"]\$//" \
    | grep -E '^[A-Za-z0-9_]+$' || true
}

# 导出列元数据（每表一行: TABLE,COLUMN,COLTYPE,KEY_SEQ,COL_FAMILY）
fetch_columns_meta() {
  local schema="$1"
  local out_csv="$2"
  local sql="$WORK/_cols_${schema}.sql"
  # 不使用 NULLS LAST（老 Phoenix 兼容）
  cat > "$sql" <<EOF
!outputformat csv
SELECT TABLE_NAME, COLUMN_NAME, COLUMN_FAMILY, DATA_TYPE, KEY_SEQ, COLUMN_SIZE, DECIMAL_DIGITS
FROM SYSTEM.CATALOG
WHERE TABLE_SCHEM = '$schema'
  AND COLUMN_NAME IS NOT NULL
ORDER BY TABLE_NAME, KEY_SEQ, COLUMN_NAME;
!quit
EOF
  run_sqlline "$sql" > "$out_csv" 2>/dev/null || true
}

# 生成 DDL（Python 2.7，读列元数据 csv）
generate_ddl_py() {
  local meta_csv="$1"
  local out_ddl="$2"
  local dst_schema="$3"
  local mapping_file="$4"   # optional: table mapping src->dst

  python - "$meta_csv" "$out_ddl" "$dst_schema" "${mapping_file:-}" <<'PYEOF'
# -*- coding: utf-8 -*-
import csv, sys, re, codecs

meta_csv, out_ddl, dst_schema = sys.argv[1], sys.argv[2], sys.argv[3]
mapping_file = sys.argv[4] if len(sys.argv) > 4 else ''

# java.sql.Types -> Phoenix
TYPES = {
    '1': 'VARCHAR', '12': 'VARCHAR', '-1': 'VARCHAR',  # CHAR/VARCHAR/LONGVARCHAR
    '-5': 'BIGINT', '4': 'INTEGER', '-6': 'TINYINT', '5': 'SMALLINT', '2': 'NUMERIC',
    '3': 'DECIMAL', '8': 'DOUBLE', '7': 'REAL', '6': 'FLOAT',
    '93': 'TIMESTAMP', '91': 'DATE', '92': 'TIME',
    '16': 'BOOLEAN', '-2': 'BINARY', '-3': 'VARBINARY', '-4': 'LONGVARBINARY',
    '2004': 'BLOB', '2005': 'CLOB', '-15': 'NVARCHAR', '-9': 'NVARCHAR',
}

def map_type(java_type):
    return TYPES.get(str(java_type).strip(), 'VARCHAR')

# table mapping file: SRC -> DST per line
name_map = {}
if mapping_file:
    try:
        f = open(mapping_file, 'rb')
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            if '=>' in line:
                a, b = line.split('=>', 1)
                name_map[a.strip()] = b.strip()
        f.close()
    except Exception:
        pass

junk = re.compile(r'^\s*(\d+/\d+|Saving all output|Recording stopped|N rows selected)')
cols = {}  # tbl -> list of dict
order = []

with open(meta_csv, 'rb') as f:
    for raw in f:
        if junk.match(raw):
            continue
        try:
            row = next(csv.reader([raw], quotechar="'", skipinitialspace=True))
        except Exception:
            continue
        # TABLE, COLUMN, FAMILY, DATA_TYPE, KEY_SEQ, COLUMN_SIZE, DECIMAL_DIGITS
        if len(row) < 5:
            continue
        tname = row[0].strip().strip('"')
        if tname.lower() in ('table_name',):
            continue
        if not tname:
            continue
        col = row[1].strip().strip('"')
        fam = row[2].strip().strip('"') if row[2].strip() else ''
        dtype = row[3].strip()
        kseq = row[4].strip().strip('"')
        if tname not in cols:
            cols[tname] = []
            order.append(tname)
        cols[tname].append({
            'name': col,
            'family': fam,
            'type': map_type(dtype),
            'key_seq': kseq,
            'is_pk': kseq not in ('', '0', 'NULL', 'None'),
        })

out = open(out_ddl, 'wb')
for t in order:
    # 映射表名
    dt = name_map.get(t, t)
    # 大小写敏感表名用双引号
    def q(n):
        return '"%s"' % n
    pk = [c for c in cols[t] if c['is_pk']]
    reg = [c for c in cols[t] if not c['is_pk']]
    pk.sort(key=lambda c: int(c['key_seq']) if c['key_seq'].isdigit() else 999)
    if not pk:
        # 无主键异常，跳过
        sys.stderr.write('skip table without pk: %s\n' % t)
        continue
    pk_parts = []
    for c in pk:
        pk_parts.append('%s %s' % (q(c['name']), c['type']))
    reg_parts = []
    for c in reg:
        if c['family'] and c['family'].upper() != '0':
            # 有 column family 时写成 "fam"."col" TYPE
            reg_parts.append('%s.%s %s' % (q(c['family']), q(c['name']), c['type']))
        else:
            reg_parts.append('%s %s' % (q(c['name']), c['type']))
    body = ',\n    '.join(pk_parts)
    if reg_parts:
        body += ',\n    ' + ',\n    '.join(reg_parts)
    ddl = 'CREATE TABLE IF NOT EXISTS %s.%s (\n    %s\n);\n' % (
        q(dst_schema), q(dt), body)
    out.write(ddl)
    # 同时写一个简短 meta: 表名映射与列（供导入转换用）
out.close()
print('ddl written: %s tables=%d' % (out_ddl, len(order)))
PYEOF
}

# 生成列映射 meta（导入转换用）: 每表一个文件，格式:
# TABLE,IS_PK,KEY_SEQ,COL_SRC,COL_DST,IS_BINARY
export_columns_for_convert() {
  local meta_csv="$1"
  local out_dir="$2"
  mkdir -p "$out_dir"
  python - "$meta_csv" "$out_dir" <<'PYEOF'
# -*- coding: utf-8 -*-
import csv, sys, re, os

meta_csv, out_dir = sys.argv[1], sys.argv[2]
junk = re.compile(r'^\s*(\d+/\d+|Saving all output|Recording stopped|N rows selected)')
BINARY_TYPES = set(['-2', '-3', '-4', '2004'])

cols = {}
order = []
with open(meta_csv, 'rb') as f:
    for raw in f:
        if junk.match(raw):
            continue
        try:
            row = next(csv.reader([raw], quotechar="'", skipinitialspace=True))
        except Exception:
            continue
        if len(row) < 5:
            continue
        tname = row[0].strip().strip('"')
        if tname.lower() == 'table_name' or not tname:
            continue
        col = row[1].strip().strip('"')
        dtype = row[3].strip()
        kseq = row[4].strip().strip('"')
        if tname not in cols:
            cols[tname] = []
            order.append(tname)
        cols[tname].append({
            'name': col,
            'type': dtype,
            'key_seq': kseq,
            'is_pk': kseq not in ('', '0', 'NULL', 'None'),
            'is_bin': dtype in BINARY_TYPES,
        })

for t in order:
    path = os.path.join(out_dir, t + '.cols')
    with open(path, 'wb') as o:
        o.write('# col_src|col_dst|is_pk|key_seq|is_bin\n')
        items = cols[t]
        items.sort(key=lambda c: (
            0 if c['is_pk'] else 1,
            int(c['key_seq']) if c['key_seq'].isdigit() else 999,
            c['name'],
        ))
        for c in items:
            o.write('%s|%s|%s|%s|%s\n' % (
                c['name'], c['name'].upper(),
                '1' if c['is_pk'] else '0',
                c['key_seq'],
                '1' if c['is_bin'] else '0',
            ))
print('cols meta dir ready: %s (%d tables)' % (out_dir, len(order)))
PYEOF
}

# ------------------------------------------------------------
# 通用 CSV 清洗转换器（按 .cols 元数据，兼容 Python 2.7）
# ------------------------------------------------------------
write_converter_py() {
  local conv="$1"
  cat > "$conv" <<'PYEOF'
# -*- coding: utf-8 -*-
# 用法: convert_csv.py raw.csv out.csv table.cols
# - 过滤 sqlline 杂行
# - 按 ' 单引号 CSV 解析
# - 二进制列: hex -> base64
# - 输出列顺序与目标一致，表头大写
import csv, sys, base64, re

csv.field_size_limit(sys.maxsize)
src, dst, colfile = sys.argv[1], sys.argv[2], sys.argv[3]

junk = re.compile(r'^\s*(\d+/\d+|Saving all output|Recording stopped)')
sel = re.compile(r'^\s*\d+\s+rows?\s+selected')

def is_hex(s):
    if not s or len(s) % 2 != 0:
        return False
    try:
        s.decode('hex')
        return True
    except Exception:
        return False

def parse_cols(path):
    items = []
    with open(path, 'rb') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split('|')
            if len(parts) < 5:
                continue
            items.append({
                'src': parts[0],
                'dst': parts[1],
                'is_pk': parts[2] == '1',
                'is_bin': parts[4] == '1',
            })
    return items

cols = parse_cols(colfile)
if not cols:
    raise SystemExit('empty cols file: ' + colfile)

n = 0
with open(src, 'rb') as f, open(dst, 'wb') as o:
    w = csv.writer(o)
    w.writerow([c['dst'] for c in cols])
    header = None
    idx = {}
    for line in f:
        if junk.match(line) or sel.match(line):
            continue
        try:
            row = next(csv.reader([line], quotechar="'", skipinitialspace=True))
        except Exception:
            continue
        if header is None:
            header = [c.strip().strip('"') for c in row]
            for i, h in enumerate(header):
                idx[h.upper()] = i
                idx[h] = i
            missing = [c['src'] for c in cols if c['src'].upper() not in idx and c['src'] not in idx]
            if missing:
                sys.stderr.write('warning: missing cols %s in header %s\n' % (missing, header))
            continue
        out = []
        for c in cols:
            i = idx.get(c['src'].upper(), idx.get(c['src']))
            val = row[i].strip() if i is not None and i < len(row) else ''
            if c['is_bin'] and val:
                if is_hex(val):
                    val = base64.b64encode(val.decode('hex'))
            out.append(val)
        w.writerow(out)
        n += 1
print('converted rows: %d' % n)
PYEOF
}

# ------------------------------------------------------------
# 生成 UPSERT SQL（按 .cols）
# ------------------------------------------------------------
gen_upsert_py() {
  local cols_file="$1"
  local out_sql="$2"
  local dst_schema="$3"
  local dst_table="$4"
  python - "$cols_file" "$out_sql" "$dst_schema" "$dst_table" <<'PYEOF'
# -*- coding: utf-8 -*-
import sys
cols_file, out_sql, schema, table = sys.argv[1:5]
cols = []
with open(cols_file, 'rb') as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        parts = line.split('|')
        if len(parts) < 5:
            continue
        cols.append((parts[0], parts[1], parts[2]))
# UPSERT 列名用目标表实际大小写（源名）
ins_cols = ','.join('"%s"' % c[0] for c in cols)
sel_cols = ','.join('"%s"' % c[1] for c in cols)
sql = 'UPSERT INTO "%s"."%s" (%s) SELECT %s FROM %s;\n' % (
    schema, table, ins_cols, sel_cols, '<<STAGE>>')
open(out_sql, 'wb').write(sql)
PYEOF
}

# 放大超时（复用 single_import 思路）
overlay_hbase_timeout() {
  local conf_over="$WORK/hbase-conf"
  mkdir -p "$conf_over"
  local old="${HBASE_CONF_DIR:-/etc/hbase/conf}"
  [ -f "$old/hbase-site.xml" ] && cp "$old/hbase-site.xml" "$conf_over/hbase-site.xml"
  python - "$conf_over/hbase-site.xml" <<'PYEOF'
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
print('hbase-site overlay: ' + path)
PYEOF
  export HBASE_CONF_DIR="$conf_over"
  info "已放大 scanner/rpc/query 超时 (HBASE_CONF_DIR=$HBASE_CONF_DIR)"
}

# ============================================================
# EXPORT
# ============================================================

# 导出单个 schema 的全部/指定表
export_one_schema() {
  local schema="$1"
  local tables=()
  mkdir -p "$OUT_DIR/$schema" "$WORK"

  if [ -n "$TABLES" ]; then
    IFS=',' read -r -a tables <<< "$TABLES"
  else
    while IFS= read -r line; do
      line=$(echo "$line" | tr -d '\r' | sed "s/^['\"]//;s/['\"]\$//")
      [ -n "$line" ] && tables+=("$line")
    done < <(fetch_table_names "$schema")
  fi

  if [ ${#tables[@]} -eq 0 ]; then
    warn "未发现可导出的表: $schema（跳过）"
    return 1
  fi

  info "===== 导出 schema=$schema 表数=${#tables[@]} ====="
  printf '%s\n' "${tables[@]}"

  local meta_csv="$OUT_DIR/$schema/_columns.csv"
  info "导出列元数据..."
  fetch_columns_meta "$schema" "$meta_csv"

  {
    echo "# phoenix migrate export"
    echo "SCHEMA=$schema"
    echo "ZK=$ZK"
    echo "DATE=$(date '+%F %T')"
    echo "TABLES=${tables[*]}"
  } > "$OUT_DIR/$schema/_manifest.txt"

  local i=0
  local t
  for t in "${tables[@]}"; do
    i=$((i+1))
    local csv="$OUT_DIR/$schema/$t.csv"
    local sql="$OUT_DIR/$schema/_export_${t}.sql"
    cat > "$sql" <<SQLEOF
!outputformat csv
!record $csv
SELECT * FROM "$schema"."$t";
!record
!quit
SQLEOF
    info "[$i/${#tables[@]}] 导出 $schema.$t -> $csv"
    run_sqlline "$sql" || warn "导出 $t 可能失败，请检查"
    local lines
    lines=$(wc -l < "$csv" 2>/dev/null || echo 0)
    info "  行数(含表头/杂行): $lines"
    head -1 "$csv" | cut -c1-120 || true
    if head -5 "$csv" | grep -q '^[|+]'; then
      warn "  $t 输出疑似表格框线，!outputformat 未生效；请参考交互式导出"
    fi
  done

  local tarball="$OUT_DIR/${schema}_export_$(date +%Y%m%d%H%M%S).tar.gz"
  info "打包: $tarball"
  tar -czf "$tarball" -C "$OUT_DIR" "$schema" || warn "打包失败（不影响 CSV）"
  ok "schema=$schema 导出完成 ($i 张表)"
  return 0
}

# 导出（单库 / 多库 / --all-schemas）
do_export() {
  require_env
  build_schema_list

  local ok_n=0
  local fail_n=0
  local s
  for s in "${SCHEMA_ARR[@]}"; do
    echo ""
    if export_one_schema "$s"; then
      ok_n=$((ok_n+1))
    else
      fail_n=$((fail_n+1))
    fi
  done

  # 多库时再打一个总包，方便一次 scp
  if [ ${#SCHEMA_ARR[@]} -gt 1 ]; then
    local stamp
    stamp=$(date +%Y%m%d%H%M%S)
    local bundle="$OUT_DIR/multi_export_${stamp}.tar.gz"
    info "多库总包: $bundle"
    tar -czf "$bundle" -C "$OUT_DIR" "${SCHEMA_ARR[@]}" || warn "多库总包打包失败"
  fi

  ok "导出结束: 成功 $ok_n 库, 失败 $fail_n 库"
  info "目录: $OUT_DIR"
  info "请将各 schema 子目录（或总包 tar.gz）scp 到目标机后执行 import"
  if [ ${#SCHEMA_ARR[@]} -eq 1 ]; then
    info "示例: scp -r ${OUT_DIR}/${SCHEMA_ARR[0]} target:/mnt/data/di/phoenix/export/"
  else
    info "示例: scp ${OUT_DIR}/multi_export_*.tar.gz target:/mnt/data/di/phoenix/export/"
  fi
}

# ============================================================
# IMPORT
# ============================================================

# 尝试在 HBase 中创建 namespace（Phoenix schema）
# 若 hbase CLI 不可用则仅提示，不影响后续 DDL 尝试
create_hbase_namespace() {
  local ns="$1"
  [ -n "$ns" ] || return 0

  # 系统库无需创建
  case "$ns" in
    SYSTEM|INFORMATION_SCHEMA) return 0 ;;
  esac

  local hbase_bin=""
  if command -v hbase >/dev/null 2>&1; then
    hbase_bin="hbase"
  elif [ -n "$HBASE_HOME" ] && [ -x "$HBASE_HOME/bin/hbase" ]; then
    hbase_bin="$HBASE_HOME/bin/hbase"
  fi

  if [ -z "$hbase_bin" ]; then
    warn "未找到 hbase CLI，跳过自动创建 namespace '$ns'（若 DDL 报错请手动: create_namespace '$ns'）"
    return 0
  fi

  info "检查/创建 HBase namespace '$ns' ..."
  if "$hbase_bin" shell -n "list_namespace" 2>/dev/null | tr -d ' ' | grep -qx "$ns"; then
    ok "namespace '$ns' 已存在"
    return 0
  fi

  if "$hbase_bin" shell -n "create_namespace '$ns'" 2>/dev/null; then
    ok "namespace '$ns' 创建成功"
    return 0
  fi

  # list_namespace 输出格式不稳时，直接 create 并忽略 already exists
  if "$hbase_bin" shell -n "create_namespace '$ns'" 2>&1 | grep -qiE 'already exist|exists'; then
    ok "namespace '$ns' 已存在"
    return 0
  fi

  warn "自动创建 namespace '$ns' 失败/跳过，若后续建表报错请在 hbase shell 执行: create_namespace '$ns'"
  return 0
}

# 导入单个 schema
import_one_schema() {
  local schema="$1"
  local src_dir="$OUT_DIR/$schema"
  [ -d "$src_dir" ] || { warn "未找到导出目录: $src_dir"; return 1; }

  # 多库时不允许统一 --dst-schema 覆盖全部（易混淆），单库可用
  local dst_schema="$schema"
  if [ ${#SCHEMA_ARR[@]} -eq 1 ] && [ -n "$DEST_SCHEMA_OVERRIDE" ]; then
    dst_schema="$DEST_SCHEMA_OVERRIDE"
  elif [ -n "$DEST_SCHEMA_OVERRIDE" ] && [ "$DEST_SCHEMA_OVERRIDE" != "$schema" ]; then
    warn "多库导入忽略 --dst-schema；若需改名请逐库执行"
  fi

  mkdir -p "$WORK" "$WORK/ddl" "$WORK/cols" "$WORK/csv"
  overlay_hbase_timeout

  # 先创建目标 namespace/schema，再执行 CREATE TABLE
  create_hbase_namespace "$dst_schema"

  local tables=()
  if [ -n "$TABLES" ]; then
    IFS=',' read -r -a tables <<< "$TABLES"
  else
    local manifest="$src_dir/_manifest.txt"
    if [ -f "$manifest" ]; then
      local line
      line=$(grep '^TABLES=' "$manifest" | head -1 | cut -d= -f2-)
      read -r -a tables <<< "$line"
    fi
    if [ ${#tables[@]} -eq 0 ]; then
      while IFS= read -r f; do
        [ -n "$f" ] && tables+=("$(basename "$f" .csv)")
      done < <(find "$src_dir" -maxdepth 1 -type f -name '*.csv' ! -name '_*.csv' ! -name '*_columns.csv')
    fi
  fi
  [ ${#tables[@]} -gt 0 ] || { warn "未找到要导入的表: $schema"; return 1; }

  info "===== 导入 src=$schema -> dst=$dst_schema 表数=${#tables[@]} ====="
  printf '%s\n' "${tables[@]}"

  local mapfile="$WORK/table_map.txt"
  : > "$mapfile"

  local meta_csv="$src_dir/_columns.csv"
  if [ ! -f "$meta_csv" ]; then
    warn "缺少元数据 $meta_csv，将按 CSV 表头兜底建表（类型可能不精确）"
  fi

  info "生成列元数据（转换用）..."
  if [ -f "$meta_csv" ]; then
    generate_ddl_py "$meta_csv" "$WORK/ddl/all_tables.sql" "$dst_schema" "$mapfile"
    export_columns_for_convert "$meta_csv" "$WORK/cols"
  else
    : > "$WORK/ddl/all_tables.sql"
  fi

  write_converter_py "$WORK/convert_csv.py"

  # 确保 .cols 存在（元数据缺失时从 CSV 表头推断）
  ensure_cols_from_csv() {
    local table="$1"
    local raw="$src_dir/$table.csv"
    local cols="$WORK/cols/$table.cols"
    [ -f "$cols" ] && return 0
    [ -f "$raw" ] || return 1
    python - "$raw" "$cols" <<'PYEOF'
# -*- coding: utf-8 -*-
import csv, sys, re
csv.field_size_limit(sys.maxsize)
raw, cols = sys.argv[1], sys.argv[2]
junk = re.compile(r'^\s*(\d+/\d+|Saving all output|Recording stopped|N rows selected)')
header = None
with open(raw, 'rb') as f:
    for line in f:
        if junk.match(line):
            continue
        try:
            row = next(csv.reader([line], quotechar="'", skipinitialspace=True))
        except Exception:
            continue
        header = [c.strip().strip('"') for c in row if c is not None and c.strip() != '']
        break
if not header:
    raise SystemExit('cannot read header: ' + raw)
with open(cols, 'wb') as o:
    o.write('# col_src|col_dst|is_pk|key_seq|is_bin\n')
    for i, name in enumerate(header):
        # 第一列当主键；含 content/content 等二进制语义的列标记 binary
        is_pk = '1' if i == 0 else '0'
        is_bin = '1' if name.lower() in ('content', 'data', 'body', 'payload', 'file_content') else '0'
        o.write('%s|%s|%s|%d|%s\n' % (name, name, is_pk, i + 1 if is_pk == '1' else '0', is_bin))
print('fallback cols: ' + cols)
PYEOF
  }

  # 按 .cols 生成并执行单表 CREATE TABLE IF NOT EXISTS
  ensure_table_exists() {
    local table="$1"
    local create_ddl="$WORK/ddl/create_${table}.sql"
    python - "$WORK/cols/$table.cols" "$create_ddl" "$dst_schema" "$table" <<'PYEOF'
# -*- coding: utf-8 -*-
import sys
cols_file, out_sql, schema, table = sys.argv[1:5]
items = []
with open(cols_file, 'rb') as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        p = line.split('|')
        if len(p) < 5:
            continue
        items.append((p[0], p[2], p[4]))
parts = []
for name, is_pk, is_bin in items:
    typ = 'VARBINARY' if is_bin == '1' else 'VARCHAR'
    if is_pk == '1':
        parts.append('"%s" %s PRIMARY KEY' % (name, typ))
    else:
        parts.append('"%s" %s' % (name, typ))
sql = 'CREATE TABLE IF NOT EXISTS "%s"."%s" (\n    %s\n);\n' % (
    schema, table, ',\n    '.join(parts))
open(out_sql, 'wb').write(sql)
PYEOF
    info "创建表 $dst_schema.$table ..."
    run_psql "$ZK" "$create_ddl" || warn "创建 $dst_schema.$table 可能失败"
  }

  # 批量 DDL（元数据完整时）
  if [ -s "$WORK/ddl/all_tables.sql" ]; then
    info "按元数据批量创建目标表（IF NOT EXISTS）..."
    run_psql "$ZK" "$WORK/ddl/all_tables.sql" || warn "批量 DDL 有错误，将逐表重试"
  fi

  # 逐表确保表存在（元数据缺项 / CSV 推断）
  for t in "${tables[@]}"; do
    if [ ! -f "$WORK/cols/$t.cols" ]; then
      if ensure_cols_from_csv "$t"; then
        info "表 $t 无元数据，已按 CSV 表头生成列定义"
      else
        warn "无法为表 $t 生成列定义（缺少 CSV/元数据）"
        continue
      fi
    fi
    ensure_table_exists "$t"
  done

  local i=0
  local t
  for t in "${tables[@]}"; do
    i=$((i+1))
    local raw="$src_dir/$t.csv"
    local cols="$WORK/cols/$t.cols"
    if [ ! -f "$raw" ]; then
      warn "[$i/${#tables[@]}] 缺少 $raw，跳过"
      continue
    fi
    if [ ! -f "$cols" ]; then
      warn "[$i/${#tables[@]}] 缺少列元数据 $cols，跳过 $t"
      continue
    fi

    echo ""
    info "===== [$i/${#tables[@]}] $schema.$t -> $dst_schema.$t ====="
    local b64="$WORK/csv/$t.b64.csv"
    python "$WORK/convert_csv.py" "$raw" "$b64" "$cols"
    head -1 "$b64" | cut -c1-120 || true

    local stage="${STAGE_PREFIX}_$i"
    if [ ${#stage} -gt 30 ]; then
      stage="${STAGE_PREFIX}_$(echo -n "$t" | tail -c 12 | tr 'a-z-' 'A-Z_')_$i"
    fi
    stage=$(echo "$stage" | tr 'a-z' 'A-Z')

    local stage_ddl="$WORK/ddl/stage_${stage}.sql"
    python - "$cols" "$stage_ddl" "$stage" <<'PYEOF'
# -*- coding: utf-8 -*-
import sys
cols_file, out_sql, stage = sys.argv[1:5]
items = []
with open(cols_file, 'rb') as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        p = line.split('|')
        if len(p) < 5:
            continue
        items.append((p[1], p[2], p[4]))
pk = [c for c in items if c[1] == '1']
reg = [c for c in items if c[1] != '1']
def typ(is_bin):
    return 'VARBINARY' if is_bin == '1' else 'VARCHAR'
parts = []
for name, _, b in pk:
    parts.append('%s %s PRIMARY KEY' % (name, typ(b)))
for name, _, b in reg:
    parts.append('%s %s' % (name, typ(b)))
sql = 'CREATE TABLE %s (\n    %s\n);\n' % (stage, ',\n    '.join(parts))
open(out_sql, 'wb').write(sql)
PYEOF

    echo "DROP TABLE IF EXISTS $stage;" > "$WORK/ddl/drop_${stage}.sql"
    run_psql "$ZK" "$WORK/ddl/drop_${stage}.sql" || true
    run_psql "$ZK" "$stage_ddl"
    info "--- CSV -> 临时表 $stage ---"
    run_psql -t "$stage" -h in-line "$ZK" "$b64"

    local copy_sql="$WORK/ddl/copy_${t}.sql"
    python - "$cols" "$copy_sql" "$dst_schema" "$t" <<'PYEOF'
# -*- coding: utf-8 -*-
import sys
cols_file, out_sql, schema, table = sys.argv[1:5]
items = []
with open(cols_file, 'rb') as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        p = line.split('|')
        if len(p) < 5:
            continue
        items.append((p[0], p[1], p[2]))
ins = ','.join('"%s"' % a for a, _, _ in items)
sel = ','.join('"%s"' % b for _, b, _ in items)
sql = 'UPSERT INTO "%s"."%s" (%s) SELECT %s FROM <<STAGE>>;\n' % (
    schema, table, ins, sel)
open(out_sql, 'wb').write(sql)
PYEOF
    sed -i "s/<<STAGE>>/$stage/g" "$copy_sql"

    info "--- 临时表转入 $dst_schema.$t ---"
    run_psql "$ZK" "$copy_sql"

    info "--- 删除临时表 $stage ---"
    run_psql "$ZK" "$WORK/ddl/drop_${stage}.sql" || true

    cat > "$WORK/ddl/count_$t.sql" <<SQLEOF
SELECT '$t' AS TBL, COUNT(*) AS CNT FROM "$dst_schema"."$t";
!quit
SQLEOF
    info "行数:"
    "$PHOENIX_HOME/bin/sqlline.py" "$ZK" "$WORK/ddl/count_$t.sql" | tail -n +1 | grep -E "$t|CNT" || true
  done

  ok "schema 导入完成: $schema -> $dst_schema"
  return 0
}

# 导入（单库 / 多库 / --all-schemas）
# --all-schemas 导入: 自动扫描 OUT_DIR 下有 _manifest.txt 的子目录
do_import() {
  require_env

  if [ "$ALL_SCHEMAS" = "1" ]; then
    SCHEMA_ARR=()
    local d
    while IFS= read -r d; do
      [ -n "$d" ] && SCHEMA_ARR+=("$d")
    done < <(find "$OUT_DIR" -mindepth 1 -maxdepth 1 -type d -exec test -f '{}/_manifest.txt' \; -print | sort)
    [ ${#SCHEMA_ARR[@]} -gt 0 ] || die "--all-schemas 未在 $OUT_DIR 下发现含 _manifest.txt 的 schema 目录"
    info "将导入 $OUT_DIR 下全部库 (${#SCHEMA_ARR[@]}): ${SCHEMA_ARR[*]}"
  else
    build_schema_list
  fi

  mkdir -p "$WORK" "$WORK/ddl" "$WORK/cols" "$WORK/csv"

  local ok_n=0
  local fail_n=0
  local s
  for s in "${SCHEMA_ARR[@]}"; do
    echo ""
    if import_one_schema "$s"; then
      ok_n=$((ok_n+1))
    else
      fail_n=$((fail_n+1))
    fi
  done

  ok "导入结束: 成功 $ok_n 库, 失败 $fail_n 库"
  info "工作目录: $WORK（确认无误后可清理）"
}

# ============================================================
main() {
  [ -n "$ACTION" ] || usage
  case "$ACTION" in
    list-schemas|schemas) list_schemas ;;
    list-tables|tables) list_tables ;;
    export) do_export ;;
    import) do_import ;;
    -h|--help|help) usage ;;
    *) die "未知命令: $ACTION（-h 查看帮助）" ;;
  esac
}

parse_args "$@"
main
