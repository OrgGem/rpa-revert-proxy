#!/usr/bin/env bash
# ==============================================================================
# haproxy-ctl.sh — Audited Validation, Graceful Drain Reload & Break-Glass CLI
# Installed to: /usr/local/bin/haproxy-ctl (FR-07)
# ==============================================================================
set -euo pipefail

CONTAINER_NAME="${HAPROXY_CONTAINER_NAME:-haproxy}"
cfg_host_dir="${HAPROXY_CONFIG_HOST_DIR:-/etc/haproxy}"
cfg_host_file="${cfg_host_dir}/haproxy.cfg"
BACKUP_DIR="${cfg_host_dir}/backups"
CONTAINER_CFG_FILE="/etc/haproxy/haproxy.cfg"
AUDIT_LOG="/var/log/haproxy-control-audit.log"

audit_log() {
    local action="$1"
    local result="$2"
    local msg="$3"
    local actor="${SUDO_USER:-${USER:-root}}"
    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    local entry="{\"ts\":\"${ts}\",\"actor\":\"${actor}\",\"action\":\"${action}\",\"result\":\"${result}\",\"detail\":\"${msg}\"}"
    echo "${entry}" >> "${AUDIT_LOG}" 2>/dev/null || true
    logger -t haproxy-ctl "${entry}" 2>/dev/null || true
}

usage() {
    cat <<EOF
Usage: $(basename "$0") <validate|reload|backup|rollback|status|logs>
EOF
}

ensure_container_running() {
    if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
        audit_log "check" "fail" "Container ${CONTAINER_NAME} not running"
        echo "[FAIL] Container '${CONTAINER_NAME}' is not running." >&2
        exit 1
    fi
}

cmd_validate() {
    ensure_container_running
    if docker exec "${CONTAINER_NAME}" haproxy -c -V -f "${CONTAINER_CFG_FILE}"; then
        audit_log "validate" "ok" "${CONTAINER_CFG_FILE} syntax valid"
    else
        audit_log "validate" "fail" "${CONTAINER_CFG_FILE} syntax invalid"
        exit 1
    fi
}

cmd_backup() {
    mkdir -p "${BACKUP_DIR}"
    chmod 0700 "${BACKUP_DIR}"
    if [[ ! -f "${cfg_host_file}" ]]; then
        echo "[FAIL] Config file not found at ${cfg_host_file}." >&2
        exit 1
    fi
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    local dst="${BACKUP_DIR}/haproxy.cfg.${ts}.bak"
    cp -p "${cfg_host_file}" "${dst}"
    ls -1t "${BACKUP_DIR}"/haproxy.cfg.*.bak 2>/dev/null | tail -n +21 | xargs -r rm -f
    audit_log "backup" "ok" "Created snapshot ${dst}"
    echo "[OK] Backed up config to ${dst}"
}

cmd_reload() {
    ensure_container_running
    cmd_validate
    cmd_backup
    echo "[INFO] Sending SIGUSR2 to ${CONTAINER_NAME} (graceful drain up to hard-stop-after)..."
    docker kill -s USR2 "${CONTAINER_NAME}" >/dev/null
    sleep 1
    audit_log "reload" "ok" "Delivered SIGUSR2 to ${CONTAINER_NAME}"
    echo "[OK] Graceful reload triggered via SIGUSR2."
}

cmd_rollback() {
    local latest_bak
    latest_bak="$(ls -1t "${BACKUP_DIR}"/haproxy.cfg.*.bak 2>/dev/null | head -n 1 || true)"
    if [[ -z "${latest_bak}" ]]; then
        audit_log "rollback" "fail" "No backup snapshot available"
        echo "[FAIL] No backup files found in ${BACKUP_DIR}." >&2
        exit 1
    fi
    echo "[WARN] Rolling back ${cfg_host_file} from ${latest_bak}..."
    cp -p "${latest_bak}" "${cfg_host_file}"
    if docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
        cmd_validate
        docker kill -s USR2 "${CONTAINER_NAME}" >/dev/null
    else
        docker start "${CONTAINER_NAME}"
    fi
    audit_log "rollback" "ok" "Restored ${latest_bak}"
    echo "[OK] Rollback applied from ${latest_bak}."
}

cmd_status() {
    docker ps -a --filter "name=^/${CONTAINER_NAME}$" --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
    if docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
        docker top "${CONTAINER_NAME}"
    fi
}

cmd_logs() {
    docker logs --tail 100 "${CONTAINER_NAME}"
}

case "${1:-}" in
    validate) cmd_validate ;;
    reload)   cmd_reload ;;
    backup)   cmd_backup ;;
    rollback) cmd_rollback ;;
    status)   cmd_status ;;
    logs)     cmd_logs ;;
    *)        usage; exit 1 ;;
esac
