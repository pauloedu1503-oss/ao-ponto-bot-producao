$ErrorActionPreference = 'Stop'

$projeto = Split-Path -Parent $MyInvocation.MyCommand.Path
$backend = Join-Path $projeto 'backend'
$bridge = Join-Path $projeto 'whatsapp_bridge'
$logs = Join-Path $projeto 'logs'
$dart = 'C:\src\flutter\bin\cache\dart-sdk\bin\dart.exe'
$node = 'C:\Program Files\nodejs\node.exe'

New-Item -ItemType Directory -Force -Path $logs | Out-Null
$env:APPDATA = Join-Path $projeto '.runtime'
New-Item -ItemType Directory -Force -Path $env:APPDATA | Out-Null

$arquivoTrava = Join-Path $logs 'producao.lock'
$arquivoPid = Join-Path $logs 'producao.pid'
try {
    Set-Content -LiteralPath $arquivoPid -Value $PID -Encoding Ascii

    $trava = [IO.File]::Open(
        $arquivoTrava,
        [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None
    )
} catch [IO.IOException] {
    exit 0
}

try {
    if (-not (Test-Path -LiteralPath $dart)) { throw "Dart não encontrado em $dart" }
    if (-not (Test-Path -LiteralPath $node)) { throw "Node não encontrado em $node" }
    if (-not (Test-Path -LiteralPath (Join-Path $backend '.env'))) { throw 'backend\.env não encontrado' }
    if (-not (Test-Path -LiteralPath (Join-Path $bridge 'auth_info\creds.json'))) { throw 'Sessão do WhatsApp não encontrada' }

    $processoBackend = $null
    $processoWhatsapp = $null

    while ($true) {
        if ($null -eq $processoBackend -or $processoBackend.HasExited) {
            $processoBackend = Start-Process -FilePath $dart `
                -ArgumentList @('run', 'bin/server.dart') `
                -WorkingDirectory $backend `
                -WindowStyle Hidden `
                -RedirectStandardOutput (Join-Path $logs 'backend.log') `
                -RedirectStandardError (Join-Path $logs 'backend-error.log') `
                -PassThru
        }

        if ($null -eq $processoWhatsapp -or $processoWhatsapp.HasExited) {
            $processoWhatsapp = Start-Process -FilePath $node `
                -ArgumentList @('index.js') `
                -WorkingDirectory $bridge `
                -WindowStyle Hidden `
                -RedirectStandardOutput (Join-Path $logs 'whatsapp.log') `
                -RedirectStandardError (Join-Path $logs 'whatsapp-error.log') `
                -PassThru
        }

        Start-Sleep -Seconds 5
    }
}
finally {
    if ($null -ne $processoWhatsapp -and -not $processoWhatsapp.HasExited) { Stop-Process -Id $processoWhatsapp.Id -Force }
    if ($null -ne $processoBackend -and -not $processoBackend.HasExited) { Stop-Process -Id $processoBackend.Id -Force }
    Remove-Item -LiteralPath $arquivoPid -Force -ErrorAction SilentlyContinue
    $trava.Dispose()
}
