# mac-wakeup — the Mac wakes up by itself when the power comes back

Project directory: `~/Documents/mac-wakeup` (git). Everything is driven by one command, **`macwake`**
(`macwake install` puts it in `~/.local/bin/macwake`, so it works from anywhere).
The daemon script lives in git, but **that copy is not what runs**: launchd runs the installed
copy at `/usr/local/bin/hermes-wakeprobe.sh`, so moving the directory breaks nothing.

## Quick start on a new Mac (5 minutes)

Assumes: macOS, Hermes installed with a working Telegram bot, internet.

```bash
# 1. Confirm the hardware has no wake-on-charger at all (expect 0)
pmset -g cap | tr ' ' '\n' | grep -c acwake

# 2. The gateway must be a service, not a manual process
hermes gateway status
hermes gateway install            # only if the status says "Running manually"

# 3. Get the project
git clone <REPO-URL> ~/Documents/mac-wakeup   # or just copy the folder
cd ~/Documents/mac-wakeup

# 4. One command: tests -> holder -> notifier -> probe daemon (password once, for the daemon)
./macwake install --notify telegram:123456789
#    chat id: hermes send --list telegram
#    without notifications:                 ./macwake install --no-notify
#    if Vorssaint/Amphetamine already holds: --holder none
#    probe interval and queue:              --step 12 --want 3

# 5. Checks
macwake status                                # probes running, holder holding, notifier running
pmset -g sched | grep -c hermes-wakeprobe     # 3
hermes send --to telegram:123456789 "test message"
#    then unplug the charger for 30 seconds and plug it back in — two messages should arrive
tail -5 ~/Library/Logs/mac-wakeup-notify.log
```

Done. Check everything at once: `macwake status` and `./tools/report.sh`.

If something is off, it is almost always one of three things: a file is not in `/tmp` (TCC),
the `pmset` events are stale (clean up: `macwake disable` / `macwake enable`), or the chat id is wrong.

## What is configured where

There is no separate config file: `macwake` writes the plists itself, and the scripts read environment
variables from those plists. Changed a value? Run `macwake install` again (it is idempotent) or edit the
plist and do `launchctl bootout` + `bootstrap`.

| Setting | How to set it | Default |
|---|---|---|
| Probe interval | `macwake install --step N` (`WAKEPROBE_STEP_MIN` in the daemon plist) | 12 min |
| How many probes to keep queued | `macwake install --want N` (`WAKEPROBE_WANT`) | 3 |
| "Stay awake on AC" holder | `macwake hold on/off`; at install time the `--holder` flag (caffeinate or none) | caffeinate -s |
| Power poll interval | `~/Library/LaunchAgents/local.mac-wakeup.notify.plist` -> `POWERNOTIFY_INTERVAL` | 30 s |
| Confirming readings before sending | same plist -> `POWERNOTIFY_DEBOUNCE` | 2 |
| Telegram chat | `macwake install --notify telegram:NUMBER`, then `macwake notify on --target …` | **required** |
| Path to `hermes` | env `POWERNOTIFY_HERMES` | from `PATH`, else `$HOME/.hermes/...` |
| Message text | `power-notify.sh`, function `compose()` | — |
| Logs | `/var/log/hermes-wakeprobe.log`, `~/Library/Logs/mac-wakeup-notify.log`, `~/Library/Logs/mac-wakeup-hold.err` | — |

Hard-coded on purpose (no need to change): the `hermes-wakeprobe` tag on the `pmset` events,
the launchd job names (`local.hermes.wakeprobe`, `local.mac-wakeup.hold`, `local.mac-wakeup.notify`),
the paths `/usr/local/bin/hermes-wakeprobe.sh` and `~/.local/bin/{power-notify.sh,macwake}`,
the state directories (`/var/log`, `~/.local/state/mac-wakeup`), and the retry ladder
30 s -> 60 s -> 3 min -> 5 min -> 10 min.

## How it works

Wake-on-charger does not exist on Apple Silicon (`pmset -g cap` has no `acwake`/`autorestart`),
so the setup is two independent halves:

1. **Wake** — the root daemon `local.hermes.wakeprobe` keeps 3 `pmset schedule wake` events
   tagged `hermes-wakeprobe` queued (roughly +12/+24/+36 minutes) and adds missing ones every
   minute. A sleeping Mac wakes on the nearest event — 12 minutes at most.
2. **Hold** — the user agent `local.mac-wakeup.hold` runs `/usr/bin/caffeinate -s`.
   Its `PreventSystemSleep` assertion works **on AC only**: while the charger is connected the Mac
   does not idle-sleep; on battery macOS drops the assertion and the Mac sleeps as usual. This is
   exactly the behavior of Vorssaint's `keepAwakeConnectedToPower` or Amphetamine's "off, while
   plugged in" — just without a GUI app. If such an app is already installed, use `--holder none`.

Why `-s` and not `-i`: `-i` holds `PreventUserIdleSystemSleep` regardless of power source, so it
would chew the battery; `-s` lets go on battery. Check it by eye:
`pmset -g | grep sleep` — on AC, `caffeinate` should appear in the "sleep prevented by" list.

The Hermes gateway lives separately: `ai.hermes.gateway`
(a LaunchAgent with `KeepAlive`); sleep does not kill it, and launchd restarts it after a crash in ~35 s.

Checks and measurements: `measurements.md`. Tests: `./test_plan.sh` (planner), `./test_notify.sh`
(power transitions and delivery), `./test_cli.sh` (macwake: dry-run and status parsing on stubs).

| What | Where |
|---|---|
| Wake daemon | `/Library/LaunchDaemons/local.hermes.wakeprobe.plist` -> `/usr/local/bin/hermes-wakeprobe.sh` |
| Daemon log | `/var/log/hermes-wakeprobe.log` (+ `.err`) |
| Daemon settings | `WAKEPROBE_STEP_MIN`, `WAKEPROBE_WANT` in the plist (or `install --step/--want`) |
| Holder | `~/Library/LaunchAgents/local.mac-wakeup.hold.plist` -> `/usr/bin/caffeinate -s` |
| Notifier | `~/Library/LaunchAgents/local.mac-wakeup.notify.plist` -> `~/.local/bin/power-notify.sh` |
| CLI | `~/.local/bin/macwake` (copy of `macwake` from the repo) |
| Gateway | `~/Library/LaunchAgents/ai.hermes.gateway.plist` |

## Control: `macwake`

```bash
macwake status              # what is on: probes / holder / notifications / power
macwake enable              # turn probes on (boot the daemon and fill the queue)
macwake disable             # turn probes off: bootout + disable + remove all events
macwake disable --all       # the same + holder and notifications
macwake hold on|off|status  # the "stay awake on AC" holder; does not touch probes
macwake notify on|off       # Telegram notifications; does not touch probes
macwake install [...]       # install/reconfigure everything
macwake uninstall [--purge] # remove everything (--purge: logs and state too)
```

Three things to keep in mind (this is the point of the split):

- `disable` does **not** touch the holder: a Mac woken by hand stays awake on AC.
- `hold off` does **not** touch the probes: the Mac keeps waking every 12 minutes but falls asleep
  a minute after waking. If you want "sleep and stay asleep", that is `disable`.
- The holder and notifications are user agents and need no sudo. Probes are a root daemon, so
  `enable/disable/install/uninstall` ask for the password once (the CLI runs `sudo` itself and
  handles TCC: root cannot read `~/Documents`, so the script is first copied to a private temp dir).

### Check by hand

```bash
launchctl print system/local.hermes.wakeprobe | grep -E "state =|pid ="   # state = running
pmset -g sched | grep -c "hermes-wakeprobe"                              # 3
pmset -g | grep "sleep "                                                 # on AC: ... by caffeinate
sudo tail -5 /var/log/hermes-wakeprobe.log                               # ticks once a minute
```

### `pmset` traps that every home-made CLI hits

- `pmset -g sched` prints a **four-digit** year, but `pmset schedule cancel` rejects the four-digit
  form ("Badly formatted date"). It needs two digits — hence `date -j -f`. `macwake` already does this.
- `for d in $(...)` splits "11/12/2026 16:59:27" on the space and every cancel fails.
  Use `while IFS= read -r d` only.
- **Never** run `sudo pmset schedule cancelall` — it wipes Apple's system alarms too.

### Pause quietly, without removing anything

Unplug the charger: `caffeinate -s` drops its assertion on battery and the Mac sleeps within a minute.
The probes keep waking it every 12 minutes — if you do not want that either, run `macwake disable`.

### The gateway itself (a separate story)

```bash
hermes gateway status     # "supervised by launchd" = all good
hermes gateway stop       # clean exit 0 -> launchd does NOT bring it back
hermes gateway start      # bring it back
launchctl print gui/$(id -u)/ai.hermes.gateway | grep -E "state =|pid =|runs ="
```

`KeepAlive = { SuccessfulExit = false }`: a crash by signal is restarted, a deliberate
`hermes gateway stop` is not. That is intended.

## Telegram notifications when power is lost and restored

A separate user agent, `local.mac-wakeup.notify`, reads `pmset -g batt` every 30 seconds and, when
the power source changes, sends a Telegram message through `hermes send` (the same bot as the
gateway; no agent loop needed).

- Installed script: `~/.local/bin/power-notify.sh` (a copy from the repo — launchd cannot
  read `~/Documents` because of TCC)
- Log: `~/Library/Logs/mac-wakeup-notify.log`, stderr: `~/Library/Logs/mac-wakeup-notify.err`
- Current state cached in: `~/.local/state/mac-wakeup/power-state` (`AC` / `BATT`)
- Undelivered messages: `~/.local/state/mac-wakeup/outbox.txt`
- Tests: `./test_notify.sh` (transitions, text, backoff, and delivery through the outbox)

Logic: the first reading is only remembered (no spam at login); a change is confirmed by two
agreeing readings in a row (protection against a loose connector), then the message goes into
the outbox and is sent. **If sending fails, the message stays queued**, and retries follow the
ladder 30 s -> 60 s -> 3 min -> 5 min -> 10 min (cap) until it goes out: every failed attempt is a
whole Python process, and you must not hammer them on battery. The router usually survives a
blackout for a while, so short outages report immediately; for a long one, "power lost" arrives
when the network is back, followed by "restored", in the right order.

Check:

```bash
macwake status
launchctl print gui/$(id -u)/local.mac-wakeup.notify | grep -E "state =|pid ="
tail -5 ~/Library/Logs/mac-wakeup-notify.log
cat ~/.local/state/mac-wakeup/power-state
cat ~/.local/state/mac-wakeup/outbox.txt     # empty = everything delivered
```

Turn off / on:

```bash
macwake notify off
macwake notify on                    # target comes from the plist
macwake notify on --target telegram:123456789   # or set a new one (rewrites the plist)
```

Reinstall after editing `power-notify.sh` (it runs the tests and re-registers the agent):

```bash
cd ~/Documents/mac-wakeup && ./macwake install --notify telegram:NUMBER
```

The poll interval is `POWERNOTIFY_INTERVAL` in `~/Library/LaunchAgents/local.mac-wakeup.notify.plist`,
then `launchctl bootout` + `bootstrap` (or `macwake notify on`).
List available targets: `hermes send --list telegram`.

### Battery cost and latency budget

| What | Value | Why |
|---|---|---|
| Power poll | every 30 s | while the Mac sleeps the process sleeps too, so polling is free; you only pay while awake |
| Retry on send failure | 30 s -> 60 s -> 3 min -> 5 min -> 10 min (cap) | every attempt is a whole Python process; do not hammer on battery |
| Wake probes | every 12 min, 3 queued | after a probe the Mac is awake ~60 s (until idle sleep) at ~5 W = 0.5 % battery per hour |
| Holder | nothing | `caffeinate -s` lives on AC only; on battery the assertion is dropped, usage is normal |
| Worst notification delay | 60 s | debounce of 2 readings 30 s apart |
| Worst recovery delay after a blackout | 12 min (probe) + 60 s = ~13 min | fits in the allowed 15, with margin |

For comparison: probes every 10 min were ~0.7 %/h, every 15 min ~0.33 %/h, but then the worst case
was exactly 15 minutes with no margin. 12 minutes is the compromise. To change it:
`macwake install --step 15` (rewrites the daemon plist and restarts it);
`POWERNOTIFY_INTERVAL` lives in the notifier plist.

## Reinstall / edits

```bash
cd ~/Documents/mac-wakeup && ./macwake install    # tests + reinstall + checks
```

`install` is idempotent: it removes the old agents and raises them again. It handles TCC itself —
`~/Documents` is protected and root cannot even **read** it, so the CLI copies `wakeprobe.sh` and
itself into a private temp dir under your name and then re-runs through `sudo` from there.
Run it **as yourself** (no `sudo`): the CLI asks for the password itself, only for the root half.
`sudo macwake install` also works but leaves root-owned files in `~/.local/bin` — avoid it.

You can trim what gets installed: `--no-notify` (no notifications), `--holder none` (Vorssaint
or nothing holds), `--step N --want N` (probe interval and queue).

## Gateway crash test (from a separate Terminal window only)

The chat session lives inside the gateway process, so killing it from the chat is pointless — the
command dies with it. `ThrottleInterval = 30`, so expect ~30–40 seconds of downtime.

```bash
pkill -9 -f "gateway run --external-supervisor"; sleep 40
launchctl print gui/$(id -u)/ai.hermes.gateway | grep -E "state =|pid =|runs ="
hermes gateway status | head -4
```

It passed if `state = running`, the PID is new, `runs` went up by one, and the status is still
"supervised by launchd".

## Full rollback

```bash
macwake uninstall --purge
```

Removes the probes (bootout + disable + all events), the holder, the notifier, the plists, the
scripts, the logs and the state — and deletes itself from `~/.local/bin`. It does not touch
`pmset` settings or third-party apps (Vorssaint/Amphetamine). To go back:
`cd ~/Documents/mac-wakeup && ./macwake install`.

**Never** run `sudo pmset schedule cancelall` — it wipes Apple's system alarms too.

## Known limitations

- This hardware has no wake-on-charger: recovery delay equals the probe interval (12 min by default).
- A fully drained battery cannot be recovered remotely — a laptop at 0% does not power on by itself
  when power returns (Apple laptops have no `autorestart`).
- FileVault is on: after a *reboot* nothing starts until you log in. That is why the strategy is
  "do not let it shut down", not "bring it up after a reboot".
- Wakes cost battery; the holder (`caffeinate -s`) does nothing on battery.
- The holder and the notifier are user LaunchAgents: they do not exist before login (same as any
  GUI app such as Vorssaint).

## What is in the repository

```
macwake                                       CLI: install/uninstall/enable/disable/hold/notify/status
wakeprobe.sh                                  wake probe daemon (the plist is generated by macwake)
power-notify.sh                               Telegram notifier
test_plan.sh, test_notify.sh, test_cli.sh     tests; fixtures/ — sample `pmset -g sched` output
tools/                                        one-shot script: report.sh (collect all the evidence)
measurements.md                               measurements and conclusions (Wake vs DarkWake, etc.)
```

Logs and runtime state (`*.log`, `*.err`, `~/.local/state/mac-wakeup`) are not committed —
see `.gitignore`. There are no secrets in the repo: the chat id is passed at install time, and the
bot token lives in the Hermes config and is never read by these scripts.

## License

MIT — see `LICENSE`. Keep the copyright, do whatever you want with the rest.
