$ErrorActionPreference = 'Stop'

$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path
$pubspec = Join-Path $raiz 'app\pubspec.yaml'
$arquivoVersao = Join-Path $raiz 'backend\lib\app_update.dart'
$flutter = 'C:\src\flutter\bin\flutter.bat'
$apk = Join-Path $raiz 'app\build\app\outputs\flutter-apk\app-release.apk'
$repositorioDownloads = 'pauloedu1503-oss/ao-ponto-bot-downloads'

function Salvar-Utf8SemBom([string]$Caminho, [string]$Conteudo) {
    $utf8SemBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Caminho, $Conteudo, $utf8SemBom)
}

if (-not (Test-Path $flutter)) {
    throw 'Flutter não foi encontrado em C:\src\flutter.'
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Host 'Instale o GitHub CLI uma única vez com:' -ForegroundColor Yellow
    Write-Host 'winget install GitHub.cli'
    Write-Host 'Depois execute: gh auth login'
    Read-Host 'Pressione Enter para fechar'
    exit 1
}

gh auth status 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Faça o login no GitHub uma única vez com: gh auth login' -ForegroundColor Yellow
    Read-Host 'Pressione Enter para fechar'
    exit 1
}

$alteracoes = @(git -C $raiz status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0) { throw 'Não foi possível verificar o estado do projeto.' }
$alteracoesReais = @($alteracoes | Where-Object {
    $_ -notmatch 'app/\.flutter-plugins-dependencies$'
})
if ($alteracoesReais.Count -eq 0) {
    Write-Host ''
    Write-Host 'O projeto não possui alterações para publicar.' -ForegroundColor Green
    Write-Host 'Nenhum APK foi gerado e nenhuma versão nova foi criada.'
    Read-Host 'Pressione Enter para fechar'
    exit 0
}

$conteudoOriginal = Get-Content $pubspec -Raw
$versaoOriginal = Get-Content $arquivoVersao -Raw
$encontrada = [regex]::Match($conteudoOriginal, '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$')
if (-not $encontrada.Success) { throw 'Não foi possível ler a versão do aplicativo.' }

$major = [int]$encontrada.Groups[1].Value
$minor = [int]$encontrada.Groups[2].Value
$patch = [int]$encontrada.Groups[3].Value + 1
$build = [int]$encontrada.Groups[4].Value + 1
$sugestao = "$major.$minor.$patch"
$informada = Read-Host "Versão que será publicada [$sugestao]"
$versao = if ([string]::IsNullOrWhiteSpace($informada)) { $sugestao } else { $informada.Trim() }
if ($versao -notmatch '^\d+\.\d+\.\d+$') { throw 'Use a versão no formato 1.2.3.' }

try {
    $novoPubspec = [regex]::Replace(
        $conteudoOriginal,
        '(?m)^version:\s*.+$',
        "version: $versao+$build"
    )
    Salvar-Utf8SemBom $pubspec $novoPubspec

    $novaVersao = [regex]::Replace($versaoOriginal, "const appVersao = '[^']+';", "const appVersao = '$versao';")
    $novaVersao = [regex]::Replace($novaVersao, 'const appBuild = \d+;', "const appBuild = $build;")
    Salvar-Utf8SemBom $arquivoVersao $novaVersao

    Push-Location (Join-Path $raiz 'app')
    try {
        & $flutter pub get
        if ($LASTEXITCODE -ne 0) { throw 'Falha ao preparar o aplicativo.' }
        & $flutter build apk --release
        if ($LASTEXITCODE -ne 0) { throw 'Falha ao gerar o APK.' }
    } finally {
        Pop-Location
    }

    $tag = "app-v$versao-build$build"
    gh release create $tag "$apk#ao-ponto-bot.apk" --repo $repositorioDownloads --title "Ao Ponto Bot $versao" --notes "Atualização automática do aplicativo." --latest
    if ($LASTEXITCODE -ne 0) { throw 'Falha ao publicar o APK no GitHub.' }

    Push-Location $raiz
    try {
        # Inclui todo o estado atual rastreável do projeto. Senhas, banco,
        # autenticação do WhatsApp e builds continuam protegidos pelo .gitignore.
        git add --all
        git commit -m "Publicar aplicativo $versao"
        if ($LASTEXITCODE -ne 0) { throw 'Falha ao registrar a nova versão.' }
        git push origin main
        if ($LASTEXITCODE -ne 0) { throw 'Falha ao atualizar o servidor.' }
    } finally {
        Pop-Location
    }

    Write-Host ''
    Write-Host "Versão $versao publicada com sucesso." -ForegroundColor Green
    Write-Host 'Os aparelhos receberão o aviso assim que o servidor terminar de atualizar.'
} catch {
    Salvar-Utf8SemBom $pubspec $conteudoOriginal
    Salvar-Utf8SemBom $arquivoVersao $versaoOriginal
    Write-Host ''
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host 'Os números de versão locais foram restaurados.'
    exit 1
} finally {
    Read-Host 'Pressione Enter para fechar'
}
