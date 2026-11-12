#!/bin/bash
# hermes-wakeprobe
#   --plan <file>   read `pmset -g sched` output from <file>, print the pmset
#                   commands needed to keep WANT FUTURE probe wakes queued:
#                   stale (already past) events are cancelled, missing future
#                   ones are armed.
#   (no args)       daemon loop: re-arm every INTERVAL seconds, log the power state.
# It holds NO power assertion. Staying awake is Vorssaint's job: it keeps the
# Mac awake while connected to AC, so a probe wake on restored power is enough.
set -uo pipefail

LABEL="hermes-wakeprobe"
PMSET="/usr/bin/pmset"
DATE="/bin/date"
STEP_MIN="${WAKEPROBE_STEP_MIN:-10}"     # spacing between probe wakes, minutes
WANT="${WAKEPROBE_WANT:-3}"              # how many future probe wakes to keep queued
INTERVAL="${WAKEPROBE_INTERVAL:-60}"     # daemon tick, seconds
GRACE="${WAKEPROBE_GRACE:-30}"           # seconds still counted as "future" (clock skew)
LOG="${WAKEPROBE_LOG:-/var/log/hermes-wakeprobe.log}"

count_ours() { grep -c "by '$LABEL'" || true; }

# "11/12/26 16:08:46" -> epoch seconds (BSD date -j)
to_epoch() { "$DATE" -j -f "%m/%d/%y %H:%M:%S" "$1" +%s 2>/dev/null; }

plan() { # $1 = file containing `pmset -g sched` output
  local sched line ts ep now future i off
  sched="$(cat "$1")"
  now="$("$DATE" +%s)"
  future=0

  # Pass 1: classify our events. Stale ones are cancelled with their own
  # timestamp (a past event never fires and must not inflate the queue).
  while IFS= read -r line; do
    case "$line" in
      *"by '$LABEL'"*) ;;
      *) continue ;;
    esac
    ts="$(printf '%s\n' "$line" | sed -E 's/.*wake at ([0-9][0-9]\/[0-9][0-9]\/[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]).*/\1/')"
    ep="$(to_epoch "$ts")"
    if [ -z "${ep:-}" ]; then
      continue                      # unparsable: leave it alone rather than cancel blind
    fi
    if [ "$ep" -gt "$((now + GRACE))" ]; then
      future=$((future + 1))
    else
      printf '%s schedule cancel wake "%s" %s\n' "$PMSET" "$ts" "$LABEL"
    fi
  done <<<"$sched"

  # Pass 2: arm what is missing.
  i="$future"
  while [ "$i" -lt "$WANT" ]; do
    off=$(( STEP_MIN * (i + 1) ))
    printf '%s schedule wake "%s" %s\n' \
      "$PMSET" "$("$DATE" -v+"${off}"M '+%m/%d/%y %H:%M:%S')" "$LABEL"
    i=$((i + 1))
  done
}

if [ "${1:-}" = "--plan" ]; then
  plan "${2:?usage: wakeprobe.sh --plan <file>}"
  exit 0
fi

log() { printf '%s %s\n' "$("$DATE" '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || true; }

tick() {
  local tmp n power pct line
  tmp="$(mktemp -t wakeprobe)"
  "$PMSET" -g sched >"$tmp" 2>/dev/null || :
  n="$(count_ours <"$tmp")"
  if "$PMSET" -g batt | head -1 | grep -q "AC Power"; then power=AC; else power=BATT; fi
  pct="$("$PMSET" -g batt | grep -o '[0-9][0-9]*%' | head -1 | tr -d '%')"
  log "tick power=${power} battery=${pct:-?}% ours=${n}"
  plan "$tmp" | while IFS= read -r line; do
    [ -z "$line" ] && continue
    if /bin/bash -c "$line" 2>>"$LOG"; then
      log "done: ${line#*pmset }"
    else
      log "ERROR: ${line}"
    fi
  done
  rm -f "$tmp"
}

log "wakeprobe start pid=$$ step=${STEP_MIN}m want=${WANT} interval=${INTERVAL}s"
while true; do
  tick
  /bin/sleep "$INTERVAL"
done
