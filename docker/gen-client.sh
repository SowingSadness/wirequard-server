#!/usr/bin/env bash
#
# gen-client.sh <имя> [--format ini|xray|both|link] [--qr]
#
# Выпускает нового клиента: ключи, Preshared Key, свободный адрес, peer и
# применение через `wg syncconf` (без разрыва сессий).
#
# Поведение вывода:
#   * без --format  -> печатает СВОДКУ для ручной настройки (адрес, DNS, MTU,
#                      endpoint, server pub, пути к файлам);
#   * с --format    -> печатает конфиг в заданном формате (ini / xray / both / link).
# Конфиг Xray сохраняется на диск ТОЛЬКО если --format включает xray,
# ссылка link — только если --format = link.
# INI-конфиг (<имя>.conf) сохраняется всегда.
#
# Логика рендеринга берётся из show-client.sh (source) — без дублирования.
#
set -euo pipefail
umask 077

CONFIG="${CONFIG_DIR:-/config}"
PORT="${WG_PORT:-38471}"

# shellcheck source=/dev/null
source /usr/local/bin/show-client.sh

usage() { echo "Использование: gen-client.sh <имя> [--format ini|xray|both|link] [--qr]" >&2; }

name=""; format=""; qr=0
while [ $# -gt 0 ]; do
  case "$1" in
    --format) format="${2:-}"; shift 2 ;;
    --qr)     qr=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Неизвестный аргумент: $1" >&2; usage; exit 1 ;;
    *)  name="$1"; shift ;;
  esac
done
[ -n "$name" ] || { usage; exit 1; }
[[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "Недопустимое имя: $name" >&2; exit 1; }
if [ -n "$format" ]; then
  case "$format" in ini|xray|both|link) ;; *) echo "format должен быть ini|xray|both|link" >&2; exit 1 ;; esac
fi

cdir="$CONFIG/clients/$name"
[ -d "$cdir" ] && { echo "Клиент '$name' уже существует: $cdir" >&2; exit 1; }
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
while printf '%s\n' "$used" | grep -qx "$idx"; do idx=$((idx + 1)); done

# --- peer в серверный конфиг -------------------------------------------------
cat >> "$CONFIG/wg0.conf" <<EOF

[Peer]
# $name
PublicKey = $(cat "$cdir/pub.key")
PresharedKey = $(cat "$cdir/psk.key")
AllowedIPs = 10.8.0.$idx/32, fd42:8:8::$idx/128
EOF

# --- применяем без разрыва существующих сессий -------------------------------
if wg show wg0 >/dev/null 2>&1; then
  wg syncconf wg0 <(grep -v '^#' "$CONFIG/wg0.conf")
fi

# --- конфиги: INI всегда; Xray — только если формат его включает -------------
conf_path="$(save_ini "$name")"
xray_path=""
link_path=""
case "$format" in
  xray|both) xray_path="$(save_xray "$name")" ;;
esac
case "$format" in
  link) link_path="$(save_link "$name")" ;;
esac

# --- вывод -------------------------------------------------------------------
if [ -z "$format" ]; then
  echo "Клиент '$name' создан."
  echo "  адрес:       10.8.0.$idx, fd42:8:8::$idx"
  echo "  DNS:         10.8.0.1, fd42:8:8::1"
  echo "  MTU:         1420"
  echo "  endpoint:    $(endpoint)"
  echo "  server pub:  $(server_pub)"
  echo "  INI конфиг:  $conf_path"
  [ -n "$xray_path" ] && echo "  Xray конфиг: $xray_path"
  [ -n "$link_path" ] && echo "  Ссылка:      $link_path"
  echo
  echo "Показать конфиг: docker exec wg show-client.sh $name --format ini|xray|both|link"
else
  case "$format" in
    ini)  render_ini "$name" ;;
    xray) render_xray "$name" ;;
    link) render_link "$name" ;;
    both)
      echo "===== WireGuard (INI) ====="
      render_ini "$name"
      echo
      echo "===== Xray-core (JSON) ====="
      render_xray "$name"
      ;;
  esac
fi

if [ "$qr" -eq 1 ]; then print_qr "$name"; fi
exit 0
