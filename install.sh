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
#   1. Клонит репо в /tmp/memory-install
#   2. Создаёт ~/.claude/CLAUDE.md (если нет)
#   3. Создаёт <cwd>/CLAUDE.md (если нет)
#   4. Копирует rules/*.md в <cwd>/rules/ (не затирая существующие)
#   5. Создаёт <cwd>/MEMORY.md и <cwd>/memory/README.md (если нет)
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

# --- 6. cleanup ---
rm -rf "${TMP}"

# --- финал ---
echo ""
echo "✅ Установлено."
echo ""
echo "Что дальше:"
echo "  1. Открой ${TARGET}/CLAUDE.md → заполни карту проекта (папки, кодовые слова)"
echo "  2. Открой ${GLOBAL_DIR}/CLAUDE.md → поправь язык/тон под себя"
echo "  3. По мере работы — обновляй current-focus.md, складывай заметки в memory/"
echo "  4. Философия слоёв — ${REPO_URL}/blob/main/ARCHITECTURE.md"
echo ""
