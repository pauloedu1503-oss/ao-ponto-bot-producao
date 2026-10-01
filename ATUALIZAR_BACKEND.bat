@echo off
setlocal
title Atualizar Backend - Ao Ponto Bot
cd /d "%~dp0"

echo ==============================================
echo       ATUALIZAR BACKEND - AO PONTO BOT
echo ==============================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PUBLICAR_BACKEND_DEPLEXO.ps1"
set "resultado=%errorlevel%"

echo.
if "%resultado%"=="0" (
  echo Processo finalizado.
) else (
  echo Ocorreu um erro. Leia a mensagem acima antes de fechar.
)
echo.
pause
exit /b %resultado%
