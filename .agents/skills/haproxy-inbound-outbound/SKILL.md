---
name: haproxy-inbound-outbound
description: >-
  Configures, hardens, validates, and reloads HAProxy for dual Inbound (L7 HTTPS/HTTP2
  TLS termination) and Outbound (L4 TCP SNI Passthrough with DNS resolvers) on
  network_mode: host. Use whenever writing or updating haproxy.cfg templates,
  TLS settings, DNS resolvers, ACL whitelists, or reload scripts.
---

# HAProxy Dual Inbound/Outbound Configuration & Hardening

Use these standards whenever authoring or reviewing `haproxy/haproxy.cfg.tpl`, HAProxy Docker service definitions, or `scripts/haproxy-ctl.sh`.

## 1. Socket Separation on Port 443

Because HAProxy runs in `network_mode: host`, Inbound and Outbound listeners MUST never bind `0.0.0.0:443`:
- **Inbound HTTP (`mode http`)**: `bind ${HOST_LAN_IP}:80` -> `http-request redirect scheme https code 301`.
- **Inbound HTTPS (`mode http`)**: `bind ${HOST_LAN_IP}:443 ssl crt /usr/local/etc/haproxy/certs/ alpn h2,http/1.1`.
- **Outbound TLS (`mode tcp`)**: `bind ${DUMMY_OUTBOUND_IP}:443` (default `10.254.254.1:443`).
- *(Optional)* **Outbound Plain HTTP (`mode http`)**: `bind ${DUMMY_OUTBOUND_IP}:80` routing by `hdr(host)` (never `mode tcp` SNI, as HTTP has no TLS ClientHello).

## 2. Mandatory Global & Inbound Settings

- **Zero-Downtime Worker Lifecycle**:
  - Enable `master-worker` (or `-W` CLI flag) AND set `hard-stop-after ${HAPROXY_HARD_STOP_AFTER}` (e.g. `60s`) in `global` so old workers holding HTTP/2 or TCP passthrough streams exit cleanly after reload instead of leaking RAM.
- **Large OIDC Session Cookie Support**:
  - Set `tune.bufsize 32768` in `global` so large `authentik_proxy_*` JWT/session cookies never trigger `400 Bad Request`.
- **TLS & Header Hygiene**:
  - Enforce `ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets`.
  - Strip or overwrite untrusted client headers before forwarding to `authentik-proxy` or apps:
    ```haproxy
    http-request del-header X-Forwarded-Proto
    http-request set-header X-Forwarded-Proto https
    option forwardfor
    ```

## 3. Mandatory Outbound SNI Passthrough & Resolver Safeguards

1. **Strict SNI Allowlist & Immediate Reject**:
   ```haproxy
   frontend fe_outbound_tls
       bind ${DUMMY_OUTBOUND_IP}:443
       mode tcp
       option tcplog
       tcp-request inspect-delay 5s
       tcp-request content accept if { req.ssl_hello_type 1 }
       tcp-request content reject
       use_backend be_authentik_main if { req.ssl_sni -i ${AUTHENTIK_DOMAIN} }
       use_backend be_out_partner    if { req.ssl_sni -i ${OUTBOUND_PARTNER_DOMAIN} }
   ```
   *(With no `default_backend`, any unlisted SNI fails immediately without forwarding).*

2. **DNS Resolver Resilience (Preventing Inbound Outages)**:
   - Never point `resolvers` at `127.0.0.53` (`systemd-resolved` stub) if upstream DNS IPs are available; configure real upstream DNS (`${HOST_UPSTREAM_DNS}:53`) and `accepted_payload_size 8192`.
   - Always set `default-server init-addr last,libc,none resolvers host_dns resolve-prefer ipv4` on external backends:
     - `init-addr last,libc,none`: prevents HAProxy from refusing to start/reload when an external partner domain has a DNS outage.
     - `resolve-prefer ipv4`: prevents HAProxy from preferring `AAAA` records (HAProxy's default) on IPv4-only hosts.
   - **NEVER add `check`** on third-party external domains (avoids getting rate-limited/blocked by partner WAFs).

3. **Long-Lived WebSocket Support for Authentik Outpost**:
   - On `be_authentik_main`, set `timeout server 3600s` (and `timeout client 3600s` or `timeout tunnel 3600s`) plus `option clitcpka` and `option srvtcpka` so `/ws/outpost/` connections do not drop every minute.
   - Prefer routing `be_authentik_main` to static IP `${AUTHENTIK_MAIN_BACKEND_IP}:443` rather than DNS when IP is static.

## 4. Container Hardening & Safe Reload Procedure

- Official `haproxy:3.0-alpine` / `haproxy:3.2-alpine` runs as UID `99` (`haproxy`).
- Configure container with:
  - `cap_drop: ["ALL"]`
  - `cap_add: ["NET_BIND_SERVICE"]`
  - `security_opt: ["no-new-privileges:true"]`
- **Reload Protocol**: Always validate syntax BEFORE signaling:
  ```bash
  docker exec haproxy haproxy -c -V -f /usr/local/etc/haproxy/haproxy.cfg && docker kill -s USR2 haproxy
  ```
