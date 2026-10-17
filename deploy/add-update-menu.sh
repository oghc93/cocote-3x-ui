#!/bin/bash
# Menambah menu "16) Update Panel Web" ke /etc/vpn-script/menu.sh (aman, ada backup, bisa diulang)
F="${MENU_FILE:-/etc/vpn-script/menu.sh}"
[[ -f $F ]] || { echo "menu.sh tidak ditemukan di $F"; exit 1; }
grep -q "Update Panel Web" "$F" && { echo "Menu sudah terpasang, tidak ada yang diubah."; exit 0; }
BK="$F.bak.$(date +%Y%m%d%H%M%S)"; cp "$F" "$BK"

cat > /tmp/_row.txt <<'EOT'
  ui_2col "$(ui_menu_num 16 'Update Panel Web')" ""
EOT
cat > /tmp/_case.txt <<'EOT'
    16) if command -v vpn-update >/dev/null 2>&1; then vpn-update; else echo -e "  ${RED}[!] vpn-update belum terpasang${NC}"; sleep 2; fi; main_menu ;;
EOT
sed -i "/ui_menu_num 12 'System Info'/r /tmp/_row.txt" "$F"
sed -i '/15) bash \$SCRIPT_DIR\/menu\/rebuild.sh ;;/r /tmp/_case.txt' "$F"
sed -i 's/Pilih menu \[0-15\]/Pilih menu [0-16]/' "$F"
rm -f /tmp/_row.txt /tmp/_case.txt

if bash -n "$F" && grep -q "16) if command" "$F" && grep -q "ui_menu_num 16" "$F"; then
  echo "✔ Menu 16 'Update Panel Web' berhasil ditambahkan. Backup: $BK"
else
  cp "$BK" "$F"; echo "✘ Gagal menambah menu, file dikembalikan seperti semula."; exit 1
fi

if ! command -v vpn-update >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/oghc93/xray/refs/heads/main/deploy/update.sh -o /usr/local/bin/vpn-update \
    && chmod +x /usr/local/bin/vpn-update && echo "✔ vpn-update terpasang" \
    || echo "! vpn-update belum bisa diunduh — upload deploy/update.sh ke GitHub dulu, lalu pasang manual"
fi
