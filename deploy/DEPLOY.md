# Deploy panel VPN (versi lengkap, sudah termasuk semua fix)

> **Syarat fitur baru (OpenVPN, User Online, Keamanan):** script VPN di server harus
> versi terbaru dari `oghc93/xray-tunell` — khususnya `menu/openvpn.sh` (perintah
> `dl-json`) dan `menu/tools.sh` (perintah `online-json`), plus `addon/torrent-block.sh`
> dan `menu/security.sh`. Kalau belum, panel tetap jalan normal; hanya bagian
> yang butuh file itu yang menampilkan pesan "update script VPN dulu".
> Setelah `vpn-update`, jalankan sekali `bash /etc/vpn-script/menu/openvpn.sh ws-apply`
> supaya link download `.ovpn` aktif.

Panduan ini sudah mengakomodasi semua masalah yang ditemukan waktu debugging
pertama kali. Ikuti urut dari atas.

## 0. Kalau kamu rebuild VPS dari nol (server baru/bersih)

```bash
git clone https://github.com/oghc93/xray.git /opt/xray-panel && cd /opt/xray-panel && apt update && apt install -y php-fpm php-cli jq && mkdir -p /etc/vpn-script/api /var/www/vpn-api /var/www/vpn-panel && cp api/api-cli.sh /etc/vpn-script/api/api-cli.sh && chmod 750 /etc/vpn-script/api/api-cli.sh && chown root:root /etc/vpn-script/api/api-cli.sh && cp api/index.php /var/www/vpn-api/index.php && touch /var/log/vpn-panel-bridge-errors.log && chown www-data:www-data /var/log/vpn-panel-bridge-errors.log && cp panel/index.html /var/www/vpn-panel/index.html && cp deploy/sudoers-vpnapi /etc/sudoers.d/vpnapi && chmod 440 /etc/sudoers.d/vpnapi && visudo -c && PHP_VER=$(php -v | head -1 | grep -oP '\d+\.\d+') && KEY=$(openssl rand -hex 32) && echo "env[VPN_API_KEY] = \"$KEY\"" >> /etc/php/$PHP_VER/fpm/pool.d/www.conf && systemctl restart php$PHP_VER-fpm && echo "=== SIMPAN API KEY INI: $KEY ==="
```

**Catat API key yang muncul di baris terakhir.**

## 1. Cek struktur nginx yang sudah ada

```bash
grep -n "listen\|server_name" /etc/nginx/conf.d/xray.conf
ls /etc/vpn-script/.multiplex-443-active 2>&1
```

Ada dua kemungkinan:
- **Kalau `.multiplex-443-active` ADA**: port publik 443 dipegang `haproxy`
  (bukan nginx langsung), nginx cuma dengar di `127.0.0.1:8443` secara
  internal. Sisipkan blok di bagian **"Port 443"** yang `listen`-nya
  `127.0.0.1:8443`, BUKAN yang `listen 443` langsung (kalau ada dua).
- **Kalau tidak ada file itu**: nginx pegang langsung `listen 443 ssl http2;`
  publik, sisipkan di situ.

Cari baris `root /var/www/html;` (fallback "situs kamuflase") — sisipkan
tepat SEBELUM baris `location / {` yang jadi induknya, supaya kamuflase
tetap fungsi.

## 2. Sisipkan blok API dan panel (PENTING: JANGAN pakai snippet PHP bawaan)

`snippets/fastcgi-php.conf` bawaan Debian punya `try_files $fastcgi_script_name =404;`
yang MEMBLOKIR method `DELETE` (nginx `try_files` cuma dukung GET/HEAD/POST).
Pakai config manual ini:

```bash
cp /etc/nginx/conf.d/xray.conf /etc/nginx/conf.d/xray.conf.bak.$(date +%Y%m%d%H%M%S)
```

Lalu edit manual atau pakai python (ganti `LINE_NUM` dengan nomor baris `location / {` yang tepat sebelum `root /var/www/html;`):

```nginx
    location /api/ {
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME /var/www/vpn-api/index.php;
        fastcgi_param QUERY_STRING $query_string;
        fastcgi_param REQUEST_METHOD $request_method;
        fastcgi_param CONTENT_TYPE $content_type;
        fastcgi_param CONTENT_LENGTH $content_length;
        fastcgi_param REQUEST_URI $request_uri;
        fastcgi_param HTTP_X_API_KEY $http_x_api_key;
        fastcgi_param SERVER_SOFTWARE nginx;
        fastcgi_param SERVER_PROTOCOL $server_protocol;
        fastcgi_index index.php;
    }

    location /panel/ {
        alias /var/www/vpn-panel/;
        index index.html;
        try_files $uri $uri/ /panel/index.html;
    }
```

(Cek versi PHP-FPM socket-nya dulu: `ls /run/php/`.)

```bash
nginx -t && systemctl reload nginx
```

## 3. PENTING — Perbaiki haproxy kalau pakai multiplex

Kalau langkah 1 nemu `.multiplex-443-active`, haproxy secara DEFAULT cuma
mengenali request `GET` sebagai trafik HTTP (semua method lain dianggap
bukan-HTTP dan dilempar ke backend SSH, bikin API selalu gagal untuk
POST/DELETE). Cek dan perbaiki:

```bash
grep -n "looks_like\|use_backend multiplex" /etc/haproxy/haproxy.cfg
```

Kalau cuma ada `looks_like_http` (GET doang), jalankan:

```bash
cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bak.$(date +%Y%m%d%H%M%S)

awk '
/^  acl looks_like_http / { print "  acl looks_like_get     req.payload(0,4) -m str \"GET \""; print "  acl looks_like_post    req.payload(0,5) -m str \"POST \""; print "  acl looks_like_put     req.payload(0,4) -m str \"PUT \""; print "  acl looks_like_delete  req.payload(0,7) -m str \"DELETE \""; print "  acl looks_like_head    req.payload(0,5) -m str \"HEAD \""; print "  acl looks_like_options req.payload(0,8) -m str \"OPTIONS \""; print "  acl looks_like_patch   req.payload(0,6) -m str \"PATCH \""; next }
/^  use_backend multiplex_xray if looks_like_http or looks_like_h2$/ { print "  use_backend multiplex_xray if looks_like_get or looks_like_post or looks_like_put or looks_like_delete or looks_like_head or looks_like_options or looks_like_patch or looks_like_h2"; next }
{ print }
' /etc/haproxy/haproxy.cfg > /tmp/haproxy.cfg.new && cat /tmp/haproxy.cfg.new > /etc/haproxy/haproxy.cfg

haproxy -c -f /etc/haproxy/haproxy.cfg && systemctl reload haproxy
```

**Catatan:** file ini bertanda "dikelola addon" — kalau kamu re-run addon
`enable-ssl-multiplex.sh` di masa depan, fix ini bisa ketimpa lagi dan perlu
diulang.

## 4. Pastikan nginx auto-start setelah reboot

```bash
systemctl enable nginx
```

Server ini reboot otomatis tiap hari (cron `re_otm` jam 2 pagi) — kalau
nginx sempat gagal start karena rebutan port dengan service lain (pernah
kejadian dengan `sslh`), servicenya perlu di-`enable` supaya sistemd
tetap coba nyalakan di boot berikutnya.

## 5. Verifikasi semua jalur kerja

```bash
KEY="isi-api-key-dari-langkah-0"
curl -sk https://DOMAIN/api/?action=summary -H "X-Api-Key: $KEY"
curl -sk -X POST "https://DOMAIN/api/?action=accounts" -H "X-Api-Key: $KEY" -H "Content-Type: application/json" -d '{"proto":"vmess","username":"tes01","days":1,"ip_limit":2,"quota_gb":1,"trial_hours":0}'
curl -sk -X DELETE "https://DOMAIN/api/?action=accounts" -H "X-Api-Key: $KEY" -H "Content-Type: application/json" -d '{"proto":"vmess","username":"tes01"}'
```

Ketiganya harus balas JSON `{"ok":true,...}`, bukan HTML error atau
`HTTP/0.9`.

## 6. Buka panel

```
https://DOMAIN/panel/
```

Klik "Hubungkan ke server", isi URL API (`https://DOMAIN/api`) dan API key.
Fitur yang tersedia: buat akun (semua protokol + password custom untuk
SSH-WS), lihat detail/link, edit limit, perpanjang, hapus, toggle layanan,
dan pilihan tema (terang/gelap/otomatis mengikuti HP).

## Keamanan (baca — servermu pernah diambil alih orang)

- **Setelah rebuild, ganti password root** (jangan pakai yang lama), atau
  pakai SSH key saja dan matikan login password.
- Cek `fail2ban` aktif: `systemctl is-active fail2ban`.
- Cek `/etc/cron.d/` untuk entri mencurigakan yang bukan bagian dari
  script VPN02 (pernah ditemukan file bernama aneh seperti `re_otm`,
  `xp_otm` — yang itu ternyata jinak/punya provider, tapi tetap harus
  dicek isinya tiap kali curiga: `cat /etc/cron.d/<nama>`).
- API key panel ini setara akses root ke semua akun VPN — jangan commit
  ke file manapun di repo, generate baru tiap kali rebuild.
- Pertimbangkan batasi akses `/api/` dan `/panel/` per-IP di nginx kalau
  cuma dipakai sendiri.
