#!/usr/bin/env bash
# Zapret VN для Linux 1.0.0
#
# Обход DPI-блокировок (Steam, Roblox, Telegram и др.) без VPN.
# Обёртка вокруг официального nfqws из zapret v72.13 (https://github.com/bol-van/zapret, MIT).
# Стратегии и списки доменов — те же, что в Windows-версии Zapret VN (https://github.com/MrMe0ws/zapret-vietnam, MIT).
#
# Нужны: root, ядро с NFQUEUE (nfnetlink_queue), nftables или iptables, curl.
# Справка: ./zapret-vn.sh help

set -u

# printf должен считать символы, а не байты (иначе таблица в `check` съезжает)
case "${LC_ALL:-${LANG:-}}" in *UTF-8*|*utf8*|*UTF8*) ;; *) export LC_ALL=C.UTF-8 ;; esac

VERSION="1.0.0"
ZAPRET_VERSION="v72.13"

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
ROOT="$(dirname "$SELF")"
ORIG_ARGS=("$@")

BIN_DIR="$ROOT/bin"
FAKE="$ROOT/fake"
LISTS="$ROOT/lists"
CONF_DIR="$ROOT/config"
CONF="$CONF_DIR/settings.conf"
LOG="$ROOT/zapret-vn.log"
PIDFILE="/run/zapret-vn.pid"
LIBERAL_SAVE="/run/zapret-vn.liberal"

QNUM="${ZVN_QNUM:-200}"          # номер очереди NFQUEUE
MARK="0x40000000"                # метка пакетов, созданных самим nfqws (значение по умолчанию в nfqws)
TABLE="zapret_vn"                # имя таблицы nftables
RUN_USER="${ZVN_USER:-nobody}"   # от чьего имени работает nfqws после старта
UNIT="/etc/systemd/system/zapret-vn.service"
DEFAULT_STRATEGY="multidisorder"

# ----------------------------------------------------------------------------- стратегии
# Порядок = приоритет при автоподборе (как в Windows-версии). {FAKE} заменяется на папку fake/.
FAKE_TLS="{FAKE}/tls_clienthello_www_google_com.bin"
STRAT_IDS=(multidisorder fake_multidisorder fake_multisplit multisplit multisplit_sni fakedsplit fake_fakedsplit fake_autottl fake_md5sig seqovl)
declare -A STRAT_TITLE=(
  [multidisorder]="Multidisorder (лучшая для FPT)"
  [fake_multidisorder]="Fake + multidisorder (badseq)"
  [fake_multisplit]="Fake + multisplit (badseq)"
  [multisplit]="Multisplit"
  [multisplit_sni]="Multisplit по SNI"
  [fakedsplit]="Fakedsplit (badseq)"
  [fake_fakedsplit]="Fake + fakedsplit (autottl)"
  [fake_autottl]="Fake (autottl)"
  [fake_md5sig]="Fake (md5sig)"
  [seqovl]="Seqovl 681"
)
declare -A STRAT_ARGS=(
  [multidisorder]="--dpi-desync=multidisorder --dpi-desync-split-pos=1,midsld"
  [fake_multidisorder]="--dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-fooling=badseq --dpi-desync-fake-tls=$FAKE_TLS"
  [fake_multisplit]="--dpi-desync=fake,multisplit --dpi-desync-split-pos=1,midsld --dpi-desync-fooling=badseq --dpi-desync-fake-tls=$FAKE_TLS"
  [multisplit]="--dpi-desync=multisplit --dpi-desync-split-pos=1,midsld"
  [multisplit_sni]="--dpi-desync=multisplit --dpi-desync-split-pos=1,sniext+1,host+1,midsld"
  [fakedsplit]="--dpi-desync=fakedsplit --dpi-desync-split-pos=1 --dpi-desync-fooling=badseq"
  [fake_fakedsplit]="--dpi-desync=fake,fakedsplit --dpi-desync-autottl=5 --dpi-desync-split-pos=1 --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com"
  [fake_autottl]="--dpi-desync=fake --dpi-desync-autottl=2 --dpi-desync-repeats=6 --dpi-desync-fake-tls=$FAKE_TLS"
  [fake_md5sig]="--dpi-desync=fake --dpi-desync-fooling=md5sig --dpi-desync-fake-tls=$FAKE_TLS"
  [seqovl]="--dpi-desync=multisplit --dpi-desync-split-seqovl=681 --dpi-desync-split-pos=1 --dpi-desync-split-seqovl-pattern=$FAKE_TLS"
)

# что показывать в `check`: подпись|хост
SITES=(
  "Steam — магазин|store.steampowered.com"
  "Steam — сообщество|steamcommunity.com"
  "Steam — поддержка|help.steampowered.com"
  "Steam — оплата|checkout.steampowered.com"
  "Steam — картинки|store.fastly.steamstatic.com"
  "Steam — чат|steam-chat.com"
  "Roblox — API|apis.roblox.com"
  "Roblox — вход в игру|gamejoin.roblox.com"
  "Roblox — друзья и чат|realtime-signalr.roblox.com"
  "Telegram Web|web.telegram.org"
  "Discord|discord.com"
)
# для автоподбора стратегии
PICK_HOSTS=(
  store.steampowered.com steamcommunity.com help.steampowered.com checkout.steampowered.com
  store.fastly.steamstatic.com steam-chat.com apis.roblox.com gamejoin.roblox.com web.telegram.org
)

# ----------------------------------------------------------------------------- утилиты
say()  { printf '%s\n' "$*"; }
warn() { printf 'Предупреждение: %s\n' "$*" >&2; }
die()  { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }

ensure_root() {
  [ "$(id -u)" -eq 0 ] && return 0
  command -v sudo >/dev/null 2>&1 || die "нужны права root (sudo не найден)"
  exec sudo -- "$SELF" "${ORIG_ARGS[@]}"
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "не найдена команда '$1'"; }

check_path() {
  case "$ROOT" in
    *[[:space:]]*) die "в пути к программе есть пробелы ($ROOT) — перенесите её, например, в /opt/zapret-vn" ;;
  esac
}

valid_host() { [[ "$1" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; }

read_domains() { [ -r "$1" ] && grep -v -E '^[[:space:]]*(#|;|$)' "$1" | tr 'A-Z' 'a-z'; return 0; }

nfqws_bin() {
  if [ -n "${ZVN_NFQWS:-}" ]; then printf '%s\n' "$ZVN_NFQWS"; return 0; fi
  case "$(uname -m)" in
    x86_64|amd64)  printf '%s\n' "$BIN_DIR/nfqws-x86_64" ;;
    aarch64|arm64) printf '%s\n' "$BIN_DIR/nfqws-arm64" ;;
    *) die "архитектура $(uname -m) не входит в пакет: возьмите nfqws из релиза zapret $ZAPRET_VERSION и задайте ZVN_NFQWS=/путь/к/nfqws" ;;
  esac
}

# ----------------------------------------------------------------------------- настройки
get_strategy() {
  local s=""
  [ -r "$CONF" ] && s="$(sed -n 's/^STRATEGY=//p' "$CONF" | tail -n1)"
  s="${s:-$DEFAULT_STRATEGY}"
  [ -n "${STRAT_ARGS[$s]+x}" ] || s="$DEFAULT_STRATEGY"
  printf '%s\n' "$s"
}

set_strategy() {
  mkdir -p "$CONF_DIR" && printf 'STRATEGY=%s\n' "$1" > "$CONF" || die "не удалось записать $CONF"
}

# Заполняет глобальный массив NFQWS_ARGS
build_args() {
  local tcp_str tcp_arr
  tcp_str="${STRAT_ARGS[$(get_strategy)]}"
  tcp_str="${tcp_str//\{FAKE\}/$FAKE}"
  read -r -a tcp_arr <<< "$tcp_str"
  NFQWS_ARGS=("--qnum=$QNUM")
  if [ "$RUN_USER" = root ]; then NFQWS_ARGS+=("--uid=0:0")
  elif id -u "$RUN_USER" >/dev/null 2>&1; then NFQWS_ARGS+=("--user=$RUN_USER"); fi
  NFQWS_ARGS+=(
    --filter-tcp=80,443
    "--hostlist=$LISTS/vietnam.txt" "--hostlist-exclude=$LISTS/exclude.txt"
    "--hostlist-auto=$LISTS/autohostlist.txt" --hostlist-auto-fail-threshold=3
    "${tcp_arr[@]}"
    --new --filter-udp=443
    "--hostlist=$LISTS/vietnam.txt" "--hostlist-exclude=$LISTS/exclude.txt"
    --dpi-desync=fake --dpi-desync-repeats=6
    "--dpi-desync-fake-quic=$FAKE/quic_initial_www_google_com.bin"
  )
}

prepare_files() {
  mkdir -p "$LISTS" "$CONF_DIR"
  [ -e "$LISTS/vietnam.txt" ]      || : > "$LISTS/vietnam.txt"
  [ -e "$LISTS/exclude.txt" ]      || : > "$LISTS/exclude.txt"
  [ -e "$LISTS/autohostlist.txt" ] || : > "$LISTS/autohostlist.txt"
  # nfqws сбрасывает права ДО чтения списков, поэтому они (и все каталоги на пути к ним) должны быть читаемы его пользователем;
  # автосписок nfqws при старте сам передаёт своему пользователю, чтобы дописывать найденные домены
  chmod 644 "$LISTS/vietnam.txt" "$LISTS/exclude.txt" "$LISTS/autohostlist.txt" 2>/dev/null
  chmod 755 "$ROOT" "$LISTS" "$FAKE" 2>/dev/null
  chmod 644 "$FAKE"/*.bin 2>/dev/null
}

# ----------------------------------------------------------------------------- файрвол
fw_backend() {
  case "${ZVN_FW:-auto}" in
    nft|iptables) printf '%s\n' "$ZVN_FW"; return 0 ;;
  esac
  if command -v nft >/dev/null 2>&1; then printf 'nft\n'
  elif command -v iptables >/dev/null 2>&1; then printf 'iptables\n'
  else printf 'none\n'; fi
}

# Правила nftables. Тот же принцип, что в официальных скриптах zapret:
#  * в очередь уходят только первые пакеты соединения (ct original packets 1-9) — нагрузка минимальна;
#  * пакеты с меткой nfqws пропускаются (иначе петля);
#  * входящие пакеты (первые 3) нужны для автосписка — чтобы nfqws видел RST/обрывы;
#  * пакеты, сгенерированные nfqws, не отслеживаются conntrack (фрагменты, данные без ACK) — иначе их дропнет INVALID.
nft_rules() {
  cat <<EOF
table inet $TABLE {
	chain post {
		type filter hook postrouting priority 99; policy accept;
		meta mark & $MARK == 0 tcp dport { 80, 443 } ct original packets 1-9 queue num $QNUM bypass
		meta mark & $MARK == 0 udp dport 443 ct original packets 1-9 queue num $QNUM bypass
	}
	chain pre {
		type filter hook prerouting priority -99; policy accept;
		tcp sport { 80, 443 } ct reply packets 1-3 queue num $QNUM bypass
	}
	chain predefrag {
		type filter hook output priority -401; policy accept;
		meta mark & $MARK != 0 jump predefrag_nfqws
	}
	chain predefrag_nfqws {
		ip frag-off & 0x1fff != 0 notrack
		exthdr frag exists notrack
		tcp flags ! syn,rst,ack notrack
	}
}
EOF
}

# Правила iptables: "цепочка|условие"
ipt_specs() {
  local o="-m connbytes --connbytes-dir=original --connbytes-mode=packets --connbytes 1:9"
  local r="-m connbytes --connbytes-dir=reply --connbytes-mode=packets --connbytes 1:3"
  local q="-j NFQUEUE --queue-num $QNUM --queue-bypass"
  printf '%s\n' \
    "POSTROUTING|-p tcp -m multiport --dports 80,443 $o -m mark ! --mark $MARK/$MARK $q" \
    "POSTROUTING|-p udp --dport 443 $o -m mark ! --mark $MARK/$MARK $q" \
    "PREROUTING|-p tcp -m multiport --sports 80,443 $r $q"
}

# $1 = -I | -D, $2 = iptables | ip6tables
ipt_apply() {
  local op=$1 tool=$2 chain spec rc=0
  command -v "$tool" >/dev/null 2>&1 || return 0
  while IFS='|' read -r chain spec; do
    if [ "$op" = "-D" ]; then
      # удаляем все копии правила (на случай повторных запусков)
      # shellcheck disable=SC2086
      while "$tool" -t mangle -D "$chain" $spec 2>/dev/null; do :; done
    else
      # shellcheck disable=SC2086
      "$tool" -t mangle -I "$chain" $spec || rc=1
    fi
  done < <(ipt_specs)
  return "$rc"
}

liberal_on() {
  # DPI часто шлёт RST с неверным ACK; conntrack считает его INVALID и правило connbytes не отдаёт его nfqws
  local v
  v="$(sysctl -n net.netfilter.nf_conntrack_tcp_be_liberal 2>/dev/null)" || return 0
  [ -e "$LIBERAL_SAVE" ] || printf '%s\n' "$v" > "$LIBERAL_SAVE"
  sysctl -qw net.netfilter.nf_conntrack_tcp_be_liberal=1 >/dev/null 2>&1
  return 0
}

liberal_off() {
  [ -r "$LIBERAL_SAVE" ] || return 0
  sysctl -qw net.netfilter.nf_conntrack_tcp_be_liberal="$(cat "$LIBERAL_SAVE")" >/dev/null 2>&1
  rm -f "$LIBERAL_SAVE"
  return 0
}

fw_del() {
  nft delete table inet "$TABLE" >/dev/null 2>&1
  ipt_apply -D iptables
  ipt_apply -D ip6tables
  liberal_off
  return 0
}

fw_add() {
  fw_del
  case "$(fw_backend)" in
    nft)
      nft_rules | nft -f - || { warn "nftables не принял правила"; return 1; } ;;
    iptables)
      ipt_apply -I iptables || { fw_del; warn "iptables не принял правила"; return 1; }
      ipt_apply -I ip6tables || warn "ip6tables: правила для IPv6 не применились (IPv6-трафик пойдёт без обхода)" ;;
    *)
      warn "не найдены ни nft, ни iptables"; return 1 ;;
  esac
  liberal_on
  return 0
}

# ----------------------------------------------------------------------------- запуск / остановка
CHILD=""

cleanup() {
  trap - EXIT INT TERM
  if [ -n "$CHILD" ]; then kill "$CHILD" 2>/dev/null; wait "$CHILD" 2>/dev/null; fi
  fw_del
  rm -f "$PIDFILE"
}

# Работа на переднем плане: правила + nfqws. Так запускает systemd; `start` без systemd — то же в фоне.
cmd_run() {
  ensure_root
  check_path
  local nfqws; nfqws="$(nfqws_bin)"
  [ -x "$nfqws" ] || die "не найден или не исполняемый: $nfqws"
  prepare_files
  build_args
  if [ "$RUN_USER" != root ] && id -u "$RUN_USER" >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1 \
     && ! runuser -u "$RUN_USER" -- test -r "$LISTS/vietnam.txt" 2>/dev/null; then
    die "пользователь '$RUN_USER' (от него работает nfqws) не может читать $LISTS — вероятно, папка лежит в домашнем каталоге или в /root.
       Решение: sudo $SELF install   (поставит программу в /opt/zapret-vn)
       или запустите с ZVN_USER=root (работает, но менее безопасно)."
  fi
  trap cleanup EXIT
  trap 'exit 143' INT TERM
  fw_add || exit 1
  printf '%s\n' "$$" > "$PIDFILE"
  say "$(date '+%F %T')  Zapret VN: стратегия $(get_strategy), файрвол $(fw_backend), очередь $QNUM"
  "$nfqws" "${NFQWS_ARGS[@]}" &
  CHILD=$!
  wait "$CHILD"
  local rc=$?
  CHILD=""
  say "$(date '+%F %T')  nfqws завершился (код $rc)"
  exit "$rc"
}

unit_installed() { [ -e "$UNIT" ] && command -v systemctl >/dev/null 2>&1; }

is_running() {
  if unit_installed && systemctl is-active --quiet zapret-vn 2>/dev/null; then return 0; fi
  [ -r "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
}

cmd_start() {
  ensure_root
  check_path
  if is_running; then say "Уже запущено."; return 0; fi
  if unit_installed; then
    systemctl start zapret-vn || die "не удалось запустить службу (journalctl -u zapret-vn)"
  else
    : >> "$LOG"
    if command -v setsid >/dev/null 2>&1; then
      setsid -f "$SELF" run >> "$LOG" 2>&1 < /dev/null
    else
      nohup "$SELF" run >> "$LOG" 2>&1 < /dev/null &
    fi
  fi
  local i
  for i in 1 2 3 4 5 6 7 8; do sleep 0.5; is_running && break; done
  sleep 1
  is_running || { tail -n 5 "$LOG" 2>/dev/null; die "обход не запустился (подробности: $LOG или journalctl -u zapret-vn)"; }
  say "Обход включён. Стратегия: $(get_strategy) — ${STRAT_TITLE[$(get_strategy)]}"
}

cmd_stop() {
  ensure_root
  if unit_installed && systemctl is-active --quiet zapret-vn 2>/dev/null; then
    systemctl stop zapret-vn
  elif [ -r "$PIDFILE" ]; then
    local pid; pid="$(cat "$PIDFILE" 2>/dev/null)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null
      local i; for i in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
      kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
    fi
  fi
  fw_del   # на случай «осиротевших» правил
  rm -f "$PIDFILE"
  say "Обход выключен."
}

cmd_restart() { cmd_stop >/dev/null; cmd_start; }

cmd_status() {
  local s; s="$(get_strategy)"
  if is_running; then say "Обход: ВКЛЮЧЁН"; else say "Обход: выключен"; fi
  say "Стратегия: $s — ${STRAT_TITLE[$s]}"
  say "Файрвол: $(fw_backend), очередь NFQUEUE $QNUM"
  if unit_installed; then
    say "Служба systemd: $(systemctl is-enabled zapret-vn 2>/dev/null || echo не-включена) / $(systemctl is-active zapret-vn 2>/dev/null)"
  else
    say "Служба systemd: не установлена (./zapret-vn.sh install-service)"
  fi
  say "Автосписок: $(read_domains "$LISTS/autohostlist.txt" | wc -l) доменов"
  [ -s "$LOG" ] && { say "--- последние строки журнала ($LOG)"; tail -n 5 "$LOG"; }
  return 0
}

# ----------------------------------------------------------------------------- проверка сайтов
declare -A IPS=()
TMP_DIR=""

mk_tmp() {
  TMP_DIR="$(mktemp -d)" || die "не удалось создать временную папку"
  trap 'rm -rf "$TMP_DIR"' EXIT
}

# resolve_ips <каталог> <хост>... — настоящие адреса через DNS-over-HTTPS (провайдер не может подменить)
resolve_ips() {
  local dir=$1; shift; local h
  for h in "$@"; do valid_host "$h" && ( doh "$h" > "$dir/ip.$h" 2>/dev/null ) & done
  wait
  for h in "$@"; do
    [ -s "$dir/ip.$h" ] && IPS[$h]="$(head -n1 "$dir/ip.$h")"
  done
  return 0
}

doh() {
  local host=$1 url out ip
  for url in "https://dns.google/resolve?type=A&name=$host" "https://cloudflare-dns.com/dns-query?type=A&name=$host"; do
    out="$(curl -s --max-time 6 -H 'accept: application/dns-json' "$url" 2>/dev/null)" || continue
    ip="$(printf '%s' "$out" | grep -oE '"data": ?"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')"
    [ -n "$ip" ] && { printf '%s\n' "$ip"; return 0; }
  done
  return 1
}

# probe <каталог> <раундов> <таймаут> <хост>... — коды curl кладёт в файлы <каталог>/<хост> (по строке на раунд)
probe() {
  local dir=$1 rounds=$2 timeout=$3; shift 3
  local r h
  for ((r = 0; r < rounds; r++)); do
    for h in "$@"; do
      valid_host "$h" || continue
      (
        a=(-s -o /dev/null --noproxy '*' --max-time "$timeout")   # напрямую: проверяем доступность, а не прокси
        [ -n "${IPS[$h]:-}" ] && a+=(--resolve "$h:443:${IPS[$h]}")
        curl "${a[@]}" "https://$h/"
        echo $? >> "$dir/$h"
      ) &
    done
    wait
  done
}

describe() {
  case "$1" in
    0)  echo "открывается" ;;
    6)  echo "адрес не найден (DNS)" ;;
    7)  echo "нет соединения" ;;
    28) echo "не отвечает (таймаут)" ;;
    35) echo "сброс при подключении (DPI)" ;;
    56) echo "соединение сброшено" ;;
    60) echo "ошибка сертификата" ;;
    *)  echo "ошибка $1" ;;
  esac
}

cmd_check() {
  need_cmd curl
  mk_tmp
  local tmp="$TMP_DIR"
  local entries=("${SITES[@]}") d
  while IFS= read -r d; do entries+=("Найдено автоматически|$d"); done < <(read_domains "$LISTS/autohostlist.txt" | head -n 8)
  local hosts=() e
  for e in "${entries[@]}"; do hosts+=("${e#*|}"); done
  say "Проверяю ${#hosts[@]} сайтов..."
  resolve_ips "$tmp" "${hosts[@]}"
  probe "$tmp" 1 8 "${hosts[@]}"
  local ok=0 code mark
  for e in "${entries[@]}"; do
    d="${e#*|}"
    code="$(head -n1 "$tmp/$d" 2>/dev/null || echo 1)"
    if [ "$code" = 0 ]; then ok=$((ok + 1)); mark="✔"; else mark="✖"; fi
    printf '%s  %-28s %-34s %s\n' "$mark" "${e%%|*}" "$d" "$(describe "$code")"
  done
  say "Открывается $ok из ${#entries[@]}"
}

cmd_pick() {
  ensure_root
  need_cmd curl
  mk_tmp
  local tmp="$TMP_DIR"
  say "Подбор стратегии займёт 1–3 минуты, обход на это время будет выключен."
  local prev; prev="$(get_strategy)"
  cmd_stop >/dev/null
  resolve_ips "$tmp" "${PICK_HOSTS[@]}"
  local max=$(( ${#PICK_HOSTS[@]} * 2 ))
  local best="" best_score=-1 id score h c
  for id in "${STRAT_IDS[@]}"; do
    set_strategy "$id"
    printf '  %-34s ' "${STRAT_TITLE[$id]}"
    if ! ( cmd_start ) >/dev/null 2>&1; then say "не запустилась"; continue; fi
    sleep 1
    for h in "${PICK_HOSTS[@]}"; do rm -f "$tmp/$h"; done
    probe "$tmp" 2 6 "${PICK_HOSTS[@]}"
    score=0
    for h in "${PICK_HOSTS[@]}"; do
      while read -r c; do [ "$c" = 0 ] && score=$((score + 1)); done < "$tmp/$h" 2>/dev/null
    done
    say "$score из $max"
    cmd_stop >/dev/null
    if [ "$score" -gt "$best_score" ]; then best_score=$score; best=$id; fi
    [ "$score" -eq "$max" ] && break
  done
  if [ -z "$best" ]; then
    set_strategy "$prev"
    die "ни одна стратегия не запустилась (проверьте nfnetlink_queue и правила файрвола)"
  fi
  set_strategy "$best"
  say "Выбрана стратегия: $best — ${STRAT_TITLE[$best]} ($best_score из $max)"
  if [ "$best_score" -le 0 ]; then
    warn "ни одна стратегия не открыла сайты — возможно, проблема в DNS (см. './zapret-vn.sh dns-on') или у провайдера другая блокировка"
  fi
  cmd_start
}

# ----------------------------------------------------------------------------- прочие команды
cmd_strategy() {
  if [ $# -eq 0 ]; then
    local cur id; cur="$(get_strategy)"
    for id in "${STRAT_IDS[@]}"; do
      printf '%s %-20s %s\n' "$([ "$id" = "$cur" ] && echo '*' || echo ' ')" "$id" "${STRAT_TITLE[$id]}"
    done
    say ""
    say "Сменить: ./zapret-vn.sh strategy <id>    Подобрать автоматически: ./zapret-vn.sh pick"
    return 0
  fi
  [ -n "${STRAT_ARGS[$1]+x}" ] || die "нет стратегии '$1' (список: ./zapret-vn.sh strategy)"
  ensure_root
  set_strategy "$1"
  say "Стратегия: $1 — ${STRAT_TITLE[$1]}"
  if is_running; then cmd_restart; fi
}

cmd_args() {
  build_args
  printf '%s' "$(nfqws_bin)"; printf ' %s' "${NFQWS_ARGS[@]}"; printf '\n'
}

cmd_rules() {
  case "$(fw_backend)" in
    nft) nft_rules ;;
    iptables)
      local t chain spec
      for t in iptables ip6tables; do
        while IFS='|' read -r chain spec; do echo "$t -t mangle -I $chain $spec"; done < <(ipt_specs)
      done ;;
    *) die "не найдены ни nft, ни iptables" ;;
  esac
}

cmd_verify() {
  need_cmd sha256sum
  ( cd "$ROOT" && sha256sum -c SHA256SUMS ) || die "хеши не совпали — файлы изменены или повреждены"
  say "Хеши nfqws и fake-файлов совпадают с официальным релизом zapret $ZAPRET_VERSION (bol-van/zapret)."
}

# Работает ли разрешение имён (несколько попыток: после restart systemd-resolved нужна пара секунд)
dns_works() {
  local i
  for i in 1 2 3 4 5; do
    getent hosts example.com >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

cmd_dns_on() {
  ensure_root
  command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved 2>/dev/null \
    || die "systemd-resolved не активен. Включите DNS-over-TLS вручную на 8.8.8.8 / 1.1.1.1 (порт 853) в вашем резолвере."
  local conf=/etc/systemd/resolved.conf.d/zapret-vn.conf base=0
  getent hosts example.com >/dev/null 2>&1 && base=1   # работал ли DNS до наших изменений
  mkdir -p /etc/systemd/resolved.conf.d
  cat > "$conf" <<'EOF'
# Создано Zapret VN: защищённый DNS (DNS-over-TLS) вместо DNS провайдера
[Resolve]
DNS=8.8.8.8#dns.google 8.8.4.4#dns.google 1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com
Domains=~.
DNSOverTLS=yes
EOF
  systemctl restart systemd-resolved
  if ! dns_works; then
    if [ "$base" = 1 ]; then
      # строгий DoT без запасного канала: если порт 853 закрыт, машина осталась бы без DNS — откатываем
      rm -f "$conf"
      systemctl restart systemd-resolved
      die "после включения DNS-over-TLS имена перестали разрешаться (порт 853 закрыт сетью или провайдером?) — изменения отменены, DNS как был."
    fi
    warn "не удалось проверить работу DNS (нет сети?) — защищённый DNS оставлен включённым; отключить: zapret-vn dns-off"
  fi
  [ "$(readlink -f /etc/resolv.conf 2>/dev/null)" = "/run/systemd/resolve/stub-resolv.conf" ] \
    || warn "/etc/resolv.conf не указывает на stub-resolv.conf systemd-resolved — приложения могут по-прежнему использовать другой DNS"
  say "Защищённый DNS включён (DNS-over-TLS, 8.8.8.8 / 1.1.1.1). Проверка: resolvectl status"
}

cmd_dns_off() {
  ensure_root
  rm -f /etc/systemd/resolved.conf.d/zapret-vn.conf
  command -v systemctl >/dev/null 2>&1 && systemctl restart systemd-resolved 2>/dev/null
  say "Защищённый DNS выключен, DNS снова от провайдера/сети."
}

# Копирует программу в /opt/zapret-vn (там доступно пользователю nobody), делает ссылку /usr/local/bin/zapret-vn и ставит службу
cmd_install() {
  ensure_root
  local dst="${ZVN_PREFIX:-/opt/zapret-vn}" f a want_dns=1 want_pick=0
  for a in "$@"; do
    case "$a" in
      --no-dns) want_dns=0 ;;
      --pick)   want_pick=1 ;;
      *) die "неизвестный параметр '$a' (доступно: --no-dns, --pick)" ;;
    esac
  done
  if [ "$ROOT" != "$dst" ]; then
    mkdir -p "$dst/lists" "$dst/config" || die "не удалось создать $dst"
    for f in zapret-vn.sh zapret-vn.service SHA256SUMS README.md CHANGELOG.md LICENSE LICENSE.zapret LICENSE.zapret-vn THIRD_PARTY_NOTICES.md bin fake; do
      [ -e "$ROOT/$f" ] && cp -a "$ROOT/$f" "$dst/"
    done
    # списки и настройки — только если их ещё нет (не затираем правки пользователя)
    cp -an "$ROOT/lists/." "$dst/lists/" 2>/dev/null
    [ -d "$ROOT/config" ] && cp -an "$ROOT/config/." "$dst/config/" 2>/dev/null
    chmod 755 "$dst" "$dst/zapret-vn.sh" "$dst"/bin/* 2>/dev/null
    say "Установлено в $dst (списки и настройки, если уже были, сохранены)."
  fi
  ln -sf "$dst/zapret-vn.sh" /usr/local/bin/zapret-vn 2>/dev/null && say "Команда: zapret-vn <команда>"
  "$dst/zapret-vn.sh" verify || die "проверка хешей не пройдена — установка остановлена"
  "$dst/zapret-vn.sh" install-service || die "не удалось установить службу"
  if [ "$want_dns" = 1 ]; then
    "$dst/zapret-vn.sh" dns-on || warn "защищённый DNS не включён — включить позже: sudo zapret-vn dns-on"
  fi
  sleep 2
  if [ "$want_pick" = 1 ]; then "$dst/zapret-vn.sh" pick || warn "автоподбор не завершился"; fi
  "$dst/zapret-vn.sh" check || true
  say ""
  say "Готово. Служба включена в автозапуск и будет стартовать вместе с системой."
  say "Если часть сайтов ✖ — попробуйте автоподбор стратегии: sudo zapret-vn pick"
  say "Состояние: zapret-vn status     Удалить: sudo zapret-vn uninstall-service"
}

cmd_install_service() {
  ensure_root
  check_path
  command -v systemctl >/dev/null 2>&1 || die "systemd не найден"
  [ -r "$ROOT/zapret-vn.service" ] || die "нет файла $ROOT/zapret-vn.service"
  prepare_files
  sed "s#@ROOT@#$ROOT#g" "$ROOT/zapret-vn.service" > "$UNIT"
  systemctl daemon-reload || die "systemctl daemon-reload не выполнился (systemd не запущен?)"
  systemctl enable --now zapret-vn || die "не удалось включить службу (journalctl -u zapret-vn)"
  say "Служба установлена и запущена; стартует вместе с системой. Журнал: journalctl -u zapret-vn"
}

cmd_uninstall_service() {
  ensure_root
  if [ -e "$UNIT" ]; then
    systemctl disable --now zapret-vn 2>/dev/null
    rm -f "$UNIT"
    systemctl daemon-reload
  fi
  fw_del
  say "Служба удалена. Папку программы можно удалить вручную; защищённый DNS отключается командой dns-off."
}

cmd_help() {
  cat <<EOF
Zapret VN для Linux $VERSION (nfqws из zapret $ZAPRET_VERSION)

Использование: ./zapret-vn.sh <команда>

  start | stop | restart | status   управление обходом (нужен root; sudo подставится сам)
  check                             открываются ли Steam / Roblox / Telegram прямо сейчас
  pick                              автоподбор стратегии (пробует все 10 и выбирает лучшую)
  strategy [id]                     показать список / выбрать стратегию
  dns-on | dns-off                  защищённый DNS (DNS-over-TLS через systemd-resolved)
  install-service                   только служба systemd из текущей папки (автозапуск с системой)
  install [--no-dns] [--pick]       всё в одном: /opt/zapret-vn + служба systemd (автозапуск) + защищённый DNS + проверка
                                    --no-dns — не трогать DNS;  --pick — сразу подобрать стратегию автоматически
  uninstall-service                 удалить службу и правила файрвола
  verify                            проверить хеши nfqws и fake-файлов
  rules                             показать правила файрвола, которые будут применены
  args                              показать командную строку nfqws
  run                               запуск на переднем плане (так работает служба)

Списки доменов: $LISTS/vietnam.txt (в обходе), exclude.txt (исключения), autohostlist.txt (найденные сами).
После правки списков: ./zapret-vn.sh restart.

Переменные: ZVN_FW=nft|iptables  ZVN_QNUM=200  ZVN_USER=nobody  ZVN_NFQWS=/путь/к/nfqws
EOF
}

# ----------------------------------------------------------------------------- точка входа
cmd="${1:-help}"
[ $# -gt 0 ] && shift
case "$cmd" in
  start)              cmd_start ;;
  stop)               cmd_stop ;;
  restart)            cmd_restart ;;
  status)             cmd_status ;;
  run)                cmd_run ;;
  stop-rules)         ensure_root; fw_del; rm -f "$PIDFILE" ;;   # служебная: вызывается из unit-файла
  check)              cmd_check ;;
  pick)               cmd_pick ;;
  strategy)           cmd_strategy "$@" ;;
  args)               cmd_args ;;
  rules)              cmd_rules ;;
  verify)             cmd_verify ;;
  dns-on)             cmd_dns_on ;;
  dns-off)            cmd_dns_off ;;
  install)            cmd_install "$@" ;;
  install-service)    cmd_install_service ;;
  uninstall-service)  cmd_uninstall_service ;;
  help|-h|--help)     cmd_help ;;
  *) echo "Неизвестная команда: $cmd" >&2; cmd_help >&2; exit 2 ;;
esac
