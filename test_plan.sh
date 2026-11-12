#!/bin/bash
# Tests for: wakeprobe.sh --plan <file-with-pmset-g-sched-output>
# Prints zero or more pmset command lines, one per missing wake event.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/wakeprobe.sh"
fails=0

expect_count() { # fixture expected_count
  local out n
  out="$("$SCRIPT" --plan "$HERE/fixtures/$1" 2>&1)"
  n="$(printf '%s' "$out" | grep -c . )"
  if [ "$n" -eq "$2" ]; then
    echo "ok   $1 -> $n command(s)"
  else
    echo "FAIL $1 -> $n command(s), want $2"
    printf '%s\n' "$out" | sed 's/^/     | /'
    fails=$((fails+1))
  fi
}

expect_count sched_empty.txt 3
expect_count sched_apple_only.txt 3     # Apple's own alarms must not count as ours
expect_count sched_one_ours.txt 2
expect_count sched_three_ours.txt 0

# Every emitted line must be a pmset schedule command owned by us, and no two
# lines may carry the same timestamp.
out="$("$SCRIPT" --plan "$HERE/fixtures/sched_empty.txt")"
if printf '%s\n' "$out" | grep -qv "schedule wake .* hermes-wakeprobe$"; then
  echo "FAIL malformed command line in output"; fails=$((fails+1))
else
  echo "ok   all lines are 'pmset schedule wake \"<time>\" hermes-wakeprobe'"
fi
times="$(printf '%s\n' "$out" | sed -E 's/.*wake "([^"]+)".*/\1/' | sort -u | wc -l | tr -d ' ')"
if [ "$times" -eq 3 ]; then echo "ok   three distinct wake times"; else
  echo "FAIL distinct wake times = $times, want 3"; fails=$((fails+1)); fi

if [ "$fails" -eq 0 ]; then echo "PASS (6/6)"; exit 0; else echo "FAILED: $fails"; exit 1; fi
