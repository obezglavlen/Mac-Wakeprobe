#!/bin/bash
# Tests for power-notify.sh
#   --decide <last> <now> <streak> <debounce>  -> send=offline | send=online | noop
#   --compose <AC|BATT> <pct>                  -> message text
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/power-notify.sh"
fails=0

decide_is() { # last now streak debounce want
  local got
  got="$("$SCRIPT" --decide "$1" "$2" "$3" "$4" 2>&1)"
  if [ "$got" = "$5" ]; then
    echo "ok   last='$1' now='$2' streak=$3 debounce=$4 -> $got"
  else
    echo "FAIL last='$1' now='$2' streak=$3 debounce=$4 -> '$got', want '$5'"
    fails=$((fails+1))
  fi
}

# first run: nothing to compare against, never notify
decide_is "" BATT 5 2 noop
# steady state
decide_is AC AC 9 2 noop
decide_is BATT BATT 5 2 noop
# transition, but the debounce counter is not satisfied yet
decide_is AC BATT 1 2 noop
decide_is BATT AC 1 2 noop
decide_is AC BATT 2 3 noop
# transition confirmed
decide_is AC BATT 2 2 send=offline
decide_is BATT AC 2 2 send=online

compose_has() { # state pct needle
  local got
  got="$("$SCRIPT" --compose "$1" "$2" 2>&1)"
  if printf '%s' "$got" | grep -q "$3"; then
    echo "ok   compose $1 $2 contains '$3'"
  else
    echo "FAIL compose $1 $2 = '$got' (want '$3')"
    fails=$((fails+1))
  fi
}

compose_has BATT 83 отключено
compose_has BATT 83 83%
compose_has AC 91 восстановлено

# Retry backoff after a failed send: a failed `hermes send` spawns a whole Python
# process, so retrying every tick on battery is wasteful. Doubling-ish ladder, capped.
backoff_is() { # attempt want_seconds
  local got
  got="$("$SCRIPT" --backoff "$1" 2>&1)"
  if [ "$got" = "$2" ]; then
    echo "ok   backoff($1) -> ${got}s"
  else
    echo "FAIL backoff($1) -> '$got', want '$2'"
    fails=$((fails+1))
  fi
}

backoff_is 1 30
backoff_is 2 60
backoff_is 3 180
backoff_is 4 300
backoff_is 5 600
backoff_is 9 600

# --- delivery path (the loop body) against stub pmset/hermes -----------------
DTMP="$(mktemp -d -t notify-delivery)"
trap 'rm -rf "$DTMP"' EXIT
export DTMP   # the stub pmset/hermes scripts read it from their own environment

cat >"$DTMP/pmset" <<'EOF'
#!/bin/bash
cat "$DTMP/power-now"
EOF
cat >"$DTMP/hermes" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$DTMP/hermes-log"
[ -f "$DTMP/hermes-fail" ] && exit 1
exit 0
EOF
chmod +x "$DTMP/pmset" "$DTMP/hermes"

run_once() { # [count]: that many loop iterations in one process (streak persists)
  local cnt="${1:-1}"
  POWERNOTIFY_TARGET="telegram:test" \
  POWERNOTIFY_STATE_DIR="$DTMP/state" \
  POWERNOTIFY_PMSET="$DTMP/pmset" \
  POWERNOTIFY_HERMES="$DTMP/hermes" \
  POWERNOTIFY_LOG="$DTMP/notify.log" \
  POWERNOTIFY_DEBOUNCE=2 \
  "$SCRIPT" --once "$cnt" >/dev/null 2>&1
}

d_ok()  { echo "ok   delivery: $*"; }
d_bad() { echo "FAIL delivery: $*"; fails=$((fails+1)); }

ac()  { printf "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t80%%; AC attached\n" > "$DTMP/power-now"; }
batt(){ printf "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t80%%; discharging\n" > "$DTMP/power-now"; }

# first run just records the state, sends nothing
rm -rf "$DTMP/state"; ac; run_once
if [ "$(cat "$DTMP/state/power-state" 2>/dev/null)" = "AC" ] && [ ! -s "$DTMP/state/outbox.txt" ]; then
  d_ok "первый запуск записывает состояние и не шлёт сообщение"
else
  d_bad "первый запуск: state=$(cat "$DTMP/state/power-state" 2>/dev/null) outbox=$(cat "$DTMP/state/outbox.txt" 2>/dev/null)"
fi

# debounce: one BATT reading is not enough
batt; run_once
if [ ! -s "$DTMP/state/outbox.txt" ]; then d_ok "debounce: одного замера BATT мало"; else d_bad "debounce: ушло сообщение после одного замера"; fi

# two agreeing readings -> one offline message, outbox drained, state updated
batt; run_once 2
if grep -q "отключено" "$DTMP/hermes-log" && [ ! -s "$DTMP/state/outbox.txt" ] && [ "$(cat "$DTMP/state/power-state" 2>/dev/null)" = "BATT" ]; then
  d_ok "переход AC->BATT: одно сообщение, очередь пуста, состояние BATT"
else
  d_bad "переход AC->BATT: log=$(cat "$DTMP/hermes-log" 2>/dev/null | tr '\n' ' ')"
fi

# failed send keeps the message in the outbox
printf 'AC\n' > "$DTMP/state/power-state"
batt; touch "$DTMP/hermes-fail"; : > "$DTMP/hermes-log"; : > "$DTMP/state/outbox.txt"
run_once 2
if [ -s "$DTMP/state/outbox.txt" ]; then d_ok "сбой отправки: сообщение остаётся в outbox"; else d_bad "сбой отправки: сообщение потеряно"; fi

# successful send drains the outbox
rm -f "$DTMP/hermes-fail"; printf 'тестовое сообщение\n' > "$DTMP/state/outbox.txt"
printf 'AC\n' > "$DTMP/state/power-state"; ac; : > "$DTMP/hermes-log"
run_once
if [ ! -s "$DTMP/state/outbox.txt" ] && grep -q "тестовое сообщение" "$DTMP/hermes-log"; then
  d_ok "успешная отправка: очередь опустошается"
else
  d_bad "успешная отправка: outbox=$(cat "$DTMP/state/outbox.txt" 2>/dev/null) log=$(cat "$DTMP/hermes-log" 2>/dev/null | tr '\n' ' ')"
fi

total=22
if [ "$fails" -eq 0 ]; then echo "PASS ($total/$total)"; exit 0; else echo "FAILED: $fails"; exit 1; fi
