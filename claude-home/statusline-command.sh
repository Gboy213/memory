#!/bin/bash
input=$(cat)

model=$(echo "$input" | jq -r '.model.display_name // "unknown"')
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
dir=$(basename "$cwd")

used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')

five=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
week=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

# Model + dir
printf "%s  %s" "$model" "$dir"

# Context
if [ -n "$used" ]; then
  printf "  ctx:%s%%" "$(printf '%.0f' "$used")"
fi

# Rate limits
if [ -n "$five" ]; then
  printf "  5h:%s%%" "$(printf '%.0f' "$five")"
fi
if [ -n "$week" ]; then
  printf "  7d:%s%%" "$(printf '%.0f' "$week")"
fi

printf "\n"
