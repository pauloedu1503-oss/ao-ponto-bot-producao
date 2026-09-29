@echo off
setlocal
title Publicar atualização do Ao Ponto Bot
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PUBLICAR_ATUALIZACAO_APP.ps1"
exit /b %errorlevel%
