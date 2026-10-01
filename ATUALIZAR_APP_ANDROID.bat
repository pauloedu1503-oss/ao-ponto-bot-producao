@echo off
setlocal
title Publicar atualização do Ao Ponto Bot
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PUBLICAR_ATUALIZACAO_APP.ps1"
set "codigo=%errorlevel%"
echo.
if not "%codigo%"=="0" (
  echo A atualizacao terminou com erro. O codigo foi: %codigo%
  echo Tire uma foto desta tela se precisar de ajuda.
) else (
  echo Processo concluido.
)
echo.
pause
exit /b %codigo%
