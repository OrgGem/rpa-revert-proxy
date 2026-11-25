---
name: openmanager-agent-control
description: >-
  Deploys and hardens HAProxy OpenManager (Central Hub without Nginx) and locked
  pull-based haproxy-agent daemons on Satellite Servers to centrally manage, version,
  diff, rollback, and monitor HAProxy instances over HTTPS without inter-server SSH.
  Use when configuring OpenManager Hub, haproxy-agent, systemd HAProxy shims, or API routing.
---

# HAProxy OpenManager Central Hub & Pull-Agent Operations

Follow these rules whenever working on `haproxy-openmanager` Hub services, `haproxy-agent` installation on Satellite nodes, or Authentik + OpenManager API routing.

## 1. Central Hub Architecture (Zero-Nginx Design)

1. **Pin Explicit Version Tags**:
   - Always pin `taylanbakircioglu/haproxy-openmanager-backend:${OPENMANAGER_TAG}` and `taylanbakircioglu/haproxy-openmanager-frontend:${OPENMANAGER_TAG}` (e.g. `1.12.3`). Never use `:latest`.
2. **Eliminate Bundled Nginx**:
   - Do NOT deploy the upstream `haproxy-openmanager-nginx` container (maintaining the project's zero-Nginx CVE posture).
   - Route `/api/*` and `/.well-known/acme-challenge/*` to `openmanager-backend:8000` and `/` to `openmanager-frontend:3000` using an internal `haproxy:3.0-alpine` router (`openmanager-router:8080`) behind `authentik-proxy`.
3. **Dual-Path Authentication on `${OPENMANAGER_PUBLIC_DOMAIN}`**:
   - **Human Admin Traffic**: All browser requests MUST pass through `authentik-proxy` (`127.0.0.1:${AUTHENTIK_PROXY_LOOPBACK_PORT}`) enforcing Authentik OIDC SSO, MFA, and Group `${AUTHENTIK_ALLOWED_GROUP}`.
   - **Satellite `haproxy-agent` Pull Traffic**: Only requests matching `/api/agents*`, `/api/clusters*`, or `/api/configuration/agents/*` that ALSO carry header `X-API-Key` route directly to `openmanager-backend:8000` (after stripping any client-supplied `X-authentik-*` headers) so `validate_agent_api_key` verifies the 256-bit agent token without triggering OIDC `302` redirects.

## 2. Satellite Node Pull-Agent & Dockerized HAProxy Bridge

Each Satellite Server runs NO web UI, NO RabbitMQ, NO `authentik-proxy`, and NO inbound SSH management user:
1. **Outbound HTTPS Polling Only**:
   - `haproxy-agent` runs as a systemd service on the Satellite Host, polling `https://${OPENMANAGER_PUBLIC_DOMAIN}` every `${OPENMANAGER_POLL_INTERVAL}s` (default `30s`) over outbound TCP `443` to pull versioned `haproxy.cfg` updates and `/etc/ssl/haproxy/*.pem` certificates, and to push CSV stats from `/var/run/haproxy/admin.sock`.
2. **Mandatory Security Hardening Against Remote Script Upgrade (Anti-RCE)**:
   - Upstream OpenManager includes a UI "Agent Script Editor & Auto-Upgrade" feature. To prevent a compromised Hub admin account from executing arbitrary Bash on Satellite nodes:
     - Strip/disable the self-upgrade block in `/usr/local/bin/haproxy-agent` (`OPENMANAGER_ALLOW_AGENT_SELF_UPGRADE=false`).
     - Lock `/usr/local/bin/haproxy-agent` as `root:root`, mode `0500`, and apply Linux immutable attribute `chattr +i /usr/local/bin/haproxy-agent`.
3. **Bridging Host `haproxy-agent` to Dockerized HAProxy (`network_mode: host`)**:
   - Manage the `haproxy` container via `/etc/systemd/system/haproxy.service` (`ExecReload=/usr/local/bin/haproxy-ctl reload` sending `SIGUSR2`) so `systemctl is-active haproxy` and `systemctl reload haproxy` invoked by `haproxy-agent` work seamlessly.
   - Install `/usr/local/sbin/haproxy` CLI shim that stages any candidate config into `/etc/haproxy/.validate/` and runs `docker exec haproxy haproxy -c -f ...` inside the `haproxy` container.
   - Bind-mount `/etc/haproxy:/etc/haproxy:ro`, `/etc/ssl/haproxy:/etc/ssl/haproxy:ro`, and `/var/run/haproxy:/var/run/haproxy:rw` into the `haproxy` container.

## 3. Preserving Dual-IP & Resolver Directives Across Partial Config Syncs

- OpenManager generates partial configs (`frontends` + `backends`) while `haproxy-agent` preserves `global`, `defaults`, and `listen` blocks from local `/etc/haproxy/haproxy.cfg`.
- Place `resolvers host_dns` immediately after `global` (before `defaults`) and declare `listen prometheus_exporter` (`127.0.0.1:${HAPROXY_METRICS_PORT}`) as a `listen` block so `haproxy-agent` preserves both untouched across every UI Apply.
- Group Satellite nodes with distinct `${HOST_LAN_IP}` bindings into dedicated 1-node Clusters inside a shared OpenManager Pool (or bind via per-node environment/VIP where identical).
