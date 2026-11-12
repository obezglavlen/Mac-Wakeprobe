#!/bin/sh
# Measurement A: prove that a scheduled wake fires, and see whether it is a
# full Wake or a DarkWake. Must be run as root:  sudo ~/Documents/mac-wakeup/tools/measure-sleep.sh
set -u
LABEL="hermes-test"
echo "[1/3] cancelling any stale $LABEL events"
for d in $(/usr/bin/pmset -g sched | sed -nE "s/.*wake at ([0-9]{2}\/[0-9]{2}\/[0-9]{2} [0-9:]{8}) by '$LABEL'.*/\1/p"); do
  /usr/bin/pmset schedule cancel wake "$d" "$LABEL" && echo "     cancelled $d"
done

TS="$(/bin/date -v+90S '+%m/%d/%y %H:%M:%S')"
echo "[2/3] arming scheduled wake at $TS"
/usr/bin/pmset schedule wake "$TS" "$LABEL" || exit 1

echo "[3/3] requesting sleep now; the Mac will wake up again at or just after $TS"
/usr/bin/pmset sleepnow
/bin/date '+      sleepnow returned at %H:%M:%S'
