@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul

REM ============================================================
REM Nacos 卸载脚本（Windows）
REM 停止 Nacos 进程并删除安装目录
REM 不会删除外部 MySQL 中的数据
REM 用法: uninstall_nacos.bat [-y]
REM ============================================================

set "NACOS_INSTALL_DIR=C:\nacos"
set "FORCE=false"

if /i "%~1"=="-y" set "FORCE=true"
if /i "%~1"=="--yes" set "FORCE=true"
if /i "%~1"=="-h" goto usage
if /i "%~1"=="--help" goto usage
goto run

:usage
echo 用法: uninstall_nacos.bat [-y^|--yes]
echo   -y, --yes   跳过确认直接卸载
exit /b 0

:run
echo [INFO] 即将卸载 Nacos
echo   - 停止 Nacos 进程
echo   - 删除安装目录 %NACOS_INSTALL_DIR%
echo [WARN] 不会删除外部 MySQL 中的数据

if /i not "%FORCE%"=="true" (
    set /p "confirm=确认卸载？(y/N): "
    if /i not "!confirm!"=="y" ( echo 已取消 & exit /b 0 )
)

echo [INFO] 停止 Nacos 进程...
if exist "%NACOS_INSTALL_DIR%\bin\shutdown.cmd" call "%NACOS_INSTALL_DIR%\bin\shutdown.cmd" >nul 2>nul
REM 兜底：结束包含 nacos 的 java 进程
powershell -NoProfile -Command "Get-WmiObject Win32_Process | Where-Object { $_.CommandLine -like '*nacos*' -and $_.Name -eq 'java.exe' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }" 2>nul

if exist "%NACOS_INSTALL_DIR%" (
    rmdir /s /q "%NACOS_INSTALL_DIR%"
    echo [SUCCESS] 已删除安装目录 %NACOS_INSTALL_DIR%
)

echo [SUCCESS] Nacos 卸载完成
endlocal
exit /b 0
