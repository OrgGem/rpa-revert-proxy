---
name: haproxy-inbound-outbound
description: >-
  Configures, hardens, validates, and reloads HAProxy for dual Inbound (L7 HTTPS/HTTP2
  TLS termination) and Outbound (L4 TCP SNI Passthrough with DNS resolvers) on
  network_mode: host, integrated with Prometheus metrics and OpenManager partial config sync.
  Use whenever writing or updating haproxy.cfg templates, TLS settings, resolvers, or reload scripts.
---

# HAProxy Dual Inbound/Outbound Configuration & Hardening

Use these standards whenever authoring or reviewing `haproxy/haproxy.cfg.tpl`, `haproxy/openmanager-router.cfg`, HAProxy systemd/Docker definitions, or `scripts/haproxy-ctl.sh`.

## 1. Socket Separation on Port 443

Because HAProxy runs in `network_mode: host`, Inbound and Outbound listeners MUST never bind `0.0.0.0:443`:
- **Inbound HTTP (`mode http`)**: `bind ${HOST_LAN_IP}:80` -> `http-request redirect scheme https code 301`.
- **Inbound HTTPS (`mode http`)**: `bind ${HOST_LAN_IP}:443 ssl crt /etc/ssl/haproxy/ alpn h2,http/1.1`.
- **Outbound TLS (`mode tcp`)**: `bind ${DUMMY_OUTBOUND_IP}:443` (default `10.254.254.1:443`).
- **Observability (`mode http`, preserved `listen` block)**: `bind 127.0.0.1:${HAPROXY_METRICS_PORT}` serving `http-request use-service prometheus-exporter if { path /metrics }` and `/stats`.

## 2. Graceful Drain Lifecycle & Privilege Separation

- **Master-Worker & Graceful Drain (`hard-stop-after`)**:
  - Enable `master-worker` and `hard-stop-after ${HAPROXY_HARD_STOP_AFTER}` (default `60s`) in `global`.
  - Document and test the exact SLO: `0%` dropped new requests during reload; active sessions gracefully drain up to `${HAPROXY_HARD_STOP_AFTER}`, after which remaining long-lived TCP/WebSocket connections on old workers are forcefully closed to prevent memory leaks.
- **Certificate Security (`0600` Root-Owned Keys)**:
  - Store certificates in `/etc/ssl/haproxy/` (`0600` `root:root`, compatible with `haproxy-agent` SSL sync).
  - Start HAProxy master with `user haproxy` and `group haproxy` in `global` (container capabilities limited strictly to `NET_BIND_SERVICE`, `SETUID`, `SETGID`, `DAC_READ_SEARCH`) so master reads `0600` keys into memory at reload while worker processes run as unprivileged UID `99` (`haproxy`) and cannot read private keys from disk.
- **Stats Socket & OIDC Cookie Buffer**:
  - Expose `stats socket /var/run/haproxy/admin.sock mode 660 level admin expose-fd listeners` (mounted at `/var/run/haproxy`) for `haproxy-agent` live telemetry.
  - Set `tune.bufsize ${HAPROXY_TUNE_BUFSIZE}` (`32768`) in `global` for large Authentik OIDC cookies.

## 3. Outbound SNI Allowlist & DNS Resolver Resilience

1. **Place `resolvers host_dns` Between `global` and `defaults`**:
   - Ensures `haproxy-agent` partial config merges preserve `resolvers host_dns` automatically alongside `global`.
   - Use `${HOST_UPSTREAM_DNS_1}:53` and `${HOST_UPSTREAM_DNS_2}:53` (never `127.0.0.53`), `accepted_payload_size 8192`.
2. **External Partner Backends**:
   - Always set `default-server init-addr last,libc,none resolvers host_dns resolve-prefer ipv4` and **NEVER enable `check`**.
3. **Long-Lived WebSocket Support (`fe_outbound_tls` & `be_out_authentik_main`)**:
   - Put `timeout client ${OUTBOUND_WSS_TIMEOUT}` + `option clitcpka` on `frontend fe_outbound_tls`, and `timeout server ${OUTBOUND_WSS_TIMEOUT}` + `timeout tunnel ${OUTBOUND_WSS_TIMEOUT}` + `option srvtcpka` on `backend be_out_authentik_main` (zero HAProxy capability warnings).
