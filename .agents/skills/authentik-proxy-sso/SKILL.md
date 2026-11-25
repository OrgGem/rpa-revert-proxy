---
name: authentik-proxy-sso
description: >-
  Deploys and configures Authentik Main (for Local 1-Server Lab) and Authentik
  Standalone Proxy Outposts (ghcr.io/goauthentik/proxy) protecting Roxy-WI across
  single or multiple satellite servers. Use when editing Authentik Compose stacks,
  Blueprints, Proxy Providers, Outpost tokens, or troubleshooting SSO/WSS flows.
---

# Authentik Main & Standalone Proxy Outpost Integration

Follow these rules whenever configuring `authentik-proxy`, `Authentik Main` (Local Lab or Hub), or Authentik Blueprints (`authentik/blueprints/`).

## 1. Strict Image Version Pinning

- **NEVER use `ghcr.io/goauthentik/proxy:latest` or `ghcr.io/goauthentik/server:latest`**.
  - Authentik does not maintain `:latest` on GHCR (`manifest unknown` error).
  - Outpost version (`proxy:${AUTHENTIK_TAG}`) MUST match the exact `major.minor.patch` version of `server:${AUTHENTIK_TAG}` (e.g. `2026.8.3`), otherwise `/ws/outpost/` synchronization fails.

## 2. Proxy Provider & Outpost Configuration Rules

For each satellite node (and the local node in 1-server mode), provision a dedicated **Proxy Provider + Application + Outpost**:
1. **Mode**: `Proxy` (Standalone Proxy — `authentik-proxy` reverses traffic directly to `roxy-wi`, no Lua/Forward-Auth plugin needed in HAProxy).
2. **External host**: `https://${ROXYWI_PUBLIC_DOMAIN}` (must start with `https://`).
3. **Internal host**: `https://roxy-wi:443` (Roxy-WI container serves HTTPS internally on `:443`, NOT HTTP `:8080`).
4. **Internal host SSL Validation**: `false` (`internal_host_ssl_validation: false` in Blueprints, because Roxy-WI uses an internal self-signed cert).
5. **Authorization flow**: `default-provider-authorization-implicit-consent` (**Implicit consent**) so admins moving across multiple satellite nodes via SSO are not prompted to click confirm on every node.
6. **Access Policy**: Bind Group `${AUTHENTIK_ALLOWED_GROUP}` (e.g. `infra-admins`) with MFA enforced; unauthorized users must receive `HTTP 403` at `authentik-proxy` before reaching `roxy-wi`.
7. **Token Blast-Radius Isolation**: Each satellite server gets its own Outpost and unique `AUTHENTIK_OUTPOST_TOKEN`.

## 3. Networking Under `net.ipv4.ip_forward = 0`

- `authentik-proxy` runs in custom bridge `mgmt_internal` (`${MGMT_SUBNET}`), exposing ONLY `"127.0.0.1:${AUTHENTIK_PROXY_PORT}:9000"` to the Host for HAProxy Inbound.
- `authentik-proxy` MUST include:
  ```yaml
  extra_hosts:
    - "${AUTHENTIK_DOMAIN}:host-gateway"
  ```
  so both OIDC token exchanges (`/application/o/token/`) and persistent Outpost WebSocket (`wss://${AUTHENTIK_DOMAIN}/ws/outpost/`) traverse HAProxy Outbound SNI Passthrough (`10.254.254.1:443`).
- `AUTHENTIK_INSECURE`:
  - Set `"true"` ONLY in `local-all-in-one` lab mode when using untrusted self-signed certs without mounting Root CA.
  - MUST be `"false"` in Production (or mount internal enterprise CA bundle into `/etc/ssl/certs/`).

## 4. Verification Steps

- Check `docker logs authentik-proxy` for `Successfully connected websocket` to `wss://${AUTHENTIK_DOMAIN}/ws/outpost/`.
- Unauthenticated `curl -I https://${ROXYWI_PUBLIC_DOMAIN}` returns `HTTP/2 302` redirecting to `https://${AUTHENTIK_DOMAIN}/...`.
