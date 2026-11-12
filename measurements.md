# Measurements

All runs 2026-11-12, MacBook M1, macOS 27.2, probe daemon `local.hermes.wakeprobe` installed.

## A — does a `pmset schedule wake` fire, and is it a full Wake?

**PASS.**

```
2026-11-12 16:05:22 +0200 Sleep         Entering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active Using AC (Charge:80%) 204 secs
2026-11-12 16:08:46 +0200 Notification  Display is turned on
2026-11-12 16:08:46 +0200 Wake          Wake from Deep Idle [CDNVA] : due to NUB.SPMI0Sw3IRQ nub-spmi.0x02 rtc/HID Activity Using AC (Charge:80%)
```

- Full `Wake`, not `DarkWake`: display came on, lock screen shown.
- The 204-second Maintenance Sleep ended exactly at the armed minute.
- Correlated by `[*process=powerd request=UserWake ... wakeAt=16:08:46 info="hermes-wakeprobe,32740"]`.

## B1 — does a probe wake fire while on BATTERY?

**PASS.** Two consecutive probes fired with the charger unplugged:

```
2026-11-12 16:18:46 +0200 Wake  Wake from Deep Idle [CDNVA] : due to NUB.SPMI0Sw3IRQ nub-spmi.0x02 rtc/HID Activity Using BATT (Charge:80%) 68 secs
2026-11-12 16:28:46 +0200 Wake  Wake from Deep Idle [CDNVA] : due to NUB.SPMI0Sw3IRQ nub-spmi.0x02 rtc/HID Activity Using BATT (Charge:80%)
```

The designed fallback is visible too — with no AC, nothing holds the machine, so it returns to sleep by
itself until the next probe:

```
2026-11-12 16:19:54 +0200 Sleep  Entering Sleep state due to 'Idle Sleep':TCPKeepAlive=active Using Batt (Charge:80%) 45 secs
```

## B2 — does Vorssaint re-hold after a timer wake with AC attached?

**PASS.**

```
2026-11-12 16:09:48 +0200  PreventUserIdleSystemSleep  1
pid 843(Vorssaint): [0x0000950f0001a445] PreventUserIdleSystemSleep named: "Vorssaint: keep the Mac awake"
```

## B3 — does the gateway survive sleep/wake?

**PASS.** PID 21569 started `Thu Nov 12 11:19:33 2026` and was still serving at 16:31
(`ELAPSED 05:11:53`) across every sleep/wake cycle of the day. Sleep suspends, never kills.

## Full end-to-end cycle (happened organically during setup)

Power lost → slept on battery → power restored → probe woke it → Vorssaint held → stayed awake:

```
16:02:35  Sleep   Entering Sleep state due to 'Idle Sleep' ... Using Batt (Charge:80%) 21 secs
16:04:41  Sleep   Entering Sleep state ... Using AC (Charge:80%) 31 secs      <- power restored
16:05:22  Sleep   Entering Sleep state due to 'Maintenance Sleep' ... Using AC ... 204 secs
16:08:46  Wake    Wake from Deep Idle ... rtc/HID Activity Using AC (Charge:80%)   <- probe
16:08:58  Notification  Display is turned off        <- display only, NOT system sleep
16:09:48  PreventUserIdleSystemSleep 1, held by Vorssaint
```

Recovery latency in this instance: **~4 minutes** from power restore to wake; worst case is the probe
interval (10 minutes).

## Trap noticed during the test

After a timer wake the screen goes dark again within ~12 s (`Display is turned off`). That is display
sleep only — the system stays awake and keeps serving. Never judge "did it sleep?" by the screen; judge
it by `pmset -g log | grep "Entering Sleep state"`.

## Known leftovers

- `sudo pmset sleepnow` from a detached child of `do shell script ... with administrator privileges` does
  NOT sleep the machine (the child is killed when the shell exits). Run it in the foreground, or just
  unplug the charger and wait one minute.
- Gateway ownership: the serving process (PID 21569) was started manually, so the launchd agent
  `ai.hermes.gateway` exits 75 (`EX_TEMPFAIL`) on every spawn. Takeover: `hermes gateway restart --yes`.
