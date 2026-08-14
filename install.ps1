# memory — установщик базовой среды Claude Code для Windows (PowerShell 5.1+).
# Аналог install.sh для мака. Запуск одной командой (PowerShell от администратора):
#
#   irm https://raw.githubusercontent.com/Gboy213/memory/main/install.ps1 | iex
#
# Что делает:
#   1. Ставит базу через winget: Git, Node.js LTS, GitHub CLI, Chrome (что уже есть — пропускает)
#   2. Ставит Claude Code (официальный установщик claude.ai)
#   3. Логинит в GitHub (gh auth login — вход через браузер)
#   4. По желанию: клонирует рабочий репо в C:\Claude\<имя> и, если в нём есть
#      scripts\station-setup.ps1 — запускает его (донастройка машины из самого репо)
#
# Секретов в скрипте нет. Доступ к приватным репо даёт только твой GitHub-аккаунт.
# Файл в UTF-8 с BOM: без BOM PS 5.1 читает кириллицу как ANSI.

$ErrorActionPreference = 'Continue'

function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path','User')
}

function Ensure-App($cmd, $wingetId, $title) {
  if (Get-Command $cmd -ErrorAction SilentlyContinue) {
    Write-Host "  ~ $title уже стоит" -ForegroundColor Yellow
    return
  }
  Write-Host "  ставлю $title..."
  winget install --id $wingetId -e --accept-package-agreements --accept-source-agreements | Out-Null
  Refresh-Path
  if (Get-Command $cmd -ErrorAction SilentlyContinue) { Write-Host "  + $title" -ForegroundColor Green }
  else { Write-Host "  ! $title не встал — поставь вручную (winget install $wingetId) и перезапусти" -ForegroundColor Red }
}

Write-Host ""
Write-Host "=== memory — установка среды Claude Code (Windows) ===" -ForegroundColor Cyan
Write-Host ""

# --- 0. winget ---
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  Write-Host "Нет winget. Обнови «App Installer» из Microsoft Store и запусти команду снова." -ForegroundColor Red
  return
}

# --- 1. база ---
Ensure-App git    'Git.Git'           'Git'
Ensure-App node   'OpenJS.NodeJS.LTS' 'Node.js LTS'
Ensure-App gh     'GitHub.cli'        'GitHub CLI'
if (-not (Test-Path "$env:ProgramFiles\Google\Chrome\Application\chrome.exe") -and
    -not (Test-Path "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe")) {
  Write-Host "  ставлю Chrome..."
  winget install --id Google.Chrome -e --accept-package-agreements --accept-source-agreements | Out-Null
} else { Write-Host "  ~ Chrome уже стоит" -ForegroundColor Yellow }

# --- 2. Claude Code ---
$claudeExe = "$env:USERPROFILE\.local\bin\claude.exe"
if (Test-Path $claudeExe) {
  Write-Host "  ~ Claude Code уже стоит" -ForegroundColor Yellow
} else {
  Write-Host "  ставлю Claude Code..."
  irm https://claude.ai/install.ps1 | iex
  Refresh-Path
  if (Test-Path $claudeExe) { Write-Host "  + Claude Code" -ForegroundColor Green }
  else { Write-Host "  ! Claude Code не встал — см. https://docs.claude.com/claude-code" -ForegroundColor Red }
}

# --- 3. GitHub-логин ---
& gh auth status 2>$null
if ($LASTEXITCODE -ne 0) {
  Write-Host ""
  Write-Host "Вход в GitHub (откроется браузер):" -ForegroundColor Cyan
  gh auth login --hostname github.com --git-protocol https --web
} else {
  Write-Host "  ~ GitHub уже залогинен" -ForegroundColor Yellow
}

# --- 4. рабочий репо (опционально) ---
Write-Host ""
$slug = Read-Host "Клонировать рабочий репо? Введи owner/repo (Enter — пропустить)"
if ($slug) {
  $name = ($slug -split '/')[-1]
  $dest = "C:\Claude\$name"
  if (Test-Path "$dest\.git") {
    Write-Host "  ~ $dest уже склонирован" -ForegroundColor Yellow
  } else {
    New-Item -ItemType Directory -Force -Path 'C:\Claude' | Out-Null
    gh repo clone $slug $dest
  }
  $setup = "$dest\scripts\station-setup.ps1"
  if (Test-Path $setup) {
    $go = Read-Host "В репо есть scripts\station-setup.ps1 — запустить донастройку? (y/N)"
    if ($go -match '^[yYдД]') { & powershell -NoProfile -ExecutionPolicy Bypass -File $setup }
  } else {
    Write-Host "  готово: cd $dest ; claude" -ForegroundColor Green
  }
}

Write-Host ""
Write-Host "База стоит. Осталось руками: запустить claude и залогиниться (браузер откроется сам)." -ForegroundColor Green
Write-Host ""
