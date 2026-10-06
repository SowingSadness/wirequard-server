#!/usr/bin/env bash
#
# quick-start.sh [--wg-port N] [--ssh-port N] [--wan IFACE] [--qr] [--yes]
#
# Разворачивает WireGuard-сервер на Debian/Ubuntu (systemd, root) одной командой:
#   * ставит зависимости (docker.io, nftables [, qrencode с --qr]);
#   * раскладывает docker/ и host/ из ЭТОГО репозитория;
#   * настраивает Docker, sysctl, nftables;
#   * собирает образ и запускает контейнер;
#   * печатает в консоль, как добавить клиента.
#
# Пользователей НЕ создаёт. Ключи сервера, клиенты и allowed-ips.list не
# перезаписываются — повторный запуск обновляет только файлы и перезапускает
# контейнер.
#
# По умолчанию SSH-порт 22 (не меняется). --ssh-port N дополнительно включает
# SSH на порту N (22 остаётся как страховка).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DOCKER="$SCRIPT_DIR/docker"
SRC_HOST="$SCRIPT_DIR/host"

WG_DIR="/root/wg-docker"
BACKUP_ROOT="/root/wg-backup"
IMAGE="wg-server:latest"
CONTAINER="wg"

WG_PORT=38471
SSH_PORT=22
WAN=""
DO_QR=0
YES=0

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --wg-port)  WG_PORT="${2:?}"; shift 2 ;;
    --ssh-port) SSH_PORT="${2:?}"; shift 2 ;;
    --wan)      WAN="${2:?}"; shift 2 ;;
    --qr)       DO_QR=1; shift ;;
    --yes|-y)   YES=1; shift ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *) die "неизвестный аргумент: $1" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "запускать нужно от root"
[ -f "$SRC_DOCKER/Dockerfile" ] || die "не найден $SRC_DOCKER/Dockerfile (запускайте из репозитория)"
[ -f "$SRC_HOST/nftables.conf" ] || die "не найден $SRC_HOST/nftables.conf"

# --- WAN ---------------------------------------------------------------------
if [ -z "$WAN" ]; then
  WAN="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
fi
[ -n "$WAN" ] || die "не удалось определить WAN-интерфейс (укажите --wan IFACE)"
log "WAN=$WAN  WG_PORT=$WG_PORT  SSH_PORT=$SSH_PORT  QR=$DO_QR"

# --- зависимости -------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
need=""
command -v docker >/dev/null 2>&1 || need="$need docker.io"
command -v nft    >/dev/null 2>&1 || need="$need nftables"
if [ "$DO_QR" -eq 1 ] && ! command -v qrencode >/dev/null 2>&1; then need="$need qrencode"; fi
if [ -n "${need// /}" ]; then
  log "устанавливаю пакеты:$need"
  apt-get update -qq
  # shellcheck disable=SC2086
  apt-get install -y -qq $need
else
  log "зависимости уже установлены"
fi

# --- бэкап оригиналов (один раз, до правок) ----------------------------------
mkdir -p "$BACKUP_ROOT"
if ! ls -1d "$BACKUP_ROOT"/orig-* >/dev/null 2>&1; then
  TS="$(date +%Y%m%d-%H%M%S)"; BK="$BACKUP_ROOT/orig-$TS"
  log "бэкап оригиналов → $BK"
  mkdir -p "$BK"/{ssh,sysctl,modules-load,docker}
  [ -f /etc/ssh/sshd_config ]    && cp -a /etc/ssh/sshd_config "$BK/ssh/"
  [ -d /etc/ssh/sshd_config.d ]  && cp -a /etc/ssh/sshd_config.d "$BK/ssh/"
  [ -f /etc/resolv.conf ]        && cp -a /etc/resolv.conf "$BK/"
  [ -f /etc/nftables.conf ]      && cp -a /etc/nftables.conf "$BK/"
  cp -a /etc/sysctl.d/. "$BK/sysctl/" 2>/dev/null || true
  cp -a /etc/modules-load.d/. "$BK/modules-load/" 2>/dev/null || true
  [ -f /etc/docker/daemon.json ] && cp -a /etc/docker/daemon.json "$BK/docker/"
  ss -tulpn > "$BK/listening-ports.txt" 2>/dev/null || true
  nft list ruleset > "$BK/nft-ruleset-before.txt" 2>/dev/null || true
  echo "$TS" > "$BACKUP_ROOT/LAST_ORIG_TS"
else
  log "бэкап оригиналов уже существует — пропускаю"
fi

# --- docker daemon.json ------------------------------------------------------
log "настраиваю Docker (daemon.json: iptables:false, bridge:none)"
mkdir -p /etc/docker
cp -a "$SRC_HOST/docker-daemon.json" /etc/docker/daemon.json

# --- модуль ядра -------------------------------------------------------------
log "загружаю модуль wireguard"
modprobe wireguard
printf 'wireguard\n' > /etc/modules-load.d/wireguard.conf

# --- проект в /root/wg-docker (config НЕ перезаписываем) ---------------------
log "раскладываю файлы в $WG_DIR (ключи/клиенты сохраняются)"
mkdir -p "$WG_DIR/config"
for f in Dockerfile entrypoint.sh gen-server.sh gen-client.sh show-client.sh unbound.conf.default up.sh; do
  cp -a "$SRC_DOCKER/$f" "$WG_DIR/$f"
done
if [ ! -f "$WG_DIR/config/allowed-ips.list" ]; then
  cp -a "$SRC_DOCKER/config/allowed-ips.list" "$WG_DIR/config/allowed-ips.list"
fi

# --- sysctl ------------------------------------------------------------------
log "применяю sysctl (forwarding + усиление)"
cp -a "$SRC_HOST/99-wireguard.conf" /etc/sysctl.d/99-wireguard.conf
sysctl --system >/dev/null

# --- nftables ----------------------------------------------------------------
log "генерирую /etc/nftables.conf (WAN=$WAN, WG_PORT=$WG_PORT, SSH=$SSH_PORT)"
SSH_PORTS="22"
[ "$SSH_PORT" != "22" ] && SSH_PORTS="22, $SSH_PORT"
sed -E \
  -e "s/^define WG_PORT = .*/define WG_PORT = $WG_PORT/" \
  -e "s/^define WAN[[:space:]]*=.*/define WAN     = \"$WAN\"/" \
  -e "s/^([[:space:]]*tcp dport \{)[^}]*(\} accept)/\1 $SSH_PORTS \2/" \
  "$SRC_HOST/nftables.conf" > /etc/nftables.conf
nft -c -f /etc/nftables.conf
nft -f /etc/nftables.conf
systemctl enable nftables >/dev/null 2>&1 || true
ok "nftables применён (наружу: SSH $SSH_PORTS/tcp, UDP $WG_PORT)"

# --- дополнительный SSH-порт (по умолчанию 22 не трогаем) --------------------
if [ "$SSH_PORT" != "22" ]; then
  log "включаю SSH также на порту $SSH_PORT (22 остаётся)"
  mkdir -p /etc/ssh/sshd_config.d
  printf 'Port 22\nPort %s\n' "$SSH_PORT" > /etc/ssh/sshd_config.d/10-wg-port.conf
  if sshd -t 2>/dev/null; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  else
    warn "sshd -t не прошёл — drop-in создан, но sshd НЕ перезагружен"
  fi
fi

# --- Docker: сборка и запуск -------------------------------------------------
log "запускаю Docker"
systemctl enable --now docker >/dev/null 2>&1 || true

log "собираю образ $IMAGE"
DOCKER_BUILDKIT=1 docker build --network=host -t "$IMAGE" "$WG_DIR" >/dev/null

log "запускаю контейнер $CONTAINER"
(cd "$WG_DIR" && ./up.sh)
sleep 3

# --- скрипт отката -----------------------------------------------------------
cp -a "$SCRIPT_DIR/wg-rollback.sh" /root/wg-rollback.sh
chmod 700 /root/wg-rollback.sh

# --- финальное сообщение -----------------------------------------------------
PUB_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)"
SPUB="$(cat "$WG_DIR/config/server.pub" 2>/dev/null || echo '?')"
STATUS="$(docker ps --filter "name=^${CONTAINER}$" --format '{{.Status}}' 2>/dev/null || true)"

cat <<EOF

============================================================
 WireGuard-сервер развёрнут.
   Endpoint:     ${PUB_IP}:${WG_PORT}
   server.pub:   ${SPUB}
   Контейнер:    ${CONTAINER} ${STATUS}
   Проект:       ${WG_DIR}
   Откат:        /root/wg-rollback.sh

 КАК ДОБАВИТЬ КЛИЕНТА:
   docker exec ${CONTAINER} gen-client.sh <имя> --format both

 Показать конфиг/ссылку клиента:
   docker exec ${CONTAINER} show-client.sh <имя> --format both
   docker exec ${CONTAINER} show-client.sh <имя> --format link   # wireguard:// для Happ

 Скачать QR-картинку клиента (если генерировали с --qr):
   scp -P ${SSH_PORT} root@${PUB_IP}:${WG_DIR}/config/clients/<имя>/<имя>.png .
============================================================
EOF
