#!/bin/bash
# Install the wake-probe root daemon. Safe to re-run (bootout + bootstrap).
#
#   ./install-wakeprobe.sh              -> runs the tests, asks for sudo once
#   sudo ./install-wakeprobe.sh         -> install from /tmp (needs the copies below)
#
# Root cannot read ~/Documents (TCC), so the files are staged in /tmp as the user first.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="local.hermes.wakeprobe"
SRC_PLIST="$HERE/local.hermes.wakeprobe.plist"
DST_PLIST="/Library/LaunchDaemons/$LABEL.plist"
DST_BIN="/usr/local/bin/hermes-wakeprobe.sh"
STAGE_BIN="/tmp/wakeprobe.sh"
STAGE_PLIST="/tmp/local.hermes.wakeprobe.plist"
STAGE_SELF="/tmp/install-wakeprobe.sh"

if [ "$(id -u)" -ne 0 ]; then
  echo "== tests =="
  "$HERE/test_plan.sh"
  echo "== staging for root (TCC: root cannot read ~/Documents) =="
  cp "$HERE/wakeprobe.sh" "$STAGE_BIN"
  cp "$SRC_PLIST" "$STAGE_PLIST"
  # Stage ourselves too: root cannot even READ a script that lives in ~/Documents (TCC).
  cp "$0" "$STAGE_SELF"
  echo "staged $STAGE_BIN, $STAGE_PLIST, $STAGE_SELF"
  echo "== installing (sudo) =="
  exec sudo /bin/bash "$STAGE_SELF"
fi

for f in "$STAGE_BIN" "$STAGE_PLIST"; do
  [ -f "$f" ] || { echo "missing $f — run ./install-wakeprobe.sh as your user, not with sudo directly" >&2; exit 1; }
done

install -o root -g wheel -m 755 "$STAGE_BIN" "$DST_BIN"
install -o root -g wheel -m 644 "$STAGE_PLIST" "$DST_PLIST"
plutil -lint "$DST_PLIST"

launchctl bootout "system/$LABEL" 2>/dev/null || true
launchctl bootstrap system "$DST_PLIST"
sleep 8

echo "== result =="
launchctl print "system/$LABEL" | grep -E "state =|pid =" | head -2
echo "queued ours: $(pmset -g sched | grep -c hermes-wakeprobe)  (expect 3)"
pmset -g sched | grep hermes-wakeprobe
