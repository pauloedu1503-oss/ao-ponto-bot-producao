@echo off
title Ao Ponto Bot - Chrome

cd /d "%~dp0app"

set "PUB_CACHE=%~dp0.runtime\pub-cache"
set "GRADLE_USER_HOME=%~dp0.runtime\gradle"

echo Abrindo o Ao Ponto Bot no Chrome...
echo.

call C:\src\flutter\bin\flutter.bat pub get
if errorlevel 1 goto erro

call C:\src\flutter\bin\flutter.bat run -d chrome
if errorlevel 1 goto erro

exit /b 0

:erro
echo.
echo Nao foi possivel abrir o aplicativo no Chrome.
pause
exit /b 1
