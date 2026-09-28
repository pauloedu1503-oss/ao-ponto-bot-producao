$ErrorActionPreference = 'Stop'

$projeto = Split-Path -Parent $MyInvocation.MyCommand.Path
$logs = Join-Path $projeto 'logs'
$arquivoPid = Join-Path $logs 'producao.pid'
$supervisor = Join-Path $projeto 'PRODUCAO_WINDOWS.ps1'
$processos = @()

if (Test-Path -LiteralPath $arquivoPid) {
    $idSalvo = Get-Content -LiteralPath $arquivoPid -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($idSalvo -match '^\d+$') {
        $processo = Get-CimInstance Win32_Process -Filter "ProcessId = $idSalvo" -ErrorAction SilentlyContinue
        if ($null -ne $processo -and $processo.CommandLine -like "*$supervisor*") {
            $processos += $processo
        }
    }
}

if ($processos.Count -eq 0) {
    $processos = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*$supervisor*" })
}

foreach ($processo in $processos) {
    & taskkill.exe /PID $processo.ProcessId /T /F | Out-Null
}

$limite = (Get-Date).AddSeconds(10)
do {
    Start-Sleep -Milliseconds 250
    $aindaRodando = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*$supervisor*" })
} while ($aindaRodando.Count -gt 0 -and (Get-Date) -lt $limite)

if ($aindaRodando.Count -gt 0) {
    throw 'O processo anterior não encerrou.'
}

Remove-Item -LiteralPath $arquivoPid -Force -ErrorAction SilentlyContinue
Write-Host 'Backend e Baileys foram encerrados.'
