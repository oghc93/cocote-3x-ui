#!/bin/bash
# ============================================================
#  INSTALL OTOMATIS - VPN Panel (Chanelog Tunnel)
#  Mencakup: clone repo, setup PHP/backend, sisip config nginx,
#  fix haproxy multiplex (kalau aktif), enable nginx.
#  Aman dijalankan di server fresh install script VPN02/xray.
# ============================================================
set -e

REPO_URL="https://github.com/oghc93/xray.git"
CLONE_DIR="/opt/xray-panel"
NGINX_CONF="/etc/nginx/conf.d/xray.conf"

echo "=== [1/7] Clone repo & install paket ==="
rm -rf "$CLONE_DIR"
git clone "$REPO_URL" "$CLONE_DIR"
cd "$CLONE_DIR"
apt update -qq
apt install -y php-fpm php-cli jq >/dev/null

echo "=== [2/7] Pasang file backend & panel ==="
mkdir -p /etc/vpn-script/api /var/www/vpn-api /var/www/vpn-panel
cp api/api-cli.sh /etc/vpn-script/api/api-cli.sh
chmod 750 /etc/vpn-script/api/api-cli.sh
chown root:root /etc/vpn-script/api/api-cli.sh
cp api/index.php /var/www/vpn-api/index.php
touch /var/log/vpn-panel-bridge-errors.log
chown www-data:www-data /var/log/vpn-panel-bridge-errors.log
cp panel/index.html /var/www/vpn-panel/index.html

echo "=== [3/7] Batasi akses sudo & generate API key ==="
cp deploy/sudoers-vpnapi /etc/sudoers.d/vpnapi
chmod 440 /etc/sudoers.d/vpnapi
visudo -c

PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
PHP_SOCK=$(ls /run/php/php*-fpm.sock 2>/dev/null | head -1)
API_KEY=$(openssl rand -hex 32)
POOL="/etc/php/$PHP_VER/fpm/pool.d/www.conf"
[[ -f "$POOL" ]] || { echo "ERROR: $POOL tidak ada"; exit 1; }
sed -i '/^env\[VPN_API_KEY\]/d' "$POOL"
echo "env[VPN_API_KEY] = \"$API_KEY\"" >> "$POOL"
mkdir -p /etc/vpn-script
echo "$API_KEY" > /etc/vpn-script/api-key.txt
chmod 600 /etc/vpn-script/api-key.txt
systemctl restart "php$PHP_VER-fpm"

echo "=== [4/7] Sisip config nginx (/api/ dan /panel/) ==="
if grep -q "root /var/www/html;" "$NGINX_CONF" 2>/dev/null; then
  cp "$NGINX_CONF" "$NGINX_CONF.bak.$(date +%Y%m%d%H%M%S)"
  ANCHOR_LINE=$(grep -n "root /var/www/html;" "$NGINX_CONF" | head -1 | cut -d: -f1)
  INSERT_AT=$((ANCHOR_LINE - 1))
  awk -v ln="$INSERT_AT" -v sock="$PHP_SOCK" '
    NR==ln {
      print "    # --- VPN PANEL API ---"
      print "    location /api/ {"
      print "        fastcgi_pass unix:" sock ";"
      print "        fastcgi_param SCRIPT_FILENAME /var/www/vpn-api/index.php;"
      print "        fastcgi_param QUERY_STRING $query_string;"
      print "        fastcgi_param REQUEST_METHOD $request_method;"
      print "        fastcgi_param CONTENT_TYPE $content_type;"
      print "        fastcgi_param CONTENT_LENGTH $content_length;"
      print "        fastcgi_param REQUEST_URI $request_uri;"
      print "        fastcgi_param HTTP_X_API_KEY $http_x_api_key;"
      print "        fastcgi_param SERVER_SOFTWARE nginx;"
      print "        fastcgi_param SERVER_PROTOCOL $server_protocol;"
      print "        fastcgi_index index.php;"
      print "    }"
      print ""
      print "    # --- VPN PANEL UI ---"
      print "    location /panel/ {"
      print "        alias /var/www/vpn-panel/;"
      print "        index index.html;"
      print "        try_files $uri $uri/ /panel/index.html;"
      print "    }"
      print ""
    }
    { print }
  ' "$NGINX_CONF" > /tmp/xray.conf.new
  cat /tmp/xray.conf.new > "$NGINX_CONF"
  nginx -t
else
  echo "PERINGATAN: pola 'root /var/www/html;' tidak ketemu di $NGINX_CONF"
  echo "Sisip config nginx manual sesuai deploy/DEPLOY.md bagian 1-2."
fi

echo "=== [5/7] Fix haproxy multiplex (kalau aktif) ==="
if [[ -f /etc/vpn-script/.multiplex-443-active ]] && [[ -f /etc/haproxy/haproxy.cfg ]]; then
  if ! grep -q "looks_like_post" /etc/haproxy/haproxy.cfg; then
    cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bak.$(date +%Y%m%d%H%M%S)
    awk '
      /^  acl looks_like_http / {
        print "  acl looks_like_get     req.payload(0,4) -m str \"GET \""
        print "  acl looks_like_post    req.payload(0,5) -m str \"POST \""
        print "  acl looks_like_put     req.payload(0,4) -m str \"PUT \""
        print "  acl looks_like_delete  req.payload(0,7) -m str \"DELETE \""
        print "  acl looks_like_head    req.payload(0,5) -m str \"HEAD \""
        print "  acl looks_like_options req.payload(0,8) -m str \"OPTIONS \""
        print "  acl looks_like_patch   req.payload(0,6) -m str \"PATCH \""
        next
      }
      /^  use_backend multiplex_xray if looks_like_http or looks_like_h2$/ {
        print "  use_backend multiplex_xray if looks_like_get or looks_like_post or looks_like_put or looks_like_delete or looks_like_head or looks_like_options or looks_like_patch or looks_like_h2"
        next
      }
      { print }
    ' /etc/haproxy/haproxy.cfg > /tmp/haproxy.cfg.new
    cat /tmp/haproxy.cfg.new > /etc/haproxy/haproxy.cfg
    haproxy -c -f /etc/haproxy/haproxy.cfg
    systemctl reload haproxy
    echo "haproxy.cfg diperbaiki (method selain GET sekarang dikenali)."
  else
    echo "haproxy.cfg sudah benar, tidak perlu diubah."
  fi
else
  echo "Multiplex tidak aktif / haproxy tidak dipakai - lewati."
fi

echo "=== [6/7] Reload nginx & enable auto-start ==="
systemctl reload nginx
systemctl enable nginx >/dev/null 2>&1

echo "=== [7/7] Selesai ==="
DOMAIN=$(grep -oP 'server_name \K[^;]+' "$NGINX_CONF" 2>/dev/null | head -1)
echo ""
echo "================================================================"
echo " INSTALASI SELESAI"
echo " Panel   : https://${DOMAIN:-<domain-mu>}/panel/"
echo " API key : $API_KEY"
echo " (tersimpan di /etc/vpn-script/api-key.txt)"
echo " (simpan API key ini - dibutuhkan saat 'Hubungkan ke server')"
echo "================================================================"
