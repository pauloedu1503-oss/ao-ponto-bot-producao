@echo off
setlocal
chcp 65001 >nul
title AO PONTO BOT - REINICIANDO
cd /d "%~dp0"

echo ==============================================
echo       REINICIANDO BAILEYS E BACKEND
echo ==============================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PARAR_PRODUCAO.ps1"
if errorlevel 1 (
  echo.
  echo [ERRO] Nao foi possivel reiniciar o bot.
  pause
  exit /b 1
)

call "%~dp0INICIAR_PRODUCAO.bat"
