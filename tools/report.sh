#!/bin/bash
# Collects all the evidence for the wake-on-power chain. Run WITHOUT sudo;
# it only asks for the root-owned log via sudo -n first, then falls back.
set -u
echo "===== now ====="
date '+%F %T %Z'

echo
echo "===== power ====="
pmset -g batt | tail -1

echo
echo "===== scheduled wakes (expect 3 hermes-wakeprobe) ====="
pmset -g sched
echo "count: $(pmset -g sched | grep -c 'hermes-wakeprobe')"

echo
echo "===== last sleep states (look for 'Using BATT') ====="
pmset -g log | grep "Entering Sleep state" | tail -4

echo
echo "===== last real wakes (Wake = usable, DarkWake = session stays suspended) ====="
pmset -g log | grep -E "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} [+-][0-9]{4} (Wake|DarkWake) " | tail -5

echo
echo "===== assertion holders right now ====="
pmset -g assertions | grep -E "^\s+pid .*(PreventUserIdleSystemSleep|PreventSystemSleep)" | head -5

echo
echo "===== gateway ====="
hermes gateway status 2>&1 | head -5

echo
echo "===== wakeprobe daemon ====="
launchctl print system/local.hermes.wakeprobe 2>&1 | grep -E "state =|pid =" | head -3
echo "--- /var/log/hermes-wakeprobe.log (last 12) ---"
sudo -n tail -12 /var/log/hermes-wakeprobe.log 2>/dev/null || echo "(run: sudo tail -12 /var/log/hermes-wakeprobe.log)"
