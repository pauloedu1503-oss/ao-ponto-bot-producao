@echo off
setlocal
chcp 65001 >nul
title AO PONTO BOT - PRODUCAO
cd /d "%~dp0"

echo ==============================================
echo       AO PONTO BOT - INICIANDO PRODUCAO
echo ==============================================
echo.

if not exist "backend\.env" (
  echo [ERRO] Nao encontrei backend\.env.
  pause
  exit /b 1
)

if not exist "backend\data\ao_ponto.db" (
  echo [ERRO] Nao encontrei o banco backend\data\ao_ponto.db.
  pause
  exit /b 1
)

if not exist "whatsapp_bridge\auth_info\creds.json" (
  echo [ERRO] Nao encontrei a sessao do WhatsApp.
  pause
  exit /b 1
)

start "Ao Ponto Bot" /min powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0PRODUCAO_WINDOWS.ps1"

echo Backend e WhatsApp estao sendo iniciados...
timeout /t 15 /nobreak >nul

powershell.exe -NoProfile -Command "try { $r=Invoke-RestMethod -Uri 'http://127.0.0.1:8080/health' -TimeoutSec 8; if($r.ok){exit 0}else{exit 1} } catch { exit 1 }"

if errorlevel 1 (
  echo.
  echo [ERRO] O backend nao respondeu.
  echo Verifique os arquivos da pasta logs.
  echo.
  pause
  exit /b 1
)

echo.
echo ==============================================
echo       BOT ATIVO PARA PRODUCAO
echo ==============================================
echo Backend: ativo
echo Baileys: iniciado e com reconexao automatica
echo Banco e fila: persistentes
echo.
echo Pode fechar esta janela. Nao desligue nem suspenda o PC.
echo Para acompanhar, abra a pasta logs.
echo.
pause
exit /b 0
