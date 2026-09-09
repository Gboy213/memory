#!/usr/bin/env python3
"""Канарейка контекста (Stop-hook): проверяет, что ответ агента начался с твоего имени.

Имя берётся из ~/.claude/canary-name (одна строка, например «Иван»). Файла нет —
хук молчит. Пропажа имени в начале ответа = маркер деградации контекста /
начала галлюцинаций: предупреждение — JSON systemMessage в stdout, ответ НЕ блокируется.
Правило для агента — в ~/.claude/CLAUDE.md § Канарейка контекста.
"""
import json
import sys
from pathlib import Path


def canary_name():
    p = Path.home() / ".claude" / "canary-name"
    try:
        return p.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def extract_text(data):
    """Текст последнего ответа: сперва из stdin, иначе из транскрипта."""
    for key in ("last_assistant_message", "assistant_message"):
        msg = data.get(key)
        if isinstance(msg, str) and msg.strip():
            return msg
    path = data.get("transcript_path")
    if not path:
        return ""
    try:
        with open(path, encoding="utf-8") as f:
            lines = [l for l in f if l.strip()]
    except OSError:
        return ""
    for line in reversed(lines):
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        m = rec.get("message", rec)
        if m.get("role") != "assistant":
            continue
        content = m.get("content", "")
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            parts = [b.get("text", "") for b in content
                     if isinstance(b, dict) and b.get("type") == "text"]
            text = "".join(parts).strip()
            if text:
                return text
    return ""


def starts_with_name(text, name):
    head = text.lstrip(" \t\r\n*#>-—.,!\"'`")
    return head[:len(name)].lower() == name.lower()


def main():
    name = canary_name()
    if not name:
        sys.exit(0)  # канарейка не настроена: echo "Имя" > ~/.claude/canary-name
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        sys.exit(0)
    text = extract_text(data)
    if not text.strip():
        sys.exit(0)
    if not starts_with_name(text, name):
        # systemMessage в stdout — единственный канал, который Claude Code показывает
        # пользователю при exit 0 (stderr успешного хука не выводится)
        print(json.dumps({"systemMessage": (
            f"⚠️ КАНАРЕЙКА: ответ не начался с «{name}» — возможна деградация "
            "контекста или галлюцинации. Перепроверь факты, при сомнении "
            "перезапусти сессию (/compact или новая).")}, ensure_ascii=False))
    sys.exit(0)


if __name__ == "__main__":
    main()
