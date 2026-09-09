#!/usr/bin/env python3
"""Детектор обобщений (Stop-hook): ловит абзацы-выводы в конце ответа.

Пользователь не заказывает выводы, мораль и объяснения «что это значит вообще»:
ответ заканчивается на фактах и следующем шаге. Правило записано текстом
в rules/data-accuracy.md § Zero Generalization и ~/.claude/CLAUDE.md
и в тот же день было нарушено дважды — поэтому нужен механизм, а не текст.

Проверяются ДВА ПОСЛЕДНИХ абзаца ответа: именно туда садится мораль.
Совпадение — systemMessage в stdout, ответ НЕ блокируется.
"""
import json
import re
import sys

# Маркеры начала абзаца-вывода. Ключ — что ищем, значение — как это назвать.
OPENERS = [
    (r"^(итак|вывод|резюмируя|подводя итог|таким образом)\b", "вводка вывода"),
    (r"^(из этого|отсюда|поэтому здесь|исходя из этого)\s+(следует|видно|вытекает)", "«из этого следует»"),
    (r"^это (значит|показывает|доказывает|говорит о том)", "«это значит»"),
    (r"^(хорошая|плохая) новость", "«хорошая/плохая новость»"),
    (r"^(главный |общий )?(урок|мораль)\b", "«урок»"),
    (r"^по сути\b", "«по сути»"),
    (r"^(закономерность|практическая вещь|практический смысл)", "обобщение"),
    (r"^что это (значит|даёт)\b", "«что это значит»"),
]

# Маркеры внутри финального абзаца (ловят обход списка выше).
INLINE = [
    (r"\bиз этого следует\b", "«из этого следует»"),
    (r"\bэто и есть\b.{0,40}\b(урок|вывод|смысл)\b", "«это и есть вывод»"),
    (r"\bпрактическая вещь\b", "«практическая вещь»"),
    (r"\bработает (это )?потому,? что\b", "«работает потому что»"),
    (r"\bпо сути это истори", "«по сути это история про»"),
]


def extract_text(data):
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


def tail_paragraphs(text, n=2):
    paras = [p.strip() for p in re.split(r"\n\s*\n", text) if p.strip()]
    # таблицы, списки и код моралью не бывают
    paras = [p for p in paras if not p.lstrip().startswith(("|", "```", "- ", "* ", "#"))]
    return paras[-n:]


def find_markers(paras):
    hits = []
    for p in paras:
        head = re.sub(r"^[\s*_>#`«\"'-]+", "", p).lower()
        for pat, label in OPENERS:
            if re.search(pat, head):
                hits.append(label)
        low = p.lower()
        for pat, label in INLINE:
            if re.search(pat, low):
                hits.append(label)
    return sorted(set(hits))


def main():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        sys.exit(0)
    text = extract_text(data)
    if not text.strip():
        sys.exit(0)
    hits = find_markers(tail_paragraphs(text))
    if hits:
        print(json.dumps({"systemMessage": (
            "⚠️ ОБОБЩЕНИЕ в конце ответа: " + ", ".join(hits) +
            ". Выводы не заказывали. Ответ заканчивается на фактах и "
            "следующем шаге — rules/data-accuracy.md § Zero Generalization.")},
            ensure_ascii=False))
    sys.exit(0)


if __name__ == "__main__":
    main()
