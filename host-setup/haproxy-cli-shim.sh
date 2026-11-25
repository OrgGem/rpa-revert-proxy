#!/usr/bin/env bash
# ==============================================================================
# haproxy-cli-shim.sh — Installed to /usr/local/sbin/haproxy
# Bridges host-level `haproxy -c -f <file>` calls from haproxy-agent into the
# hardened Docker `haproxy` container without installing HAProxy on Host OS.
# ==============================================================================
set -euo pipefail

CONTAINER_NAME="${HAPROXY_CONTAINER_NAME:-haproxy}"
cfg_host_dir="${HAPROXY_CONFIG_HOST_DIR:-/etc/haproxy}"

if [[ "${1:-}" == "-v" || "${1:-}" == "--version" ]]; then
    exec docker exec "${CONTAINER_NAME}" haproxy -v
fi

# Detect `-f <candidate_file>` and stage external temp files into ${cfg_host_dir}
ARGS=()
STAGE_HOST_FILE=""
cleanup() {
    if [[ -n "${STAGE_HOST_FILE}" && -f "${STAGE_HOST_FILE}" ]]; then
        rm -f "${STAGE_HOST_FILE}"
    fi
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
    if [[ "$1" == "-f" && $# -ge 2 ]]; then
        CANDIDATE="$2"
        if [[ "${CANDIDATE}" == "${cfg_host_dir}/"* ]]; then
            REL_SUB="${CANDIDATE#"${cfg_host_dir}/"}"
            ARGS+=("-f" "/etc/haproxy/${REL_SUB}")
        elif [[ -f "${CANDIDATE}" ]]; then
            STAGE_NAME=".agent-validate-$$.cfg"
            STAGE_HOST_FILE="${cfg_host_dir}/${STAGE_NAME}"
            cp -f "${CANDIDATE}" "${STAGE_HOST_FILE}"
            chmod 0644 "${STAGE_HOST_FILE}"
            ARGS+=("-f" "/etc/haproxy/${STAGE_NAME}")
        else
            ARGS+=("-f" "${CANDIDATE}")
        fi
        shift 2
    else
        ARGS+=("$1")
        shift
    fi
done

docker exec "${CONTAINER_NAME}" haproxy "${ARGS[@]}"
