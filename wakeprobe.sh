#!/bin/bash
# hermes-wakeprobe
#   --plan <file>   read `pmset -g sched` output from <file>, print the pmset
#                   commands that are missing to keep WANT probe wakes queued.
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
LOG="${WAKEPROBE_LOG:-/var/log/hermes-wakeprobe.log}"

count_ours() { grep -c "by '$LABEL'" || true; }

plan() { # $1 = file containing `pmset -g sched` output
  local sched n i off
  sched="$(cat "$1")"
  n="$(printf '%s\n' "$sched" | count_ours)"
  i="$n"
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
  log "tick power=${power} battery=${pct:-?}% queued=${n}"
  plan "$tmp" | while IFS= read -r line; do
    [ -z "$line" ] && continue
    if /bin/bash -c "$line" 2>>"$LOG"; then
      log "armed: ${line#*schedule }"
    else
      log "ERROR arming: ${line}"
    fi
  done
  rm -f "$tmp"
}

log "wakeprobe start pid=$$ step=${STEP_MIN}m want=${WANT} interval=${INTERVAL}s"
while true; do
  tick
  /bin/sleep "$INTERVAL"
done
