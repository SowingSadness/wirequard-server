# deja-wg — WireGuard-шлюз в Docker (шаблон развёртывания)

Централизованный репозиторий решения: WireGuard-сервер в Docker + рекурсивный
DNS (unbound) + фаервол nftables/NAT на хосте + генератор клиентов + скрипт отката.

> **В репозитории НЕТ секретов.** Ключи сервера/клиентов, `wg0.conf`, клиентские
> `.conf`, `endpoint` и сгенерированный `unbound.conf` создаются на сервере при
> первом запуске и **не коммитятся** (см. `.gitignore`).

## Состав

```
deja-wg/
├── quick-start.sh          # авторазвёртывание сервера с нуля одной командой
├── promt-wg.txt            # пошаговый промт для развёртывания с нуля
├── WIREGUARD-CLIENTS.md    # документация по подключению клиентов
├── wg-rollback.sh          # полный откат установки (конфиги -> ~/wg-backup)
├── docker/
│   ├── Dockerfile
│   ├── entrypoint.sh       # поднимает wg0 (kernel) + unbound
│   ├── gen-server.sh       # генерация ключей сервера (идемпотентно)
│   ├── gen-client.sh       # генератор клиентов
│   ├── show-client.sh      # вывод актуального конфига клиента (ini/xray/both)
│   ├── unbound.conf.default
│   ├── up.sh               # сборка + запуск с усиленными флагами
│   └── config/
│       └── allowed-ips.list   # список подсетей для клиентов (редактируемый)
└── host/
    ├── nftables.conf          # фаервол + NAT44/NAT66 + логирование дропов
    ├── 99-wireguard.conf      # sysctl: forwarding + усиление
    ├── docker-daemon.json     # iptables:false, bridge:none
    └── sshd-10-wg-port.conf   # SSH на порту 8222
```

## Что НЕ входит (и почему)

| Не входит | Причина |
|---|---|
| `server.key`, `server.pub` | приватный ключ сервера — секрет |
| `clients/*/priv.key`, `psk.key`, `pub.key`, `<имя>.conf` | ключи и конфиги клиентов |
| `wg0.conf` | содержит `PrivateKey` сервера |
| `endpoint` | рантайм-файл (автоопределяется) |
| `unbound.conf`, `unbound/root.key` | генерируются при первом запуске |

Все они создаются автоматически:
- `gen-server.sh` — ключи сервера и `wg0.conf` (вызывается из `entrypoint.sh`);
- `entrypoint.sh` — поднимает `wg0` и генерирует `unbound.conf`;
- `gen-client.sh` — ключи клиента, PSK и `<имя>.conf` (Xray — только с `--format`).

## Развёртывание на новом сервере

### Быстрый путь (Debian/Ubuntu, root)
```bash
git clone https://github.com/SowingSadness/wirequard-server.git
cd wirequard-server
./quick-start.sh                      # SSH-порт по умолчанию 22
# опции:
#   --ssh-port 8222   дополнительно включить SSH на 8222
#   --wg-port 38471    UDP-порт WireGuard
#   --wan eth0         WAN-интерфейс (по умолчанию определяется автоматически)
#   --qr               установить qrencode для QR-кодов
```
Скрипт поставит зависимости, разложит файлы, настроит Docker/sysctl/nftables,
соберёт образ, запустит контейнер и напечатает, как добавить клиента.
Пользователей не создаёт; ключи и клиенты при повторном запуске сохраняются.

### Пошагово — в `promt-wg.txt`. Кратко:

1. Установить зависимости и разложить файлы:
   - `docker/ → /root/wg-docker/`
   - `host/nftables.conf → /etc/nftables.conf`
   - `host/99-wireguard.conf → /etc/sysctl.d/99-wireguard.conf`
   - `host/docker-daemon.json → /etc/docker/daemon.json`
   - `host/sshd-10-wg-port.conf → /etc/ssh/sshd_config.d/10-wg-port.conf`
2. `modprobe wireguard`; `systemctl enable --now docker`.
3. Собрать и запустить: `cd /root/wg-docker && ./up.sh`.
4. Применить хост-настройки: `sysctl --system`, `nft -f /etc/nftables.conf`.
5. Ключи сервера создаются автоматически при первом запуске. Вручную / при
   необходимости: `docker exec wg gen-server.sh` (`--force` — перегенерировать).
6. Выпустить клиента: `docker exec wg gen-client.sh <имя>` (по умолчанию — сводка).
   Конфиг: `docker exec wg show-client.sh <имя> --format ini|xray|both`.

## Обновление решения (централизованно)

1. Меняете файлы в этом репозитории.
2. На сервере: `git pull` (или копирование файлов).
3. Если обновился образ: `cd /root/wg-docker && ./up.sh` (пересоберёт и перезапустит).
4. Ключи и клиенты на сервере при этом сохраняются (они в `config/`, не в git).

## Безопасность

- Секреты не коммитить (`.gitignore` уже это предотвращает).
- Файлы на сервере: ключи `600`, каталог `config/` доступен только root.
- Контейнер: `--network host`, `cap-drop ALL` + минимальный набор caps,
  `no-new-privileges`, `--read-only`, лимиты памяти/pids.
