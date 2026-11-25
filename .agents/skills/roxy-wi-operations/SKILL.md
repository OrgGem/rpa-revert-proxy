---
name: roxy-wi-operations
description: >-
  Configures and hardens Roxy-WI Community Edition in isolated Docker networks,
  persistent storage, shared /etc/haproxy permissions, and least-privilege local
  SSH control of HAProxy. Use when working on Roxy-WI containers, roxyadmin SSH
  users, sudoers rules, or HAProxy management workflows.
---

# Roxy-WI Isolated Deployment & Least-Privilege SSH Operations

Follow these guidelines whenever configuring the `roxy-wi` container, Host SSH integration, or `/etc/haproxy` file permissions.

## 1. Security Version Floor & Network Isolation

1. **CVE-Patched Version Floor**:
   - Always pin Roxy-WI to a patched release (`>= 8.2.8.2` or official GHCR `ghcr.io/roxy-wi/roxy-wi` `9.1.x+`) to mitigate critical vulnerabilities (`CVE-2026-33076`, `CVE-2026-33078`, `CVE-2026-22265`).
2. **Zero Direct Host Exposure**:
   - `roxy-wi` MUST NOT declare `ports:` in `docker-compose.yml`.
   - Attach `roxy-wi` strictly to `mgmt_internal` alongside `authentik-proxy`.
3. **Mandatory Persistent Volumes**:
   - Always mount persistent volumes for `/etc/roxy-wi`, `/var/lib/roxy-wi`, and SSH keys so recreating or upgrading `roxy-wi` never wipes configured servers, SQLite DB, or credentials.

## 2. Local SSH to Satellite Host (Respecting No-Inter-Server-SSH Policy)

- Because inter-server SSH is blocked by firewall policy, each satellite node runs its own local `roxy-wi` which connects over SSH ONLY to its own Host via:
  ```yaml
  extra_hosts:
    - "host.docker.internal:host-gateway"
  ```
- Host Firewall (`iptables`/`firewalld`/`ufw`) MUST allow TCP port `22` on `INPUT` exclusively from `${MGMT_SUBNET}` (e.g. `172.25.0.0/24`), while keeping LAN port `22` restricted per corporate policy.

## 3. Least-Privilege `roxyadmin` User & Shared `/etc/haproxy` Permissions

1. **NEVER add `roxyadmin` to the `docker` group** (which grants root equivalence on the Host).
2. **Shared File Permissions with HAProxy Container (UID `99`)**:
   - Create a dedicated host group (or align with GID `99`), set ownership `roxyadmin:99` and `chmod 2770` (`setgid`) on `/etc/haproxy` and `/etc/haproxy/certs`, plus default POSIX ACLs:
     ```bash
     setfacl -R -m u:99:rX,u:roxyadmin:rwX /etc/haproxy
     setfacl -R -d -m u:99:rX,u:roxyadmin:rwX /etc/haproxy
     ```
   - Keep TLS private keys `0640` (readable by UID `99`, never world-readable `0644`).
3. **Restricted `sudoers` (`/etc/sudoers.d/roxyadmin`)**:
   - Allow `NOPASSWD` ONLY for explicit, non-wildcard-exploitable HAProxy validation, log inspection, status check, and `USR2` reload commands via `scripts/haproxy-ctl.sh` (and exact Docker read/signal commands required by Roxy-WI Docker mode).

## 4. Expected Authentication Behavior ("Double Login")

- Roxy-WI Community Edition does not map `X-authentik-username` headers into internal sessions.
- Passing `authentik-proxy` SSO automatically unlocks the outer pre-auth perimeter across all authorized nodes; operators still authenticate once per node against Roxy-WI's internal login screen. Do not patch Roxy-WI source files to bypass internal sessions unless explicitly requested and security-reviewed.
