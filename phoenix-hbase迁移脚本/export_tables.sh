#!/bin/bash
# ============================================================
# Phoenix 批量导出脚本（在 A 机器执行）
# 用法:
#   bash export_tables.sh
# 可选环境变量:
#   ZK=di-zk01  OUT_DIR=/mnt/data/di/phoenix/export
# 前置: 已 source /etc/profile，PHOENIX_HOME 可用
# ============================================================
set -e

ZK="${ZK:-di-zk01}"
SCHEMA="p_504"
OUT_DIR="${OUT_DIR:-/mnt/data/di/phoenix/export}"

if [ -z "$PHOENIX_HOME" ]; then
  echo "请先 source /etc/profile 或 export PHOENIX_HOME"
  exit 1
fi

# 待导出的表（表名大小写敏感，勿改）
TABLES=(
  dsrmx2es5hCqt0Xk
  dsaR242QGsnozGhJ
  dsMrFSqbUDcUBevE
  ds2KUqFHFyhlwiPQ
  dsKgUAQsMnBIekl8
)

mkdir -p "$OUT_DIR"

for T in "${TABLES[@]}"; do
  SQL="$OUT_DIR/export_$T.sql"
  CSV="$OUT_DIR/$T.csv"
  cat > "$SQL" <<SQLEOF
!outputformat csv
!record $CSV
SELECT * FROM "$SCHEMA"."$T";
!record
!quit
SQLEOF
  echo "===== export $T ====="
  "$PHOENIX_HOME/bin/sqlline.py" "$ZK" "$SQL"
  echo "----- $T 原始输出行数: $(wc -l < "$CSV")"
done

echo ""
echo "全部导出完成，目录: $OUT_DIR"
echo "下一步: 将 $OUT_DIR/*.csv 拷贝到 B 机器，然后在 B 机器执行 import_tables.sh"
