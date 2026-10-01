@echo off
setlocal
title Sincronizar Projeto - Ao Ponto Bot
cd /d "%~dp0"

echo ==============================================
echo       SINCRONIZAR PROJETO COM O GITHUB
echo ==============================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0SINCRONIZAR_PROJETO_GITHUB.ps1"
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
