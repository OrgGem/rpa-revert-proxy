# Quy tắc Phát triển & Vận hành Dự án `rpa-revert-proxy`

Tài liệu này quy định các ràng buộc kiến trúc và quy trình bắt buộc cho mọi tác vụ phát triển, cấu hình và kiểm thử trong kho mã nguồn.

## 1. Kích hoạt Kỹ năng Chuyên biệt (Mandatory Domain Skills)

Trước khi thiết kế hoặc chỉnh sửa bất kỳ thành phần nào bên dưới, bắt buộc đọc và tuân thủ `SKILL.md` tương ứng trong `.agents/skills/`:
- **Hạ tầng OS, `ip_forward=0` (IPv4/IPv6), `dummy0`, `daemon.json`, Egress Firewall & Mô hình 1-Server vs Hub/Satellite**: `.agents/skills/zero-ip-forward-architecture/SKILL.md`
- **Cấu hình HAProxy Inbound (HTTP/2) + Outbound (SNI Passthrough), TLS `0600`, DNS Resolvers, Prometheus Metrics & Graceful Drain**: `.agents/skills/haproxy-inbound-outbound/SKILL.md`
- **Cấu hình Authentik Main (`server` + `worker`), Authentik Proxy Outpost & Blueprints SSO**: `.agents/skills/authentik-proxy-sso/SKILL.md`
- **Quản trị Tập trung `haproxy-openmanager` (Zero-Nginx Hub) & `haproxy-agent` Pull Daemon khóa bất biến (`chattr +i`)**: `.agents/skills/openmanager-agent-control/SKILL.md`

---

## 2. Quy tắc Đồng bộ Biến Môi trường (`.env.example` ↔ `.env`) Theo Luồng Phát triển & Kiểm thử

`.env.example` là **Nguồn Sự thật Duy nhất về Cấu trúc Biến (Schema Single Source of Truth)** của toàn dự án. Mọi thay đổi liên quan đến biến môi trường phải tuân thủ nghiêm ngặt 5 quy tắc sau:

### Quy tắc 2.1 — Đồng bộ Nguyên tử ngay khi Phát triển (Atomic Sync on Edit)
- Bất kỳ khi nào thêm mới, đổi tên, thay đổi giá trị mặc định hoặc xóa một biến `${VAR}` trong `docker-compose*.yml`, `haproxy/*.tpl`, `host-setup/*`, `authentik/blueprints/*`, `mock-app/*`, hoặc `scripts/*`:
  1. **Cập nhật `.env.example` trước tiên** (đúng phân nhóm, kèm chú thích rõ ràng).
  2. **Đồng bộ sang `.env`** bằng `python scripts/check_env_sync.py --sync` (bổ sung biến mới, thu hồi biến đã xóa khỏi schema, **không ghi đè** các giá trị secret/IP cục bộ đang cấu hình trong `.env`, và luôn đảm bảo quyền file `0600` trên hệ thống POSIX).
  3. Không được kết thúc bước code hoặc chuyển sang bước chạy test nếu `.env.example`, `.env` và tên biến trong `.agents/skills/` đang lệch nhau (key drift).

### Quy tắc 2.2 — Chuẩn Đặt tên & Phân nhóm Biến (Naming & Scoping Convention)
Mọi biến môi trường phải mang tiền tố theo đúng phân hệ và ghi rõ phạm vi áp dụng trong comment (`[ALL]`, `[HUB_OR_LOCAL]`, `[SATELLITE_OR_LOCAL]`, `[LOCAL_ONLY]`):
- `DEPLOY_MODE`, `NODE_*`, `TZ`: Chế độ triển khai (`local-all-in-one` | `prod-hub` | `prod-satellite`) và định danh máy chủ.
- `HOST_*`, `DUMMY_*`, `MGMT_*`: Cấu hình mạng Host, interface `dummy0` (`10.254.254.1`) và dải mạng quản trị nội bộ.
- `HAPROXY_*`, `OUTBOUND_*`: Tham số tiến trình HAProxy, Prometheus metrics port, buffer, timeout và danh sách domain đối tác cho phép.
- `AUTHENTIK_*`: Thông số kết nối Authentik Main & Proxy Outpost (`AUTHENTIK_TAG` bắt buộc ghim cứng dạng `YYYY.M.P`, ánh xạ `AUTHENTIK_OUTPOST_TOKEN` sang biến `AUTHENTIK_TOKEN` của container Outpost).
- `OPENMANAGER_*`: Thông số Central `haproxy-openmanager` Hub (`OPENMANAGER_TAG` ghim cứng, loại bỏ Nginx) và `haproxy-agent` Pull Daemon trên các Server vệ tinh.
- `APP_*`: Thông số ứng dụng nghiệp vụ / `mock-app` kiểm thử.
- `LOCAL_IDP_*`: Dành cho cụm `Authentik Main` chạy trên 01 máy chủ ở chế độ `local-all-in-one` (hoặc khởi tạo trên `prod-hub`).

### Quy tắc 2.3 — Cấm Lưu trữ Secret Thật trong `.env.example` (Zero-Secret Policy)
- Trong `.env.example`: Mọi khóa bí mật, mật khẩu, token bắt buộc đặt giá trị giữ chỗ tường minh theo mẫu `CHANGE_ME_<TEN_BIEN>`.
- Trong `.env`: Khởi tạo sẵn các giá trị phát triển cục bộ có tiền tố `dev_only_...` cho chế độ `local-all-in-one`; khi chuyển sang `prod-hub` hoặc `prod-satellite` bắt buộc thay toàn bộ bằng khóa ngẫu nhiên an toàn (`openssl rand -base64 48`) và khóa quyền file `chmod 0600 .env`.

### Quy tắc 2.4 — Cổng Kiểm tra Tự động theo Luồng Dev → Test → UAT (Validation Gate)
Trước khi khởi chạy container, sinh file cấu hình, chạy kiểm thử hoặc bàn giao thay đổi, **bắt buộc** thực thi:
```bash
python scripts/check_env_sync.py
```
Lệnh kiểm tra phải trả về `EXIT CODE 0` (xác nhận không có biến mồ côi trên toàn bộ Compose/Template/Blueprint/Script/Mock-App, không lệch khóa giữa `.env.example` và `.env`, quyền file `.env` an toàn, không rò rỉ secret vào `.env.example`, và không dùng tag `latest`).

### Quy tắc 2.5 — Bảo vệ File Nhạy cảm trong Git
- Tuyệt đối không xóa hoặc nới lỏng các rule chặn `.env`, `.env.*` (trừ `.env.example`), `*.pem`, `*.key`, `id_ed25519*` trong `.gitignore`.
