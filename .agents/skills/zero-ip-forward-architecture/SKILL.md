---
name: zero-ip-forward-architecture
description: >-
  Guides system architecture, Linux kernel networking, Docker bridge isolation,
  dummy0 interface setup, and firewall rules under strict net.ipv4.ip_forward=0
  and no-inter-server-SSH constraints. Use when designing or modifying host setup,
  daemon.json, network topologies, or Single-Server Lab vs Multi-Server Production parity.
---

# Zero-IP-Forward Proxy & Network Architecture

Follow these architectural invariants whenever working on host networking, Docker daemon settings, Compose networks, or multi-server vs single-server topologies in `rpa-prory`.

## 1. Non-Negotiable Kernel & Docker Invariants

1. **Kernel Forwarding Disabled (`net.ipv4.ip_forward = 0`)**:
   - Linux blocks all packets traversing the `FORWARD` chain (`PREROUTING -> FORWARD -> POSTROUTING`).
   - Every network flow MUST terminate locally on the Host (`INPUT` chain) or originate locally from the Host (`OUTPUT` chain).
   - `/etc/docker/daemon.json` MUST set `"ip-forward": false`, otherwise `dockerd` overwrites `net.ipv4.ip_forward = 1` on startup/reboot.

2. **Inbound Path (`External -> Host_LAN_IP:443 -> HAProxy -> 127.0.0.1:<port> -> Container`)**:
   - HAProxy runs with `network_mode: host`.
   - `/etc/docker/daemon.json` MUST keep `"userland-proxy": true` and `"ip": "127.0.0.1"`.
   - Without `docker-proxy` (`userland-proxy: true`), connections to `127.0.0.1:<port>` cannot reach bridge containers when `ip_forward = 0`.
   - Application containers MUST bind ports strictly to loopback (`"127.0.0.1:${PORT}:${CONTAINER_PORT}"`), never `0.0.0.0`, so LAN peers cannot bypass HAProxy via `docker-proxy`.

3. **Outbound Path (`Container -> extra_hosts -> dummy0 10.254.254.1:443 -> HAProxy SNI -> External`)**:
   - Docker's `host-gateway` magic keyword resolves to `docker0` (`172.17.0.1`) by default, NOT custom Compose bridge gateways (`172.25.0.1`). Furthermore, custom Compose bridges disappear on `docker compose down`.
   - Always provision an OS-level persistent `dummy0` interface (`${DUMMY_OUTBOUND_IP}/32`, default `10.254.254.1/32`) BEFORE `docker.service` starts, and set `"host-gateway-ip": "10.254.254.1"` in `/etc/docker/daemon.json`.
   - Ensure `net.ipv4.conf.all.rp_filter` / `net.ipv4.conf.br-*.rp_filter` is set to `2` (loose) or `0` if strict reverse-path filtering drops packets arriving on `br-*` destined for `dummy0` (`10.254.254.1`).

4. **Firewall Rules (`INPUT` Chain)**:
   - Allow `eth0` / LAN interface -> `Host_LAN_IP:80,443` (TCP).
   - Allow `docker0` and `br-+` -> `${DUMMY_OUTBOUND_IP}:443` (and `:80` only if HTTP outbound is explicitly enabled).
   - Block inter-server SSH (`Port 22` on LAN if required by policy, excluding authorized Bastion IPs), while **explicitly allowing `INPUT` TCP `22` from `mgmt_internal` subnet (`${MGMT_SUBNET}`, e.g. `172.25.0.0/24`)** so `roxy-wi` can SSH locally into its own Host.

## 2. Single-Server Lab vs Multi-Server Production Parity

Never short-circuit `authentik-proxy` or HAProxy Outbound SNI Passthrough in Local Single-Server mode:
- **`local-all-in-one` mode (1 Server)**:
  - Run `Authentik Main` bound to `127.0.0.1:${LOCAL_IDP_PORT}` (e.g. `9001`) behind HAProxy Inbound (`${AUTHENTIK_DOMAIN}` on `Host_LAN_IP:443`).
  - Still deploy standalone `authentik-proxy` (`127.0.0.1:9000`) inside `mgmt_internal` with `extra_hosts: "${AUTHENTIK_DOMAIN}:host-gateway"`.
  - Configure HAProxy Outbound (`10.254.254.1:443`) to match `req.ssl_sni -i ${AUTHENTIK_DOMAIN}` and forward raw TCP to `${HOST_LAN_IP}:443`.
- **`prod-satellite` mode (N Satellite Servers)**:
  - Identical satellite stack; only change `${AUTHENTIK_MAIN_BACKEND_IP}` / `${AUTHENTIK_DOMAIN}` in `.env` to point to the central Authentik Hub server.

## 3. Verification Checklist

- `sysctl -n net.ipv4.ip_forward` outputs `0` after `systemctl restart docker`.
- `ip -4 addr show dev dummy0` shows `10.254.254.1/32`.
- `ss -tulpn` confirms no container ports (`8081`, `9000`, `9001`) are bound on `0.0.0.0` or `Host_LAN_IP`.
