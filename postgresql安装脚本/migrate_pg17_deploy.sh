#!/usr/bin/env bash
# =============================================================
# migrate_pg17_deploy.sh —— 目标机一键部署脚本（交互式）
#
# 前提：已用 migrate_pg17_pack.sh 在源机打好包，并把所有
#       pg17-*.tar.gz / pg17-migrate.env 拷到本机（默认 /mnt/data）。
#
# 自动完成：
#   1. 创建 postgres 用户/组
#   2. 解压三个包（PG 程序、/usr/local 依赖、系统库）
#   3. 写 /etc/ld.so.conf.d/pg17-syslib.conf（三行）并 ldconfig
#   4. ldd 校验无缺库（缺库则中止并提示）
#   5. initdb 全新 data 目录
#   6. 覆盖源机带过来的 postgresql.conf / pg_hba.conf（自动替换路径）
#   7. 安装 postgresql17.service 并启动
#   8. 写 /etc/profile 环境变量（PG_HOME/PGDATA，与 install_postgresql.sh 一致）
#   9. CREATE EXTENSION postgis/vector/timescaledb 并验证
#
# 用法：在【目标机】上以 root 执行
#   bash migrate_pg17_deploy.sh                 # 自动扫描迁移包目录
#   bash migrate_pg17_deploy.sh /path/to/pkg    # 直接指定迁移包目录
#
# 只需关心两件事：① 源机打包产物（pg17-*.tar.gz + pg17-migrate.env）
#                ② 目标机安装位置（PG 目录、data 目录）
# 源机路径等信息已在打包时写入 pg17-migrate.env，无需再填。
# =============================================================
set -euo pipefail

info() { echo -e "\033[32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[31m[ERR ]\033[0m $*" >&2; }

[ "$(id -u)" -eq 0 ] || { err "请以 root 执行"; exit 1; }

echo "=============================================="
echo "  PostgreSQL 17 目标机部署"
echo "=============================================="

# ---------- 定位迁移包目录（含 pg17-bin.tar.gz 的目录） ----------
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PKG_DIR="${1:-}"
if [ -z "$PKG_DIR" ]; then
  for d in "$script_dir" /mnt/data /home/data /root /tmp "$PWD"; do
    if [ -f "$d/pg17-bin.tar.gz" ]; then PKG_DIR="$d"; break; fi
  done
fi

if [ -n "$PKG_DIR" ] && [ -f "$PKG_DIR/pg17-bin.tar.gz" ]; then
  info "已定位迁移包目录：$PKG_DIR"
  read -r -p "直接回车使用该目录；如包在其他位置，请输入完整目录路径: " v
  PKG_DIR=${v:-$PKG_DIR}
else
  PKG_DIR=
  echo "未在以下位置找到迁移包（pg17-bin.tar.gz）："
  echo "  ${script_dir:-(脚本目录)} /mnt/data /home/data /root /tmp 当前目录"
  read -r -p "请输入迁移包所在目录（把 pg17-*.tar.gz 全部上传到同一目录）: " PKG_DIR
fi
PKG_DIR=${PKG_DIR%/}
[ -d "$PKG_DIR" ] || { err "目录不存在：$PKG_DIR"; exit 1; }

# 从 bin 包推导默认目标 PG 目录（以源机打包的程序目录名为准，如 postgresql-17.11）
bin_top=$(tar -tzf "$PKG_DIR/pg17-bin.tar.gz" 2>/dev/null | awk -F/ 'NR==1{print $1}')
default_pg_home=/mnt/data/postgresql/${bin_top:-postgresql-17}

# ---------- 交互输入（只问目标机两件事） ----------
read -r -p "目标机 PG 安装目录 [$default_pg_home]: " PG_HOME
PG_HOME=${PG_HOME:-$default_pg_home}

read -r -p "目标机 data 数据目录（全新初始化） [/mnt/data/postgresql/data]: " PGDATA
PGDATA=${PGDATA:-/mnt/data/postgresql/data}

# 系统库解压到 PG 安装目录的同级目录 pg17-syslib，便于统一管理
# （默认 PG_HOME=/mnt/data/postgresql/postgresql-17.11 时，即 /mnt/data/postgresql/pg17-syslib）
SYSLIB="$(dirname "$PG_HOME")/pg17-syslib"

# 源机路径只从打包时生成的 pg17-migrate.env 读取（用于替换配置里的旧路径），无需填写
SRC_PG_HOME=""
SRC_PGDATA=""
if [ -f "$PKG_DIR/pg17-migrate.env" ]; then
  # shellcheck disable=SC1090
  . "$PKG_DIR/pg17-migrate.env"
  # 兼容旧包字段名 SOURCE_PGHOME
  SRC_PG_HOME=${SOURCE_PG_HOME:-${SOURCE_PGHOME:-}}
  SRC_PGDATA=${SOURCE_PGDATA:-}
fi
# 预构造路径替换表达式（后面应用配置/服务文件时统一使用）
SED_PATH_EXPR=()
[ -n "$SRC_PG_HOME" ] && SED_PATH_EXPR+=(-e "s|$SRC_PG_HOME|$PG_HOME|g")
[ -n "$SRC_PGDATA" ] && SED_PATH_EXPR+=(-e "s|$SRC_PGDATA|$PGDATA|g")

# ---------- 前置检查：缺什么一次性列清楚 ----------
missing_files=()
# bin/deps/syslib/env 为必需；conf 可选（缺失时用 initdb 默认配置 + 自动生成服务文件）
for p in pg17-bin.tar.gz pg17-deps.tar.gz pg17-syslib.tar.gz pg17-migrate.env; do
  [ -f "$PKG_DIR/$p" ] || missing_files+=("$p")
done
[ -f "$PKG_DIR/pg17-conf.tar.gz" ] || warn "缺少 pg17-conf.tar.gz，将使用 initdb 默认配置 + 自动生成服务文件"
if [ "${#missing_files[@]}" -gt 0 ]; then
  err "迁移包目录 $PKG_DIR 中缺少以下文件："
  for f in "${missing_files[@]}"; do echo "    - $f"; done
  echo
  echo "  该目录现有内容："
  ls -lh "$PKG_DIR" 2>/dev/null | sed 's/^/    /'
  echo
  echo "  已自动扫描过的位置：${script_dir:-(脚本目录)} /mnt/data /home/data /root /tmp 当前目录"
  echo "  请确认源机执行 migrate_pg17_pack.sh 后，已把全部产物（含 pg17-migrate.env）上传到同一目录。"
  exit 1
fi

echo
echo "---------- 部署参数 ----------"
echo "迁移包目录 : $PKG_DIR"
echo "PG 目录    : $PG_HOME"
echo "data 目录  : $PGDATA"
echo "系统库目录 : $SYSLIB"
if [ -n "$SRC_PG_HOME" ] || [ -n "$SRC_PGDATA" ]; then
  echo "源机路径   : $SRC_PG_HOME  $SRC_PGDATA（来自 pg17-migrate.env，仅用于配置路径替换）"
else
  warn "未读取到源机路径（pg17-migrate.env 为空），配置文件中的旧路径不会自动替换"
fi
echo "------------------------------"
read -r -p "确认开始部署？[Y/n]: " yn
[[ "${yn:-Y}" =~ ^[Nn]$ ]] && { echo "已取消"; exit 0; }

# ---------- 1. 创建 postgres 用户/组 ----------
info "1/9 创建 postgres 用户/组"
getent group postgres >/dev/null || groupadd -r postgres
id postgres >/dev/null 2>&1 || useradd -r -g postgres -m -s /bin/bash postgres
id postgres

# ---------- 2. 解压三个包 ----------
info "2/9 解压迁移包"
mkdir -p "$(dirname "$PG_HOME")" "$SYSLIB"
# 系统库：包内是 usr/lib64/...，strip 两级平铺
tar -zxf "$PKG_DIR/pg17-syslib.tar.gz" --strip-components=2 -C "$SYSLIB"
# PG 程序：包内顶层目录名（前面推导默认 PG 目录时已读取为 bin_top）；若与目标 PG_HOME 目录名不同则重命名
tar -zxf "$PKG_DIR/pg17-bin.tar.gz" -C "$(dirname "$PG_HOME")"
if [ -n "$bin_top" ] && [ "$bin_top" != "$(basename "$PG_HOME")" ]; then
  [ -e "$PG_HOME" ] && { err "$PG_HOME 已存在，无法把 $bin_top 重命名为目标目录名"; exit 1; }
  mv "$(dirname "$PG_HOME")/$bin_top" "$PG_HOME"
fi
chown -R postgres:postgres "$PG_HOME"
# 自研依赖：包内自带 usr/local/...，必须 -C / 还原
tar -zxf "$PKG_DIR/pg17-deps.tar.gz" -C /
[ -x "$PG_HOME/bin/postgres" ] || { err "解压后未找到 $PG_HOME/bin/postgres，检查 PG 目录参数"; exit 1; }
[ -f /usr/local/share/proj/proj.db ] || warn "未发现 /usr/local/share/proj/proj.db，PostGIS 投影功能可能异常"

# ---------- 3. 配置动态库搜索路径 ----------
info "3/9 写 /etc/ld.so.conf.d/pg17-syslib.conf 并刷新缓存"
cat > /etc/ld.so.conf.d/pg17-syslib.conf <<EOF
$PG_HOME/lib
/usr/local/lib
$SYSLIB
EOF
cat /etc/ld.so.conf.d/pg17-syslib.conf
ldconfig

# ---------- 4. ldd 校验 ----------
info "4/9 校验依赖库完整性"
missing=0
for f in "$PG_HOME/bin/postgres" "$PG_HOME/bin/psql" "$PG_HOME/lib/"*.so; do
  out=$(ldd "$f" 2>/dev/null | grep 'not found' || true)
  if [ -n "$out" ]; then
    echo "$f:"; echo "$out"; missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  err "存在缺失库。请按《迁移操作.md》Q9/Q10 从源机补拷到 $SYSLIB 后 ldconfig，再重跑本脚本"
  exit 1
fi
"$PG_HOME/bin/postgres" --version
info "    依赖库全部就位"

# ---------- 5. initdb ----------
info "5/9 初始化 data 目录"
if [ -s "$PGDATA/PG_VERSION" ]; then
  warn "    $PGDATA 已初始化（发现 PG_VERSION），跳过 initdb"
else
  mkdir -p "$PGDATA"
  chown -R postgres:postgres "$PGDATA"
  chmod 700 "$PGDATA"
  su - postgres -c "$PG_HOME/bin/initdb -D $PGDATA --encoding=UTF8 --locale=C -U postgres"
fi

# ---------- 6. 覆盖源机配置文件 ----------
info "6/9 应用源机配置 postgresql.conf / pg_hba.conf"
conf_tmp=$(mktemp -d)
if [ -f "$PKG_DIR/pg17-conf.tar.gz" ]; then
  tar -zxf "$PKG_DIR/pg17-conf.tar.gz" -C "$conf_tmp"
  if [ "${#SED_PATH_EXPR[@]}" -eq 0 ]; then
    warn "    无 pg17-migrate.env 源机路径信息，配置文件中的旧路径不会替换，请部署后人工核对 data_directory / hba_file 等路径配置"
  fi
  for f in postgresql.conf pg_hba.conf; do
    if [ -f "$conf_tmp/$f" ]; then
      cp -a "$conf_tmp/$f" "$PGDATA/$f"
      # 把源机绝对路径替换为目标机路径（源机路径缺失时 SED_PATH_EXPR 为空，sed 仅做空操作有风险，故守卫）
      if [ "${#SED_PATH_EXPR[@]}" -gt 0 ]; then
        sed -i "${SED_PATH_EXPR[@]}" "$PGDATA/$f"
      fi
      chown postgres:postgres "$PGDATA/$f"
      info "    已应用 $f"
    fi
  done
else
  # 没有带来配置：写最小必要配置
  echo "listen_addresses = '*'" >> "$PGDATA/postgresql.conf"
  echo "port = 5432" >> "$PGDATA/postgresql.conf"
  chown postgres:postgres "$PGDATA/postgresql.conf"
fi
# 保证 timescaledb 预加载（源机配置一般已带；此处兜底）
if ! grep -q "shared_preload_libraries.*timescaledb" "$PGDATA/postgresql.conf"; then
  warn "    配置中未发现 shared_preload_libraries 含 timescaledb，自动追加"
  echo "shared_preload_libraries = 'timescaledb'" >> "$PGDATA/postgresql.conf"
  chown postgres:postgres "$PGDATA/postgresql.conf"
fi
# 提示用户核对可能与源机环境相关的项
grep -nE '^(port|listen_addresses|archive_|log_directory)' "$PGDATA/postgresql.conf" 2>/dev/null || true
# 从配置里取端口（源机配置可能改过端口），供后续 pg_isready/psql 使用
PORT=$(awk -F= '/^[[:space:]]*port[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$PGDATA/postgresql.conf")
PORT=${PORT:-5432}
info "    数据库端口：$PORT"

# ---------- 7. 安装并启动 systemd 服务 ----------
info "7/9 配置 postgresql17.service 并启动"
if [ -f "$conf_tmp/postgresql17.service" ] && [ "${#SED_PATH_EXPR[@]}" -gt 0 ]; then
  sed "${SED_PATH_EXPR[@]}" \
    "$conf_tmp/postgresql17.service" > /etc/systemd/system/postgresql17.service
  info "    已使用源机带来的服务文件（路径已替换为目标机）"
else
  # 无源机服务文件，或有源机服务文件但缺源机路径信息（无法可靠替换路径），均自动生成
  [ -f "$conf_tmp/postgresql17.service" ] && \
    warn "    有源机服务文件但缺少源机路径信息（pg17-migrate.env），改用自动生成服务文件"
  cat > /etc/systemd/system/postgresql17.service <<EOF
[Unit]
Description=PostgreSQL 17 Server
After=network.target

[Service]
Type=forking
User=postgres
Group=postgres
PIDFile=$PGDATA/postmaster.pid
ExecStart=$PG_HOME/bin/pg_ctl start -D $PGDATA -l $PGDATA/postgresql.log
ExecStop=$PG_HOME/bin/pg_ctl stop -D $PGDATA
ExecReload=$PG_HOME/bin/pg_ctl reload -D $PGDATA
Restart=on-failure
RestartSec=5s
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF
  info "    已自动生成服务文件"
fi
rm -rf "$conf_tmp"
chmod 644 /etc/systemd/system/postgresql17.service
systemctl daemon-reload
systemctl enable postgresql17
if ! systemctl restart postgresql17; then
  err "服务启动失败，最近日志如下："
  tail -50 "$PGDATA/postgresql.log" 2>/dev/null || true
  exit 1
fi

# 等待就绪（最多 30 秒；端口从配置里解析，兼容改过端口的情况）
for i in $(seq 1 30); do
  "$PG_HOME/bin/pg_isready" -p "$PORT" -q && break
  sleep 1
done
if ! "$PG_HOME/bin/pg_isready" -p "$PORT" -q; then
  err "服务未能就绪，请检查日志：tail -100 $PGDATA/postgresql.log"
  systemctl status postgresql17 --no-pager || true
  exit 1
fi
systemctl status postgresql17 --no-pager | head -5 || true

# ---------- 8. 写环境变量到 /etc/profile（与 install_postgresql.sh 同一套变量名） ----------
info "8/9 写入 PostgreSQL 环境变量到 /etc/profile"
cp /etc/profile "/etc/profile.backup.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
# 幂等：先剔除旧块再追加
sed -i '/# PostgreSQL Environment/,/# End PostgreSQL Environment/d' /etc/profile
cat >> /etc/profile <<EOF

# PostgreSQL Environment
export PG_HOME=$PG_HOME
export PGDATA=$PGDATA
export PATH=\$PG_HOME/bin:\$PATH
export MANPATH=\$PG_HOME/share/man:\$MANPATH
# End PostgreSQL Environment
EOF
info "    已写入 PG_HOME=$PG_HOME、PGDATA=$PGDATA（重新登录或 source /etc/profile 后生效）"

# ---------- 9. 创建扩展并验证 ----------
info "9/9 创建扩展并验证"
su - postgres -c "$PG_HOME/bin/psql -p $PORT -d postgres -c 'CREATE EXTENSION IF NOT EXISTS postgis;'"
su - postgres -c "$PG_HOME/bin/psql -p $PORT -d postgres -c 'CREATE EXTENSION IF NOT EXISTS vector;'"
su - postgres -c "$PG_HOME/bin/psql -p $PORT -d postgres -c 'CREATE EXTENSION IF NOT EXISTS timescaledb;'"
echo
su - postgres -c "$PG_HOME/bin/psql -p $PORT -d postgres -c '\dx'"
echo
su - postgres -c "$PG_HOME/bin/psql -p $PORT -d postgres -t -c 'SELECT postgis_full_version();'"

echo
info "部署完成。远程连接请确认 pg_hba.conf 已放行网段、防火墙开放端口。"
