#!/bin/sh
# Crash test: kill the gateway process tree and verify launchd's KeepAlive brings it back.
# Submitted via `launchctl submit` so it is not a child of the gateway it kills.
LOG="/Users/mykyta/.hermes/wakeprobe/crashtest.log"
HERMES="/Users/mykyta/.hermes/hermes-agent/.hermes/bin/hermes"
DOM="gui/$(id -u)/ai.hermes.gateway"

{
  echo "=== $(date '+%F %T') crashtest start"
  sleep 5

  SUP="$(launchctl print "$DOM" 2>&1 | sed -n 's/.*pid = \([0-9]*\).*/\1/p' | head -1)"
  echo "supervised pid before: $SUP"
  echo "runs before: $(launchctl print "$DOM" 2>&1 | grep 'runs =' | tr -d '\t')"

  KIDS="$(pgrep -P "$SUP" 2>/dev/null | tr '\n' ' ')"
  echo "children to kill: $KIDS"
  echo "--- simulating a hard crash ---"
  kill -9 $KIDS "$SUP" 2>/dev/null

  sleep 20
  echo "--- 20s after the crash ---"
  launchctl print "$DOM" 2>&1 | grep -E 'state =|pid =|runs =|last exit' | head -4

  if ! launchctl print "$DOM" 2>&1 | grep -q "state = running"; then
    echo "--- NOT running: falling back to kickstart ---"
    launchctl kickstart -k "$DOM" 2>&1
    sleep 20
    launchctl print "$DOM" 2>&1 | grep -E 'state =|pid =|runs =' | head -3
  fi

  echo "--- hermes gateway status ---"
  "$HERMES" gateway status 2>&1 | head -6
  echo "=== $(date '+%F %T') crashtest done"
} >>"$LOG" 2>&1

launchctl remove local.hermes.crashtest 2>/dev/null
exit 0
