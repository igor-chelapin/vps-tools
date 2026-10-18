#!/bin/bash
# ============================================================
# Monitor — мониторинг VPN-сервера с 3x-ui (Ubuntu).
# Проверяет диск, память, нагрузку, службу x-ui, процесс Xray,
# порт панели, порты inbound'ов и срок сертификата. Уведомляет
# в Telegram (или пишет в лог) только при смене состояния.
# ============================================================

set -euo pipefail

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

# Пути можно переопределить переменными окружения
XUI_DB="${XUI_DB:-/etc/x-ui/x-ui.db}"
XUI_BIN="${XUI_BIN:-/usr/local/x-ui/x-ui}"
XUI_ENV_FILE="${XUI_ENV_FILE:-/etc/default/x-ui}"
TG_CONF="${TG_CONF:-/etc/vps-tools/telegram.conf}"
TG_API="${TG_API:-https://api.telegram.org}"
STATE_FILE="${STATE_FILE:-/var/lib/vps-tools/monitor.state}"
LOG_FILE="${LOG_FILE:-/var/log/vps-tools.log}"
LOCK_FILE="${LOCK_FILE:-/var/lock/vps-tools-monitor.lock}"
CRON_FILE="${CRON_FILE:-/etc/cron.d/vps-tools-monitor}"
INSTALL_PATH="${INSTALL_PATH:-/usr/local/sbin/vps-tools-monitor}"
RAW_URL="https://raw.githubusercontent.com/igor-chelapin/vps-tools/vps-tools/monitor.sh"

DISK_WARN=90
MEM_WARN=90
LOAD_WARN="2.0"
CERT_DAYS=14
CONFIRM=2
REMIND_HOURS=6
INTERVAL=5

ACTION="run"
QUIET=0

usage() {
    cat <<'EOF'
Использование: monitor.sh [опции]

  (без опций)         выполнить проверки и уведомить о переменах (для cron)
  --status            показать текущее состояние, ничего не отправляя и не сохраняя
  --test              отправить тестовое сообщение в Telegram
  --setup-telegram    интерактивно сохранить токен бота и chat id
  --install-cron      запускать проверки по расписанию (--interval минут)
  --interval N        период проверки в минутах, 1-59 (по умолчанию 5)
  --remove-cron       убрать расписание

Пороги:
  --disk N            диск, % занято (по умолчанию 90)
  --mem N             память, % занято (по умолчанию 90)
  --load X            5-минутная нагрузка на одно ядро (по умолчанию 2.0)
  --cert-days N       предупреждать, если до конца сертификата меньше N дней (14)
  --confirm N         сколько проверок подряд проблема должна держаться, чтобы
                      отправить уведомление (по умолчанию 2, защита от ложных срабатываний)
  --remind-hours N    повторять напоминание о нерешённой проблеме раз в N часов (6)

  --quiet             минимум вывода (для cron)
  -h, --help          эта справка

Переменные окружения: XUI_DB, XUI_BIN, XUI_ENV_FILE, TG_CONF (нестандартные пути).
EOF
}

need_arg() { if [[ $2 -lt 2 ]]; then echo "$1 требует аргумент" >&2; exit 2; fi; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --disk)         need_arg "$1" $#; DISK_WARN="$2"; shift ;;
        --mem)          need_arg "$1" $#; MEM_WARN="$2"; shift ;;
        --load)         need_arg "$1" $#; LOAD_WARN="$2"; shift ;;
        --cert-days)    need_arg "$1" $#; CERT_DAYS="$2"; shift ;;
        --confirm)      need_arg "$1" $#; CONFIRM="$2"; shift ;;
        --remind-hours) need_arg "$1" $#; REMIND_HOURS="$2"; shift ;;
        --interval)     need_arg "$1" $#; INTERVAL="$2"; shift ;;
        --status)         ACTION="status" ;;
        --test)           ACTION="test" ;;
        --setup-telegram) ACTION="setup-telegram" ;;
        --install-cron)   ACTION="install-cron" ;;
        --remove-cron)    ACTION="remove-cron" ;;
        --quiet|-q)       QUIET=1 ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "Неизвестная опция: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

for pair in "disk:$DISK_WARN" "mem:$MEM_WARN" "cert-days:$CERT_DAYS" "confirm:$CONFIRM" "remind-hours:$REMIND_HOURS"; do
    if ! [[ "${pair#*:}" =~ ^[0-9]+$ ]] || (( ${pair#*:} < 1 )); then
        echo "--${pair%%:*} должен быть целым числом от 1" >&2; exit 2
    fi
done
if ! [[ "$LOAD_WARN" =~ ^[0-9]+([.][0-9]+)?$ ]]; then echo "--load должен быть числом, например 2.0" >&2; exit 2; fi
if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || (( INTERVAL < 1 || INTERVAL > 59 )); then
    echo "--interval должен быть от 1 до 59 минут" >&2; exit 2
fi

log_file() {
    { printf '%s monitor: %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; } 2>/dev/null || true
}
ok()   { if [[ $QUIET -eq 0 ]]; then echo -e "${GREEN}[✓] $*${NC}"; fi; }
info() { if [[ $QUIET -eq 0 ]]; then echo -e "${YELLOW}[*] $*${NC}"; fi; }
warn() { echo -e "${YELLOW}[!] $*${NC}"; }
fail() { echo -e "${RED}[✗] $*${NC}" >&2; log_file "ERROR: $*"; exit 1; }

need_root() {
    if [[ $EUID -ne 0 ]]; then fail "Запусти скрипт от root"; fi
}

# ----- Telegram -----
conf_get() {
    grep -E "^$1=" "$TG_CONF" 2>/dev/null | tail -1 | cut -d= -f2- \
        | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//"
}

TG_TOKEN=""
TG_CHAT=""
tg_load() {
    TG_TOKEN=""; TG_CHAT=""
    [[ -r "$TG_CONF" ]] || return 1
    TG_TOKEN="$(conf_get TG_TOKEN)"
    TG_CHAT="$(conf_get TG_CHAT)"
    [[ -n "$TG_TOKEN" && -n "$TG_CHAT" ]]
}

# Токен передаётся curl через stdin (-K -), чтобы не светиться в списке процессов
tg_call() {
    local method="$1"; shift
    printf 'url = "%s/bot%s/%s"\n' "$TG_API" "$TG_TOKEN" "$method" | curl -sS -m 30 -K - "$@"
}

tg_ok() { grep -qE '"ok"[[:space:]]*:[[:space:]]*true' <<< "$1"; }

tg_send_message() {
    local resp
    resp="$(tg_call sendMessage --form-string "chat_id=$TG_CHAT" --form-string "text=$1" 2>&1)" || return 1
    tg_ok "$resp"
}

do_setup_telegram() {
    need_root
    local token chat resp
    echo -e "${BLUE}Настройка Telegram${NC}"
    echo "1. Откройте @BotFather в Telegram, создайте бота командой /newbot и скопируйте токен."
    echo "2. Напишите своему новому боту любое сообщение (например, /start)."
    echo ""
    read -r -s -p "Токен бота: " token </dev/tty; echo ""
    [[ -n "$token" ]] || fail "Токен не введён"

    TG_TOKEN="$token"
    resp="$(tg_call getMe 2>&1)" || fail "Не удалось связаться с Telegram: $resp"
    tg_ok "$resp" || fail "Telegram не принял токен"
    ok "Токен принят"

    read -r -p "Chat ID (Enter — определить автоматически): " chat </dev/tty
    if [[ -z "$chat" ]]; then
        resp="$(tg_call getUpdates 2>&1)" || fail "Не удалось получить сообщения: $resp"
        chat="$(grep -oE '"chat"[[:space:]]*:[[:space:]]*\{[[:space:]]*"id"[[:space:]]*:[[:space:]]*-?[0-9]+' <<< "$resp" | tail -1 | grep -oE -- '-?[0-9]+$' || true)"
        [[ -n "$chat" ]] || fail "Сообщений боту не найдено. Напишите боту /start и запустите настройку снова."
        ok "Chat ID определён: $chat"
    fi
    TG_CHAT="$chat"

    tg_send_message "vps-tools: Telegram подключён к серверу $(hostname)" \
        || fail "Тестовое сообщение не отправилось. Проверьте chat id и что вы написали боту."

    umask 077
    mkdir -p "$(dirname "$TG_CONF")"
    chmod 700 "$(dirname "$TG_CONF")"
    printf 'TG_TOKEN=%s\nTG_CHAT=%s\n' "$token" "$chat" > "$TG_CONF"
    chmod 600 "$TG_CONF"
    ok "Сохранено в $TG_CONF (права 600). Тестовое сообщение отправлено."
}

# ----- Чтение настроек 3x-ui -----
is_postgres() {
    [[ -r "$XUI_ENV_FILE" ]] && grep -q '^XUI_DB_TYPE=postgres' "$XUI_ENV_FILE"
}

have_db() {
    [[ -f "$XUI_DB" ]] && command -v sqlite3 >/dev/null 2>&1 && ! is_postgres
}

sql() {
    sqlite3 -readonly -cmd ".timeout 3000" "$XUI_DB" "$1"
}

setting() {
    # setting KEY DEFAULT -> значение из базы или значение по умолчанию 3x-ui
    local key="$1" def="$2" val=""
    if have_db; then
        val="$(sql "SELECT value FROM settings WHERE \"key\"='$key' LIMIT 1;" 2>/dev/null || true)"
    fi
    echo "${val:-$def}"
}

tcp_open() {
    local host="$1" port="$2"
    timeout 3 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null
}

probe_host() {
    case "$1" in
        ""|0.0.0.0|::|"[::]") echo "127.0.0.1" ;;
        *) echo "$1" ;;
    esac
}

# ----- Проверки -----
IDS=()
declare -A LABEL=() STATUS=() DETAIL=()

add_check() {
    # add_check ID "Название" OK|PROBLEM "подробности"
    local id="$1"
    IDS+=("$id")
    LABEL[$id]="$2"
    STATUS[$id]="$3"
    DETAIL[$id]="$4"
}

ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 >= b+0)}'; }

check_disk() {
    local pct
    pct="$(df -P / | awk 'NR==2{gsub("%","",$5); print $5}')"
    if [[ -z "$pct" ]]; then return 0; fi
    if (( pct >= DISK_WARN )); then
        add_check disk "Диск" PROBLEM "занято ${pct}% (порог ${DISK_WARN}%)"
    else
        add_check disk "Диск" OK "занято ${pct}%"
    fi
}

check_mem() {
    local total avail used
    total="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
    avail="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"
    if [[ -z "$total" || -z "$avail" || "$total" -eq 0 ]]; then return 0; fi
    used=$(( 100 - avail * 100 / total ))
    if (( used >= MEM_WARN )); then
        add_check mem "Память" PROBLEM "занято ${used}% (порог ${MEM_WARN}%)"
    else
        add_check mem "Память" OK "занято ${used}%"
    fi
}

check_load() {
    local l5 cpus ratio
    l5="$(awk '{print $2}' /proc/loadavg)"
    cpus="$(nproc 2>/dev/null || echo 1)"
    ratio="$(awk -v l="$l5" -v c="$cpus" 'BEGIN{printf "%.2f", l/c}')"
    if ge "$ratio" "$LOAD_WARN"; then
        add_check load "Нагрузка CPU" PROBLEM "5-мин. нагрузка ${l5} на ${cpus} ядер, ${ratio} на ядро (порог ${LOAD_WARN})"
    else
        add_check load "Нагрузка CPU" OK "${ratio} на ядро"
    fi
}

XUI_INSTALLED=0
XUI_RUNNING=0
check_xui() {
    if ! systemctl cat x-ui >/dev/null 2>&1; then
        return 0   # 3x-ui не установлен — служебные проверки пропускаем
    fi
    XUI_INSTALLED=1
    if systemctl is-active --quiet x-ui; then
        XUI_RUNNING=1
        add_check xui "Служба x-ui" OK "работает"
    else
        add_check xui "Служба x-ui" PROBLEM "не запущена (systemctl status x-ui)"
    fi
}

check_xray() {
    if [[ $XUI_RUNNING -eq 0 ]]; then return 0; fi
    if pgrep -f 'bin/xray-linux' >/dev/null 2>&1; then
        add_check xray "Процесс Xray" OK "работает"
    else
        add_check xray "Процесс Xray" PROBLEM "процесс не найден, хотя x-ui запущен"
    fi
}

check_panel() {
    if [[ $XUI_RUNNING -eq 0 ]] || ! have_db; then return 0; fi
    local port host
    port="$(setting webPort 2053)"
    host="$(probe_host "$(setting webListen "")")"
    if tcp_open "$host" "$port"; then
        add_check panel "Порт панели" OK "$host:$port отвечает"
    else
        add_check panel "Порт панели" PROBLEM "$host:$port не отвечает"
    fi
}

check_inbounds() {
    if [[ $XUI_RUNNING -eq 0 ]] || ! have_db; then return 0; fi
    local rows closed="" total=0 port listen protocol network host
    if ! rows="$(sql "SELECT port, IFNULL(listen,''), protocol,
        CASE WHEN json_valid(stream_settings) THEN IFNULL(json_extract(stream_settings,'\$.network'),'') ELSE '' END
        FROM inbounds WHERE enable=1 AND port>0 ORDER BY port;" 2>/dev/null)"; then
        return 0
    fi
    while IFS='|' read -r port listen protocol network; do
        [[ -n "$port" ]] || continue
        case "$protocol" in hysteria|wireguard|tuic|amneziawg|masque) continue ;; esac   # только UDP
        case "$network" in kcp|mkcp|hysteria|quic|masque) continue ;; esac
        total=$((total + 1))
        host="$(probe_host "$listen")"
        if ! tcp_open "$host" "$port"; then closed+="$port "; fi
    done <<< "$rows"
    if [[ $total -eq 0 ]]; then return 0; fi
    if [[ -n "$closed" ]]; then
        add_check inbounds "Порты inbound'ов (TCP)" PROBLEM "не отвечают: ${closed% }"
    else
        add_check inbounds "Порты inbound'ов (TCP)" OK "все ${total} отвечают"
    fi
}

check_cert() {
    if [[ $XUI_INSTALLED -eq 0 ]] || ! have_db || ! command -v openssl >/dev/null 2>&1; then return 0; fi
    local cert end_epoch days
    cert="$(setting webCertFile "")"
    if [[ -z "$cert" ]]; then return 0; fi
    if [[ ! -r "$cert" ]]; then
        add_check cert "Сертификат панели" PROBLEM "файл не найден или не читается: $cert"
        return 0
    fi
    end_epoch="$(date -d "$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)" +%s 2>/dev/null || true)"
    if [[ -z "$end_epoch" ]]; then
        add_check cert "Сертификат панели" PROBLEM "не удалось прочитать срок действия: $cert"
        return 0
    fi
    days=$(( (end_epoch - $(date +%s)) / 86400 ))
    if (( days < CERT_DAYS )); then
        if (( days < 0 )); then
            add_check cert "Сертификат панели" PROBLEM "истёк $(( -days )) дн. назад"
        else
            add_check cert "Сертификат панели" PROBLEM "истекает через ${days} дн. (порог ${CERT_DAYS})"
        fi
    else
        add_check cert "Сертификат панели" OK "действителен ещё ${days} дн."
    fi
}

run_checks() {
    check_disk
    check_mem
    check_load
    check_xui
    check_xray
    check_panel
    check_inbounds
    check_cert
}

# ----- Состояние и уведомления -----
# Формат строки состояния: id fails notified last_notified_epoch
declare -A S_FAILS=() S_NOTIFIED=() S_LAST=()

load_state() {
    local id fails notified last
    [[ -r "$STATE_FILE" ]] || return 0
    while read -r id fails notified last; do
        [[ -n "$id" ]] || continue
        S_FAILS[$id]="${fails:-0}"
        S_NOTIFIED[$id]="${notified:-0}"
        S_LAST[$id]="${last:-0}"
    done < "$STATE_FILE"
}

save_state() {
    local id tmp
    mkdir -p "$(dirname "$STATE_FILE")"
    tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
    for id in "${IDS[@]}"; do
        printf '%s %s %s %s\n' "$id" "${S_FAILS[$id]:-0}" "${S_NOTIFIED[$id]:-0}" "${S_LAST[$id]:-0}" >> "$tmp"
    done
    chmod 600 "$tmp"
    mv "$tmp" "$STATE_FILE"
}

do_run() {
    need_root
    if command -v flock >/dev/null 2>&1; then
        mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
        exec 9>"$LOCK_FILE"
        flock -n 9 || exit 0   # предыдущая проверка ещё идёт
    fi

    run_checks
    load_state

    local now remind_sec id lines="" mark sent=1
    local -A prev_notified=() prev_last=()
    local changed=()
    now="$(date +%s)"
    remind_sec=$(( REMIND_HOURS * 3600 ))

    for id in "${IDS[@]}"; do
        prev_notified[$id]="${S_NOTIFIED[$id]:-0}"
        prev_last[$id]="${S_LAST[$id]:-0}"
        if [[ "${STATUS[$id]}" == "PROBLEM" ]]; then
            S_FAILS[$id]=$(( ${S_FAILS[$id]:-0} + 1 ))
            if (( S_FAILS[$id] >= CONFIRM )); then
                if [[ "${S_NOTIFIED[$id]:-0}" -eq 0 ]]; then
                    lines+="⚠️ ${LABEL[$id]}: ${DETAIL[$id]}"$'\n'
                    S_NOTIFIED[$id]=1; S_LAST[$id]=$now; changed+=("$id")
                elif (( now - ${S_LAST[$id]:-0} >= remind_sec )); then
                    lines+="⚠️ (всё ещё) ${LABEL[$id]}: ${DETAIL[$id]}"$'\n'
                    S_LAST[$id]=$now; changed+=("$id")
                fi
            fi
        else
            if [[ "${S_NOTIFIED[$id]:-0}" -eq 1 ]]; then
                lines+="✅ ${LABEL[$id]}: снова в норме (${DETAIL[$id]})"$'\n'
                changed+=("$id")
            fi
            S_FAILS[$id]=0; S_NOTIFIED[$id]=0; S_LAST[$id]=0
        fi
    done

    if [[ -z "$lines" ]]; then
        save_state
        info "Без изменений, уведомлять не о чем"
        return 0
    fi

    while IFS= read -r mark; do
        [[ -n "$mark" ]] || continue
        log_file "$mark"
        logger -t vps-tools-monitor -- "$mark" 2>/dev/null || true
    done <<< "$lines"

    if tg_load; then
        if tg_send_message "🖥 $(hostname)"$'\n'"$lines"; then
            info "Уведомление отправлено в Telegram"
        else
            sent=0
            warn "Не удалось отправить уведомление в Telegram (запись есть в логе $LOG_FILE), повторю при следующей проверке"
        fi
    else
        info "Telegram не настроен: события записаны в лог $LOG_FILE"
        if [[ $QUIET -eq 0 ]]; then printf '%s' "$lines"; fi
    fi

    # Не отправилось — возвращаем прежние отметки, чтобы следующая проверка попробовала снова
    if [[ $sent -eq 0 ]]; then
        for id in "${changed[@]}"; do
            S_NOTIFIED[$id]="${prev_notified[$id]}"
            S_LAST[$id]="${prev_last[$id]}"
        done
    fi
    save_state
}

do_status() {
    run_checks
    local id color mark pad problems=0
    echo ""
    for id in "${IDS[@]}"; do
        if [[ "${STATUS[$id]}" == "OK" ]]; then
            color="$GREEN"; mark="[✓]"
        else
            color="$RED"; mark="[✗]"; problems=$((problems + 1))
        fi
        pad=$(( 26 - ${#LABEL[$id]} )); if (( pad < 1 )); then pad=1; fi
        printf '%b%s%b %s%*s%s\n' "$color" "$mark" "$NC" "${LABEL[$id]}" "$pad" "" "${DETAIL[$id]}"
    done
    echo ""
    if (( problems == 0 )); then ok "Проблем не найдено"; else warn "Проблем: $problems"; fi
    if tg_load; then info "Telegram: настроен"; else info "Telegram: не настроен (--setup-telegram)"; fi
    return $(( problems > 0 ? 1 : 0 ))
}

do_test() {
    tg_load || fail "Telegram не настроен: запустите с --setup-telegram"
    if tg_send_message "vps-tools: тестовое сообщение от $(hostname)"; then
        ok "Тестовое сообщение отправлено"
    else
        fail "Не удалось отправить сообщение: проверьте токен, chat id и доступ к api.telegram.org"
    fi
}

# ----- cron -----
do_install_cron() {
    need_root
    local src="$0" tmp args=""
    if ! command -v sqlite3 >/dev/null 2>&1; then
        info "Устанавливаю sqlite3 (нужен для чтения настроек 3x-ui)..."
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y -qq sqlite3 >/dev/null || warn "Не удалось установить sqlite3: проверки панели и портов будут пропущены"
    fi
    mkdir -p "$(dirname "$INSTALL_PATH")"
    if [[ -f "$src" && "$src" != /dev/fd/* && "$src" != /proc/* ]]; then
        install -m 755 "$src" "$INSTALL_PATH"
    else
        info "Скачиваю скрипт для cron..."
        tmp="$(mktemp)"
        curl -fsSL "$RAW_URL" -o "$tmp" || { rm -f "$tmp"; fail "Не удалось скачать $RAW_URL"; }
        head -1 "$tmp" | grep -q '^#!/bin/bash' || { rm -f "$tmp"; fail "Скачан не тот файл"; }
        install -m 755 "$tmp" "$INSTALL_PATH"
        rm -f "$tmp"
    fi

    if [[ "$DISK_WARN" != "90" ]]; then args+=" --disk $DISK_WARN"; fi
    if [[ "$MEM_WARN" != "90" ]]; then args+=" --mem $MEM_WARN"; fi
    if [[ "$LOAD_WARN" != "2.0" ]]; then args+=" --load $LOAD_WARN"; fi
    if [[ "$CERT_DAYS" != "14" ]]; then args+=" --cert-days $CERT_DAYS"; fi
    if [[ "$CONFIRM" != "2" ]]; then args+=" --confirm $CONFIRM"; fi
    if [[ "$REMIND_HOURS" != "6" ]]; then args+=" --remind-hours $REMIND_HOURS"; fi

    {
        echo "# vps-tools: мониторинг сервера (создано monitor.sh --install-cron)"
        echo "SHELL=/bin/bash"
        echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        echo "*/$INTERVAL * * * * root $INSTALL_PATH --quiet$args >> $LOG_FILE 2>&1"
    } > "$CRON_FILE"
    chmod 644 "$CRON_FILE"
    ok "Мониторинг включён: проверка каждые $INTERVAL мин. (скрипт: $INSTALL_PATH, лог: $LOG_FILE)"
    if ! tg_load; then
        info "Telegram не настроен: события пишутся только в лог. Настроить: $INSTALL_PATH --setup-telegram"
    fi
}

do_remove_cron() {
    need_root
    rm -f "$CRON_FILE" "$INSTALL_PATH"
    ok "Мониторинг по расписанию отключён"
}

if [[ $QUIET -eq 0 ]]; then
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}  Monitor${NC}"
    echo -e "${BLUE}============================================${NC}"
fi

case "$ACTION" in
    run)            do_run ;;
    status)         do_status ;;
    test)           do_test ;;
    setup-telegram) do_setup_telegram ;;
    install-cron)   do_install_cron ;;
    remove-cron)    do_remove_cron ;;
esac
