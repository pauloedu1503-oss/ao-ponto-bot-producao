@echo off
setlocal
title Limpar projetos duplicados e arquivos gerados
cd /d "%~dp0"
echo ==============================================
echo     LIMPEZA SEGURA DE PROJETOS E CACHES
echo ==============================================
echo.
echo A copia atual da Ao Ponto e os projetos mais recentes serao preservados.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0LIMPAR_PROJETOS_DUPLICADOS.ps1"
set "resultado=%errorlevel%"
echo.
if "%resultado%"=="0" (echo Processo finalizado.) else (echo A limpeza parou por causa de um erro. Leia a mensagem acima.)
echo.
pause
exit /b %resultado%
