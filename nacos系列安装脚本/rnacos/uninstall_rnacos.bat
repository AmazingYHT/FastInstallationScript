@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul

REM ============================================================
REM rnacos 卸载脚本（Windows）
REM 停止 rnacos 进程并删除安装目录
REM 默认保留数据目录，需用 --purge 显式删除
REM 用法: uninstall_rnacos.bat [-y] [--purge]
REM ============================================================

set "RNACOS_INSTALL_DIR=C:\rnacos"
set "RNACOS_DATA_DIR=C:\rnacos\data"
set "FORCE=false"
set "PURGE=false"

:parse_args
if "%~1"=="" goto run
if /i "%~1"=="-y" ( set "FORCE=true" & shift & goto parse_args )
if /i "%~1"=="--yes" ( set "FORCE=true" & shift & goto parse_args )
if /i "%~1"=="--purge" ( set "PURGE=true" & shift & goto parse_args )
if /i "%~1"=="-h" goto usage
if /i "%~1"=="--help" goto usage
shift
goto parse_args

:usage
echo 用法: uninstall_rnacos.bat [-y^|--yes] [--purge]
echo   -y, --yes   跳过确认直接卸载
echo   --purge     同时删除数据目录 %RNACOS_DATA_DIR%
exit /b 0

:run
echo [INFO] 即将卸载 rnacos
echo   - 停止 rnacos 进程
echo   - 删除安装目录 %RNACOS_INSTALL_DIR%
if /i "%PURGE%"=="true" (
    echo [WARN]  - 删除数据目录 %RNACOS_DATA_DIR%（不可恢复）
) else (
    echo   - 保留数据目录 %RNACOS_DATA_DIR%（如需删除请加 --purge）
)

if /i not "%FORCE%"=="true" (
    set /p "confirm=确认卸载？(y/N): "
    if /i not "!confirm!"=="y" ( echo 已取消 & exit /b 0 )
)

echo [INFO] 停止 rnacos 进程...
taskkill /f /im rnacos.exe >nul 2>nul

REM 如果 purge 则连数据目录一起删，否则保留数据目录
if /i "%PURGE%"=="true" (
    if exist "%RNACOS_INSTALL_DIR%" rmdir /s /q "%RNACOS_INSTALL_DIR%"
    echo [SUCCESS] 已删除安装目录及数据目录
) else (
    REM 数据目录在安装目录下时，先备份再删除安装目录
    if exist "%RNACOS_INSTALL_DIR%\rnacos.exe" del /q "%RNACOS_INSTALL_DIR%\rnacos.exe"
    if exist "%RNACOS_INSTALL_DIR%\rnacos.env" del /q "%RNACOS_INSTALL_DIR%\rnacos.env"
    echo [SUCCESS] 已删除 rnacos 程序文件，数据目录保留: %RNACOS_DATA_DIR%
)

echo [SUCCESS] rnacos 卸载完成
endlocal
exit /b 0
