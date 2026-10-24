# VPN Panel

Web UI untuk mengelola script VPN tunnel manager (VMess / VLess / Trojan /
Shadowsocks / SSH‑WS) tanpa harus masuk terminal tiap kali buat, hapus, edit,
atau perpanjang akun. Ringan: cuma Nginx + PHP-FPM di backend, HTML/CSS/JS
polos di panel — tanpa Node, tanpa framework.

## Fitur
- Buat akun (semua protokol, termasuk password custom untuk SSH‑WS)
- Lihat detail/link koneksi tiap akun
- Edit limit IP & kuota
- Perpanjang masa aktif
- Hapus akun
- Toggle layanan sistem (xray, nginx, dropbear, stunnel4, haproxy)
- Tema terang / gelap / otomatis (ikut preferensi perangkat)
- Hitungan akun per-protokol yang akurat (termasuk SSH‑WS)
- **OpenVPN**: detail akun SSH‑WS menampilkan info OpenVPN + tombol download config
  (`.ovpn` TCP / UDP / WS / WSS, link sementara 60 menit; akun OpenVPN = akun SSH yang sama)
- **User Online**: daftar sesi SSH, Xray, dan OpenVPN (segar tiap 15 detik) + tombol putuskan sesi
- **Keamanan**: saklar blokir torrent, status Fail2ban + buka blokir IP, status BBR/IPv6
- Layanan tambahan otomatis muncul kalau terpasang: OpenVPN TCP/UDP, WebSocket OpenVPN,
  UDPGW, Fail2ban, xray-maxlogin
- Menghapus akun SSH‑WS ikut memutus sesi SSH/OpenVPN-nya dan membersihkan kuota/limit-nya

## Struktur

```
vpn-panel/
├── panel/
│   ├── index.html              ← panel utama (yang dipakai)
│   └── design-variants/        ← alternatif desain (referensi, tidak dipakai)
├── api/
│   ├── index.php               ← backend, terima request dari panel
│   └── api-cli.sh               ← jembatan ke lib.sh script VPN aslimu
└── deploy/
    ├── DEPLOY.md                ← langkah pasang LENGKAP (baca sebelum install)
    └── sudoers-vpnapi           ← batasi hak akses PHP ke satu script saja
```

## Cara pakai

**Baca `deploy/DEPLOY.md` secara lengkap sebelum mulai** — panduan itu sudah
mencakup beberapa perbaikan penting (nginx, haproxy) yang WAJIB dilakukan
kalau setup-mu pakai multiplex port 443 (haproxy + nginx internal), kalau
tidak API tidak akan berfungsi untuk request selain GET.

Ringkasnya:
1. Jalankan command instalasi di `DEPLOY.md` bagian 0.
2. Sisipkan konfigurasi nginx (bagian 1–2) — perhatikan mana blok yang harus
   disisipi (tergantung apakah `haproxy` multiplex aktif atau tidak).
3. **Kalau multiplex aktif, WAJIB perbaiki `haproxy.cfg`** (bagian 3) —
   tanpa ini, POST/DELETE dari panel akan selalu gagal.
4. `systemctl enable nginx` (bagian 4) — servermu reboot otomatis tiap hari.
5. Verifikasi dengan `curl` (bagian 5) sebelum buka panel di browser.

## Keamanan (baca sebelum dipakai online)

- Endpoint API ini bisa membuat/menghapus/mengubah akun VPN di server —
  perlakukan API key-nya sekuat password root.
- **Wajib** HTTPS sebelum dipakai lewat internet publik.
- `deploy/sudoers-vpnapi` sengaja membatasi PHP-FPM (`www-data`) hanya boleh
  menjalankan satu file (`api-cli.sh`) sebagai root — jangan diperlonggar.
- Jangan commit API key, domain asli, atau IP server ke repo publik.
- **Server ini pernah diambil alih pihak lain** — setiap kali rebuild,
  ganti password root, cek `fail2ban`, dan periksa `/etc/cron.d/` untuk
  entri mencurigakan sebelum menyambungkan kembali ke akun pelanggan asli.
- Pertimbangkan batasi akses `/api/` per-IP di Nginx, atau taruh panel di
  belakang VPN/WireGuard terpisah kalau cuma dipakai sendiri.

## Lisensi

Belum ditentukan — tambahkan file `LICENSE` sesuai preferensimu.
