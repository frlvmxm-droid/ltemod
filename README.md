# ltemod

LTE + WiFi роутер на **Orange Pi 3 LTS** (Armbian) с поддержкой нескольких VPN протоколов.

## Возможности

| Функция | Описание |
|---------|----------|
| **LTE** | Sierra Wireless EM7565 через MBIM/QMI (ModemManager) |
| **WiFi AP** | Точка доступа 2.4 / 5 GHz (AP6256/BCM4345) |
| **Бридж LAN+WiFi** | Кабельные и WiFi клиенты в одной сети |
| **WiFi клиент** | Подключение к upstream WiFi роутеру |
| **WireGuard** | VPN туннель |
| **AmneziaWG** | Обфусцированный WireGuard (обход DPI) |
| **VLESS** | XTLS-Reality через sing-box |
| **Профили VPN** | Несколько именованных конфигов, переключение одной командой |
| **Kill-switch** | Блокировка трафика при падении VPN + защита от DNS-leak |
| **Bypass routing** | Избирательная маршрутизация: обход блокировок РКН или исключения для банков/сервисов |
| **Списки блокировок** | Автозагрузка/обновление списков доменов и IP с поддержкой preset-ов |
| **Учёт трафика** | Расход данных LTE по дням/месяцам (vnstat) |
| **SMS / USSD** | Баланс и SMS оператора через модем |
| **Watchdog** | Автоматическое переподключение LTE (и VPN) |
| **Автодетект** | Определение LAN/WiFi/WWAN интерфейсов под конкретное устройство |
| **Doctor** | Диагностика конфига и окружения до запуска (ловит ошибки заранее) |

### Топология сети

```
Internet
   ↑
wwan0 (LTE) / wlan1 (WiFi upstream) / end0 (Ethernet upstream)
   ↑
[VPN: wg0 / awg0 / tun0]  ← опционально
   ↑
MASQUERADE (iptables)
   ↑
br0 (если BRIDGE_LAN_ENABLED=yes)  или  wlan0 + end0 раздельно
 /     \
wlan0  end0
(WiFi) (кабель)
```

---

## Установка

**Требования:** Orange Pi 3 LTS, Armbian (Debian-based), root доступ.

```bash
git clone <url> /opt/ltemod
cd /opt/ltemod
sudo bash install.sh
```

После установки — автоопределить интерфейсы, отредактировать конфиг и проверить его:

```bash
sudo detect-hardware --write     # запишет LAN/WiFi/WWAN интерфейсы в конфиг
sudo nano /etc/ltemod/ltemod.conf  # APN, имя сети, пароль (8..63 символов)
sudo ltemod-doctor               # проверка перед запуском — поймает ошибки заранее
```

---

## Конфигурация

Всё управляется через один файл: `/etc/ltemod/ltemod.conf`

### LTE модем

```bash
APN="internet"          # APN вашего оператора
MODEM_PROTO="mbim"      # mbim или qmi
WWAN_IFACE="wwan0"      # интерфейс модема
LAN_IFACE="end0"        # Ethernet порт
```

Готовые значения для российских операторов — в папке [`examples/operators/`](examples/operators/):

| Оператор | APN | USSD баланс |
|----------|-----|-------------|
| МТС | `internet.mts.ru` | `*100#` |
| Tele2 | `m.tele2.ru` | `*100#` |
| Билайн | `internet.beeline.ru` | `*102#` |
| МегаФон | `internet` | `#100#` |
| Yota | `yota.ru` | нет (только my.yota.ru) |

Каждый файл содержит значения для прямой вставки в `/etc/ltemod/ltemod.conf`.

### WiFi точка доступа

```bash
WIFI_AP_ENABLED="yes"
WIFI_AP_SSID="МояСеть"          # имя сети
WIFI_AP_PASSWORD="пароль1234"   # минимум 8 символов
WIFI_AP_BAND="2g"               # 2g / 5g / both
WIFI_AP_CHANNEL_2G=6            # канал (1, 6 или 11)
WIFI_AP_IP="192.168.10.1"       # IP роутера
WIFI_AP_DHCP_RANGE="192.168.10.100,192.168.10.200,12h"
```

### Бридж LAN + WiFi (кабель и WiFi в одной сети)

```bash
BRIDGE_LAN_ENABLED="yes"   # объединить wlan0 и end0 → br0
BRIDGE_IFACE="br0"
```

### WiFi подключение к upstream роутеру

```bash
WIFI_CLIENT_ENABLED="yes"
WIFI_CLIENT_SSID="ИмяСетиРоутера"
WIFI_CLIENT_PASSWORD="пароль"
```

### Приоритет uplink

```bash
# Порядок выбора интернет-канала: LTE → WiFi upstream → Ethernet
UPLINK_PRIORITY="lte wifi eth"
```

### VPN

```bash
VPN_PROTO="none"  # none / wg / amnezia / vless
```

| Значение | Описание | Когда использовать |
|----------|----------|-------------------|
| `none` | VPN отключён, трафик идёт напрямую | По умолчанию; без VPN-конфига |
| `wg` | WireGuard (стандартный туннель) | Быстрый и широко поддерживаемый |
| `amnezia` | AmneziaWG (обфусцированный WireGuard) | Если WireGuard блокируется провайдером |
| `vless` | XTLS-Reality через sing-box | Обход DPI; требует sing-box |

`ltemod-vpn.service` читает `VPN_PROTO` при каждом старте системы и автоматически поднимает туннель. Значение `none` — сервис завершается без ошибки.

---

## Управление

### WiFi AP

```bash
sudo systemctl start wifi-ap.service    # запустить
sudo systemctl stop wifi-ap.service     # остановить
sudo systemctl enable wifi-ap.service   # автостарт
sudo setup-ap status                    # статус + кол-во клиентов
```

### VPN

```bash
# WireGuard
sudo setup-vpn /path/to/wg0.conf        # установить конфиг
sudo vpn-toggle wg on                   # включить
sudo vpn-toggle wg off                  # выключить

# AmneziaWG
sudo setup-amnezia /path/to/awg0.conf
sudo vpn-toggle amnezia on

# VLESS (sing-box)
sudo setup-vless /path/to/config.json
sudo vpn-toggle vless on

# Выключить любой VPN
sudo vpn-toggle off

# Статус всех протоколов
vpn-toggle status
```

### Профили VPN (несколько конфигов)

Храните много конфигов и переключайтесь между ними одной командой. Протокол
определяется автоматически по содержимому файла.

```bash
sudo vpn-profile add home /tmp/wg0.conf        # добавить (автодетект wg/amnezia/vless)
sudo vpn-profile add germany /tmp/vless.json   # ещё один профиль
sudo vpn-profile list                          # список (активный помечен)
sudo vpn-profile use germany                   # активировать + поднять VPN
sudo vpn-profile current                       # какой профиль активен
sudo vpn-profile show home                     # показать конфиг
sudo vpn-profile rm home                       # удалить
```

Профили хранятся в `/etc/ltemod/profiles/<name>/` (права 600).

### Kill-switch и защита от утечек

Чтобы при падении VPN трафик клиентов **не уходил в обход** туннеля, включите
kill-switch в `/etc/ltemod/ltemod.conf`:

```bash
VPN_KILLSWITCH="yes"      # блокировать выход клиентов мимо VPN
VPN_DNS_REDIRECT="yes"    # перехват DNS клиентов на роутер (анти DNS-leak)
```

При активном VPN весь клиентский трафик форвардится только через VPN-интерфейс;
если туннель падает — пакеты отбрасываются (DROP), утечки нет. DNS-запросы
клиентов перенаправляются на роутер (dnsmasq → туннель).

```bash
sudo killswitch status    # проверить состояние защиты
```

### Обход блокировок (bypass routing)

Избирательная маршрутизация, аналогичная podkop: конкретные домены/IP идут через VPN
(или в обход него), остальной трафик — как настроено. Реализовано через **ipset +
iptables mangle + policy routing + dnsmasq ipset**. При разрешении домена через DNS
его IP автоматически попадает в ipset — последующие соединения маршрутизируются
правильно даже без повторного DNS-запроса.

#### Режимы

| Режим | Описание | Когда использовать |
|-------|----------|-------------------|
| `selective` | Заблокированные домены/IP → VPN; остальное → прямой uplink | Нет постоянного VPN, нужен обход конкретных блокировок РКН |
| `exclude`  | VPN для всего, исключения (банки, Госуслуги) → прямой uplink | Постоянный full-tunnel VPN, но нужны российские сервисы |

#### Быстрый старт

```bash
# 1. Включить в конфиге
sudo nano /etc/ltemod/ltemod.conf
#   BYPASS_ENABLED="yes"
#   BYPASS_MODE="selective"          # или exclude
#   BYPASS_LIST_PRESET="russia-inside"  # для selective; russia-outside для exclude

# 2. Скачать списки блокировок
sudo list-manager update             # скачает russia-inside (домены + IP)
sudo list-manager status             # проверить: кол-во записей в ipset/dnsmasq

# 3. Включить VPN (для selective — туннель должен быть поднят)
sudo vpn-toggle wg on                # или amnezia/vless

# 4. Проверить
bypass-routing status
ip rule show                         # должно быть: fwmark 0x64 lookup 100
iptables -t mangle -L PREROUTING    # должны быть MARK правила для ltemod_bypass_*
```

#### Команды

```bash
sudo list-manager update              # скачать preset + загрузить в ipset/dnsmasq
sudo list-manager update russia-outside  # конкретный preset
sudo list-manager load                # перезагрузить уже скачанные файлы
sudo list-manager status              # файлы, размеры, счётчики ipset
sudo list-manager flush               # очистить ipset и dnsmasq

sudo bypass-routing status            # активные правила и счётчики
sudo bypass-routing add-ip 1.2.3.4   # добавить IP вручную
sudo bypass-routing add-net 1.2.3.0/24
sudo bypass-routing flush             # очистить ipsets (не трогает правила)
```

#### Конфиг

```bash
BYPASS_ENABLED="yes"
BYPASS_MODE="selective"              # selective | exclude
BYPASS_LIST_PRESET="russia-inside"  # russia-inside | russia-outside | none
BYPASS_LIST_URLS=""                  # дополнительные URL (через пробел)
BYPASS_TABLE="100"                   # таблица policy routing (не менять без причины)
BYPASS_FWMARK="0x64"                 # firewall mark для bypass-трафика
```

#### Presets (источник: [itdoginfo/allow-domains](https://github.com/itdoginfo/allow-domains))

| Preset | Содержит | Подходит для |
|--------|----------|-------------|
| `russia-inside` | Домены, заблокированные РКН (~700k) + их IP | `selective`: обход блокировок |
| `russia-outside` | Сервисы, блокирующие VPN-IP (банки, госпортал) + их IP | `exclude`: работа сервисов на full-VPN |

#### Автообновление

Списки обновляются автоматически каждый день в 04:00 через systemd timer:

```bash
sudo systemctl status ltemod-bypass-update.timer
sudo systemctl start ltemod-bypass-update.service  # принудительное обновление
journalctl -u ltemod-bypass-update -f
```

---

### LTE: расход трафика и баланс

```bash
sudo data-usage           # сводка: получено/отправлено (день/месяц)
sudo data-usage live      # трафик в реальном времени
sudo data-usage month     # помесячно

sudo sms balance          # баланс через USSD (USSD_BALANCE_CODE в конфиге)
sudo sms ussd '*100#'     # произвольный USSD-запрос
sudo sms list             # входящие SMS
sudo sms send +7900... "текст"
```

### WiFi upstream клиент

```bash
sudo setup-wifi-client connect      # подключиться
sudo setup-wifi-client disconnect   # отключиться
sudo setup-wifi-client scan         # список доступных сетей
sudo setup-wifi-client status       # статус
```

### Общий статус системы

```bash
sudo modem-status
```

Показывает: LTE сигнал / оператор, WiFi AP (клиенты), все VPN, маршруты, NAT.

### Диагностика и автонастройка

```bash
sudo detect-hardware            # показать найденные LAN/WiFi/WWAN интерфейсы
sudo detect-hardware --write    # записать их в /etc/ltemod/ltemod.conf
sudo ltemod-doctor              # полная проверка конфига и окружения
```

`ltemod-doctor` проверяет: длину WiFi-пароля (8..63), валидность канала,
наличие интерфейсов и поддержку драйвером AP-режима, непересечение подсетей,
установленные зависимости и конфликтующие службы. Возвращает ненулевой код при
наличии ошибок — удобно для автоматических проверок.

> WiFi AP не стартует с заведомо битым конфигом: `setup-ap.sh` выполняет
> встроенный preflight (пароль, канал, интерфейс) перед запуском hostapd и
> печатает понятную причину в журнал.

---

## VPN — настройка с нуля

### WireGuard

```bash
cp /etc/ltemod/wg0.conf.template /tmp/wg0.conf
nano /tmp/wg0.conf          # заполнить YOUR_* значения
sudo setup-vpn /tmp/wg0.conf
sudo vpn-toggle wg on
```

### AmneziaWG

```bash
cp /etc/ltemod/amnezia-wg.conf.template /tmp/awg0.conf
nano /tmp/awg0.conf         # заполнить YOUR_* значения
sudo setup-amnezia /tmp/awg0.conf
sudo vpn-toggle amnezia on
```

Параметры обфускации (`Jc`, `Jmin`, `Jmax`, `S1`-`S2`, `H1`-`H4`) задаются сервером AmneziaWG.

### VLESS (sing-box, XTLS-Reality)

```bash
cp /etc/ltemod/vless.json.template /tmp/vless.json
nano /tmp/vless.json        # заполнить YOUR_* значения
sudo setup-vless /tmp/vless.json
sudo vpn-toggle vless on
```

---

## Обновление

```bash
cd /opt/ltemod
git pull origin claude/lte-modem-vpn-setup-nYTq5
sudo bash install.sh        # обновит скрипты и шаблоны, конфиг сохранится
```

После обновления сравнить новый шаблон конфига с текущим:
```bash
diff /etc/ltemod/ltemod.conf /etc/ltemod/ltemod.conf.new
```

---

## Удаление

```bash
sudo ltemod-uninstall            # удалить скрипты и сервисы, СОХРАНИТЬ конфиги
sudo ltemod-uninstall --purge    # удалить всё, включая /etc/ltemod (профили, пароли)
```

Установленные пакеты (hostapd, dnsmasq, sing-box) и VPN-секреты в
`/etc/wireguard`, `/etc/amnezia`, `/etc/sing-box` не удаляются.

---

## Структура проекта

```
ltemod/
├── install.sh                  # установщик
├── examples/
│   └── operators/              # конфиги операторов (МТС, Tele2, Билайн, МегаФон, Yota)
├── uninstall.sh                # деинсталлятор (--purge для полного удаления)
├── config/
│   └── ltemod.conf             # центральный конфиг (шаблон)
├── modem/
│   ├── connect-modem.sh        # подключение LTE
│   ├── modem-status.sh         # статус всей системы
│   ├── modem-watchdog.sh       # watchdog переподключения (LTE + VPN)
│   ├── data-usage.sh           # учёт трафика LTE (vnstat)
│   ├── sms.sh                  # SMS и USSD (баланс) через mmcli
│   └── 99-em7565.rules         # udev правила для EM7565
├── network/
│   ├── setup-routing.sh        # настройка маршрутизации и NAT
│   ├── vpn-toggle.sh           # переключение VPN протоколов
│   ├── killswitch.sh           # kill-switch + защита от DNS-leak
│   ├── bypass-routing.sh       # избирательная маршрутизация (ipset+policy routing)
│   └── lists/
│       └── list-manager.sh     # менеджер списков блокировок (загрузка, ipset, dnsmasq)
├── vpn/
│   ├── setup-vpn.sh            # установка WireGuard конфига
│   ├── setup-amnezia.sh        # установка AmneziaWG конфига
│   ├── setup-vless.sh          # установка VLESS конфига
│   ├── vpn-profile.sh          # менеджер именованных VPN-профилей
│   ├── wg0.conf.template       # шаблон WireGuard
│   ├── amnezia-wg.conf.template # шаблон AmneziaWG
│   └── vless.json.template     # шаблон sing-box VLESS
├── wifi/
│   ├── setup-ap.sh             # управление WiFi AP
│   ├── setup-wifi-client.sh    # WiFi upstream клиент
│   ├── hostapd-2g.conf.template # шаблон hostapd 2.4GHz
│   ├── hostapd-5g.conf.template # шаблон hostapd 5GHz
│   └── 10-wifi-ap.conf         # NM: не управлять wlan0
├── tools/
│   ├── detect-hardware.sh      # автодетект LAN/WiFi/WWAN интерфейсов
│   └── ltemod-doctor.sh        # диагностика конфига и окружения
└── systemd/
    ├── lte-modem.service               # запуск LTE при старте
    ├── lte-watchdog.service            # watchdog сервис
    ├── lte-watchdog.timer              # watchdog таймер (каждые 5 мин)
    ├── wifi-ap.service                 # автостарт WiFi AP
    ├── ltemod-vpn.service              # автостарт VPN (читает VPN_PROTO из конфига)
    ├── sing-box.service                # sing-box daemon (VLESS, управляется vpn-toggle)
    ├── ltemod-bypass-update.service    # обновление bypass-списков
    └── ltemod-bypass-update.timer      # ежедневный таймер (04:00)
```

---

## Известные ограничения

- **WiFi 802.11n отключён** — драйвер `brcmfmac` (AP6256/BCM4345) не поддерживает HT_SCAN в AP режиме. Работает в режиме 802.11g (до 54 Mbps).
- **WiFi AP + клиент одновременно** — требует поддержки concurrent mode в драйвере. На AP6256 работает нестабильно.
- **AmneziaWG** — требует отдельной установки модуля ядра (см. [amnezia-vpn/amneziawg-linux-kernel-module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module)).

---

## Логи

```bash
journalctl -u lte-modem -f        # LTE подключение
journalctl -u lte-watchdog -f     # watchdog
journalctl -u wifi-ap -f          # WiFi AP
journalctl -u sing-box -f         # VLESS
```
