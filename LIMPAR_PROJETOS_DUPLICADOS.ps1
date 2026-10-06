$ErrorActionPreference = 'Stop'

$targets = @(
    'C:\Users\Usuario\Desktop\ao_ponto_bot_revisado\.runtime',
    'C:\Users\Usuario\Desktop\ao_ponto_bot_revisado\app\build',
    'C:\Users\Usuario\Desktop\ao_ponto_bot_revisado\app\.dart_tool',
    'C:\Users\Usuario\Desktop\ao_ponto_bot_revisado\app\.flutter-plugins-dependencies',
    'C:\Users\Usuario\Desktop\ao_ponto_bot_revisado\backend\.dart_tool',
    'C:\Users\Usuario\Desktop\ao_ponto_bot_revisado\whatsapp_bridge\node_modules',
    'C:\Users\Usuario\Documents\Codex\2026-09-12\quero-criar-um-micro-saas-de\outputs\cardapio-saas-para-zip',
    'C:\Users\Usuario\Documents\Codex\2026-07-30\meu\work\pub_cache',
    'C:\Users\Usuario\Documents\Codex\2026-07-30\meu\work\gradle_probe',
    'C:\Users\Usuario\Documents\Codex\2026-09-12\quero-criar-um-micro-saas-de\outputs\cardapio-saas\backend\node_modules',
    'C:\Users\Usuario\Documents\Codex\2026-09-12\quero-criar-um-micro-saas-de\outputs\cardapio-saas\panel\build',
    'C:\Users\Usuario\Documents\Codex\2026-09-12\quero-criar-um-micro-saas-de\outputs\cardapio-saas\public-menu\node_modules',
    'C:\Users\Usuario\Documents\Codex\2026-09-12\quero-criar-um-micro-saas-de\outputs\cardapio-saas\panel\.dart_tool',
    'C:\Users\Usuario\Documents\Codex\2026-09-12\quero-criar-um-micro-saas-de\outputs\cardapio-saas\backend\dist',
    'C:\Users\Usuario\Documents\Codex\2026-09-12\quero-criar-um-micro-saas-de\outputs\cardapio-saas\public-menu\dist',
    'C:\Users\Usuario\Documents\Codex\2026-07-30\meu\work\pizza-brava-worker-deploy\node_modules',
    'C:\Users\Usuario\Documents\Novo Estudo\sistema_estudo\build',
    'C:\Users\Usuario\Documents\Novo Estudo\sistema_estudo\.dart_tool',
    'C:\Users\Usuario\Documents\Novo Estudo\sistema_estudo\android\.gradle'
)

$allowedRoots = @(
    'C:\Users\Usuario\Desktop\ao_ponto_bot_revisado\',
    'C:\Users\Usuario\Documents\Codex\',
    'C:\Users\Usuario\Documents\Novo Estudo\'
)
$bytes = 0L
$removed = 0

Write-Host 'Preservando os projetos mais recentes e removendo apenas duplicatas e arquivos recriáveis.' -ForegroundColor Cyan
Write-Host ''
foreach ($target in $targets) {
    $full = [IO.Path]::GetFullPath($target)
    $allowed = $false
    foreach ($root in $allowedRoots) {
        if ($full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
            $allowed = $true
            break
        }
    }
    if (-not $allowed) { throw "Destino fora do escopo seguro: $full" }
    if (-not (Test-Path -LiteralPath $full)) { continue }
    $item = Get-Item -LiteralPath $full -Force
    $size = if ($item.PSIsContainer) {
        (Get-ChildItem -LiteralPath $full -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    } else { $item.Length }
    if ($null -eq $size) { $size = 0 }
    Remove-Item -LiteralPath $full -Recurse -Force
    $bytes += [long]$size
    $removed++
    Write-Host "Removido: $full" -ForegroundColor DarkGray
}
Write-Host ''
Write-Host "Limpeza concluída: $removed itens removidos." -ForegroundColor Green
Write-Host ("Espaço liberado: {0:N2} GB" -f ($bytes / 1GB)) -ForegroundColor Green
Write-Host 'Foram removidas somente duplicatas confirmadas e arquivos gerados que podem ser recriados.'
