#!/bin/bash
# Pulihkan blok /api/ & /panel/ di Nginx (hilang setelah config Nginx dibuat ulang) + pastikan HAProxy meneruskan POST/PUT dll.
CONF="${NGINX_CONF:-/etc/nginx/conf.d/xray.conf}"
SNIP="${PANEL_SNIP:-/etc/nginx/snippets/vpn-panel-ui.conf}"
HCFG="${HAPROXY_CONF:-/etc/haproxy/haproxy.cfg}"
[[ -f /var/www/vpn-panel/index.html && -f /var/www/vpn-api/index.php ]] || { echo "[GAGAL] Panel web belum terpasang di VPS ini (jalankan installer panel)."; exit 1; }
[[ -f "$CONF" ]] || { echo "[GAGAL] $CONF tidak ada"; exit 1; }
SOCK=$(ls /run/php/php*-fpm.sock 2>/dev/null | head -1); SOCK="${PHP_SOCK:-$SOCK}"
[[ -n "$SOCK" ]] || { echo "[GAGAL] socket PHP-FPM tidak ketemu"; exit 1; }
TS=$(date +%s); cp "$CONF" "$CONF.bak.panelfix.$TS"
if grep -q 'location /panel/' "$CONF" || { grep -q 'vpn-panel-\*.conf' "$CONF" && [[ -f "$SNIP" ]]; }; then
  echo "[OK] Blok panel sudah ada di Nginx."
else
  mkdir -p "$(dirname "$SNIP")"
  cat > "$SNIP" <<EOS
# --- VPN PANEL API & UI (dikelola script, aman dari regenerate config) ---
location /api/ {
    fastcgi_pass unix:$SOCK;
    fastcgi_param SCRIPT_FILENAME /var/www/vpn-api/index.php;
    fastcgi_param QUERY_STRING \$query_string;
    fastcgi_param REQUEST_METHOD \$request_method;
    fastcgi_param CONTENT_TYPE \$content_type;
    fastcgi_param CONTENT_LENGTH \$content_length;
    fastcgi_param REQUEST_URI \$request_uri;
    fastcgi_param HTTP_X_API_KEY \$http_x_api_key;
    fastcgi_param SERVER_SOFTWARE nginx;
    fastcgi_param SERVER_PROTOCOL \$server_protocol;
    fastcgi_index index.php;
}
location /panel/ {
    alias /var/www/vpn-panel/;
    index index.html;
    try_files \$uri \$uri/ /panel/index.html;
}
EOS
  if ! grep -q 'vpn-panel-\*.conf' "$CONF"; then
    A=$(grep -n 'root /var/www/html;' "$CONF" | head -1 | cut -d: -f1)
    [[ -n "$A" ]] || { echo "[GAGAL] pola 'root /var/www/html;' tidak ada di $CONF"; exit 1; }
    awk -v ln=$((A-1)) 'NR==ln{print "    include /etc/nginx/snippets/vpn-panel-*.conf; # vpn-panel"} {print}' "$CONF.bak.panelfix.$TS" > "$CONF"
  fi
  if ! nginx -t >/tmp/nginx-fix.log 2>&1; then cat /tmp/nginx-fix.log; cp "$CONF.bak.panelfix.$TS" "$CONF"; rm -f "$SNIP"; echo "[GAGAL] nginx -t gagal -> dikembalikan"; exit 1; fi
  echo "[OK] Blok /api/ & /panel/ dipulihkan."
fi
# HAProxy: kenali POST/PUT/DELETE/HEAD/OPTIONS/PATCH (API panel pakai POST)
if [[ -f /etc/vpn-script/.multiplex-443-active && -f "$HCFG" ]] && ! grep -q 'looks_like_post' "$HCFG"; then
  cp "$HCFG" "$HCFG.bak.panelfix.$TS"
  awk '
    /^  acl looks_like_http / {
      print "  acl looks_like_get     req.payload(0,4) -m str \"GET \""
      print "  acl looks_like_post    req.payload(0,5) -m str \"POST \""
      print "  acl looks_like_put     req.payload(0,4) -m str \"PUT \""
      print "  acl looks_like_delete  req.payload(0,7) -m str \"DELETE \""
      print "  acl looks_like_head    req.payload(0,5) -m str \"HEAD \""
      print "  acl looks_like_options req.payload(0,8) -m str \"OPTIONS \""
      print "  acl looks_like_patch   req.payload(0,6) -m str \"PATCH \""
      next }
    /^  use_backend multiplex_xray if looks_like_http or looks_like_h2$/ {
      print "  use_backend multiplex_xray if looks_like_get or looks_like_post or looks_like_put or looks_like_delete or looks_like_head or looks_like_options or looks_like_patch or looks_like_h2"
      next }
    { print }' "$HCFG.bak.panelfix.$TS" > "$HCFG"
  if haproxy -c -f "$HCFG" >/tmp/hap-fix.log 2>&1; then echo "[OK] HAProxy: method POST dkk sekarang dikenali."
  else cat /tmp/hap-fix.log; cp "$HCFG.bak.panelfix.$TS" "$HCFG"; echo "[GAGAL] haproxy.cfg invalid -> dikembalikan"; fi
fi
systemctl reload haproxy 2>/dev/null; systemctl reload nginx 2>/dev/null
echo "[OK] Selesai. Buka https://$(grep -m1 -oP 'server_name \K[^; ]+' "$CONF")/panel/ (refresh Ctrl+F5)."
