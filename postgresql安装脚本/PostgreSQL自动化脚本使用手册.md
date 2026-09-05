# PostgreSQL 自动化脚本使用手册

> 一套完整的 PostgreSQL 安装、配置、WAL归档管理和卸载自动化脚本

---

## 📋 目录

1. [脚本概览](#脚本概览)
2. [快速开始](#快速开始)
3. [安装脚本详解](#安装脚本详解)
4. [WAL归档管理](#wal归档管理)
5. [卸载脚本](#卸载脚本)
6. [常见问题](#常见问题)

---

## 📌 脚本概览

### 脚本列表

| 脚本名称 | 功能说明 | 权限要求 |
|---------|---------|---------|
| `install_postgresql.sh` | PostgreSQL 安装脚本 | root |
| `postgresql_wal_archive_manager.sh` | WAL归档管理脚本 | root (setup/cron模式) |
| `uninstall_postgresql.sh` | PostgreSQL 完全卸载脚本 | root |

### 支持的特性

- **多版本支持**：PostgreSQL 12.x ~ 18.x
- **多架构支持**：x86_64、ARM64
- **双安装模式**：在线安装、离线安装
- **镜像源选择**：官网镜像、腾讯云镜像（国内加速）
- **下载重试机制**：自动重试、文件完整性验证
- **插件依赖检查**：自动检查并安装插件依赖
- **插件系统**：openssl、perl、python、tcl、uuid、xml、icu、ldap、pam、systemd、bonjour
- **pgvector 向量扩展**：独立第三方扩展，用 `pg_config` 单独编译，在线自动下载源码、离线支持本地源码包
- **PostGIS 空间扩展**：独立第三方扩展（3.5.7），autotools 构建，在线自动下载源码、离线支持本地源码包，自动检测并安装 geos/proj/gdal 等依赖；老系统（如 CentOS 7）GEOS<3.8 / PROJ<6 时自动源码编译 GEOS 3.9.3 / PROJ 6.3.2 到 `/usr/local`
- **TimescaleDB 时序扩展**：独立第三方扩展（2.29.2），cmake 构建，自动配置 `shared_preload_libraries` 并重启数据库后注册扩展
- **pg_textsearch 全文检索扩展**：Timescale 出品的 BM25 全文检索扩展（1.4.0），仅支持 PostgreSQL 17/18；**优先使用官方预编译包免编译部署**（拷贝 `.so`/`.control`/`.sql`），无预编译包时回退源码 `make` 编译；需配置 `shared_preload_libraries` 并重启后注册扩展
- **ICU 可用性探测**：采用真实编译+链接测试，避免仅有头文件而缺开发库导致的链接失败
- **路径默认值**：离线 tar 包路径留空时默认使用脚本所在目录
- **临时文件清理**：安装完成后自动清理临时文件（含 pgvector / PostGIS / TimescaleDB / pg_textsearch 构建目录）
- **WAL归档**：完整归档配置、自动清理、定时清理、智能清理

---

## 🚀 快速开始

### 一键安装 PostgreSQL

```bash
# 赋予执行权限
chmod +x install_postgresql.sh

# 运行安装脚本
sudo ./install_postgresql.sh
```

### 配置 WAL 归档

```bash
# 完整配置WAL归档（推荐）
sudo ./postgresql_wal_archive_manager.sh setup

# 快速配置定时清理
sudo ./postgresql_wal_archive_manager.sh cron -d 7
```

### 完全卸载

```bash
# 自动搜索并卸载
sudo ./uninstall_postgresql.sh

# 跳过确认直接卸载
sudo ./uninstall_postgresql.sh -y
```

---

## 📥 安装脚本详解

### install_postgresql.sh

#### 功能特点

```
┌─────────────────────────────────────────────────────────────┐
│              PostgreSQL 安装向导                             │
├─────────────────────────────────────────────────────────────┤
│  ✅ 在线下载安装 - 从 PostgreSQL FTP 下载源码               │
│  ✅ 镜像源选择 - 官网镜像/腾讯云镜像（国内加速）             │
│  ✅ 下载重试机制 - 自动重试、文件完整性验证                  │
│  ✅ 离线安装 - 使用本地 tar.gz 包                            │
│  ✅ 插件依赖检查 - 自动检查并安装插件依赖                    │
│  ✅ 插件选择 - 10+ 可选插件                                  │
│  ✅ 自动配置 - systemd 服务、环境变量                        │
│  ✅ 临时文件清理 - 安装完成后自动清理                        │
│  ✅ 远程访问 - Navicat 连接配置                              │
└─────────────────────────────────────────────────────────────┘
```

#### 安装模式

##### 1️⃣ 在线安装模式

```bash
# 完整在线安装（交互式）
sudo ./install_postgresql.sh

# 选择菜单：
# 1. 完整在线安装
# 2. 直接初始化数据库（已编译）
# 3. 安装 contrib 扩展
# 4. 离线安装
# m. 选择下载镜像源（当前: 官网镜像）
```

**安装流程**：

```
选择镜像源 → 选择版本 → 下载源码 → 安装依赖 → 编译安装 → 初始化数据库 → 启动服务
```

##### 1️⃣1️⃣ 镜像源选择

```bash
# 在主菜单选择 m 进入镜像源选择
sudo ./install_postgresql.sh
# 选择: m

# 可选镜像源：
# 1. 官网镜像 (https://ftp.postgresql.org)
# 2. 腾讯云镜像 (https://mirrors.cloud.tencent.com) - 国内推荐
```

**镜像源说明**：

| 镜像源 | 地址 | 推荐场景 |
|-------|------|---------|
| 官网镜像 | https://ftp.postgresql.org | 国外服务器 |
| 腾讯云镜像 | https://mirrors.cloud.tencent.com | 国内服务器（推荐） |

> 💡 **提示**：首次安装时会提示选择镜像源，也可在配置确认阶段更换镜像源。

##### 2️⃣ 离线安装模式

```bash
# 准备离线包
# 1. 提前下载 postgresql-18.1.tar.gz
# 2. 上传到服务器

# 运行离线安装
sudo ./install_postgresql.sh

# 选择 "4. 离线安装"
# 输入 tar.gz 包路径（直接回车则默认使用脚本所在目录）
```

> 💡 **路径默认值**：提示输入离线 tar 包路径时，**直接回车**即默认使用脚本当前所在目录，无需手动填写。

> 📦 **离线安装第三方扩展**：离线模式不会联网下载第三方扩展。请提前在联网机下载源码包，与 PostgreSQL tar 包放在同一目录（或放到 `/tmp`）。下载时把 URL 末尾版本号替换为目标版本即可：
> ```bash
> # pgvector（版本发布页 https://github.com/pgvector/pgvector/releases ）
> wget https://github.com/pgvector/pgvector/archive/refs/tags/v0.8.6.tar.gz -O pgvector-0.8.6.tar.gz
>
> # PostGIS 3.5.7（codeload 源码包，解压目录为 postgis-3.5.7）
> wget https://codeload.github.com/postgis/postgis/tar.gz/refs/tags/3.5.7 -O postgis-3.5.7.tar.gz
>
> # 老系统（CentOS 7 等）GEOS/PROJ 版本过低，PostGIS 编译前需源码升级（可选，详见 PostGIS 专节）
> wget https://download.osgeo.org/geos/geos-3.9.3.tar.bz2
> wget https://download.osgeo.org/proj/proj-6.3.2.tar.gz
>
> # TimescaleDB 2.29.2（codeload 源码包，解压目录为 timescaledb-2.29.2）
> wget https://codeload.github.com/timescale/timescaledb/tar.gz/refs/tags/2.29.2 -O timescaledb-2.29.2.tar.gz
>
> # pg_textsearch 1.4.0 —— 推荐预编译二进制包（免编译，按 PG 大版本选择 pg17 或 pg18）
> wget https://github.com/timescale/pg_textsearch/releases/download/v1.4.0/pg_textsearch-pg17-v1.4.0.tar.gz
> #   若目标机缺编译工具链或预编译包不可用，再备源码包（纯 C / PGXS make 编译）：
> wget https://github.com/timescale/pg_textsearch/archive/refs/tags/v1.4.0.tar.gz -O pg_textsearch-1.4.0.tar.gz
> ```
> 也可解压后把源码目录放到上述位置（pgvector 目录需含 `Makefile` 与 `vector.control`；PostGIS 目录顶层需含 `GNUmakefile.in`（`postgis.control.in` 实际在 `extensions/postgis/` 子目录）；TimescaleDB 目录需含 `bootstrap` 与 `timescaledb.control.in`）。脚本会按扩展标记自动识别，并归一化到真正的源码根目录（含 `configure`/`bootstrap` 的那一层）。
>
> **pg_textsearch 离线准备（两种方式，二选一）**：①（推荐）预编译包 `pg_textsearch-pg17-v1.4.0.tar.gz`（PG18 换成 `pg18`）——直接放上述目录即可，脚本自动解压并拷贝文件，**目标机无需 gcc/make**；② 源码包 `pg_textsearch-1.4.0.tar.gz`（或解压后含 `Makefile` 与 `pg_textsearch.control` 的目录）——目标机需有 gcc、make。预编译包与源码包同时存在时，**优先使用预编译包**。注意预编译包按 PostgreSQL 大版本发布，务必下载与目标库一致的 `pg17`/`pg18` 包。
>
> ⚠️ **PostGIS 注意**：从 GitHub/codeload 下载的源码包**不含已生成的 `configure`**（只有 `configure.ac` 与 `autogen.sh`）。脚本会自动运行 `./autogen.sh` 生成（需目标机装有 `autoconf`/`automake`/`libtool`，依赖检查阶段会自动安装）；若下载的是 PostGIS 官方 make dist 发布包（自带 `configure`），则跳过此步骤直接编译。

#### 可选插件

| 插件 | 说明 | 依赖 |
|-----|------|------|
| openssl | SSL/TLS 加密 | openssl-devel |
| perl | Perl 存储过程 | perl-devel |
| python | Python 存储过程 | python3-devel |
| tcl | Tcl 存储过程 | tcl-devel |
| uuid | UUID 生成 | uuid-devel / libossp-uuid-devel |
| xml | XML 数据类型 | libxml2-devel |
| icu | 国际化支持（排序/字符序） | libicu-devel |
| ldap | LDAP 认证 | openldap-devel |
| pam | PAM 认证 | pam-devel |
| systemd | systemd 集成 | systemd-devel |
| bonjour | Bonjour 服务发现 | avahi-devel |
| pgvector | 向量检索扩展（独立扩展，非 `./configure` 插件） | gcc、make、pg_config |
| postgis | 空间/GIS 扩展（独立扩展，autotools 构建） | geos≥3.8、proj≥6（老系统自动源码编译 GEOS 3.9.3/PROJ 6.3.2）、gdal、json-c、libxml2、protobuf-c |
| timescaledb | 时序数据库扩展（独立扩展，cmake 构建，需 preload 并重启） | cmake ≥ 3.15（CentOS 7 用 cmake3）、gcc、openssl-devel |
| pg_textsearch | BM25 全文检索扩展（独立扩展，Timescale 出品，仅 PG17/18，需 preload 并重启） | **推荐预编译包：免依赖**；源码编译回退需 gcc、make、pg_config |

> ⚠️ **UUID插件说明**：脚本会自动检测系统中可用的UUID库（e2fsprogs或OSSP），优先使用e2fsprogs。如两者都未安装，会尝试自动安装。

> ⚠️ **ICU 探测说明**：ICU 是否可用通过**真实编译+链接测试**判定（调用 `u_strToLower`/`ucol_open` 试编译），而非仅检查头文件。某些系统（如 CentOS 7）自带 ICU 头文件但缺少可链接的开发库（`libicuuc.so`），仅检测头文件会误判为可用、导致 make 阶段报 `undefined reference to u_xxx_50`。探测不通过时，可选择在线安装 `libicu-devel` 后复测，或改用 `--without-icu`。**不启用 ICU 不影响数据库核心功能**，仅排序规则使用 libc 提供者（详见 [FAQ：ICU 相关](#q8-不启用-icu-有什么影响)）。

---

#### pgvector 向量扩展

pgvector 提供向量类型 `vector` 与相似度检索（`<->`/`<=>`/`<#>`），是**独立第三方扩展**，不在 PostgreSQL 源码树内，也没有 `./configure --with-xxx` 开关。脚本在 PostgreSQL 主程序编译安装完成后，使用已安装的 `pg_config` 单独编译它。

**安装机制（两步）**：

1. **编译安装文件**（不需要数据库运行）：定位/下载 pgvector 源码 → `make PG_CONFIG=<prefix>/bin/pg_config` → `make install`，仅把 `vector.so`、`vector.control`、`vector--*.sql` 拷贝到 PostgreSQL 安装目录。
2. **在库内注册扩展**（需要数据库运行）：服务启动后自动执行 `CREATE EXTENSION IF NOT EXISTS vector;`。扩展按数据库生效，需要在每个要用向量检索的库中单独创建（脚本默认在 `postgres` 库创建）。

> 💡 跳过"启动数据库"**不影响** pgvector 文件安装；只是 `CREATE EXTENSION` 会被跳过，待服务启动后手动执行即可。

**源码获取顺序**（脚本依次尝试）：

1. 已解压源码：在 `脚本所在目录`、`/tmp`、`离线tar包同级目录`、`当前目录`、`/tmp/pgvector_build` 中递归查找含 `vector.control` 的目录；
2. 本地压缩包：匹配 `pgvector-*.tar.gz` 或 `v<版本>.tar.gz` 并解压；
3. 以上都没有时：
   - **在线模式**：自动从 GitHub 下载（见下）；
   - **离线模式**：不下载，打印手动下载指引后跳过（不影响 PostgreSQL 主程序）。

**在线下载地址**（版本由变量 `PGVECTOR_VERSION` 控制，默认 `0.8.6`）：

```
https://github.com/pgvector/pgvector/archive/refs/tags/v<PGVECTOR_VERSION>.tar.gz
# 默认拼接为：
https://github.com/pgvector/pgvector/archive/refs/tags/v0.8.6.tar.gz
```

> 📌 **版本下载地址（可自行替换版本号）**：
> - 版本发布页（浏览/选择版本）：<https://github.com/pgvector/pgvector/releases>
> - 指定版本页面（如 v0.8.6）：<https://github.com/pgvector/pgvector/releases/tag/v0.8.6>
> - 直接下载源码包（把 URL 末尾的版本号换成需要的版本即可，脚本即用此地址）：
>   `https://github.com/pgvector/pgvector/archive/refs/tags/v0.8.6.tar.gz`

可通过环境变量指定版本：

```bash
export PGVECTOR_VERSION=0.8.6
sudo ./install_postgresql.sh
```

**离线环境准备**：在联网机下载后，把压缩包（或解压后的源码目录，需含 `Makefile` 与 `vector.control`）放到脚本目录、PostgreSQL tar 包同级目录或 `/tmp`：

```bash
# 下载指定版本（版本号可自行替换，发布页见 https://github.com/pgvector/pgvector/releases ）
wget https://github.com/pgvector/pgvector/archive/refs/tags/v0.8.6.tar.gz -O pgvector-0.8.6.tar.gz
```

**事后加装**：已装好的 PostgreSQL 也可通过主菜单 `3 → 1（外部插件向导）` 输入 `pgvector` 单独加装，无需重新编译 PostgreSQL。

**手动启用扩展**（服务未运行而跳过时）：

```bash
# 启动数据库后，在目标库执行
<prefix>/bin/psql -U postgres -d <数据库名> -c "CREATE EXTENSION vector;"
```

---

#### PostGIS 空间扩展

PostGIS 为 PostgreSQL 增加地理空间（GIS）类型与函数（`geometry`/`geography`、空间索引、投影变换等）。它与 pgvector 一样是**独立第三方扩展**，不在 PostgreSQL 源码树内，没有 `./configure --with-xxx` 开关；脚本在主程序编译安装完成后，用已安装的 `pg_config` 单独编译。默认版本 `3.5.7`（由变量 `POSTGIS_VERSION` 控制）。

**安装机制（两步）**：

1. **编译安装文件**（不需要数据库运行）：定位/下载 PostGIS 源码 → （GEOS/PROJ 版本不达标时自动源码编译到 `/usr/local`）→ `./configure --with-pgconfig=<prefix>/bin/pg_config --with-geosconfig=... --with-projdir=...` → `make && make install`。若完整特性（raster/topology）因依赖缺失 configure 失败，脚本会自动回退为 `./configure ... --without-raster --without-topology` 再编译。
2. **在库内注册扩展**（需要数据库运行）：服务启动后自动执行 `CREATE EXTENSION IF NOT EXISTS postgis;`（默认在 `postgres` 库）。扩展按数据库生效，需要在每个要用空间功能的库中单独创建。

**核心依赖版本要求（重要）**：PostGIS 3.5 要求 **GEOS ≥ 3.8**、**PROJ ≥ 4.9（脚本统一要求 ≥ 6）**。CentOS 7 等老系统自带源里的 GEOS 仅 **3.4.2**、PROJ 仅 **4.8**，版本过低会导致 configure 报 `PostGIS requires GEOS >= 3.8.0`。脚本在 configure 前会先用 `geos-config --version` / `pkg-config --modversion proj` 检测版本，**不达标时自动从源码编译安装到 `/usr/local`**（并配置 `PATH`/`LD_LIBRARY_PATH`/`PKG_CONFIG_PATH`、写入 `ld.so.conf.d` 后 `ldconfig`）：

| 依赖 | 自动编译版本 | 选该版本的原因 | 下载地址 |
|-----|-------------|---------------|---------|
| GEOS | **3.9.3**（变量 `GEOS_VERSION`） | GEOS 3.10+ 需 C++14/17，而 CentOS 7 的 gcc 4.8.5 仅支持 C++11；3.9.x 用 autotools 构建且满足 ≥3.8 | `https://download.osgeo.org/geos/geos-3.9.3.tar.bz2` |
| PROJ | **6.3.2**（变量 `PROJ_VERSION`） | PROJ 7+ 改用 cmake 且强制依赖 sqlite3/tiff；6.3.2 用 autotools、自带 datumgrid 栅格，更稳妥 | `https://download.osgeo.org/proj/proj-6.3.2.tar.gz` |

> 编译 GEOS 需 `gcc-c++ make bzip2`（解压 `.tar.bz2`），编译 PROJ 需 `gcc-c++ make sqlite-devel`，脚本会在编译前自动安装这些工具链。

**其它系统依赖**（脚本通过 `pkg-config` 与头文件检测，缺失时自动安装）：

| 系统 | 依赖包 |
|-----|-------|
| CentOS/RHEL | `geos-devel proj-devel proj-epsg gdal-devel json-c-devel libxml2-devel protobuf-c-devel` |
| Debian/Ubuntu | `libgeos-dev libproj-dev libgdal-dev libjson-c-dev libxml2-dev libprotobuf-c-dev` |

> 💡 PostGIS **不需要** `shared_preload_libraries`，编译安装后即可直接 `CREATE EXTENSION`。

**在线下载地址**（codeload，版本由 `POSTGIS_VERSION` 控制）：

```
https://codeload.github.com/postgis/postgis/tar.gz/refs/tags/<POSTGIS_VERSION>
# 默认拼接为：
https://codeload.github.com/postgis/postgis/tar.gz/refs/tags/3.5.7
# 下载后解压目录为 postgis-3.5.7
wget https://codeload.github.com/postgis/postgis/tar.gz/refs/tags/3.5.7 -O postgis-3.5.7.tar.gz
```

可通过环境变量指定版本：

```bash
export POSTGIS_VERSION=3.5.7
sudo ./install_postgresql.sh
```

**离线环境准备**：在联网机下载后，把压缩包（或解压后的源码目录，顶层含 `GNUmakefile.in`、子目录 `extensions/postgis/` 内含 `postgis.control.in`）放到脚本目录、PostgreSQL tar 包同级目录或 `/tmp`。脚本会自动识别并定位到源码根。

> **离线老系统（如 CentOS 7）还需提前准备 GEOS/PROJ 源码包**：因系统自带 GEOS 3.4 / PROJ 4.8 版本过低，脚本需源码编译升级。离线环境无法联网下载时，请预先把下面两个包一并放到脚本目录 / tar 同级目录 / `/tmp`（脚本本地优先识别 `geos-[0-9]*.tar.*`、`proj-[0-9]*.tar.*`）：
>
> ```
> wget https://download.osgeo.org/geos/geos-3.9.3.tar.bz2
> wget https://download.osgeo.org/proj/proj-6.3.2.tar.gz
> ```

> 说明：codeload/GitHub 源码包顶层没有已生成的 `configure`（只有 `autogen.sh`），脚本会自动运行 `./autogen.sh` 生成（需 `autoconf`/`automake`/`libtool`）；官方 make dist 发布包自带 `configure`，可直接编译。

**事后加装**：已装好的 PostgreSQL 可通过主菜单 `3 → 1（外部插件向导）` 输入 `postgis` 单独加装，无需重新编译 PostgreSQL。

**手动启用扩展**（服务未运行而跳过时）：

```bash
<prefix>/bin/psql -U postgres -d <数据库名> -c "CREATE EXTENSION postgis;"
```

---

#### TimescaleDB 时序扩展

TimescaleDB 为 PostgreSQL 提供时序数据能力（hypertable、自动分区、连续聚合等）。同样是**独立第三方扩展**，使用 **cmake** 构建。默认版本 `2.29.2`（由变量 `TIMESCALEDB_VERSION` 控制）。

**安装机制（三步）**：

1. **编译安装文件**（不需要数据库运行）：定位/下载源码 → `./bootstrap -DPG_CONFIG=<prefix>/bin/pg_config`（内部调用 cmake）→ `cd build && make && make install`。脚本会先检测 `cmake` **版本是否 ≥ 3.15**（TimescaleDB 2.x 硬性要求）：已达标直接使用；否则在 CentOS/RHEL 7 上自动安装并启用 `cmake3`（来自 EPEL，通常为 `/usr/bin/cmake3`）并加入 PATH，在 dnf/apt 系统上升级 `cmake`。bootstrap 以 `BUILD_FORCE_REMOVE=true` 运行，遇到旧的 `build/` 目录会自动重建，避免交互询问与旧缓存残留。bootstrap 还会自动追加 `-DREGRESS_CHECKS=OFF`（跳过回归测试、加快构建）。
   - **OpenSSL 检查与交互选择**：TimescaleDB 默认强制要求 PostgreSQL 带 OpenSSL（`--with-openssl`）。脚本在 bootstrap 前用 `pg_config --configure` 探测主程序是否启用 OpenSSL；若**未启用**（cmake 会报 `PostgreSQL was built without OpenSSL support`），会**暂停并提示二选一**：
     - **选项 1（默认）**：忽略 OpenSSL，以 `-DUSE_OPENSSL=0` 继续编译——核心时序功能（hypertable、分区、连续聚合等）不受影响，仅压缩/加密相关能力不可用；
     - **选项 2**：取消安装，先 `yum install openssl-devel`（Debian/Ubuntu 为 `libssl-dev`），并让 PostgreSQL 带 `--with-openssl` 插件**重新编译**（注意：仅装 openssl-devel 无效，PostgreSQL 本身必须重编带 openssl），再回来装 TimescaleDB。
2. **配置预加载库并重启**（TimescaleDB 的特殊要求）：TimescaleDB **必须**出现在 `shared_preload_libraries` 中才能创建扩展。脚本优先用 `ALTER SYSTEM SET shared_preload_libraries TO '<现有>,timescaledb';` 在线配置；服务未运行/离线时则直接改写 `postgresql.conf`。配置后**自动重启** PostgreSQL 服务并等待其就绪。
3. **在库内注册扩展**：重启就绪后自动执行 `CREATE EXTENSION IF NOT EXISTS timescaledb;`（默认在 `postgres` 库）。扩展按数据库生效。

> ⚠️ **与 pgvector/PostGIS 的关键区别**：TimescaleDB 需要 `shared_preload_libraries = 'timescaledb'` 且**必须重启数据库**后才能 `CREATE EXTENSION`。脚本已自动完成配置与重启；若手动安装，请务必先配置 preload 并重启。

**在线下载地址**（codeload，版本由 `TIMESCALEDB_VERSION` 控制）：

```
https://codeload.github.com/timescale/timescaledb/tar.gz/refs/tags/<TIMESCALEDB_VERSION>
# 默认拼接为：
https://codeload.github.com/timescale/timescaledb/tar.gz/refs/tags/2.29.2
# 下载后解压目录为 timescaledb-2.29.2
wget https://codeload.github.com/timescale/timescaledb/tar.gz/refs/tags/2.29.2 -O timescaledb-2.29.2.tar.gz
```

可通过环境变量指定版本：

```bash
export TIMESCALEDB_VERSION=2.29.2
sudo ./install_postgresql.sh
```

**离线环境准备**：在联网机下载后，把压缩包（或解压后的源码目录，需含 `bootstrap` 与 `timescaledb.control.in`）放到脚本目录、PostgreSQL tar 包同级目录或 `/tmp`。注意 TimescaleDB 编译仍需目标机装有 `cmake` 与编译工具链。

**事后加装**：已装好的 PostgreSQL 可通过主菜单 `3 → 1（外部插件向导）` 输入 `timescaledb` 单独加装；向导会自动配置 preload、重启服务并创建扩展。

**手动启用扩展**（如需手动操作）：

```bash
# 1. 配置预加载库（二选一）
<prefix>/bin/psql -U postgres -c "ALTER SYSTEM SET shared_preload_libraries TO 'timescaledb';"
#   或在 postgresql.conf 中设置：shared_preload_libraries = 'timescaledb'

# 2. 重启数据库（服务名为 postgresql<主版本号>）
systemctl restart postgresql17

# 3. 在目标库创建扩展
<prefix>/bin/psql -U postgres -d <数据库名> -c "CREATE EXTENSION timescaledb;"
```

#### pg_textsearch 全文检索扩展

pg_textsearch 是 [Timescale](https://github.com/timescale/pg_textsearch) 出品的 BM25 全文检索扩展（前身 Tapir，纯 C 编写，PostgreSQL 许可、可商用），提供 BM25 排名（`<@>` 操作符）、`CREATE INDEX ... USING bm25`、Block-Max WAND top-k 优化等，复用 PostgreSQL 文本搜索配置。默认版本 `1.4.0`（由变量 `PG_TEXTSEARCH_VERSION` 控制）。

> ⚠️ **硬性限制**：pg_textsearch **仅支持 PostgreSQL 17/18**，且与 TimescaleDB 一样**必须**出现在 `shared_preload_libraries` 中、**重启数据库**后才能 `CREATE EXTENSION`。脚本在安装前会用 `pg_config --version` 校验主版本，非 17/18 会跳过安装（不影响 PostgreSQL 主程序）。

**安装机制：文件部署 → 配置 preload 并重启 → 注册扩展**。其中"文件部署"支持两种方式，脚本**自动优先使用预编译包**：

**方式一（推荐）：官方预编译二进制包 —— 免编译、免工具链**

Timescale 在 Releases 中按 PG 大版本提供预编译包 `pg_textsearch-pg17-v1.4.0.tar.gz` / `pg_textsearch-pg18-v1.4.0.tar.gz`，包内只有三类文件：

```text
pg_textsearch.control        # 扩展控制文件
pg_textsearch--1.4.0.sql     # 扩展注册 SQL
pg_textsearch.so             # 动态库
```

脚本流程：在脚本目录 / `/tmp` / 离线 tar 包同级目录 / 当前目录中查找 `pg_textsearch-pg<主版本>*.tar.gz`（或已解压且含 `pg_textsearch.so`+`pg_textsearch.control` 的目录）；在线模式下本地没有时自动从 GitHub Releases 下载对应 PG 大版本的包 → 解压 → 校验三类文件齐全 → 拷贝到 PostgreSQL 目录（`control`/`.sql` → `<prefix>/share/extension/`，`.so` → `<prefix>/lib/`）。**全程不需要 gcc/make/cmake**，适合精简系统或离线环境。

> 📌 **版本必须匹配**：预编译包按 PostgreSQL 大版本发布（pg17 / pg18），脚本只匹配当前数据库主版本对应的包；放错版本（如 PG17 环境放了 pg18 包）不会被采用。

**方式二（回退）：源码编译 —— 纯 C / PGXS**

当预编译包不存在、下载失败或内容不完整时，自动回退源码编译：定位/下载源码包 → `make PG_CONFIG=<prefix>/bin/pg_config -jN`（失败自动降 `-j1` 重试）→ `make install PG_CONFIG=...`，需要目标机装有 `gcc`、`make`。

**文件部署完成后**（与 TimescaleDB 相同的启用流程）：脚本询问是否立即启用 → 用 `ALTER SYSTEM`（服务未运行/离线时改写 `postgresql.conf`）把 `pg_textsearch` 幂等加入 `shared_preload_libraries` → 自动重启服务并等待就绪 → 执行 `CREATE EXTENSION IF NOT EXISTS pg_textsearch;`（默认在 `postgres` 库）。

**下载地址**（版本由 `PG_TEXTSEARCH_VERSION` 控制）：

```bash
# 预编译包（推荐，按 PG 大版本二选一）
wget https://github.com/timescale/pg_textsearch/releases/download/v1.4.0/pg_textsearch-pg17-v1.4.0.tar.gz
wget https://github.com/timescale/pg_textsearch/releases/download/v1.4.0/pg_textsearch-pg18-v1.4.0.tar.gz
# 源码包（回退编译用）
wget https://github.com/timescale/pg_textsearch/archive/refs/tags/v1.4.0.tar.gz -O pg_textsearch-1.4.0.tar.gz
```

可通过环境变量指定版本：

```bash
export PG_TEXTSEARCH_VERSION=1.4.0
sudo ./install_postgresql.sh
```

**事后加装**：已装好的 PostgreSQL（17/18）可通过主菜单 `3 → 1（外部插件向导）` 输入 `pg_textsearch` 单独加装；向导会自动部署文件、配置 preload、重启服务并创建扩展。

**手动安装/启用**（不使用脚本时，对应预编译包 README 的三步）：

```bash
# 1. 部署文件（<prefix> 为 PostgreSQL 安装目录）
cp pg_textsearch.control pg_textsearch--*.sql  <prefix>/share/extension/
cp pg_textsearch.so                            <prefix>/lib/

# 2. 配置预加载库（二选一）
<prefix>/bin/psql -U postgres -c "ALTER SYSTEM SET shared_preload_libraries TO 'pg_textsearch';"
#   或在 postgresql.conf 中设置：shared_preload_libraries = 'pg_textsearch'

# 3. 重启数据库（服务名为 postgresql<主版本号>）
systemctl restart postgresql17

# 4. 在目标库创建扩展
<prefix>/bin/psql -U postgres -d <数据库名> -c "CREATE EXTENSION pg_textsearch;"

# 5. 建 BM25 索引示例
#   CREATE INDEX idx_fts ON 表名 USING bm25(内容列) WITH (text_config='english');
#   SELECT * FROM 表名 ORDER BY 内容列 <@> '检索词' LIMIT 10;
```

> 💡 **与 pg_search（ParadeDB）的区别**：pg_textsearch 为 Timescale 出品、纯 C、**PostgreSQL 许可（宽松、可商用）**、仅 PG17/18、专注 BM25 检索性能；pg_search 为 ParadeDB 出品、Rust/Tantivy、**AGPL-3.0 许可（SaaS 商用需商业授权）**、支持 PG13+，功能更广（高亮、facets 聚合、模糊/短语查询等）。

#### 默认配置

```
配置项              默认值
─────────────────────────────────
PostgreSQL 版本    18.1
用户/组            postgres / postgres
安装目录           /mnt/data/postgresql/postgresql-18.1
数据目录           /mnt/data/postgresql/data
端口               5432
密码               postgres
```

#### 常用安装示例

```bash
# 1. 使用默认配置快速安装
sudo ./install_postgresql.sh
# 选择: 1 → 1 → 1

# 2. 自定义安装路径
sudo ./install_postgresql.sh
# 选择: 1 → 1 → 2
# 自定义: /opt/pgsql

# 3. 选择特定版本
sudo ./install_postgresql.sh
# 选择: 2 → 8 (查询18.x版本)

# 4. 离线安装
sudo ./install_postgresql.sh
# 选择: 4 → 输入包路径
```

---

## 🗄️ WAL归档管理

### postgresql_wal_archive_manager.sh

#### 工作模式

```
┌────────────────────────────────────────────────────────────┐
│           WAL 归档管理脚本 v2.0.0                          │
├────────────────────────────────────────────────────────────┤
│  模式          功能说明                                    │
│  ───────────────────────────────────────────────────────  │
│  setup         完整WAL归档配置（推荐）                     │
│  manual        手动清理旧WAL文件                           │
│  auto          配置archive_cleanup_command自动清理         │
│  cron          设置cron定时清理任务                        │
│  smart         智能清理（基于pg_controldata）              │
│  status        显示当前归档状态                            │
│  test          测试归档配置                                │
└────────────────────────────────────────────────────────────┘
```

#### 模式详解

##### 1️⃣ setup 模式（推荐）

完整配置 WAL 归档，包含所有必要设置。

```bash
sudo ./postgresql_wal_archive_manager.sh setup
```

**配置内容**：
- ✅ 创建归档目录
- ✅ 配置 wal_level、archive_mode、archive_command
- ✅ 优化 WAL 参数
- ✅ 创建清理脚本
- ✅ 设置定时任务
- ✅ 重启服务并验证

##### 2️⃣ cron 模式

仅设置定时清理任务。

```bash
# 设置保留7天的归档
sudo ./postgresql_wal_archive_manager.sh cron -d 7

# 设置保留15天的归档
sudo ./postgresql_wal_archive_manager.sh cron -d 15
```

**定时任务说明**：

```bash
# cron 任务被安装到 postgres 用户的 crontab
# 每周日凌晨 2 点执行

# 查看任务（注意用户）
sudo -u postgres crontab -l

# 任务内容：
0 2 * * 0 LC_ALL=C LANG=C /path/to/wal_cleanup.sh >> /path/to/wal_cleanup.log 2>&1
```

> ⚠️ **重要**：cron 任务安装在 postgres 用户下，不是 root 用户！

##### 3️⃣ manual 模式

手动触发清理。

```bash
# 清理7天前的归档
sudo ./postgresql_wal_archive_manager.sh manual -d 7

# 强制清理（不确认）
sudo ./postgresql_wal_archive_manager.sh manual -d 7 -f
```

##### 4️⃣ status 模式

查看当前归档状态。

```bash
sudo ./postgresql_wal_archive_manager.sh status
```

**输出示例**：

```
=== PostgreSQL WAL归档状态 ===
PostgreSQL服务状态: 运行中
WAL级别: replica
归档模式: on
归档命令: cp %p /mnt/data/postgresql/archive/%f
清理命令: /mnt/data/postgresql/postgresql-18.1/bin/pg_archivecleanup
归档目录: /mnt/data/postgresql/archive
归档文件数量: 152
归档目录大小: 2.3G
定时清理任务: 0 2 * * 0 /path/to/wal_cleanup.sh
```

##### 5️⃣ test 模式

测试归档配置是否正确。

```bash
sudo ./postgresql_wal_archive_manager.sh test
```

#### WAL 参数说明

| 参数 | 默认值 | 说明 |
|-----|-------|------|
| wal_level | replica | WAL 级别（minimal/replica/logical） |
| archive_mode | on | 归档模式 |
| archive_command | cp %p ... | 归档命令 |
| max_wal_size | 1GB | 最大 WAL 大小 |
| min_wal_size | 80MB | 最小 WAL 大小 |
| checkpoint_completion_target | 0.9 | 检查点完成目标 |
| wal_buffers | 16MB | WAL 缓冲区 |
| wal_writer_delay | 200ms | WAL 写入延迟 |

---

## 🗑️ 卸载脚本

### uninstall_postgresql.sh

#### 功能特点

```
┌────────────────────────────────────────────────────────────┐
│              PostgreSQL 完全卸载脚本                       │
├────────────────────────────────────────────────────────────┤
│  ✅ 自动搜索 - 自动查找系统中的PostgreSQL安装             │
│  ✅ 智能清理 - 多种方法确保彻底删除                        │
│  ✅ 干运行模式 --dry-run 预览删除内容                     │
│  ✅ 残留检查 - 最终验证确保完全清理                        │
└────────────────────────────────────────────────────────────┘
```

#### 卸载流程

```
搜索安装 → 停止服务 → 删除服务文件 → 删除文件目录 →
删除配置 → 删除用户组 → 系统清理 → 残留检查
```

#### 使用示例

##### 1️⃣ 自动搜索卸载（推荐）

```bash
sudo ./uninstall_postgresql.sh
```

**交互流程**：
```
1. 选择自动搜索
2. 脚本列出找到的安装
3. 选择要卸载的安装
4. 确认卸载
```

##### 2️⃣ 指定路径卸载

```bash
# 指定安装目录和数据目录
sudo ./uninstall_postgresql.sh \
  -i /mnt/data/postgresql/postgresql-18.1 \
  -d /mnt/data/postgresql/data
```

##### 3️⃣ 干运行模式（预览）

```bash
# 预览将要删除的内容，不实际删除
sudo ./uninstall_postgresql.sh --dry-run
```

##### 4️⃣ 跳过确认

```bash
# 跳过所有确认提示
sudo ./uninstall_postgresql.sh -y
```

#### 命令行参数

| 参数 | 说明 |
|-----|------|
| `-u, --user USER` | PostgreSQL 用户名 |
| `-i, --install-dir DIR` | 安装目录 |
| `-d, --data-dir DIR` | 数据目录 |
| `-h, --home DIR` | 主目录 |
| `-y, --yes` | 跳过确认提示 |
| `--dry-run` | 预览模式 |
| `--help` | 显示帮助 |

#### 卸载内容清单

**将被删除**：
- ❌ PostgreSQL 用户和组
- ❌ 安装目录
- ❌ 数据目录（包含所有数据！）
- ❌ systemd 服务文件
- ❌ 配置文件

**不会被删除**：
- ⚠️ 主目录（如 /mnt/data/postgresql）
  - 用于保留可能的配置文件
  - 需手动删除

#### 备份建议

```bash
# 卸载前务必备份数据！

# 1. 使用 pg_dumpall 备份
sudo -u postgres /path/to/bin/pg_dumpall > postgresql_backup.sql

# 2. 备份数据目录
tar -czf postgresql_data_backup.tar.gz /mnt/data/postgresql/data

# 3. 备份配置文件
cp /mnt/data/postgresql/data/postgresql.conf ./postgresql.conf.bak
```

---

## 🔧 常见问题

### Q1: 为什么 crontab -e 看不到定时任务？

**原因**：cron 任务被安装到 **postgres 用户**的 crontab，不是 root 用户。

**查看方法**：

```bash
# 查看postgres用户的cron任务
sudo -u postgres crontab -l

# 或切换到postgres用户
su - postgres -c "crontab -l"
```

---

### Q2: 安装时网络连接失败怎么办？

**解决方案**：

1. **切换镜像源**（推荐国内用户）：
   ```bash
   sudo ./install_postgresql.sh
   # 在主菜单选择: m
   # 选择: 2. 腾讯云镜像
   ```

2. **使用代理**：
   ```bash
   export http_proxy=http://proxy_host:port
   export https_proxy=http://proxy_host:port
   sudo ./install_postgresql.sh
   ```

3. **使用离线安装**：
   ```bash
   # 提前下载源码包
   wget https://ftp.postgresql.org/pub/source/v18.1/postgresql-18.1.tar.gz

   # 上传后运行离线安装
   sudo ./install_postgresql.sh
   # 选择: 4. 离线安装
   ```

4. **下载失败后处理**：
   下载失败时，脚本会提供以下选项：
   - 重新尝试下载
   - 切换镜像源后重试
   - 返回主菜单
   - 退出安装

---

### Q3: 如何修改默认安装路径？

**方法一**：安装时选择自定义
```bash
sudo ./install_postgresql.sh
# 选择: 1 → 1 → 2
# 输入自定义路径
```

**方法二**：使用环境变量
```bash
export PG_HOME=/custom/path
sudo ./install_postgresql.sh
```

---

### Q4: 服务启动失败怎么办？

**排查步骤**：

```bash
# 1. 查看服务状态（服务名为 postgresql<主版本号>，如 postgresql17）
systemctl status postgresql17

# 2. 查看详细日志
journalctl -u postgresql17 -n 50

# 3. 检查数据目录权限
ls -la /mnt/data/postgresql/data

# 4. 手动启动查看错误
sudo -u postgres /mnt/data/postgresql/postgresql-17.9/bin/pg_ctl \
  -D /mnt/data/postgresql/data start

# 5. 查看数据库日志文件
tail -n 50 /mnt/data/postgresql/data/postgresql.log
```

> ⚠️ 若执行 `systemctl status postgresql` 报 `Unit postgresql.service could not be found.`，说明服务名用错了——正确服务名带主版本号（如 `postgresql17`），可用 `systemctl list-unit-files --type=service | grep postgresql` 查询。

---

### Q5: 如何开启远程连接？

**修改配置文件**：

```bash
# 1. 编辑 postgresql.conf
vi /mnt/data/postgresql/data/postgresql.conf

# 添加或修改：
listen_addresses = '*'
port = 5432

# 2. 编辑 pg_hba.conf
vi /mnt/data/postgresql/data/pg_hba.conf

# 添加允许连接的网段：
host    all             all             0.0.0.0/0               md5
# 或指定网段：
host    all             all             192.168.1.0/24          md5

# 3. 重启服务（服务名带主版本号，如 postgresql17）
systemctl restart postgresql17

# 4. 开放防火墙端口
firewall-cmd --permanent --add-port=5432/tcp
firewall-cmd --reload
```

---

### Q6: WAL 归档目录占用空间过大？

**解决方案**：

```bash
# 方法1: 手动清理
sudo ./postgresql_wal_archive_manager.sh manual -d 7

# 方法2: 调整保留天数
sudo ./postgresql_wal_archive_manager.sh cron -d 3

# 方法3: 手动删除特定文件
sudo -u postgres /mnt/data/postgresql/postgresql-18.1/bin/pg_archivecleanup \
  /mnt/data/postgresql/archive 000000010000000000000001
```

---

### Q7: 卸载后残留文件无法删除？

**强制删除方法**：

```bash
# 修改权限后删除
sudo chown -R root:root /path/to/dir
sudo chmod -R 777 /path/to/dir
sudo rm -rf /path/to/dir

# 或使用 --no-preserve-root
sudo rm -rf --no-preserve-root /path/to/dir
```

---

### Q8: 不启用 ICU 有什么影响？

**结论**：不影响数据库、SQL、事务、复制等核心功能。ICU 只决定**字符串排序/比较规则（collation，字符序）的提供者**：

- `--with-icu`：使用跨平台的 ICU 库提供排序规则；
- `--without-icu`：使用操作系统 libc（glibc）提供排序规则。

**不启用 ICU 的实际差异**：

1. **glibc 升级后需重建索引**（最需注意）：系统升级 glibc 后排序规则可能变化，导致已建的 text/varchar B-tree 索引逻辑顺序错乱。升级 glibc 后应对相关库执行 `REINDEX`（或 `reindexdb -a`）。
2. **跨平台/跨系统迁移**排序结果可能不一致（如 CentOS 与 Ubuntu 之间）；同版本同系统内无影响。
3. 无法使用 ICU 专属的定制排序（忽略大小写/重音、数字自然排序等）。

> 💡 CentOS 7 自带 ICU 50 且通常缺少可链接开发库，直接 `--without-icu` 是合理选择。脚本已通过编译+链接测试自动判断 ICU 是否真正可用，不可用时会引导安装 `libicu-devel` 或关闭 ICU。

---

### Q9: 安装 pgvector 必须启动数据库吗？离线怎么准备？

**不需要启动数据库即可完成文件安装**。pgvector 分两步：

1. `make && make install` 只拷贝扩展文件（`vector.so` 等），**与数据库是否运行无关**；
2. `CREATE EXTENSION vector` 才需要数据库运行，且按数据库生效。

跳过"启动数据库"时，脚本会用 `pg_isready` 探测，服务未运行则跳过注册并打印手动命令，待启动后执行：

```bash
<prefix>/bin/psql -U postgres -d <数据库名> -c "CREATE EXTENSION vector;"
```

**离线环境**：脚本不会联网下载，需提前把 `pgvector-*.tar.gz`（或解压后的源码目录）放到脚本目录、PostgreSQL tar 包同级目录或 `/tmp`。详见 [pgvector 向量扩展](#pgvector-向量扩展)。

PostGIS 的文件安装同样不需要数据库运行（仅 `CREATE EXTENSION postgis` 需要运行）；离线时提前准备 `postgis-*.tar.gz`，详见 [PostGIS 空间扩展](#postgis-空间扩展)。

---

### Q10: TimescaleDB 为什么要重启数据库？PostGIS 需要吗？

**TimescaleDB 必须重启，PostGIS 不需要。**

- **TimescaleDB**：它属于需要预加载的扩展，`shared_preload_libraries` 必须包含 `timescaledb`，且该参数只在数据库启动时读取。因此流程是：配置 preload → **重启** → `CREATE EXTENSION timescaledb`。脚本已自动完成 `ALTER SYSTEM`（或改写 `postgresql.conf`）、重启服务、等待就绪、创建扩展这一整套动作。手动安装时若漏了重启，`CREATE EXTENSION` 会报错提示必须先加入 preload 并重启。
- **PostGIS / pgvector**：不需要 `shared_preload_libraries`，编译安装后直接 `CREATE EXTENSION` 即可，无需重启。
- **pg_textsearch**：与 TimescaleDB 同属预加载扩展，`shared_preload_libraries` 必须包含 `pg_textsearch` 并重启后才能创建。脚本自动完成"配置 preload → 重启 → `CREATE EXTENSION pg_textsearch`"。另外它**仅支持 PostgreSQL 17/18**，低版本会在安装阶段被跳过。

> 💡 若 TimescaleDB / pg_textsearch 扩展创建失败，请确认 `SHOW shared_preload_libraries;` 的输出中含有对应库名，且数据库在配置后已重启。

> 💡 **pg_textsearch 免编译**：脚本优先使用官方预编译包（`pg_textsearch-pg17/pg18-v*.tar.gz`），目标机无需 gcc/make；预编译包缺失或下载失败时才回退源码 `make` 编译。离线时把对应 PG 大版本的预编译包放到脚本目录 / tar 包同级目录 / `/tmp` 即可。

---

### Q11: TimescaleDB 报 `CMake 3.15 or higher is required`？

**原因**：TimescaleDB 2.x 要求 **cmake ≥ 3.15**，而 CentOS/RHEL 7 系统自带的 cmake 是 **2.8.12.2**，版本过低。

**脚本已自动处理**：依赖检查和安装阶段都会校验 cmake 版本，不达标时在 CentOS/RHEL 7 自动安装并启用 `cmake3`（EPEL 提供，通常是 `/usr/bin/cmake3`）并加入 PATH；在 dnf（RHEL 8+）/apt（Debian/Ubuntu）系统上直接升级 `cmake`。

如需手动处理：

```bash
# CentOS/RHEL 7
yum install -y epel-release
yum install -y cmake3            # 提供 /usr/bin/cmake3
# 让 bootstrap 能调用到（bootstrap 内部调用的是 cmake）：
export PATH=/usr/bin:$PATH       # cmake3 与 cmake 同名时可不处理；若只有 cmake3：
ln -sf /usr/bin/cmake3 /usr/local/bin/cmake

# 验证版本
cmake --version                  # 需 >= 3.15
```

> 💡 若 EPEL 的 cmake3 仍不可用，可从 <https://github.com/Kitware/CMake/releases> 下载预编译二进制（如 `cmake-3.2x.x-linux-x86_64.tar.gz`），解压后把其 `bin` 加入 PATH 再重跑向导。

---

## 📝 附录

### 目录结构

```
/mnt/data/postgresql/
├── postgresql-18.1/          # 安装目录
│   ├── bin/                  # 可执行文件
│   ├── lib/                  # 库文件
│   ├── share/                # 共享文件
│   └── include/              # 头文件
├── data/                     # 数据目录
│   ├── base/                 # 数据库文件
│   ├── global/               # 全局数据
│   ├── pg_wal/               # WAL文件
│   ├── postgresql.conf       # 主配置
│   ├── pg_hba.conf           # 认证配置
│   └── postmaster.opts       # 启动选项
├── archive/                  # WAL归档目录
├── cleanup_wal.sh            # WAL清理脚本
└── cleanup_wal.log           # 清理日志
```

### 服务管理

> ⚠️ **服务名规则**：systemd 服务名为 `postgresql<主版本号>`（只取主版本，不含小版本）。例如 PostgreSQL 17.9 的服务名是 `postgresql17`，18.1 是 `postgresql18`。**不是** `postgresql`（该单元不存在，执行会报 `Unit postgresql.service could not be found.`）。
>
> 安装结束后脚本会自动探测并展示实际服务名，以下以 17 为例：

```bash
# 启动服务
systemctl start postgresql17

# 停止服务
systemctl stop postgresql17

# 重启服务
systemctl restart postgresql17

# 查看状态
systemctl status postgresql17

# 开机自启
systemctl enable postgresql17

# 禁用自启
systemctl disable postgresql17
```

> 💡 不确定服务名时，可查询：
> ```bash
> systemctl list-unit-files --type=service | grep postgresql
> ```

### 数据库连接

```bash
# 命令行连接（依赖 /etc/profile 中的 PATH 环境变量，需重新登录或 source /etc/profile 后生效）
psql -U postgres -W

# 若提示 psql 命令不存在，使用完整路径连接（-h 指定主机、-p 指定端口、-d 指定数据库）
<安装目录>/bin/psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -W

# 连接指定数据库
psql -U postgres -d mydb -W

# 执行SQL命令
psql -U postgres -c "SELECT version();"
```

### SQL常用命令

```sql
-- 列出所有数据库
\l

-- 切换数据库
\c database_name

-- 列出所有表
\dt

-- 查看表结构
\d table_name

-- 退出
\q
```

---

## 📞 技术支持

如有问题，请检查：
1. 系统日志：`journalctl -u postgresql<主版本号> -n 100`（如 `journalctl -u postgresql17 -n 100`）
2. PostgreSQL 日志：`/mnt/data/postgresql/data/log/`
3. 清理日志：`/mnt/data/postgresql/cleanup_wal.log`

---

## 📌 版本更新信息

### v2.3.0 (最新)

#### 新增功能

- **PostGIS 空间扩展支持（默认 3.5.7）**
  - 在线安装、离线安装、外部插件向导三处均可选择 postgis
  - 独立第三方扩展，autotools 构建：`./configure --with-pgconfig=...` + `make && make install`
  - configure 失败自动回退 `--without-raster --without-topology`
  - 自动检测并安装 geos/proj/gdal/json-c/libxml2/protobuf-c 等依赖（区分 CentOS/Debian）
  - 在线从 codeload 下载源码（版本由 `POSTGIS_VERSION` 控制），离线支持本地 `postgis-*.tar.gz`/源码目录
  - 服务启动后自动 `CREATE EXTENSION postgis`；无需 preload、无需重启
  - **老系统 GEOS/PROJ 自动源码升级**：PostGIS 3.5 需 GEOS ≥ 3.8、PROJ ≥ 6，CentOS 7 自带 GEOS 3.4 / PROJ 4.8 会报 `requires GEOS >= 3.8.0`。脚本 configure 前自动检测版本，不达标时从源码编译 **GEOS 3.9.3**（兼容 gcc 4.8 的 C++11，不用需 C++14 的 3.10+）与 **PROJ 6.3.2**（autotools 构建，不用需 cmake 的 7+）到 `/usr/local`，并配置 `PATH`/`LD_LIBRARY_PATH`/`PKG_CONFIG_PATH` 与 `ldconfig`；configure 显式传 `--with-geosconfig`/`--with-projdir` 指向新版本。离线可预置 `geos-*.tar.*`/`proj-*.tar.*`，版本由 `GEOS_VERSION`/`PROJ_VERSION` 控制

- **TimescaleDB 时序扩展支持（默认 2.29.2）**
  - 在线安装、离线安装、外部插件向导三处均可选择 timescaledb
  - 独立第三方扩展，cmake 构建：`./bootstrap -DPG_CONFIG=...` + `cd build && make && make install`
  - 自动检测并安装 cmake / openssl-devel（libssl-dev）
  - **版本感知的 cmake 校验**：TimescaleDB 2.x 需 cmake ≥ 3.15，旧系统（如 CentOS 7 自带 cmake 2.8）会自动安装 `cmake3`（EPEL），并在独立 shim 目录（`/tmp/pg_cmake_shim`）中把现代 cmake 软链为 `cmake`、置于 PATH 最前并清理命令缓存，确保覆盖系统旧 cmake；dnf/apt 系统自动升级 `cmake`
  - bootstrap 以 `BUILD_FORCE_REMOVE=true` 运行，自动清理重建旧 `build/` 目录，避免交互询问与旧缓存残留
  - 自动配置 `shared_preload_libraries='timescaledb'`（优先 `ALTER SYSTEM`，离线改写 `postgresql.conf`）并**自动重启**服务、等待就绪后 `CREATE EXTENSION timescaledb`
  - 在线从 codeload 下载源码（版本由 `TIMESCALEDB_VERSION` 控制），离线支持本地 `timescaledb-*.tar.gz`/源码目录
  - **内存感知的安全并行编译**：新增 `_pg_safe_jobs()`，按 `min(CPU核数, 可用内存MB/1500)` 自动限制 `make -j` 并行度，避免并行编译 C++（GEOS/PostGIS/TimescaleDB）时内存不足触发 GCC 内部错误（`internal compiler error ... likely a hardware or OS problem`）；编译失败时自动降级重试：先 `make -j1`（单线程降峰值内存），仍失败则以 `-O0` 低优化重新 configure/cmake 后再单线程编译。编译重型 C++ 前还会检测内存，物理内存+swap 低于 ~3GB 时**自动创建临时 swap 文件**（`_pg_ensure_swap()`，1~4GB，放在空间充足的分区）兜底，防止编译器进程被 OOM 杀死。**自动启用新版 GCC（devtoolset）**：CentOS/RHEL 7 自带 g++ 4.8.5 对现代 C++11/14 支持不全、编译 GEOS 3.9 等会随机触发 GCC 内部错误（`internal compiler error`，每次崩溃文件不同，与内存无关）；`_pg_enable_modern_gcc()` 检测到 g++ < 7 时自动安装并启用 SCL `devtoolset-8/9/10/11`（`centos-release-scl` + `devtoolset-N-toolchain`，source `/opt/rh/devtoolset-N/root/enable` 并导出 `CC/CXX`），同时 `export CCACHE_DISABLE=1` 禁用 ccache 排除缓存导致的偶发异常。源码下载统一启用进度条（`wget --progress=bar:force` / `curl --progress-bar`）
  - 新增服务名动态探测、服务重启、preload 幂等配置等通用辅助函数（同时复用于其他扩展）
  - **OpenSSL 检查与交互选择**：bootstrap 前用 `pg_config --configure` 探测主程序是否启用 OpenSSL；未启用（cmake 会报 `PostgreSQL was built without OpenSSL support`）时**暂停提示二选一**：选项 1（默认）以 `-DUSE_OPENSSL=0` 继续（核心时序功能不受影响）；选项 2 取消并指引安装 `openssl-devel`、带 `--with-openssl` 重编 PostgreSQL 后再来（仅装 openssl-devel 无效）。并统一加 `-DREGRESS_CHECKS=OFF` 跳过回归测试

- **pg_textsearch 全文检索扩展支持（默认 1.4.0，Timescale 出品）**
  - 在线安装、离线安装、外部插件向导三处均可选择 pg_textsearch
  - 独立第三方扩展，纯 C / 标准 PGXS；**仅支持 PostgreSQL 17/18**，安装前用 `pg_config --version` 校验主版本，不匹配则跳过且不影响主程序
  - **双模式文件部署，优先免编译**：① 优先使用官方预编译二进制包 `pg_textsearch-pg17/pg18-v<版本>.tar.gz`（本地查找 `pg_textsearch-pg<主版本>*.tar.gz` → 在线模式自动从 GitHub Releases 下载 → 解压校验 `pg_textsearch.control`/`pg_textsearch--*.sql`/`pg_textsearch.so` 三类文件齐全 → 拷贝到 `share/extension/` 与 `lib/`），**目标机无需 gcc/make**；② 预编译包缺失/下载失败/内容不完整时自动回退源码编译（`make PG_CONFIG=... -jN`，失败降 `-j1` 重试）
  - 预编译包按 PG 大版本匹配（pg17/pg18），放错版本不会被采用；已解压目录中含 `.so`+`.control` 且无 `Makefile` 的也识别为预编译文件
  - 自动配置 `shared_preload_libraries='pg_textsearch'`（优先 `ALTER SYSTEM`，离线改写 `postgresql.conf`）并**自动重启**服务、等待就绪后 `CREATE EXTENSION pg_textsearch`
  - 离线支持本地预编译包 / 源码包 `pg_textsearch-*.tar.gz` / 已解压目录；临时构建目录 `/tmp/pg_textsearch_build` 自动清理

#### 功能优化

- 第三方扩展源码定位统一支持 `*.control` 与构建期才生成的 `*.control.in` 标记，解决全新源码首次解压误判"缺少 control"的问题
- **修复 PostGIS 源码识别失败**：PostGIS 的 `postgis.control.in` 实际位于 `extensions/postgis/` 子目录（非源码根），原查找深度不足且会把目录误判到子目录。现放宽查找深度，并在命中标记后沿目录向上**归一化到真正的源码根**（PostGIS 以含 `configure`/`GNUmakefile.in`/`autogen.sh` 的目录为准，TimescaleDB 以含 `bootstrap` 的目录为准）
- **兼容 codeload/GitHub 源码包**：该类源码包不含已生成的 `configure`，PostGIS 安装时自动运行 `./autogen.sh` 生成；依赖检查阶段对缺失的 `autoconf`/`automake`/`libtool` 自动安装（官方 make dist 发布包自带 `configure`，直接跳过）
- 修复 PostGIS/TimescaleDB 源码准备阶段日志被命令替换吞掉的问题：失败时回显完整下载/解压日志与手动下载命令，便于定位
- 第三方扩展一律**优先使用本地源码**（已解压目录 → 本地压缩包），均未找到时才在线下载
- TimescaleDB 源码根自动归一化（命中 `build/src` 时回溯到含 `bootstrap` 的源码根）
- 外部插件向导支持 pgvector / postgis / timescaledb 与 contrib 插件任意混选，独立扩展统一走"编译→启用"流程
- 临时文件清理新增 `/tmp/postgis_build`、`/tmp/timescaledb_build`

### v2.2.0

#### 新增功能

- **pgvector 向量扩展支持**
  - 在线安装、离线安装、外部插件向导三处均可选择 pgvector
  - 独立扩展，使用 `pg_config` 单独 `make && make install`，无需重编 PostgreSQL
  - 在线模式自动从 GitHub 下载源码（版本由 `PGVECTOR_VERSION` 控制，默认 0.8.0）
  - 离线模式支持本地源码目录 / `pgvector-*.tar.gz`（可放脚本目录、tar 包同级或 `/tmp`）
  - 服务启动后自动 `CREATE EXTENSION vector`；未启动则跳过并给出手动命令
  - 已装 PostgreSQL 可通过主菜单 `3 → 1` 事后单独加装

- **路径默认值优化**
  - 离线 tar 包路径留空回车时，默认使用脚本当前所在目录

- **ICU 可用性探测增强**
  - 改用真实编译+链接测试判定 ICU 是否可用，避免仅有头文件缺开发库导致的链接失败
  - configure 失败后的自动修复分支与编译前依赖检查统一复用该链接测试
  - 移除旧的"伪造 pkg-config"逻辑，改为在线装包复测 / 关闭 ICU 等明确选项

#### 功能优化

- **修正安装完成后展示的服务管理命令**：服务名改为动态探测实际的 systemd 单元（`postgresql<主版本号>`，如 `postgresql17`），不再用完整版本号错拼成 `postgresql17.9` 或退化成不存在的 `postgresql`
- 连接命令同时展示简洁形式 `psql -U postgres -W` 与带完整路径/主机/端口的兜底形式
- 重配前自动执行 `make distclean`，避免 `--with-icu` 与 `--without-icu` 混配残留导致链接错误
- 临时文件清理新增 pgvector 构建目录 `/tmp/pgvector_build`
- pgvector 启用前用 `pg_isready` 探测服务，避免无意义重试等待

### v2.1.0

#### 新增功能

- **镜像源选择**
  - 新增下载镜像源选择功能
  - 支持官网镜像和腾讯云镜像
  - 配置确认界面显示当前镜像源
  - 支持在配置过程中切换镜像源

- **下载功能增强**
  - 下载失败自动重试机制（最多3次）
  - 下载超时时间延长至600秒
  - 新增文件完整性验证功能
  - 新增文件大小检查（最小20MB）
  - 下载失败后提供多种处理选项

- **插件依赖管理**
  - 新增插件依赖自动检查功能
  - 新增单个包自动安装函数
  - 新增UUID库智能安装（支持e2fsprogs和OSSP）
  - 优先使用系统已有UUID库，自动安装缺失依赖

- **临时文件清理**
  - 新增临时文件自动清理功能
  - 清理源码包、解压目录、配置日志等
  - 安装完成后自动执行

#### 功能优化

- 修正编译核心数选择逻辑
- 优化UUID库依赖安装提示
- 新增bonjour插件支持
- 优化解压错误处理
- 添加更详细的下载错误提示

#### 依赖更新

- UUID插件依赖更新为：`uuid-devel` / `libossp-uuid-devel`

### v2.0.0

- 初始版本发布
- 支持PostgreSQL 12.x ~ 18.x
- 在线/离线安装模式
- WAL归档管理
- 完全卸载功能

