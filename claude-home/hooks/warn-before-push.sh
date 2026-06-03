#!/bin/bash
# PreToolUse hook: предупреждение перед git push
# Показывает напоминание проверить изменения перед отправкой

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Только для Bash
[ "$TOOL_NAME" != "Bash" ] && exit 0

# Только для git push (но не --force, он уже в deny)
echo "$COMMAND" | grep -q 'git push' || exit 0

cat <<EOF
{
  "systemMessage": "Перед push: убедись что все изменения проверены, тесты пройдены, .md документация обновлена. Если есть незакоммиченные файлы — сначала разберись с ними.",
  "continue": true
}
EOF

exit 0
