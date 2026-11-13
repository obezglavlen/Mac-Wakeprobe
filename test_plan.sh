#!/bin/bash
# Tests for: wakeprobe.sh --plan <file-with-pmset-g-sched-output>
# Output lines are pmset commands:
#   "/usr/bin/pmset schedule cancel wake \"<time>\" hermes-wakeprobe"  -> drop a stale event
#   "/usr/bin/pmset schedule wake \"<time>\" hermes-wakeprobe"         -> arm a future probe
# Only events within the probe horizon (now .. now + STEP_MIN*WANT + GRACE) count as
# queued; past events are cancelled, far-future artifacts are ignored.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/wakeprobe.sh"
fails=0

TMP="$(mktemp -d -t wakeprobe-test)"
trap 'rm -rf "$TMP"' EXIT

# `pmset -g sched` prints a four-digit year; `date -v+NM` shifts N minutes.
ts() {
  local v="$1"
  case "$v" in -*) ;; *) v="+$v" ;; esac
  date -v"${v}"M '+%m/%d/%Y %H:%M:%S'
}
ours() { printf ' [0]  wake at %s by '\''hermes-wakeprobe'\''\n' "$(ts "$1")"; }
apple(){ printf ' [1]  wake at %s by '\''com.apple.alarm.user-invisible-com.apple.acmd.alarm'\''\n' "$(ts "$1")"; }
mkfix() { # name, then minute offsets of our events (relative to now)
  local name="$1"; shift
  { echo "Scheduled power events:"; for m in "$@"; do ours "$m"; done; } >"$TMP/$name"
}

mkfix empty.txt
mkfix one_ours.txt 10
mkfix three_ours.txt 10 20 30
mkfix mixed.txt -10 -20 10
mkfix far.txt 100000 100010 100020
{ echo "Scheduled power events:"; apple 60; } >"$TMP/apple_only.txt"

# stale.txt: all three in the past; capture the oldest so we can assert the cancel
# uses its own two-digit-year timestamp, not "now".
s30="$(ts -30)"
{ echo "Scheduled power events:"; ours -10; ours -20; printf ' [0]  wake at %s by '\''hermes-wakeprobe'\''\n' "$s30"; } >"$TMP/stale.txt"
exp_cancel="$(date -j -f '%m/%d/%Y %H:%M:%S' "$s30" '+%m/%d/%y %H:%M:%S')"

count_wake()   { printf '%s\n' "$1" | grep -c "schedule wake .* hermes-wakeprobe$" || true; }
count_cancel() { printf '%s\n' "$1" | grep -c "schedule cancel wake .* hermes-wakeprobe$" || true; }

expect() { # file want_wake want_cancel
  local out w c
  out="$("$SCRIPT" --plan "$TMP/$1" 2>&1)"
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

expect empty.txt 3 0            # nothing queued
expect apple_only.txt 3 0       # Apple's alarms are not ours
expect one_ours.txt 2 0         # one future event -> arm two more
expect three_ours.txt 0 0       # queue full
expect stale.txt 3 3            # all three already passed -> cancel them, arm three
expect mixed.txt 2 2            # two stale + one future -> cancel two, arm two
expect far.txt 3 0              # far-future artifacts are ignored, not counted

# Shape of the emitted commands, and no duplicate wake times.
out="$("$SCRIPT" --plan "$TMP/empty.txt")"
if printf '%s\n' "$out" | grep -qv "schedule wake .* hermes-wakeprobe$"; then
  echo "FAIL malformed command line in output"; fails=$((fails+1))
else
  echo "ok   all lines are 'pmset schedule wake \"<time>\" hermes-wakeprobe'"
fi
times="$(printf '%s\n' "$out" | sed -E 's/.*wake "([^"]+)".*/\1/' | sort -u | wc -l | tr -d ' ')"
if [ "$times" -eq 3 ]; then echo "ok   three distinct wake times"; else
  echo "FAIL distinct wake times = $times, want 3"; fails=$((fails+1)); fi

# A stale event must be cancelled with its own original two-digit-year timestamp.
out="$("$SCRIPT" --plan "$TMP/stale.txt")"
if printf '%s\n' "$out" | grep -q "schedule cancel wake \"$exp_cancel\" hermes-wakeprobe"; then
  echo "ok   stale event cancelled with its original timestamp, two-digit year"
else
  echo "FAIL stale cancel: want '$exp_cancel'"
  printf '%s\n' "$out" | sed 's/^/     | /'; fails=$((fails+1))
fi

if [ "$fails" -eq 0 ]; then echo "PASS (10/10)"; exit 0; else echo "FAILED: $fails"; exit 1; fi