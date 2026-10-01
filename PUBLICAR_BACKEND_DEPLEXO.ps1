$ErrorActionPreference = 'Stop'

$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path
$backend = Join-Path $raiz 'backend'
$ponte = Join-Path $raiz 'whatsapp_bridge'
$repositorio = 'https://github.com/pauloedu1503-oss/ao-ponto-bot-backend-deploy.git'
$dartPreferido = 'C:\src\flutter\bin\cache\dart-sdk\bin\dart.exe'
$temporario = Join-Path ([IO.Path]::GetTempPath()) ("ao-ponto-backend-" + [guid]::NewGuid().ToString('N'))

function Exigir-Comando([string]$Nome, [string]$Ajuda) {
    if (-not (Get-Command $Nome -ErrorAction SilentlyContinue)) {
        throw "$Nome não foi encontrado. $Ajuda"
    }
}

function Copiar-PastaLimpa([string]$Origem, [string]$Destino) {
    $raizTemp = [IO.Path]::GetFullPath($temporario).TrimEnd('\') + '\'
    $destinoCompleto = [IO.Path]::GetFullPath($Destino)
    if (-not $destinoCompleto.StartsWith($raizTemp, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Destino temporário inválido. A publicação foi interrompida por segurança.'
    }
    if (Test-Path -LiteralPath $destinoCompleto) {
        Remove-Item -LiteralPath $destinoCompleto -Recurse -Force
    }
    Copy-Item -LiteralPath $Origem -Destination $destinoCompleto -Recurse -Force
}

try {
    Exigir-Comando 'git' 'Instale o Git para continuar.'
    Exigir-Comando 'gh' 'Instale o GitHub CLI e execute: gh auth login'

    gh auth status 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'Entre no GitHub executando uma vez: gh auth login'
    }

    if (-not (Test-Path -LiteralPath (Join-Path $backend 'bin\server.dart'))) {
        throw 'A pasta do backend não foi encontrada.'
    }
    foreach ($arquivo in @('index.js', 'package.json', 'package-lock.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $ponte $arquivo))) {
            throw "Arquivo da ponte do WhatsApp não encontrado: $arquivo"
        }
    }

    $dart = if (Test-Path -LiteralPath $dartPreferido) {
        $dartPreferido
    } else {
        (Get-Command dart -ErrorAction Stop).Source
    }

    Write-Host ''
    Write-Host '1/4 Verificando o backend...' -ForegroundColor Cyan
    Push-Location $backend
    try {
        & $dart test
        if ($LASTEXITCODE -ne 0) {
            throw 'Os testes falharam. Nada foi publicado.'
        }
    } finally {
        Pop-Location
    }

    Write-Host ''
    Write-Host '2/4 Preparando a publicação...' -ForegroundColor Cyan
    git clone --quiet $repositorio $temporario
    if ($LASTEXITCODE -ne 0) {
        throw 'Não foi possível baixar o repositório de implantação.'
    }

    Copiar-PastaLimpa (Join-Path $backend 'bin') (Join-Path $temporario 'bin')
    Copiar-PastaLimpa (Join-Path $backend 'lib') (Join-Path $temporario 'lib')
    Copy-Item -LiteralPath (Join-Path $backend 'pubspec.yaml') -Destination $temporario -Force
    Copy-Item -LiteralPath (Join-Path $backend 'pubspec.lock') -Destination $temporario -Force

    $ponteDestino = Join-Path $temporario 'whatsapp_bridge'
    New-Item -ItemType Directory -Path $ponteDestino -Force | Out-Null
    foreach ($arquivo in @('index.js', 'package.json', 'package-lock.json')) {
        Copy-Item -LiteralPath (Join-Path $ponte $arquivo) -Destination $ponteDestino -Force
    }

    $dockerfile = @'
FROM dart:stable AS build

RUN apt-get update \
    && apt-get install -y --no-install-recommends libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app/backend
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get --enforce-lockfile
COPY bin ./bin
COPY lib ./lib
RUN dart compile exe bin/server.dart -o /app/backend/server

FROM node:22-bookworm-slim AS whatsapp
WORKDIR /app/whatsapp_bridge
COPY whatsapp_bridge/package.json whatsapp_bridge/package-lock.json ./
RUN npm ci --omit=dev
COPY whatsapp_bridge/index.js ./index.js

FROM node:22-bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl libsqlite3-dev \
    && ln -sf /usr/lib/x86_64-linux-gnu/libsqlite3.so.0 /usr/local/lib/libsqlite3.so \
    && ldconfig \
    && test -e /usr/local/lib/libsqlite3.so \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app/backend
COPY --from=build /app/backend/server ./server
COPY --from=whatsapp /app/whatsapp_bridge /app/whatsapp_bridge
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh && mkdir -p /data/whatsapp_auth

ENV HOST=0.0.0.0
ENV PORT=8080
ENV DATABASE_PATH=/data/ao_ponto.db
ENV BACKUP_PATH=/data/backups
ENV BACKEND_URL=http://127.0.0.1:8080
ENV WHATSAPP_AUTH_PATH=/data/whatsapp_auth
ENV BRIDGE_CONTACTS_PATH=/data/bridge_contacts.json

EXPOSE 8080
VOLUME ["/data"]
CMD ["/app/start.sh"]
'@
    [IO.File]::WriteAllText(
        (Join-Path $temporario 'Dockerfile'),
        $dockerfile,
        (New-Object System.Text.UTF8Encoding($false))
    )

    Write-Host ''
    Write-Host '3/4 Enviando para o GitHub...' -ForegroundColor Cyan
    git -C $temporario add --all
    $alteracoes = git -C $temporario status --porcelain
    if ([string]::IsNullOrWhiteSpace(($alteracoes -join ''))) {
        Write-Host 'O backend publicado já está atualizado.' -ForegroundColor Green
        exit 0
    }

    git -C $temporario config user.name 'Ao Ponto Publicador'
    git -C $temporario config user.email 'deploy@ao-ponto.local'
    git -C $temporario commit --quiet -m "Atualizar backend $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    if ($LASTEXITCODE -ne 0) {
        throw 'Não foi possível preparar a atualização no Git.'
    }
    git -C $temporario push origin main
    if ($LASTEXITCODE -ne 0) {
        throw 'O GitHub recusou a atualização. Tente executar o script novamente.'
    }

    Write-Host ''
    Write-Host '4/4 Backend enviado com sucesso!' -ForegroundColor Green
    Write-Host 'O Deplexo iniciou a implantação automática.'
    Write-Host 'Aguarde aparecer READY/RUNNING no Deplexo antes de atualizar o aplicativo.'
} catch {
    Write-Host ''
    Write-Host 'A publicação não foi concluída:' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
} finally {
    if (Test-Path -LiteralPath $temporario) {
        $raizTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $temporarioCompleto = [IO.Path]::GetFullPath($temporario)
        if ($temporarioCompleto.StartsWith($raizTemp, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $temporarioCompleto -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
