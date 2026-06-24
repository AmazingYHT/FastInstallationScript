@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul

REM ============================================================
REM Nacos 自动化安装脚本（Windows）
REM 支持单机/集群模式，Derby/MySQL 存储库选择，版本可配置
REM 本地 package\ 目录优先，缺失时自动从官方下载
REM 用法: install_nacos.bat [选项]，详见 --help
REM ============================================================

REM -------------------- 默认配置 --------------------
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "LIB_COMMON=%SCRIPT_DIR%\..\lib_common.bat"
if not exist "%LIB_COMMON%" (
    echo [ERROR] 未找到通用库文件 %LIB_COMMON%
    exit /b 1
)
if "%NACOS_VERSION%"=="" set "NACOS_VERSION=2.5.0"
set "NACOS_INSTALL_DIR=C:\nacos"
set "NACOS_PACKAGE_DIR=%SCRIPT_DIR%\package"
set "DEPLOY_MODE="
set "DB_TYPE="
set "NACOS_PORT=8848"
set "CLUSTER_NODES="
set "MYSQL_HOST=127.0.0.1"
set "MYSQL_PORT=3306"
set "MYSQL_DB=nacos"
set "MYSQL_USER=nacos"
set "MYSQL_PASSWORD="
set "NON_INTERACTIVE=false"
set "DOWNLOAD_BASE=https://github.com/alibaba/nacos/releases/download"

REM -------------------- 解析参数 --------------------
:parse_args
if "%~1"=="" goto after_args
if /i "%~1"=="--standalone" ( set "DEPLOY_MODE=standalone" & set "NON_INTERACTIVE=true" & shift & goto parse_args )
if /i "%~1"=="--cluster" ( set "DEPLOY_MODE=cluster" & set "NON_INTERACTIVE=true" & shift & goto parse_args )
if /i "%~1"=="--db" ( set "DB_TYPE=%~2" & shift & shift & goto parse_args )
if /i "%~1"=="--version" ( set "NACOS_VERSION=%~2" & shift & shift & goto parse_args )
if /i "%~1"=="--port" ( set "NACOS_PORT=%~2" & shift & shift & goto parse_args )
if /i "%~1"=="--nodes" ( set "CLUSTER_NODES=%~2" & shift & shift & goto parse_args )
if /i "%~1"=="--mysql-host" ( set "MYSQL_HOST=%~2" & shift & shift & goto parse_args )
if /i "%~1"=="--mysql-port" ( set "MYSQL_PORT=%~2" & shift & shift & goto parse_args )
if /i "%~1"=="--mysql-db" ( set "MYSQL_DB=%~2" & shift & shift & goto parse_args )
if /i "%~1"=="--mysql-user" ( set "MYSQL_USER=%~2" & shift & shift & goto parse_args )
if /i "%~1"=="--mysql-password" ( set "MYSQL_PASSWORD=%~2" & shift & shift & goto parse_args )
if /i "%~1"=="-h" goto usage
if /i "%~1"=="--help" goto usage
echo [ERROR] 未知参数: %~1（使用 --help 查看帮助）
exit /b 1

:usage
echo Nacos 自动化安装脚本（Windows）
echo.
echo 用法: install_nacos.bat [选项]
echo.
echo   --standalone              单机模式部署
echo   --cluster                 集群模式部署
echo   --db derby^|mysql          存储库类型（默认 derby）
echo   --version 版本号           指定 Nacos 版本（默认 %NACOS_VERSION%）
echo   --port 端口                Nacos 服务端口（默认 %NACOS_PORT%）
echo   --nodes ip:port,...        集群节点列表（集群模式必填）
echo   --mysql-host host          MySQL 主机
echo   --mysql-port port          MySQL 端口
echo   --mysql-db dbname          MySQL 数据库名
echo   --mysql-user user          MySQL 用户名
echo   --mysql-password pwd        MySQL 密码
echo   -h, --help                显示此帮助
echo.
echo 示例:
echo   install_nacos.bat --standalone --db derby
echo   install_nacos.bat --standalone --db mysql --mysql-password 123456
echo   install_nacos.bat --cluster --db mysql --nodes 192.168.1.10:8848,192.168.1.11:8848 --mysql-host 192.168.1.20 --mysql-password 123456
exit /b 0

:after_args
echo [INFO] 开始安装 Nacos %NACOS_VERSION% ...

REM -------------------- 检查管理员权限 --------------------
net session >nul 2>nul
if errorlevel 1 (
    echo [ERROR] 权限不足：安装到 %NACOS_INSTALL_DIR% 需要管理员权限
    echo         请右键以「管理员身份运行」本脚本
    exit /b 1
)
echo [INFO] 管理员权限检查通过

REM -------------------- 检查 Java --------------------
where java >nul 2>nul
if errorlevel 1 (
    echo [ERROR] 未检测到 Java 环境，Nacos 需要 JDK 8 及以上，请先安装并配置 JAVA_HOME
    exit /b 1
)
echo [INFO] 已检测到 Java 环境

REM -------------------- 基础配置（交互） --------------------
if /i "%NON_INTERACTIVE%"=="true" goto skip_basic
echo.
echo [INFO] 基础配置（直接回车使用默认值）
set /p "input=Nacos 版本 (默认 %NACOS_VERSION%): " & if not "!input!"=="" set "NACOS_VERSION=!input!"
set /p "input=服务端口 (默认 %NACOS_PORT%): " & if not "!input!"=="" set "NACOS_PORT=!input!"
echo [INFO] 版本: %NACOS_VERSION%  端口: %NACOS_PORT%
:skip_basic

REM -------------------- 校验端口 --------------------
call "%LIB_COMMON%" :validate_port "%NACOS_PORT%" "Nacos 服务" || exit /b 1

REM -------------------- 选择部署模式 --------------------
if not "%DEPLOY_MODE%"=="" goto skip_mode
echo.
echo 请选择部署模式:
echo   1^) 单机模式 ^(standalone^)
echo   2^) 集群模式 ^(cluster^)
set /p "choice=请输入选项 [1-2] (默认 1): "
if "!choice!"=="2" ( set "DEPLOY_MODE=cluster" ) else ( set "DEPLOY_MODE=standalone" )
:skip_mode
echo [INFO] 部署模式: %DEPLOY_MODE%

REM -------------------- 选择存储库 --------------------
if not "%DB_TYPE%"=="" goto skip_db
echo.
echo 请选择存储库类型:
echo   1^) Derby  ^(内嵌数据库，适合单机/测试^)
echo   2^) MySQL  ^(外部数据库，集群模式推荐^)
set /p "choice=请输入选项 [1-2] (默认 1): "
if "!choice!"=="2" ( set "DB_TYPE=mysql" ) else ( set "DB_TYPE=derby" )
:skip_db
echo [INFO] 存储库: %DB_TYPE%

REM -------------------- 集群节点 --------------------
if /i not "%DEPLOY_MODE%"=="cluster" goto skip_cluster_input
if not "%CLUSTER_NODES%"=="" goto skip_cluster_input
if /i "%NON_INTERACTIVE%"=="true" goto check_cluster_nodes
echo.
echo 请输入集群所有节点（格式 ip:port，多个用逗号分隔）
echo 例如: 192.168.1.10:8848,192.168.1.11:8848,192.168.1.12:8848
set /p "CLUSTER_NODES=集群节点: "
:check_cluster_nodes
if "%CLUSTER_NODES%"=="" (
    echo [ERROR] 集群模式必须提供节点列表（--nodes 或交互输入）
    exit /b 1
)
echo [INFO] 集群节点: %CLUSTER_NODES%
:skip_cluster_input

REM -------------------- MySQL 信息 --------------------
if /i not "%DB_TYPE%"=="mysql" goto skip_mysql_input
if /i "%NON_INTERACTIVE%"=="true" goto skip_mysql_input
echo.
echo [INFO] 配置 MySQL 连接信息（直接回车使用默认值）
set /p "input=MySQL 主机 (默认 %MYSQL_HOST%): " & if not "!input!"=="" set "MYSQL_HOST=!input!"
set /p "input=MySQL 端口 (默认 %MYSQL_PORT%): " & if not "!input!"=="" set "MYSQL_PORT=!input!"
set /p "input=数据库名 (默认 %MYSQL_DB%): " & if not "!input!"=="" set "MYSQL_DB=!input!"
set /p "input=用户名 (默认 %MYSQL_USER%): " & if not "!input!"=="" set "MYSQL_USER=!input!"
set /p "MYSQL_PASSWORD=密码: "
:skip_mysql_input

REM -------------------- 准备安装包 --------------------
set "PKG_NAME=nacos-server-%NACOS_VERSION%.zip"
set "LOCAL_PKG=%NACOS_PACKAGE_DIR%\%PKG_NAME%"
if not exist "%NACOS_PACKAGE_DIR%" mkdir "%NACOS_PACKAGE_DIR%"
if exist "%LOCAL_PKG%" (
    echo [INFO] 使用本地安装包: %LOCAL_PKG%
    goto deploy
)
set "DL_URL=%DOWNLOAD_BASE%/%NACOS_VERSION%/%PKG_NAME%"
echo [INFO] 本地未找到安装包，从官方下载: %DL_URL%
powershell -NoProfile -Command "$ErrorActionPreference='Stop'; try { [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $pp=$ProgressPreference; $ProgressPreference='SilentlyContinue'; Invoke-WebRequest -Uri '%DL_URL%' -OutFile '%LOCAL_PKG%' -TimeoutSec 60; $ProgressPreference=$pp } catch { Write-Host $_.Exception.Message; exit 1 }"
if errorlevel 1 (
    if exist "%LOCAL_PKG%" del "%LOCAL_PKG%"
    echo [ERROR] 下载失败（网络超时或版本不存在），请检查网络或手动将 %PKG_NAME% 放入 %NACOS_PACKAGE_DIR%
    exit /b 1
)
REM 校验下载文件大小（< 1MB 视为无效，如 404 页面）
for %%A in ("%LOCAL_PKG%") do set "PKG_SIZE=%%~zA"
if "%PKG_SIZE%"=="" set "PKG_SIZE=0"
if %PKG_SIZE% LSS 1048576 (
    del "%LOCAL_PKG%"
    echo [ERROR] 下载的文件大小异常（%PKG_SIZE% 字节），版本号 %NACOS_VERSION% 可能不存在，请确认后重试
    exit /b 1
)
echo [SUCCESS] 下载完成: %LOCAL_PKG%

REM -------------------- 解压部署 --------------------
:deploy
if exist "%NACOS_INSTALL_DIR%" (
    echo [WARN] 检测到已存在安装目录: %NACOS_INSTALL_DIR%
    if /i not "%NON_INTERACTIVE%"=="true" (
        set /p "confirm=是否覆盖安装？(y/N): "
        if /i not "!confirm!"=="y" ( echo [ERROR] 已取消安装 & exit /b 1 )
    )
    rmdir /s /q "%NACOS_INSTALL_DIR%"
)
echo [INFO] 解压安装包到 C:\ ...
powershell -NoProfile -Command "$ErrorActionPreference='Stop'; try { Expand-Archive -Path '%LOCAL_PKG%' -DestinationPath 'C:\' -Force } catch { Write-Host $_.Exception.Message; exit 1 }"
if errorlevel 1 (
    echo [ERROR] 解压失败，安装包可能已损坏，请删除 %LOCAL_PKG% 后重新下载
    exit /b 1
)
if not exist "%NACOS_INSTALL_DIR%" (
    echo [ERROR] 解压后未找到 nacos 目录，安装包结构异常
    exit /b 1
)
echo [SUCCESS] Nacos 已部署到 %NACOS_INSTALL_DIR%

REM -------------------- 配置 application.properties --------------------
set "CONF=%NACOS_INSTALL_DIR%\conf\application.properties"
if not exist "%CONF%" (
    echo [ERROR] 未找到配置文件 %CONF%，安装包结构异常
    exit /b 1
)
echo [INFO] 配置 %CONF% ...
echo.>> "%CONF%"
echo # ===== 自动化脚本添加的配置 =====>> "%CONF%"
echo server.port=%NACOS_PORT%>> "%CONF%"
if /i "%DB_TYPE%"=="mysql" (
    echo spring.sql.init.platform=mysql>> "%CONF%"
    echo db.num=1>> "%CONF%"
    echo db.url.0=jdbc:mysql://%MYSQL_HOST%:%MYSQL_PORT%/%MYSQL_DB%?characterEncoding=utf8^&connectTimeout=1000^&socketTimeout=3000^&autoReconnect=true^&useUnicode=true^&useSSL=false^&serverTimezone=UTC>> "%CONF%"
    echo db.user.0=%MYSQL_USER%>> "%CONF%"
    echo db.password.0=%MYSQL_PASSWORD%>> "%CONF%"
    echo [INFO] 已写入 MySQL 存储配置
) else (
    echo [INFO] 使用 Derby 内嵌存储库（默认）
)
REM 鉴权配置（生成随机密钥）
for /f %%i in ('powershell -NoProfile -Command "[Convert]::ToBase64String((1..32 ^| %%{Get-Random -Max 256}))"') do set "AUTH_TOKEN=%%i"
for /f %%i in ('powershell -NoProfile -Command "-join((1..16) ^| %%{[char](Get-Random -Min 97 -Max 122)})"') do set "AUTH_VALUE=%%i"
echo nacos.core.auth.enabled=true>> "%CONF%"
echo nacos.core.auth.server.identity.key=nacos>> "%CONF%"
echo nacos.core.auth.server.identity.value=%AUTH_VALUE%>> "%CONF%"
echo nacos.core.auth.plugin.nacos.token.secret.key=%AUTH_TOKEN%>> "%CONF%"
echo [SUCCESS] application.properties 配置完成

REM -------------------- 集群配置 --------------------
if /i not "%DEPLOY_MODE%"=="cluster" goto skip_cluster_conf
set "CLUSTER_CONF=%NACOS_INSTALL_DIR%\conf\cluster.conf"
echo [INFO] 生成集群配置 %CLUSTER_CONF% ...
echo # Nacos 集群节点列表（由自动化脚本生成）> "%CLUSTER_CONF%"
for %%n in (%CLUSTER_NODES:,= %) do echo %%n>> "%CLUSTER_CONF%"
echo [SUCCESS] 集群配置完成
if /i not "%DB_TYPE%"=="mysql" echo [WARN] 集群模式强烈建议使用 MySQL 存储库
:skip_cluster_conf

REM -------------------- MySQL 表结构提示 --------------------
if /i "%DB_TYPE%"=="mysql" (
    echo [WARN] 请确保已创建数据库 %MYSQL_DB% 并导入表结构:
    echo        %NACOS_INSTALL_DIR%\conf\mysql-schema.sql
    echo        可执行: mysql -h%MYSQL_HOST% -P%MYSQL_PORT% -u%MYSQL_USER% -p %MYSQL_DB% ^< "%NACOS_INSTALL_DIR%\conf\mysql-schema.sql"
)

REM -------------------- 启动服务 --------------------
echo [INFO] 启动 Nacos 服务...
if /i "%DEPLOY_MODE%"=="standalone" (
    start "Nacos" cmd /c "%NACOS_INSTALL_DIR%\bin\startup.cmd -m standalone"
) else (
    start "Nacos" cmd /c "%NACOS_INSTALL_DIR%\bin\startup.cmd"
)
timeout /t 8 /nobreak >nul

REM -------------------- 安装总结 --------------------
echo.
echo ========================================
echo         Nacos 安装完成
echo ========================================
echo 版本:        %NACOS_VERSION%
echo 部署模式:    %DEPLOY_MODE%
echo 存储库:      %DB_TYPE%
echo 安装目录:    %NACOS_INSTALL_DIR%
echo 控制台地址:  http://localhost:%NACOS_PORT%/nacos
echo 默认账号:    nacos / nacos（首次登录请尽快修改）
echo.
echo 常用命令:
echo   启动: %NACOS_INSTALL_DIR%\bin\startup.cmd -m standalone
echo   停止: %NACOS_INSTALL_DIR%\bin\shutdown.cmd
if /i "%DEPLOY_MODE%"=="cluster" echo [WARN] 集群模式：请在每个节点上执行本脚本，保持相同的节点列表和 MySQL 配置
echo ========================================

endlocal
exit /b 0
