@echo off
REM ============================================================
REM lib_common.bat —— 安装脚本通用子程序库（Windows）
REM
REM 供各安装脚本以 call 方式复用，避免重复实现公共逻辑。
REM
REM 用法:
REM   call "%~dp0..\lib_common.bat" :detect_arch SYS_TARGET
REM   call "%~dp0..\lib_common.bat" :check_target_match "x86_64-pc-windows-msvc" "%SYS_TARGET%"
REM   call "%~dp0..\lib_common.bat" :verify_executable "C:\rnacos\rnacos.exe" "%SYS_TARGET%"
REM   call "%~dp0..\lib_common.bat" :validate_port "8848" "HTTP/API"
REM
REM 约定:
REM   - 第一个参数为子程序标签（如 :detect_arch）
REM   - 成功返回 exit /b 0，失败返回 exit /b 1
REM ============================================================

REM 根据第一个参数分发到对应子程序
if "%~1"=="" (
    echo [ERROR] lib_common.bat 需要指定子程序标签作为第一个参数
    exit /b 1
)
call %*
exit /b %errorlevel%

REM ------------------------------------------------------------
REM :detect_arch <返回变量名>
REM   推断当前系统应使用的目标平台标识，写入指定变量。
REM   ARM64 -> aarch64-pc-windows-msvc，其余 -> x86_64-pc-windows-msvc
REM ------------------------------------------------------------
:detect_arch
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" (
    set "%~1=aarch64-pc-windows-msvc"
) else (
    set "%~1=x86_64-pc-windows-msvc"
)
exit /b 0

REM ------------------------------------------------------------
REM :check_target_match <选择的target> <系统推断target>
REM   两者不一致时输出 WARN（不阻断安装）。
REM ------------------------------------------------------------
:check_target_match
if /i not "%~1"=="%~2" (
    echo [WARN] 当前选择的目标平台 %~1 与系统架构 %PROCESSOR_ARCHITECTURE%（推断为 %~2）不一致
    echo [WARN] 若安装后可执行文件无法运行，请用 --target %~2 重新安装
)
exit /b 0

REM ------------------------------------------------------------
REM :verify_executable <可执行文件路径> <系统推断target>
REM   尝试运行 --version，失败再试 --help，两者皆失败则 WARN 架构不匹配。
REM   仅警告，不阻断（返回 0）。
REM ------------------------------------------------------------
:verify_executable
"%~1" --version >nul 2>nul
if not errorlevel 1 exit /b 0
"%~1" --help >nul 2>nul
if not errorlevel 1 exit /b 0
echo [WARN] %~1 无法运行，可能与系统架构不匹配，请尝试 --target %~2 重新安装
exit /b 0

REM ------------------------------------------------------------
REM :validate_port <端口> <名称>
REM   校验端口为 1-65535 的整数，非法则报错返回 1。
REM ------------------------------------------------------------
:validate_port
set "_port=%~1"
set "_name=%~2"
echo %_port%| findstr /r "^[1-9][0-9]*$" >nul
if errorlevel 1 (
    echo [ERROR] %_name% 端口无效: '%_port%'，请输入 1-65535 之间的数字
    exit /b 1
)
if %_port% GTR 65535 (
    echo [ERROR] %_name% 端口无效: '%_port%'，请输入 1-65535 之间的数字
    exit /b 1
)
exit /b 0
