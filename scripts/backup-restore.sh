#!/usr/bin/env bash
# ==============================================================================
# backup-restore.sh — Disaster Recovery Tool for Hub DBs & HAProxy State (DR-01)
# Targets RPO <= 24h & RTO <= 30m across Authentik, OpenManager & HAProxy
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

if [[ $EUID -ne 0 ]]; then
    echo "[FAIL] Run as root: sudo bash scripts/backup-restore.sh <backup|restore> [archive_path]" >&2
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

BACKUP_ROOT="${PROJECT_ROOT}/backups"
mkdir -p "${BACKUP_ROOT}"
chmod 0700 "${BACKUP_ROOT}"

do_backup() {
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    local work_dir
    work_dir="$(mktemp -d)"
    trap 'rm -rf "${work_dir}"' EXIT

    echo "[INFO] Snapshotting HAProxy config and TLS certificates..."
    mkdir -p "${work_dir}/haproxy" "${work_dir}/ssl"
    cp -a "${HAPROXY_CONFIG_HOST_DIR}/." "${work_dir}/haproxy/" 2>/dev/null || true
    cp -a "${HAPROXY_SSL_HOST_DIR}/." "${work_dir}/ssl/" 2>/dev/null || true

    if docker ps --format '{{.Names}}' | grep -qx "authentik-postgresql"; then
        echo "[INFO] Dumping Authentik PostgreSQL database..."
        docker exec authentik-postgresql pg_dump -U "${LOCAL_IDP_POSTGRES_USER}" "${LOCAL_IDP_POSTGRES_DB}" \
            > "${work_dir}/authentik-db.sql"
    fi

    if docker ps --format '{{.Names}}' | grep -qx "openmanager-postgres"; then
        echo "[INFO] Dumping HAProxy OpenManager PostgreSQL database..."
        docker exec openmanager-postgres pg_dump -U "${OPENMANAGER_POSTGRES_USER}" "${OPENMANAGER_POSTGRES_DB}" \
            > "${work_dir}/openmanager-db.sql"
    fi

    local archive="${BACKUP_ROOT}/rpa-dr-backup-${NODE_ID}-${ts}.tar.gz"
    tar -C "${work_dir}" -czf "${archive}" .
    chmod 0600 "${archive}"
    echo "[OK] DR backup created: ${archive}"
}

do_restore() {
    local archive="${1:-}"
    if [[ -z "${archive}" || ! -f "${archive}" ]]; then
        echo "[FAIL] Specify a valid backup archive (.tar.gz) to restore." >&2
        exit 1
    fi

    local work_dir
    work_dir="$(mktemp -d)"
    trap 'rm -rf "${work_dir}"' EXIT
    tar -C "${work_dir}" -xzf "${archive}"

    if [[ -d "${work_dir}/ssl" ]]; then
        mkdir -p "${HAPROXY_SSL_HOST_DIR}"
        cp -a "${work_dir}/ssl/." "${HAPROXY_SSL_HOST_DIR}/"
        chmod 0700 "${HAPROXY_SSL_HOST_DIR}"
    fi

    if [[ -d "${work_dir}/haproxy" ]]; then
        mkdir -p "${HAPROXY_CONFIG_HOST_DIR}"
        cp -a "${work_dir}/haproxy/." "${HAPROXY_CONFIG_HOST_DIR}/"
    fi

    if [[ -f "${work_dir}/authentik-db.sql" ]] && docker ps --format '{{.Names}}' | grep -qx "authentik-postgresql"; then
        echo "[INFO] Restoring Authentik PostgreSQL database..."
        docker exec -i authentik-postgresql psql -U "${LOCAL_IDP_POSTGRES_USER}" -d "${LOCAL_IDP_POSTGRES_DB}" \
            < "${work_dir}/authentik-db.sql" >/dev/null
    fi

    if [[ -f "${work_dir}/openmanager-db.sql" ]] && docker ps --format '{{.Names}}' | grep -qx "openmanager-postgres"; then
        echo "[INFO] Restoring OpenManager PostgreSQL database..."
        docker exec -i openmanager-postgres psql -U "${OPENMANAGER_POSTGRES_USER}" -d "${OPENMANAGER_POSTGRES_DB}" \
            < "${work_dir}/openmanager-db.sql" >/dev/null
    fi

    /usr/local/bin/haproxy-ctl reload || true
    echo "[OK] DR restore completed from ${archive}."
}

case "${1:-}" in
    backup)  do_backup ;;
    restore) do_restore "${2:-}" ;;
    *)       echo "Usage: $0 <backup|restore [archive.tar.gz]>"; exit 1 ;;
esac
