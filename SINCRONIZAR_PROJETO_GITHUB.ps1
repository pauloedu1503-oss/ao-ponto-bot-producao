$ErrorActionPreference = 'Stop'

$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path
$repositorio = 'pauloedu1503-oss/ao-ponto-bot-producao'

function Chamar-GhJson([string]$Rota, [string]$Metodo, $Corpo) {
    $json = $Corpo | ConvertTo-Json -Depth 20 -Compress
    $resposta = $json | gh api $Rota --method $Metodo --input -
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao acessar o GitHub em $Rota."
    }
    return $resposta | ConvertFrom-Json
}

try {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw 'GitHub CLI não encontrado. Instale e execute: gh auth login'
    }
    gh auth status 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'Entre no GitHub executando uma vez: gh auth login'
    }

    Push-Location $raiz
    try {
        $arquivos = @(
            git ls-files --cached --others --exclude-standard |
                Where-Object {
                    $_ -notmatch '^app/build/' -and
                    $_ -notmatch '^app/\.dart_tool/' -and
                    $_ -notmatch '^backend/\.dart_tool/' -and
                    $_ -notmatch '^\.runtime/' -and
                    $_ -notmatch '^logs/' -and
                    $_ -notmatch '(^|/)\.env$' -and
                    $_ -notmatch 'firebase-service-account\.json$' -and
                    $_ -notmatch '(^|/)auth_info/' -and
                    $_ -notmatch '\.(db|sqlite|sqlite3)$' -and
                    $_ -notmatch '^whatsapp_bridge/node_modules/'
                }
        )
        if ($LASTEXITCODE -ne 0 -or $arquivos.Count -eq 0) {
            throw 'Não foi possível localizar os arquivos do projeto.'
        }

        $referencia = gh api "repos/$repositorio/git/ref/heads/main" | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw 'Não foi possível ler a branch main.' }
        $cabeca = $referencia.object.sha
        $commitAtual = gh api "repos/$repositorio/git/commits/$cabeca" | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw 'Não foi possível ler o commit atual.' }
        $arvoreBase = $commitAtual.tree.sha
        $arvoreRemota = gh api "repos/$repositorio/git/trees/$arvoreBase`?recursive=1" | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw 'Não foi possível ler os arquivos remotos.' }

        $shasRemotos = @{}
        foreach ($item in $arvoreRemota.tree | Where-Object { $_.type -eq 'blob' }) {
            $shasRemotos[$item.path] = $item.sha
        }

        $entradas = @()
        $contador = 0
        foreach ($caminho in $arquivos) {
            $absoluto = Join-Path $raiz $caminho
            if (-not (Test-Path -LiteralPath $absoluto -PathType Leaf)) { continue }
            $shaLocal = (git hash-object -- $caminho).Trim()
            if ($LASTEXITCODE -ne 0) { throw "Falha ao verificar $caminho." }
            if ($shasRemotos[$caminho] -eq $shaLocal) { continue }

            $blob = Chamar-GhJson "repos/$repositorio/git/blobs" 'POST' @{
                content  = [Convert]::ToBase64String([IO.File]::ReadAllBytes($absoluto))
                encoding = 'base64'
            }
            $entradas += @{
                path = $caminho.Replace('\', '/')
                mode = '100644'
                type = 'blob'
                sha  = $blob.sha
            }
            $contador++
            Write-Host "Preparado: $contador arquivo(s)" -ForegroundColor DarkGray
        }

        if ($entradas.Count -eq 0) {
            Write-Host 'O projeto do GitHub já está sincronizado.' -ForegroundColor Green
            exit 0
        }

        $novaArvore = Chamar-GhJson "repos/$repositorio/git/trees" 'POST' @{
            base_tree = $arvoreBase
            tree      = $entradas
        }
        $novoCommit = Chamar-GhJson "repos/$repositorio/git/commits" 'POST' @{
            message = "Sincronizar projeto $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
            tree    = $novaArvore.sha
            parents = @($cabeca)
        }

        # Atualização normal, sem force. Se outra alteração entrar enquanto o
        # script roda, o GitHub recusará em vez de apagar trabalho remoto.
        Chamar-GhJson "repos/$repositorio/git/refs/heads/main" 'PATCH' @{
            sha   = $novoCommit.sha
            force = $false
        } | Out-Null

        Write-Host ''
        Write-Host 'Projeto sincronizado com o GitHub com sucesso.' -ForegroundColor Green
        Write-Host "Commit remoto: $($novoCommit.sha.Substring(0, 7))"
    } finally {
        Pop-Location
    }
} catch {
    Write-Host ''
    Write-Host 'A sincronização não foi concluída:' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
