#!/bin/sh
# One-shot takeover: hand the gateway over from the manually started process to
# the launchd agent ai.hermes.gateway (which has RunAtLoad + KeepAlive).
# Submitted via `launchctl submit` so it survives the gateway being killed.
LOG="${TAKEOVER_LOG:-$HOME/Library/Logs/mac-wakeup-takeover.log}"
HERMES="${HERMES:-$(command -v hermes 2>/dev/null || echo "$HOME/.hermes/hermes-agent/.hermes/bin/hermes")}"
UID_NUM="$(id -u)"

{
  echo "=== $(date '+%F %T') takeover start"
  sleep 20
  "$HERMES" gateway restart --yes 2>&1
  echo "restart exit=$?"
  sleep 25

  STATE="$(launchctl print "gui/$UID_NUM/ai.hermes.gateway" 2>&1 | grep -E 'state =|pid =' | head -3)"
  echo "--- launchd state ---"
  echo "$STATE"
  if ! echo "$STATE" | grep -q "state = running"; then
    echo "--- falling back to kickstart ---"
    launchctl kickstart -k "gui/$UID_NUM/ai.hermes.gateway" 2>&1
    sleep 20
    launchctl print "gui/$UID_NUM/ai.hermes.gateway" 2>&1 | grep -E 'state =|pid =' | head -3
  fi

  echo "--- hermes gateway status ---"
  "$HERMES" gateway status 2>&1 | head -8
  echo "=== $(date '+%F %T') takeover done"
} >>"$LOG" 2>&1

# `launchctl submit` re-launches a finished job: remove ourselves so this runs once.
launchctl remove local.hermes.takeover 2>/dev/null
exit 0
