#!/bin/bash
# PostToolUse hook: syntax-check после Edit/Write
# Тихо если OK, алерт через systemMessage если ошибка
# Поддержка: .py .json .sh/.bash .js

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Только Edit и Write
case "$TOOL_NAME" in
  Edit|Write) ;;
  *) exit 0 ;;
esac

[ -z "$FILE_PATH" ] && exit 0
[ ! -f "$FILE_PATH" ] && exit 0

ERROR=""
case "$FILE_PATH" in
  *.py)
    OUT=$(python3 -c "import ast, sys; ast.parse(open(sys.argv[1]).read())" "$FILE_PATH" 2>&1)
    [ $? -ne 0 ] && ERROR="Python: $OUT"
    ;;
  *.json)
    OUT=$(python3 -c "import json, sys; json.load(open(sys.argv[1]))" "$FILE_PATH" 2>&1)
    [ $? -ne 0 ] && ERROR="JSON: $OUT"
    ;;
  *.sh|*.bash)
    OUT=$(bash -n "$FILE_PATH" 2>&1)
    [ $? -ne 0 ] && ERROR="Bash: $OUT"
    ;;
  *.js)
    if command -v node >/dev/null 2>&1; then
      OUT=$(node --check "$FILE_PATH" 2>&1)
      [ $? -ne 0 ] && ERROR="JavaScript: $OUT"
    fi
    ;;
esac

if [ -n "$ERROR" ]; then
  ERROR_TRUNC="${ERROR:0:500}"
  jq -n --arg msg "⚠️ Синтаксис в $FILE_PATH: $ERROR_TRUNC" \
    '{systemMessage: $msg, continue: true}'
fi

exit 0
