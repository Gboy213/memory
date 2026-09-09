#!/usr/bin/env python3
"""Выбор одной сквозной ночной миссии (реестр zones.tsv, имя сохранено для совместимости).

Каждая строка реестра — законченный бизнес-поток через несколько модулей, а не папка.
Одна ночь = одна миссия от источника до результата.

Приоритет = давность миссии + небольшой бонус CORE + свежие уникальные файлы. После
полной миссии она 7 дней не выбирается снова: аудит не должен крутиться вокруг
собственных свежих исправлений.

    python3 pick_zones.py --count 1          # одна миссия
    python3 pick_zones.py --list             # весь реестр с давностью
    python3 pick_zones.py --done order-flow --verdict "2 находки, 1 починена"
"""
from __future__ import annotations

import argparse
import csv
import os
import subprocess
import sys
from datetime import date
from pathlib import Path

PKG = Path(os.environ.get('NIGHT_PKG') or Path.cwd() / 'night')   # пакет репо: run.sh экспортирует NIGHT_PKG
ZONES = PKG / 'zones.tsv'
REPO = Path(subprocess.run(['git', '-C', str(PKG), 'rev-parse', '--show-toplevel'],
                           capture_output=True, text=True).stdout.strip() or PKG)
NEVER = 9999          # давность «ни разу не проверяли»
CORE_BONUS = 7        # CORE впереди при равной давности, но SUPPORT не голодает
FRESH_DAYS = 14       # окно «свежих правок»
FRESH_BONUS_MAX = 7
MISSION_COOLDOWN_DAYS = 7
MISSION_MARKER = 'mission:'
FIELDS = ['n', 'id', 'class', 'paths', 'entry', 'check', 'runtime', 'last_audit', 'note']


def load() -> list[dict]:
    with ZONES.open(encoding='utf-8') as f:
        return list(csv.DictReader(f, delimiter='\t'))


def save(rows: list[dict]) -> None:
    tmp = ZONES.with_suffix('.tsv.tmp')
    with tmp.open('w', encoding='utf-8', newline='') as f:
        f.write('\t'.join(FIELDS) + '\n')
        for row in rows:
            f.write('\t'.join(str(row.get(field) or '') for field in FIELDS).rstrip('\t') + '\n')
    tmp.replace(ZONES)


def age_days(row: dict, today: date) -> int:
    raw = (row.get('last_audit') or '').strip()
    if not raw:
        return NEVER
    try:
        audited = date.fromisoformat(raw)
        return (today - audited).days
    except ValueError:
        return NEVER


def churn(row: dict) -> int:
    """Сколько код-файлов зоны трогали за FRESH_DAYS — свежие правки = свежие баги."""
    paths = [p for p in row['paths'].split(',') if p.strip()]
    if not paths:
        return 0
    # core.quotepath=false обязателен: иначе кириллические пути приходят в кавычках
    # («"\320\261..."») и хвост .py не совпадает — счётчик молча даёт 0.
    out = subprocess.run(
        ['git', '-C', str(REPO), '-c', 'core.quotepath=false', 'log',
         f'--since={FRESH_DAYS} days ago',
         '--name-only', '--pretty=format:', '--', *paths],
        capture_output=True, text=True)
    return len({ln.strip() for ln in out.stdout.splitlines()
                if ln.strip().endswith(('.py', '.js', '.css', '.html', '.sh'))})


def score(row: dict, today: date) -> int:
    s = age_days(row, today)
    if row['class'] == 'CORE':
        s += CORE_BONUS
    return s + min(churn(row), FRESH_BONUS_MAX)


def render(rows: list[dict], today: date) -> str:
    out = [f'## Сквозная миссия этой ночи ({len(rows)}) — реестр {{{{PKG}}}}/zones.tsv\n']
    for r in rows:
        a = age_days(r, today)
        seen = 'НИ РАЗУ не проверялась' if a >= NEVER else f'последний раз {r["last_audit"]} ({a} дн назад)'
        out.append(
            f'### Миссия: {r["id"]} ({r["class"]}) — {seen}\n'
            f'- границы кода: {r["paths"]}\n'
            f'- вход (доки): {r["entry"]}\n'
            f'- проверка: {r["check"]}\n'
            f'- бизнес-результат, до которого надо дойти: {r["runtime"] or "—"}\n'
            f'- прошлый вердикт: {r["note"] or "—"}\n')
    out.append('Закончил сквозную миссию — отметь: '
               '`python3 {{NIGHT}}/pick_zones.py --done <id> --verdict "<итог одной строкой>"`\n')
    return '\n'.join(out)


def main() -> int:
    ap = argparse.ArgumentParser(description='Выбор ночной миссии по zones.tsv')
    ap.add_argument('--count', type=int, default=1, help='сколько миссий взять (default 1)')
    ap.add_argument('--list', action='store_true', help='весь реестр с давностью')
    ap.add_argument('--done', help='id миссии — отметить проверенной сегодня')
    ap.add_argument('--verdict', default='', help='итог миссии одной строкой (к --done)')
    ap.add_argument('--only', help='взять именно эти id миссий через запятую (тест)')
    ap.add_argument('--ids', action='store_true', help='печатать только id по строкам (для run.sh)')
    args = ap.parse_args()

    today = date.today()
    rows = load()

    if args.done:
        hit = [r for r in rows if r['id'] == args.done]
        if not hit:
            print(f'нет миссии {args.done}; есть: {", ".join(r["id"] for r in rows)}',
                  file=sys.stderr)
            return 2
        hit[0]['last_audit'] = today.isoformat()
        verdict = args.verdict.replace('\t', ' ').strip() or 'существенных дефектов нет'
        hit[0]['note'] = f'{MISSION_MARKER} {verdict}'
        save(rows)
        print(f'{args.done}: отмечен {today.isoformat()}')
        return 0

    if args.list:
        for r in sorted(rows, key=lambda x: -score(x, today)):
            a = age_days(r, today)
            state = 'готова' if a >= MISSION_COOLDOWN_DAYS else f'cooldown {MISSION_COOLDOWN_DAYS - a} дн'
            print(f'{r["id"]:16} {r["class"]:8} '
                  f'{"НИКОГДА" if a >= NEVER else str(a) + " дн":>9}  '
                  f'правок14д={churn(r):3}  score={score(r, today)}  {state}')
        return 0

    if args.only:
        want = [s.strip() for s in args.only.split(',') if s.strip()]
        if len(want) != 1:
            print('одна ночь = одна миссия; --only принимает ровно один id', file=sys.stderr)
            return 2
        pick = [r for r in rows if r['id'] == want[0]]
        if not pick:
            print(f'нет миссии {want[0]}; есть: {", ".join(r["id"] for r in rows)}',
                  file=sys.stderr)
            return 2
    else:
        if args.count != 1:
            print('одна ночь = одна миссия; --count должен быть 1', file=sys.stderr)
            return 2
        eligible = [r for r in rows if age_days(r, today) >= MISSION_COOLDOWN_DAYS]
        if not eligible:
            print('нет миссий вне cooldown; см. --list', file=sys.stderr)
            return 3
        pick = sorted(eligible, key=lambda r: -score(r, today))[:max(1, args.count)]
    if args.ids:
        print('\n'.join(r['id'] for r in pick))
    else:
        print(render(pick, today))
    return 0


if __name__ == '__main__':
    sys.exit(main())
