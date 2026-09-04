#!/usr/bin/env bash
# =============================================================
# migrate_pg17_pack.sh —— 源机打包脚本（交互式）
#
# 用途：把已编译好的 PostgreSQL 17（含 PostGIS/pgvector/TimescaleDB，
#       GEOS/PROJ/SQLite 在 /usr/local）打成迁移包，配合
#       migrate_pg17_deploy.sh 在目标机一键部署。
#
# 产出（默认放 /mnt/data）：
#   pg17-bin.tar.gz     PG 程序目录（含扩展，不含 data）
#   pg17-deps.tar.gz    /usr/local 自研依赖库（GEOS/PROJ/SQLite + proj.db）
#   pg17-syslib.tar.gz  系统运行时库（ldd 自动收集，跳过 glibc 核心库）
#   pg17-conf.tar.gz    postgresql.conf / pg_hba.conf / postgresql17.service
#   pg17-migrate.env    源机路径清单（目标机部署时用于自动替换路径）
#   pg17-ldd.txt        依赖清单（目标机缺库时对照用）
#
# 用法：在【源机】上以 root 执行  bash migrate_pg17_pack.sh
# =============================================================
set -euo pipefail

info() { echo -e "\033[32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[31m[ERR ]\033[0m $*" >&2; }

[ "$(id -u)" -eq 0 ] || { err "请以 root 执行"; exit 1; }

echo "=============================================="
echo "  PostgreSQL 17 源机打包"
echo "=============================================="

# ---------- 交互输入 ----------
read -r -p "源机 PG 安装目录 [/home/data/postgresql/postgresql-17.9]: " SRC_PGHOME
SRC_PGHOME=${SRC_PGHOME:-/home/data/postgresql/postgresql-17.9}

read -r -p "源机 data 数据目录（取配置文件用） [/home/data/postgresql/data]: " SRC_PGDATA
SRC_PGDATA=${SRC_PGDATA:-/home/data/postgresql/data}

read -r -p "压缩包输出目录 [/mnt/data]: " OUT
OUT=${OUT:-/mnt/data}

# ---------- 校验 ----------
[ -x "$SRC_PGHOME/bin/postgres" ] || { err "未找到 $SRC_PGHOME/bin/postgres，请检查 PG 安装目录"; exit 1; }
mkdir -p "$OUT"

info "源机 PG 目录 : $SRC_PGHOME"
info "源机 data 目录: $SRC_PGDATA"
info "输出目录     : $OUT"
read -r -p "确认开始打包？[Y/n]: " yn
[[ "${yn:-Y}" =~ ^[Nn]$ ]] && { echo "已取消"; exit 0; }

# ---------- 1. 打包 PG 程序目录 ----------
info "1/6 打包 PG 程序目录 -> pg17-bin.tar.gz"
tar -zcf "$OUT/pg17-bin.tar.gz" -C "$(dirname "$SRC_PGHOME")" "$(basename "$SRC_PGHOME")"
# 注意：不能用 grep -q（提前退出会使 tar 收 SIGPIPE，pipefail 下误判）
if tar -tzf "$OUT/pg17-bin.tar.gz" | grep -E 'postgis.*\.control' >/dev/null 2>&1; then
  info "    已确认包内含 postgis 扩展"
else
  warn "    未在包内发现 postgis，扩展可能不完整"
fi
ls -lh "$OUT/pg17-bin.tar.gz"

# ---------- 2. 打包 /usr/local 自研依赖库 ----------
info "2/6 打包 GEOS/PROJ/SQLite -> pg17-deps.tar.gz"
tar -zcf "$OUT/pg17-deps.tar.gz" -C / \
  usr/local/lib/libgeos* \
  usr/local/lib/libproj* \
  usr/local/lib/libsqlite3* \
  usr/local/lib/pkgconfig/geos*.pc \
  usr/local/lib/pkgconfig/proj.pc \
  usr/local/lib/pkgconfig/sqlite3.pc \
  usr/local/bin/geos-config \
  usr/local/bin/proj \
  usr/local/bin/projinfo \
  usr/local/bin/cs2cs \
  usr/local/bin/cct \
  usr/local/bin/gie \
  usr/local/bin/sqlite3 \
  usr/local/include/geos* \
  usr/local/include/proj* \
  usr/local/include/proj.h \
  usr/local/include/sqlite3.h \
  usr/local/share/proj \
  usr/local/lib/cmake/geos* \
  usr/local/lib/cmake/proj* \
  2>/dev/null
if tar -tzf "$OUT/pg17-deps.tar.gz" | grep -F 'usr/local/share/proj/proj.db' >/dev/null 2>&1; then
  info "    已确认包内含 proj.db"
else
  warn "    未在包内发现 share/proj/proj.db，PostGIS 投影功能会报错"
fi
ls -lh "$OUT/pg17-deps.tar.gz"

# ---------- 3. 收集系统运行时库（跳过 glibc 核心库） ----------
info "3/6 ldd 收集系统运行时库 -> pg17-syslib.tar.gz"
list="$OUT/pg17-syslib.list"
: > "$list"
for bin in "$SRC_PGHOME/bin/postgres" "$SRC_PGHOME/bin/psql" "$SRC_PGHOME/lib/"*.so; do
  ldd "$bin" 2>/dev/null
done | \
  awk '{for(i=1;i<=NF;i++) if($i ~ /^\//) print $i}' | \
  sed 's#^/lib64/#/usr/lib64/#' | \
  { grep '^/usr/lib64/' || true; } | sort -u | \
  while read -r lib; do
    # 跳过 glibc 核心库（目标机 CentOS 7 自带，跨机拷贝有风险）
    case "$(basename "$lib")" in
      ld-*|libc.*|libc-*|libm.*|libm-*|libdl.*|libdl-*|librt.*|librt-*|\
      libpthread.*|libpthread-*|libresolv.*|libresolv-*|libutil.*|libutil-*|\
      libcrypt.*|libcrypt-*|libnsl*|libnss_*|libcidn*|libBrokenLocale*|\
      libanl.*|libanl-*) continue;;
    esac
    echo "$lib"
    [ -L "$lib" ] && readlink -f "$lib"
  done | sort -u > "$list"
info "    收集到 $(wc -l < "$list") 个库文件"
# 提示 "Removing leading '/'" 属正常（tar 把绝对路径存为相对 usr/lib64/...）
tar -zcf "$OUT/pg17-syslib.tar.gz" -T "$list" 2>/dev/null
ls -lh "$OUT/pg17-syslib.tar.gz"

# ---------- 4. 打包数据库配置与 systemd 服务 ----------
info "4/6 打包配置文件 -> pg17-conf.tar.gz"
conf_tmp=$(mktemp -d)
conf_cnt=0
for f in postgresql.conf pg_hba.conf; do
  if [ -f "$SRC_PGDATA/$f" ]; then
    cp -a "$SRC_PGDATA/$f" "$conf_tmp/$f"; conf_cnt=$((conf_cnt+1))
  else
    warn "    $SRC_PGDATA/$f 不存在（源机未 initdb？）"
  fi
done
if [ -f /etc/systemd/system/postgresql17.service ]; then
  cp -a /etc/systemd/system/postgresql17.service "$conf_tmp/"; conf_cnt=$((conf_cnt+1))
else
  warn "    /etc/systemd/system/postgresql17.service 不存在，目标机将自动生成服务文件"
fi
if [ "$conf_cnt" -gt 0 ]; then
  tar -zcf "$OUT/pg17-conf.tar.gz" -C "$conf_tmp" .
  ls -lh "$OUT/pg17-conf.tar.gz"
else
  warn "    未收集到任何配置文件，跳过 pg17-conf.tar.gz"
fi
rm -rf "$conf_tmp"

# ---------- 5. 写源机路径清单 ----------
info "5/6 写路径清单 -> pg17-migrate.env"
cat > "$OUT/pg17-migrate.env" <<EOF
# 由 migrate_pg17_pack.sh 自动生成，目标机 deploy 脚本读取后做路径替换
SOURCE_PGHOME=$SRC_PGHOME
SOURCE_PGDATA=$SRC_PGDATA
EOF
cat "$OUT/pg17-migrate.env"

# ---------- 6. 生成依赖清单（目标机对照用） ----------
info "6/6 生成依赖清单 -> pg17-ldd.txt"
{
  echo "===== postgres 主程序 ====="
  ldd "$SRC_PGHOME/bin/postgres"
  echo "===== PostGIS 扩展 ====="
  ldd "$SRC_PGHOME/lib/postgis-3.so" 2>/dev/null || true
  echo "===== pgvector 扩展 ====="
  ldd "$SRC_PGHOME/lib/vector.so" 2>/dev/null || true
  echo "===== TimescaleDB 扩展 ====="
  ldd "$SRC_PGHOME/lib/"timescaledb-*.so 2>/dev/null || true
} > "$OUT/pg17-ldd.txt" 2>&1

# ---------- 汇总 ----------
echo
info "打包完成，产物如下："
ls -lh "$OUT"/pg17-*.tar.gz "$OUT"/pg17-migrate.env "$OUT"/pg17-ldd.txt 2>/dev/null || true
echo
echo "传到目标机（把 目标IP 换成实际 IP）："
echo "  scp $OUT/pg17-bin.tar.gz $OUT/pg17-deps.tar.gz $OUT/pg17-syslib.tar.gz \\"
echo "      $OUT/pg17-conf.tar.gz $OUT/pg17-migrate.env $OUT/pg17-ldd.txt root@目标IP:/mnt/data/"
echo
echo "目标机部署：上传 migrate_pg17_deploy.sh 后执行  bash migrate_pg17_deploy.sh"
