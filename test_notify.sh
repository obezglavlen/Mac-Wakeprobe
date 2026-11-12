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

total=11
if [ "$fails" -eq 0 ]; then echo "PASS ($total/$total)"; exit 0; else echo "FAILED: $fails"; exit 1; fi
