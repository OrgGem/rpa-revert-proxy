# RPA Revert Proxy — HAProxy (Zero-IP-Forward) & Authentik SSO + Roxy-WI

Giải pháp triển khai **HAProxy Inbound (HTTPS / HTTP/2) & Outbound (TCP SNI Passthrough)** tuân thủ nghiêm ngặt ràng buộc bảo mật hệ điều hành `net.ipv4.ip_forward = 0` và cấm mở SSH liên server, kết hợp **Authentik Standalone Proxy Outpost** bọc xác thực SSO (OIDC) phía trước **Roxy-WI Community Edition**.

---

## Điểm nhấn Kiến trúc

* **Tuân thủ tuyệt đối `net.ipv4.ip_forward = 0`:** Toàn bộ lưu lượng chuyển đổi thành giao tiếp cục bộ trên Host (`INPUT`/`OUTPUT` chain) thông qua HAProxy (`network_mode: host`), `docker-proxy` trên `127.0.0.1` (Inbound) và interface ảo cố định `dummy0` `10.254.254.1/32` (Outbound).
* **Tương thích 100% ứng dụng hiện hữu:** Không cần sửa mã nguồn ứng dụng, không cần cài Root CA nội bộ vào container; giữ nguyên hiệu lực chứng chỉ SSL gốc (hỗ trợ cả mTLS) ở chiều Outbound nhờ cơ chế `SNI Passthrough` kèm Whitelist tên miền.
* **Bảo vệ Portal Quản trị Pre-Auth 100%:** Cô lập hoàn toàn `roxy-wi` trong mạng nội bộ `mgmt_internal` (không mở port ra Host/LAN), bắt buộc xác thực SSO & kiểm tra phân quyền Group/MFA qua `authentik-proxy` trước khi chạm tới Roxy-WI.
* **Quản trị an toàn không cần SSH liên server:** Mỗi node vệ tinh vận hành cặp `authentik-proxy + roxy-wi` cục bộ, kết nối SSH đặc quyền tối thiểu (`roxyadmin`, không gán group `docker`) vào chính Host chứa nó và đồng bộ cấu hình zero-downtime (`master-worker` + `USR2`).

---

## Các Chế độ Triển khai Hỗ trợ

1. **`local-all-in-one` (Môi trường Phát triển / Kiểm thử trên 01 Server):**
   * Triển khai đồng thời cả cụm `Authentik Main` (`127.0.0.1:9001`) lẫn `authentik-proxy` độc lập (`127.0.0.1:9000`), `roxy-wi`, `haproxy` và `mock-app` ngay trên 01 máy chủ.
   * Tái hiện **đúng 100%** luồng mạng `authentik-proxy` → `HAProxy Outbound SNI Passthrough` → `Authentik Main` như môi trường đa server.
2. **`prod-hub` & `prod-satellite` (Môi trường Sản xuất Đa Server):**
   * **01 Server Chính (`prod-hub`):** Vận hành `Authentik Main` tập trung.
   * **N Server Vệ tinh (`prod-satellite`):** Giữ nguyên toàn bộ cấu hình của cụm vệ tinh, chỉ trỏ biến môi trường `AUTHENTIK_HOST` / `AUTHENTIK_MAIN_BACKEND_IP` về Server Chính qua cổng `443` (HTTPS/WSS).

---

## Cấu trúc Thư mục

```text
.
├── .agents/skills/               # Bộ kỹ năng chuyên biệt (Architecture, HAProxy, Authentik, Roxy-WI)
├── AGENTS.md                     # Quy tắc dự án & quy trình đồng bộ .env.example <-> .env
├── BRD.md                        # Tài liệu đặc tả yêu cầu nghiệp vụ & kỹ thuật chi tiết
├── .env.example                  # Cấu trúc chuẩn biến môi trường (Single Source of Truth)
├── host-setup/                   # Cấu hình OS: sysctl, dummy0 (10.254.254.1), daemon.json, sudoers, firewall
├── haproxy/                      # Mẫu cấu hình haproxy.cfg.tpl và thư mục certs/
│   └── certs/                    # Lưu trữ chứng chỉ TLS (.pem bị chặn bởi .gitignore)
├── authentik/blueprints/         # Blueprint YAML khởi tạo tự động Provider, App, Group & Outpost
├── mock-app/                     # Ứng dụng mẫu (Service A) phục vụ kiểm thử Inbound HTTP/2 & Outbound SNI
├── scripts/                      # Công cụ kiểm tra biến môi trường, reload zero-downtime & cứu hộ
│   └── check_env_sync.py         # Kiểm tra đồng bộ biến & an toàn cấu hình theo luồng Dev/Test/Prod
└── tests/                        # Kịch bản kiểm thử tự động các tiêu chí nghiệm thu (UAT)
```

---

## Khởi tạo Nhanh & Kiểm tra Biến Môi trường

Yêu cầu: `Python 3.9+` (để chạy công cụ kiểm tra cấu hình), `Docker Engine` & `Docker Compose v2` trên máy chủ Linux mục tiêu.

1. **Khởi tạo hoặc đồng bộ file `.env` cục bộ từ `.env.example`** (tự động thêm biến mới mà không ghi đè các khóa/secret đã cấu hình):
   ```bash
   python scripts/check_env_sync.py --sync
   ```

2. **Kiểm tra tính hợp lệ và an toàn của biến môi trường** trước khi chạy kiểm thử hoặc triển khai:
   ```bash
   python scripts/check_env_sync.py
   ```

---

## Tài liệu Tham khảo Dự án

* **Đặc tả Yêu cầu Nghiệp vụ & Kỹ thuật (BRD):** [BRD.md](./BRD.md)
* **Quy tắc Phát triển & Đồng bộ Biến Môi trường:** [AGENTS.md](./AGENTS.md)
* **Bộ Kỹ năng Chuyên biệt (`.agents/skills/`):**
  * [zero-ip-forward-architecture](./.agents/skills/zero-ip-forward-architecture/SKILL.md)
  * [haproxy-inbound-outbound](./.agents/skills/haproxy-inbound-outbound/SKILL.md)
  * [authentik-proxy-sso](./.agents/skills/authentik-proxy-sso/SKILL.md)
  * [roxy-wi-operations](./.agents/skills/roxy-wi-operations/SKILL.md)
