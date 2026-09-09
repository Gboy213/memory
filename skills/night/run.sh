#!/bin/bash
# night — одна сквозная миссия за ночь: Primary (ротация codex→claude→kimi) идёт
# от источника до бизнес-результата, две другие модели проверяют находки и решения.
# Primary сам чинит, коммитит, пушит и деплоит по contract.md пакета.
#
# Движок (этот файл, board.py, pick_zones.py, roles/, stages/) живёт в ~/.claude/skills/night.
# Пакет репо (contract.md, zones.tsv, summary.md, при желании свои roles/ и stages/) — в <repo>/night/.
# Запуск из корня репо: bash ~/.agents/skills/night/run.sh [--dry-run] [--only <mission>]
# Пакет в другом месте: NIGHT_PKG=<папка с contract.md> bash …/run.sh — REPO берётся из git этой папки.
# Необязательные хуки пакета: notify.sh "<текст>" (уведомление владельцу), preflight.sh (доступы,
# без которых ночь мертва; ненулевой код + причины в stdout → HOLD).
set -uo pipefail

ENGINE="$(cd "$(dirname "$0")" && pwd -P)"
if [ -n "${NIGHT_PKG:-}" ]; then PKG="$(cd "$NIGHT_PKG" && pwd -P)"
elif [ -f "$PWD/night/contract.md" ]; then PKG="$(cd "$PWD/night" && pwd -P)"
elif [ -f "$ENGINE/contract.md" ]; then PKG="$ENGINE"
else echo "night: пакет не найден — запускай из корня репо с папкой night/ или задай NIGHT_PKG=<папка с contract.md>" >&2; exit 2; fi
export NIGHT_PKG="$PKG"                      # board.py / pick_zones.py находят пакет по нему
REPO="$(git -C "$PKG" rev-parse --show-toplevel)"
PKG_REL="${PKG#$REPO/}"                     # напр. night
LOCK="/tmp/night-$(basename "$REPO").lock"
STAGE_TIMEOUT="${STAGE_TIMEOUT:-}"          # задаётся после определения режима
NIGHT_END="${NIGHT_END:-07:30}"             # новые этапы не стартуют после
MAX_NIGHT_SECONDS="${MAX_NIGHT_SECONDS:-34200}"
PRIMARY_OVERRIDE="${PRIMARY:-}"             # PRIMARY=kimi bash run.sh — принудительно

STAGES=("" "system-map" "architecture" "code-quality" "ux-frontend" "docs" "failure-modes" "bug-hunt" "meta-context")
LAST_STAGE=8
PRIMARIES=(codex claude kimi)
# Режим миссии: каждая строка zones.tsv пакета задаёт один сквозной бизнес-поток через
# границы модулей (stages/zone-audit.md). Пакет без zones.tsv работает по-старому,
# этапами-линзами 01–07 из его stages/.
ZONES_FILE="$PKG/zones.tsv"
ZONE_MODE=0; [ -f "$ZONES_FILE" ] && ZONE_MODE=1
if [ "$ZONE_MODE" -eq 1 ] && [ "${NIGHT_ZONES:-1}" != "1" ]; then
  echo "night mission mode runs exactly one mission; remove NIGHT_ZONES=${NIGHT_ZONES}" >&2
  exit 2
fi
ZONES_PER_NIGHT=1
[ -n "$STAGE_TIMEOUT" ] || { [ "$ZONE_MODE" -eq 1 ] && STAGE_TIMEOUT=25200 || STAGE_TIMEOUT=5400; }
# Параллельные роли («чтобы не ждать никого»): ведущая модель
# идёт по миссии и пишет находки в общий журнал, проверяющий и судья работают по
# журналу одновременно с ней, каждый в свой файл. Роли — только те CLI, у которых в
# headless есть shell (codex/claude/kimi): проверять по первоисточникам без чтения
# файлов нельзя, поэтому qwen в ролях не участвует.
PARALLEL="${NIGHT_PARALLEL:-1}"; [ "$ZONE_MODE" -eq 0 ] && PARALLEL=0
ROLE_TIMEOUT="${ROLE_TIMEOUT:-1500}"        # кап на один заход роли, сек
ROLE_IDLE_SLEEP="${ROLE_IDLE_SLEEP:-90}"    # пусто в журнале — столько ждём до следующей проверки
ROLE_GRACE="${ROLE_GRACE:-1800}"            # после миссии даём ролям догнать хвост
DRY_RUN=0; ONLY=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --only) ONLY="next" ;;
    0[1-7]) [ "$ONLY" = "next" ] && ONLY="$arg" ;;
    [a-z]*) [ "$ONLY" = "next" ] && ONLY="$arg" ;;   # --only order-flow
    *) echo "Неизвестный аргумент: $arg" >&2; exit 2 ;;
  esac
done

TODAY="$(date +%F)"
STATE_DIR="$PKG/state"; STATE_FILE="$STATE_DIR/night.state"   # "<campaign> <next-stage> <night-no>"
mkdir -p "$STATE_DIR" "$PKG/reports"
CAMPAIGN="$TODAY"; NEXT=1; NIGHT_NO=0
[ -f "$STATE_FILE" ] && read -r CAMPAIGN NEXT NIGHT_NO < "$STATE_FILE"
case "$CAMPAIGN" in ????-??-??) ;; *) CAMPAIGN="$TODAY"; NEXT=1 ;; esac
case "$NEXT" in ''|*[!0-9]*) NEXT=1 ;; esac
case "$NIGHT_NO" in ''|*[!0-9]*) NIGHT_NO=0 ;; esac
if [ "$NEXT" -gt "$LAST_STAGE" ] && [ "$CAMPAIGN" != "$TODAY" ]; then CAMPAIGN="$TODAY"; NEXT=1; fi
PRIMARY="${PRIMARY_OVERRIDE:-${PRIMARIES[$((NIGHT_NO % 3))]}}"
# refine внутри этапов: три внешних CLI (из codex/claude/kimi/qwen минус Primary), порядок сдвигается по ночам —
# первые два = роли раунда, третий = резерв при лимитах. qwen Primary не бывает (в -p у него нет shell).
ALL_CLIS=(codex claude kimi qwen); EXT=(); for c in "${ALL_CLIS[@]}"; do [ "$c" != "$PRIMARY" ] && EXT+=("$c"); done
r=$((NIGHT_NO % 3)); export REFINE_EXTERNALS="${EXT[$r]},${EXT[$(((r+1)%3))]},${EXT[$(((r+2)%3))]}"
# Только старый этапный режим вызывает refine без живого пользователя (критика выбирает раннер).
[ "$ZONE_MODE" -eq 0 ] && export REFINE_AUTOMATED=1
LOGDIR="$PKG/logs/$CAMPAIGN"; LOG="$LOGDIR/runner.log"

# Роли параллельной ночи: ведущий — PRIMARY, две другие shell-модели проверяют и судят.
SHELL_CLIS=(codex claude kimi); ROLES=(); for c in "${SHELL_CLIS[@]}"; do [ "$c" != "$PRIMARY" ] && ROLES+=("$c"); done
AUDITOR="${NIGHT_AUDITOR:-${ROLES[0]:-}}"; JUDGE="${NIGHT_JUDGE:-${ROLES[1]:-}}"
[ "$PRIMARY" = "qwen" ] && PARALLEL=0        # qwen ведущим не бывает, но подстрахуемся
[ -z "$AUDITOR" ] || [ -z "$JUDGE" ] && PARALLEL=0
export NIGHT_ID="$CAMPAIGN"
BOARD_DIR="$STATE_DIR/$CAMPAIGN"; export NIGHT_BOARD="$BOARD_DIR"
BOARD="python3 $ENGINE/board.py"
# Промты собираются из файлов пакета, при их отсутствии — из движка; плейсхолдеры
# {{NIGHT}} (папка движка) и {{PKG}} (пакет относительно репо) подставляются в конце.
pkg_or_engine() { [ -f "$PKG/$1" ] && echo "$PKG/$1" || echo "$ENGINE/$1"; }
render_prompt() { sed -e "s|{{NIGHT}}|$ENGINE|g" -e "s|{{PKG}}|$PKG_REL|g" "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }

ZONE_LIST=""
if [ "$ZONE_MODE" -eq 1 ]; then
  # Миссия ночи фиксируется один раз за кампанию: прервалась ночь — рестарт
  # продолжает тот же сквозной поток.
  ZONES_TONIGHT="$STATE_DIR/missions-$CAMPAIGN.txt"
  if [ -n "$ONLY" ] && [ "$ONLY" != "next" ]; then
    if ! ZONE_LIST="$(python3 "$ENGINE/pick_zones.py" --only "$ONLY" --ids)" || [ -z "$ZONE_LIST" ]; then
      echo "ABORT: неизвестная или неоднозначная миссия: $ONLY" >&2
      exit 2
    fi
  else
    if [ ! -s "$ZONES_TONIGHT" ]; then
      PICK_TMP="$(mktemp "$STATE_DIR/.missions.XXXXXX")"
      if ! python3 "$ENGINE/pick_zones.py" --count 1 --ids > "$PICK_TMP" || [ ! -s "$PICK_TMP" ]; then
        rm -f "$PICK_TMP"
        echo "ABORT: нет доступной ночной миссии (проверь cooldown через pick_zones.py --list)" >&2
        exit 1
      fi
      mv "$PICK_TMP" "$ZONES_TONIGHT"
    fi
    SAVED_MISSION="$(tr '\n' ' ' < "$ZONES_TONIGHT")"
    if ! ZONE_LIST="$(python3 "$ENGINE/pick_zones.py" --only "$SAVED_MISSION" --ids)" || [ -z "$ZONE_LIST" ]; then
      echo "ABORT: сохранённая миссия некорректна: $SAVED_MISSION" >&2
      exit 2
    fi
  fi
elif [ -n "$ONLY" ] && [ "$ONLY" != "next" ]; then
  NEXT=$((10#$ONLY)); LAST_STAGE="$NEXT"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY-RUN night: campaign=$CAMPAIGN night_no=$NIGHT_NO primary=$PRIMARY"
  if [ "$ZONE_MODE" -eq 1 ]; then
    echo "  режим сквозной миссии из zones.tsv, миссий за ночь: $ZONES_PER_NIGHT"
    if [ "$PARALLEL" -eq 1 ]; then
      echo "  параллельно: ведущий=$PRIMARY, проверяющий=$AUDITOR, судья=$JUDGE; журнал $BOARD_DIR"
    else
      echo "  последовательно (без параллельных ролей)"
    fi
    for z in $ZONE_LIST; do printf '  миссия %-20s → отчёт %s/reports/%s-zone-%s.md\n' "$z" "$PKG_REL" "$CAMPAIGN" "$z"; done
  else
    echo "  refine-externals=$REFINE_EXTERNALS"
    echo "  режим этапов (пакет без zones.tsv), next=$NEXT"
    i="$NEXT"; while [ "$i" -le "$LAST_STAGE" ]; do printf '  этап %02d %s → отчёт %s/reports/%s-%02d-%s.md\n' "$i" "${STAGES[$i]}" "$PKG_REL" "$CAMPAIGN" "$i" "${STAGES[$i]}"; i=$((i+1)); done
  fi
  echo "  затем: сводка $PKG_REL/reports/$CAMPAIGN-summary.md + уведомление (notify.sh, если есть)"
  exit 0
fi

mkdir -p "$LOGDIR"; touch "$LOG"
log() { echo "$(date -Iseconds) $*" | tee -a "$LOG"; }
# Уведомление владельцу: хук пакета notify.sh "<текст>" (Telegram, почта — что угодно); нет хука — только лог.
notify() { if [ -x "$PKG/notify.sh" ]; then bash "$PKG/notify.sh" "$1" >> "$LOG" 2>&1 || log "WARN: notify.sh вернул ошибку"; fi; }

CHILD=""; CAFF=""; LOCK_HELD=0
cleanup() {
  [ -n "$CHILD" ] && kill "$CHILD" 2>/dev/null
  # роли: STOP-файл гасит циклы, kill — их текущие заходы
  [ -n "${BOARD_DIR:-}" ] && [ -d "$BOARD_DIR" ] && touch "$BOARD_DIR/STOP" 2>/dev/null
  [ -n "${AUD_PID:-}" ] && kill "$AUD_PID" 2>/dev/null
  [ -n "${JDG_PID:-}" ] && kill "$JDG_PID" 2>/dev/null
  pkill -f "refine.py _run" 2>/dev/null
  [ -n "$CAFF" ] && kill "$CAFF" 2>/dev/null
  [ "$LOCK_HELD" -eq 1 ] && rmdir "$LOCK" 2>/dev/null
}
trap cleanup EXIT; trap 'exit 130' INT TERM

# ---- preflight ----
for c in codex claude kimi; do command -v "$c" >/dev/null || { log "ABORT: $c не найден в PATH"; exit 1; }; done
mkdir "$LOCK" 2>/dev/null || { log "ABORT: ночь уже идёт ($LOCK)"; exit 1; }; LOCK_HELD=1

# preflight предпосылок: только «мертво до запуска» — логины CLI и то, что проверяет хук
# пакета preflight.sh (ssh до сервера деплоя, токены и т.п.). Таймауты/зависания по ходу
# ночи — вне скоупа (их держат STAGE_TIMEOUT и капы). Провал = state/HOLD с причинами +
# уведомление, ночь не стартует; при живых предпосылках HOLD снимается сам.
HOLD_FILE="$STATE_DIR/HOLD"; FAILS=""
codex login status >/dev/null 2>&1 || FAILS="$FAILS; codex разлогинен (codex login)"
if [ "$(uname)" = "Darwin" ]; then
  security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1 || FAILS="$FAILS; claude без кредов в Keychain (claude /login)"
else
  [ -s "$HOME/.claude/.credentials.json" ] || FAILS="$FAILS; claude без кредов (~/.claude/.credentials.json — claude /login)"
fi
[ -s "$HOME/.kimi-code/credentials/kimi-code.json" ] || FAILS="$FAILS; kimi без кредов (~/.kimi-code/credentials/)"
if command -v qwen >/dev/null 2>&1; then [ -s "$HOME/.qwen/settings.json" ] || FAILS="$FAILS; qwen без настроек (~/.qwen/settings.json)"; fi
if [ -x "$PKG/preflight.sh" ]; then
  PF_OUT="$(bash "$PKG/preflight.sh" 2>> "$LOG")" || FAILS="$FAILS; $(echo "$PF_OUT" | tr '\n' ';' | sed 's/;$//')"
fi
if [ -n "$FAILS" ]; then
  FAILS="${FAILS#; }"
  { date -Iseconds; echo "$FAILS" | tr ';' '\n'; } > "$HOLD_FILE"
  log "ABORT preflight: $FAILS (HOLD: $HOLD_FILE)"
  notify "🛑 night $CAMPAIGN не стартовал — preflight: $FAILS"
  exit 1
fi
rm -f "$HOLD_FILE"

cd "$REPO" || { log "ABORT: нет $REPO"; exit 1; }
[ "$(git symbolic-ref --short HEAD 2>/dev/null)" = "main" ] || { log "ABORT: HEAD не на main"; exit 1; }
[ -z "$(git status --porcelain)" ] || { log "ABORT: рабочее дерево нечистое — закоммить или убери чужие изменения"; exit 1; }
git pull --ff-only origin main >> "$LOG" 2>&1 || { log "ABORT: git pull --ff-only не удался"; exit 1; }
command -v caffeinate >/dev/null && { caffeinate -is -w $$ & CAFF=$!; }

START_TS="$(date +%s)"
log "START campaign=$CAMPAIGN next=$NEXT primary=$PRIMARY externals=$REFINE_EXTERNALS night_no=$NIGHT_NO pid=$$"

write_state() { local tmp; tmp="$(mktemp "$STATE_DIR/.state.XXXXXX")" && printf '%s %s %s\n' "$CAMPAIGN" "$1" "$NIGHT_NO" > "$tmp" && mv "$tmp" "$STATE_FILE"; }
night_over() {  # кап ночи; утреннее окно 07:30–12:00 — только для полной ночи (тестовый --only не блокируется)
  [ $(( $(date +%s) - START_TS )) -ge "$MAX_NIGHT_SECONDS" ] && { log "STOP: кап ночи ${MAX_NIGHT_SECONDS}s"; return 0; }
  local now; now="$(date +%H:%M)"
  [ -z "$ONLY" ] && [[ "$now" > "$NIGHT_END" && "$now" < "12:00" ]] && { log "STOP: после $NIGHT_END новые этапы не стартуют"; return 0; }
  return 1
}

# Один headless-прогон Primary с промтом из файла; таймаут — kill.
run_primary() {  # $1=label $2=prompt-file
  local label="$1" pf="$2" out="$LOGDIR/$1.out" err="$LOGDIR/$1.err" waited=0 rc
  log "primary $PRIMARY start: $label"
  case "$PRIMARY" in
    codex)  codex exec --ephemeral -s danger-full-access --json --color never -c 'approval_policy="never"' -C "$REPO" - < "$pf" > "$out" 2> "$err" & ;;
    claude) claude -p --output-format json --dangerously-skip-permissions --no-session-persistence < "$pf" > "$out" 2> "$err" & ;;
    kimi)   kimi -p "$(cat "$pf")" --output-format stream-json < /dev/null > "$out" 2> "$err" & ;;
  esac
  CHILD=$!
  while kill -0 "$CHILD" 2>/dev/null; do
    sleep 30; waited=$((waited + 30))
    if [ "$waited" -ge "$STAGE_TIMEOUT" ] || [ $(( $(date +%s) - START_TS )) -ge "$MAX_NIGHT_SECONDS" ]; then
      kill "$CHILD" 2>/dev/null; sleep 5; kill -9 "$CHILD" 2>/dev/null; wait "$CHILD" 2>/dev/null; CHILD=""
      pkill -f "refine.py _run" 2>/dev/null
      log "TIMEOUT: $label после ${waited}s"; return 124
    fi
  done
  wait "$CHILD"; rc=$?; CHILD=""
  log "primary done: $label rc=$rc (${waited}s)"; return "$rc"
}

# Primary мог не закоммитить отчёт/журнал refine — докоммитить только их. Любая другая грязь
# (недоделанные правки, мусор) — не коммитить: STOP с перечнем.
sweep() {
  [ -z "$(git status --porcelain)" ] && return 0
  git add -A -- "$PKG_REL/reports" ".llm-audit" 2>/dev/null
  # отметка о проверенной миссии в реестре — тоже наш след, не чужая грязь
  [ "$ZONE_MODE" -eq 1 ] && git add -- "$PKG_REL/zones.tsv" 2>/dev/null
  git diff --cached --quiet || { git commit -q -m "night($1): отчёт/журнал этапа (докоммит раннера)" >> "$LOG" 2>&1; git push origin main >> "$LOG" 2>&1 || log "WARN: push докоммита не удался"; }
  local dirty; dirty="$(git status --porcelain)"
  [ -z "$dirty" ] && return 0
  log "STOP: после этапа $1 в дереве остались незакоммиченные файлы (не трогаю):"; printf '%s\n' "$dirty" >> "$LOG"
  notify "⚠️ night $CAMPAIGN: этап $1 оставил незакоммиченные файлы — ночь остановлена, разбери утром. Лог: $LOG"
  return 1
}

build_prompt() {  # $1=NN $2=slug $3=report-rel $4=prompt-file
  {
    printf 'Параметры прогона:\n- NIGHT_ID=%s\n- STAGE_NN=%s\n- STAGE_SLUG=%s\n- PRIMARY=%s\n- файл отчёта: %s\n- файл этого промта (для task.md refine): %s\n\n' "$CAMPAIGN" "$1" "$2" "$PRIMARY" "$3" "$4"
    cat "$PKG/contract.md"; echo; cat "$PKG/stages/$1-$2.md"
  } > "$4"
  render_prompt "$4"
}

# Один заход роли (проверяющий/судья): короткий headless-прогон со своим таймаутом.
# Отдельно от run_primary: у ролей свои процессы, их не должен убивать таймаут ведущего.
run_role() {  # $1=cli $2=label $3=prompt-file
  local cli="$1" label="$2" pf="$3" out="$LOGDIR/$2.out" err="$LOGDIR/$2.err" waited=0 pid rc
  case "$cli" in
    codex)  codex exec --ephemeral -s danger-full-access --json --color never -c 'approval_policy="never"' -C "$REPO" - < "$pf" > "$out" 2> "$err" & ;;
    claude) claude -p --output-format json --dangerously-skip-permissions --no-session-persistence < "$pf" > "$out" 2> "$err" & ;;
    kimi)   kimi -p "$(cat "$pf")" --output-format stream-json < /dev/null > "$out" 2> "$err" & ;;
    *) log "роль $label: неизвестный CLI $cli"; return 2 ;;
  esac
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 15; waited=$((waited + 15))
    if [ "$waited" -ge "$ROLE_TIMEOUT" ] || [ -f "$BOARD_DIR/STOP" ]; then
      kill "$pid" 2>/dev/null; sleep 3; kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
      log "роль $label: прерван после ${waited}s"; return 124
    fi
  done
  wait "$pid"; rc=$?
  log "роль $label: заход завершён rc=$rc (${waited}s)"; return "$rc"
}

# Цикл роли: есть работа в журнале — работаем, нет — ждём и смотрим снова.
# Никто никого не ждёт: ведущий пишет находки и идёт дальше, роли разбирают по мере появления.
role_loop() {  # $1=cli $2=role(auditor|judge) $3=pending-key(audit|judge)
  local cli="$1" role="$2" key="$3" n i=0
  while [ ! -f "$BOARD_DIR/STOP" ]; do
    n="$($BOARD pending --for "$key" --count 2>/dev/null || echo 0)"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    if [ "$n" -gt 0 ]; then
      i=$((i + 1))
      local pf="$LOGDIR/$role-$i.prompt.md"
      { printf 'Параметры прогона:\n- NIGHT_ID=%s\n- РОЛЬ=%s\n- журнал ночи: %s\n- рабочая папка: %s\n\n' "$CAMPAIGN" "$role" "$BOARD_DIR" "$REPO"
        printf 'В журнале ждут твоей работы: %s шт.\n\n' "$n"
        cat "$(pkg_or_engine "roles/$role.md")"
      } > "$pf"
      render_prompt "$pf"
      log "роль $role ($cli): в журнале $n — запускаю заход $i"
      run_role "$cli" "$role-$i" "$pf"
    else
      sleep "$ROLE_IDLE_SLEEP"
    fi
  done
  log "роль $role ($cli): остановлена"
}

build_zone_prompt() {  # $1=zone-id $2=report-rel $3=prompt-file
  local checklist="$PKG/stages/zone-$1.md"           # спец-чеклист миссии, если есть
  [ -f "$checklist" ] || checklist="$(pkg_or_engine stages/zone-audit.md)"
  {
    printf 'Параметры прогона:\n- NIGHT_ID=%s\n- ZONE=%s\n- PRIMARY=%s\n- файл отчёта: %s\n- файл этого промта (для task.md refine): %s\n\n' "$CAMPAIGN" "$1" "$PRIMARY" "$2" "$3"
    cat "$PKG/contract.md"; echo
    python3 "$ENGINE/pick_zones.py" --only "$1"; echo
    cat "$checklist"
  } > "$3"
  render_prompt "$3"
}

STOP=""
AUD_PID=""; JDG_PID=""

if [ "$ZONE_MODE" -eq 1 ] && [ "$PARALLEL" -eq 1 ]; then
  mkdir -p "$BOARD_DIR"; rm -f "$BOARD_DIR/STOP"
  role_loop "$AUDITOR" auditor audit & AUD_PID=$!
  role_loop "$JUDGE" judge judge & JDG_PID=$!
  log "параллельные роли подняты: проверяющий=$AUDITOR (pid $AUD_PID), судья=$JUDGE (pid $JDG_PID)"
fi

if [ "$ZONE_MODE" -eq 1 ]; then
  for Z in $ZONE_LIST; do
    night_over && { STOP="временной лимит перед миссией $Z"; break; }
    REPORT_REL="$PKG_REL/reports/$CAMPAIGN-zone-$Z.md"
    if git ls-files --error-unmatch "$REPORT_REL" >/dev/null 2>&1; then
      log "миссия $Z уже закоммичена — пропускаю"; continue
    fi
    log "=== миссия $Z ==="
    PF="$LOGDIR/zone-$Z.prompt.md"
    build_zone_prompt "$Z" "$REPORT_REL" "$PF"
    run_primary "zone-$Z" "$PF"; RC=$?
    sweep "zone-$Z" || { STOP="грязное дерево после миссии $Z"; break; }
    if [ ! -f "$REPO/$REPORT_REL" ]; then
      log "WARN: миссия $Z без отчёта (rc=$RC)"
      printf '# Ночь %s — миссия %s — Primary: %s\n\n## Итог: миссия не завершена (rc=%s, см. logs/%s/zone-%s.err)\n' "$CAMPAIGN" "$Z" "$PRIMARY" "$RC" "$CAMPAIGN" "$Z" > "$REPO/$REPORT_REL"
      git add "$REPORT_REL" && git commit -q -m "night(zone-$Z): миссия не завершена (rc=$RC)" >> "$LOG" 2>&1 && git push origin main >> "$LOG" 2>&1
    fi
  done
  # Миссия закончилась. Дальше финальный круг: ждём хвост проверки и суда, потом ведущий
  # отвечает на приговоры (согласен / спорю с новым следом). Спор = второй круг судьи,
  # после него решение окончательное. Кругов максимум два — дальше арбитр человек.
  if [ "$PARALLEL" -eq 1 ] && [ -z "$STOP" ]; then
    wait_roles() {   # $1=сколько ждать, пока в журнале есть работа для ролей
      local end=$(( $(date +%s) + $1 )) a j
      while [ "$(date +%s)" -lt "$end" ]; do
        a="$($BOARD pending --for audit --count 2>/dev/null || echo 0)"
        j="$($BOARD pending --for judge --count 2>/dev/null || echo 0)"
        case "$a$j" in ''|*[!0-9]*) a=0; j=0 ;; esac
        [ "$a" = "0" ] && [ "$j" = "0" ] && return 0
        night_over && return 1
        sleep 30
      done
      return 1
    }
    log "миссия пройдена — жду проверку и суд: $($BOARD stats 2>/dev/null | tr -d '\n ')"
    wait_roles "$ROLE_GRACE"

    ROUND=1
    while [ "$ROUND" -le 2 ]; do
      night_over && { log "финальный круг $ROUND прерван по времени"; break; }
      H="$($BOARD pending --for hunter --count 2>/dev/null || echo 0)"
      case "$H" in ''|*[!0-9]*) H=0 ;; esac
      [ "$H" = "0" ] && break
      log "=== финальный круг $ROUND: ведущему ответить на $H приговор(ов) ==="
      PF="$LOGDIR/final-round-$ROUND.prompt.md"
      { printf 'Параметры прогона:\n- NIGHT_ID=%s\n- РОЛЬ=ведущий, финальный круг %s\n- журнал ночи: %s\n- приговоров без ответа: %s\n- файл отчёта круга: %s/reports/%s-final-round.md\n\n' \
          "$CAMPAIGN" "$ROUND" "$BOARD_DIR" "$H" "$PKG_REL" "$CAMPAIGN"
        cat "$PKG/contract.md"; echo
        cat "$(pkg_or_engine roles/hunter-final.md)"
      } > "$PF"
      render_prompt "$PF"
      run_primary "final-round-$ROUND" "$PF"
      sweep "final-$ROUND" || { STOP="грязное дерево после финального круга $ROUND"; break; }
      wait_roles 900     # спорные ушли судье на второй круг — дождаться
      ROUND=$((ROUND + 1))
    done

    TODO="$($BOARD todo --count 2>/dev/null || echo 0)"
    [ "$TODO" != "0" ] && log "ВНИМАНИЕ: $TODO приговоров остались неисполненными — разбери утром"
  fi
  if [ -n "$AUD_PID$JDG_PID" ]; then
    touch "$BOARD_DIR/STOP"
    kill "$AUD_PID" "$JDG_PID" 2>/dev/null; wait "$AUD_PID" "$JDG_PID" 2>/dev/null
    log "роли остановлены; журнал: $($BOARD stats 2>/dev/null | tr -d '\n ')"
    for f in "$BOARD_DIR"/*.jsonl; do   # журнал ночи уезжает в git как история
      [ -f "$f" ] && cp "$f" "$REPO/$PKG_REL/reports/$CAMPAIGN-$(basename "$f")"
    done
  fi
  i=$((LAST_STAGE + 1))   # сводку ниже собираем так же, как в режиме этапов
fi

i="${i:-$NEXT}"
while [ "$ZONE_MODE" -eq 0 ] && [ "$i" -le "$LAST_STAGE" ]; do
  night_over && { STOP="временной лимит перед этапом $i"; break; }
  NN="$(printf '%02d' "$i")"; SLUG="${STAGES[$i]}"
  if [ ! -f "$PKG/stages/$NN-$SLUG.md" ]; then   # пакет без этого этапа — пропуск
    log "этап $NN $SLUG: нет в пакете $PKG_REL — пропускаю"
    [ -n "$ONLY" ] || write_state "$((i+1))"; i=$((i+1)); continue
  fi
  REPORT_REL="$PKG_REL/reports/$CAMPAIGN-$NN-$SLUG.md"
  if git ls-files --error-unmatch "$REPORT_REL" >/dev/null 2>&1; then
    log "этап $NN уже закоммичен — пропускаю"; write_state "$((i+1))"; i=$((i+1)); continue
  fi
  log "=== этап $NN $SLUG ==="
  PF="$LOGDIR/stage-$NN-$SLUG.prompt.md"
  build_prompt "$NN" "$SLUG" "$REPORT_REL" "$PF"
  run_primary "stage-$NN-$SLUG" "$PF"; RC=$?
  sweep "$NN" || { STOP="грязное дерево после этапа $NN"; break; }
  if [ ! -f "$REPO/$REPORT_REL" ]; then
    log "WARN: этап $NN без отчёта (rc=$RC)"
    printf '# Ночь %s — этап %s %s — Primary: %s\n\n## Итог: этап не завершён (rc=%s, см. logs/%s/stage-%s-%s.err)\n' "$CAMPAIGN" "$NN" "$SLUG" "$PRIMARY" "$RC" "$CAMPAIGN" "$NN" "$SLUG" > "$REPO/$REPORT_REL"
    git add "$REPORT_REL" && git commit -q -m "night($NN): этап не завершён (rc=$RC)" >> "$LOG" 2>&1 && git push origin main >> "$LOG" 2>&1
  fi
  [ -n "$ONLY" ] || write_state "$((i+1))"
  i=$((i+1))
done

if [ -z "$STOP" ] && [ -z "$ONLY" ] && [ "$i" -gt "$LAST_STAGE" ]; then
  SUMMARY_REL="$PKG_REL/reports/$CAMPAIGN-summary.md"
  if ! git ls-files --error-unmatch "$SUMMARY_REL" >/dev/null 2>&1; then
    log "=== сводка ==="
    PF="$LOGDIR/summary.prompt.md"
    { printf 'Параметры прогона:\n- NIGHT_ID=%s\n- PRIMARY=%s\n- файл сводки: %s\n\n' "$CAMPAIGN" "$PRIMARY" "$SUMMARY_REL"; cat "$(pkg_or_engine summary.md)"; } > "$PF"
    render_prompt "$PF"
    run_primary "summary" "$PF" || STOP="сводка не завершена"
    sweep "summary" || STOP="грязное дерево после сводки"
    [ -f "$REPO/$SUMMARY_REL" ] || STOP="сводка не создана"
  fi
  if [ -z "$STOP" ]; then
    NIGHT_NO=$((NIGHT_NO + 1)); write_state "$((LAST_STAGE + 1))"
    TLDR="$(grep '^TL;DR:' "$REPO/$SUMMARY_REL" | head -1 | sed 's/^TL;DR: *//' | cut -c1-700)"
    notify "🌙 night $CAMPAIGN (Primary $PRIMARY): ${TLDR:-сводка готова} — $SUMMARY_REL"
    echo; cat "$REPO/$SUMMARY_REL"   # выжимка в терминал, если раннер шёл в foreground
  fi
fi

if [ -n "$STOP" ]; then log "STOP: $STOP"; notify "⚠️ night $CAMPAIGN остановлен: $STOP. Лог: $LOG"; exit 1; fi
log "END campaign=$CAMPAIGN primary=$PRIMARY"
