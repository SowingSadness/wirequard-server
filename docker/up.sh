#!/usr/bin/env bash
#
# up.sh — собрать (если нужно) и запустить контейнер wg с усиленными флагами.
#
set -euo pipefail

cd "$(dirname "$0")"

IMAGE="wg-server:latest"
CONTAINER="wg"
CONFIG_DIR="${CONFIG_DIR:-$(pwd)/config}"
PORT="${WG_PORT:-38471}"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "[*] Сборка образа $IMAGE ..."
  DOCKER_BUILDKIT=1 docker build --network=host -t "$IMAGE" .
fi

if docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "[*] Контейнер $CONTAINER уже существует — пересоздаю."
  docker rm -f "$CONTAINER" >/dev/null
fi

docker run -d --name "$CONTAINER" \
  --network host \
  --cap-drop ALL \
  --cap-add NET_ADMIN \
  --cap-add NET_BIND_SERVICE \
  --cap-add SETUID \
  --cap-add SETGID \
  --cap-add CHOWN \
  --security-opt no-new-privileges:true \
  --read-only \
  --tmpfs /run:rw,noexec,nosuid,size=8m \
  --tmpfs /tmp:rw,noexec,nosuid,size=8m \
  -v "$CONFIG_DIR":/config:rw \
  --pids-limit 128 \
  --memory 192m --memory-swap 384m \
  --restart unless-stopped \
  "$IMAGE"

echo "[*] Ждём запуска..."
sleep 5
docker ps --filter "name=^${CONTAINER}$" --format '{{.Names}}  {{.Status}}'
docker logs "$CONTAINER" 2>&1 | tail -8
