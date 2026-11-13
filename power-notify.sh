#!/bin/bash
# power-notify: Telegram notice when AC power is lost or restored.
#   --decide <last> <now> <streak> <debounce>   pure decision (used by tests)
#   --compose <AC|BATT> <pct>                   message text (used by tests)
#   (no args)                                   daemon loop
#
# Delivery goes through `hermes send` (reuses the gateway's Telegram credentials, no
# agent loop needed). Messages are queued in an outbox first: during a real outage the
# router is usually dead too, so the notice is retried until it gets through and both
# notices arrive in order once the network is back.
set -uo pipefail

PMSET="${POWERNOTIFY_PMSET:-/usr/bin/pmset}"
HERMES="${POWERNOTIFY_HERMES:-$(command -v hermes 2>/dev/null || echo "$HOME/.hermes/hermes-agent/.hermes/bin/hermes")}"
TARGET="${POWERNOTIFY_TARGET:-}"               # required at runtime, e.g. telegram:123456789
STATE_DIR="${POWERNOTIFY_STATE_DIR:-$HOME/.local/state/mac-wakeup}"
STATE_FILE="$STATE_DIR/power-state"
OUTBOX="$STATE_DIR/outbox.txt"
LOG="${POWERNOTIFY_LOG:-$HOME/Library/Logs/mac-wakeup-notify.log}"
INTERVAL="${POWERNOTIFY_INTERVAL:-30}"
DEBOUNCE="${POWERNOTIFY_DEBOUNCE:-2}"          # consecutive agreeing readings
DRY="${POWERNOTIFY_DRY:-0}"

decide() { # last now streak debounce -> send=offline | send=online | noop
  local last="$1" now="$2" streak="$3" debounce="$4"
  if [ -z "$last" ]; then echo noop; return 0; fi          # first run: just record
  if [ "$now" = "$last" ]; then echo noop; return 0; fi    # no change
  if [ "$streak" -lt "$debounce" ]; then echo noop; return 0; fi
  case "$now" in
    BATT) echo send=offline ;;
    AC)   echo send=online ;;
    *)    echo noop ;;
  esac
}

compose() { # state pct
  local state="$1" pct="${2:-?}" host
  host="$(hostname -s 2>/dev/null || echo mac)"
  case "$state" in
    BATT) printf '🔌 Питание отключено — %s работает от батареи (%s%%).' "$host" "$pct" ;;
    AC)   printf '⚡ Питание восстановлено — %s снова на зарядке (%s%%).' "$host" "$pct" ;;
  esac
}

backoff() { # attempt -> seconds to wait before the next send attempt
  case "${1:-1}" in
    1) echo 30 ;;
    2) echo 60 ;;
    3) echo 180 ;;
    4) echo 300 ;;
    *) echo 600 ;;
  esac
}

case "${1:-}" in
  --decide)  decide "${2:-}" "${3:-}" "${4:-0}" "${5:-2}"; exit 0 ;;
  --compose) compose "${2:?state}" "${3:-}"; exit 0 ;;
  --backoff) backoff "${2:-1}"; exit 0 ;;
  --once)    : ;;   # one loop iteration, then exit (used by tests)
  "")        : ;;   # no args: run the daemon loop
  *)         echo "usage: $0 [--decide last now streak debounce | --compose state pct | --backoff attempt | --once]" >&2; exit 2 ;;
esac

# ---- runtime ----
# No baked-in default on purpose: a hardcoded chat id would ship the maintainer's
# Telegram id to everyone who clones this repo.
if [ -z "$TARGET" ] && [ "$DRY" != 1 ]; then
  echo "power-notify: POWERNOTIFY_TARGET is not set (format: telegram:ЧИСЛО)." >&2
  echo "  discover it with: hermes send --list telegram" >&2
  exit 2
fi
mkdir -p "$STATE_DIR" "$(dirname "$LOG")"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || true; }

read_state() {
  if "$PMSET" -g batt 2>/dev/null | head -1 | grep -q "AC Power"; then echo AC; else echo BATT; fi
}
read_pct() { "$PMSET" -g batt 2>/dev/null | grep -o '[0-9][0-9]*%' | head -1 | tr -d '%'; }

send() { # $1 = message
  if [ "$DRY" = 1 ]; then printf 'DRY send: %s\n' "$1"; return 0; fi
  "$HERMES" send --to "$TARGET" --quiet "$1" >/dev/null 2>&1
}

enqueue() { printf '%s\n' "$1" >>"$OUTBOX"; }

NEXT_FLUSH=0
ATTEMPTS=0
flush() { # $1 = now (epoch)
  [ -s "$OUTBOX" ] || return 0
  [ "$1" -ge "$NEXT_FLUSH" ] || return 0
  local queue rest line blocked=0
  queue="$(mktemp -t powernotify)"
  rest="$(mktemp -t powernotify)"
  cp "$OUTBOX" "$queue"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if [ "$blocked" = 1 ]; then printf '%s\n' "$line" >>"$rest"; continue; fi
    if send "$line"; then log "sent: $line"; else
      blocked=1
      printf '%s\n' "$line" >>"$rest"
    fi
  done <"$queue"
  # atomic replace: the outbox is never truncated in place, so a kill mid-send
  # cannot lose messages that were already accepted.
  mv "$rest" "$OUTBOX"
  rm -f "$queue"
  if [ "$blocked" = 1 ]; then
    # Every failed attempt is a whole Python process — back off instead of hammering.
    ATTEMPTS=$((ATTEMPTS + 1))
    NEXT_FLUSH=$(( $1 + $(backoff "$ATTEMPTS") ))
    log "send failed (attempt $ATTEMPTS), next try in $(backoff "$ATTEMPTS")s"
  else
    ATTEMPTS=0
  fi
}

last="$(cat "$STATE_FILE" 2>/dev/null || true)"
streak=0
cand=""
log "power-notify start pid=$$ last='${last}' interval=${INTERVAL}s debounce=${DEBOUNCE} dry=${DRY}"

once() {
  local now_state msg
  now_state="$(read_state)"
  if [ -z "$last" ]; then
    last="$now_state"; printf '%s\n' "$last" >"$STATE_FILE"
    log "init state=$last"
  elif [ "$now_state" = "$last" ]; then
    streak=0; cand=""
  else
    if [ "$now_state" = "$cand" ]; then streak=$((streak + 1)); else cand="$now_state"; streak=1; fi
    if [ "$(decide "$last" "$now_state" "$streak" "$DEBOUNCE")" != "noop" ]; then
      msg="$(compose "$now_state" "$(read_pct)")"
      enqueue "$msg"
      log "transition ${last}->${now_state} queued: $msg"
      last="$now_state"; printf '%s\n' "$last" >"$STATE_FILE"
      streak=0; cand=""
      flush "$(date +%s)"            # try immediately
    fi
  fi
  flush "$(date +%s)"
}

if [ "${1:-}" = "--once" ]; then
  n="${2:-1}"
  i=0
  while [ "$i" -lt "$n" ]; do
    once
    i=$((i + 1))
  done
  exit 0
fi

while true; do
  once
  sleep "$INTERVAL"
done
