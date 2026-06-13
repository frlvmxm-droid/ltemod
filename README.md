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
VPN_PROTO="wg"    # wg / amnezia / vless / none
```

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

## Структура проекта

```
ltemod/
├── install.sh                  # установщик
├── config/
│   └── ltemod.conf             # центральный конфиг (шаблон)
├── modem/
│   ├── connect-modem.sh        # подключение LTE
│   ├── modem-status.sh         # статус всей системы
│   ├── modem-watchdog.sh       # watchdog переподключения
│   └── 99-em7565.rules         # udev правила для EM7565
├── network/
│   ├── setup-routing.sh        # настройка маршрутизации и NAT
│   └── vpn-toggle.sh           # переключение VPN протоколов
├── vpn/
│   ├── setup-vpn.sh            # установка WireGuard конфига
│   ├── setup-amnezia.sh        # установка AmneziaWG конфига
│   ├── setup-vless.sh          # установка VLESS конфига
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
    ├── lte-modem.service       # запуск LTE при старте
    ├── lte-watchdog.service    # watchdog сервис
    ├── lte-watchdog.timer      # watchdog таймер (каждые 5 мин)
    └── wifi-ap.service         # автостарт WiFi AP
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
