---
name: authentik-proxy-sso
description: >-
  Deploys and configures Authentik Main (Server + Worker, 2026.x Redis-free) and
  Authentik Standalone Proxy Outpost (ghcr.io/goauthentik/proxy) protecting the
  central HAProxy OpenManager Portal while allowing authenticated X-API-Key agent
  pull endpoints. Use when editing Authentik stacks, Blueprints, or SSO/WSS flows.
---

# Authentik Main & Standalone Proxy Outpost for Central OpenManager

Follow these rules whenever configuring `Authentik Main`, `authentik-proxy`, or Authentik Blueprints (`authentik/blueprints/`).

## 1. Architecture & Version Pinning

1. **Exact Version Match**:
   - Pin `ghcr.io/goauthentik/server:${AUTHENTIK_TAG}` (for both `server` and `worker` containers) and `ghcr.io/goauthentik/proxy:${AUTHENTIK_TAG}` to the exact same `YYYY.M.P` release (never `:latest`).
   - Always deploy `authentik-worker` alongside `authentik-server` and `authentik-postgresql` (Authentik 2025.10+/2026.x is Redis-free; `worker` processes Blueprints, background tasks, and Outpost state).
   - Map project `.env` variable `AUTHENTIK_OUTPOST_TOKEN` to container environment variable `AUTHENTIK_TOKEN` on `authentik-proxy`.

## 2. Central OpenManager Protection & Agent API Coexistence

Unlike decentralized portals, **only ONE `authentik-proxy` Outpost is required** (deployed in front of `haproxy-openmanager` on the Hub, or on the single machine in `local-all-in-one` mode):
1. **Proxy Provider Settings**:
   - `mode`: `proxy` (Standalone Proxy).
   - `external_host`: `https://${OPENMANAGER_PUBLIC_DOMAIN}`.
   - `internal_host`: `${OPENMANAGER_INTERNAL_URL}` (`http://openmanager-router:8080` inside `mgmt_internal`).
   - `internal_host_ssl_validation`: `false` (plain HTTP inside isolated `mgmt_internal` Docker bridge).
   - `authorization_flow`: `default-provider-authorization-implicit-consent`.
2. **RBAC Policy**:
   - Bind Group `${AUTHENTIK_ALLOWED_GROUP}` (`infra-admins`) to the Application; non-members receive `HTTP 403` at `authentik-proxy` before touching OpenManager.
3. **Coexistence with Satellite `haproxy-agent` Polling**:
   - Human browsers (no `X-API-Key` header) ALWAYS route through `authentik-proxy` (`127.0.0.1:${AUTHENTIK_PROXY_LOOPBACK_PORT}`).
   - Satellite `haproxy-agent` requests matching ONLY `/api/agents*`, `/api/clusters*`, or `/api/configuration/agents/*` WITH header `X-API-Key` route on HAProxy Inbound to `127.0.0.1:${OPENMANAGER_AGENT_API_LOOPBACK_PORT}` (`openmanager-router` -> `openmanager-backend:8000`), where `validate_agent_api_key` verifies the token.

## 3. Outbound WSS Under `net.ipv4.ip_forward = 0`

- `authentik-proxy` runs inside `mgmt_internal` (`${MGMT_SUBNET}`), exposing ONLY `"127.0.0.1:${AUTHENTIK_PROXY_LOOPBACK_PORT}:9000"`, with `extra_hosts: ["${AUTHENTIK_DOMAIN}:host-gateway"]` so `/ws/outpost/` and `/application/o/token/` traverse HAProxy Outbound SNI Passthrough (`${DUMMY_OUTBOUND_IP}:443`).
- Failure mode: if `Authentik Main` is unreachable, new browser logins fail closed (`502`/`302`), while running HAProxy instances on all Satellite nodes continue serving live production traffic uninterrupted.
