# Документация: подключение клиентов к WireGuard

Руководство по выдаче, установке, управлению и диагностике клиентов WireGuard
для сервера, развёрнутого в `/root/wg-docker` (контейнер `wg`).

---

## 1. Параметры сервера

| Параметр | Значение |
|---|---|
| Публичный адрес (Endpoint) | `<SERVER_IP>:38471` |
| Публичный ключ сервера | `<SERVER_PUBLIC_KEY>` |
| Транспорт | UDP (порт 38471) |
| Внутренний IPv4 сервера | `10.8.0.1` (сеть `10.8.0.0/24`) |
| Внутренний IPv6 сервера | `fd42:8:8::1` (сеть `fd42:8:8::/64`) |
| DNS клиентам | `10.8.0.1`, `fd42:8:8::1` (рекурсивный unbound, DNSSEC) |
| MTU | `1420` |
| Режим туннеля | полный (`0.0.0.0/0, ::/0`), шлюз = сервер |

> Значения можно проверить на сервере: `cat /root/wg-docker/config/server.pub`
> и `cat /root/wg-docker/config/endpoint`.

---

## 2. Быстрый старт (уже выпущенный клиент `deja-pc`)

Готовый конфиг лежит на сервере:
```
/root/wg-docker/config/clients/deja-pc/deja-pc.conf
```
Скопируйте его содержимое на устройство (см. §4 «Импорт по платформам») и
включите туннель. Проверка: внешний IP должен стать `<SERVER_IP>`.

Конфиг `deja-pc`:
```ini
[Interface]
PrivateKey = <CLIENT_PRIVATE_KEY>
Address = 10.8.0.2/24, fd42:8:8::2/64
DNS = 10.8.0.1, fd42:8:8::1
MTU = 1420

[Peer]
PublicKey = <SERVER_PUBLIC_KEY>
PresharedKey = <CLIENT_PSK>
Endpoint = <SERVER_IP>:38471
AllowedIPs = 10.8.0.0/24, fd42:8:8::/64, 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

---

## 3. Выпуск нового клиента

Выполняется на сервере. Одной командой генерируются ключи и PSK, выделяется
свободный адрес, создаётся `.conf` и peer применяется без разрыва сессий:

```bash
docker exec wg gen-client.sh <имя-клиента>
```

По умолчанию печатается **сводка для ручной настройки** (адрес, DNS, MTU,
endpoint, публичный ключ сервера, пути к файлам). Конфиг выводится сразу, если
указать формат:

```bash
docker exec wg gen-client.sh <имя> --format both    # ini + xray
docker exec wg gen-client.sh <имя> --format ini     # только WireGuard .conf
docker exec wg gen-client.sh <имя> --format xray    # сохранит <имя>.xray.json
```

Правила имени: `A–Z a–z 0–9 _ -`. Пример:
```bash
docker exec wg gen-client.sh laptop --format both
```

Что появится:
```
/root/wg-docker/config/clients/<имя>/
├── <имя>.conf        # конфиг WireGuard (сохраняется всегда)
├── <имя>.xray.json   # конфиг Xray (только если --format включает xray)
├── priv.key          # приватный ключ
├── pub.key           # публичный ключ
└── psk.key           # Preshared Key
```
Серверный peer при этом добавляется в `config/wg0.conf` и применяется
(`wg syncconf`), поэтому перезапуск контейнера не нужен.

Адреса выдаются последовательно: `10.8.0.2`, `10.8.0.3`, … и `fd42:8:8::2`, `::3`, …

### Показать актуальный конфиг клиента
`show-client.sh` пересобирает конфиг из ключей клиента, `server.pub`, `endpoint`
и **текущего** `allowed-ips.list` (то есть отражает последние изменения списка):

```bash
docker exec wg show-client.sh <имя> --format ini      # WireGuard .conf
docker exec wg show-client.sh <имя> --format xray     # Xray JSON
docker exec wg show-client.sh <имя> --format link     # ссылка wireguard:// (Happ/sing-box)
docker exec wg show-client.sh <имя> --format both      # ini + xray
docker exec wg show-client.sh <имя> --format ini --qr  # + QR (нужен qrencode)
```
`show-client.sh` ничего не меняет на сервере; при `--save` дополнительно
обновляет файлы `<имя>.conf` / `<имя>.xray.json` / `<имя>.link.txt`.

#### Ссылка `--format link` (Happ / sing-box)
Формируется самодостаточная ссылка `wireguard://`, в которой уже есть все данные
(ключи, адрес, endpoint, PSK) — клиент **не обращается к серверу**:

```
wireguard://<PrivateKey>@<host>:<port>?publickey=<ServerPublicKey>&address=<IPv4>/32,<IPv6>/128&mtu=1420&presharedkey=<PSK>#<имя>
```
Её можно вставить в телефон (Happ/V2rayTun и совместимые клиенты) или сгенерировать
из неё QR. Параметры: `publickey`, `address`, `mtu`, `presharedkey`, заголовок после `#`.
(Параметр `reserved` не используется — он только для Cloudflare WARP.)

---

## 4. Импорт по платформам

### Windows
1. Установите WireGuard из официального сайта.
2. `Add tunnel` → `Import tunnel(s) from file…` → выберите `<имя>.conf`.
3. `Activate`.

### macOS
1. Приложение WireGuard из App Store.
2. `+` → `Import tunnel(s) from file…` → `<имя>.conf` → `Activate`.
   (Альтернатива через Homebrew: `brew install wireguard-tools`, затем
   `wg-quick up ./<имя>.conf`.)

### Linux
```bash
sudo install -m 600 <имя>.conf /etc/wireguard/<имя>.conf
sudo wg-quick up <имя>          # поднять
sudo wg-quick down <имя>        # опустить
sudo systemctl enable wg-quick@<имя>   # автозапуск (по желанию)
```
Требуется пакет `wireguard-tools`.

### Android
1. Приложение WireGuard (Google Play / F-Droid).
2. `+` → `Import from file or archive` → `<имя>.conf` → включить переключатель.

### iOS / iPadOS
1. Приложение WireGuard (App Store).
2. `+` → `Create from file or archive` → `<имя>.conf` → включить.

### OpenWrt / роутер
- LuCI: `Network` → `Interfaces` → `Add new interface` → протокол `WireGuard VPN`,
  либо импорт готового конфига (в зависимости от версии).
- CLI: пакеты `kmod-wireguard` `wireguard-tools`, затем
  `wg-quick up <имя>` / настройка через UCI.

### QR-код
На сервере пакет `qrencode` не установлен (в целях экономии RAM). Сгенерировать
QR можно на любом устройстве с `qrencode`:
```bash
qrencode -t ansiutf8 < <имя>.conf      # вывод в терминал
qrencode -o <имя>.png < <имя>.conf     # файл-картинка
```
Мобильные приложения WireGuard также умеют импортировать `.conf` напрямую и
показывать QR по уже добавленному туннелю.

---

## 4.1. Клиент Xray-core (WireGuard outbound)

> Готовый конфиг можно получить автоматически:
> `docker exec wg show-client.sh <имя> --format xray` (или `--format both`).

Xray-core (v1.8.6+) умеет WireGuard как **userspace-outbound**. Это и есть
«режим прокси»: Xray поднимает локальный SOCKS/HTTP, а в туннель уходит только
тот трафик, который Xray туда направил. Сервер при этом остаётся обычным
WireGuard. То есть «VPN в режиме прокси» = WireGuard-туннель, поднятый изнутри
Xray, а не отдельный прокси-протокол.

**Критично** (типичный симптом «handshake есть, но в интернет ничего не идёт»):

- `address` **обязан** совпадать с `AllowedIPs` этого клиента на сервере:
  `10.8.0.2/32` и `fd42:8:8::2/128`. Если `address` не задан, Xray берёт
  дефолт `10.0.0.1`, и сервер **молча отбрасывает** все внутренние пакеты —
  при этом handshake проходит, что вводит в заблуждение.
- `remoteDNS` = `["10.8.0.1", "fd42:8:8::1"]` — иначе доменные имена не
  резолвятся внутри туннеля (цели внутри WG-туннеля обязаны быть IP).
- `preSharedKey` — тот же PSK, что и на сервере.
- Браузер/система должны быть настроены на локальный прокси Xray (`socks`/`http`).

Пример конфига (ключи и адрес берутся из `config/clients/<имя>/`):

```json
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "tag": "socks", "listen": "127.0.0.1", "port": 10808,
      "protocol": "socks", "settings": { "udp": true } },
    { "tag": "http",  "listen": "127.0.0.1", "port": 10809, "protocol": "http" }
  ],
  "outbounds": [
    {
      "tag": "wg",
      "protocol": "wireguard",
      "settings": {
        "secretKey": "<CLIENT_PRIVATE_KEY>",
        "address": ["10.8.0.2/32", "fd42:8:8::2/128"],
        "mtu": 1420,
        "noKernelTun": true,
        "remoteDNS": ["10.8.0.1", "fd42:8:8::1"],
        "peers": [
          {
            "endpoint": "<SERVER_IP>:38471",
            "publicKey": "<SERVER_PUBLIC_KEY>",
            "preSharedKey": "<CLIENT_PSK>",
            "allowedIPs": ["0.0.0.0/0", "::/0"],
            "keepAlive": 25
          }
        ]
      }
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [ { "type": "field", "network": "tcp,udp", "outboundTag": "wg" } ]
  }
}
```

Браузер → SOCKS `127.0.0.1:10808` или HTTP `127.0.0.1:10809`.
Признак успеха: на сервере растут счётчики `wg0-in` и `wg0->wan` (см. §7).

---

## 5. Полный туннель и split-tunnel

- **Сейчас (полный туннель):** `AllowedIPs = 0.0.0.0/0, ::/0` — весь трафик
  клиента идёт через сервер. Список для новых клиентов задаётся в
  `/root/wg-docker/config/allowed-ips.list`.
- **Split-tunnel:** отредактируйте `allowed-ips.list` (одна подсеть CIDR на
  строку, `#` — комментарий), удалив `0.0.0.0/0` и `::/0`. Новые клиенты
  получат нужные маршруты автоматически.

### Изменить маршруты у УЖЕ выпущенного клиента
Ключи при этом менять не нужно — достаточно поправить строку `AllowedIPs`
в его `.conf` и переимпортировать конфиг на устройстве:
```ini
# было (полный туннель)
AllowedIPs = 10.8.0.0/24, fd42:8:8::/64, 0.0.0.0/0, ::/0
# стало (только доступ к VPN и DNS)
AllowedIPs = 10.8.0.0/24, fd42:8:8::/64
```
> Важно: `10.8.0.0/24` (или хотя бы `10.8.0.1/32`) должен остаться в
> `AllowedIPs`, иначе клиент не достучится до DNS-сервера.

---

## 6. Управление клиентами

### Список клиентов
```bash
ls -1 /root/wg-docker/config/clients/
cat /root/wg-docker/config/wg0.conf          # адреса и комментарии с именами
docker exec wg wg show                       # активные peer'ы и последний handshake
```

### Отзыв клиента (revoke)
Удаляет peer из серверного конфига и применяет изменения; приватный ключ
отозванного клиента после этого бесполезен.

```bash
NAME=deja-pc
CONF=/root/wg-docker/config/wg0.conf

cp -a "$CONF" "$CONF.bak.$(date +%s)"
awk -v name="$NAME" '
  BEGIN{RS=""; ORS="\n\n"}
  $0 !~ ("# " name "\n")
' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"

docker exec wg wg syncconf wg0 /config/wg0.conf
# при желании — убрать файлы клиента:
# mv /root/wg-docker/config/clients/$NAME /root/wg-docker/config/clients/_revoked_$NAME
```

### Ротация Preshared Key (PSK) для клиента
```bash
NAME=deja-pc
D=/root/wg-docker/config/clients/$NAME
NEWPSK=$(docker exec wg wg genpsk)
# заменить строку PresharedKey в серверном wg0.conf и в клиентском .conf
sed -i "/^# $NAME$/{n;n;s|^PresharedKey = .*|PresharedKey = $NEWPSK|}" /root/wg-docker/config/wg0.conf
sed -i "s|^PresharedKey = .*|PresharedKey = $NEWPSK|" "$D/$NAME.conf"
docker exec wg wg syncconf wg0 /config/wg0.conf
```
После этого переимпортируйте обновлённый `$D/$NAME.conf` на устройстве.

---

## 7. Диагностика

Проверки **на клиенте**:
```bash
# Linux: состояние туннеля (должен быть latest handshake)
sudo wg show

# доступ к серверу внутри туннеля
ping -c2 10.8.0.1

# DNS через туннель
nslookup example.com 10.8.0.1

# внешний IP (для полного туннеля должен быть <SERVER_IP>)
curl -4 https://ifconfig.me ; curl -6 https://ifconfig.me
```

Проверки **на сервере**:
```bash
docker ps --filter name=wg                 # контейнер healthy
docker logs wg | tail                      # логи entrypoint/unbound
docker exec wg wg show                     # peer'ы и handshake
journalctl -k | grep nft-drop              # дропы фаервола

# счётчики туннеля (включены в /etc/nftables.conf)
nft list chain inet filter input   | grep -E 'wg0-in|udp dport 53'
nft list chain inet filter forward | grep 'wg0->wan'
journalctl -k | grep wg-fwd-new            # новые соединения из туннеля
```

> Если handshake есть, а `wg0-in` и `wg0->wan` остаются `0` — клиент не
> отправляет прикладной трафик. Для Xray это почти всегда несовпадение
> `address` с `AllowedIPs` сервера (см. §4.1).

Подробное логирование для отладки (можно включать/выключать):
```bash
# включить: в /root/wg-docker/config/unbound.conf
#   verbosity: 2
#   log-queries: yes
docker restart wg
docker logs -f wg | grep -Ei 'query|reply'
# после отладки вернуть verbosity: 1 и убрать log-queries, затем docker restart wg
```

Типовые проблемы:

| Симптом | Причина и решение |
|---|---|
| Нет handshake | Неверный порт/Endpoint, не тот публичный ключ сервера, peer не добавлен, UDP-порт закрыт. Проверьте `docker exec wg wg show` и `nc -vzu <SERVER_IP> 38471`. |
| Handshake есть, но сайты не открываются | На сервере нет forwarding/NAT. Проверьте `cat /proc/sys/net/ipv4/ip_forward` (=1) и правила `nft list ruleset`. |
| Соединение нестабильно, часть сайтов не грузится | Проблема MTU. Уменьшите `MTU` в конфиге клиента: 1380 → 1280. |
| Не работает DNS | В `AllowedIPs` нет `10.8.0.0/24` / `10.8.0.1`; или клиент переопределяет DNS. Проверьте `nslookup example.com 10.8.0.1`. |
| Работает IPv4, не работает IPv6 | Нет NAT66/маршрутов; проверьте `ip -6 route` на сервере и `net.ipv6.conf.all.forwarding=1`. |
| Handshake есть, но трафика нет (`wg0-in`/`wg0->wan` = 0) | Клиент не шлёт данные. У Xray это почти всегда не задан/неверен `address` (должен быть `10.8.0.2/32`), нет `remoteDNS` или браузер не ходит через локальный прокси Xray. См. §4.1. |
| У Xray не резолвятся домены внутри туннеля | Не задан `remoteDNS` (`["10.8.0.1","fd42:8:8::1"]`) либо нет `domainStrategy`/`targetStrategy`. |
| Клиенты не видят друг друга | Так и задумано: включена изоляция клиентов (на сервере `/32` и `/128`, `wg0→wg0` запрещён). |

---

## 8. Безопасность

- Приватный ключ клиента (`PrivateKey`) и `PresharedKey` — секретны. Не
  публикуйте `.conf` целиком; храните файлы с правами `600`.
- На сервере все ключи лежат в `/root/wg-docker/config/` (доступ только root).
- Каждому клиенту выдаётся уникальная пара ключей и уникальный PSK.
- Отозванным клиентам доступ закрывается только через удаление peer (см. §6);
  одного «удаления» приложения на устройстве недостаточно.
- Для смены области маршрутизации ключи перевыпускать не нужно (§5), а для
  нового устройства — всегда используйте `gen-client.sh` (§3).

---

## 9. Справочник команд (на сервере)

```bash
# выпустить нового клиента (по умолчанию — сводка)
docker exec wg gen-client.sh <имя>
docker exec wg gen-client.sh <имя> --format both   # сразу вывести ini+xray

# показать актуальный конфиг существующего клиента
docker exec wg show-client.sh <имя> --format ini|xray|both|link
docker exec wg show-client.sh <имя> --format link        # ссылка wireguard:// для Happ
docker exec wg show-client.sh <имя> --format ini --qr    # + QR (нужен qrencode)

# ключи сервера: создать/поддерживать wg0.conf (идемпотентно, клиенты сохраняются)
docker exec wg gen-server.sh
docker exec wg gen-server.sh --force   # перегенерировать ключ сервера (разорвёт клиентов!)

# посмотреть серверные peer'ы
docker exec wg wg show

# путь к конфигу клиента
cat /root/wg-docker/config/clients/<имя>/<имя>.conf

# применить изменения wg0.conf без разрыва
docker exec wg wg syncconf wg0 /config/wg0.conf

# управление сервером
docker restart wg
/root/wg-docker/up.sh

# полный откат (перенос конфигов и ключей в ~/wg-backup/)
/root/wg-rollback.sh
```

См. также самодостаточный промт для развёртывания на другой системе:
`/root/promt-wg.txt`.
