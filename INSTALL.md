# Installation — для Claude Code (агент, не человек)

Этот файл — инструкция для Claude-агента. Когда пользователь говорит:

> «Установи систему правил из `github.com/Gboy213/memory` — см. `INSTALL.md`»

Выполни шаги ниже **в указанном порядке**. Не пропускай защиты от перезаписи — у пользователя могут быть свои наработки.

---

## Шаг 0. Контекст

- `<repo>` — корень рабочего git-репозитория пользователя (`git rev-parse --show-toplevel`).
- `<global>` — `~/.claude/CLAUDE.md` (глобальный конфиг Claude Code).
- `<tmp>` — `/tmp/memory-install` (временная папка для клона).

Если cwd не git-репозиторий — спроси у пользователя путь к репо для установки. Не предполагай.

> **Машина новая, инструментов ещё нет?** Если на машине не стоит Homebrew / Node / git / сам Claude Code — сначала пройди `SETUP.md` (разворот среды с нуля). Этот `INSTALL.md` предполагает, что Claude Code уже запущен и git доступен.

---

## Шаг 1. Клонировать пэк во временную папку

```bash
rm -rf /tmp/memory-install
git clone --depth 1 https://github.com/Gboy213/memory /tmp/memory-install
```

Если `git clone` упал — сообщи пользователю точную ошибку (нет сети / нет доступа / git не установлен) и остановись.

---

## Шаг 2. Глобальный `~/.claude/CLAUDE.md`

```bash
mkdir -p ~/.claude
```

Если `~/.claude/CLAUDE.md` **не существует**:
```bash
cp /tmp/memory-install/templates/global-CLAUDE.md ~/.claude/CLAUDE.md
```
Сообщить: «Глобальный CLAUDE.md создан. Открой и подправь под себя: язык, тон, личные предпочтения».

Если **существует** — НЕ затирать. Показать пользователю diff (`diff ~/.claude/CLAUDE.md /tmp/memory-install/templates/global-CLAUDE.md`), спросить:
- `skip` — не трогать (по умолчанию)
- `overwrite` — затереть (только по явному согласию)
- `show` — вывести оба файла для решения

---

## Шаг 3. `<repo>/CLAUDE.md`

Аналогично шагу 2, но для корня репо пользователя.

Источник: `/tmp/memory-install/templates/project-CLAUDE.md`.
Цель: `<repo>/CLAUDE.md`.

Та же логика «существует → не затирать, спросить».

---

## Шаг 4. `<repo>/rules/`

```bash
mkdir -p <repo>/rules
```

Для каждого файла в `/tmp/memory-install/rules/*.md`:
- Если `<repo>/rules/<имя>.md` НЕ существует — copy.
- Если существует — **не затирать**. В отчёте отметить «уже было: rules/<имя>.md».

Не использовать `cp -r rules/` целиком — оно затрёт существующие правила пользователя.

---

## Шаг 5. `<repo>/MEMORY.md` и `<repo>/memory/`

```bash
mkdir -p <repo>/memory
```

- Если `<repo>/MEMORY.md` не существует — `cp /tmp/memory-install/templates/MEMORY.md <repo>/MEMORY.md`.
- Если `<repo>/memory/README.md` не существует — `cp /tmp/memory-install/memory/README.md <repo>/memory/README.md`.

Если существует — не трогать.

**Никогда** не копировать файлы из `<repo>/memory/*.md` (кроме `README.md`). Это персональная память пользователя — даже если она пустая.

---

## Шаг 6. Глобальный харнес `~/.claude/` (среда Claude Code)

Это то, что обычно настраивают руками и из-за чего онбординг на новой машине болезненный: права, нижняя панель (статуслайн), хуки, скиллы. Ставим из `claude-home/` и `skills/` пэка.

**6.1 `~/.claude/settings.json`** (права allow/deny + statusLine + хуки + ultrathink-на-каждый-промпт):
- Если НЕ существует — `cp /tmp/memory-install/claude-home/settings.json ~/.claude/settings.json`.
- Если существует — **НЕ затирать** (там личные права/хуки пользователя). Показать diff, спросить `skip`/`merge`/`overwrite`. По умолчанию skip.

**6.2 Статуслайн:**
- Основной — `claude-home/statusline.js` (node; `settings.json` уже указывает на него): модель, папка, ctx-токены и %, лимиты 5ч/7д с таймером сброса, цена сессии. Если `~/.claude/statusline.js` нет — скопировать.
- Запасной bash-вариант `statusline-command.sh` — скопировать тоже (Windows-настройки указывают на него).

**6.3 Хуки** (`~/.claude/hooks/`) — пофайлово, не затирая:
- `warn-before-push.sh`, `post-edit-syntax-check.sh`, `drift-markers.py` (метки `#длинно/#вода/#круги` из промта → `~/.claude/drift-markers.tsv`), `canary-name-check.py` (Stop-hook: ответ не начался с имени пользователя → systemMessage-предупреждение). `chmod +x` после копирования.
- Канарейка работает только после `echo "Имя" > ~/.claude/canary-name` (спросить имя у пользователя) и секции «Канарейка контекста» в `~/.claude/CLAUDE.md` (есть в шаблоне). Предупреждение приходит как systemMessage хука (Stop-событие); проверка: `echo '{"last_assistant_message":"Привет"}' | python3 ~/.claude/hooks/canary-name-check.py` → JSON с текстом предупреждения.

**6.4 Скиллы** (`~/.claude/skills/`) — по одной папке, не затирая существующие:
- `close`, `handoff`, `write` (+ `references/` — конспекты книг Ильяхова), `diplomat` (резкое → рабочее), `council` (4 параллельных агента для стратегических решений), `memory-audit` (чистка долгой памяти), `refine`. `cp -r /tmp/memory-install/skills/<name> ~/.claude/skills/<name>` только если папки ещё нет.
- Для каждого — ссылка `~/.agents/skills/<name> → ~/.claude/skills/<name>` (эту папку читают Claude Code, Codex, Kimi и Qwen; `refine` без неё виден только Claude).

**6.4a refine — проверка второй моделью** (`skills/refine/README.md` — полное описание):
- Что это: твоё решение прогоняется через одну другую модель, которую ты называешь сам (она ищет ошибки в режиме audit или лишнюю сложность в режиме optimize); ты остаёшься автором и сам решаешь по каждому замечанию. Третья модель-судья (`--judge`) и второй раунд (`--rounds 2`) — только по прямой просьбе. Вызов: `/refine codex <задача>` в Claude Code, `$refine claude <задача>` в Codex, `/skill:refine codex <задача>` в Kimi (вместо codex/claude — любой из четырёх CLI, кроме своего).
- Нужно: кроме твоего CLI ещё **минимум один** из `codex`, `claude`, `kimi`, `qwen` в PATH и залогиненный (подписки, не API-ключи). Для `--judge` / `--rounds 2` — минимум два.
- Проверка: `python3 ~/.agents/skills/refine/refine.py init --host claude --reviewer codex --slug test` печатает критика раунда 1 и резерв → удалить созданную папку `.llm-audit/` в текущей директории.
- Kimi: усилие `max` в `~/.kimi-code/config.toml` (`[thinking] effort = "max"`); модели Kimi/Qwen закреплены в `skills/refine/models.json`.
- Проверено на macOS. На Windows не тестировалось: `refine.py` зовёт CLI по имени через subprocess — `.cmd`-шимы npm могут не находиться, при первом запуске проверить.

**6.5 MCP-серверы** (`~/.claude/.mcp.json`):
- Если файла нет — взять `claude-home/.mcp.json.template`, заменить `__REPO__` на абсолютный путь `<repo>`, записать в `~/.claude/.mcp.json`.
- `playwright` работает сразу (через `npx`). `google-sheets`/`google-docs` указывают на `<repo>/integrations/.../server.py` — нужны их venv + `credentials.json`. Если этих серверов в репо нет — предупредить пользователя, что записи можно удалить или донастроить.
- Если `~/.claude/.mcp.json` уже есть — НЕ затирать, показать образец.
- **sqlite и другие credential-bound MCP** (если были у пользователя) добавляются через `claude mcp add` вручную — их в пэке нет, путь к БД и доступы машинно-зависимы.

---

**6.6 Другие CLI — Codex / Qwen / Kimi** (только если соответствующий CLI уже установлен; `refine` нужен минимум один кроме Claude):
- Codex: `codex-home/AGENTS.md` → `~/.codex/AGENTS.md` (глобальные правила, зеркало `~/.claude/CLAUDE.md` без Claude-специфики), `codex-home/hooks/*` → `~/.codex/hooks/`, `codex-home/hooks.json` → `~/.codex/hooks.json` с заменой `__HOME__` на домашнюю папку. Не затирать существующее. **После установки хуков Codex их надо доверить руками:** в codex открыть `/hooks`, проверить три определения (warn-before-push, post-edit-syntax-check, drift-markers) и подтвердить — до этого Codex их пропускает. Статуслайн Codex (остаток контекста, токены, лимиты 5ч/7д) и `model_reasoning_effort = "xhigh"` — строки из `codex-home/config.snippet.toml` слить в `~/.codex/config.toml` руками (файл содержит auth, не перезаписывать).
- Qwen: `qwen-home/QWEN.md` → `~/.qwen/QWEN.md`.
- Kimi: строки из `kimi-home/config.snippet.toml` в `~/.kimi-code/config.toml` (усилие `max`) — руками, файл содержит OAuth-секции, не перезаписывать.
- В проекте адаптеры для этих CLI — `AGENTS.md` (Codex, Kimi) и `QWEN.md` в корне репо: копии карты проекта без ссылок на `CLAUDE.md`/`.claude/**` (каждый агент читает только свой adapter и нейтральные `rules/`, `context.md`).

## Шаг 7. Shell-алиас быстрого запуска

Чтобы Claude запускался по короткой команде с заходом в проект (как `213` → `cd <repo> && claude`):

```bash
ALIAS_NAME=$(basename "<repo>")
RC=~/.zshrc            # или ~/.bashrc для bash
```

- Если в `$RC` уже есть `alias $ALIAS_NAME=` — пропустить.
- Иначе дописать: `alias <ALIAS_NAME>='cd <repo> && claude'`.
- Сообщить пользователю: «перезапусти терминал или `source $RC`, дальше команда `<ALIAS_NAME>` открывает Claude в проекте».

**НЕ** копировать `.zshrc`/`.bashrc` пользователя куда-либо — там могут быть секреты (прокси-пароли и т.п.). Только дописать одну строку алиаса.

---

## Шаг 8. Опциональные шаблоны

Если пользователь явно попросит «положи шаблоны context.md/current-focus.md в подпроекты» — можно скопировать `templates/context.md` и `templates/current-focus.md` в нужный подпроект. По умолчанию — не копировать (это шаблоны для будущих подпроектов, не системные файлы).

---

## Шаг 9. Отчёт пользователю

После завершения — одно сообщение:

```
Pack установлен из github.com/Gboy213/memory.

Создано:
  - <список созданных файлов с путями>

Пропущено (уже было):
  - <список с путями>

Что дальше:
  1. source ~/.zshrc (или новый терминал) — команда <ALIAS_NAME> откроет Claude в проекте.
  2. Открой <repo>/CLAUDE.md и заполни карту проекта (папки, кодовые слова).
  3. Открой ~/.claude/CLAUDE.md и поправь язык/тон под себя.
  4. settings.json: ultrathink-на-каждый-промпт и model opus[1m] — личные настройки, при желании убери.
  5. Полная философия слоёв — github.com/Gboy213/memory/blob/main/ARCHITECTURE.md
```

---

## Шаг 10. Очистка

```bash
rm -rf /tmp/memory-install
```

---

## Обновление (повторный запуск)

Если пользователь говорит «обнови систему правил с того же URL» — повтори шаги 1-10. На каждом шаге, где файл уже существует:

1. Сделать diff с свежей версией из `/tmp/.../`.
2. Если различий нет — пропустить.
3. Если есть — показать diff, спросить `update`/`skip`/`merge`.
4. **Никогда не затирать чужой `CLAUDE.md` или `memory/` без явного `yes` от пользователя.**

---

## Что НЕ делать

- Не копировать `.git/` папку пэка в репо пользователя.
- Не копировать `LICENSE` пэка в репо пользователя (у него может быть своя лицензия).
- Не копировать `INSTALL.md` или `README.md` пэка в репо пользователя.
- Не запускать `git init` если репо уже git-проект.
- Не делать `git add` / `git commit` от своего имени — пусть пользователь решит когда коммитить.
- Не редактировать чужие файлы без явного согласия.

---

## Failure modes

- **Нет git CLI** — сообщить пользователю «нужен git, установи и повтори».
- **Нет интернета** — сообщить «не могу склонировать репо, проверь сеть».
- **Нет прав на запись в `~/.claude/`** — сообщить точную ошибку, спросить как продолжить.
- **Конфликт версий** — показать diff, не решать самостоятельно.
