# RPA Revert Proxy — HAProxy (Zero-IP-Forward) + Authentik SSO + HAProxy OpenManager

Nền tảng triển khai **HAProxy 3.0 Inbound (HTTPS / HTTP/2) & Outbound (TCP SNI Passthrough)** dưới ràng buộc bảo mật nghiêm ngặt `net.ipv4.ip_forward = 0` (IPv4 & IPv6) và cấm mở SSH liên server, kết hợp **Control Plane Quản trị Đa Cụm Tập trung (`haproxy-openmanager`)** được bảo vệ bởi **Authentik Standalone Proxy SSO**.

---

## Điểm nhấn Kiến trúc (`v1.1.0`)

* **Loại bỏ `100%` NGINX trên toàn hệ thống:** Thay thế hoàn toàn NGINX ở cả tầng Edge Proxy lẫn bộ định tuyến nội bộ của OpenManager bằng `haproxy:3.0-alpine`.
* **Quản trị Tập trung qua Cơ chế Pull-Agent (`Zero Inter-Server SSH`):**
  * Chỉ vận hành **01 cụm `haproxy-openmanager` + `Authentik Main` + `authentik-proxy` duy nhất tại Server Chính (Hub)** để quản lý cấu hình, xem Version Diff, Rollback 1-click, phân phối SSL và theo dõi Real-time Metrics của toàn bộ hệ thống.
  * Các **Server Vệ tinh (Satellites)** không cần cài đặt Web UI, RabbitMQ hay mở cổng SSH quản trị: chỉ chạy `haproxy-agent` siêu nhẹ chủ động gọi **Outbound HTTPS (`:443`)** về Hub mỗi `30s` để kéo cấu hình mới và đẩy metrics từ `/var/run/haproxy/admin.sock`.
* **Tuân thủ tuyệt đối `ip_forward = 0` & Chống đi vòng Egress (`FR-03A`):** Tách biệt lưu lượng Inbound (`${HOST_LAN_IP}:443` → `127.0.0.1:<port>`) và Outbound SNI Passthrough (`dummy0` `10.254.254.1:443`), kết hợp Host Firewall chặn đứng mọi kết nối đi vòng qua IP trần, UDP `:443` (QUIC) hoặc IPv6.
* **Khóa Bảo mật Chống Leo thang Đặc quyền (`Anti-RCE & 0600 Key Isolation`):**
  * Vô hiệu hóa tính năng tự sửa/nâng cấp script từ xa và khóa bất biến file `/usr/local/bin/haproxy-agent` bằng `chattr +i` trên mọi Server vệ tinh.
  * Tách biệt khóa riêng tư TLS `/etc/ssl/haproxy/*.pem` (`0600 root:root`) khỏi các tiến trình worker `haproxy` không đặc quyền (UID `99`).

---

## Ba Chế độ Triển khai Hỗ trợ Đồng nhất

1. **`local-all-in-one` (Kiểm thử / PoC trọn bộ trên 01 Server Linux):** Chạy đồng thời Hub (`Authentik Main` + `authentik-proxy` + `OpenManager`) và Satellite (`HAProxy` + `haproxy-agent` + `mock-app`) trên cùng 01 máy chủ mà vẫn đi qua đúng luồng `dummy0` SNI Passthrough.
2. **`prod-hub` (Server Chính — Central Control Plane):** Vận hành Edge HAProxy, `Authentik Main` (`server` + `worker` + `postgresql`), `authentik-proxy` và `haproxy-openmanager`.
3. **`prod-satellite` (Các Server Vệ tinh 1..N):** Chỉ vận hành Edge/Outbound `HAProxy`, `haproxy-agent` (kéo cấu hình từ Hub qua HTTPS `:443`) và các container ứng dụng nghiệp vụ.

---

## Cấu trúc Thư mục

```text
.
├── .agents/skills/                     # 4 bộ kỹ năng chuyên biệt (Architecture, HAProxy, Authentik, OpenManager)
├── AGENTS.md                           # Quy tắc phát triển & đồng bộ .env.example <-> .env
├── BRD.md                              # Đặc tả yêu cầu nghiệp vụ & kỹ thuật v1.1.0
├── docs/RUNBOOK.md                     # Sổ tay triển khai, vận hành, sao lưu DR & cứu hộ khẩn cấp
├── .env.example                        # Schema biến môi trường chuẩn (Single Source of Truth)
├── docker-compose.yml                  # Stack Data Plane HAProxy chạy trên mọi node
├── docker-compose.hub.yml              # Stack Control Plane cho Hub & Local 1-Server
├── docker-compose.mock-app.yml         # Ứng dụng mẫu Service A kiểm thử Inbound/Outbound/Egress
├── host-setup/                         # Cấu hình sysctl, dummy0, daemon.json, systemd wrapper & CLI shim
├── haproxy/                            # Mẫu haproxy.cfg.tpl & bộ định tuyến nội bộ openmanager-router.cfg
├── authentik/blueprints/               # Blueprint YAML tự động tạo Group, Proxy Provider, App & Outpost
├── scripts/                            # Công cụ check_env_sync, render_configs, cài đặt agent, DR & reload
└── tests/                              # Bộ kiểm thử Offline & kịch bản 7 cổng PoC/UAT thực chiến
```

---

## Kiểm tra Nhanh & Khởi tạo Cấu hình

```bash
# 1. Đồng bộ .env từ .env.example (tự đặt quyền 0600, thêm khóa mới & thu hồi khóa cũ)
python scripts/check_env_sync.py --sync

# 2. Kiểm tra tính toàn vẹn biến môi trường & sinh toàn bộ file cấu hình theo DEPLOY_MODE
python scripts/render_configs.py

# 3. Chạy bộ kiểm thử tự động Offline
python tests/test_project_integrity.py
```

Hướng dẫn triển khai chi tiết từng bước xem tại: **[docs/RUNBOOK.md](./docs/RUNBOOK.md)** và **[BRD.md](./BRD.md)**.
