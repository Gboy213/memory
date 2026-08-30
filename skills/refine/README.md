# refine — Primary → Optimizer → Judge, два раунда, три CLI

Одна команда в любом из трёх терминалов (Codex / Claude Code / Kimi Code):
сессия, из которой ты запустил, остаётся автором (Primary), две другие модели по
очереди ищут лишнюю сложность (Optimizer) и решают, что из этого безопасно принять
(Judge). Во втором раунде они меняются ролями. Хост сам вносит правки.

```
ROUND 1: Primary → Optimizer(A) → Judge(B) → Revision 1
ROUND 2: Revision 1 → Optimizer(B) → Judge(A) → Final
```

Четыре CLI: `codex`, `claude`, `kimi`, `qwen` (с 30.08.2026). Внешние = три не-хостовых в порядке
`codex → claude → kimi → qwen` минус хост: первые два — роли раундов (раунд 1: e0 → e1, раунд 2:
e1 → e0), третий — **резерв**. Порядок можно задать: `REFINE_EXTERNALS="kimi,qwen,codex"`
(так ночной раннер сдвигает пары по ночам).

| Хост (Primary) | Раунд 1 | Раунд 2 | Резерв |
|---|---|---|---|
| Claude | Codex → Kimi | Kimi → Codex | Qwen |
| Codex | Claude → Kimi | Kimi → Claude | Qwen |
| Kimi | Codex → Claude | Claude → Codex | Qwen |
| Qwen | Codex → Claude | Claude → Codex | Kimi |

**Лимиты и отказы (с 30.08.2026).** Вызов упал с признаками лимита (rate limit / usage limit /
quota / 429 / overloaded) — второй попытки той же модели нет, роль сразу берёт резерв со своим
промтом; упал дважды по другой причине — тоже резерв. В `meta.json` у вызова `quota: true`,
`substituted_for: <кто выбыл>`, в `rounds` — `optimizer_original` / `judge_original`. Резерв тоже
упал — раунд `failed`, как раньше (финал = предыдущая версия).

**Модели закреплены** в `models.json` (Kimi `kimi-code/k3`, Qwen `qwen3.8-max-preview`);
Codex/Claude — дефолт их CLI. Усилие Kimi — `max` через `~/.kimi-code/config.toml`
(`[thinking] effort = "max"` + `default_effort = "max"` у k3; решение Жени 30.08.2026).
Переопределить разово: `REFINE_MODEL_<CLI>=…`.

## Два режима второй модели
| Режим | Вторая модель | Вопрос | Формат | Судья |
|---|---|---|---|---|
| `optimize` (дефолт) | Optimizer | «можно ли проще без потери качества?» | `## P1:` WHAT/WHY/ALTERNATIVE/TRADEOFF/VERDICT/EVIDENCE или `KEEP AS IS` | ACCEPT/MODIFY/REJECT по предложению |
| `audit` (`init --mode audit`) | Auditor (adversarial) | «что здесь неверно?» — ошибки, ложные допущения, пропущенные edge cases, противоречия источникам; не улучшать текст | `## A1:` CLAIM/EVIDENCE/IMPACT/SEVERITY/FIX или `NO FINDINGS` | ACCEPT = валидно, чинить / MODIFY = частично / REJECT = невалидно или без evidence |

Мотор, ротация, логи, метрики и отказы одинаковы; промты — `optimizer.md` / `auditor.md`, судья один (`judge.md`, режим передаётся строкой MODE).

## Установка / удаление

Все три CLI читают `~/.agents/skills/` (проверено 29.08.2026: Claude Code 2.1.251,
Codex 0.149.1, Kimi 0.36.0). Один симлинк:

```bash
# установщик пэка (install.sh / install.ps1) кладёт skills/refine в ~/.claude/skills/refine
# и делает ссылку ~/.agents/skills/refine → на неё; руками то же самое:
mkdir -p ~/.agents/skills && ln -s ~/.claude/skills/refine ~/.agents/skills/refine
rm ~/.agents/skills/refine                                   # удалить
```

Нужны установленные и залогиненные `codex`, `claude`, `kimi` в PATH. Python 3, без зависимостей.

## Запуск

| Среда | Команда |
|---|---|
| Claude Code | `/refine <задача>` или после решения: «прогони через refine» |
| Codex | `$refine <задача>` |
| Kimi Code | `/skill:refine <задача>` |

Codex-хост: его sandbox режет дочерним процессам сеть и запись вне workspace, а
Kimi/Claude пишут в свои домашние папки (проверено 29.08: внутри sandbox Kimi падает
`storage write failed: permission denied`). `refine.py round` это видит
(`CODEX_SANDBOX`) и отказывается с подсказкой: одобрить запуск команды вне sandbox
(Codex сам предложит эскалацию) или стартовать `codex -s danger-full-access`.

Хост читает `SKILL.md` и сам делает: `init → task.md + primary.md → round 1 → wait →
revision-1.md → round 2 → wait → final.md → finish`. Скрипт зовёт внешние модели,
хост думает. Ручного копипаста между моделями нет.

## Что остаётся после прогона

`.llm-audit/<дата-время-slug>/` в рабочей папке задачи (`.llm-audit/latest` → последний):

| Файл | Кто пишет | Что |
|---|---|---|
| `task.md` | хост | задача дословно |
| `primary.md` (+`primary.diff`) | хост (+скрипт) | решение; diff к базовому коммиту скрипт снимает в журнал (в промт не вкладывается: ревьюеры читают репо сами по `base_sha`) |
| `optimizer-1.md`, `judge-1.md` | внешние | отчёт и вердикты раунда 1 |
| `revision-1.md` (+`.diff`) | хост | `Applied: n/m` + что изменено |
| `optimizer-2.md`, `judge-2.md` | внешние | раунд 2 |
| `final.md` (+`final.diff`) | хост | итог |
| `meta.json` | скрипт | метрики: модели, роли, время, токены, стоимость, счётчики вердиктов, applied |
| `calls.log` | скрипт | stderr/ошибки внешних вызовов |
| `round-N.status` | скрипт | running / done / failed |

## Метрики (meta.json → будущий бенчмарк)

По каждому вызову: `cli`, `model`, `role`, `round`, `attempt`, `latency_s`, `usage`
(сырой формат CLI), `cost_usd` (только Claude, оценка клиента), `prompt_chars`,
`output_chars`, `ok`. По раунду: `proposals`, `keep_as_is`, `accept/modify/reject`,
`unresolved`. По прогону: `applied` из шапок `revision-1.md` / `final.md`.
Kimi не отдаёт токены ни в одном формате вывода: у него только время и размеры. В audit-режиме
в раунд пишется `severity` (сколько critical/high/medium/low нашёл Auditor).

Все три CLI у нас на подписках, поэтому `cost_usd` информационный.

## Как зовутся внешние модели (все read-only)

- Codex: `codex exec --json --ephemeral -s read-only -C <cwd> -o <file> -` (промт со stdin; OS-sandbox).
- Claude: `claude -p --output-format json --setting-sources '' --strict-mcp-config --permission-mode dontAsk --tools Read,Glob,Grep,Bash --allowedTools Read,Glob,Grep,Bash(git diff|log|show|status|ls-files|blame *)`. Без `--setting-sources ''` каждый вызов тащит все правила репо (71K токенов вместо 3K).
- Qwen: `qwen -p … --output-format json -m qwen3.8-max-preview` (промт со stdin). В `-p` у Qwen нет shell и
  write-инструментов (проверено 30.08.2026: отказался выполнить `touch`) — read-only по конструкции, но и
  `git diff` он запустить не может, поэтому ему единственному diff-снимок вкладывается в промт (до 150K символов).
  Токены отдаёт (`usage`), стоимость — нет. Хостом (Primary) в ночи не бывает — без shell нечем коммитить.
- Kimi: `kimi -p "<prompt>" --output-format stream-json --agent-file kimi-agent.md` (профиль без Write/Edit; Bash ограничен только инструкцией промта — OS-sandbox у Kimi нет, это самая слабая из трёх гарантий read-only; промт в argv, лимит 600K символов).

Промты ролей: `optimizer.md`, `judge.md`. Формат ответа строгий, по нему считаются метрики
(`## P1:` у оптимизатора, `VERDICT: ACCEPT|MODIFY|REJECT` у судьи, `Applied: n/m` у хоста).

## Отказы

- Вызов упал / пустой ответ → один ретрай → `optimizer-N.md` = `FAILED: …`, раунд `failed`, хост идёт дальше.
- Таймаут (`REFINE_TIMEOUT` 1200 с; судье отдельно `REFINE_JUDGE_TIMEOUT` 600 с) → без ретрая, роль сразу берёт резерв (с 30.08.2026: один Kimi-судья думал 28 мин над одним предложением). В `meta.json` у вызова `timeout: true`.
- Судья упал → `judge-N.md` = `FAILED`, хост решает по отчёту оптимизатора сам.
- Оптимизатор ответил `KEEP AS IS` → судья пропускается.
- Раунд 1 = `KEEP AS IS` / `NO FINDINGS` → раунд 2 не запускается (`round 2` пишет `skipped`, хост сразу `final.md` + `finish`). По 16 прогонам второй проход после чистого первого давал 4 мелких правки из 47 ценой 2–7 мин.
- Одна и та же модель в двух ролях (`REFINE_EXTERNALS="qwen,qwen"`) → `init` отказывает: модель не судит собственный отчёт.
- Раунд 2 упал → финал = revision 1 (`finish` работает после любого раунда).
- CLI не в PATH → без ретрая, сразу FAILED.

## Переменные окружения

`REFINE_TIMEOUT` (сек на вызов), `REFINE_JUDGE_TIMEOUT` (сек на судью, дефолт 600), `REFINE_AUDIT_DIR` (дефолт `.llm-audit`),
`REFINE_MODEL_CODEX` / `REFINE_MODEL_CLAUDE` / `REFINE_MODEL_KIMI` (иначе дефолт CLI).

## Почему так, а не иначе

- Один скилл на трёх, потому что `~/.agents/skills/` общий; три копии промта не нужны.
- Diff не вкладывается в промты (dogfood 29.08, предложение Codex, принято Kimi): у всех трёх внешних моделей есть read-only доступ к репо, они смотрят `git diff <base_sha>` сами; вложенный diff был 76% промта и дублировал источник истины.
- Скрипт вместо «хост сам зовёт CLI»: воспроизводимый парсинг JSON трёх форматов, фон + `wait` (у Kimi foreground-bash 60 с), таймауты, ротация, meta. 300 строк вместо импровизации трёх моделей.
- Без MCP/SDK/шины файлов/launchd: CLI уже умеют читать репо и работают на подписках.
