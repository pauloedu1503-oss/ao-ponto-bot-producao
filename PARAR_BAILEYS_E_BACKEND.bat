@echo off
setlocal
chcp 65001 >nul
title AO PONTO BOT - PARANDO
cd /d "%~dp0"

echo ==============================================
echo         PARANDO BAILEYS E BACKEND
echo ==============================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PARAR_PRODUCAO.ps1"
if errorlevel 1 (
  echo.
  echo [ERRO] Nao foi possivel parar o bot.
  pause
  exit /b 1
)

echo.
echo ==============================================
echo             BOT DESLIGADO
echo ==============================================
echo.
pause
exit /b 0
