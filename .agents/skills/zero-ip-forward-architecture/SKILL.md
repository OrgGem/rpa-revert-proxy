---
name: zero-ip-forward-architecture
description: >-
  Guides system architecture, Linux kernel networking, IPv4/IPv6 forwarding lockdown,
  Docker bridge isolation, dummy0 interface setup, and egress firewall enforcement under
  strict net.ipv4.ip_forward=0 and no-inter-server-SSH constraints. Use when designing
  or modifying host setup, daemon.json, network topologies, or Hub vs Satellite parity.
---

# Zero-IP-Forward Proxy & Egress Enforcement Architecture

Follow these architectural invariants whenever working on host networking, Docker daemon settings, Compose networks, or Single-Server Lab vs Multi-Server Hub/Satellite topologies.

## 1. Non-Negotiable Kernel, IPv6 & Docker Invariants

1. **Kernel IPv4 & IPv6 Forwarding Disabled**:
   - `net.ipv4.ip_forward = 0`, `net.ipv6.conf.all.forwarding = 0`, and `net.ipv6.conf.default.forwarding = 0`.
   - Every container flow MUST terminate locally on the Host (`INPUT` chain) or originate locally from the Host (`OUTPUT` chain).
   - `/etc/docker/daemon.json` MUST set `"ip-forward": false` and `"ipv6": false`, otherwise `dockerd` overwrites `net.ipv4.ip_forward = 1` on startup/reboot or opens an unmonitored IPv6 path.

2. **Inbound Path (`External -> ${HOST_LAN_IP}:443 -> HAProxy -> 127.0.0.1:<port> -> Container`)**:
   - HAProxy runs with `network_mode: host`.
   - `/etc/docker/daemon.json` MUST keep `"userland-proxy": true` and `"ip": "127.0.0.1"`.
   - Application and Hub containers MUST bind published ports strictly to loopback (`"127.0.0.1:${APP_LOOPBACK_PORT}:${APP_CONTAINER_PORT}"`), never `0.0.0.0`.

3. **Outbound Path & Egress Enforcement (`Container -> extra_hosts -> ${DUMMY_INTERFACE_NAME} ${DUMMY_OUTBOUND_IP}:443 -> HAProxy SNI -> External`)**:
   - Provision persistent OS-level `${DUMMY_INTERFACE_NAME}` (`${DUMMY_OUTBOUND_IP}/32`, default `10.254.254.1/32`) BEFORE `docker.service` starts, and set `"host-gateway-ip": "${DUMMY_OUTBOUND_IP}"` in `/etc/docker/daemon.json`.
   - Set `net.ipv4.conf.all.rp_filter = 2` (loose) so packets from `br-*` to `${DUMMY_OUTBOUND_IP}` are accepted on `INPUT`.
   - **Defense-in-Depth Egress Enforcement (`FR-03A`)**: Enforce explicit firewall `DROP`/`REJECT` rules for any traffic from `docker0`/`br-+` attempting to reach Host ports other than allowed loopback/dummy listeners (`${DUMMY_OUTBOUND_IP}:443`) or attempting `FORWARD` (including UDP `:443` QUIC, raw IP literals, or IPv6), ensuring no container can bypass HAProxy SNI inspection.

4. **Zero Inter-Server SSH & Zero Local Web-UI SSH**:
   - Satellite servers require NO SSH daemon exposure for proxy management: `haproxy-agent` runs locally on the Satellite Host and initiates **outbound HTTPS (`:443`)** pull connections to `${OPENMANAGER_PUBLIC_DOMAIN}` on the Hub.

## 2. Single-Server Lab (`local-all-in-one`) vs Multi-Server Production (`prod-hub` / `prod-satellite`)

- **`local-all-in-one` (1 Linux Server)**:
  - Runs Hub stack (`Authentik Main` on `127.0.0.1:${LOCAL_IDP_LOOPBACK_PORT}`, `authentik-proxy` on `127.0.0.1:${AUTHENTIK_PROXY_LOOPBACK_PORT}`, and `haproxy-openmanager`) + Satellite stack (`haproxy` + `haproxy-agent` + `mock-app`) on the same host.
  - `authentik-proxy` inside `mgmt_internal` still traverses `extra_hosts` -> `${DUMMY_OUTBOUND_IP}:443` -> HAProxy Outbound SNI Passthrough -> `${HOST_LAN_IP}:443` to reach `Authentik Main`, proving the exact zero-ip-forward path on 1 machine.
- **`prod-hub` + `prod-satellite` (Multi-Server Production)**:
  - **Hub Server (`prod-hub`)**: Runs Edge HAProxy + `Authentik Main` + `authentik-proxy` + `haproxy-openmanager`.
  - **Satellite Servers (`prod-satellite`)**: Run ONLY Edge/Outbound `HAProxy` + `haproxy-agent` (polling Hub over HTTPS `:443`) + Business Docker Apps.
