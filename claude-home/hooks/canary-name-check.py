#!/usr/bin/env python3
"""Канарейка контекста (Stop-hook): проверяет, что ответ агента начался с твоего имени.

Имя берётся из ~/.claude/canary-name (одна строка, например «Женя»). Файла нет —
хук молчит. Пропажа имени в начале ответа = маркер деградации контекста /
начала галлюцинаций: предупреждение уходит в stderr, ответ НЕ блокируется.
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
    msg = data.get("assistant_message")
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
        sys.stderr.write(
            f"⚠️  КАНАРЕЙКА: ответ не начался с «{name}» — возможна деградация "
            "контекста или галлюцинации. Перепроверь факты, при сомнении "
            "перезапусти сессию (/compact или новая).\n"
        )
    sys.exit(0)


if __name__ == "__main__":
    main()
