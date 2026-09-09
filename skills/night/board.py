#!/usr/bin/env python3
"""Общий журнал ночи: три модели пишут в него параллельно и никто никого не ждёт.

Роли и их файлы (каждая пишет ТОЛЬКО в свой — поэтому гонок нет):
  hunter  → findings.jsonl   нашёл дефект на участке, дописал строку, пошёл дальше
  auditor → audit.jsonl      берёт находки без проверки, сверяет по первоисточникам
  judge   → verdicts.jsonl   берёт проверенные находки, выносит ACCEPT/MODIFY/REJECT
  hunter  → responses.jsonl  финальный круг: согласен с приговором или спорит с новым следом
  judge   → verdicts.jsonl   круг 2 по спорным — решение окончательное
  hunter  → applied.jsonl    что из приговоров уже применил

Кругов максимум два: не сошлись после второго — в «Ждёт решения», арбитр человек.

Все файлы append-only JSONL в <пакет>/state/<кампания>/ (gitignored): в git уезжает только
итог ночи, поэтому параллельная работа не спорит с git-деревом.

    python3 board.py add finding --json '{"id":"order-flow-01",…}'
    python3 board.py pending --for audit          # находки без проверки
    python3 board.py pending --for judge          # проверенные, но без приговора (+ спорные на круг 2)
    python3 board.py pending --for hunter         # приговоры, на которые ведущий не ответил
    python3 board.py todo                         # приговоры, которые hunter ещё не применил
    python3 board.py stats                        # счётчики для сводки
    python3 board.py mark-applied order-flow-01 --note "fixed abc1234"
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime
from pathlib import Path

PKG = Path(os.environ.get('NIGHT_PKG') or Path.cwd() / 'night')   # пакет репо: run.sh экспортирует NIGHT_PKG
KINDS = {'finding': 'findings.jsonl', 'audit': 'audit.jsonl',
         'verdict': 'verdicts.jsonl', 'response': 'responses.jsonl',
         'applied': 'applied.jsonl'}
MAX_ROUND = 2


def board_dir() -> Path:
    """Папка журнала этой ночи: NIGHT_BOARD или state/<кампания>."""
    d = os.environ.get('NIGHT_BOARD')
    if d:
        return Path(d)
    campaign = os.environ.get('NIGHT_ID') or datetime.now().strftime('%Y-%m-%d')
    return PKG / 'state' / campaign


def read(kind: str) -> list[dict]:
    """Битую строку пропускаем: модель могла оборваться на середине записи."""
    p = board_dir() / KINDS[kind]
    if not p.exists():
        return []
    out = []
    for ln in p.read_text(encoding='utf-8', errors='replace').splitlines():
        ln = ln.strip()
        if not ln:
            continue
        try:
            rec = json.loads(ln)
        except json.JSONDecodeError:
            continue
        if isinstance(rec, dict) and rec.get('id'):
            out.append(rec)
    return out


def append(kind: str, rec: dict) -> None:
    d = board_dir()
    d.mkdir(parents=True, exist_ok=True)
    rec.setdefault('ts', datetime.now().isoformat(timespec='seconds'))
    line = json.dumps(rec, ensure_ascii=False) + '\n'
    with (d / KINDS[kind]).open('a', encoding='utf-8') as f:
        f.write(line)          # одна короткая строка в режиме append — атомарна


def _ids(kind: str) -> set[str]:
    return {r['id'] for r in read(kind)}


def _round(rec: dict) -> int:
    try:
        return max(1, min(MAX_ROUND, int(rec.get('round', 1))))
    except (TypeError, ValueError):
        return 1


def _latest(kind: str) -> dict[str, dict]:
    """Последняя запись по каждому id (важен максимальный круг)."""
    out: dict[str, dict] = {}
    for r in read(kind):
        cur = out.get(r['id'])
        if cur is None or _round(r) >= _round(cur):
            out[r['id']] = r
    return out


def cmd_add(args) -> int:
    try:
        rec = json.loads(args.json)
    except json.JSONDecodeError as e:
        print(f'битый JSON: {e}', file=sys.stderr)
        return 2
    if not isinstance(rec, dict) or not rec.get('id'):
        print('в записи обязателен "id" (например "order-flow-01")', file=sys.stderr)
        return 2
    append(args.kind, rec)
    print(f'{args.kind} {rec["id"]}: записан')
    return 0


def cmd_pending(args) -> int:
    findings = read('finding')
    by_find = {f['id']: f for f in findings}
    audits, verdicts, responses = _latest('audit'), _latest('verdict'), _latest('response')

    if args.for_role == 'audit':
        rows = [f for f in findings if f['id'] not in audits]

    elif args.for_role == 'judge':
        rows = []
        for f in findings:
            fid = f['id']
            if fid not in audits:
                continue                       # проверяющий ещё не дошёл
            v, resp = verdicts.get(fid), responses.get(fid)
            if v is None:
                rows.append(dict(f, audit=audits[fid], round=1))
            elif (resp is not None and str(resp.get('response', '')).lower() == 'dispute'
                  and _round(resp) >= _round(v) and _round(v) < MAX_ROUND):
                # ведущий оспорил приговор — второй и последний круг
                rows.append(dict(f, audit=audits[fid], verdict=v, response=resp, round=2))

    else:  # hunter — приговоры, на которые ведущий ещё не ответил
        rows = []
        for fid, v in verdicts.items():
            resp = responses.get(fid)
            if resp is not None and _round(resp) >= _round(v):
                continue                       # на этот круг ответ уже есть
            rows.append(dict(by_find.get(fid, {'id': fid}),
                             audit=audits.get(fid, {}), verdict=v, round=_round(v),
                             final=_round(v) >= MAX_ROUND))
    if args.count:
        print(len(rows))
    else:
        print(json.dumps(rows, ensure_ascii=False, indent=1))
    return 0


def cmd_todo(args) -> int:
    """Что hunter обязан исполнить: приговор, с которым он согласился, либо
    окончательный приговор второго круга (спорить дальше нельзя — только к человеку)."""
    applied = _ids('applied')
    by_id = {f['id']: f for f in read('finding')}
    verdicts, responses = _latest('verdict'), _latest('response')
    rows = []
    for fid, v in verdicts.items():
        if fid in applied:
            continue
        resp = responses.get(fid)
        agreed = resp is not None and str(resp.get('response', '')).lower() == 'agree' \
            and _round(resp) >= _round(v)
        if not (agreed or _round(v) >= MAX_ROUND):
            continue                    # ещё не отвечен либо оспорен — рано применять
        if str(v.get('ruling', '')).upper() not in ('ACCEPT', 'MODIFY', 'REJECT'):
            continue
        rows.append(dict(v, finding=by_id.get(fid, {}), response=resp or {}))
    if args.count:
        print(len(rows))
    else:
        print(json.dumps(rows, ensure_ascii=False, indent=1))
    return 0


def cmd_mark(args) -> int:
    append('applied', {'id': args.finding_id, 'note': args.note})
    print(f'{args.finding_id}: отмечен применённым')
    return 0


def cmd_stats(args) -> int:
    findings, audits, verdicts = read('finding'), read('audit'), read('verdict')
    rulings = {}
    for v in verdicts:
        k = str(v.get('ruling', '?')).upper()
        rulings[k] = rulings.get(k, 0) + 1
    zones = {}
    for f in findings:
        z = f.get('zone', '?')
        zones[z] = zones.get(z, 0) + 1
    responses = read('response')
    disputes = [r for r in responses if str(r.get('response', '')).lower() == 'dispute']
    print(json.dumps({
        'findings': len(findings), 'audited': len(audits), 'judged': len(verdicts),
        'answered': len(responses), 'disputes': len(disputes),
        'applied': len(read('applied')), 'rulings': rulings, 'by_zone': zones,
        'board': str(board_dir()),
    }, ensure_ascii=False, indent=1))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description='Общий журнал параллельной ночи')
    sub = ap.add_subparsers(dest='cmd', required=True)

    a = sub.add_parser('add', help='дописать запись')
    a.add_argument('kind', choices=sorted(KINDS))
    a.add_argument('--json', required=True, help='одна запись JSON-объектом, обязателен "id"')
    a.set_defaults(func=cmd_add)

    p = sub.add_parser('pending', help='что ещё не обработано')
    p.add_argument('--for', dest='for_role', choices=('audit', 'judge', 'hunter'), required=True)
    p.add_argument('--count', action='store_true', help='только число')
    p.set_defaults(func=cmd_pending)

    t = sub.add_parser('todo', help='приговоры, которые hunter ещё не применил')
    t.add_argument('--count', action='store_true')
    t.set_defaults(func=cmd_todo)

    m = sub.add_parser('mark-applied', help='отметить приговор применённым')
    m.add_argument('finding_id')
    m.add_argument('--note', default='')
    m.set_defaults(func=cmd_mark)

    s = sub.add_parser('stats', help='счётчики для сводки')
    s.set_defaults(func=cmd_stats)

    args = ap.parse_args()
    return args.func(args)


if __name__ == '__main__':
    sys.exit(main())
