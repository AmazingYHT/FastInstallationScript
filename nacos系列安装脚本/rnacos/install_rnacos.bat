@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul

REM ============================================================
REM rnacos 自动化安装脚本（Windows）
REM rnacos 是用 Rust 重写的 Nacos 服务，单文件部署
REM 支持单机/集群模式（基于 Raft），版本可配置
REM 本地 package\ 目录优先，缺失时自动从 GitHub 下载
REM 用法: install_rnacos.bat [选项]，详见 --help
REM ============================================================

REM -------------------- 默认配置 --------------------
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "LIB_COMMON=%SCRIPT_DIR%\..\lib_common.bat"
if not exist "%LIB_COMMON%" (
    echo [ERROR] 未找到通用库文件 %LIB_COMMON%
    exit /b 1
)
if "%RNACOS_VERSION%"=="" set "RNACOS_VERSION=v0.8.3"
set "RNACOS_INSTALL_DIR=C:\rnacos"
set "RNACOS_DATA_DIR=C:\rnacos\data"
set "RNACOS_PACKAGE_DIR=%SCRIPT_DIR%\package"
set "RNACOS_TARGET=x86_64-pc-windows-msvc"
set "HTTP_PORT=8848"
set "GRPC_PORT="
set "CONSOLE_PORT=10848"
set "DEPLOY_MODE="
set "RAFT_NODE_ID=1"
set "RAFT_NODE_ADDR="
set "RAFT_AUTO_INIT=true"
set "RAFT_JOIN_ADDR="
set "NON_INTERACTIVE=false"
set "DOWNLOAD_BASE=https://github.com/nacos-group/r-nacos/releases/download"

REM -------------------- 解析参数 --------------------
:parse_args
if "%~1"=="" goto after_args
if /i "%~1"=="--standalone" ( set "DEPLOY_MODE=standalone" & set "NON_INTERACTIVE=true" & shift & goto parse_args )
if /i "%~1"=="--cluster" ( set "DEPLOY_MODE=cluster" & set "NON_INTERACTIVE=true" & shift & goto parse_args )
if /i "%~1"=="--version" ( set "RNACOS_VERSION=%~2" & shift & shift & goto parse_args )
if /i "%~1"=="--http-port" ( set "HTTP_PORT=%~2" & shift & shift & goto parse_args )
if /i "%~1"=="--grpc-port" ( set "GRPC_PORT=%~2" & shift & shift & goto parse_args )
if /i "%~1"=="--console-port" ( set "CONSOLE_PORT=%~2" & shift & shift & goto parse_args )
if /i "%~1"=="--node-id" ( set "RAFT_NODE_ID=%~2" & shift & shift & goto parse_args )
if /i "%~1"=="--node-addr" ( set "RAFT_NODE_ADDR=%~2" & shift & shift & goto parse_args )
if /i "%~1"=="--auto-init" ( set "RAFT_AUTO_INIT=true" & shift & goto parse_args )
if /i "%~1"=="--join-addr" ( set "RAFT_JOIN_ADDR=%~2" & set "RAFT_AUTO_INIT=false" & shift & shift & goto parse_args )
if /i "%~1"=="--target" ( set "RNACOS_TARGET=%~2" & shift & shift & goto parse_args )
if /i "%~1"=="-h" goto usage
if /i "%~1"=="--help" goto usage
echo [ERROR] 未知参数: %~1（使用 --help 查看帮助）
exit /b 1

:usage
echo rnacos 自动化安装脚本（Windows）
echo.
echo 用法: install_rnacos.bat [选项]
echo.
echo   --standalone               单机模式部署
echo   --cluster                  集群模式部署
echo   --version 版本号            指定 rnacos 版本（默认 %RNACOS_VERSION%）
echo   --http-port 端口            HTTP/API 端口（默认 %HTTP_PORT%）
echo   --grpc-port 端口            gRPC 端口（默认 HTTP端口+1000）
echo   --console-port 端口         控制台端口（默认 %CONSOLE_PORT%）
echo   --node-id id               集群节点 ID（集群模式必填）
echo   --node-addr ip:port        本节点 Raft 地址 ip:grpc端口（集群模式必填）
echo   --auto-init                作为集群首个节点初始化
echo   --join-addr ip:port        加入已有集群，填首节点地址
echo   --target target            二进制目标平台（默认 %RNACOS_TARGET%）
echo   -h, --help                 显示此帮助
echo.
echo 示例:
echo   install_rnacos.bat --standalone
echo   install_rnacos.bat --cluster --node-id 1 --node-addr 192.168.1.10:9848 --auto-init
echo   install_rnacos.bat --cluster --node-id 2 --node-addr 192.168.1.11:9848 --join-addr 192.168.1.10:9848
exit /b 0

:after_args
echo [INFO] 开始安装 rnacos %RNACOS_VERSION% ...

REM -------------------- 检查管理员权限 --------------------
net session >nul 2>nul
if errorlevel 1 (
    echo [ERROR] 权限不足：安装到 %RNACOS_INSTALL_DIR% 需要管理员权限
    echo         请右键以「管理员身份运行」本脚本
    exit /b 1
)
echo [INFO] 管理员权限检查通过

REM -------------------- 检测系统架构 --------------------
call "%LIB_COMMON%" :detect_arch SYS_TARGET
call "%LIB_COMMON%" :check_target_match "%RNACOS_TARGET%" "%SYS_TARGET%"

REM -------------------- 基础配置（交互） --------------------
if /i "%NON_INTERACTIVE%"=="true" goto skip_basic
echo.
echo [INFO] 基础配置（直接回车使用默认值）
set /p "input=rnacos 版本 (默认 %RNACOS_VERSION%): " & if not "!input!"=="" set "RNACOS_VERSION=!input!"
set /p "input=HTTP/API 端口 (默认 %HTTP_PORT%): " & if not "!input!"=="" set "HTTP_PORT=!input!"
set /a "DEFAULT_GRPC=%HTTP_PORT%+1000"
set /p "input=gRPC 端口 (默认 !DEFAULT_GRPC!): " & if not "!input!"=="" ( set "GRPC_PORT=!input!" ) else ( if "%GRPC_PORT%"=="" set "GRPC_PORT=!DEFAULT_GRPC!" )
set /p "input=控制台端口 (默认 %CONSOLE_PORT%): " & if not "!input!"=="" set "CONSOLE_PORT=!input!"
echo [INFO] 版本: %RNACOS_VERSION%  HTTP: %HTTP_PORT%  gRPC: %GRPC_PORT%  控制台: %CONSOLE_PORT%
:skip_basic

REM -------------------- 校验端口 --------------------
if "%GRPC_PORT%"=="" set /a GRPC_PORT=%HTTP_PORT%+1000
call "%LIB_COMMON%" :validate_port "%HTTP_PORT%" "HTTP/API" || exit /b 1
call "%LIB_COMMON%" :validate_port "%GRPC_PORT%" "gRPC" || exit /b 1
call "%LIB_COMMON%" :validate_port "%CONSOLE_PORT%" "控制台" || exit /b 1

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

REM -------------------- 集群参数 --------------------
if /i not "%DEPLOY_MODE%"=="cluster" goto skip_cluster_input
if /i "%NON_INTERACTIVE%"=="true" goto check_cluster
echo.
echo [INFO] 配置集群节点信息
set /p "input=本节点 ID (整数，每个节点唯一，默认 %RAFT_NODE_ID%): " & if not "!input!"=="" set "RAFT_NODE_ID=!input!"
set /p "RAFT_NODE_ADDR=本节点 Raft 地址 (ip:grpc端口，如 192.168.1.10:9848): "
echo 本节点是否为集群首个节点?
set /p "c=  1) 是，自动初始化  2) 否，加入已有集群 [1-2] (默认 1): "
if "!c!"=="2" (
    set "RAFT_AUTO_INIT=false"
    set /p "RAFT_JOIN_ADDR=请输入首节点的 Raft 地址 (ip:grpc端口): "
) else (
    set "RAFT_AUTO_INIT=true"
)
:check_cluster
if "%RAFT_NODE_ADDR%"=="" ( echo [ERROR] 集群模式必须提供本节点地址（--node-addr） & exit /b 1 )
if /i "%RAFT_AUTO_INIT%"=="false" if "%RAFT_JOIN_ADDR%"=="" ( echo [ERROR] 加入集群的节点必须提供首节点地址（--join-addr） & exit /b 1 )
:skip_cluster_input

REM -------------------- 准备安装包 --------------------
set "PKG_NAME=rnacos-%RNACOS_TARGET%-%RNACOS_VERSION%.zip"
set "LOCAL_PKG=%RNACOS_PACKAGE_DIR%\%PKG_NAME%"
if not exist "%RNACOS_PACKAGE_DIR%" mkdir "%RNACOS_PACKAGE_DIR%"
if exist "%LOCAL_PKG%" (
    echo [INFO] 使用本地安装包: %LOCAL_PKG%
    goto deploy
)
set "DL_URL=%DOWNLOAD_BASE%/%RNACOS_VERSION%/%PKG_NAME%"
echo [INFO] 本地未找到安装包，从 GitHub 下载: %DL_URL%
powershell -NoProfile -Command "$ErrorActionPreference='Stop'; try { [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $pp=$ProgressPreference; $ProgressPreference='SilentlyContinue'; Invoke-WebRequest -Uri '%DL_URL%' -OutFile '%LOCAL_PKG%' -TimeoutSec 60; $ProgressPreference=$pp } catch { Write-Host $_.Exception.Message; exit 1 }"
if errorlevel 1 (
    if exist "%LOCAL_PKG%" del "%LOCAL_PKG%"
    echo [ERROR] 下载失败（网络超时或版本不存在），请检查网络或手动将 %PKG_NAME% 放入 %RNACOS_PACKAGE_DIR%
    echo         若为架构不匹配，可尝试 --target %SYS_TARGET%
    exit /b 1
)
REM 校验下载文件大小（< 1MB 视为无效，如 404 页面）
for %%A in ("%LOCAL_PKG%") do set "PKG_SIZE=%%~zA"
if "%PKG_SIZE%"=="" set "PKG_SIZE=0"
if %PKG_SIZE% LSS 1048576 (
    del "%LOCAL_PKG%"
    echo [ERROR] 下载的文件大小异常（%PKG_SIZE% 字节），版本 %RNACOS_VERSION% 或目标平台 %RNACOS_TARGET% 可能不存在，请确认后重试
    exit /b 1
)
echo [SUCCESS] 下载完成: %LOCAL_PKG%

REM -------------------- 解压部署 --------------------
:deploy
if not exist "%RNACOS_INSTALL_DIR%" mkdir "%RNACOS_INSTALL_DIR%"
if not exist "%RNACOS_DATA_DIR%" mkdir "%RNACOS_DATA_DIR%"
echo [INFO] 解压 rnacos 二进制...
powershell -NoProfile -Command "$ErrorActionPreference='Stop'; try { Expand-Archive -Path '%LOCAL_PKG%' -DestinationPath '%RNACOS_INSTALL_DIR%' -Force } catch { Write-Host $_.Exception.Message; exit 1 }"
if errorlevel 1 (
    echo [ERROR] 解压失败，安装包可能已损坏，请删除 %LOCAL_PKG% 后重新下载
    exit /b 1
)
REM 查找 rnacos.exe 并归位
if not exist "%RNACOS_INSTALL_DIR%\rnacos.exe" (
    for /r "%RNACOS_INSTALL_DIR%" %%f in (rnacos.exe) do (
        if not "%%~dpf"=="%RNACOS_INSTALL_DIR%\" move /y "%%f" "%RNACOS_INSTALL_DIR%\rnacos.exe" >nul
    )
)
if not exist "%RNACOS_INSTALL_DIR%\rnacos.exe" (
    echo [ERROR] 解压后未找到 rnacos.exe，请确认目标平台 %RNACOS_TARGET% 是否正确
    exit /b 1
)
REM 验证可执行文件能否在当前架构运行（架构不匹配时会报错）
call "%LIB_COMMON%" :verify_executable "%RNACOS_INSTALL_DIR%\rnacos.exe" "%SYS_TARGET%"
echo [SUCCESS] rnacos 已部署到 %RNACOS_INSTALL_DIR%

REM -------------------- 生成配置文件 --------------------
if "%GRPC_PORT%"=="" set /a GRPC_PORT=%HTTP_PORT%+1000
set "ENV_FILE=%RNACOS_INSTALL_DIR%\rnacos.env"
echo [INFO] 生成配置文件 %ENV_FILE% ...
set "DATA_DIR_FWD=%RNACOS_DATA_DIR:\=/%"
(
echo # rnacos 配置文件（由自动化脚本生成）
echo RNACOS_HTTP_PORT=%HTTP_PORT%
echo RNACOS_GRPC_PORT=%GRPC_PORT%
echo RNACOS_HTTP_CONSOLE_PORT=%CONSOLE_PORT%
echo RNACOS_CONFIG_DB_DIR=%DATA_DIR_FWD%
echo RNACOS_HTTP_WORKERS=8
) > "%ENV_FILE%"
if /i "%DEPLOY_MODE%"=="cluster" (
    (
    echo.
    echo # ===== 集群配置 =====
    echo RNACOS_RAFT_NODE_ID=%RAFT_NODE_ID%
    echo RNACOS_RAFT_NODE_ADDR=%RAFT_NODE_ADDR%
    echo RNACOS_RAFT_AUTO_INIT=%RAFT_AUTO_INIT%
    ) >> "%ENV_FILE%"
    if /i "%RAFT_AUTO_INIT%"=="false" echo RNACOS_RAFT_JOIN_ADDR=%RAFT_JOIN_ADDR%>> "%ENV_FILE%"
)
if not exist "%ENV_FILE%" (
    echo [ERROR] 配置文件写入失败，请检查 %RNACOS_INSTALL_DIR% 目录权限
    exit /b 1
)
echo [SUCCESS] 配置文件生成完成

REM -------------------- 启动服务 --------------------
echo [INFO] 启动 rnacos 服务...
start "rnacos" cmd /c "cd /d %RNACOS_INSTALL_DIR% && rnacos.exe -e rnacos.env"
timeout /t 3 /nobreak >nul

REM -------------------- 安装总结 --------------------
echo.
echo ========================================
echo         rnacos 安装完成
echo ========================================
echo 版本:        %RNACOS_VERSION%
echo 部署模式:    %DEPLOY_MODE%
echo 安装目录:    %RNACOS_INSTALL_DIR%
echo 数据目录:    %RNACOS_DATA_DIR%
echo HTTP/API:    %HTTP_PORT%   gRPC: %GRPC_PORT%
echo 控制台地址:  http://localhost:%CONSOLE_PORT%/rnacos/
echo 默认账号:    admin / admin（首次登录请尽快修改）
echo.
echo 常用命令:
echo   启动: cd /d %RNACOS_INSTALL_DIR% ^&^& rnacos.exe -e rnacos.env
echo   提示: 如需开机自启，可借助 nssm 等工具将其注册为 Windows 服务
if /i "%DEPLOY_MODE%"=="cluster" echo [WARN] 集群模式：先启动 --auto-init 首节点，再在其他节点用 --join-addr 加入
echo ========================================

endlocal
exit /b 0
