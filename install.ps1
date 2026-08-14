# memory — установщик среды Claude Code для Windows (PowerShell 5.1+). v2.
# Запуск одной командой (PowerShell от администратора):
#
#   irm https://raw.githubusercontent.com/Gboy213/memory/main/install.ps1 | iex
#
# Что делает (идемпотентно — уже сделанное пропускает):
#   1. Разрешает запуск скриптов (ExecutionPolicy RemoteSigned для пользователя)
#   2. Ставит базу через winget: Git, Node.js LTS, GitHub CLI, Chrome, jq
#   3. Ставит Claude Code: нативный установщик claude.ai; если тот недоступен
#      (регион-блок отдаёт заглушку вместо скрипта) — fallback на npm
#   4. Раскладывает глобальный слой ~/.claude из этого пэка: CLAUDE.md (правила),
#      settings.json (Windows-вариант), статуслайн, хуки, скиллы — не затирая твоё
#   5. Логинит в GitHub (gh auth login — вход через браузер)
#   6. По желанию клонирует рабочий репо в C:\213\<имя>; если в нём есть
#      scripts\station-setup.ps1 — предлагает запустить (донастройка машины)
#
# Секретов в скрипте нет. Доступ к приватным репо даёт только твой GitHub-аккаунт.
# Файл в UTF-8 БЕЗ BOM: точка входа — irm | iex, а BOM ломает iex (проверено);
# irm сам декодирует UTF-8 по charset.

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

function Copy-IfMissing($src, $dst, $label) {
  if (Test-Path $dst) { Write-Host "  ~ $label (уже было, не трогаю)" -ForegroundColor Yellow }
  elseif (Test-Path $src) {
    Copy-Item $src $dst -Recurse
    Write-Host "  + $label" -ForegroundColor Green
  }
}

Write-Host ""
Write-Host "=== memory — установка среды Claude Code (Windows) ===" -ForegroundColor Cyan
Write-Host ""

# --- 1. разрешить запуск скриптов (npm-шимы claude.ps1 иначе блокируются) ---
$pol = Get-ExecutionPolicy -Scope CurrentUser
if ($pol -notin @('RemoteSigned','Unrestricted','Bypass')) {
  Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
  Write-Host "  + ExecutionPolicy: RemoteSigned (для пользователя)" -ForegroundColor Green
} else { Write-Host "  ~ ExecutionPolicy уже ок ($pol)" -ForegroundColor Yellow }

# --- 2. база ---
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  Write-Host "Нет winget. Обнови «App Installer» из Microsoft Store и запусти команду снова." -ForegroundColor Red
  return
}
Ensure-App git    'Git.Git'           'Git'
Ensure-App node   'OpenJS.NodeJS.LTS' 'Node.js LTS'
Ensure-App gh     'GitHub.cli'        'GitHub CLI'
Ensure-App jq     'jqlang.jq'         'jq (нужен статуслайну)'
if (-not (Test-Path "$env:ProgramFiles\Google\Chrome\Application\chrome.exe") -and
    -not (Test-Path "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe")) {
  Write-Host "  ставлю Chrome..."
  winget install --id Google.Chrome -e --accept-package-agreements --accept-source-agreements | Out-Null
} else { Write-Host "  ~ Chrome уже стоит" -ForegroundColor Yellow }

# --- 3. Claude Code: нативный установщик → npm fallback ---
$claudeExe = "$env:USERPROFILE\.local\bin\claude.exe"
if ((Test-Path $claudeExe) -or (Get-Command claude -ErrorAction SilentlyContinue)) {
  Write-Host "  ~ Claude Code уже стоит" -ForegroundColor Yellow
} else {
  Write-Host "  пробую нативный установщик claude.ai..."
  $tmpPs = "$env:TEMP\claude-native-install.ps1"
  Remove-Item $tmpPs -Force -ErrorAction SilentlyContinue
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri 'https://claude.ai/install.ps1' -UseBasicParsing -OutFile $tmpPs -ErrorAction Stop
  } catch {}
  $head = ''
  if (Test-Path $tmpPs) { $head = (Get-Content $tmpPs -TotalCount 1) }
  if ("$head" -match '^\s*param') {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $tmpPs
    Refresh-Path
  } else {
    Write-Host "  ! claude.ai отдаёт не скрипт (регион-блок?) — пропускаю нативный путь" -ForegroundColor Yellow
  }
  if (-not (Test-Path $claudeExe) -and -not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host "  ставлю Claude Code через npm..."
    npm install -g '@anthropic-ai/claude-code'
    Refresh-Path
  }
  if ((Test-Path $claudeExe) -or (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host "  + Claude Code" -ForegroundColor Green
  } else {
    Write-Host "  ! Claude Code не встал ни нативно, ни через npm — дальше без него, но разберись" -ForegroundColor Red
  }
}

# --- 4. глобальный слой ~/.claude из пэка ---
Write-Host ""
Write-Host "Раскладываю глобальный слой ~\.claude (правила, статуслайн, хуки, скиллы):" -ForegroundColor Cyan
$pack = "$env:TEMP\memory-pack"
Remove-Item $pack -Recurse -Force -ErrorAction SilentlyContinue
git clone --depth 1 https://github.com/Gboy213/memory $pack 2>$null | Out-Null
if (-not (Test-Path "$pack\claude-home")) {
  Write-Host "  ! не смог склонировать пэк — глобальный слой пропущен" -ForegroundColor Red
} else {
  $g = "$env:USERPROFILE\.claude"
  New-Item -ItemType Directory -Force -Path $g, "$g\hooks", "$g\skills" | Out-Null
  Copy-IfMissing "$pack\templates\global-CLAUDE.md"        "$g\CLAUDE.md"             'CLAUDE.md (глобальные правила)'
  Copy-IfMissing "$pack\claude-home\settings.windows.json" "$g\settings.json"         'settings.json (права, хуки, статуслайн — Windows-вариант)'
  Copy-IfMissing "$pack\claude-home\statusline-command.sh" "$g\statusline-command.sh" 'статуслайн'
  Get-ChildItem "$pack\claude-home\hooks\*.sh" | ForEach-Object {
    Copy-IfMissing $_.FullName "$g\hooks\$($_.Name)" "hook $($_.Name)"
  }
  Get-ChildItem "$pack\skills" -Directory | ForEach-Object {
    Copy-IfMissing $_.FullName "$g\skills\$($_.Name)" "skill /$($_.Name)"
  }
}

# --- 5. GitHub-логин ---
& gh auth status 2>$null
if ($LASTEXITCODE -ne 0) {
  Write-Host ""
  Write-Host "Вход в GitHub (откроется браузер):" -ForegroundColor Cyan
  gh auth login --hostname github.com --git-protocol https --web
} else {
  Write-Host "  ~ GitHub уже залогинен" -ForegroundColor Yellow
}

# --- 6. рабочий репо (опционально) ---
Write-Host ""
$slug = Read-Host "Клонировать рабочий репо? Введи owner/repo (Enter — пропустить)"
if ($slug) {
  $name = ($slug -split '/')[-1]
  $dest = "C:\213\$name"
  if (Test-Path "$dest\.git") {
    Write-Host "  ~ $dest уже склонирован" -ForegroundColor Yellow
  } else {
    New-Item -ItemType Directory -Force -Path 'C:\213' | Out-Null
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
Write-Host "Готово. Осталось руками: открыть НОВОЕ окно PowerShell, запустить claude и залогиниться." -ForegroundColor Green
Write-Host ""
