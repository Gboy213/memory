#!/usr/bin/env bash
# memory — установщик для bash.
# Альтернатива «дай команду Claude'у установить отсюда» — для тех, кто хочет одну CLI-команду.
#
# Использование:
#   curl -fsSL https://raw.githubusercontent.com/Gboy213/memory/main/install.sh | bash
#
# Или локально:
#   bash install.sh
#
# Что делает:
#   ПРОЕКТ (<cwd>):
#     1. Создаёт <cwd>/CLAUDE.md (если нет)
#     2. Копирует rules/*.md в <cwd>/rules/ (не затирая существующие)
#     3. Создаёт <cwd>/MEMORY.md и <cwd>/memory/README.md (если нет)
#   ГЛОБАЛЬНЫЙ ХАРНЕС (~/.claude/):
#     4. Создаёт ~/.claude/CLAUDE.md (если нет)
#     5. Создаёт ~/.claude/settings.json — права, статуслайн, хуки, ultrathink (если нет)
#     6. Копирует statusline-command.sh + hooks/ (если нет)
#     7. Копирует skills/ — close, handoff, write, diplomat, council, memory-audit, refine, night (по одному, не затирая)
#        + ссылка ~/.agents/skills/<name> → общая папка скиллов Codex/Kimi/Qwen (refine зовут все четыре CLI)
#     8. Создаёт ~/.claude/.mcp.json — playwright + google-sheets/docs → <cwd> (если нет)
#   SHELL:
#     9. Добавляет alias <имя-репо>='cd <cwd> && claude' в ~/.zshrc или ~/.bashrc
#
# Защита от перезаписи: если файл уже есть — пропускаем, выводим warning. Ничего не теряется.

set -euo pipefail

REPO_URL="${CSP_REPO_URL:-https://github.com/Gboy213/memory}"
TMP="/tmp/memory-install"
TARGET="${PWD}"
GLOBAL_DIR="${HOME}/.claude"

# --- утилиты вывода ---
log()  { printf "  %s\n" "$*"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$*"; }
skip() { printf "  \033[33m~\033[0m %s (уже было, не трогаем)\n" "$*"; }
err()  { printf "  \033[31m✗\033[0m %s\n" "$*" >&2; }

# --- prerequisites ---
command -v git >/dev/null 2>&1 || { err "нужен git. Установи его и повтори."; exit 1; }

if [ ! -d "${TARGET}/.git" ]; then
    err "Текущая папка не git-репозиторий: ${TARGET}"
    err "Запусти 'git init' или перейди в нужный репо и повтори."
    exit 1
fi

# --- 1. clone ---
echo ""
echo "📦 memory — claude-code starter pack installer"
echo ""
log "Клонирую ${REPO_URL} → ${TMP}"
rm -rf "${TMP}"
git clone --depth 1 "${REPO_URL}" "${TMP}" >/dev/null 2>&1 || {
    err "git clone упал. Проверь сеть и URL."; exit 1;
}
ok "пэк склонирован"

# --- 2. global CLAUDE.md ---
echo ""
log "Глобальный конфиг ~/.claude/CLAUDE.md"
mkdir -p "${GLOBAL_DIR}"
if [ ! -f "${GLOBAL_DIR}/CLAUDE.md" ]; then
    cp "${TMP}/templates/global-CLAUDE.md" "${GLOBAL_DIR}/CLAUDE.md"
    ok "создан ${GLOBAL_DIR}/CLAUDE.md"
else
    skip "${GLOBAL_DIR}/CLAUDE.md"
fi

# --- 3. project CLAUDE.md ---
echo ""
log "Проектный CLAUDE.md в ${TARGET}"
if [ ! -f "${TARGET}/CLAUDE.md" ]; then
    cp "${TMP}/templates/project-CLAUDE.md" "${TARGET}/CLAUDE.md"
    ok "создан ${TARGET}/CLAUDE.md"
else
    skip "${TARGET}/CLAUDE.md"
fi

# --- 4. rules/ ---
echo ""
log "Правила ${TARGET}/rules/"
mkdir -p "${TARGET}/rules"
created=0
skipped=0
for src in "${TMP}/rules/"*.md; do
    name=$(basename "${src}")
    dst="${TARGET}/rules/${name}"
    if [ ! -f "${dst}" ]; then
        cp "${src}" "${dst}"
        created=$((created + 1))
    else
        skipped=$((skipped + 1))
    fi
done
ok "правила: создано ${created}, пропущено ${skipped} (уже было)"

# --- 5. memory ---
echo ""
log "Память ${TARGET}/MEMORY.md и ${TARGET}/memory/"
mkdir -p "${TARGET}/memory"
if [ ! -f "${TARGET}/MEMORY.md" ]; then
    cp "${TMP}/templates/MEMORY.md" "${TARGET}/MEMORY.md"
    ok "создан ${TARGET}/MEMORY.md"
else
    skip "${TARGET}/MEMORY.md"
fi
if [ ! -f "${TARGET}/memory/README.md" ]; then
    cp "${TMP}/memory/README.md" "${TARGET}/memory/README.md"
    ok "создан ${TARGET}/memory/README.md"
else
    skip "${TARGET}/memory/README.md"
fi

# --- 6. global settings.json (права + статуслайн + хуки + ultrathink) ---
echo ""
log "Среда Claude Code ~/.claude/settings.json"
if [ ! -f "${GLOBAL_DIR}/settings.json" ]; then
    cp "${TMP}/claude-home/settings.json" "${GLOBAL_DIR}/settings.json"
    ok "создан ${GLOBAL_DIR}/settings.json (allow/deny, statusLine, ultrathink-хук)"
else
    skip "${GLOBAL_DIR}/settings.json — слей вручную, образец: ${REPO_URL}/blob/main/claude-home/settings.json"
fi

# --- 7. statusline-command.sh ---
echo ""
log "Статуслайн (нижняя панель)"
if [ ! -f "${GLOBAL_DIR}/statusline-command.sh" ]; then
    cp "${TMP}/claude-home/statusline-command.sh" "${GLOBAL_DIR}/statusline-command.sh"
    chmod +x "${GLOBAL_DIR}/statusline-command.sh"
    ok "создан ${GLOBAL_DIR}/statusline-command.sh"
else
    skip "${GLOBAL_DIR}/statusline-command.sh"
fi
# statusline.js — основной вариант (settings.json → node ~/.claude/statusline.js):
# модель · папка · ctx% · лимиты 5ч/7д с таймером сброса · цена сессии. bash-версия — запасная.
if [ ! -f "${GLOBAL_DIR}/statusline.js" ]; then
    cp "${TMP}/claude-home/statusline.js" "${GLOBAL_DIR}/statusline.js"
    ok "создан ${GLOBAL_DIR}/statusline.js"
else
    skip "${GLOBAL_DIR}/statusline.js"
fi

# --- 8. hooks ---
echo ""
log "Хуки ${GLOBAL_DIR}/hooks/"
mkdir -p "${GLOBAL_DIR}/hooks"
hcreated=0
hskipped=0
for src in "${TMP}/claude-home/hooks/"*.sh "${TMP}/claude-home/hooks/"*.py; do
    name=$(basename "${src}")
    dst="${GLOBAL_DIR}/hooks/${name}"
    if [ ! -f "${dst}" ]; then
        cp "${src}" "${dst}"
        chmod +x "${dst}"
        hcreated=$((hcreated + 1))
    else
        hskipped=$((hskipped + 1))
    fi
done
ok "хуки: создано ${hcreated}, пропущено ${hskipped} (уже было)"
[ -f "${GLOBAL_DIR}/canary-name" ] || log "    канарейка контекста: положи своё имя в ${GLOBAL_DIR}/canary-name (echo \"Имя\" > ~/.claude/canary-name) — без него Stop-hook молчит"

# --- 9. skills (close / handoff / write / refine / night) ---
echo ""
log "Скиллы ${GLOBAL_DIR}/skills/"
mkdir -p "${GLOBAL_DIR}/skills"
screated=0
sskipped=0
for sdir in "${TMP}/skills/"*/; do
    sname=$(basename "${sdir}")
    dst="${GLOBAL_DIR}/skills/${sname}"
    if [ ! -d "${dst}" ]; then
        cp -r "${sdir}" "${dst}"
        screated=$((screated + 1))
    else
        sskipped=$((sskipped + 1))
    fi
    # ~/.agents/skills/ читают Claude Code, Codex, Kimi и Qwen — один скилл на все CLI
    mkdir -p "${HOME}/.agents/skills"
    [ -e "${HOME}/.agents/skills/${sname}" ] || ln -s "${dst}" "${HOME}/.agents/skills/${sname}"
done
ok "скиллы: создано ${screated}, пропущено ${sskipped} (уже было); ссылки в ~/.agents/skills/"

# --- 9b. Codex / Qwen / Kimi — глобальный слой других CLI (только если CLI уже стоит) ---
echo ""
log "Другие CLI (Codex / Qwen / Kimi)"
if command -v codex >/dev/null 2>&1; then
    mkdir -p "${HOME}/.codex/hooks"
    [ -f "${HOME}/.codex/AGENTS.md" ] && skip "~/.codex/AGENTS.md" || { cp "${TMP}/codex-home/AGENTS.md" "${HOME}/.codex/AGENTS.md"; ok "создан ~/.codex/AGENTS.md (глобальные правила Codex)"; }
    for src in "${TMP}/codex-home/hooks/"*; do
        name=$(basename "${src}")
        [ -f "${HOME}/.codex/hooks/${name}" ] || { cp "${src}" "${HOME}/.codex/hooks/${name}"; chmod +x "${HOME}/.codex/hooks/${name}"; }
    done
    if [ ! -f "${HOME}/.codex/hooks.json" ]; then
        sed "s|__HOME__|${HOME}|g" "${TMP}/codex-home/hooks.json" > "${HOME}/.codex/hooks.json"
        ok "создан ~/.codex/hooks.json (warn-before-push, syntax-check, drift-markers)"
        log "    ВАЖНО: Codex пропускает новые хуки, пока их не доверить: открой codex → /hooks → проверь три определения → trust"
    else
        skip "~/.codex/hooks.json — образец: ${REPO_URL}/blob/main/codex-home/hooks.json"
    fi
else
    skip "codex не установлен — слой ~/.codex пропущен"
fi
if command -v qwen >/dev/null 2>&1; then
    mkdir -p "${HOME}/.qwen"
    [ -f "${HOME}/.qwen/QWEN.md" ] && skip "~/.qwen/QWEN.md" || { cp "${TMP}/qwen-home/QWEN.md" "${HOME}/.qwen/QWEN.md"; ok "создан ~/.qwen/QWEN.md (глобальные правила Qwen)"; }
else
    skip "qwen не установлен — слой ~/.qwen пропущен"
fi
if command -v kimi >/dev/null 2>&1; then
    log "kimi найден: усилие max для refine — слей руками в ~/.kimi-code/config.toml строки из ${REPO_URL}/blob/main/kimi-home/config.snippet.toml"
fi
if command -v codex >/dev/null 2>&1; then
    log "codex: статуслайн (контекст/токены/лимиты) + reasoning xhigh — слей руками в ~/.codex/config.toml (не перезаписывать) строки из ${REPO_URL}/blob/main/codex-home/config.snippet.toml"
fi

# --- 10. MCP-серверы (~/.claude/.mcp.json) ---
echo ""
log "MCP-серверы ~/.claude/.mcp.json"
if [ ! -f "${GLOBAL_DIR}/.mcp.json" ]; then
    sed "s|__REPO__|${TARGET}|g" "${TMP}/claude-home/.mcp.json.template" > "${GLOBAL_DIR}/.mcp.json"
    ok "создан ${GLOBAL_DIR}/.mcp.json (playwright + google-sheets/docs → ${TARGET}/integrations/...)"
    if [ ! -f "${TARGET}/integrations/google-sheets/app/server.py" ]; then
        log "    note: google-sheets/docs указывают на ${TARGET}/integrations/... — этих серверов в репо нет."
        log "          поставь их venv + credentials.json или убери эти записи. playwright работает сразу."
    fi
else
    skip "${GLOBAL_DIR}/.mcp.json — образец: ${REPO_URL}/blob/main/claude-home/.mcp.json.template"
fi

# --- 11. shell alias ---
echo ""
log "Shell-алиас для быстрого запуска"
ALIAS_NAME=$(basename "${TARGET}")
ALIAS_LINE="alias ${ALIAS_NAME}='cd ${TARGET} && claude'"
RC=""
case "${SHELL:-}" in
    *zsh)  RC="${HOME}/.zshrc" ;;
    *bash) RC="${HOME}/.bashrc" ;;
    *)
        if [ -f "${HOME}/.zshrc" ]; then RC="${HOME}/.zshrc"
        elif [ -f "${HOME}/.bashrc" ]; then RC="${HOME}/.bashrc"
        fi
        ;;
esac
if [ -z "${RC}" ]; then
    skip "не нашёл ~/.zshrc или ~/.bashrc — добавь вручную: ${ALIAS_LINE}"
elif grep -q "^alias ${ALIAS_NAME}=" "${RC}" 2>/dev/null; then
    skip "алиас '${ALIAS_NAME}' уже есть в ${RC}"
else
    printf "\n# claude-code: быстрый запуск проекта\n%s\n" "${ALIAS_LINE}" >> "${RC}"
    ok "добавлен '${ALIAS_NAME}' в ${RC} → перезапусти терминал или 'source ${RC}'"
fi

# --- 12. cleanup ---
rm -rf "${TMP}"

# --- финал ---
echo ""
echo "✅ Установлено."
echo ""
echo "Что дальше:"
echo "  1. source ~/.zshrc (или новый терминал) → команда '${ALIAS_NAME}' запустит Claude в этом проекте"
echo "  2. Открой ${TARGET}/CLAUDE.md → заполни карту проекта (папки, кодовые слова)"
echo "  3. Открой ${GLOBAL_DIR}/CLAUDE.md → поправь язык/тон под себя"
echo "  4. settings.json: если ultrathink-на-каждый-промпт или model opus[1m] не нужны — убери их в ${GLOBAL_DIR}/settings.json"
echo "  5. MCP: playwright готов сразу; google-sheets/docs требуют venv+credentials в ${TARGET}/integrations/ (или убери из ~/.claude/.mcp.json)"
echo "  6. Философия слоёв — ${REPO_URL}/blob/main/ARCHITECTURE.md"
echo ""
