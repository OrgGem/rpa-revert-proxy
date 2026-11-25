#!/usr/bin/env bash
# ==============================================================================
# bootstrap-host.sh — Idempotent Linux Host Setup for RPA Revert Proxy v1.1.0
# Enforces FR-01 (ip_forward=0 IPv4/IPv6, dummy0) & FR-03A (Egress Enforcement)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

if [[ $EUID -ne 0 ]]; then
    echo "[FAIL] Run as root: sudo bash host-setup/bootstrap-host.sh" >&2
    exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
    echo "[FAIL] Missing ${ENV_FILE}. Run: python3 scripts/check_env_sync.py --sync" >&2
    exit 1
fi

chmod 0600 "${ENV_FILE}"

# 1. Validate .env and render system configuration files
echo "[INFO] Validating environment schema and rendering templates..."
python3 "${PROJECT_ROOT}/scripts/render_configs.py"

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

# 2. Install required host utilities for haproxy-agent & chattr immutability
echo "[INFO] Ensuring required host packages (socat, jq, curl, e2fsprogs) are installed..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq socat jq curl openssl e2fsprogs
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q socat jq curl openssl e2fsprogs
elif command -v yum >/dev/null 2>&1; then
    yum install -y -q socat jq curl openssl e2fsprogs
fi

# 3. Enforce sysctl IPv4 & IPv6 ip_forward = 0 & loose rp_filter
echo "[INFO] Applying kernel sysctl hardening (/etc/sysctl.d/99-haproxy-zero-fwd.conf)..."
install -m 0644 "${SCRIPT_DIR}/99-haproxy-zero-fwd.conf" /etc/sysctl.d/99-haproxy-zero-fwd.conf
sysctl --system >/dev/null
sysctl -w net.ipv4.ip_forward=0 >/dev/null
sysctl -w net.ipv6.conf.all.forwarding=0 >/dev/null || true
sysctl -w net.ipv6.conf.default.forwarding=0 >/dev/null || true

# 4. Provision persistent dummy0 interface before Docker starts
echo "[INFO] Activating systemd unit rpa-dummy0.service (${DUMMY_INTERFACE_NAME}: ${DUMMY_OUTBOUND_IP}/32)..."
install -m 0644 "${SCRIPT_DIR}/rpa-dummy0.service" /etc/systemd/system/rpa-dummy0.service
systemctl daemon-reload
systemctl enable --now rpa-dummy0.service
ip -4 addr show dev "${DUMMY_INTERFACE_NAME}" | grep -q "${DUMMY_OUTBOUND_IP}"

# 5. Configure /etc/docker/daemon.json and verify IPv4/IPv6 forwarding remain 0
echo "[INFO] Installing /etc/docker/daemon.json..."
mkdir -p /etc/docker
if [[ -f /etc/docker/daemon.json ]] && ! cmp -s "${SCRIPT_DIR}/daemon.json" /etc/docker/daemon.json; then
    cp /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)"
fi
install -m 0644 "${SCRIPT_DIR}/daemon.json" /etc/docker/daemon.json
systemctl enable --now docker
systemctl restart docker

if [[ "$(sysctl -n net.ipv4.ip_forward)" != "0" ]]; then
    echo "[FAIL] net.ipv4.ip_forward did not remain 0 after Docker restart!" >&2
    exit 1
fi
echo "[OK] Verified net.ipv4.ip_forward = 0 after Docker restart."

# 6. Prepare isolated HAProxy config, 0600 TLS cert store & stats socket directories
mkdir -p "${HAPROXY_CONFIG_HOST_DIR}/backups" "${HAPROXY_SSL_HOST_DIR}/crtlists" "${HAPROXY_RUNTIME_SOCKET_DIR}"
chown -R root:root "${HAPROXY_CONFIG_HOST_DIR}" "${HAPROXY_SSL_HOST_DIR}"
chmod 0755 "${HAPROXY_CONFIG_HOST_DIR}"
chmod 0700 "${HAPROXY_SSL_HOST_DIR}" "${HAPROXY_CONFIG_HOST_DIR}/backups"
chmod 0775 "${HAPROXY_RUNTIME_SOCKET_DIR}"

if [[ -f "${PROJECT_ROOT}/haproxy/haproxy.cfg" && ! -f "${HAPROXY_CONFIG_HOST_DIR}/haproxy.cfg" ]]; then
    install -o root -g root -m 0644 "${PROJECT_ROOT}/haproxy/haproxy.cfg" "${HAPROXY_CONFIG_HOST_DIR}/haproxy.cfg"
fi

touch /var/log/haproxy-control-audit.log
chmod 0600 /var/log/haproxy-control-audit.log

# 7. Install haproxy-ctl, /usr/local/sbin/haproxy shim & systemd haproxy.service wrapper
install -m 0755 "${PROJECT_ROOT}/scripts/haproxy-ctl.sh" /usr/local/bin/haproxy-ctl
install -m 0755 "${SCRIPT_DIR}/haproxy-cli-shim.sh" /usr/local/sbin/haproxy
install -m 0644 "${SCRIPT_DIR}/haproxy.service" /etc/systemd/system/haproxy.service
systemctl daemon-reload
systemctl enable haproxy.service >/dev/null 2>&1 || true

# 8. Configure Host Ingress & Egress Enforcement Firewall (FR-01 & FR-03A)
echo "[INFO] Applying Ingress & Outbound Egress Enforcement firewall rules..."
add_ipt_once() {
    local table="$1"; shift
    if ! iptables -t "${table}" -C "$@" 2>/dev/null; then
        iptables -t "${table}" -I "$@"
    fi
}

if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=80/tcp >/dev/null
    firewall-cmd --permanent --add-port=443/tcp >/dev/null
    firewall-cmd --reload >/dev/null
elif command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow in on "${HOST_LAN_INTERFACE}" to "${HOST_LAN_IP}" port 80 proto tcp >/dev/null
    ufw allow in on "${HOST_LAN_INTERFACE}" to "${HOST_LAN_IP}" port 443 proto tcp >/dev/null
fi

# Allow Docker bridges -> dummy0:443 (TCP SNI Passthrough), block QUIC UDP :443 & FORWARD bypass
add_ipt_once filter INPUT -i docker0 -d "${DUMMY_OUTBOUND_IP}/32" -p tcp --dport 443 -j ACCEPT
add_ipt_once filter INPUT -i br-+ -d "${DUMMY_OUTBOUND_IP}/32" -p tcp --dport 443 -j ACCEPT
add_ipt_once filter INPUT -i docker0 -p udp --dport 443 -j REJECT
add_ipt_once filter INPUT -i br-+ -p udp --dport 443 -j REJECT
add_ipt_once filter FORWARD -i docker0 -j DROP
add_ipt_once filter FORWARD -i br-+ -j DROP

if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -C FORWARD -i docker0 -j DROP 2>/dev/null || ip6tables -I FORWARD -i docker0 -j DROP || true
    ip6tables -C FORWARD -i br-+ -j DROP 2>/dev/null || ip6tables -I FORWARD -i br-+ -j DROP || true
fi

echo "[OK] Host bootstrap v1.1.0 completed (IPv4/IPv6 ip_forward=0, dummy0=${DUMMY_OUTBOUND_IP}, Egress Enforcement active)."
