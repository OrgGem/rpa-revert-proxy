#!/usr/bin/env bash
# ==============================================================================
# install-openmanager-agent.sh — Install & Immutable-Lock (chattr +i) Pull Agent
# Polls Central HAProxy OpenManager over HTTPS (:443) without inter-server SSH
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

if [[ $EUID -ne 0 ]]; then
    echo "[FAIL] Run as root: sudo bash scripts/install-openmanager-agent.sh" >&2
    exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
    echo "[FAIL] Missing ${ENV_FILE}" >&2
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

if [[ -z "${OPENMANAGER_AGENT_TOKEN}" || "${OPENMANAGER_AGENT_TOKEN}" == CHANGE_ME_* || "${OPENMANAGER_AGENT_TOKEN}" == dev_only_* ]]; then
    echo "[FAIL] Set a valid OPENMANAGER_AGENT_TOKEN (generated in OpenManager UI -> Security -> Agent Tokens) in .env first." >&2
    exit 1
fi

# Ensure OPENMANAGER_PUBLIC_DOMAIN resolves to OPENMANAGER_HUB_BACKEND_IP on local/lab setups if needed
if ! getent hosts "${OPENMANAGER_PUBLIC_DOMAIN}" >/dev/null 2>&1; then
    echo "${OPENMANAGER_HUB_BACKEND_IP} ${OPENMANAGER_PUBLIC_DOMAIN}" >> /etc/hosts
    echo "[INFO] Added /etc/hosts entry: ${OPENMANAGER_HUB_BACKEND_IP} -> ${OPENMANAGER_PUBLIC_DOMAIN}"
fi

CURL_FLAGS=("-fsSL")
if [[ "${AUTHENTIK_INSECURE}" == "true" ]]; then
    CURL_FLAGS+=("-k")
fi

TMP_INSTALLER="$(mktemp /tmp/om-agent-installer.XXXXXX.sh)"
trap 'rm -f "${TMP_INSTALLER}"' EXIT

echo "[INFO] Requesting agent script from https://${OPENMANAGER_PUBLIC_DOMAIN}/api/agents/generate-install-script..."
PAYLOAD="$(jq -n \
    --arg platform "linux" \
    --arg arch "$(uname -m)" \
    --arg agent_name "${NODE_ID}" \
    --arg pool_id "${OPENMANAGER_POOL_ID}" \
    --arg cluster_id "${OPENMANAGER_CLUSTER_ID}" \
    --arg haproxy_bin_path "/usr/local/sbin/haproxy" \
    --arg haproxy_config_path "${HAPROXY_CONFIG_HOST_DIR}/haproxy.cfg" \
    --arg stats_socket_path "${HAPROXY_RUNTIME_SOCKET_DIR}/admin.sock" \
    '{
        platform: $platform,
        architecture: $arch,
        agent_name: $agent_name,
        pool_id: ($pool_id | tonumber),
        cluster_id: ($cluster_id | tonumber),
        haproxy_bin_path: $haproxy_bin_path,
        haproxy_config_path: $haproxy_config_path,
        stats_socket_path: $stats_socket_path
    }')"

RESPONSE_JSON="$(curl "${CURL_FLAGS[@]}" -X POST \
    "https://${OPENMANAGER_PUBLIC_DOMAIN}/api/agents/generate-install-script" \
    -H "Content-Type: application/json" \
    -H "X-API-Key: ${OPENMANAGER_AGENT_TOKEN}" \
    -d "${PAYLOAD}")"

echo "${RESPONSE_JSON}" | jq -r '.script // empty' > "${TMP_INSTALLER}"
if [[ ! -s "${TMP_INSTALLER}" ]] || ! head -n 1 "${TMP_INSTALLER}" | grep -q "^#!/bin/bash"; then
    echo "[FAIL] Did not receive a valid bash installer script from OpenManager Hub." >&2
    exit 1
fi

# SECURITY HARDENING (FR-06.3 Anti-RCE):
# Disable remote script self-upgrade when OPENMANAGER_ALLOW_AGENT_SELF_UPGRADE != true
if [[ "${OPENMANAGER_ALLOW_AGENT_SELF_UPGRADE}" != "true" ]]; then
    echo "[INFO] Stripping/neutralizing remote self-upgrade capability in haproxy-agent..."
    sed -i 's/should_upgrade="true"/should_upgrade="false"/g' "${TMP_INSTALLER}"
    sed -i 's/if \[\[ "\$should_upgrade" == "true" \]\]; then/if false; then # LOCKED_BY_RPA_SECURITY_POLICY/g' "${TMP_INSTALLER}"
fi

# Unlock existing binary if previously chattr +i locked
if [[ -f /usr/local/bin/haproxy-agent ]]; then
    chattr -i /usr/local/bin/haproxy-agent 2>/dev/null || true
fi

# Backup our pre-seeded haproxy.cfg before running interactive-bypassed installer
PRESEED_BACKUP="${HAPROXY_CONFIG_HOST_DIR}/haproxy.cfg.rpa-preseed"
cp -p "${HAPROXY_CONFIG_HOST_DIR}/haproxy.cfg" "${PRESEED_BACKUP}"

yes Y | bash "${TMP_INSTALLER}"

# Restore pre-seeded dual-IP config if installer blanked frontends before initial Bulk Import
if [[ -f "${PRESEED_BACKUP}" ]]; then
    cp -p "${PRESEED_BACKUP}" "${HAPROXY_CONFIG_HOST_DIR}/haproxy.cfg"
    /usr/local/bin/haproxy-ctl reload || true
fi

# Lock /usr/local/bin/haproxy-agent immutable against tampering / remote overwrite
if [[ -f /usr/local/bin/haproxy-agent ]]; then
    chown root:root /usr/local/bin/haproxy-agent
    chmod 0500 /usr/local/bin/haproxy-agent
    if [[ "${OPENMANAGER_ALLOW_AGENT_SELF_UPGRADE}" != "true" ]]; then
        chattr +i /usr/local/bin/haproxy-agent
        echo "[OK] Applied root:root 0500 + immutable lock (chattr +i) on /usr/local/bin/haproxy-agent."
    fi
fi

if [[ -f /etc/haproxy-agent/config.json ]]; then
    chown root:root /etc/haproxy-agent/config.json
    chmod 0600 /etc/haproxy-agent/config.json
fi

systemctl restart haproxy-agent
systemctl status haproxy-agent --no-pager -l | head -n 15
echo "[OK] haproxy-agent installed, hardened, and polling https://${OPENMANAGER_PUBLIC_DOMAIN}."
