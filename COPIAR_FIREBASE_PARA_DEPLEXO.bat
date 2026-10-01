@echo off
setlocal
title Configurar notificacoes no Deplexo

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop'; $arquivo=Join-Path '%~dp0' 'backend\firebase-service-account.json'; if(-not (Test-Path -LiteralPath $arquivo)){throw 'Credencial do Firebase nao encontrada.'}; $json=(Get-Content -LiteralPath $arquivo -Raw | ConvertFrom-Json | ConvertTo-Json -Compress); Set-Clipboard -Value ('FIREBASE_SERVICE_ACCOUNT_JSON=' + $json); Write-Host ''; Write-Host 'Credencial copiada com sucesso.' -ForegroundColor Green; Write-Host 'No Deplexo, abra Env vars, clique em Paste .env e pressione Ctrl+V.'"

echo.
pause
