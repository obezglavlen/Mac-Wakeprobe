#!/bin/bash
# Tests for: wakeprobe.sh --plan <file-with-pmset-g-sched-output>
# Output lines are pmset commands:
#   "/usr/bin/pmset schedule cancel wake \"<time>\" hermes-wakeprobe"  -> drop a stale event
#   "/usr/bin/pmset schedule wake \"<time>\" hermes-wakeprobe"         -> arm a future probe
# Only FUTURE events count as queued; events whose time already passed are cancelled,
# because a stale event never fires and would otherwise inflate the queue forever.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/wakeprobe.sh"
fails=0

count_wake()   { printf '%s\n' "$1" | grep -c "schedule wake .* hermes-wakeprobe$" || true; }
count_cancel() { printf '%s\n' "$1" | grep -c "schedule cancel wake .* hermes-wakeprobe$" || true; }

expect() { # fixture want_wake want_cancel
  local out w c
  out="$("$SCRIPT" --plan "$HERE/fixtures/$1" 2>&1)"
  w="$(count_wake "$out")"
  c="$(count_cancel "$out")"
  if [ "$w" -eq "$2" ] && [ "$c" -eq "$3" ]; then
    echo "ok   $1 -> wake=$w cancel=$c"
  else
    echo "FAIL $1 -> wake=$w cancel=$c, want wake=$2 cancel=$3"
    printf '%s\n' "$out" | sed 's/^/     | /'
    fails=$((fails+1))
  fi
}

expect sched_empty.txt 3 0            # nothing queued
expect sched_apple_only.txt 3 0       # Apple's alarms are not ours
expect sched_one_ours.txt 2 0         # one future event -> arm two more
expect sched_three_ours.txt 0 0       # queue full
expect sched_stale.txt 3 3            # all three already passed -> cancel them, arm three
expect sched_mixed.txt 2 2            # two stale + one future -> cancel two, arm two

# Shape of the emitted commands, and no duplicate wake times.
out="$("$SCRIPT" --plan "$HERE/fixtures/sched_empty.txt")"
if printf '%s\n' "$out" | grep -qv "schedule wake .* hermes-wakeprobe$"; then
  echo "FAIL malformed command line in output"; fails=$((fails+1))
else
  echo "ok   all lines are 'pmset schedule wake \"<time>\" hermes-wakeprobe'"
fi
times="$(printf '%s\n' "$out" | sed -E 's/.*wake "([^"]+)".*/\1/' | sort -u | wc -l | tr -d ' ')"
if [ "$times" -eq 3 ]; then echo "ok   three distinct wake times"; else
  echo "FAIL distinct wake times = $times, want 3"; fails=$((fails+1)); fi

# A stale event must be cancelled with its own original timestamp, not with "now".
out="$("$SCRIPT" --plan "$HERE/fixtures/sched_stale.txt")"
if printf '%s\n' "$out" | grep -q 'schedule cancel wake "01/01/20 10:10:00" hermes-wakeprobe'; then
  echo "ok   stale event cancelled with its original timestamp"
else
  echo "FAIL stale cancel does not carry the original timestamp"; fails=$((fails+1))
fi

if [ "$fails" -eq 0 ]; then echo "PASS (10/10)"; exit 0; else echo "FAILED: $fails"; exit 1; fi
