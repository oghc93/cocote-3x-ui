#!/bin/bash
# ============================================================
#  API BRIDGE — dipanggil oleh backend PHP (index.php)
#  Tugasnya cuma satu: terima perintah lewat argumen,
#  panggil fungsi asli di lib.sh, keluarkan JSON ke stdout.
#  Script asli (create_vmess, dkk) TIDAK diubah sama sekali.
#
#  Install di: /etc/vpn-script/api/api-cli.sh
#  Jalan sebagai root lewat sudo (lihat README-DEPLOY.md)
#
#  CATATAN PERBAIKAN (dari sesi debugging):
#  - "set -e" dibuang (jadi "set -uo pipefail" saja) karena
#    beberapa fungsi asli di lib.sh (mis. reset_xray_user_traffic)
#    bisa return non-zero untuk kegagalan yang sebenarnya tidak
#    fatal (mis. Xray API stats belum aktif) — dengan "set -e"
#    itu mematikan seluruh bridge tanpa output apa pun.
#  - baris terakhir lib.sh punya idiom
#    `[[ "${BASH_SOURCE[0]}" == "${0}" ]] && "$@"` yang exit
#    status-nya ikut jadi status "source" — makanya ditambah
#    `|| true` di baris source supaya tidak dianggap gagal.
#  - gen_*_link butuh 5 argumen (yang ke-5/"remark" opsional),
#    tapi karena lib.sh pakai `set -u` di beberapa tempat,
#    argumen ke-5 harus tetap dikirim eksplisit sebagai ""
#    kalau tidak dipakai, kalau tidak akan "unbound variable".
# ============================================================
set -uo pipefail
SCRIPT_DIR="/etc/vpn-script"
source "$SCRIPT_DIR/lib.sh" || true

json_err() { printf '{"ok":false,"error":%s}\n' "$(jq -Rn --arg m "$1" '$m')"; exit 1; }
json_ok_secret() { printf '{"ok":true,"secret":%s}\n' "$(jq -Rn --arg s "$1" '$s')"; }

# ── Layanan tambahan (OpenVPN, UDPGW, Fail2ban, dll) ────────────────
# nama di panel -> nama unit systemd. Hanya yang unit-nya benar-benar ada
# di VPS yang ditampilkan/boleh di-toggle.
declare -A SVC_UNIT=(
  [xray]=xray [nginx]=nginx [dropbear]=dropbear [stunnel4]=stunnel4 [haproxy]=haproxy
  [openvpn-tcp]=openvpn-server@vpn-script-tcp [openvpn-udp]=openvpn-server@vpn-script-udp
  [ws-openvpn]=ws-openvpn [badvpn-udpgw]=badvpn-udpgw [fail2ban]=fail2ban [xray-maxlogin]=xray-maxlogin
)
SVC_CORE=(xray nginx dropbear stunnel4 haproxy)
SVC_OPTIONAL=(openvpn-tcp openvpn-udp ws-openvpn badvpn-udpgw fail2ban xray-maxlogin)
unit_exists() { systemctl cat "$1" >/dev/null 2>&1; }
OVPN_CONF_FILE="/etc/openvpn/vpn-script/ovpn.conf"
OVPN_SERVER_CONF="/etc/openvpn/server/vpn-script-tcp.conf"
ovpn_installed() { [[ -f "$OVPN_SERVER_CONF" ]]; }
valid_user() { [[ "${1:-}" =~ ^[a-zA-Z0-9_]{3,32}$ ]]; }
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# ════════════════════════════════════════════════════════════════
#  V8 — fitur tambahan panel (log aktivitas, riwayat, SSL, traffic,
#  speedtest, backup, Telegram). Semua ada di file ini; script VPN
#  tidak perlu diubah.
# ════════════════════════════════════════════════════════════════
ACT_LOG="/var/log/vpn-panel-activity.log"
HIST_LOG="/var/log/vpn-panel-history.jsonl"
SAMPLE_CRON="/etc/cron.d/vpn-panel-sample"
SPEEDTEST_BIN="/usr/local/bin/speedtest"
SPEED_LIVE="/var/log/vpn-panel-speedtest.live"
SSL_CRT="/etc/ssl/xray/xray.crt"

act_log() {   # act_log <aksi> <target> <ok:true|false> <detail>
  jq -cn --argjson t "$(date +%s)" --arg a "$1" --arg g "$2" --argjson ok "$3" --arg d "${4:-}" \
    '{t:$t, action:$a, target:$g, ok:$ok, detail:$d}' >> "$ACT_LOG" 2>/dev/null || return 0
  chmod 600 "$ACT_LOG" 2>/dev/null
  if [[ $(wc -l < "$ACT_LOG" 2>/dev/null || echo 0) -gt 600 ]]; then
    tail -n 400 "$ACT_LOG" > "$ACT_LOG.tmp" 2>/dev/null && mv "$ACT_LOG.tmp" "$ACT_LOG"
  fi
}

cpu_pct() {
  local a b ta tb ia ib dt di
  read -ra a < <(head -n1 /proc/stat); sleep 0.4; read -ra b < <(head -n1 /proc/stat)
  ta=0; tb=0
  for v in "${a[@]:1:8}"; do ta=$((ta+v)); done
  for v in "${b[@]:1:8}"; do tb=$((tb+v)); done
  ia=$(( ${a[4]:-0} + ${a[5]:-0} )); ib=$(( ${b[4]:-0} + ${b[5]:-0} ))
  dt=$((tb-ta)); di=$((ib-ia))
  (( dt > 0 )) && echo $(( (dt-di)*100/dt )) || echo 0
}
mem_pct()  { free -m 2>/dev/null | awk 'NR==2 && $2>0{printf "%.0f", $3*100/$2; exit} END{if(NR<2)print 0}'; }
disk_pct() { df / 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5+0}'; }

ssl_json() {
  [[ -s "$SSL_CRT" ]] || { echo '{"present":false}'; return; }
  local end subj iss exp_epoch now o cn days ss=false
  end=$(openssl x509 -in "$SSL_CRT" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')
  subj=$(openssl x509 -in "$SSL_CRT" -noout -subject -nameopt RFC2253 2>/dev/null | sed 's/^subject=//')
  iss=$(openssl x509 -in "$SSL_CRT" -noout -issuer -nameopt RFC2253 2>/dev/null | sed 's/^issuer=//')
  [[ -n "$end" ]] || { echo '{"present":false}'; return; }
  exp_epoch=$(date -d "$end" +%s 2>/dev/null || echo 0); now=$(date +%s)
  days=$(( (exp_epoch - now) / 86400 ))
  o=$(sed -n 's/.*O=\([^,]*\).*/\1/p' <<< "$iss"); cn=$(sed -n 's/.*CN=\([^,]*\).*/\1/p' <<< "$iss")
  [[ -n "$subj" && "$subj" == "$iss" ]] && ss=true
  jq -cn --arg exp "$(date -d "@$exp_epoch" +%Y-%m-%d 2>/dev/null)" --argjson days "$days" \
    --arg issuer "${o:-$cn}" --argjson ss "$ss" \
    '{present:true, expiry:$exp, days_left:$days, issuer:$issuer, self_signed:$ss}'
}

vn_iface() { ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'; }
traffic_json() {
  command -v vnstat >/dev/null 2>&1 || { echo '{"installed":false}'; return; }
  vnstat --version 2>/dev/null | grep -q 'vnStat 2' || { echo '{"installed":true,"supported":false}'; return; }
  local iface d m
  iface=$(vn_iface); [[ -n "$iface" ]] || { echo '{"installed":true,"supported":false}'; return; }
  d=$(vnstat --json d 14 -i "$iface" 2>/dev/null); m=$(vnstat --json m 2 -i "$iface" 2>/dev/null)
  jq -e . >/dev/null 2>&1 <<< "${d:-}" || d=null
  jq -e . >/dev/null 2>&1 <<< "${m:-}" || m=null
  jq -cn --argjson d "$d" --argjson m "$m" --arg iface "$iface" '
    def mul: if (($d.jsonversion // "2")|tostring) == "1" then 1024 else 1 end;
    ($d.interfaces[0].traffic.day // []) as $days |
    ($m.interfaces[0].traffic.month // []) as $mons |
    ($mons | last // null) as $cm |
    {installed:true, supported:true, iface:$iface,
     month: (if $cm then {label:(($cm.date.year|tostring)+"-"+(("0"+($cm.date.month|tostring))|.[-2:])), rx:($cm.rx*mul), tx:($cm.tx*mul)} else null end),
     days: [$days[-14:][]? | {d:((("0"+(.date.month|tostring))|.[-2:])+"-"+(("0"+(.date.day|tostring))|.[-2:])), rx:(.rx*mul), tx:(.tx*mul)}]}'
}

tg_json() {
  local tok="${TELEGRAM_BOT_TOKEN:-}" chat="${TELEGRAM_CHAT_ID:-}" bot=false cr=false
  systemctl is-active --quiet tg-backup-bot 2>/dev/null && bot=true
  [[ -f /etc/cron.d/tg-backup ]] && cr=true
  jq -cn --argjson ts "$([[ -n "$tok" ]] && echo true || echo false)" --arg hint "${tok: -4}" \
    --arg chat "$chat" --argjson bot "$bot" --argjson cr "$cr" \
    '{token_set:$ts, token_hint:(if $ts then $hint else "" end), chat_id:$chat, bot_active:$bot, cron_active:$cr}'
}

hist_sample() {
  local ts last online=0 oj
  ts=$(date +%s)
  last=$(tail -n1 "$HIST_LOG" 2>/dev/null | jq -r '.t // 0' 2>/dev/null); [[ "$last" =~ ^[0-9]+$ ]] || last=0
  (( ts - last < 240 )) && return 0
  if [[ -f "$SCRIPT_DIR/menu/tools.sh" ]]; then
    oj=$(timeout 25 bash "$SCRIPT_DIR/menu/tools.sh" online-json 2>/dev/null)
    online=$(jq -r '.total // 0' <<< "$oj" 2>/dev/null); [[ "$online" =~ ^[0-9]+$ ]] || online=0
  fi
  jq -cn --argjson t "$ts" --argjson o "$online" --argjson c "$(cpu_pct)" --argjson m "$(mem_pct)" \
    '{t:$t, online:$o, cpu:$c, mem:$m}' >> "$HIST_LOG" 2>/dev/null
  chmod 600 "$HIST_LOG" 2>/dev/null
  if [[ $(wc -l < "$HIST_LOG" 2>/dev/null || echo 0) -gt 700 ]]; then
    tail -n 600 "$HIST_LOG" > "$HIST_LOG.tmp" 2>/dev/null && mv "$HIST_LOG.tmp" "$HIST_LOG"
  fi
}
ensure_quota_cron() {
  [[ -f /etc/vpn-script/addon/quota-limiter.sh && ! -f /etc/cron.d/vpn-quota-limiter ]] || return 0
  printf '* * * * * root /bin/bash /etc/vpn-script/addon/quota-limiter.sh >/dev/null 2>&1\n' > /etc/cron.d/vpn-quota-limiter 2>/dev/null \
    && chmod 644 /etc/cron.d/vpn-quota-limiter 2>/dev/null
  return 0
}
ensure_sample_cron() {
  [[ -f "$SAMPLE_CRON" ]] && return 0
  printf '*/5 * * * * root /etc/vpn-script/api/api-cli.sh --sample >/dev/null 2>&1\n' > "$SAMPLE_CRON" 2>/dev/null \
    && chmod 644 "$SAMPLE_CRON" 2>/dev/null
  return 0
}

# ── Pekerjaan lama (speedtest, backup, perpanjang SSL) dijalankan di latar
#    belakang supaya tidak kena batas waktu nginx/PHP; hasilnya dibaca lewat job_status.
job_file() { echo "/var/log/vpn-panel-job-$1.json"; }
job_start() {
  local name="$1" f st ts; f=$(job_file "$name")
  if [[ -f "$f" ]]; then
    st=$(jq -r '.state // ""' "$f" 2>/dev/null); ts=$(jq -r '.ts // 0' "$f" 2>/dev/null)
    if [[ "$st" == "running" && "$ts" =~ ^[0-9]+$ ]] && (( $(date +%s) - ts < 300 )); then
      echo '{"ok":true,"state":"running","already":true}'; return
    fi
  fi
  printf '{"state":"running","ts":%s}\n' "$(date +%s)" > "$f"
  [[ "$name" == "speedtest" ]] && : > "$SPEED_LIVE"
  setsid nohup "$0" --job "$name" >/dev/null 2>&1 </dev/null &
  echo '{"ok":true,"state":"running"}'
}
job_status() {
  local name="$1" f st ts now; f=$(job_file "$name")
  [[ -f "$f" ]] || { echo '{"ok":true,"state":"none"}'; return; }
  st=$(jq -r '.state // ""' "$f" 2>/dev/null); ts=$(jq -r '.ts // 0' "$f" 2>/dev/null); now=$(date +%s)
  if [[ "$st" == "running" && "$ts" =~ ^[0-9]+$ ]] && (( now - ts > 400 )); then
    echo '{"ok":true,"state":"error","result":{"ok":false,"error":"Proses terlalu lama / terhenti"}}'; return
  fi
  jq -c '. + {ok:true}' "$f" 2>/dev/null || echo '{"ok":true,"state":"none"}'
}

do_speedtest() {
  local a tmp raw
  if [[ ! -x "$SPEEDTEST_BIN" ]] && ! command -v speedtest >/dev/null 2>&1; then
    case "$(uname -m)" in
      x86_64) a=x86_64;; aarch64|arm64) a=aarch64;; armv7l|armv6l) a=armhf;; i?86) a=i386;; *) a="";;
    esac
    [[ -n "$a" ]] || { echo '{"ok":false,"error":"Arsitektur CPU tidak didukung Ookla CLI"}'; return; }
    tmp=$(mktemp -d)
    curl -fsSL --max-time 60 "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-${a}.tgz" 2>/dev/null \
      | tar -xz -C "$tmp" speedtest 2>/dev/null && install -m 755 "$tmp/speedtest" "$SPEEDTEST_BIN" 2>/dev/null
    rm -rf "$tmp"
    [[ -x "$SPEEDTEST_BIN" ]] || { echo '{"ok":false,"error":"Gagal memasang Ookla Speedtest (install.speedtest.net tidak terjangkau). Pasang lewat vpn → 18 → Speedtest"}'; return; }
  fi
  local bin="$SPEEDTEST_BIN"; [[ -x "$bin" ]] || bin=$(command -v speedtest)
  : > "$SPEED_LIVE"; chmod 600 "$SPEED_LIVE" 2>/dev/null
  timeout 150 "$bin" --accept-license --accept-gdpr -f jsonl -p no > "$SPEED_LIVE" 2>/dev/null
  raw=$(grep '"type":"result"' "$SPEED_LIVE" 2>/dev/null | tail -n1)
  jq -e '.download.bandwidth' >/dev/null 2>&1 <<< "$raw" || { echo '{"ok":false,"error":"Speedtest gagal / tidak ada server yang terjangkau"}'; return; }
  jq -c '{ok:true,
          ping:(.ping.latency*10|round/10), jitter:(.ping.jitter*10|round/10),
          down:(.download.bandwidth*8/1000000*10|round/10), up:(.upload.bandwidth*8/1000000*10|round/10),
          server:((.server.name // "")+" · "+(.server.location // "")), isp:(.isp // ""),
          url:(.result.url // ""), ts:(.timestamp // "")}' <<< "$raw"
}
do_backup() {
  local raw rc msg
  [[ -f "$SCRIPT_DIR/menu/backup.sh" ]] || { echo '{"ok":false,"error":"menu/backup.sh tidak ada, update script VPN dulu"}'; return; }
  raw=$(timeout 150 bash "$SCRIPT_DIR/menu/backup.sh" now 2>&1); rc=$?
  msg=$(strip_ansi <<< "$raw" | sed 's/^ *//' | paste -sd' ' -)
  [[ $rc -eq 0 ]] && ! grep -qi 'gagal' <<< "$msg" || rc=1
  local err="Backup gagal terkirim. Cek Bot Token / Chat ID dan koneksi internet VPS"
  grep -qi 'belum diisi' <<< "$msg" && err="Bot Token / Chat ID belum diisi (isi di kartu Telegram)"
  jq -cn --arg m "$msg" --arg e "$err" --argjson ok "$([[ $rc -eq 0 ]] && echo true || echo false)" \
    '{ok:$ok, message:$m, error:(if $ok then null else $e end)}'
}
do_ssl_renew() {
  local d acme="/root/.acme.sh/acme.sh" raw rc msg opts
  d=$(get_domain)
  [[ -x "$acme" ]] || { echo '{"ok":false,"error":"acme.sh tidak ditemukan. Terbitkan SSL lewat vpn → 09 Change Domain"}'; return; }
  opts=(--renew -d "$d" --force --server letsencrypt)
  [[ -d "/root/.acme.sh/${d}_ecc" ]] && opts+=(--ecc)
  systemctl stop nginx 2>/dev/null
  raw=$(timeout 240 "$acme" "${opts[@]}" 2>&1); rc=$?
  systemctl start nginx 2>/dev/null
  msg=$(strip_ansi <<< "$raw" | tail -n 4 | sed 's/^ *//' | paste -sd' ' -)
  if [[ $rc -eq 0 ]]; then
    cat /etc/ssl/xray/xray.crt /etc/ssl/xray/xray.key > /etc/ssl/xray/xray.pem 2>/dev/null; chmod 600 /etc/ssl/xray/xray.pem 2>/dev/null
    systemctl restart xray 2>/dev/null; systemctl reload haproxy 2>/dev/null
    jq -cn --argjson s "$(ssl_json)" '{ok:true, message:"SSL berhasil diperpanjang", ssl:$s}'
  else
    jq -cn --arg m "${msg:-acme.sh gagal}" '{ok:false, error:("Perpanjang SSL gagal: "+$m)}'
  fi
}

# ── Pembungkus: catat log aktivitas untuk aksi yang mengubah sesuatu ──
if [[ "${1:-}" == "--inner" ]]; then
  shift
else
  case "${1:-}" in
    create_account|delete_account|renew_account|edit_limits|kick|toggle_service|torrent|f2b_unban|tg_set)
      out=$("$0" --inner "$@"); rc=$?
      a="$1"; ok=$(jq -r '.ok // false' <<< "$out" 2>/dev/null); [[ "$ok" == "true" ]] || ok=false
      case "$a" in
        create_account) lbl="Buat akun";        tgt="${3:-} (${2:-})"; det="${4:-0} hari, limit IP ${5:-0}, kuota ${6:-0} GB$([[ "${7:-0}" != "0" ]] && echo ", trial ${7} jam")" ;;
        delete_account) lbl="Hapus akun";       tgt="${3:-} (${2:-})"; det="" ;;
        renew_account)  lbl="Perpanjang akun";  tgt="${3:-} (${2:-})"; det="+${4:-30} hari" ;;
        edit_limits)    lbl="Edit limit akun";  tgt="${3:-} (${2:-})"; det="limit IP ${4:-}, kuota ${5:-} GB" ;;
        kick)           lbl="Putuskan sesi";    tgt="${2:-}"; det="" ;;
        toggle_service) lbl="Layanan ${3:-}";   tgt="${2:-}"; det="" ;;
        torrent)        lbl="Blokir torrent";   tgt="${2:-}"; det="" ;;
        f2b_unban)      lbl="Buka blokir IP";   tgt="${2:-}"; det="" ;;
        tg_set)         lbl="Ubah pengaturan Telegram"; tgt="bot"; det="" ;;
      esac
      [[ "$ok" == "false" ]] && det="$(jq -r '.error // empty' <<< "$out" 2>/dev/null | cut -c1-120)"
      act_log "$lbl" "$tgt" "$ok" "$det"
      printf '%s\n' "$out"
      exit $rc ;;
  esac
fi


case "${1:-}" in

  summary)
    xray_on=$(systemctl is-active xray 2>/dev/null || true)
    nginx_on=$(systemctl is-active nginx 2>/dev/null || true)
    db_on=$(systemctl is-active dropbear 2>/dev/null || true)
    stunnel_on=$(systemctl is-active stunnel4 2>/dev/null || true)
    haproxy_on=$(systemctl is-active haproxy 2>/dev/null || true)
    # layanan opsional: hanya yang terpasang
    extra='{}'
    for n in "${SVC_OPTIONAL[@]}"; do
      if unit_exists "${SVC_UNIT[$n]}"; then
        st=$(systemctl is-active "${SVC_UNIT[$n]}" 2>/dev/null || true)
        extra=$(jq -c --arg n "$n" --arg s "$st" '. + {($n):$s}' <<< "$extra")
      fi
    done
    ovpn_in=false; ovpn_installed && ovpn_in=true
    ensure_sample_cron
    ensure_quota_cron
    cpu_now=$(cpu_pct)
    torrent_on=false; [[ -f "$SCRIPT_DIR/.torrent-block-on" ]] && torrent_on=true
    jq -n \
      --arg domain "$(get_domain)" \
      --arg ip "$(get_server_ip)" \
      --arg os "$(get_os_info)" \
      --arg uptime "$(get_uptime)" \
      --arg load "$(get_load_avg)" \
      --argjson cores "$(get_cpu_cores)" \
      --arg mem "$(get_mem_usage)" \
      --arg disk "$(get_disk_usage)" \
      --argjson vmess "$(count_vmess)" \
      --argjson vless "$(count_vless)" \
      --argjson trojan "$(count_trojan)" \
      --argjson ss "$(count_ss)" \
      --argjson ssh "$(count_ssh 2>/dev/null || wc -l < "$DB_SSH" 2>/dev/null || echo 0)" \
      --arg xray "$xray_on" --arg nginx "$nginx_on" --arg dropbear "$db_on" \
      --arg stunnel4 "$stunnel_on" --arg haproxy "$haproxy_on" \
      --argjson extra "$extra" --argjson ovpn "$ovpn_in" --argjson torrent "$torrent_on" \
      --arg bbr "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo -)" \
      --arg version "$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo -)" \
      --argjson cpu_pct "${cpu_now:-0}" --argjson mem_pct "$(mem_pct)" --argjson disk_pct "$(disk_pct)" \
      --argjson ssl "$(ssl_json)" --argjson traffic "$(traffic_json)" --argjson tg "$(tg_json)" \
      --argjson spd "$([[ -x "$SPEEDTEST_BIN" ]] && echo true || echo false)" \
      --argjson qd "$([[ -f /etc/cron.d/vpn-quota-limiter && -f "$DB_DIR/usage.db" ]] && echo true || echo false)" \
      '{domain:$domain, server_ip:$ip, os:$os, uptime:$uptime, load:$load, cpu_cores:$cores,
        mem:$mem, disk:$disk,
        counts:{vmess:$vmess, vless:$vless, trojan:$trojan, ss:$ss, sshws:$ssh},
        services:({xray:$xray, nginx:$nginx, dropbear:$dropbear, stunnel4:$stunnel4, haproxy:$haproxy} + $extra),
        features:{openvpn:$ovpn, torrent_block:$torrent, bbr:$bbr, script_version:$version, speedtest:$spd, quota_daemon:$qd},
        cpu_pct:$cpu_pct, mem_pct:$mem_pct, disk_pct:$disk_pct, ssl:$ssl, traffic:$traffic, telegram:$tg}'
    ;;

  list_accounts)
    tmp=$(mktemp)
    : > "$tmp.ndjson"
    # pemakaian Xray: satu query untuk semua user (uplink+downlink)
    declare -A XR_USED=()
    if command -v xray >/dev/null 2>&1; then
      while IFS=$'\t' read -r un ub; do
        [[ -n "$un" ]] && XR_USED[$un]=$(( ${ub%.*} / 1024 / 1024 ))
      done < <(xray_stat_query "user>>>" 2>/dev/null | jq -r '
        [.stat[]? | select(.name|test("^user>>>.+>>>traffic>>>(uplink|downlink)$"))
         | {u:(.name|split(">>>")[1]), v:((.value // 0)|tonumber)}]
        | group_by(.u)[] | "\(.[0].u)\t\(map(.v)|add)"' 2>/dev/null)
    fi
    # buku besar pemakaian permanen (ditulis addon/quota-limiter.sh): jenis|user|total_byte|counter
    declare -A LED=()
    if [[ -f "$DB_DIR/usage.db" ]]; then
      while IFS='|' read -r lk lu lt _; do [[ -n "$lk" ]] && LED["$lk|$lu"]="$lt"; done < "$DB_DIR/usage.db"
    fi
    add_rows() {
      local proto="$1" file="$2" used used_b susp lk="x"
      [[ "$proto" == "sshws" ]] && lk="s"
      [[ -f "$file" ]] || return 0
      while IFS='|' read -r c1 c2 c3 c4 c5 c6 c7; do
        [[ -z "$c1" ]] && continue
        if [[ "$proto" == "ss" ]]; then
          exp="$c4"; ip_limit="$c6"; quota_mb="$c7"
        else
          exp="$c3"; ip_limit="$c5"; quota_mb="$c6"
        fi
        if [[ -n "${LED[$lk|$c1]:-}" ]]; then
          used_b="${LED[$lk|$c1]}"
        elif [[ "$proto" == "sshws" ]]; then
          used_b=$(( $(get_ssh_usage_mb "$c1" 2>/dev/null || echo 0) * 1048576 ))
        else
          used_b=$(( ${XR_USED[$c1]:-0} * 1048576 ))
        fi
        [[ "$used_b" =~ ^[0-9]+$ ]] || used_b=0
        used=$(( used_b / 1048576 ))
        susp=false; [[ -f "$SCRIPT_DIR/.quota-disabled/$([[ "$proto" == "sshws" ]] && echo ssh || echo "$proto")_$c1" ]] && susp=true
        local pk="xray-$proto" pu=0 ps=0 pf
        [[ "$proto" == "sshws" ]] && pk="ssh"
        pf="$SCRIPT_DIR/.penalty/${pk}_$c1"
        [[ -f "$pf" ]] && read -r ps _ pu < "$pf"
        [[ "$pu" =~ ^[0-9]+$ ]] || pu=0; [[ "$ps" =~ ^[0-9]+$ ]] || ps=0
        (( pu > $(date +%s) )) || pu=0
        jq -c -n --arg proto "$proto" --arg user "$c1" --arg exp "$exp" \
          --argjson ip_limit "${ip_limit:-0}" --argjson quota_mb "${quota_mb:-0}" --argjson used_mb "$used" --argjson used_bytes "$used_b" --argjson susp "$susp" \
          --argjson pen_until "$pu" --argjson strikes "$ps" \
          '{proto:$proto, username:$user, exp:$exp, ip_limit:$ip_limit, quota_mb:$quota_mb, used_mb:$used_mb, used_bytes:$used_bytes, suspended:$susp, penalty_until:$pen_until, strikes:$strikes}' \
          >> "$tmp.ndjson"
      done < "$file"
    }
    add_rows vmess "$DB_VMESS"
    add_rows vless "$DB_VLESS"
    add_rows trojan "$DB_TROJAN"
    add_rows ss "$DB_SS"
    add_rows sshws "$DB_SSH"
    jq -s '.' "$tmp.ndjson" 2>/dev/null || echo "[]"
    rm -f "$tmp" "$tmp.ndjson"
    ;;

  create_account)
    proto="${2:-}"; username="${3:-}"; days="${4:-30}"; ip_limit="${5:-}"; quota_gb="${6:-0}"; trial_hours="${7:-0}"; custom_password="${8:-}"
    [[ -z "$proto" || -z "$username" ]] && json_err "proto dan username wajib diisi"
    [[ "$username" =~ ^[a-zA-Z0-9_]{3,32}$ ]] || json_err "username tidak valid (huruf/angka/underscore, 3-32 karakter)"
    quota_mb=$(( ${quota_gb%.*} * 1024 ))
    case "$proto" in
      vmess)  secret=$(create_vmess  "$username" "$days" "$ip_limit" "$quota_mb" "$trial_hours") ;;
      vless)  secret=$(create_vless  "$username" "$days" "$ip_limit" "$quota_mb" "$trial_hours") ;;
      trojan) secret=$(create_trojan "$username" "$days" "$ip_limit" "$quota_mb" "$trial_hours") ;;
      ss)     secret=$(create_ss     "$username" "$days" "$ip_limit" "$quota_mb" "$trial_hours") ;;
      sshws)  secret=$(create_ssh    "$username" "$days" "$custom_password" "$ip_limit" "$quota_mb" "$trial_hours") ;;
      *) json_err "protokol tidak dikenal: $proto" ;;
    esac
    json_ok_secret "$secret"
    ;;

  delete_account)
    proto="${2:-}"; username="${3:-}"
    [[ -z "$proto" || -z "$username" ]] && json_err "proto dan username wajib diisi"
    case "$proto" in
      vmess)  delete_vmess  "$username" ;;
      vless)  delete_vless  "$username" ;;
      trojan) delete_trojan "$username" ;;
      ss)     delete_ss     "$username" ;;
      sshws)
        valid_user "$username" || json_err "username tidak valid"
        # putuskan sesi SSH/OpenVPN yang masih jalan sebelum akun dihapus
        [[ -f "$SCRIPT_DIR/menu/tools.sh" ]] && bash "$SCRIPT_DIR/menu/tools.sh" kick-ssh "$username" -y >/dev/null 2>&1 || true
        delete_ssh "$username" ;;
      *) json_err "protokol tidak dikenal: $proto" ;;
    esac
    echo '{"ok":true}'
    ;;

  toggle_service)
    svc="${2:-}"; action="${3:-}"
    unit="${SVC_UNIT[$svc]:-}"
    [[ -n "$unit" ]] || json_err "layanan tidak diizinkan: $svc"
    unit_exists "$unit" || json_err "layanan belum terpasang: $svc"
    [[ "$action" == "start" || "$action" == "stop" || "$action" == "restart" ]] || json_err "aksi tidak dikenal"
    systemctl "$action" "$unit" 2>/dev/null || true
    sleep 1
    state=$(systemctl is-active "$unit" 2>/dev/null || true)
    jq -n --arg svc "$svc" --arg state "$state" '{ok:true, service:$svc, state:$state}'
    ;;

  get_link)
    proto="${2:-}"; username="${3:-}"
    [[ -z "$proto" || -z "$username" ]] && json_err "proto dan username wajib diisi"
    domain=$(get_domain)
    fmt_quota() { [[ "${1:-0}" == "0" ]] && echo "Unlimited" || echo "$(( $1 / 1024 )) GB"; }
    fmt_limit() { [[ "${1:-0}" == "0" ]] && echo "Unlimited" || echo "$1"; }
    case "$proto" in
      vmess)
        row=$(grep "^$username|" "$DB_VMESS" 2>/dev/null); [[ -z "$row" ]] && json_err "akun tidak ditemukan"
        IFS='|' read -r u secret exp created ip_limit quota_mb <<< "$row"
        l_tls=$(gen_vmess_link "$username" "$secret" "$domain" tls "")
        l_ntls=$(gen_vmess_link "$username" "$secret" "$domain" ntls "")
        detail="✅ AKUN VMESS
Username        : $username
UUID            : $secret
Domain          : $domain
Expired         : $exp
Limit Device/IP : $(fmt_limit "$ip_limit")
Limit Kuota     : $(fmt_quota "$quota_mb")

── WS TLS (443, path /vmess-ws) ──
$l_tls

── WS nTLS (80, path /vmess-ntls) ──
$l_ntls"
        ;;
      vless)
        row=$(grep "^$username|" "$DB_VLESS" 2>/dev/null); [[ -z "$row" ]] && json_err "akun tidak ditemukan"
        IFS='|' read -r u secret exp created ip_limit quota_mb <<< "$row"
        l_tls=$(gen_vless_link "$username" "$secret" "$domain" tls "")
        l_ntls=$(gen_vless_link "$username" "$secret" "$domain" ntls "")
        l_grpc="vless://${secret}@${domain}:443?encryption=none&security=tls&type=grpc&serviceName=vless-grpc&sni=${domain}#${username}-vless-grpc"
        detail="✅ AKUN VLESS
Username        : $username
UUID            : $secret
Domain          : $domain
Expired         : $exp
Limit Device/IP : $(fmt_limit "$ip_limit")
Limit Kuota     : $(fmt_quota "$quota_mb")

── WS TLS (443, path /vless-ws) ──
$l_tls

── WS nTLS (80, path /vless-ntls) ──
$l_ntls

── gRPC TLS (443, service vless-grpc) ──
$l_grpc"
        ;;
      trojan)
        row=$(grep "^$username|" "$DB_TROJAN" 2>/dev/null); [[ -z "$row" ]] && json_err "akun tidak ditemukan"
        IFS='|' read -r u secret exp created ip_limit quota_mb <<< "$row"
        l_ws=$(gen_trojan_link "$username" "$secret" "$domain" ws "")
        l_grpc=$(gen_trojan_link "$username" "$secret" "$domain" grpc "")
        detail="✅ AKUN TROJAN
Username        : $username
Password        : $secret
Domain          : $domain
Expired         : $exp
Limit Device/IP : $(fmt_limit "$ip_limit")
Limit Kuota     : $(fmt_quota "$quota_mb")

── WS TLS (443, path /trojan-ws) ──
$l_ws

── gRPC TLS (443, service trojan-grpc) ──
$l_grpc"
        ;;
      ss)
        row=$(grep "^$username|" "$DB_SS" 2>/dev/null); [[ -z "$row" ]] && json_err "akun tidak ditemukan"
        IFS='|' read -r u secret method exp created ip_limit quota_mb <<< "$row"
        l_ws=$(gen_ss_link "$username" "$secret" "$domain" ws "")
        l_grpc=$(gen_ss_link "$username" "$secret" "$domain" grpc "")
        detail="✅ AKUN SHADOWSOCKS
Username        : $username
Password        : $secret
Method          : $method
Domain          : $domain
Expired         : $exp
Limit Device/IP : $(fmt_limit "$ip_limit")
Limit Kuota     : $(fmt_quota "$quota_mb")

── WS TLS (443, path /ss-ws) ──
$l_ws

── gRPC TLS (443, service ss-grpc) ──
$l_grpc"
        ;;
      sshws)
        row=$(grep "^$username|" "$DB_SSH" 2>/dev/null); [[ -z "$row" ]] && json_err "akun tidak ditemukan"
        IFS='|' read -r u secret exp created ip_limit quota_mb <<< "$row"
        detail="✅ AKUN SSH
Username        : $username
Password        : $secret
Domain/IP       : $domain
Expired         : $exp
Limit Sesi      : $(fmt_limit "$ip_limit")
Limit Kuota     : $(fmt_quota "$quota_mb")

── Port Koneksi ──
SSH Direct   : 442 / 109 / 143
SSH-SSL      : $STUNNEL_SSL_PORT (Dropbear) / $HAPROXY_SSL_PORT (OpenSSH) — SNI bebas, tanpa payload
SSH-WS nTLS  : 80 / 8880 / 8080 / 2080 / 2082
SSH-WS TLS   : 443
Path         : /ssh-ws (Dropbear) atau /ssh-ws-ssh (OpenSSH)

── Payload WS ──
Dropbear:
GET /ssh-ws HTTP/1.1[crlf]Host: $domain[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]

OpenSSH:
GET /ssh-ws-ssh HTTP/1.1[crlf]Host: $domain[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]"
        if ovpn_installed; then
          TCP_PORT=1194; UDP_PORT=2200
          [[ -f "$OVPN_CONF_FILE" ]] && source "$OVPN_CONF_FILE"
          detail+="

── OpenVPN (login sama dengan akun SSH ini) ──
TCP          : $TCP_PORT
UDP          : $UDP_PORT
WS nTLS      : 80  (path /ovpn-ws, butuh aplikasi dengan payload)
WS TLS       : 443 (path /ovpn-ws, SNI $domain)
File .ovpn   : lihat tombol download di bawah (link berlaku 60 menit)"
        fi
        ;;
      *) json_err "protokol tidak dikenal: $proto" ;;
    esac
    jq -n --arg detail "$detail" '{ok:true, type:"detail", detail:$detail}'
    ;;

  renew_account)
    proto="${2:-}"; username="${3:-}"; days="${4:-30}"
    [[ -z "$proto" || -z "$username" ]] && json_err "proto dan username wajib diisi"
    case "$proto" in
      vmess)  renew_vmess  "$username" "$days" ;;
      vless)  renew_vless  "$username" "$days" ;;
      trojan) renew_trojan "$username" "$days" ;;
      ss)     renew_ss     "$username" "$days" ;;
      sshws)  renew_ssh    "$username" "$days" ;;
      *) json_err "protokol tidak dikenal: $proto" ;;
    esac
    echo '{"ok":true}'
    ;;

  edit_limits)
    proto="${2:-}"; username="${3:-}"; ip_limit="${4:-2}"; quota_gb="${5:-0}"
    [[ -z "$proto" || -z "$username" ]] && json_err "proto dan username wajib diisi"
    quota_mb=$(( ${quota_gb%.*} * 1024 ))
    case "$proto" in
      vmess)  edit_vmess_limits  "$username" "$ip_limit" "$quota_mb" ;;
      vless)  edit_vless_limits  "$username" "$ip_limit" "$quota_mb" ;;
      trojan) edit_trojan_limits "$username" "$ip_limit" "$quota_mb" ;;
      ss)     edit_ss_limits     "$username" "$ip_limit" "$quota_mb" ;;
      sshws)  edit_ssh_limits    "$username" "$ip_limit" "$quota_mb" ;;
      *) json_err "protokol tidak dikenal: $proto" ;;
    esac
    echo '{"ok":true}'
    ;;

  ovpn_links)
    username="${2:-}"
    valid_user "$username" || json_err "username tidak valid"
    ovpn_installed || json_err "OpenVPN belum terpasang di VPS (menu 16 → Install OpenVPN)"
    grep -q "^$username|" "$DB_SSH" 2>/dev/null || json_err "akun SSH tidak ditemukan"
    [[ -f "$SCRIPT_DIR/menu/openvpn.sh" ]] || json_err "menu/openvpn.sh tidak ada, update script VPN dulu"
    out=$(timeout 40 bash "$SCRIPT_DIR/menu/openvpn.sh" dl-json "$username" 2>/dev/null)
    jq -e . >/dev/null 2>&1 <<< "$out" || json_err "script VPN belum mendukung link otomatis, update script VPN (menu/openvpn.sh) dulu"
    printf '%s\n' "$out"
    ;;

  online)
    [[ -f "$SCRIPT_DIR/menu/tools.sh" ]] || json_err "menu/tools.sh tidak ada, update script VPN dulu"
    out=$(timeout 40 bash "$SCRIPT_DIR/menu/tools.sh" online-json 2>/dev/null)
    jq -e . >/dev/null 2>&1 <<< "$out" || json_err "script VPN belum mendukung daftar online, update script VPN (menu/tools.sh) dulu"
    printf '%s\n' "$out"
    ;;

  kick)
    username="${2:-}"
    valid_user "$username" || json_err "username tidak valid"
    grep -q "^$username|" "$DB_SSH" 2>/dev/null || json_err "bukan akun SSH terdaftar"
    [[ -f "$SCRIPT_DIR/menu/tools.sh" ]] || json_err "menu/tools.sh tidak ada, update script VPN dulu"
    raw=$(timeout 30 bash "$SCRIPT_DIR/menu/tools.sh" kick-ssh "$username" -y 2>&1); rc=$?
    msg=$(strip_ansi <<< "$raw" | sed 's/^ *//' | paste -sd' ' -)
    jq -n --arg m "$msg" --argjson ok "$([[ $rc -eq 0 ]] && echo true || echo false)" '{ok:$ok, message:$m, error:(if $ok then null else $m end)}'
    ;;

  security_status)
    f2b_inst=false; f2b_act=false; banned='[]'
    if command -v fail2ban-client >/dev/null 2>&1; then
      f2b_inst=true
      if systemctl is-active --quiet fail2ban 2>/dev/null; then
        f2b_act=true
        for jail in sshd dropbear; do
          o=$(fail2ban-client status "$jail" 2>/dev/null) || continue
          list=$(sed -n 's/.*Banned IP list:[[:space:]]*//p' <<< "$o")
          for ip in $list; do banned=$(jq -c --arg ip "$ip" --arg j "$jail" '. + [{ip:$ip,jail:$j}]' <<< "$banned"); done
        done
      fi
    fi
    t_flag=false; [[ -f "$SCRIPT_DIR/.torrent-block-on" ]] && t_flag=true
    jq -n --argjson fi "$f2b_inst" --argjson fa "$f2b_act" --argjson banned "$banned" --argjson tor "$t_flag" \
      --arg cc "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo -)" \
      --arg qd "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo -)" \
      --arg v6 "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo -)" \
      '{ok:true, torrent_block:$tor,
        fail2ban:{installed:$fi, active:$fa, banned:$banned},
        bbr:{congestion:$cc, qdisc:$qd, enabled:($cc=="bbr")},
        ipv6_disabled:($v6=="1")}'
    ;;

  torrent)
    mode="${2:-}"
    [[ "$mode" == "on" || "$mode" == "off" ]] || json_err "mode harus on atau off"
    [[ -f "$SCRIPT_DIR/addon/torrent-block.sh" ]] || json_err "addon/torrent-block.sh tidak ada, update script VPN dulu"
    raw=$(timeout 60 bash "$SCRIPT_DIR/addon/torrent-block.sh" "$mode" -y 2>&1); rc=$?
    msg=$(strip_ansi <<< "$raw" | sed 's/^ *//' | paste -sd' ' -)
    t_flag=false; [[ -f "$SCRIPT_DIR/.torrent-block-on" ]] && t_flag=true
    jq -n --arg m "$msg" --argjson t "$t_flag" --argjson ok "$([[ $rc -eq 0 ]] && echo true || echo false)" \
      '{ok:$ok, message:$m, torrent_block:$t, error:(if $ok then null else $m end)}'
    ;;

  f2b_unban)
    ip="${2:-}"
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || "$ip" =~ ^[0-9a-fA-F:]+$ ]] || json_err "format IP tidak valid"
    [[ -f "$SCRIPT_DIR/menu/security.sh" ]] || json_err "menu/security.sh tidak ada, update script VPN dulu"
    raw=$(timeout 30 bash "$SCRIPT_DIR/menu/security.sh" f2b-unban "$ip" -y 2>&1); rc=$?
    msg=$(strip_ansi <<< "$raw" | sed 's/^ *//' | paste -sd' ' -)
    jq -n --arg m "$msg" --argjson ok "$([[ $rc -eq 0 ]] && echo true || echo false)" '{ok:$ok, message:$m, error:(if $ok then null else $m end)}'
    ;;

  # ── V8: aksi tambahan ──────────────────────────────────────────
  --sample)
    hist_sample
    ;;

  --job)
    name="${2:-}"; f=$(job_file "$name")
    case "$name" in
      speedtest) res=$(do_speedtest) ;;
      backup)    res=$(do_backup) ;;
      ssl_renew) res=$(do_ssl_renew) ;;
      *) exit 1 ;;
    esac
    jq -e . >/dev/null 2>&1 <<< "$res" || res='{"ok":false,"error":"hasil tidak valid"}'
    jq -cn --argjson r "$res" --argjson t "$(date +%s)" '{state:(if $r.ok then "done" else "error" end), ts:$t, result:$r}' > "$f.tmp" && mv "$f.tmp" "$f"
    jok=$(jq -r '.ok // false' <<< "$res"); [[ "$jok" == "true" ]] || jok=false
    case "$name" in
      speedtest) act_log "Speedtest" "Ookla" "$jok" "$(jq -r 'if .ok then "↓\(.down) ↑\(.up) Mbps, ping \(.ping) ms" else (.error // "") end' <<< "$res" | cut -c1-120)" ;;
      backup)    act_log "Backup ke Telegram" "semua data" "$jok" "$(jq -r '.error // empty' <<< "$res" | cut -c1-120)" ;;
      ssl_renew) act_log "Perpanjang SSL" "$(get_domain)" "$jok" "$(jq -r '.error // empty' <<< "$res" | cut -c1-120)" ;;
    esac
    ;;

  speedtest)  job_start speedtest ;;
  backup_now) job_start backup ;;
  ssl_renew)  job_start ssl_renew ;;

  job_status)
    name="${2:-}"
    [[ "$name" == "speedtest" || "$name" == "backup" || "$name" == "ssl_renew" ]] || json_err "nama job tidak dikenal"
    job_status "$name"
    ;;

  speedtest_live)
    # progres realtime dari file jsonl Ookla (dibaca panel tiap ±0,7 detik)
    last=$(tail -n1 "$SPEED_LIVE" 2>/dev/null)
    srv=$(grep -m1 '"type":"testStart"' "$SPEED_LIVE" 2>/dev/null | jq -r '(.server.name // "")+" · "+(.server.location // "")' 2>/dev/null)
    if [[ -z "$last" ]] || ! jq -e . >/dev/null 2>&1 <<< "$last"; then
      jq -n --arg s "${srv:-}" '{ok:true, phase:"start", mbps:0, progress:0, server:$s}'
    else
      jq -c --arg s "${srv:-}" '{ok:true, phase:(.type // "start"), server:$s,
        mbps:((if .type=="download" then .download.bandwidth elif .type=="upload" then .upload.bandwidth else 0 end)*8/1000000*10|round/10),
        ping:(if .type=="ping" then (.ping.latency*10|round/10) else null end),
        progress:((if .type=="ping" then .ping.progress elif .type=="download" then .download.progress elif .type=="upload" then .upload.progress elif .type=="result" then 1 else 0 end)*100|round)}' <<< "$last"
    fi
    ;;

  host2ip)
    h="${2:-}"; h="${h,,}"; h="${h#http://}"; h="${h#https://}"; h="${h%%/*}"; h="${h%%:*}"
    [[ "$h" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ || "$h" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || json_err "format host tidak valid (contoh: listen.noice.id)"
    v4=$(getent ahostsv4 "$h" 2>/dev/null | awk '{print $1}' | sort -u)
    v6=$(getent ahostsv6 "$h" 2>/dev/null | awk '{print $1}' | sort -u)
    if [[ -z "$v4" && -z "$v6" ]] && command -v dig >/dev/null 2>&1; then
      v4=$(dig +short +time=3 +tries=1 A "$h" 2>/dev/null | grep -E '^[0-9.]+$' | sort -u)
      v6=$(dig +short +time=3 +tries=1 AAAA "$h" 2>/dev/null | grep -E ':' | sort -u)
    fi
    cn=""; command -v dig >/dev/null 2>&1 && cn=$(dig +short +time=3 +tries=1 CNAME "$h" 2>/dev/null | head -n1 | sed 's/\.$//')
    [[ -n "$v4$v6" ]] || json_err "host tidak ditemukan / tidak punya IP"
    jq -n --arg h "$h" --arg cn "$cn" --arg me "$(get_server_ip)" \
      --argjson v4 "$(printf '%s\n' "$v4" | jq -Rn '[inputs|select(length>0)]')" \
      --argjson v6 "$(printf '%s\n' "$v6" | jq -Rn '[inputs|select(length>0)]')" \
      '{ok:true, host:$h, cname:$cn, ipv4:$v4, ipv6:$v6, points_to_server:(($v4|index($me)) != null)}'
    ;;

  history)
    tail -n 300 "$HIST_LOG" 2>/dev/null | jq -cs '{ok:true, samples:.}' 2>/dev/null || echo '{"ok":true,"samples":[]}'
    ;;

  activity)
    tail -n 60 "$ACT_LOG" 2>/dev/null | jq -cs '{ok:true, items:(. | reverse)}' 2>/dev/null || echo '{"ok":true,"items":[]}'
    ;;

  tg_get)
    jq -c '. + {ok:true}' <<< "$(tg_json)"
    ;;

  tg_set)
    new_tok="${2:-}"; new_chat="${3:-}"
    if [[ -n "$new_tok" ]]; then
      [[ "$new_tok" =~ ^[0-9]{5,15}:[A-Za-z0-9_-]{30,60}$ ]] || json_err "format Bot Token tidak valid"
      TELEGRAM_BOT_TOKEN="$new_tok"
    fi
    if [[ -n "$new_chat" ]]; then
      [[ "$new_chat" =~ ^-?[0-9]{3,20}$ ]] || json_err "Chat ID harus berupa angka"
      TELEGRAM_CHAT_ID="$new_chat"
    fi
    [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] || json_err "Bot Token dan Chat ID harus terisi"
    # cek token ke Telegram: 401/404 = token salah (tidak disimpan); gagal jaringan = tetap simpan
    gm=$(curl -sS --max-time 8 -o /tmp/.tg_getme.$$ -w '%{http_code}' "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" 2>/dev/null || echo 000)
    bot_name=$(jq -r '.result.username // empty' /tmp/.tg_getme.$$ 2>/dev/null); rm -f /tmp/.tg_getme.$$
    if [[ "$gm" == "401" || "$gm" == "404" ]]; then json_err "Token ditolak Telegram (salah / sudah di-revoke). Tidak disimpan."; fi
    save_pro_config
    if [[ -f "$SCRIPT_DIR/menu/backup.sh" ]]; then
      bash "$SCRIPT_DIR/menu/backup.sh" install >/dev/null 2>&1 || true
      systemctl restart tg-backup-bot >/dev/null 2>&1 || true
    fi
    jq -n --arg bn "$bot_name" --arg code "$gm" --argjson tg "$(tg_json)" \
      '{ok:true, bot_name:$bn, verified:($code=="200"), telegram:$tg}'
    ;;

  *)
    json_err "aksi tidak dikenal: ${1:-<kosong>}"
    ;;
esac
