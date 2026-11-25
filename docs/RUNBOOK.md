# Sổ tay Triển khai, Vận hành & Cứu hộ (`RUNBOOK.md` — v1.1.0)

Tài liệu hướng dẫn từng bước triển khai và vận hành kiến trúc **HAProxy Zero-IP-Forward + Authentik SSO + HAProxy OpenManager (Pull-Agent)** cho cả **Môi trường Kiểm thử 01 Server (`local-all-in-one`)** và **Môi trường Sản xuất Đa Server (`prod-hub` + `prod-satellite`)**.

---

## 1. Triển khai Kiểm thử Trọn Bộ Trên 01 Server Linux (`local-all-in-one`)

Chế độ này cài đặt đồng thời cả **Central Hub** (`Authentik Main` + `Authentik Proxy` + `HAProxy OpenManager` không dùng Nginx) và **Satellite Data Plane** (`HAProxy` + `haproxy-agent` + `mock-app`) ngay trên 01 máy chủ Linux với `net.ipv4.ip_forward = 0`.

### Bước 1.1 — Chuẩn bị `.env` & Sinh Cấu hình
```bash
git clone https://github.com/OrgGem/rpa-revert-proxy.git
cd rpa-revert-proxy

# Đồng bộ .env từ .env.example (tự động đặt quyền 0600 trên Linux)
python3 scripts/check_env_sync.py --sync
```
Chỉnh sửa `.env`: cập nhật `HOST_LAN_INTERFACE`, `HOST_LAN_IP`, `AUTHENTIK_MAIN_BACKEND_IP` và `OPENMANAGER_HUB_BACKEND_IP` trùng với địa chỉ IPv4 LAN của máy chủ Linux. Sau đó sinh toàn bộ cấu hình:
```bash
python3 scripts/render_configs.py
```

### Bước 1.2 — Chuẩn hóa Tầng OS, Firewall & Tạo Chứng chỉ TLS Local
```bash
# Thiết lập IPv4/IPv6 ip_forward=0, dummy0 (10.254.254.1), daemon.json & Egress Firewall
sudo bash host-setup/bootstrap-host.sh

# Tạo Local Root CA & chứng chỉ Multi-SAN (0600 root:root) trong /etc/ssl/haproxy/
sudo bash scripts/generate-local-certs.sh
```
*(Trên máy trạm quản trị, trỏ file `hosts` cho `auth.local.test`, `portal.local.test`, `app.local.test` về `<HOST_LAN_IP>`).*

### Bước 1.3 — Khởi chạy Stack Hub + Data Plane & Lấy Token Tự động
```bash
# 1. Khởi chạy HAProxy Data Plane + Hub Control Plane + Mock Service A
sudo docker compose -f docker-compose.yml -f docker-compose.hub.yml -f docker-compose.mock-app.yml up -d

# 2. Chờ ~30-45s để Authentik khởi tạo DB & nạp Blueprint, sau đó tự động lấy Outpost Token:
sudo bash scripts/fetch-outpost-token.sh
```

### Bước 1.4 — Đăng ký `haproxy-agent` Trên OpenManager & Kích hoạt Pull Agent
1. Truy cập `https://auth.local.test`, đăng nhập bằng `admin@local.test` (mật khẩu `LOCAL_IDP_BOOTSTRAP_PASSWORD` trong `.env`) và thêm tài khoản vào Group **`infra-admins`**.
2. Truy cập `https://portal.local.test` (tự động xác thực SSO qua Authentik) → đăng nhập giao diện quản trị OpenManager:
   * Tạo **Pool** (`ID = 1`) và **Cluster** (`ID = 1`) trong OpenManager.
   * Vào **Security → Agent Tokens**, tạo API Token mới cho node, điền giá trị vào biến `OPENMANAGER_AGENT_TOKEN` trong `.env`.
   * Dùng tính năng **Bulk Import** trên OpenManager để nạp các Frontend/Backend hiện có từ `/etc/haproxy/haproxy.cfg` lên cơ sở dữ liệu quản lý tập trung.
3. Cài đặt và khóa bất biến (`chattr +i`) `haproxy-agent` ngay trên máy chủ:
   ```bash
   sudo bash scripts/install-openmanager-agent.sh
   ```
4. Chạy bộ kiểm thử nghiệm thu **7 cổng kỹ thuật**:
   ```bash
   sudo bash tests/verify-acceptance.sh
   ```

---

## 2. Triển khai Sản xuất Đa Server (`prod-hub` + `N prod-satellite`)

### 2.1. Trên Server Chính (`DEPLOY_MODE=prod-hub`)
1. Đặt `DEPLOY_MODE=prod-hub`, `AUTHENTIK_INSECURE=false`, cấu hình tên miền thật (`auth.main-domain.com`, `portal.main-domain.com`) và thay toàn bộ các khóa `CHANGE_ME_*` / `dev_only_*` bằng khóa ngẫu nhiên an toàn (`openssl rand -base64 48`).
2. Đặt chứng chỉ SSL thật vào `/etc/ssl/haproxy/` (`chmod 0600`, `chown root:root`).
3. Thực thi:
   ```bash
   python3 scripts/check_env_sync.py
   python3 scripts/render_configs.py
   sudo bash host-setup/bootstrap-host.sh
   sudo cp haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg
   sudo docker compose -f docker-compose.yml -f docker-compose.hub.yml up -d
   sudo bash scripts/fetch-outpost-token.sh
   ```

### 2.2. Trên Từng Server Vệ tinh (`DEPLOY_MODE=prod-satellite`)
Trên Server vệ tinh **không cài đặt Authentik hay OpenManager UI** — chỉ chạy `HAProxy` và `haproxy-agent` siêu nhẹ gọi HTTPS Pull về Server Chính:
1. Trên giao diện OpenManager (`https://portal.main-domain.com`), tạo Cluster tương ứng cho Server vệ tinh (ghi nhận `OPENMANAGER_POOL_ID`, `OPENMANAGER_CLUSTER_ID`) và cấp riêng 1 `OPENMANAGER_AGENT_TOKEN`.
2. Trên Server vệ tinh, cấu hình `.env`:
   * `DEPLOY_MODE=prod-satellite`
   * `NODE_ID=sat-node1`
   * `HOST_LAN_IP=<IP_LAN_SERVER_VE_TINH>`
   * `OPENMANAGER_PUBLIC_DOMAIN=portal.main-domain.com`
   * `OPENMANAGER_HUB_BACKEND_IP=<IP_LAN_HOAC_WAN_SERVER_HUB>`
   * `OPENMANAGER_AGENT_TOKEN=<TOKEN_CUA_NODE_NAY>`
   * `AUTHENTIK_INSECURE=false`
3. Thực thi tuần tự:
   ```bash
   python3 scripts/check_env_sync.py
   python3 scripts/render_configs.py
   sudo bash host-setup/bootstrap-host.sh
   sudo cp haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg
   sudo docker compose up -d
   sudo bash scripts/install-openmanager-agent.sh
   sudo bash tests/verify-acceptance.sh
   ```

---

## 3. Quy trình Vận hành, Sao lưu DR & Cứu hộ Khẩn cấp

### 3.1. Cập nhật Cấu hình Proxy & Mở Whitelist Outbound Từ Xa
* Mọi thay đổi Frontend Inbound, Backend ứng dụng, chứng chỉ SSL hoặc thêm Backend SNI Passthrough mới đều thực hiện tập trung trên `https://portal.main-domain.com` → kiểm tra Diff ở màn hình **Apply Management** → bấm **Apply Changes**.
* Trong vòng `30 giây`, `haproxy-agent` trên Server vệ tinh mục tiêu sẽ tự động kéo bản cập nhật qua HTTPS, giữ nguyên `global` + `resolvers host_dns` + `defaults` + `listen prometheus_exporter`, kiểm tra cú pháp `haproxy -c` và phát tín hiệu `SIGUSR2` graceful reload.

### 3.2. Sao lưu & Phục hồi Thảm họa (`RPO <= 24h`, `RTO <= 30m`)
```bash
# Sao lưu toàn bộ DB Authentik + DB OpenManager + cấu hình HAProxy & chứng chỉ SSL
sudo bash scripts/backup-restore.sh backup

# Khôi phục từ bản sao lưu khi xảy ra sự cố
sudo bash scripts/backup-restore.sh restore backups/rpa-dr-backup-<node>-<timestamp>.tar.gz
```

### 3.3. Cứu hộ Cục bộ (`Break-Glass`) & Mở khóa Bảo trì Agent
* **Khôi phục cấu hình HAProxy ngay trên Server vệ tinh khi đứt kết nối về Hub:**
  ```bash
  sudo /usr/local/bin/haproxy-ctl status
  sudo /usr/local/bin/haproxy-ctl rollback
  ```
* **Nâng cấp phiên bản `haproxy-agent` có kiểm soát (do file đang khóa `chattr +i`):**
  ```bash
  sudo chattr -i /usr/local/bin/haproxy-agent
  sudo bash scripts/install-openmanager-agent.sh
  ```
