# hermes-wakeprobe

Keeps N probe wake events queued so the Mac wakes at least every 10 minutes while asleep.
Vorssaint (`com.vorssaint.utils`, `keepAwakeConnectedToPower = true`) holds the machine awake
once AC is back. No caffeinate involved — Vorssaint is the keep-awake half, this daemon is the
wake half.

- Gateway service label: `ai.hermes.gateway` (LaunchAgent, installed via `hermes gateway install`)
- Wake daemon label: `local.hermes.wakeprobe` (root LaunchDaemon)
- Log: `/var/log/hermes-wakeprobe.log` (root), stderr: `/var/log/hermes-wakeprobe.err`
- Tune: `WAKEPROBE_STEP_MIN` / `WAKEPROBE_WANT` in `/Library/LaunchDaemons/local.hermes.wakeprobe.plist`
- Tests: `./test_plan.sh` (fixtures in `./fixtures`)

## Reinstall after editing wakeprobe.sh

```bash
sudo install -o root -g wheel -m 755 ~/.hermes/wakeprobe/wakeprobe.sh /usr/local/bin/hermes-wakeprobe.sh
sudo launchctl kickstart -k system/local.hermes.wakeprobe
```

## Status

```bash
launchctl print system/local.hermes.wakeprobe | grep -E "state =|pid ="
pmset -g sched | grep -c "hermes-wakeprobe"     # expect 3
sudo tail -5 /var/log/hermes-wakeprobe.log
```

## Crash test (run from a shell OUTSIDE the gateway)

The gateway's chat session lives inside the gateway process, so this must be a separate Terminal
window. `KeepAlive` is `{ SuccessfulExit = false }`: any signal/crash death relaunches, a clean
`exit 0` stop does not. `ThrottleInterval` is 30 s, so expect ~30–40 s of downtime.

```bash
pkill -9 -f "gateway run --external-supervisor"; sleep 40
launchctl print gui/$(id -u)/ai.hermes.gateway | grep -E "state =|pid =|runs ="
hermes gateway status | head -4
```

Pass: `state = running`, a **new** pid, `runs` incremented by one, and status still says
"supervised by launchd".

## Rollback

```bash
sudo launchctl bootout system /Library/LaunchDaemons/local.hermes.wakeprobe.plist
sudo rm /Library/LaunchDaemons/local.hermes.wakeprobe.plist /usr/local/bin/hermes-wakeprobe.sh
for d in $(pmset -g sched | sed -nE "s/.*wake at ([0-9]{2}\/[0-9]{2}\/[0-9]{2} [0-9:]{8}) by 'hermes-wakeprobe'.*/\1/p"); do
  sudo pmset schedule cancel wake "$d" hermes-wakeprobe
done
```

**Never** run `sudo pmset schedule cancelall` — it deletes Apple's own alarms.

## Known limits

- No wake-on-charger on this hardware (`pmset -g cap` has no `acwake`/`autorestart`). Recovery
  latency = the probe interval (10 min by default).
- A fully drained battery is unrecoverable remotely: a MacBook at 0% does not boot when power
  returns.
- FileVault is On: after a *reboot* nothing starts until someone logs in, so the design goal is
  "never let it shut down", not "restart after reboot".
