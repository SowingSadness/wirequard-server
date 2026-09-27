#!/usr/bin/env bash
#
# gen-client.sh <name> — выпускает нового клиента:
#   * генерирует ключи и Preshared Key;
#   * выделяет свободный адрес 10.8.0.X / fd42:8:8::X;
#   * формирует клиентский .conf (AllowedIPs из /config/allowed-ips.list);
#   * дописывает [Peer] в wg0.conf и применяет через wg syncconf (без разрыва).
#
set -euo pipefail
umask 077

CONFIG="${CONFIG_DIR:-/config}"
PORT="${WG_PORT:-38471}"
name="${1:-}"
if [ -z "$name" ]; then
  echo "Использование: gen-client.sh <name>" >&2
  exit 1
fi
if ! [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "Недопустимое имя (разрешены A-Z a-z 0-9 _ -): $name" >&2
  exit 1
fi

cdir="$CONFIG/clients/$name"
if [ -d "$cdir" ]; then
  echo "Клиент '$name' уже существует: $cdir" >&2
  exit 1
fi
mkdir -p "$cdir"

# --- ключи -------------------------------------------------------------------
wg genkey > "$cdir/priv.key"
wg pubkey < "$cdir/priv.key" > "$cdir/pub.key"
wg genpsk > "$cdir/psk.key"
chmod 600 "$cdir"/*.key

# --- свободный индекс адреса -------------------------------------------------
used="$(awk -F'[=,/ ]+' '
  /^AllowedIPs/ { for (i=1;i<=NF;i++)
      if ($i ~ /^10\.8\.0\.[0-9]+$/) { split($i,a,"."); print a[4] } }
' "$CONFIG/wg0.conf" 2>/dev/null | sort -n | uniq || true)"
idx=2
while printf '%s\n' "$used" | grep -qx "$idx"; do
  idx=$((idx + 1))
done

# --- peer в серверный конфиг -------------------------------------------------
cat >> "$CONFIG/wg0.conf" <<EOF

[Peer]
# $name
PublicKey = $(cat "$cdir/pub.key")
PresharedKey = $(cat "$cdir/psk.key")
AllowedIPs = 10.8.0.$idx/32, fd42:8:8::$idx/128
EOF

# --- AllowedIPs клиента из allowed-ips.list ----------------------------------
allowed=""
if [ -f "$CONFIG/allowed-ips.list" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [ -z "$line" ] && continue
    allowed="$allowed, $line"
  done < "$CONFIG/allowed-ips.list"
fi
# VPN-подсети добавляем всегда (нужны для DNS и шлюза)
allowed="10.8.0.0/24, fd42:8:8::/64${allowed}"

endpoint="$(cat "$CONFIG/endpoint" 2>/dev/null || echo "REPLACE_WITH_SERVER_IP:$PORT")"

# --- клиентский конфиг -------------------------------------------------------
conf="$cdir/$name.conf"
cat > "$conf" <<EOF
[Interface]
PrivateKey = $(cat "$cdir/priv.key")
Address = 10.8.0.$idx/24, fd42:8:8::$idx/64
DNS = 10.8.0.1, fd42:8:8::1
MTU = 1420

[Peer]
PublicKey = $(cat "$CONFIG/server.pub")
PresharedKey = $(cat "$cdir/psk.key")
Endpoint = $endpoint
AllowedIPs =$allowed
PersistentKeepalive = 25
EOF
chmod 600 "$conf"

# --- применяем на сервере без разрыва существующих сессий --------------------
if wg show wg0 >/dev/null 2>&1; then
  wg syncconf wg0 <(grep -v '^#' "$CONFIG/wg0.conf")
fi

# --- QR ----------------------------------------------------------------------
qrencode -t ansiutf8 < "$conf" > "$cdir/$name.qr.txt" 2>/dev/null || true
qrencode -o "$cdir/$name.png" < "$conf" 2>/dev/null || true

echo "Клиент '$name' создан:"
echo "  адрес:    10.8.0.$idx, fd42:8:8::$idx"
echo "  конфиг:   $conf"
[ -f "$cdir/$name.png" ] && echo "  QR (png): $cdir/$name.png"
echo
cat "$cdir/$name.qr.txt" 2>/dev/null || true
