#!/bin/bash
# Install power-notify as a user LaunchAgent.
# The script is copied to ~/.local/bin because a launchd agent cannot read ~/Documents
# (TCC) — same class of failure as root reading it during `sudo install`.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.local/bin"
PLIST="$HOME/Library/LaunchAgents/local.mac-wakeup.notify.plist"
LABEL="local.mac-wakeup.notify"
TARGET="${POWERNOTIFY_TARGET:-telegram:ЧИСЛО}"
INTERVAL="${POWERNOTIFY_INTERVAL:-30}"
DEBOUNCE="${POWERNOTIFY_DEBOUNCE:-2}"

"$HERE/test_notify.sh"

mkdir -p "$BIN_DIR" "$HOME/Library/Logs" "$HOME/.local/state/mac-wakeup"
install -m 755 "$HERE/power-notify.sh" "$BIN_DIR/power-notify.sh"
echo "installed $BIN_DIR/power-notify.sh"

cat >"$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$BIN_DIR/power-notify.sh</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>POWERNOTIFY_TARGET</key><string>$TARGET</string>
    <key>POWERNOTIFY_INTERVAL</key><string>$INTERVAL</string>
    <key>POWERNOTIFY_DEBOUNCE</key><string>$DEBOUNCE</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/mac-wakeup-notify.err</string>
</dict>
</plist>
PLIST_EOF

plutil -lint "$PLIST"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 3
launchctl print "gui/$(id -u)/$LABEL" | grep -E "state =|pid =" | head -2
