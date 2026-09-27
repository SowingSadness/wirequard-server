FROM alpine:3.20

# Kernel-WireGuard (userspace не нужен), unbound для DNS внутри туннеля.
RUN apk add --no-cache \
      wireguard-tools \
      iproute2 \
      unbound \
      bash \
      tini \
      ca-certificates \
 && rm -rf /var/cache/apk/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY gen-client.sh /usr/local/bin/gen-client.sh
COPY unbound.conf.default /usr/local/share/unbound.conf.default
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/gen-client.sh

VOLUME ["/config"]
EXPOSE 38471/udp

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD wg show wg0 >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
