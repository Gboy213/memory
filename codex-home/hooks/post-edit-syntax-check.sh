#!/bin/bash
# PostToolUse hook (Codex): syntax-check после правки файла.
# Канонический инструмент правок Codex — apply_patch (пути берём из текста патча);
# Edit/Write с tool_input.file_path — на случай других версий CLI.
# Тихо если OK, алерт через systemMessage если ошибка. Поддержка: .py .json .sh/.bash .js

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

FILES=""
case "$TOOL_NAME" in
  Edit|Write)
    FILES=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty') ;;
  apply_patch)
    # tool_input.command — текст патча: строки "*** Add File: path" / "*** Update File: path"
    FILES=$(echo "$INPUT" | jq -r '.tool_input.command // .tool_input.patch // empty' \
            | grep -E '^\*\*\* (Add|Update) File: ' | sed -E 's/^\*\*\* (Add|Update) File: //') ;;  # BSD/GNU sed
  *) exit 0 ;;
esac

[ -z "$FILES" ] && exit 0

ERRORS=""
while IFS= read -r FILE_PATH; do
  [ -z "$FILE_PATH" ] && continue
  [ ! -f "$FILE_PATH" ] && continue
  ERROR=""
  case "$FILE_PATH" in
    *.py)
      OUT=$(python3 -c "import ast, sys; ast.parse(open(sys.argv[1]).read())" "$FILE_PATH" 2>&1)
      [ $? -ne 0 ] && ERROR="Python: $OUT" ;;
    *.json)
      OUT=$(python3 -c "import json, sys; json.load(open(sys.argv[1]))" "$FILE_PATH" 2>&1)
      [ $? -ne 0 ] && ERROR="JSON: $OUT" ;;
    *.sh|*.bash)
      OUT=$(bash -n "$FILE_PATH" 2>&1)
      [ $? -ne 0 ] && ERROR="Bash: $OUT" ;;
    *.js)
      if command -v node >/dev/null 2>&1; then
        OUT=$(node --check "$FILE_PATH" 2>&1)
        [ $? -ne 0 ] && ERROR="JavaScript: $OUT"
      fi ;;
  esac
  [ -n "$ERROR" ] && ERRORS="${ERRORS}${FILE_PATH}: ${ERROR:0:300}\n"
done <<< "$FILES"

if [ -n "$ERRORS" ]; then
  jq -n --arg msg "⚠️ Синтаксис после правки: $(printf '%b' "$ERRORS")" \
    '{systemMessage: $msg, continue: true}'
fi

exit 0
