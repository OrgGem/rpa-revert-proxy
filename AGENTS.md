# Quy tắc Phát triển & Vận hành Dự án `rpa-prory`

Tài liệu này quy định các ràng buộc kiến trúc và quy trình bắt buộc cho mọi tác vụ phát triển, cấu hình và kiểm thử trong kho mã nguồn `rpa-prory`.

## 1. Kích hoạt Kỹ năng Chuyên biệt (Mandatory Domain Skills)

Trước khi thiết kế hoặc chỉnh sửa bất kỳ thành phần nào bên dưới, bắt buộc đọc và tuân thủ `SKILL.md` tương ứng trong `.agents/skills/`:
- **Hạ tầng OS, `ip_forward=0`, `dummy0`, `daemon.json`, Firewall & Mô hình 1-Server vs Đa Server**: `.agents/skills/zero-ip-forward-architecture/SKILL.md`
- **Cấu hình HAProxy Inbound (HTTP/2) + Outbound (SNI Passthrough), TLS, DNS Resolvers & Reload**: `.agents/skills/haproxy-inbound-outbound/SKILL.md`
- **Cấu hình Authentik Main (Local Lab), Authentik Proxy Outpost & Blueprints SSO**: `.agents/skills/authentik-proxy-sso/SKILL.md`
- **Cô lập Roxy-WI, Persistent Volumes, phân quyền `/etc/haproxy` & SSH `roxyadmin`**: `.agents/skills/roxy-wi-operations/SKILL.md`

---

## 2. Quy tắc Đồng bộ Biến Môi trường (`.env.example` ↔ `.env`) Theo Luồng Phát triển & Kiểm thử

`.env.example` là **Nguồn Sự thật Duy nhất về Cấu trúc Biến (Schema Single Source of Truth)** của toàn dự án. Mọi thay đổi liên quan đến biến môi trường phải tuân thủ nghiêm ngặt 5 quy tắc sau:

### Quy tắc 2.1 — Đồng bộ Nguyên tử ngay khi Phát triển (Atomic Sync on Edit)
- Bất kỳ khi nào thêm mới, đổi tên, thay đổi giá trị mặc định hoặc xóa một biến `${VAR}` trong `docker-compose*.yml`, `haproxy/*.tpl`, `host-setup/*`, `authentik/blueprints/*`, `mock-app/*`, hoặc `scripts/*`:
  1. **Cập nhật `.env.example` trước tiên** (đúng phân nhóm, kèm chú thích rõ ràng).
  2. **Đồng bộ sang `.env`** (bổ sung biến mới hoặc loại bỏ biến thừa, **không ghi đè** các giá trị secret/IP cục bộ đã cấu hình trong `.env`).
  3. Không được kết thúc bước code hoặc chuyển sang bước chạy test nếu `.env.example` và `.env` đang lệch danh sách khóa (key drift).

### Quy tắc 2.2 — Chuẩn Đặt tên & Phân nhóm Biến (Naming & Scoping Convention)
Mọi biến môi trường phải mang tiền tố theo đúng phân hệ và ghi rõ phạm vi áp dụng trong comment (`[ALL]`, `[LOCAL_ONLY]`, hoặc `[PROD_SATELLITE]`):
- `DEPLOY_MODE`, `NODE_*`, `TZ`: Chế độ triển khai (`local-all-in-one` | `prod-satellite` | `prod-hub`) và định danh máy chủ.
- `HOST_*`, `DUMMY_*`, `MGMT_*`: Cấu hình mạng Host, interface `dummy0` (`10.254.254.1`) và dải mạng quản trị nội bộ.
- `HAPROXY_*`, `OUTBOUND_*`: Tham số tiến trình HAProxy, buffer, timeout và danh sách domain đối tác cho phép.
- `AUTHENTIK_*`: Thông số kết nối Authentik Main & Proxy Outpost (phiên bản `AUTHENTIK_TAG` bắt buộc ghim cứng dạng `YYYY.M.P`, cấm dùng `latest`).
- `ROXYWI_*`: Thông số container Roxy-WI, domain quản trị và tài khoản SSH đặc quyền tối thiểu.
- `APP_*`: Thông số ứng dụng nghiệp vụ / `mock-app` kiểm thử.
- `LOCAL_IDP_*`: Chỉ dành cho cụm `Authentik Main` chạy giả lập trên 01 máy chủ ở chế độ `local-all-in-one`.

### Quy tắc 2.3 — Cấm Lưu trữ Secret Thật trong `.env.example` (Zero-Secret Policy)
- Trong `.env.example`:
  - Mọi khóa bí mật, mật khẩu, token bắt buộc đặt giá trị giữ chỗ tường minh theo mẫu `CHANGE_ME_<TEN_BIEN>`.
  - Các địa chỉ IP/tên miền dùng dải mạng mẫu an toàn (`192.168.56.10`, `10.254.254.1`, `*.local.test`).
- Trong `.env` (phục vụ chạy thử local, bị chặn commit bởi `.gitignore`):
  - Khởi tạo sẵn các giá trị phát triển cục bộ có tiền tố `dev_only_...` để phân biệt rõ với môi trường Production; khi lên Production bắt buộc thay toàn bộ các giá trị `CHANGE_ME_*` và `dev_only_*` bằng khóa sinh ngẫu nhiên an toàn (`openssl rand -base64 48`).

### Quy tắc 2.4 — Cổng Kiểm tra Tự động theo Luồng Dev → Test → UAT (Validation Gate)
Trước khi khởi chạy container (`docker compose up`), chạy script kiểm thử nghiệm thu, hoặc bàn giao thay đổi, **bắt buộc** thực thi công cụ kiểm tra đồng bộ:
```bash
python scripts/check_env_sync.py
```
*(Hoặc chạy `python scripts/check_env_sync.py --sync` khi cần tự động chèn các biến mới từ `.env.example` vào `.env` hiện có).*

Lệnh kiểm tra phải trả về `EXIT CODE 0` (xác nhận đủ 4 điều kiện: không có biến `${VAR}` mồ côi trong template/compose, không lệch danh sách biến giữa `.env.example` và `.env`, không rò rỉ secret vào `.env.example`, và không vi phạm các ràng buộc an toàn như `AUTHENTIK_TAG=latest`).

### Quy tắc 2.5 — Bảo vệ File Nhạy cảm trong Git
- Tuyệt đối không xóa hoặc nới lỏng các rule chặn `.env`, `.env.*` (trừ `.env.example`), `*.pem`, `*.key`, `id_ed25519*` trong `.gitignore`.
