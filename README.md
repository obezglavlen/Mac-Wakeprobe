# mac-wakeup — мак просыпается сам, когда возвращается электричество

Проект каталога: `~/Documents/mac-wakeup` (git). Скрипт демона лежит в git, но **работает не он**:
launchd запускает установленную копию `/usr/local/bin/hermes-wakeprobe.sh`, поэтому перенос каталога
ничего не ломает.

## Быстрый старт на новом маке (5 минут)

Предполагается: macOS, установленный Hermes с настроенным Telegram-ботом, интернет.
Заодно ставится приложение-держатель (см. шаг 9) — без него схема не имеет смысла.

```bash
# 1. Убедиться, что железо вообще не умеет wake-on-charger (ожидаем 0)
pmset -g cap | tr ' ' '\n' | grep -c acwake

# 2. Gateway должен быть сервисом, а не ручным процессом
hermes gateway status
hermes gateway install            # только если в статусе «Running manually»

# 3. Узнать chat id для уведомлений (формат telegram:ЧИСЛО)
hermes send --list telegram

# 4. Забрать проект
git clone <URL-репозитория> ~/Documents/mac-wakeup   # или просто скопировать папку
cd ~/Documents/mac-wakeup

# 5. Тесты до установки: должно быть PASS (10/10) и PASS (17/17)
./test_plan.sh && ./test_notify.sh

# 6. Демон пробуждения (спросит пароль один раз; TCC обходится через /tmp сам)
./install-wakeprobe.sh
#    ждём: state = running, pid = ..., queued ours: 3 (expect 3)

# 7. Уведомлятор в Telegram (подставь свой chat id из шага 3)
POWERNOTIFY_TARGET=telegram:123456789 ./install-notify.sh
#    ждём: PASS (17/17), «installed», state = running

# 8. Проверки: сообщение доходит и переходы ловятся
hermes send --to telegram:123456789 "проверка связи"
#    затем отключи зарядку на 30 секунд и подключи обратно — придёт два сообщения
tail -5 ~/Library/Logs/mac-wakeup-notify.log
pmset -g sched | grep -c hermes-wakeprobe     # 3
```

```bash
# 9. Держатель «пока подключено питание» — обязательно, иначе после пробуждения
#    мак снова уснёт через минуту. Варианты:
#    Vorssaint → Preferences → keep awake при keepAwakeConnectedToPower = true
#    Amphetamine → «Allow system to sleep… off, while plugged in»
#    или свой caffeinate-демон (см. раздел «Стоимость для батареи»)
```

Готово. Проверить всё разом: `./tools/report.sh` (для демона) и лог уведомлятора.

Если что-то не сошлось — почти всегда одна из трёх причин: файл не в `/tmp` (TCC),
`pmset`-события старые (почисти: раздел «Выключить»), или chat id в plist не тот.

## Что где конфигурируется

Отдельного конфиг-файла нет: скрипты читают переменные окружения, а их задаёт plist
соответствующего агента. Меняешь plist → переустанавливаешь (`install-*.sh`).

| Параметр | Где | По умолчанию |
|---|---|---|
| Интервал проб пробуждения | `/Library/LaunchDaemons/local.hermes.wakeprobe.plist` → `WAKEPROBE_STEP_MIN` | 12 мин |
| Сколько проб держать в очереди | там же → `WAKEPROBE_WANT` | 3 |
| Интервал опроса питания | `~/Library/LaunchAgents/local.mac-wakeup.notify.plist` → `POWERNOTIFY_INTERVAL` | 30 с |
| Подтверждающих замеров до отправки | там же → `POWERNOTIFY_DEBOUNCE` | 2 |
| Чат Telegram | там же → `POWERNOTIFY_TARGET` | `telegram:ЧИСЛО` |
| Путь к `hermes` | env `POWERNOTIFY_HERMES` | из `PATH`, иначе `$HOME/.hermes/...` |
| Тексты сообщений | `power-notify.sh`, функция `compose()` | — |
| Логи | `/var/log/hermes-wakeprobe.log`, `~/Library/Logs/mac-wakeup-notify.log` | — |

Жёстко зашито (сознательно, менять не нужно): метка `hermes-wakeprobe`, имена
launchd-джобов, пути `/usr/local/bin/hermes-wakeprobe.sh` и `~/.local/bin/power-notify.sh`,
каталоги состояния (`/var/log`, `~/.local/state/mac-wakeup`), интервалы ретраев
30 с → 60 с → 3 мин → 5 мин → 10 мин.

## Как устроено

Wake-on-charger на Apple Silicon не существует (`pmset -g cap` не содержит `acwake`/`autorestart`),
поэтому схема собрана из двух половин:

1. **Разбудить** — root-демон `local.hermes.wakeprobe` держит в очереди 3 события
   `pmset schedule wake` с меткой `hermes-wakeprobe` (примерно +10/+20/+30 минут) и каждую минуту
   докидывает недостающие. Спящий мак просыпается на ближайшем событии — максимум через 10 минут.
2. **Удержать** — приложение **Vorssaint** (`com.vorssaint.utils`) с настройкой
   `keepAwakeConnectedToPower = true` держит `PreventUserIdleSystemSleep`, пока подключено питание.
   Как только проба разбудила мак с уже подключённой зарядкой, Vorssaint оставляет его включённым.

`caffeinate` в схеме не участвует. Gateway Hermes живёт отдельно: `ai.hermes.gateway`
(LaunchAgent с `KeepAlive`), сон его не убивает, падение — перезапускает launchd за ~35 с.

Проверки и замеры: `measurements.md`. Тесты планировщика: `./test_plan.sh`.

| Что | Где |
|---|---|
| Демон пробуждений | `/Library/LaunchDaemons/local.hermes.wakeprobe.plist` → `/usr/local/bin/hermes-wakeprobe.sh` |
| Лог демона | `/var/log/hermes-wakeprobe.log` (+ `.err`) |
| Настройки | `WAKEPROBE_STEP_MIN` (интервал, мин), `WAKEPROBE_WANT` (сколько событий держать) в plist |
| Gateway | `~/Library/LaunchAgents/ai.hermes.gateway.plist` |

## Управление: выключить / включить

### Проверить, что работает

```bash
launchctl print system/local.hermes.wakeprobe | grep -E "state =|pid ="   # state = running
pmset -g sched | grep -c "hermes-wakeprobe"                              # 3
sudo tail -5 /var/log/hermes-wakeprobe.log                               # тикает раз в минуту
```

### Выключить (временно, до перезагрузки)

```bash
sudo launchctl bootout system/local.hermes.wakeprobe
pmset -g sched | sed -nE "s/.*wake at ([0-9]{2}\/[0-9]{2}\/[0-9]{2,4} [0-9:]{8}) by 'hermes-wakeprobe'.*/\1/p" |
while IFS= read -r d; do
  cts=$(date -j -f "%m/%d/%Y %H:%M:%S" "$d" '+%m/%d/%y %H:%M:%S' 2>/dev/null) || cts="$d"
  sudo pmset schedule cancel wake "$cts" hermes-wakeprobe
done
pmset -g sched | grep -c hermes-wakeprobe    # ожидаем 0
```

Два подвоха, на которых легко обжечься:

- `pmset -g sched` печатает год **четырёхзначным**, а `pmset schedule cancel` четырёхзначный
  отвергает («Badly formatted date»). Нужен двузначный — отсюда `date -j -f` в примере.
- `for d in $(...)` разбивает «11/12/2026 16:59:27» по пробелу, и все cancel'ы падают.
  Только `while IFS= read -r d`.

После перезагрузки демон поднимется снова (plist остался на месте).

### Выключить насовсем (переживает перезагрузку)

```bash
sudo launchctl bootout system/local.hermes.wakeprobe
sudo launchctl disable system/local.hermes.wakeprobe
```

### Включить обратно

```bash
sudo launchctl enable system/local.hermes.wakeprobe
sudo launchctl bootstrap system /Library/LaunchDaemons/local.hermes.wakeprobe.plist
sleep 6
launchctl print system/local.hermes.wakeprobe | grep -E "state =|pid ="   # state = running
pmset -g sched | grep -c "hermes-wakeprobe"                              # 3
```

`bootstrap` идемпотентным не бывает: если ругается «service already loaded», сначала `bootout`.

### Приостановить «по-тихому», ничего не снимая

Просто отключи зарядку — мак уснёт сам через минуту (Vorssaint отпускает на батарее), а пробуждения
продолжат его будить раз в 10 минут. Если нужно, чтобы он спал и **не** просыпался — только `bootout`
из предыдущего раздела.

### Сам gateway (отдельная история)

```bash
hermes gateway status     # «supervised by launchd» = всё хорошо
hermes gateway stop       # чистый exit 0 → launchd его НЕ поднимет
hermes gateway start      # поднять обратно
launchctl print gui/$(id -u)/ai.hermes.gateway | grep -E "state =|pid =|runs ="
```

`KeepAlive = { SuccessfulExit = false }`: падение по сигналу перезапускается, сознательный
`hermes gateway stop` — нет. Так и задумано.

## Уведомления в Telegram при отключении и возврате питания

Отдельный пользовательский агент `local.mac-wakeup.notify` раз в 30 секунд смотрит
`pmset -g batt` и при смене источника питания отправляет сообщение в Telegram через
`hermes send` (тот же бот, что и gateway; агент-цикл не нужен).

- Установленный скрипт: `~/.local/bin/power-notify.sh` (копия из репозитория — launchd не может
  читать `~/Documents` из-за TCC)
- Лог: `~/Library/Logs/mac-wakeup-notify.log`, stderr: `~/Library/Logs/mac-wakeup-notify.err`
- Текущее состояние в кэше: `~/.local/state/mac-wakeup/power-state` (`AC` / `BATT`)
- Неотправленные сообщения: `~/.local/state/mac-wakeup/outbox.txt`
- Тесты: `./test_notify.sh` (11 проверок логики переходов и текста)

Логика: первое показание только запоминается (никакого спама при логине), переход
подтверждается двумя согласными замерами подряд (защита от дребезга разъёма), затем сообщение
кладётся в outbox и отправляется. **Если отправка не удалась — сообщение остаётся в очереди**, а
повторы идут по лестнице 30 с → 60 с → 3 мин → 5 мин → 10 мин (кап), пока не уйдёт: каждая
неудачная попытка — это целый Python-процесс, и долбить ими на батарее нельзя. Роутер после
отключения света живёт ещё какое-то время, так что короткие провалы обычно отчитываются сразу;
при долгом — «питание отключено» придёт, когда сеть вернётся, а следом «восстановлено», в
правильном порядке.

Проверить:

```bash
launchctl print gui/$(id -u)/local.mac-wakeup.notify | grep -E "state =|pid ="
tail -5 ~/Library/Logs/mac-wakeup-notify.log
cat ~/.local/state/mac-wakeup/power-state
cat ~/.local/state/mac-wakeup/outbox.txt     # пусто = всё доставлено
```

Выключить / включить:

```bash
launchctl bootout gui/$(id -u)/local.mac-wakeup.notify
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.mac-wakeup.notify.plist
```

Переустановить после правок `power-notify.sh` (сам прогонит тесты и перерегистрирует агент):

```bash
~/Documents/mac-wakeup/install-notify.sh
```

Сменить чат/интервал — `POWERNOTIFY_TARGET` и `POWERNOTIFY_INTERVAL` в
`~/Library/LaunchAgents/local.mac-wakeup.notify.plist`, затем `install-notify.sh` заново.
Список доступных целей: `hermes send --list telegram`.

### Стоимость для батареи и бюджет задержки

| Что | Значение | Почему так |
|---|---|---|
| Опрос питания | раз в 30 с | пока мак спит, процесс тоже спит — опрос бесплатен; платим только пока бодрствуем |
| Повтор отправки при сбое | 30 с → 60 с → 3 мин → 5 мин → 10 мин (кап) | каждая попытка — целый Python-процесс; на батарее нельзя долбить |
| Пробы пробуждения | раз в 12 мин, 3 в очереди | после пробы мак бодрствует ~60 с (до idle sleep) при ~5 Вт ≈ 0.5 % батареи в час |
| Худшая задержка уведомления | 30 с | дебаунс 2 замера |
| Худшая задержка восстановления после света | 12 мин (проба) + 30 с = ~12.5 мин | укладывается в разрешённые 15, остаётся запас |

Для сравнения: при пробах раз в 10 мин это было ~0.7 %/ч, раз в 15 — ~0.33 %/ч, но тогда
худший случай ровно 15 минут без запаса. 12 минут — компромисс. Менять:
`WAKEPROBE_STEP_MIN` в `/Library/LaunchDaemons/local.hermes.wakeprobe.plist`
(+ `launchctl bootout`/`bootstrap`), `POWERNOTIFY_INTERVAL` — в plist уведомлятора.

## Переустановка демона после правок `wakeprobe.sh`

```bash
cd ~/Documents/mac-wakeup && ./install-wakeprobe.sh    # тесты + переустановка + проверка
```

Скрипт сам делает всё, что нужно знать про TCC: `~/Documents` защищён, и root (в том числе
через `osascript … with administrator privileges`) не может оттуда даже **прочитать** —
поэтому он сначала кладёт `wakeprobe.sh`, plist и самого себя в `/tmp` от твоего имени, а потом
перезапускается через `sudo` уже из `/tmp`. Если запустить его сразу с `sudo` без этой
подготовки, он честно скажет, чего не хватает.

## Краштест gateway (только из отдельного окна Terminal)

Сессия чата живёт внутри процесса gateway, поэтому убивать его из чата бессмысленно — команда умрёт
вместе с ним. `ThrottleInterval = 30`, так что простой ~30–40 секунд.

```bash
pkill -9 -f "gateway run --external-supervisor"; sleep 40
launchctl print gui/$(id -u)/ai.hermes.gateway | grep -E "state =|pid =|runs ="
hermes gateway status | head -4
```

Прошло, если `state = running`, PID новый, `runs` вырос на единицу, статус всё ещё «supervised by
launchd».

## Полный откат

```bash
sudo launchctl bootout system/local.hermes.wakeprobe
sudo launchctl disable system/local.hermes.wakeprobe
sudo rm /Library/LaunchDaemons/local.hermes.wakeprobe.plist /usr/local/bin/hermes-wakeprobe.sh
pmset -g sched | sed -nE "s/.*wake at ([0-9]{2}\/[0-9]{2}\/[0-9]{2,4} [0-9:]{8}) by 'hermes-wakeprobe'.*/\1/p" |
while IFS= read -r d; do
  cts=$(date -j -f "%m/%d/%Y %H:%M:%S" "$d" '+%m/%d/%y %H:%M:%S' 2>/dev/null) || cts="$d"
  sudo pmset schedule cancel wake "$cts" hermes-wakeprobe
done
```

**Никогда** не запускай `sudo pmset schedule cancelall` — он сносит и системные будильники Apple.

## Известные ограничения

- Wake-on-charger на этом железе нет: задержка восстановления = интервал проб (по умолчанию 10 мин).
- Полностью севшая батарея не восстанавливается удалённо — ноутбук с 0% сам не включается при
  возврате питания (`autorestart` у ноутбуков Apple нет).
- FileVault включён: после *перезагрузки* ничего не стартует до входа в систему. Отсюда и стратегия
  «не дать выключиться», а не «поднять после ребута».
- Пробуждения расходуют батарею; порог заряда самого Vorssaint — `batteryLimitPercent = 10`.
