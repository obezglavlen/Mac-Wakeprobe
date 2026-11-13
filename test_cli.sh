#!/bin/bash
# Tests for ./macwake.
#
# Two kinds of checks, both safe to run anywhere:
#   1. MACWAKE_DRY=1 — every mutating command is printed as "would: ..." instead of
#      being executed, so the test asserts on the planned command sequence.
#   2. `status` — parsed against stub `launchctl`/`pmset` on PATH, so the assertions
#      do not depend on what this particular Mac has installed right now.
#
# The point of the dry-run assertions is the invariant the CLI exists for:
# probes and holder are independent — `disable` never prints a gui/ line,
# `hold off` never prints a system/ line.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CLI="$HERE/macwake"
fails=0

ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
has() {
  case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 (not found: $2)" ;; esac
}
hasnt() {
  case "$1" in *"$2"*) bad "$3 (unexpected: $2)" ;; *) ok "$3" ;; esac
}
count_of() { printf '%s\n' "$1" | grep -c -- "$2"; }
eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

TMP="$(mktemp -d -t macwake-test)"
trap 'rm -rf "$TMP"' EXIT
STUB="$TMP/stubs"; FIX="$TMP/fix"
mkdir -p "$STUB" "$FIX"

cp "$HERE/fixtures/sched_three_ours.txt" "$FIX/sched_three_ours.txt"
cat >"$FIX/assertions.txt" <<'EOF'
2026-11-13 11:00:00 +0200
Assertion status system-wide:
   PreventUserIdleSystemSleep     1
Listed by owning process:
   pid 4343(caffeinate): [0x0001] 00:01:00 PreventSystemSleep named: "caffeinate command-line tool"
   pid 843(Vorssaint): [0x0002] 01:00:00 PreventUserIdleSystemSleep named: "Vorssaint: keep the Mac awake"
EOF

cat >"$STUB/pmset" <<'EOF'
#!/bin/bash
case "$*" in
  "-g sched")      cat "${TEST_FIXTURES:?}/sched_three_ours.txt" ;;
  "-g assertions") cat "${TEST_FIXTURES:?}/assertions.txt" ;;
  "-g batt")       printf "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t80%%; AC attached\n" ;;
  "-g")            printf ' sleep                1 (sleep prevented by caffeinate, Vorssaint)\n' ;;
  *)               exit 0 ;;
esac
EOF

cat >"$STUB/launchctl" <<'EOF'
#!/bin/bash
case "$1" in
  print)
    case "$2" in
      system/local.hermes.wakeprobe) printf '\tstate = running\n\tpid = 4242\n' ;;
      gui/*local.mac-wakeup.hold)    printf '\tstate = running\n\tpid = 4343\n' ;;
      gui/*local.mac-wakeup.notify)  printf '\tstate = running\n\tpid = 4444\n' ;;
      *) printf 'Could not find service\n'; exit 1 ;;
    esac ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$STUB/pmset" "$STUB/launchctl"

stub_run() { # runs the CLI with stubbed launchctl/pmset
  TEST_FIXTURES="$FIX" PATH="$STUB:$PATH" "$CLI" "$@" 2>&1
}
dry() { # runs the CLI in dry-run with stubbed pmset
  TEST_FIXTURES="$FIX" MACWAKE_DRY=1 PATH="$STUB:$PATH" "$CLI" "$@" 2>&1
}

# --- interface ---------------------------------------------------------------
out="$("$CLI" version 2>&1)"; has "$out" "macwake 1.0.0" "version prints the version"
out="$("$CLI" help 2>&1)";   has "$out" "macwake hold on|off|status" "help prints the commands"
"$CLI" nonsense >/dev/null 2>&1; eq "$?" "1" "unknown command -> exit 1"
dry install --holder bogus >/dev/null 2>&1; eq "$?" "1" "install --holder bogus -> exit 1"
dry install --step x >/dev/null 2>&1; eq "$?" "1" "install --step x -> exit 1"
dry install --step >/dev/null 2>&1; eq "$?" "1" "install --step with no value -> exit 1 (no hang)"
dry notify on --target >/dev/null 2>&1; eq "$?" "1" "notify --target with no value -> exit 1 (no hang)"

# --- status parsing against stubs -------------------------------------------
out="$(stub_run status)"
has "$out" "probes:   running (pid 4242)" "status: probes running"
has "$out" "queued 3 of" "status: queue from the fixture = 3"
has "$out" "holder:   caffeinate holds PreventSystemSleep (pid 4343)" "status: caffeinate holds"
has "$out" "notify:   running (pid 4444)" "status: notifier running"
has "$out" "power:    Now drawing from 'AC Power'" "status: power source"
has "$out" "Vorssaint" "status: sees the second holder"

# same check, but with a pmset whose output dwarfs the pipe buffer: an early `grep -q`
# would SIGPIPE it and (with `pipefail`) report "no holder" on a Mac that has one.
mkdir -p "$TMP/stubs_big"
cp "$STUB/launchctl" "$TMP/stubs_big/launchctl"
cat >"$TMP/stubs_big/pmset" <<'EOF'
#!/bin/bash
case "$*" in
  "-g assertions")
    cat "${TEST_FIXTURES:?}/assertions.txt"
    yes '   pid 999(noise): [0x0] 00:00:00 PreventUserIdleSystemSleep named: "filler"' | head -2000
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/stubs_big/pmset"
out="$(TEST_FIXTURES="$FIX" PATH="$TMP/stubs_big:$PATH" "$CLI" hold status 2>&1)"
has "$out" "holding:  yes" "hold status: large pmset output does not turn the holder into 'no'"

# --- probes on/off never touch the holder ------------------------------------
out="$(dry disable)"
has "$out" "would: launchctl bootout system/local.hermes.wakeprobe" "disable: boots the daemon out"
has "$out" "would: launchctl disable system/local.hermes.wakeprobe" "disable: turns autostart off"
eq "$(count_of "$out" 'would: pmset schedule cancel wake')" "3" "disable: removes all 3 events"
hasnt "$out" "gui/" "disable: does not touch holder/notifier"

out="$(dry enable)"
has "$out" "would: launchctl enable system/local.hermes.wakeprobe" "enable: turns autostart on"
has "$out" "would: launchctl bootstrap system /Library/LaunchDaemons/local.hermes.wakeprobe.plist" "enable: boots the daemon"
hasnt "$out" "gui/" "enable: does not touch holder/notifier"

out="$(dry disable --all)"
has "$out" "would: launchctl bootout gui/" "disable --all: removes the holder"
has "$out" "local.mac-wakeup.notify" "disable --all: removes the notifier"

# --- holder on/off never touches the probes ---------------------------------
out="$(dry hold on)"
has "$out" "would: write plist" "hold on: writes the plist"
has "$out" "(caffeinate -s)" "hold on: holder = caffeinate -s"
has "$out" "would: launchctl bootstrap gui/" "hold on: boots the agent"
hasnt "$out" "system/" "hold on: probes untouched"

out="$(dry hold off)"
has "$out" "would: launchctl bootout gui/" "hold off: removes the agent"
has "$out" "would: launchctl disable gui/" "hold off: autostart off"
hasnt "$out" "system/" "hold off: probes untouched"
has "$out" "probes untouched: 3" "hold off: reports that probes are untouched"

out="$(dry notify off)"
has "$out" "local.mac-wakeup.notify" "notify off: removes the notifier"
hasnt "$out" "system/" "notify off: probes untouched"

# notify on --target must actually change the target (regression: it used to no-op)
out="$(dry notify on --target telegram:777)"
has "$out" "would: write plist $HOME/Library/LaunchAgents/local.mac-wakeup.notify.plist (target=telegram:777" "notify on --target rewrites the plist with the new target"

# --- install ----------------------------------------------------------------
out="$(dry install --no-test --notify telegram:12345)"
has "$out" "would: write plist $HOME/Library/LaunchAgents/local.mac-wakeup.notify.plist (target=telegram:12345" "install: notifier plist with the target"
has "$out" "would: write plist $HOME/Library/LaunchAgents/local.mac-wakeup.hold.plist (caffeinate -s)" "install: holder plist"
has "$out" ".local/bin/macwake" "install: puts the CLI itself in ~/.local/bin"
has "$out" "would: write plist /Library/LaunchDaemons/local.hermes.wakeprobe.plist (step=12 want=3)" "install: default daemon plist"
has "$out" "would: launchctl bootstrap system /Library/LaunchDaemons/local.hermes.wakeprobe.plist" "install: boots the daemon"

out="$(dry install --no-test --no-notify --holder none --step 7 --want 2)"
has "$out" "would: write plist /Library/LaunchDaemons/local.hermes.wakeprobe.plist (step=7 want=2)" "install: --step/--want reach the plist"
hasnt "$out" "would: write plist $HOME/Library/LaunchAgents/local.mac-wakeup.notify.plist" "install --no-notify: does not write the notifier plist"
hasnt "$out" "would: write plist $HOME/Library/LaunchAgents/local.mac-wakeup.hold.plist" "install --holder none: does not write the holder plist"

# --- uninstall --------------------------------------------------------------
out="$(dry uninstall)"
has "$out" "would: rm -f $HOME/Library/LaunchAgents/local.mac-wakeup.hold.plist" "uninstall: removes the holder plist"
has "$out" "would: rm -f $HOME/Library/LaunchAgents/local.mac-wakeup.notify.plist" "uninstall: removes the notifier plist"
has "$out" "would: launchctl disable system/local.hermes.wakeprobe" "uninstall: shuts the daemon down"
eq "$(count_of "$out" 'would: pmset schedule cancel wake')" "3" "uninstall: removes the probe events"
has "$out" "would: rm -f /Library/LaunchDaemons/local.hermes.wakeprobe.plist" "uninstall: removes the daemon plist"

echo
if [ "$fails" -eq 0 ]; then echo "PASS (all macwake checks)"; exit 0; fi
echo "FAIL: $fails checks"; exit 1
