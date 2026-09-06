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
# 用法：在【源机】上以 root 执行
#   bash migrate_pg17_pack.sh                          # 交互确认（路径自动探测）
#   bash migrate_pg17_pack.sh <PG目录> <data目录> <输出目录>   # 全参数免交互
#
# 只需确认三个路径：
#   ① 源机 PG 安装目录（bin/、lib/ 所在目录，如 .../postgresql-17.11，即环境变量 PG_HOME）→ 打成 pg17-bin.tar.gz
#   ② 源机 data 数据目录（postgresql.conf 所在目录，仅取配置，不打包数据，即环境变量 PGDATA）→ pg17-conf.tar.gz
#   ③ 压缩包输出目录（打包产物存放处，供 scp 传到目标机）
# =============================================================
set -euo pipefail

info() { echo -e "\033[32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[31m[ERR ]\033[0m $*" >&2; }

[ "$(id -u)" -eq 0 ] || { err "请以 root 执行"; exit 1; }

echo "=============================================="
echo "  PostgreSQL 17 源机打包"
echo "=============================================="

# ---------- 自动探测源机 PG 环境（优先读环境变量 PG_HOME/PGDATA） ----------
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AUTO_PG_HOME=""
AUTO_PGDATA=""

# ① 优先读 /etc/profile 等写入的 PG_HOME / PGDATA 环境变量
if [ -n "${PG_HOME:-}" ] && [ -x "$PG_HOME/bin/postgres" ]; then
  AUTO_PG_HOME=$PG_HOME
fi
if [ -n "${PGDATA:-}" ] && [ -f "$PGDATA/postgresql.conf" ]; then
  AUTO_PGDATA=$PGDATA
fi

# ② 其次从正在运行的 postgres 进程获取（ps 取进程命令行；CentOS 7 兼容：ps -eo args）
if [ -z "$AUTO_PG_HOME" ] || [ -z "$AUTO_PGDATA" ]; then
  pg_proc=$(ps -eo args 2>/dev/null | grep -E '[p]ostgres( |$).*-D ' | head -1 || true)
  if [ -n "$pg_proc" ]; then
    proc_bin=${pg_proc%% *}
    if [ -z "$AUTO_PG_HOME" ]; then
      case "$proc_bin" in
        */bin/postgres) AUTO_PG_HOME=${proc_bin%/bin/postgres} ;;
        postgres)
          p=$(command -v postgres 2>/dev/null || true)
          [ -n "$p" ] && AUTO_PG_HOME=${p%/bin/postgres} ;;
      esac
    fi
    if [ -z "$AUTO_PGDATA" ]; then
      d=$(printf '%s\n' "$pg_proc" | sed -n 's/.*-D[[:space:]]*\([^[:space:]]*\).*/\1/p')
      [ -n "$d" ] && AUTO_PGDATA=$d
    fi
  fi
fi

# ③ 进程也没拿到则扫描常见安装位置
if [ -z "$AUTO_PG_HOME" ]; then
  for d in /home/data/postgresql/postgresql-17* /mnt/data/postgresql/postgresql-17* \
           /usr/local/pgsql* /opt/postgresql*/postgresql-17*; do
    [ -x "$d/bin/postgres" ] && { AUTO_PG_HOME="$d"; break; }
  done
fi
# data 目录：先看探测值，再看 PG 目录同级
if [ -z "$AUTO_PGDATA" ] && [ -n "$AUTO_PG_HOME" ]; then
  for d in "$(dirname "$AUTO_PG_HOME")/data" /home/data/postgresql/data /mnt/data/postgresql/data; do
    [ -f "$d/postgresql.conf" ] && { AUTO_PGDATA="$d"; break; }
  done
fi
# 输出目录：/mnt/data 可写则用之，否则用脚本所在目录
AUTO_OUT=/mnt/data
{ [ -d /mnt/data ] && [ -w /mnt/data ]; } || AUTO_OUT="$script_dir"

# ---------- 交互确认（仅确认/修改三个路径；命令行传参则跳过对应提问） ----------
if [ -n "${1:-}" ]; then
  SRC_PG_HOME=$1
else
  if [ -n "$AUTO_PG_HOME" ]; then
    info "自动探测到 PG 安装目录（PG_HOME）：$AUTO_PG_HOME"
    read -r -p "① PG 安装目录（bin/、lib/ 所在目录，直接回车用探测值）: " SRC_PG_HOME
    SRC_PG_HOME=${SRC_PG_HOME:-$AUTO_PG_HOME}
  else
    read -r -p "① PG 安装目录（bin/、lib/ 所在目录，如 /home/data/postgresql/postgresql-17.11）: " SRC_PG_HOME
  fi
fi

if [ -n "${2:-}" ]; then
  SRC_PGDATA=$2
else
  if [ -n "$AUTO_PGDATA" ]; then
    info "自动探测到 data 数据目录（PGDATA）：$AUTO_PGDATA"
    read -r -p "② data 数据目录（postgresql.conf 所在目录，仅取配置不打包数据，回车用探测值）: " SRC_PGDATA
    SRC_PGDATA=${SRC_PGDATA:-$AUTO_PGDATA}
  else
    read -r -p "② data 数据目录（postgresql.conf 所在目录，仅取配置不打包数据）: " SRC_PGDATA
  fi
fi

if [ -n "${3:-}" ]; then
  OUT=$3
else
  read -r -p "③ 压缩包输出目录（产物存放处，回车用 $AUTO_OUT）: " OUT
  OUT=${OUT:-$AUTO_OUT}
fi

# ---------- 校验 ----------
[ -x "$SRC_PG_HOME/bin/postgres" ] || { err "未找到 $SRC_PG_HOME/bin/postgres，请检查 ① PG 安装目录"; exit 1; }
[ -f "$SRC_PGDATA/postgresql.conf" ] || warn "$SRC_PGDATA 下未找到 postgresql.conf，将无法打出 pg17-conf.tar.gz（目标机用默认配置）"
if ! mkdir -p "$OUT" 2>/dev/null || [ ! -w "$OUT" ]; then
  err "输出目录 $OUT 无法创建或不可写，请检查 ③ 输出目录"; exit 1
fi

echo
echo "---------- 打包参数 ----------"
echo "① PG 安装目录 : $SRC_PG_HOME  -> pg17-bin.tar.gz（程序+扩展）、pg17-deps/syslib.tar.gz（依赖库）"
echo "② data 目录   : $SRC_PGDATA  -> pg17-conf.tar.gz（仅取 postgresql.conf/pg_hba.conf）"
echo "③ 输出目录    : $OUT  （6 个打包产物全部放这里）"
echo "------------------------------"
read -r -p "确认开始打包？[Y/n]: " yn
[[ "${yn:-Y}" =~ ^[Nn]$ ]] && { echo "已取消"; exit 0; }

# ---------- 1. 打包 PG 程序目录 ----------
info "1/6 打包 PG 程序目录 -> pg17-bin.tar.gz"
tar -zcf "$OUT/pg17-bin.tar.gz" -C "$(dirname "$SRC_PG_HOME")" "$(basename "$SRC_PG_HOME")"
# 注意：不能用 grep -q（提前退出会使 tar 收 SIGPIPE，pipefail 下误判）
if tar -tzf "$OUT/pg17-bin.tar.gz" | grep -E 'postgis.*\.control' >/dev/null 2>&1; then
  info "    已确认包内含 postgis 扩展"
else
  warn "    未在包内发现 postgis，扩展可能不完整"
fi
ls -lh "$OUT/pg17-bin.tar.gz"

# ---------- 2. 打包 /usr/local 自研依赖库 ----------
info "2/6 打包 GEOS/PROJ/SQLite -> pg17-deps.tar.gz"
# 先让 shell 展开通配符，只保留真实存在的文件/目录；
# 避免 tar 直接吃未展开的通配字面量，源机缺某个文件时整体失败中断
shopt -s nullglob
deps_entries=(
  /usr/local/lib/libgeos*
  /usr/local/lib/libproj*
  /usr/local/lib/libsqlite3*
  /usr/local/lib/pkgconfig/geos*.pc
  /usr/local/lib/pkgconfig/proj.pc
  /usr/local/lib/pkgconfig/sqlite3.pc
  /usr/local/bin/geos-config
  /usr/local/bin/proj
  /usr/local/bin/projinfo
  /usr/local/bin/cs2cs
  /usr/local/bin/cct
  /usr/local/bin/gie
  /usr/local/bin/sqlite3
  /usr/local/include/geos*
  /usr/local/include/proj*
  /usr/local/include/proj.h
  /usr/local/include/sqlite3.h
  /usr/local/share/proj
  /usr/local/lib/cmake/geos*
  /usr/local/lib/cmake/proj*
)
shopt -u nullglob
deps_files=()
for p in "${deps_entries[@]}"; do
  [ -e "$p" ] && deps_files+=("${p#/}")
done
if [ "${#deps_files[@]}" -eq 0 ]; then
  warn "    /usr/local 下未发现 GEOS/PROJ/SQLite 任何文件，跳过 pg17-deps.tar.gz（目标机 PostGIS 将不可用）"
else
  info "    纳入 ${#deps_files[@]} 个依赖条目"
  tar -zcf "$OUT/pg17-deps.tar.gz" -C / "${deps_files[@]}" 2>/dev/null
  if tar -tzf "$OUT/pg17-deps.tar.gz" | grep -F 'usr/local/share/proj/proj.db' >/dev/null 2>&1; then
    info "    已确认包内含 proj.db"
  else
    warn "    未在包内发现 share/proj/proj.db，PostGIS 投影功能会报错"
  fi
  ls -lh "$OUT/pg17-deps.tar.gz"
fi

# ---------- 3. 收集系统运行时库（跳过 glibc 核心库） ----------
info "3/6 ldd 收集系统运行时库 -> pg17-syslib.tar.gz"
list="$OUT/pg17-syslib.list"
: > "$list"
for bin in "$SRC_PG_HOME/bin/postgres" "$SRC_PG_HOME/bin/psql" "$SRC_PG_HOME/lib/"*.so; do
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
info "    ldd 收集到 $(wc -l < "$list") 个库路径"
# 过滤掉收集后已不存在/不可访问的文件，避免 tar 遇到不存在文件报错中断
: > "$list.ok"
while IFS= read -r lib; do
  [ -f "$lib" ] && echo "$lib" >> "$list.ok"
done < "$list"
if [ ! -s "$list.ok" ]; then
  warn "    未收集到任何可打包的系统库，跳过 pg17-syslib.tar.gz（目标机若缺库需手动补拷）"
else
  info "    实际打包 $(wc -l < "$list.ok") 个库文件"
  # 提示 "Removing leading '/'" 属正常（tar 把绝对路径存为相对 usr/lib64/...）
  tar -zcf "$OUT/pg17-syslib.tar.gz" -T "$list.ok" 2>/dev/null
  ls -lh "$OUT/pg17-syslib.tar.gz"
fi
rm -f "$list" "$list.ok"

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
SOURCE_PG_HOME=$SRC_PG_HOME
SOURCE_PGDATA=$SRC_PGDATA
EOF
cat "$OUT/pg17-migrate.env"

# ---------- 6. 生成依赖清单（目标机对照用） ----------
info "6/6 生成依赖清单 -> pg17-ldd.txt"
{
  echo "===== postgres 主程序 ====="
  ldd "$SRC_PG_HOME/bin/postgres"
  echo "===== PostGIS 扩展 ====="
  ldd "$SRC_PG_HOME/lib/postgis-3.so" 2>/dev/null || true
  echo "===== pgvector 扩展 ====="
  ldd "$SRC_PG_HOME/lib/vector.so" 2>/dev/null || true
  echo "===== TimescaleDB 扩展 ====="
  ldd "$SRC_PG_HOME/lib/"timescaledb-*.so 2>/dev/null || true
} > "$OUT/pg17-ldd.txt" 2>&1

# ---------- 汇总 ----------
echo
info "打包完成，产物如下："
ls -lh "$OUT"/pg17-*.tar.gz "$OUT"/pg17-migrate.env "$OUT"/pg17-ldd.txt 2>/dev/null || true
echo
echo "传到目标机（把 目标IP 换成实际 IP；6 个文件放同一目录）："
echo "  scp $OUT/pg17-bin.tar.gz $OUT/pg17-deps.tar.gz $OUT/pg17-syslib.tar.gz \\"
echo "      $OUT/pg17-conf.tar.gz $OUT/pg17-migrate.env $OUT/pg17-ldd.txt root@目标IP:/mnt/data/"
echo
echo "目标机部署：上传 migrate_pg17_deploy.sh 后执行  bash migrate_pg17_deploy.sh"
echo "  （部署脚本会自动扫描 /mnt/data 等目录找到迁移包，无需手填路径）"
