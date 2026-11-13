# mac-wakeup — мак просыпается сам, когда возвращается электричество

Проект каталога: `~/Documents/mac-wakeup` (git). Управление — одной командой **`macwake`**
(`macwake install` ставит её в `~/.local/bin/macwake`, так что она работает из любого места).
Скрипт демона лежит в git, но **работает не он**: launchd запускает установленную копию
`/usr/local/bin/hermes-wakeprobe.sh`, поэтому перенос каталога ничего не ломает.

## Быстрый старт на новом маке (5 минут)

Предполагается: macOS, установленный Hermes с настроенным Telegram-ботом, интернет.

```bash
# 1. Убедиться, что железо вообще не умеет wake-on-charger (ожидаем 0)
pmset -g cap | tr ' ' '\n' | grep -c acwake

# 2. Gateway должен быть сервисом, а не ручным процессом
hermes gateway status
hermes gateway install            # только если в статусе «Running manually»

# 3. Забрать проект
git clone <URL-репозитория> ~/Documents/mac-wakeup   # или просто скопировать папку
cd ~/Documents/mac-wakeup

# 4. Одна команда: тесты → держатель → уведомлятор → демон проб (пароль один раз, для демона)
./macwake install --notify telegram:123456789
#    chat id: hermes send --list telegram
#    без уведомлений:                       ./macwake install --no-notify
#    если держит Vorssaint/Amphetamine:     --holder none
#    интервал проб и очередь:               --step 12 --want 3

# 5. Проверки
macwake status                                # пробы running, держатель держит, уведомлятор running
pmset -g sched | grep -c hermes-wakeprobe     # 3
hermes send --to telegram:123456789 "проверка связи"
#    затем отключи зарядку на 30 секунд и подключи обратно — придёт два сообщения
tail -5 ~/Library/Logs/mac-wakeup-notify.log
```

Готово. Проверить всё разом: `macwake status` и `./tools/report.sh`.

Если что-то не сошлось — почти всегда одна из трёх причин: файл не в `/tmp` (TCC),
`pmset`-события старые (почисти: `macwake disable` / `macwake enable`), или chat id не тот.

## Что где конфигурируется

Отдельного конфиг-файла нет: `macwake` пишет plist'ы сам, а скрипты читают переменные окружения
из этих plist'ов. Поменял значение → `macwake install` заново (идемпотентен) либо правишь plist
и делаешь `launchctl bootout` + `bootstrap`.

| Параметр | Как задать | По умолчанию |
|---|---|---|
| Интервал проб пробуждения | `macwake install --step N` (`WAKEPROBE_STEP_MIN` в plist демона) | 12 мин |
| Сколько проб держать в очереди | `macwake install --want N` (`WAKEPROBE_WANT`) | 3 |
| Держатель «не спать на AC» | `macwake hold on/off`; при установке флаг `--holder` (caffeinate или none) | caffeinate -s |
| Интервал опроса питания | `~/Library/LaunchAgents/local.mac-wakeup.notify.plist` → `POWERNOTIFY_INTERVAL` | 30 с |
| Подтверждающих замеров до отправки | там же → `POWERNOTIFY_DEBOUNCE` | 2 |
| Чат Telegram | `macwake install --notify telegram:ЧИСЛО`, затем `macwake notify on --target …` | **обязателен** |
| Путь к `hermes` | env `POWERNOTIFY_HERMES` | из `PATH`, иначе `$HOME/.hermes/...` |
| Тексты сообщений | `power-notify.sh`, функция `compose()` | — |
| Логи | `/var/log/hermes-wakeprobe.log`, `~/Library/Logs/mac-wakeup-notify.log`, `~/Library/Logs/mac-wakeup-hold.err` | — |

Жёстко зашито (сознательно, менять не нужно): метка `hermes-wakeprobe` в `pmset`-событиях,
имена launchd-джобов (`local.hermes.wakeprobe`, `local.mac-wakeup.hold`, `local.mac-wakeup.notify`),
пути `/usr/local/bin/hermes-wakeprobe.sh` и `~/.local/bin/{power-notify.sh,macwake}`,
каталоги состояния (`/var/log`, `~/.local/state/mac-wakeup`), интервалы ретраев
30 с → 60 с → 3 мин → 5 мин → 10 мин.

## Как устроено

Wake-on-charger на Apple Silicon не существует (`pmset -g cap` не содержит `acwake`/`autorestart`),
поэтому схема собрана из двух независимых половин:

1. **Разбудить** — root-демон `local.hermes.wakeprobe` держит в очереди 3 события
   `pmset schedule wake` с меткой `hermes-wakeprobe` (примерно +12/+24/+36 минут) и каждую минуту
   докидывает недостающие. Спящий мак просыпается на ближайшем событии — максимум через 12 минут.
2. **Удержать** — пользовательский агент `local.mac-wakeup.hold` запускает `/usr/bin/caffeinate -s`.
   Его assertion `PreventSystemSleep` действует **только на AC**: пока зарядка подключена, мак не
   засыпает по idle; на батарее macOS assertion снимает, и мак спит как обычно. Это ровно то же
   поведение, что у Vorssaint с `keepAwakeConnectedToPower` или у Amphetamine с «off, while
   plugged in» — только без GUI-приложения. Если такое приложение уже стоит, бери `--holder none`.

Почему именно `-s`, а не `-i`: `-i` держит `PreventUserIdleSystemSleep` независимо от источника
питания, то есть жевал бы батарею; `-s` на батарее отпускает. Проверяется глазами:
`pmset -g | grep sleep` — на AC в списке «sleep prevented by» должен появиться `caffeinate`.

Gateway Hermes живёт отдельно: `ai.hermes.gateway`
(LaunchAgent с `KeepAlive`), сон его не убивает, падение — перезапускает launchd за ~35 с.

Проверки и замеры: `measurements.md`. Тесты: `./test_plan.sh` (планировщик), `./test_notify.sh`
(переходы питания), `./test_cli.sh` (macwake: dry-run и парсинг статуса на заглушках).

| Что | Где |
|---|---|
| Демон пробуждений | `/Library/LaunchDaemons/local.hermes.wakeprobe.plist` → `/usr/local/bin/hermes-wakeprobe.sh` |
| Лог демона | `/var/log/hermes-wakeprobe.log` (+ `.err`) |
| Настройки демона | `WAKEPROBE_STEP_MIN`, `WAKEPROBE_WANT` в plist (или флаги `install --step/--want`) |
| Держатель | `~/Library/LaunchAgents/local.mac-wakeup.hold.plist` → `/usr/bin/caffeinate -s` |
| Уведомлятор | `~/Library/LaunchAgents/local.mac-wakeup.notify.plist` → `~/.local/bin/power-notify.sh` |
| CLI | `~/.local/bin/macwake` (копия `macwake` из репозитория) |
| Gateway | `~/Library/LaunchAgents/ai.hermes.gateway.plist` |

## Управление: `macwake`

```bash
macwake status              # что включено: пробы / держатель / уведомления / питание
macwake enable              # включить пробы (поднять демон и зарядить очередь)
macwake disable             # выключить пробы: bootout + disable + снять все события
macwake disable --all       # то же + держатель и уведомления
macwake hold on|off|status  # держатель «не спать на AC»; пробы не трогает
macwake notify on|off       # уведомления в Telegram; пробы не трогает
macwake install [...]       # установить/переконфигурировать всё
macwake uninstall [--purge] # снять всё (--purge: ещё логи и состояние)
```

Три вещи, которые стоит держать в голове (это и есть смысл разделения):

- `disable` **не** трогает держатель: мак, разбуженный вручную, останется включённым на AC.
- `hold off` **не** трогает пробы: мак продолжит просыпаться раз в 12 минут, но уснёт через
  минуту после пробуждения. Нужно «спать и не просыпаться» — это `disable`.
- Держатель и уведомления — пользовательские агенты, sudo им не нужен. Пробы — root-демон,
  поэтому `enable/disable/install/uninstall` спросят пароль один раз (CLI сам делает `sudo`
  и сам обходит TCC: `~/Documents` root прочитать не может, поэтому скрипт сначала кладётся в `/tmp`).

### Проверить вручную

```bash
launchctl print system/local.hermes.wakeprobe | grep -E "state =|pid ="   # state = running
pmset -g sched | grep -c "hermes-wakeprobe"                              # 3
pmset -g | grep "sleep "                                                 # на AC: ... by caffeinate
sudo tail -5 /var/log/hermes-wakeprobe.log                               # тикает раз в минуту
```

### Подвохи `pmset`, на которые наступает любой самодельный CLI

- `pmset -g sched` печатает год **четырёхзначным**, а `pmset schedule cancel` четырёхзначный
  отвергает («Badly formatted date»). Нужен двузначный — отсюда `date -j -f`. `macwake` это уже делает.
- `for d in $(...)` разбивает «11/12/2026 16:59:27» по пробелу, и все cancel'ы падают.
  Только `while IFS= read -r d`.
- **Никогда** не `sudo pmset schedule cancelall` — сносит и системные будильники Apple.

### Приостановить «по-тихому», ничего не снимая

Отключи зарядку: `caffeinate -s` отпускает assertion на батарее, мак засыпает через минуту.
Пробы при этом продолжают его будить раз в 12 минут — если не нужно и это, `macwake disable`.

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
- Тесты: `./test_notify.sh` (переходы, текст, backoff и доставка через outbox)

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
macwake status
launchctl print gui/$(id -u)/local.mac-wakeup.notify | grep -E "state =|pid ="
tail -5 ~/Library/Logs/mac-wakeup-notify.log
cat ~/.local/state/mac-wakeup/power-state
cat ~/.local/state/mac-wakeup/outbox.txt     # пусто = всё доставлено
```

Выключить / включить:

```bash
macwake notify off
macwake notify on                    # цель берётся из plist
macwake notify on --target telegram:123456789   # или задать новую (перепишет plist)
```

Переустановить после правок `power-notify.sh` (сам прогонит тесты и перерегистрирует агент):

```bash
cd ~/Documents/mac-wakeup && ./macwake install --notify telegram:ЧИСЛО
```

Интервал опроса — `POWERNOTIFY_INTERVAL` в `~/Library/LaunchAgents/local.mac-wakeup.notify.plist`,
затем `launchctl bootout` + `bootstrap` (или `macwake notify on`).
Список доступных целей: `hermes send --list telegram`.

### Стоимость для батареи и бюджет задержки

| Что | Значение | Почему так |
|---|---|---|
| Опрос питания | раз в 30 с | пока мак спит, процесс тоже спит — опрос бесплатен; платим только пока бодрствуем |
| Повтор отправки при сбое | 30 с → 60 с → 3 мин → 5 мин → 10 мин (кап) | каждая попытка — целый Python-процесс; на батарее нельзя долбить |
| Пробы пробуждения | раз в 12 мин, 3 в очереди | после пробы мак бодрствует ~60 с (до idle sleep) при ~5 Вт ≈ 0.5 % батареи в час |
| Держатель | ничего | `caffeinate -s` живёт только на AC; на батарее assertion снят, расход = обычный |
| Худшая задержка уведомления | 60 с | дебаунс 2 замера по 30 с |
| Худшая задержка восстановления после света | 12 мин (проба) + 60 с = ~13 мин | укладывается в разрешённые 15, остаётся запас |

Для сравнения: при пробах раз в 10 мин это было ~0.7 %/ч, раз в 15 — ~0.33 %/ч, но тогда
худший случай ровно 15 минут без запаса. 12 минут — компромисс. Менять:
`macwake install --step 15` (перепишет plist демона и перезапустит его),
`POWERNOTIFY_INTERVAL` — в plist уведомлятора.

## Переустановка / правки

```bash
cd ~/Documents/mac-wakeup && ./macwake install    # тесты + переустановка + проверка
```

`install` идемпотентен: снимает старые агенты и поднимает заново. TCC он обходит сам —
`~/Documents` защищён, и root не может оттуда даже **прочитать**, поэтому CLI сначала кладёт
`wakeprobe.sh` и себя в `/tmp` от твоего имени, а потом перезапускается через `sudo` уже из `/tmp`.
Запускать надо **от своего имени** (без `sudo`): пароль CLI спросит сам, только для root-половины.
`sudo macwake install` тоже отработает, но оставит root-owned файлы в `~/.local/bin` — не надо.

Состав установки можно сузить: `--no-notify` (без уведомлений), `--holder none` (держит Vorssaint
или ничего), `--step N --want N` (интервал и очередь проб).

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
macwake uninstall --purge
```

Снимает пробы (bootout + disable + все события), держатель, уведомлятор, plist'ы, скрипты,
логи и состояние — и удаляет себя из `~/.local/bin`. Настройки `pmset` и сторонние приложения
(Vorssaint/Amphetamine) не трогает. Обратно: `cd ~/Documents/mac-wakeup && ./macwake install`.

**Никогда** не запускай `sudo pmset schedule cancelall` — он сносит и системные будильники Apple.

## Известные ограничения

- Wake-on-charger на этом железе нет: задержка восстановления = интервал проб (по умолчанию 12 мин).
- Полностью севшая батарея не восстанавливается удалённо — ноутбук с 0% сам не включается при
  возврате питания (`autorestart` у ноутбуков Apple нет).
- FileVault включён: после *перезагрузки* ничего не стартует до входа в систему. Отсюда и стратегия
  «не дать выключиться», а не «поднять после ребута».
- Пробуждения расходуют батарею; держатель (`caffeinate -s`) на батарее ничего не делает.
- Держатель и уведомлятор — пользовательские LaunchAgent'ы: до логина их нет (как и любого
  GUI-приложения вроде Vorssaint).

## Что лежит в репозитории

```
macwake                                       CLI: install/uninstall/enable/disable/hold/notify/status
wakeprobe.sh                                  демон пробуждений (plist генерирует macwake)
power-notify.sh                               уведомлятор в Telegram
test_plan.sh, test_notify.sh, test_cli.sh     тесты; fixtures/ — образцы `pmset -g sched`
tools/                                        разовый скрипт: report.sh (собрать все улики)
measurements.md                               замеры и выводы (Wake vs DarkWake и т.д.)
```

Логи и рантайм-состояние (`*.log`, `*.err`, `~/.local/state/mac-wakeup`) в git не попадают —
см. `.gitignore`. Секретов в репозитории нет: chat id передаётся при установке, токен бота
живёт в конфиге Hermes и скриптами не читается.

## Лицензия

MIT — см. `LICENSE`. Копирайт сохрани, остальное делай что хочешь.
