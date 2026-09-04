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
#   8. CREATE EXTENSION postgis/vector/timescaledb 并验证
#
# 用法：在【目标机】上以 root 执行  bash migrate_pg17_deploy.sh
# =============================================================
set -euo pipefail

info() { echo -e "\033[32m[INFO]\033[0m $*"; }
warn() { echo -e "\033[33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[31m[ERR ]\033[0m $*" >&2; }

[ "$(id -u)" -eq 0 ] || { err "请以 root 执行"; exit 1; }

echo "=============================================="
echo "  PostgreSQL 17 目标机部署"
echo "=============================================="

# ---------- 交互输入 ----------
read -r -p "迁移包所在目录 [/mnt/data]: " PKG_DIR
PKG_DIR=${PKG_DIR:-/mnt/data}

read -r -p "目标机 PG 安装目录 [/mnt/data/postgresql/postgresql-17.9]: " PGHOME
PGHOME=${PGHOME:-/mnt/data/postgresql/postgresql-17.9}

read -r -p "目标机 data 数据目录（全新初始化） [/mnt/data/postgresql/data]: " PGDATA
PGDATA=${PGDATA:-/mnt/data/postgresql/data}

read -r -p "系统库解压目录 [$PKG_DIR/pg17-syslib]: " SYSLIB
SYSLIB=${SYSLIB:-$PKG_DIR/pg17-syslib}

# 读取源机路径清单（用于替换配置文件里的旧路径）
SRC_PGHOME=/home/data/postgresql/postgresql-17.9
SRC_PGDATA=/home/data/postgresql/data
if [ -f "$PKG_DIR/pg17-migrate.env" ]; then
  # shellcheck disable=SC1090
  . "$PKG_DIR/pg17-migrate.env"
  # 清单里的变量名是 SOURCE_*，映射到本脚本的 SRC_*
  SRC_PGHOME=${SOURCE_PGHOME:-$SRC_PGHOME}
  SRC_PGDATA=${SOURCE_PGDATA:-$SRC_PGDATA}
fi
read -r -p "源机 PG 目录（用于替换配置中的旧路径） [$SRC_PGHOME]: " v
SRC_PGHOME=${v:-$SRC_PGHOME}
read -r -p "源机 data 目录 [$SRC_PGDATA]: " v
SRC_PGDATA=${v:-$SRC_PGDATA}

# ---------- 前置检查 ----------
for p in pg17-bin.tar.gz pg17-deps.tar.gz pg17-syslib.tar.gz; do
  [ -f "$PKG_DIR/$p" ] || { err "缺少 $PKG_DIR/$p"; exit 1; }
done
[ -f "$PKG_DIR/pg17-conf.tar.gz" ] || warn "缺少 pg17-conf.tar.gz，将使用 initdb 默认配置 + 自动生成服务文件"

echo
echo "---------- 部署参数 ----------"
echo "迁移包目录 : $PKG_DIR"
echo "PG 目录    : $PGHOME"
echo "data 目录  : $PGDATA"
echo "系统库目录 : $SYSLIB"
echo "源机 PG    : $SRC_PGHOME"
echo "源机 data  : $SRC_PGDATA"
echo "------------------------------"
read -r -p "确认开始部署？[Y/n]: " yn
[[ "${yn:-Y}" =~ ^[Nn]$ ]] && { echo "已取消"; exit 0; }

# ---------- 1. 创建 postgres 用户/组 ----------
info "1/8 创建 postgres 用户/组"
getent group postgres >/dev/null || groupadd -r postgres
id postgres >/dev/null 2>&1 || useradd -r -g postgres -m -s /bin/bash postgres
id postgres

# ---------- 2. 解压三个包 ----------
info "2/8 解压迁移包"
mkdir -p "$(dirname "$PGHOME")" "$SYSLIB"
# 系统库：包内是 usr/lib64/...，strip 两级平铺
tar -zxf "$PKG_DIR/pg17-syslib.tar.gz" --strip-components=2 -C "$SYSLIB"
# PG 程序：包内顶层目录名以源机打包时为准；若与目标 PGHOME 目录名不同则重命名
# （awk 读全量，避免 tar|head 的 SIGPIPE 在 pipefail 下误判）
pg_top=$(tar -tzf "$PKG_DIR/pg17-bin.tar.gz" 2>/dev/null | awk -F/ 'NR==1{print $1}')
tar -zxf "$PKG_DIR/pg17-bin.tar.gz" -C "$(dirname "$PGHOME")"
if [ -n "$pg_top" ] && [ "$pg_top" != "$(basename "$PGHOME")" ]; then
  [ -e "$PGHOME" ] && { err "$PGHOME 已存在，无法把 $pg_top 重命名为目标目录名"; exit 1; }
  mv "$(dirname "$PGHOME")/$pg_top" "$PGHOME"
fi
chown -R postgres:postgres "$PGHOME"
# 自研依赖：包内自带 usr/local/...，必须 -C / 还原
tar -zxf "$PKG_DIR/pg17-deps.tar.gz" -C /
[ -x "$PGHOME/bin/postgres" ] || { err "解压后未找到 $PGHOME/bin/postgres，检查 PG 目录参数"; exit 1; }
[ -f /usr/local/share/proj/proj.db ] || warn "未发现 /usr/local/share/proj/proj.db，PostGIS 投影功能可能异常"

# ---------- 3. 配置动态库搜索路径 ----------
info "3/8 写 /etc/ld.so.conf.d/pg17-syslib.conf 并刷新缓存"
cat > /etc/ld.so.conf.d/pg17-syslib.conf <<EOF
$PGHOME/lib
/usr/local/lib
$SYSLIB
EOF
cat /etc/ld.so.conf.d/pg17-syslib.conf
ldconfig

# ---------- 4. ldd 校验 ----------
info "4/8 校验依赖库完整性"
missing=0
for f in "$PGHOME/bin/postgres" "$PGHOME/bin/psql" "$PGHOME/lib/"*.so; do
  out=$(ldd "$f" 2>/dev/null | grep 'not found' || true)
  if [ -n "$out" ]; then
    echo "$f:"; echo "$out"; missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  err "存在缺失库。请按《迁移操作.md》Q9/Q10 从源机补拷到 $SYSLIB 后 ldconfig，再重跑本脚本"
  exit 1
fi
"$PGHOME/bin/postgres" --version
info "    依赖库全部就位"

# ---------- 5. initdb ----------
info "5/8 初始化 data 目录"
if [ -s "$PGDATA/PG_VERSION" ]; then
  warn "    $PGDATA 已初始化（发现 PG_VERSION），跳过 initdb"
else
  mkdir -p "$PGDATA"
  chown -R postgres:postgres "$PGDATA"
  chmod 700 "$PGDATA"
  su - postgres -c "$PGHOME/bin/initdb -D $PGDATA --encoding=UTF8 --locale=C -U postgres"
fi

# ---------- 6. 覆盖源机配置文件 ----------
info "6/8 应用源机配置 postgresql.conf / pg_hba.conf"
conf_tmp=$(mktemp -d)
if [ -f "$PKG_DIR/pg17-conf.tar.gz" ]; then
  tar -zxf "$PKG_DIR/pg17-conf.tar.gz" -C "$conf_tmp"
  for f in postgresql.conf pg_hba.conf; do
    if [ -f "$conf_tmp/$f" ]; then
      cp -a "$conf_tmp/$f" "$PGDATA/$f"
      # 把源机绝对路径替换为目标机路径
      sed -i "s|$SRC_PGHOME|$PGHOME|g; s|$SRC_PGDATA|$PGDATA|g" "$PGDATA/$f"
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
info "7/8 配置 postgresql17.service 并启动"
if [ -f "$conf_tmp/postgresql17.service" ]; then
  sed "s|$SRC_PGHOME|$PGHOME|g; s|$SRC_PGDATA|$PGDATA|g" \
    "$conf_tmp/postgresql17.service" > /etc/systemd/system/postgresql17.service
  info "    已使用源机带来的服务文件（路径已替换为目标机）"
else
  cat > /etc/systemd/system/postgresql17.service <<EOF
[Unit]
Description=PostgreSQL 17 Server
After=network.target

[Service]
Type=forking
User=postgres
Group=postgres
PIDFile=$PGDATA/postmaster.pid
ExecStart=$PGHOME/bin/pg_ctl start -D $PGDATA -l $PGDATA/postgresql.log
ExecStop=$PGHOME/bin/pg_ctl stop -D $PGDATA
ExecReload=$PGHOME/bin/pg_ctl reload -D $PGDATA
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
  "$PGHOME/bin/pg_isready" -p "$PORT" -q && break
  sleep 1
done
if ! "$PGHOME/bin/pg_isready" -p "$PORT" -q; then
  err "服务未能就绪，请检查日志：tail -100 $PGDATA/postgresql.log"
  systemctl status postgresql17 --no-pager || true
  exit 1
fi
systemctl status postgresql17 --no-pager | head -5 || true

# ---------- 8. 创建扩展并验证 ----------
info "8/8 创建扩展并验证"
su - postgres -c "$PGHOME/bin/psql -p $PORT -d postgres -c 'CREATE EXTENSION IF NOT EXISTS postgis;'"
su - postgres -c "$PGHOME/bin/psql -p $PORT -d postgres -c 'CREATE EXTENSION IF NOT EXISTS vector;'"
su - postgres -c "$PGHOME/bin/psql -p $PORT -d postgres -c 'CREATE EXTENSION IF NOT EXISTS timescaledb;'"
echo
su - postgres -c "$PGHOME/bin/psql -p $PORT -d postgres -c '\dx'"
echo
su - postgres -c "$PGHOME/bin/psql -p $PORT -d postgres -t -c 'SELECT postgis_full_version();'"

echo
info "部署完成。远程连接请确认 pg_hba.conf 已放行网段、防火墙开放端口。"
