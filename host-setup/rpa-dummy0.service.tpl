[Unit]
Description=Persistent Dummy Interface (${DUMMY_INTERFACE_NAME}) for HAProxy Outbound SNI Passthrough
DefaultDependencies=no
After=systemd-sysctl.service
Before=network-pre.target network.target docker.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '/sbin/ip link show ${DUMMY_INTERFACE_NAME} >/dev/null 2>&1 || /sbin/ip link add ${DUMMY_INTERFACE_NAME} type dummy; /sbin/ip addr replace ${DUMMY_OUTBOUND_IP}/32 dev ${DUMMY_INTERFACE_NAME}; /sbin/ip link set ${DUMMY_INTERFACE_NAME} up'
ExecStop=/bin/sh -c '/sbin/ip link del ${DUMMY_INTERFACE_NAME} 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
