#!/bin/bash
# ============================================================
#  vpn-update — update panel dari GitHub dengan satu perintah
#  Pasang : curl -fsSL https://raw.githubusercontent.com/oghc93/xray/refs/heads/main/deploy/update.sh -o /usr/local/bin/vpn-update && chmod +x /usr/local/bin/vpn-update
#  Pakai  : vpn-update            (menu)
#           vpn-update all|panel|api|rollback|info
#  Aman   : backup otomatis, cek sintaks sebelum pasang, bisa rollback.
#  Tidak menyentuh: API key, nginx, haproxy, akun-akun VPN.
# ============================================================
set -uo pipefail
REPO_URL="${REPO_URL:-https://github.com/oghc93/xray.git}"
BRANCH="${BRANCH:-main}"
SRC="/opt/xray-panel"; BK="/var/backups/vpn-panel"; STATE="/var/lib/vpn-panel"; BIN="/usr/local/bin/vpn-update"
[[ $EUID -eq 0 ]] || { echo "Jalankan sebagai root"; exit 1; }
G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'
ok(){ echo "${G}✔${N} $*"; }; warn(){ echo "${Y}!${N} $*"; }; err(){ echo "${R}✘${N} $*"; }

# sumber di repo -> tujuan di VPS
declare -A MAP_PANEL=( ["panel/index.html"]="/var/www/vpn-panel/index.html" ["free/index.html"]="/var/www/vpn-free/index.html" )
declare -A MAP_API=(   ["api/api-cli.sh"]="/etc/vpn-script/api/api-cli.sh" ["api/index.php"]="/var/www/vpn-api/index.php" ["api/free.php"]="/var/www/vpn-api/free.php" )
CHG=0; API_CHG=0; OLD=""; NEW=""

fetch(){
  command -v git >/dev/null || apt-get install -y git >/dev/null 2>&1
  if [[ -d $SRC/.git ]]; then
    git -C "$SRC" fetch -q origin "$BRANCH" || { err "Gagal ambil dari GitHub (cek internet / nama repo)"; return 1; }
  else
    rm -rf "$SRC"; git clone -q --branch "$BRANCH" "$REPO_URL" "$SRC" || { err "Gagal clone $REPO_URL"; return 1; }
  fi
  OLD=$(cat "$STATE/deployed-commit" 2>/dev/null || true)
  git -C "$SRC" reset -q --hard "origin/$BRANCH"
  NEW=$(git -C "$SRC" rev-parse HEAD)
}

validate(){
  bash -n "$SRC/api/api-cli.sh" 2>/dev/null || { err "api-cli.sh error sintaks — update dibatalkan"; return 1; }
  if command -v php >/dev/null; then
    for f in api/index.php api/free.php; do
      [[ -f $SRC/$f ]] && ! php -l "$SRC/$f" >/dev/null 2>&1 && { err "$f error sintaks — update dibatalkan"; return 1; }
    done
  fi
  grep -qi "<html" "$SRC/panel/index.html" || { err "panel/index.html tidak valid — update dibatalkan"; return 1; }
}

backup(){
  mkdir -p "$BK"; local ts list=() t
  ts=$(date +%Y%m%d-%H%M%S)
  for t in "$@"; do [[ -f $t ]] && list+=("${t#/}"); done
  if ((${#list[@]})); then tar -C / -czf "$BK/$ts.tgz" "${list[@]}" && ok "Backup tersimpan: $BK/$ts.tgz"; fi
  ls -1t "$BK"/*.tgz 2>/dev/null | tail -n +8 | xargs -r rm -f
}

deploy(){  # $1 = nama array peta
  local -n M=$1; local s t m
  for s in "${!M[@]}"; do
    t="${M[$s]}"; [[ -f $SRC/$s ]] || continue
    # halaman/API akun gratis hanya diperbarui kalau memang sudah terpasang
    [[ $s == *free* && ! -f $t ]] && continue
    cmp -s "$SRC/$s" "$t" 2>/dev/null && continue
    [[ $s == *.sh ]] && m=750 || m=644
    mkdir -p "$(dirname "$t")"
    install -o root -g root -m "$m" "$SRC/$s" "$t" && { ok "Diperbarui: $t"; CHG=$((CHG+1)); [[ $1 == MAP_API ]] && API_CHG=1; }
  done
}

reload_php(){
  local s; s=$(systemctl list-units --type=service --no-legend 'php*-fpm.service' 2>/dev/null | awk '{print $1}' | head -1)
  [[ -n $s ]] && systemctl reload "$s" && ok "Reload $s"
}

sync_sudoers(){
  local f="$SRC/deploy/sudoers-vpnapi" t=/etc/sudoers.d/vpnapi
  [[ -f $f ]] && ! cmp -s "$f" "$t" || return 0
  if visudo -cf "$f" >/dev/null 2>&1; then install -m 440 -o root -g root "$f" "$t" && ok "Aturan sudoers diperbarui"
  else warn "sudoers baru tidak valid, dilewati"; fi
}

do_update(){  # $1 = all | panel | api
  local what="$1" groups=() g t
  fetch || return 1
  validate || return 1
  case $what in panel) groups=(MAP_PANEL);; api) groups=(MAP_API);; *) groups=(MAP_PANEL MAP_API);; esac
  local targets=(); for g in "${groups[@]}"; do local -n M=$g; for t in "${M[@]}"; do targets+=("$t"); done; unset -n M; done
  backup "${targets[@]}"
  CHG=0; API_CHG=0
  for g in "${groups[@]}"; do deploy "$g"; done
  if ((API_CHG)); then sync_sudoers; reload_php; fi
  if [[ $what == all && -f $SRC/deploy/update.sh ]] && ! cmp -s "$SRC/deploy/update.sh" "$BIN"; then
    install -m 755 "$SRC/deploy/update.sh" "$BIN.new" && mv -f "$BIN.new" "$BIN" && ok "vpn-update ikut diperbarui"
  fi
  mkdir -p "$STATE"; echo "$NEW" > "$STATE/deployed-commit"
  if ((CHG==0)); then ok "Sudah yang terbaru — tidak ada file yang berubah"
  else
    ok "Selesai: $CHG file diperbarui → versi $(git -C "$SRC" log -1 --format='%h — %s')"
    echo "   Refresh browser dengan Ctrl+Shift+R"
  fi
}

do_rollback(){
  local f a; f=$(ls -1t "$BK"/*.tgz 2>/dev/null | head -1)
  [[ -n $f ]] || { err "Belum ada backup"; return 1; }
  read -rp "Kembalikan ke backup $(basename "$f")? [y/N] " a
  [[ $a == y || $a == Y ]] || { warn "Dibatalkan"; return 0; }
  tar -C / -xzf "$f" && ok "File dikembalikan dari $(basename "$f")" && reload_php
}

do_info(){
  fetch || return 1
  echo "Terpasang : ${OLD:0:7}  ${OLD:+$(git -C "$SRC" log -1 --format='%s' "$OLD" 2>/dev/null)}"
  echo "Terbaru   : ${NEW:0:7}  $(git -C "$SRC" log -1 --format='%s')"
  if [[ -n $OLD && $OLD != "$NEW" ]] && git -C "$SRC" cat-file -e "$OLD" 2>/dev/null; then
    echo "Perubahan yang menunggu:"; git -C "$SRC" log --format='  • %s (%cr)' "$OLD..$NEW"
  elif [[ $OLD == "$NEW" ]]; then ok "Sudah versi terbaru"
  else warn "Versi terpasang belum tercatat — jalankan update sekali"; fi
}

menu(){
  while true; do
    echo; echo "${C}══════ VPN PANEL UPDATER ══════${N}"
    echo " 1) Update SEMUA (tampilan + API + fitur)"
    echo " 2) Update tampilan panel saja"
    echo " 3) Update API / backend saja"
    echo " 4) Cek versi & perubahan baru"
    echo " 5) Rollback ke backup terakhir"
    echo " 0) Keluar"
    read -rp "Pilih: " c
    case $c in 1) do_update all;; 2) do_update panel;; 3) do_update api;; 4) do_info;; 5) do_rollback;; 0) exit 0;; *) warn "Pilihan tidak ada";; esac
  done
}

case "${1:-menu}" in
  all|panel|api) do_update "$1";;
  rollback) do_rollback;; info) do_info;;
  install) install -m 755 "$0" "$BIN" && ok "Terpasang: ketik 'vpn-update'";;
  menu|*) menu;;
esac
