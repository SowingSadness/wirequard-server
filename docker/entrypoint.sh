#!/usr/bin/env bash
#
# entrypoint.sh — поднимает wg0 (kernel WireGuard) и unbound в одном контейнере.
# Конфиги и ключи живут в /config (bind-mount с хоста).
#
set -euo pipefail
umask 077

CONFIG="${CONFIG_DIR:-/config}"
UNBOUND_DIR="$CONFIG/unbound"
PORT="${WG_PORT:-38471}"
ADDR4="${WG_ADDR4:-10.8.0.1/24}"
ADDR6="${WG_ADDR6:-fd42:8:8::1/64}"
MTU="${WG_MTU:-1420}"

mkdir -p "$CONFIG/clients" "$UNBOUND_DIR"

# --- 1-2. Ключи сервера и wg0.conf (см. gen-server.sh) -----------------------
# gen-server.sh идемпотентен: если ключ уже есть — просто поддерживает wg0.conf
# в актуальном состоянии, сохраняя существующих peer'ов.
gen-server.sh

# --- 3. Конфиг unbound -------------------------------------------------------
if [ ! -s "$CONFIG/unbound.conf" ]; then
  cp /usr/local/share/unbound.conf.default "$CONFIG/unbound.conf"
fi
# Владелец root, группа unbound, 0770: root может chdir до сброса прав,
# а unbound (после setuid) — писать root.key. Без CAP_DAC_OVERRIDE.
chown root:unbound "$UNBOUND_DIR" 2>/dev/null || true
chmod 0770 "$UNBOUND_DIR" 2>/dev/null || true
# Bootstrap DNSSEC trust anchor (root.key), если его ещё нет.
if [ ! -s "$UNBOUND_DIR/root.key" ]; then
  unbound-anchor -a "$UNBOUND_DIR/root.key" >/dev/null 2>&1 || true
  chown root:unbound "$UNBOUND_DIR/root.key" 2>/dev/null || true
  chmod 0660 "$UNBOUND_DIR/root.key" 2>/dev/null || true
fi

# --- 4. Публичный адрес для клиентских конфигов -----------------------------
if [ ! -s "$CONFIG/endpoint" ]; then
  EP="$PORT"
  HOST="${WG_ENDPOINT:-}"
  if [ -z "$HOST" ]; then
    HOST="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)"
  fi
  [ -n "$HOST" ] && echo "$HOST:$EP" > "$CONFIG/endpoint"
fi

# --- 5. Поднимаем wg0 --------------------------------------------------------
ip link del wg0 2>/dev/null || true
ip link add wg0 type wireguard
wg setconf wg0 "$CONFIG/wg0.conf"
ip -4 addr add "$ADDR4" dev wg0 2>/dev/null || true
ip -6 addr add "$ADDR6" dev wg0 2>/dev/null || true
ip link set wg0 mtu "$MTU"
ip link set wg0 up

UNBOUND_PID=""
cleanup() {
  echo "[entrypoint] завершение, останавливаю unbound и удаляю wg0..."
  [ -n "$UNBOUND_PID" ] && kill "$UNBOUND_PID" 2>/dev/null || true
  wg show wg0 >/dev/null 2>&1 && ip link del wg0 2>/dev/null || true
}
trap cleanup TERM INT EXIT

# --- 6. Запускаем unbound ----------------------------------------------------
unbound -d -c "$CONFIG/unbound.conf" &
UNBOUND_PID=$!
echo "[entrypoint] unbound pid=$UNBOUND_PID"
echo "[entrypoint] wg0 поднят: $(wg show wg0 | head -1)"

# Если unbound падает — контейнер завершается и перезапускается Docker'ом.
wait -n "$UNBOUND_PID"
