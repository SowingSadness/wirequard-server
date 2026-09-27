#!/usr/bin/env bash
#
# show-client.sh <имя> [--format ini|xray|both] [--save] [--qr]
#
# Выводит АКТУАЛЬНЫЙ конфиг клиента (пересобирается из ключей клиента,
# server.pub, endpoint и текущего allowed-ips.list):
#   ini  — конфиг WireGuard (.conf)
#   xray — конфиг Xray-core (JSON, WireGuard outbound)
#   both — оба (по умолчанию ini)
#
# Скрипт можно подключать как библиотеку: `source show-client.sh` — тогда
# доступны функции render_ini / render_xray / save_ini / save_xray / print_qr
# (используется в gen-client.sh, чтобы избежать дублирования).
#
set -euo pipefail
umask 077

CONFIG="${CONFIG_DIR:-/config}"
PORT="${WG_PORT:-38471}"

die() { echo "[show-client] $*" >&2; exit 1; }

client_index() {   # -> X (последний октет адреса клиента)
  local name="$1" x=""
  if [ -s "$CONFIG/clients/$name/$name.conf" ]; then
    x="$(grep -m1 -oE '10\.8\.0\.[0-9]+' "$CONFIG/clients/$name/$name.conf" \
         | head -1 | awk -F. '{print $4}')"
  fi
  if [ -z "$x" ] && [ -s "$CONFIG/wg0.conf" ]; then
    x="$(awk -v n="$name" '
      /^\[Peer\]/   { found = 0 }
      $0 == "# " n  { found = 1 }
      found && /^AllowedIPs/ {
        if (match($0, /10\.8\.0\.[0-9]+/)) {
          s = substr($0, RSTART, RLENGTH); split(s, a, "."); print a[4]; exit
        }
      }' "$CONFIG/wg0.conf")"
  fi
  [ -n "$x" ] || die "не удалось определить адрес клиента '$name'"
  printf '%s' "$x"
}

client_field() {   # name priv|psk
  local name="$1" kind="$2" f
  case "$kind" in
    priv) f="$CONFIG/clients/$name/priv.key" ;;
    psk)  f="$CONFIG/clients/$name/psk.key"  ;;
    *) die "неизвестное поле: $kind" ;;
  esac
  [ -s "$f" ] || die "нет файла $f (клиент '$name' не найден?)"
  cat "$f"
}

server_pub() { cat "$CONFIG/server.pub"; }

endpoint() {
  local ep=""
  [ -s "$CONFIG/endpoint" ] && ep="$(cat "$CONFIG/endpoint")"
  [ -n "$ep" ] || ep="${WG_ENDPOINT:-REPLACE_WITH_SERVER_IP:$PORT}"
  printf '%s' "$ep"
}

allowed_ips() {    # -> "10.8.0.0/24, fd42:8:8::/64[, ...]"
  local out="10.8.0.0/24, fd42:8:8::/64" line
  if [ -f "$CONFIG/allowed-ips.list" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%#*}"; line="$(printf '%s' "$line" | tr -d '[:space:]')"
      [ -z "$line" ] && continue
      out="$out, $line"
    done < "$CONFIG/allowed-ips.list"
  fi
  printf '%s' "$out"
}

allowed_ips_json() {   # -> ["10.8.0.0/24", ...]
  local -a items=("10.8.0.0/24" "fd42:8:8::/64")
  local line out="" i
  if [ -f "$CONFIG/allowed-ips.list" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%#*}"; line="$(printf '%s' "$line" | tr -d '[:space:]')"
      [ -z "$line" ] && continue
      items+=("$line")
    done < "$CONFIG/allowed-ips.list"
  fi
  for i in "${items[@]}"; do out="$out\"$i\", "; done
  printf '[%s]' "${out%, }"
}

render_ini() {     # <имя> -> WireGuard .conf
  local name="$1" idx priv psk
  idx="$(client_index "$name")"
  priv="$(client_field "$name" priv)"
  psk="$(client_field "$name" psk)"
  cat <<EOF
[Interface]
PrivateKey = $priv
Address = 10.8.0.$idx/24, fd42:8:8::$idx/64
DNS = 10.8.0.1, fd42:8:8::1
MTU = 1420

[Peer]
PublicKey = $(server_pub)
PresharedKey = $psk
Endpoint = $(endpoint)
AllowedIPs = $(allowed_ips)
PersistentKeepalive = 25
EOF
}

render_xray() {    # <имя> -> Xray-core config.json (wireguard outbound)
  local name="$1" idx priv psk
  idx="$(client_index "$name")"
  priv="$(client_field "$name" priv)"
  psk="$(client_field "$name" psk)"
  cat <<EOF
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
        "secretKey": "$priv",
        "address": ["10.8.0.$idx/32", "fd42:8:8::$idx/128"],
        "mtu": 1420,
        "noKernelTun": true,
        "remoteDNS": ["10.8.0.1", "fd42:8:8::1"],
        "peers": [
          {
            "endpoint": "$(endpoint)",
            "publicKey": "$(server_pub)",
            "preSharedKey": "$psk",
            "allowedIPs": $(allowed_ips_json),
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
EOF
}

save_ini() {       # <имя> -> путь
  local name="$1" d="$CONFIG/clients/$name"
  mkdir -p "$d"
  render_ini "$name" > "$d/$name.conf"
  chmod 600 "$d/$name.conf"
  printf '%s' "$d/$name.conf"
}

save_xray() {      # <имя> -> путь
  local name="$1" d="$CONFIG/clients/$name"
  mkdir -p "$d"
  render_xray "$name" > "$d/$name.xray.json"
  chmod 600 "$d/$name.xray.json"
  printf '%s' "$d/$name.xray.json"
}

print_qr() {       # <имя> (только INI)
  local name="$1" d="$CONFIG/clients/$name"
  [ -s "$d/$name.conf" ] || save_ini "$name" >/dev/null
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ansiutf8 < "$d/$name.conf"
    qrencode -o "$d/$name.png" < "$d/$name.conf" 2>/dev/null || true
  else
    echo "[show-client] qrencode не установлен — QR пропущен (ожидаемо внутри контейнера)." >&2
  fi
}

main() {
  local name="${1:-}"; [ $# -gt 0 ] && shift
  [ -n "$name" ] || die "Использование: show-client.sh <имя> [--format ini|xray|both] [--save] [--qr]"

  local format="ini" save=0 qr=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --format) format="${2:-}"; shift 2 ;;
      --save)   save=1; shift ;;
      --qr)     qr=1; shift ;;
      *) die "неизвестный аргумент: $1" ;;
    esac
  done
  case "$format" in ini|xray|both) ;; *) die "format должен быть ini|xray|both" ;; esac

  if [ "$save" -eq 1 ]; then
    case "$format" in ini|both) save_ini  "$name" >/dev/null ;; esac
    case "$format" in xray|both) save_xray "$name" >/dev/null ;; esac
  fi

  case "$format" in
    ini)  render_ini "$name" ;;
    xray) render_xray "$name" ;;
    both)
      echo "===== WireGuard (INI) ====="
      render_ini "$name"
      echo
      echo "===== Xray-core (JSON) ====="
      render_xray "$name"
      ;;
  esac
  if [ "$qr" -eq 1 ]; then print_qr "$name"; fi
  return 0
}

# Если скрипт запущен напрямую — выполнить CLI; если подключён (source) — только функции.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
