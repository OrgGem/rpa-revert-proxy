[Unit]
Description=HAProxy Container Service Wrapper (Bridges haproxy-agent systemctl calls to Docker)
After=docker.service rpa-dummy0.service
Requires=docker.service rpa-dummy0.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'docker ps --format "{{.Names}}" | grep -qx haproxy || docker start haproxy'
ExecReload=/usr/local/bin/haproxy-ctl reload
ExecStop=/bin/sh -c 'docker stop haproxy 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
