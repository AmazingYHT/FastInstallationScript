#!/bin/bash
# ============================================================
# 单表导出脚本（在 A 源机器执行）
# 示例: p_504.dsz8y4YfNx4nSLy4
# 用法: bash single_export.sh
# ============================================================
set -e

# ===== 按需修改这 4 个变量 =====
ZK="di-zk01"
SRC_SCHEMA="p_504"
TABLE="dsz8y4YfNx4nSLy4"
OUT_DIR="/mnt/data/di/phoenix/export"
# ================================

if [ -z "$PHOENIX_HOME" ]; then
  echo "请先 source /etc/profile 或 export PHOENIX_HOME"
  exit 1
fi

mkdir -p "$OUT_DIR"
SQL="$OUT_DIR/export_$TABLE.sql"
CSV="$OUT_DIR/$TABLE.csv"

cat > "$SQL" <<SQLEOF
!outputformat csv
!record $CSV
SELECT * FROM "$SRC_SCHEMA"."$TABLE";
!record
!quit
SQLEOF

echo "===== 导出 $SRC_SCHEMA.$TABLE ====="
"$PHOENIX_HOME/bin/sqlline.py" "$ZK" "$SQL"

echo ""
echo "===== 结果检查 ====="
echo "文件: $CSV (行数: $(wc -l < "$CSV"))"
head -3 "$CSV"

# 校验是否真的是 csv（若出现 | 或 +--- 框线，说明 outputformat 没生效，需交互式导出）
if head -5 "$CSV" | grep -q '^[|+]'; then
  echo ""
  echo "[警告] 输出仍是表格框线格式，脚本模式下 !outputformat 未生效。"
  echo "请改用交互式导出，依次执行:"
  echo "  $PHOENIX_HOME/bin/sqlline.py $ZK"
  echo "  !outputformat csv"
  echo "  !record $CSV"
  echo "  SELECT * FROM \"$SRC_SCHEMA\".\"$TABLE\";"
  echo "  !record"
  echo "  !quit"
  exit 1
fi

echo ""
echo "导出成功，下一步: scp $CSV 到 B 机器后执行 single_import.sh"
