#!/usr/bin/env python3
"""UserPromptSubmit hook: ловит дрифт-метки #длинно/#вода/#круги в запросе
пользователя и дописывает строку в лог. Раз в неделю — ручной просмотр суммы.

Лог: $DRIFT_MARKERS_LOG или ~/.codex/drift-markers.tsv (свой у каждого CLI; общий — через переменную). Никогда не падает
(всегда exit 0) и ничего не печатает в stdout — не ломает сессию и не засоряет контекст.
"""
import sys, json, re, os, datetime

LOG = os.environ.get("DRIFT_MARKERS_LOG") or os.path.join(os.path.expanduser("~"), ".codex", "drift-markers.tsv")
MARKERS = ("#длинно", "#вода", "#круги")

try:
    data = json.load(sys.stdin)
    prompt = data.get("prompt", "") or ""
    marks = [m for m in MARKERS if m in prompt]
    if marks:
        ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
        snippet = re.sub(r"\s+", " ", prompt).strip()[:120]
        new = not os.path.exists(LOG)
        with open(LOG, "a", encoding="utf-8") as f:
            if new:
                f.write("date\tmarkers\tprompt\n")
            f.write(f"{ts}\t{','.join(marks)}\t{snippet}\n")
except Exception:
    pass

sys.exit(0)
