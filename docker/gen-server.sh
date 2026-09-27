#!/usr/bin/env bash
#
# gen-server.sh [--force]
#
# Генерирует ключи WireGuard-сервера и (пере)создаёт блок [Interface] в
# wg0.conf, СОХРАНЯЯ существующих peer'ов (клиентов). Идемпотентен: если ключ
# уже есть — просто поддерживает wg0.conf в актуальном состоянии.
#
#   --force  перегенерировать ключ сервера. ВНИМАНИЕ: это разорвёт всех
#            существующих клиентов — им понадобится новый публичный ключ
#            сервера (server.pub).
#
set -euo pipefail
umask 077

CONFIG="${CONFIG_DIR:-/config}"
PORT="${WG_PORT:-38471}"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

mkdir -p "$CONFIG"

# --- 1. Ключи сервера --------------------------------------------------------
if [ ! -s "$CONFIG/server.key" ] || [ "$FORCE" -eq 1 ]; then
  if [ -s "$CONFIG/server.key" ] && [ "$FORCE" -eq 1 ]; then
    cp -a "$CONFIG/server.key" "$CONFIG/server.key.bak.$(date +%s)"
    if grep -q '^\[Peer\]' "$CONFIG/wg0.conf" 2>/dev/null; then
      echo "[gen-server] ВНИМАНИЕ: у сервера есть peer'ы — смена ключа сервера" >&2
      echo "[gen-server] разорвёт всех клиентов, им нужен новый server.pub." >&2
    fi
  fi
  wg genkey > "$CONFIG/server.key"
fi
chmod 600 "$CONFIG/server.key"
wg pubkey < "$CONFIG/server.key" > "$CONFIG/server.pub"
chmod 600 "$CONFIG/server.pub"

# --- 2. Блок [Interface] в wg0.conf (peer'ы сохраняются как есть) ------------
peers=""
if [ -s "$CONFIG/wg0.conf" ] && grep -q '^\[Peer\]' "$CONFIG/wg0.conf"; then
  peers="$(awk '/^\[Peer\]/{f=1} f' "$CONFIG/wg0.conf")"
fi

tmp="$CONFIG/wg0.conf.tmp.$$"
{
  echo "[Interface]"
  echo "PrivateKey = $(cat "$CONFIG/server.key")"
  echo "ListenPort = $PORT"
  if [ -n "$peers" ]; then
    echo
    printf '%s\n' "$peers"
  fi
} > "$tmp"
mv "$tmp" "$CONFIG/wg0.conf"
chmod 600 "$CONFIG/wg0.conf"

echo "[gen-server] ключи сервера готовы:"
echo "  private: $CONFIG/server.key"
echo "  public:  $CONFIG/server.pub"
echo "[gen-server] публичный ключ сервера (нужен клиентам):"
cat "$CONFIG/server.pub"
