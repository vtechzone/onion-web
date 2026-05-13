#!/bin/bash
# =============================================================================
#  setup-onion-service.sh
#  Tự động thiết lập Tor Hidden Service (v3) với Nginx qua Unix Socket
#  Yêu cầu: Ubuntu/Debian, chạy với quyền root
# =============================================================================

set -euo pipefail

# ─── Màu sắc terminal ────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ─── Hằng số cấu hình ────────────────────────────────────────────────────────
WEB_DIR="/var/www/myonionsite"
NGINX_CONF="/etc/nginx/sites-available/myonionsite"
NGINX_SOCKET="/run/nginx-onion.sock"
TORRC_FILE="/etc/tor/torrc"
ONION_DIR="/var/lib/tor/myonionservice"
HOSTNAME_FILE="${ONION_DIR}/hostname"

# ─── Hàm tiện ích ────────────────────────────────────────────────────────────
log_step() { echo -e "\n${CYAN}${BOLD}[BƯỚC $1/6]${NC} $2"; }
log_ok()   { echo -e "  ${GREEN}✔${NC} $1"; }
log_warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }
log_err()  { echo -e "  ${RED}✘${NC} $1" >&2; }

die() {
    log_err "$1"
    exit 1
}

# ─── Kiểm tra quyền root ─────────────────────────────────────────────────────
[[ "$EUID" -ne 0 ]] && die "Vui lòng chạy script với quyền root: sudo $0"

# ─── Banner ──────────────────────────────────────────────────────────────────
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║      TỰ ĐỘNG THIẾT LẬP TOR ONION SERVICE (NGINX)    ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ─── Bước 1: Cài đặt các gói phụ thuộc ──────────────────────────────────────
log_step 1 "Cập nhật hệ thống và cài đặt các gói cần thiết..."

apt-get update -y -qq
apt-get install -y -qq tor nginx curl
log_ok "Đã cài đặt: tor, nginx, curl"

systemctl enable --now tor nginx
log_ok "Đã bật dịch vụ tor và nginx"

# ─── Bước 2: Tạo thư mục và trang web mẫu ───────────────────────────────────
log_step 2 "Tạo thư mục trang web và file index.html..."

mkdir -p "$WEB_DIR"

cat > "${WEB_DIR}/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="vi">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Onion Site</title>
    <style>
        body { font-family: monospace; background: #0d0d0d; color: #00ff88; 
               display: flex; justify-content: center; align-items: center; 
               height: 100vh; margin: 0; }
        .box { text-align: center; border: 1px solid #00ff88; padding: 2rem; }
        h1   { font-size: 2rem; margin-bottom: 0.5rem; }
        p    { color: #aaa; }
    </style>
</head>
<body>
    <div class="box">
        <h1>🧅 Onion Service</h1>
        <p>Chào mừng! Trang web của bạn đang chạy trên mạng Tor.</p>
    </div>
</body>
</html>
HTML

chown -R www-data:www-data "$WEB_DIR"
chmod -R 755 "$WEB_DIR"
log_ok "Đã tạo trang web tại $WEB_DIR"

# ─── Bước 3: Cấu hình Nginx ──────────────────────────────────────────────────
log_step 3 "Cấu hình Nginx lắng nghe trên Unix Domain Socket..."

cat > "$NGINX_CONF" <<NGINX
server {
    listen unix:${NGINX_SOCKET};

    server_name _;

    root ${WEB_DIR};
    index index.html;

    # Bảo mật: ẩn phiên bản Nginx
    server_tokens off;

    # Xóa các header tiết lộ thông tin hệ thống
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # Chặn truy cập file ẩn (ví dụ: .htaccess, .git)
    location ~ /\. {
        deny all;
    }
}
NGINX

# Kích hoạt site, xóa liên kết cũ nếu có
ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/myonionsite"
log_ok "Đã tạo cấu hình Nginx tại $NGINX_CONF"

# ─── Bước 4: Kiểm tra và khởi động lại Nginx ─────────────────────────────────
log_step 4 "Kiểm tra cấu hình và khởi động lại Nginx..."

nginx -t 2>/dev/null || die "Cấu hình Nginx không hợp lệ. Kiểm tra: nginx -t"
systemctl restart nginx
log_ok "Nginx đã khởi động thành công"

# Cấp quyền socket cho Tor sau khi Nginx tạo socket
sleep 2
if [[ -S "$NGINX_SOCKET" ]]; then
    chmod 666 "$NGINX_SOCKET"
    log_ok "Đã cấp quyền socket: $NGINX_SOCKET"
else
    log_warn "Không tìm thấy socket $NGINX_SOCKET — Tor sẽ tự kết nối sau khi Nginx tạo"
fi

# ─── Xác định user Tor theo distro ───────────────────────────────────────────
if id "debian-tor" &>/dev/null; then
    TOR_USER="debian-tor"
elif id "tor" &>/dev/null; then
    TOR_USER="tor"
else
    die "Không tìm thấy user Tor (debian-tor hoặc tor). Kiểm tra cài đặt Tor."
fi
log_ok "User Tor: ${TOR_USER}"

# ─── Bước 5: Cấu hình Tor ────────────────────────────────────────────────────
log_step 5 "Cấu hình Tor Hidden Service..."

mkdir -p "$ONION_DIR"
chown -R "${TOR_USER}:${TOR_USER}" "$ONION_DIR"
chmod 700 "$ONION_DIR"

# Chỉ thêm cấu hình nếu chưa tồn tại
if grep -q "HiddenServiceDir ${ONION_DIR}" "$TORRC_FILE" 2>/dev/null; then
    log_warn "Cấu hình Tor cho ${ONION_DIR} đã tồn tại — bỏ qua ghi đè"
else
    cat >> "$TORRC_FILE" <<TOR

# ── myonionservice ────────────────────────────────
HiddenServiceDir ${ONION_DIR}
HiddenServicePort 80 unix:${NGINX_SOCKET}
TOR
    log_ok "Đã thêm cấu hình vào ${TORRC_FILE}"
fi

# ─── Bước 6: Khởi động lại Tor và lấy địa chỉ .onion ────────────────────────
log_step 6 "Khởi động lại Tor và lấy địa chỉ .onion..."

systemctl restart tor

echo -n "  Đang chờ Tor khởi tạo địa chỉ .onion"
for i in {1..15}; do
    [[ -f "$HOSTNAME_FILE" ]] && break
    echo -n "."
    sleep 1
done
echo ""

if [[ ! -f "$HOSTNAME_FILE" ]]; then
    log_warn "Chưa tìm thấy file hostname sau 15 giây."
    log_warn "Kiểm tra log: journalctl -u tor -f"
    exit 1
fi

ONION_ADDRESS=$(cat "$HOSTNAME_FILE")

# ─── Kết quả ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║            THIẾT LẬP HOÀN TẤT THÀNH CÔNG! ✔         ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  📁 Thư mục trang web  : ${CYAN}${WEB_DIR}${NC}"
echo -e "  🔌 Unix Socket Nginx  : ${CYAN}${NGINX_SOCKET}${NC}"
echo -e "  🗂  Thư mục Tor        : ${CYAN}${ONION_DIR}${NC}"
echo ""
echo -e "  🧅 ${BOLD}Địa chỉ .onion của bạn:${NC}"
echo -e "     ${GREEN}${BOLD}${ONION_ADDRESS}${NC}"
echo ""
echo -e "  ℹ️  Mở bằng ${BOLD}Tor Browser${NC} — cần vài phút để địa chỉ lan truyền"
echo ""
