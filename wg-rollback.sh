#!/usr/bin/env bash
#
# wg-rollback.sh — полный откат WireGuard-in-Docker установки.
#
# Переносит конфиги и ключи в ~/wg-backup/rollback-<timestamp>/, возвращает
# хостовые настройки (nftables, sysctl, SSH, Docker) к состоянию из последнего
# бэкапа ~/wg-backup/orig-*/.
#
# Использование:
#   /root/wg-rollback.sh [--yes] [--purge-image] [--purge-docker]
#
#   --yes            не спрашивать подтверждение
#   --purge-image    также удалить docker-образ wg-server:latest
#   --purge-docker   также удалить пакет docker.io (и /var/lib/docker)
#
set -euo pipefail

CONTAINER="wg"
IMAGE="wg-server:latest"
WG_DIR="/root/wg-docker"
BACKUP_ROOT="/root/wg-backup"
NFT_CONF="/etc/nftables.conf"
SYSCTL_FILE="/etc/sysctl.d/99-wireguard.conf"
MODLOAD_FILE="/etc/modules-load.d/wireguard.conf"
DOCKER_DAEMON="/etc/docker/daemon.json"
SSHD_DROPIN="/etc/ssh/sshd_config.d/10-wg-port.conf"

ASSUME_YES=0
PURGE_IMAGE=0
PURGE_DOCKER=0
for arg in "$@"; do
  case "$arg" in
    --yes)          ASSUME_YES=1 ;;
    --purge-image)  PURGE_IMAGE=1 ;;
    --purge-docker) PURGE_DOCKER=1 ;;
    -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Неизвестный аргумент: $arg" >&2; exit 1 ;;
  esac
done

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "Запускать нужно от root." >&2; exit 1; }

ORIG="$(ls -1d "$BACKUP_ROOT"/orig-* 2>/dev/null | sort | tail -1 || true)"
if [ -z "${ORIG:-}" ]; then
  warn "Не найден каталог бэкапа $BACKUP_ROOT/orig-* — хостовые файлы восстанавливать не из чего."
else
  log "Использую оригиналы из: $ORIG"
fi

TS="$(date +%Y%m%d-%H%M%S)"
ROLLBACK_DIR="$BACKUP_ROOT/rollback-$TS"

if [ "$ASSUME_YES" -ne 1 ]; then
  echo
  warn "Будет выполнен ПОЛНЫЙ откат: остановка контейнера, снятие nftables,"
  warn "возврат sysctl/SSH/Docker, перенос конфигов и ключей в:"
  echo "    $ROLLBACK_DIR"
  read -r -p "Продолжить? [y/N] " ans
  case "$ans" in y|Y|yes|YES) ;; *) echo "Отменено."; exit 0 ;; esac
fi

mkdir -p "$ROLLBACK_DIR"

# --- 1. Остановка и удаление контейнера -------------------------------------
if command -v docker >/dev/null 2>&1; then
  if docker inspect "$CONTAINER" >/dev/null 2>&1; then
    log "Останавливаю и удаляю контейнер $CONTAINER..."
    docker stop "$CONTAINER" >/dev/null 2>&1 || true
    docker rm -f "$CONTAINER"   >/dev/null 2>&1 || true
  else
    log "Контейнер $CONTAINER не найден — пропускаю."
  fi
  if [ "$PURGE_IMAGE" -eq 1 ]; then
    docker rmi "$IMAGE" >/dev/null 2>&1 && ok "Образ $IMAGE удалён." || warn "Образ $IMAGE не удалён (возможно, отсутствует)."
  fi
else
  log "Docker не установлен — пропускаю шаг с контейнером."
fi

# --- 2. nftables: вернуть оригинал и снять активные правила -----------------
log "Возвращаю правила nftables..."
if [ -n "${ORIG:-}" ] && [ -f "$ORIG/nftables.conf" ]; then
  cp -a "$ORIG/nftables.conf" "$NFT_CONF"
elif [ ! -f "$NFT_CONF" ]; then
  printf '#!/usr/sbin/nft -f\nflush ruleset\n' > "$NFT_CONF"
fi
nft flush ruleset 2>/dev/null || true
if [ -f "$NFT_CONF" ]; then
  nft -f "$NFT_CONF" 2>/dev/null || warn "Не удалось применить $NFT_CONF (возможно, он загружается через systemd)."
fi
if systemctl list-unit-files 2>/dev/null | grep -q '^nftables.service'; then
  systemctl disable --now nftables >/dev/null 2>&1 || true
fi
ok "nftables возвращён в исходное состояние."

# --- 3. Docker daemon.json: вернуть оригинал --------------------------------
if [ -n "${ORIG:-}" ] && [ -f "$ORIG/docker/daemon.json" ]; then
  mkdir -p /etc/docker
  cp -a "$ORIG/docker/daemon.json" "$DOCKER_DAEMON"
elif [ -f "$DOCKER_DAEMON" ]; then
  rm -f "$DOCKER_DAEMON"
fi
ok "Конфигурация Docker daemon.json возвращена."

# --- 4. SSH: убрать наш drop-in и перезагрузить sshd ------------------------
log "Возвращаю настройки SSH..."
rm -f "$SSHD_DROPIN"
if [ -n "${ORIG:-}" ] && [ -d "$ORIG/ssh/sshd_config.d" ]; then
  mkdir -p /etc/ssh/sshd_config.d
  cp -a "$ORIG/ssh/sshd_config.d/." /etc/ssh/sshd_config.d/ 2>/dev/null || true
fi
if [ -n "${ORIG:-}" ] && [ -f "$ORIG/ssh/sshd_config" ]; then
  cp -a "$ORIG/ssh/sshd_config" /etc/ssh/sshd_config
fi
if command -v sshd >/dev/null 2>&1 && sshd -t >/dev/null 2>&1; then
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  ok "SSH перезагружен (порт 22 снова как в оригинале)."
else
  warn "Проверка sshd -t не прошла — SSH не перезагружен. Проверьте конфиг вручную!"
fi

# --- 5. sysctl: убрать наш файл и вернуть значения --------------------------
log "Возвращаю sysctl..."
rm -f "$SYSCTL_FILE"
if [ -n "${ORIG:-}" ] && [ -d "$ORIG/sysctl" ]; then
  mkdir -p /etc/sysctl.d
  cp -a "$ORIG/sysctl/." /etc/sysctl.d/ 2>/dev/null || true
fi
sysctl -w net.ipv4.ip_forward=0           >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.all.forwarding=0  >/dev/null 2>&1 || true
sysctl --system >/dev/null 2>&1 || true
ok "sysctl восстановлен (forwarding выключен)."

# --- 6. modules-load: убрать автозагрузку wireguard -------------------------
log "Убираю автозагрузку модуля wireguard..."
rm -f "$MODLOAD_FILE"
if [ -n "${ORIG:-}" ] && [ -d "$ORIG/modules-load" ]; then
  cp -a "$ORIG/modules-load/." /etc/modules-load.d/ 2>/dev/null || true
fi
ok "modules-load.d очищен (модуль останется загруженным до перезагрузки)."

# --- 7. Перенос конфигов и ключей ------------------------------------------
log "Переношу конфиги и ключи в $ROLLBACK_DIR ..."
if [ -d "$WG_DIR" ]; then
  mkdir -p "$ROLLBACK_DIR"
  cp -a "$WG_DIR" "$ROLLBACK_DIR/"
  rm -rf "$WG_DIR"
  ok "Каталог $WG_DIR перенесён."
else
  warn "$WG_DIR не найден — переносить нечего."
fi
# на случай прямого (не-docker) размещения в /etc/wireguard
if [ -d /etc/wireguard ]; then
  cp -a /etc/wireguard "$ROLLBACK_DIR/etc-wireguard"
  rm -rf /etc/wireguard
  ok "/etc/wireguard также перенесён."
fi

# --- 8. Опционально: удалить Docker -----------------------------------------
if [ "$PURGE_DOCKER" -eq 1 ]; then
  if dpkg -s docker.io >/dev/null 2>&1; then
    log "Удаляю пакет docker.io..."
    systemctl disable --now docker >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y docker.io containerd >/dev/null 2>&1 || warn "apt remove docker.io завершился с ошибкой."
    apt-get autoremove -y >/dev/null 2>&1 || true
    rm -rf /var/lib/docker /etc/docker
    ok "Docker удалён."
  else
    log "Пакет docker.io не установлен — пропускаю."
  fi
fi

# --- 9. Итог ----------------------------------------------------------------
echo
ok "Откат завершён."
echo "    Бэкап конфигов и ключей:  $ROLLBACK_DIR"
[ -n "${ORIG:-}" ] && echo "    Оригиналы хостовых файлов: $ORIG"
echo
echo "Проверьте: ssh-порт, внешний фаервол, отсутствие интерфейса wg0:"
echo "    ip link show wg0 2>/dev/null || echo 'wg0 отсутствует — ок'"
