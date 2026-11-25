# ==============================================================================
# RPA Revert Proxy — Master HAProxy Configuration Template v1.1.0
# Compatible with HAProxy OpenManager Partial Config Sync:
# - `global`, `resolvers`, `defaults`, and `listen` blocks are preserved locally!
# ==============================================================================

global
    master-worker
    hard-stop-after ${HAPROXY_HARD_STOP_AFTER}
    tune.bufsize ${HAPROXY_TUNE_BUFSIZE}
    maxconn 10000
    user haproxy
    group haproxy
    log stdout format raw local0 info
    stats socket /var/run/haproxy/admin.sock mode 660 level admin expose-fd listeners

    # Modern TLS Baseline (TLS 1.2 / 1.3)
    ssl-default-bind-options ssl-min-ver ${HAPROXY_TLS_MIN_VER} no-tls-tickets
    ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305

# Placed immediately after `global` (before `defaults`) so haproxy-agent
# partial-config merge preserves `resolvers host_dns` automatically on every sync
resolvers host_dns
    nameserver dns1 ${HOST_UPSTREAM_DNS_1}:53
    nameserver dns2 ${HOST_UPSTREAM_DNS_2}:53
    accepted_payload_size 8192
    resolve_retries 3
    timeout resolve 2s
    timeout retry   1s
    hold valid      30s
    hold nx         10s
    hold other      10s

defaults
    log global
    option dontlognull
    timeout connect 5s
    timeout client  60s
    timeout server  60s
    timeout http-request 15s
    timeout http-keep-alive 15s

# Preserved `listen` block for independent Prometheus Observability & Stats
listen prometheus_exporter
    bind 127.0.0.1:${HAPROXY_METRICS_PORT}
    mode http
    http-request use-service prometheus-exporter if { path /metrics }
    stats enable
    stats uri /stats
    stats refresh 10s

# ==============================================================================
# INBOUND LAYER 7 — HTTP REDIRECT & HTTPS (HTTP/2) TERMINATION ON HOST LAN IP
# ==============================================================================
frontend fe_inbound_http
    bind ${HOST_LAN_IP}:80
    mode http
    option httplog
    http-request redirect scheme https code 301

frontend fe_inbound_https
    bind ${HOST_LAN_IP}:443 ssl crt /etc/ssl/haproxy/ alpn h2,http/1.1
    mode http
    option httplog

    # Sanitize client headers to prevent spoofing X-Forwarded-* or Authentik identity headers
    http-request del-header X-Forwarded-Proto
    http-request del-header X-authentik-username
    http-request del-header X-authentik-groups
    http-request del-header X-authentik-email
    http-request set-header X-Forwarded-Proto https
    http-request set-header X-Forwarded-Host %[req.hdr(Host)]
    option forwardfor
    http-response set-header Strict-Transport-Security "max-age=31536000; includeSubDomains"

__HAPROXY_INBOUND_ROLE_USE_BACKENDS__

__HAPROXY_INBOUND_ROLE_BACKENDS__

# ==============================================================================
# OUTBOUND LAYER 4 — TCP SNI PASSTHROUGH ON PERSISTENT DUMMY INTERFACE
# ==============================================================================
frontend fe_outbound_tls
    bind ${DUMMY_OUTBOUND_IP}:443
    mode tcp
    option tcplog
    timeout client ${OUTBOUND_WSS_TIMEOUT}
    option clitcpka

    tcp-request inspect-delay ${OUTBOUND_INSPECT_DELAY}
    tcp-request content accept if { req.ssl_hello_type 1 }
    tcp-request content reject

__HAPROXY_OUTBOUND_USE_BACKENDS__

__HAPROXY_OUTBOUND_BACKENDS__
