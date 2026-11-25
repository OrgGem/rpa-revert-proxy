#!/usr/bin/env bash
# ==============================================================================
# generate-local-certs.sh — Generate Local Root CA & Multi-SAN PEM in /etc/ssl/haproxy
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
    echo "[FAIL] Missing ${ENV_FILE}. Run: python3 scripts/check_env_sync.py --sync" >&2
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

OUT_DIR="${1:-${PROJECT_ROOT}/haproxy/certs}"
mkdir -p "${OUT_DIR}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

CA_KEY="${OUT_DIR}/local-root-ca.key"
CA_CRT="${OUT_DIR}/local-root-ca.crt"
BUNDLE_PEM="${OUT_DIR}/rpa-local-bundle.pem"

if [[ ! -f "${CA_CRT}" || ! -f "${CA_KEY}" ]]; then
    echo "[INFO] Generating Local Root CA (${CA_CRT})..."
    openssl genrsa -out "${CA_KEY}" 4096 2>/dev/null
    openssl req -x509 -new -nodes -key "${CA_KEY}" -sha256 -days 3650 \
        -subj "/C=VN/ST=HCMC/O=RPA-Revert-Proxy-Lab/CN=RPA Local Root CA" \
        -out "${CA_CRT}" 2>/dev/null
    chmod 0600 "${CA_KEY}"
    chmod 0644 "${CA_CRT}"
fi

cat > "${TMP_DIR}/san.cnf" <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
req_extensions = req_ext
distinguished_name = dn

[dn]
C = VN
ST = HCMC
O = RPA-Revert-Proxy
CN = ${OPENMANAGER_PUBLIC_DOMAIN}

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${OPENMANAGER_PUBLIC_DOMAIN}
DNS.2 = ${APP_PUBLIC_DOMAIN}
DNS.3 = ${AUTHENTIK_DOMAIN}
IP.1  = ${HOST_LAN_IP}
EOF

echo "[INFO] Generating multi-SAN leaf certificate for: ${OPENMANAGER_PUBLIC_DOMAIN}, ${APP_PUBLIC_DOMAIN}, ${AUTHENTIK_DOMAIN}..."
openssl genrsa -out "${TMP_DIR}/leaf.key" 2048 2>/dev/null
openssl req -new -key "${TMP_DIR}/leaf.key" -out "${TMP_DIR}/leaf.csr" -config "${TMP_DIR}/san.cnf" 2>/dev/null
openssl x509 -req -in "${TMP_DIR}/leaf.csr" -CA "${CA_CRT}" -CAkey "${CA_KEY}" -CAcreateserial \
    -out "${TMP_DIR}/leaf.crt" -days 825 -sha256 -extensions req_ext -extfile "${TMP_DIR}/san.cnf" 2>/dev/null

cat "${TMP_DIR}/leaf.crt" "${CA_CRT}" "${TMP_DIR}/leaf.key" > "${BUNDLE_PEM}"
chmod 0600 "${BUNDLE_PEM}"

if [[ $EUID -eq 0 && -d "${HAPROXY_SSL_HOST_DIR}" ]]; then
    install -o root -g root -m 0600 "${BUNDLE_PEM}" "${HAPROXY_SSL_HOST_DIR}/rpa-local-bundle.pem"
    install -o root -g root -m 0644 "${CA_CRT}" "${HAPROXY_CONFIG_HOST_DIR}/local-root-ca.crt"
    echo "[OK] Installed 0600 root:root PEM bundle to ${HAPROXY_SSL_HOST_DIR}/rpa-local-bundle.pem"
fi

echo "[OK] Generated HAProxy TLS PEM bundle: ${BUNDLE_PEM}"
