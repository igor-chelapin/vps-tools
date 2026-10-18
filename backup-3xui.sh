#!/bin/bash
# ============================================================
# Backup 3x-ui — бэкап базы и настроек панели 3x-ui (Ubuntu).
# Консистентная копия SQLite, ротация, отправка в Telegram (по желанию),
# установка в cron и восстановление из архива.
# ============================================================

set -euo pipefail

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

# Пути можно переопределить переменными окружения (нестандартная установка)
XUI_DB="${XUI_DB:-/etc/x-ui/x-ui.db}"
XUI_DIR="${XUI_DIR:-$(dirname "$XUI_DB")}"
XUI_ENV_FILE="${XUI_ENV_FILE:-/etc/default/x-ui}"
XRAY_CONFIG="${XRAY_CONFIG:-/usr/local/x-ui/bin/config.json}"
TG_CONF="${TG_CONF:-/etc/vps-tools/telegram.conf}"
TG_API="${TG_API:-https://api.telegram.org}"
LOG_FILE="${LOG_FILE:-/var/log/vps-tools.log}"
LOCK_FILE="${LOCK_FILE:-/var/lock/vps-tools-backup.lock}"
CRON_FILE="${CRON_FILE:-/etc/cron.d/vps-tools-backup}"
INSTALL_PATH="${INSTALL_PATH:-/usr/local/sbin/vps-tools-backup-3xui}"
RAW_URL="https://raw.githubusercontent.com/igor-chelapin/vps-tools/vps-tools/backup-3xui.sh"

BACKUP_DIR="/var/backups/3x-ui"
KEEP=14
INCLUDES=()
ACTION="backup"
ARG_FILE=""
CRON_TIME="03:15"
YES=0
DRY=0
QUIET=0
NO_TG=0

log_file() {
    if [[ $DRY -eq 0 ]]; then
        { printf '%s backup: %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; } 2>/dev/null || true
    fi
}
ok()   { if [[ $QUIET -eq 0 ]]; then echo -e "${GREEN}[✓] $*${NC}"; fi; log_file "$*"; }
info() { if [[ $QUIET -eq 0 ]]; then echo -e "${YELLOW}[*] $*${NC}"; fi; }
warn() { echo -e "${YELLOW}[!] $*${NC}"; log_file "WARN: $*"; }
fail() { echo -e "${RED}[✗] $*${NC}" >&2; log_file "ERROR: $*"; exit 1; }

usage() {
    cat <<'EOF'
Использование: backup-3xui.sh [опции]

Бэкап:
  (без опций)            сделать бэкап сейчас
  --dir DIR              каталог для архивов (по умолчанию /var/backups/3x-ui)
  --keep N               сколько последних архивов хранить (по умолчанию 14)
  --include PATH         добавить в архив ещё файл или каталог (можно несколько раз),
                         например --include /root/cert
  --no-telegram          не отправлять этот архив в Telegram
  --dry-run              показать, что попадёт в архив, ничего не создавая
  --quiet                минимум вывода (для cron)

Telegram:
  --setup-telegram       интерактивно сохранить токен бота и chat id

Расписание:
  --install-cron         ставить ежедневный бэкап в cron (время: --time)
  --time HH:MM           время запуска (по умолчанию 03:15)
  --remove-cron          убрать из cron

Прочее:
  --list                 показать имеющиеся архивы
  --restore FILE         восстановить 3x-ui из архива (с подтверждением)
  --yes                  не спрашивать подтверждение
  -h, --help             эта справка

Переменные окружения: XUI_DB, XUI_ENV_FILE, XRAY_CONFIG, TG_CONF (нестандартные пути).
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)     [[ $# -ge 2 ]] || { echo "--dir требует аргумент" >&2; exit 2; }; BACKUP_DIR="$2"; shift ;;
        --keep)    [[ $# -ge 2 ]] || { echo "--keep требует аргумент" >&2; exit 2; }; KEEP="$2"; shift ;;
        --include) [[ $# -ge 2 ]] || { echo "--include требует аргумент" >&2; exit 2; }; INCLUDES+=("$2"); shift ;;
        --time)    [[ $# -ge 2 ]] || { echo "--time требует аргумент" >&2; exit 2; }; CRON_TIME="$2"; shift ;;
        --restore) [[ $# -ge 2 ]] || { echo "--restore требует аргумент" >&2; exit 2; }; ACTION="restore"; ARG_FILE="$2"; shift ;;
        --setup-telegram) ACTION="setup-telegram" ;;
        --install-cron)   ACTION="install-cron" ;;
        --remove-cron)    ACTION="remove-cron" ;;
        --list)           ACTION="list" ;;
        --no-telegram)    NO_TG=1 ;;
        --yes|-y)  YES=1 ;;
        --dry-run) DRY=1 ;;
        --quiet|-q) QUIET=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Неизвестная опция: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if ! [[ "$KEEP" =~ ^[0-9]+$ ]] || (( KEEP < 1 )); then
    echo "--keep должен быть целым числом от 1" >&2; exit 2
fi
if ! [[ "$CRON_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo "--time должно быть в формате HH:MM, например 03:15" >&2; exit 2
fi

need_root() {
    if [[ $EUID -ne 0 ]]; then fail "Запусти скрипт от root"; fi
}

is_postgres() {
    [[ -r "$XUI_ENV_FILE" ]] && grep -q '^XUI_DB_TYPE=postgres' "$XUI_ENV_FILE"
}

human_size() {
    local bytes="$1"
    if (( bytes >= 1048576 )); then
        awk -v b="$bytes" 'BEGIN{printf "%.1f МБ", b/1048576}'
    else
        awk -v b="$bytes" 'BEGIN{printf "%.1f КБ", b/1024}'
    fi
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
    printf 'url = "%s/bot%s/%s"\n' "$TG_API" "$TG_TOKEN" "$method" | curl -sS -m 180 -K - "$@"
}

tg_send_message() {
    local resp
    resp="$(tg_call sendMessage --form-string "chat_id=$TG_CHAT" --form-string "text=$1" 2>&1)" || return 1
    grep -qE '"ok"[[:space:]]*:[[:space:]]*true' <<< "$resp"
}

tg_send_file() {
    local resp
    resp="$(tg_call sendDocument --form-string "chat_id=$TG_CHAT" --form-string "caption=$2" -F "document=@$1" 2>&1)" || return 1
    grep -qE '"ok"[[:space:]]*:[[:space:]]*true' <<< "$resp"
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
    grep -qE '"ok"[[:space:]]*:[[:space:]]*true' <<< "$resp" || fail "Telegram не принял токен"
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

# ----- Бэкап -----
stage_files() {
    local stage="$1" p

    if is_postgres; then
        warn "3x-ui работает на PostgreSQL: сама база не копируется, делайте pg_dump отдельно."
    elif [[ -f "$XUI_DB" ]]; then
        mkdir -p "$stage$XUI_DIR"
        sqlite3 "$XUI_DB" ".backup '$stage$XUI_DB'" || fail "Не удалось сделать копию базы $XUI_DB"
    else
        fail "База $XUI_DB не найдена. Установлен ли 3x-ui?"
    fi

    # Прочие файлы каталога x-ui (кроме базы, WAL и логов)
    if [[ -d "$XUI_DIR" ]]; then
        mkdir -p "$stage$XUI_DIR"
        find "$XUI_DIR" -maxdepth 1 -type f ! -name '*.db' ! -name '*.db-wal' ! -name '*.db-shm' ! -name '*.log' \
            -exec cp -p {} "$stage$XUI_DIR/" \;
    fi
    if [[ -f "$XUI_ENV_FILE" ]]; then cp -p --parents "$XUI_ENV_FILE" "$stage"; fi
    if [[ -f "$XRAY_CONFIG" ]]; then cp -p --parents "$XRAY_CONFIG" "$stage"; fi

    for p in "${INCLUDES[@]+"${INCLUDES[@]}"}"; do
        if [[ -e "$p" ]]; then
            cp -a --parents "$p" "$stage"
        else
            warn "Путь из --include не найден, пропускаю: $p"
        fi
    done
}

ensure_sqlite() {
    if command -v sqlite3 >/dev/null 2>&1; then return 0; fi
    info "Устанавливаю sqlite3..."
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq sqlite3 >/dev/null || fail "Не удалось установить sqlite3"
}

STAGE=""
cleanup() {
    if [[ -n "$STAGE" ]]; then rm -rf "$STAGE"; fi
}
trap cleanup EXIT

ARCHIVE_PATH=""
make_archive() {
    # make_archive PREFIX -> путь к созданному архиву в переменной ARCHIVE_PATH
    local prefix="$1" name
    name="${prefix}-$(hostname -s)-$(date +%Y%m%d-%H%M%S).tar.gz"
    ARCHIVE_PATH="$BACKUP_DIR/$name"
    STAGE="$(mktemp -d /tmp/vps-tools-backup.XXXXXX)"

    stage_files "$STAGE"
    printf 'host=%s\ndate=%s\n' "$(hostname)" "$(date '+%F %T %z')" > "$STAGE/backup-info.txt"

    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    (umask 077; tar -C "$STAGE" -czf "$ARCHIVE_PATH" .)
    rm -rf "$STAGE"
    STAGE=""
}

rotate() {
    local count=0 f
    while read -r f; do
        rm -f -- "$f"
        count=$((count + 1))
    done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name '3xui-*.tar.gz' -printf '%T@ %p\n' \
                | sort -rn | tail -n +$((KEEP + 1)) | cut -d' ' -f2-)
    if (( count > 0 )); then info "Удалено старых архивов: $count (храню последние $KEEP)"; fi
}

do_backup() {
    need_root_unless_dry
    if [[ $DRY -eq 1 ]]; then
        info "[dry-run] архив будет создан в $BACKUP_DIR, хранится последних: $KEEP"
        if is_postgres; then
            info "[dry-run] PostgreSQL: база не копируется"
        else
            info "[dry-run] база: $XUI_DB ($( [[ -f "$XUI_DB" ]] && echo найдена || echo НЕ найдена ))"
        fi
        local p
        for p in "$XUI_DIR" "$XUI_ENV_FILE" "$XRAY_CONFIG" "${INCLUDES[@]+"${INCLUDES[@]}"}"; do
            if [[ -e "$p" ]]; then info "[dry-run] включено: $p"; else info "[dry-run] нет на сервере: $p"; fi
        done
        if tg_load && [[ $NO_TG -eq 0 ]]; then info "[dry-run] будет отправлен в Telegram"; else info "[dry-run] Telegram не используется"; fi
        return 0
    fi

    ensure_sqlite
    if command -v flock >/dev/null 2>&1; then
        mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
        exec 9>"$LOCK_FILE"
        flock -n 9 || fail "Другой бэкап уже выполняется"
    fi

    local out size
    make_archive 3xui
    out="$ARCHIVE_PATH"
    size="$(stat -c %s "$out")"
    ok "Бэкап создан: $out ($(human_size "$size"))"
    rotate

    if [[ $NO_TG -eq 1 ]]; then
        info "Отправка в Telegram пропущена (--no-telegram)"
    elif tg_load; then
        if (( size > 49000000 )); then
            warn "Архив больше 49 МБ, Telegram его не примет. Остался только на сервере."
        elif tg_send_file "$out" "Бэкап 3x-ui | $(hostname) | $(date '+%F %H:%M') | $(human_size "$size")"; then
            ok "Отправлено в Telegram"
        else
            warn "Не удалось отправить в Telegram (бэкап на сервере цел)"
        fi
    else
        info "Telegram не настроен: архив только на сервере (настроить: --setup-telegram)"
    fi
}

need_root_unless_dry() {
    if [[ $DRY -eq 0 ]]; then need_root; fi
}

do_list() {
    if [[ ! -d "$BACKUP_DIR" ]]; then info "Каталог $BACKUP_DIR пока не создан"; return 0; fi
    local f found=0
    while read -r f; do
        found=1
        printf '%s  %s\n' "$(human_size "$(stat -c %s "$f")")" "$f"
    done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name '*3xui-*.tar.gz' | sort -r)
    if [[ $found -eq 0 ]]; then info "Архивов нет"; fi
}

# ----- cron -----
do_install_cron() {
    need_root
    local src="$0" tmp args=""
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

    if [[ "$BACKUP_DIR" != "/var/backups/3x-ui" ]]; then args+=" --dir $(printf '%q' "$BACKUP_DIR")"; fi
    if [[ "$KEEP" != "14" ]]; then args+=" --keep $KEEP"; fi
    local p
    for p in "${INCLUDES[@]+"${INCLUDES[@]}"}"; do args+=" --include $(printf '%q' "$p")"; done

    args="${args//%/\\%}"   # в cron символ % означает перевод строки
    {
        echo "# vps-tools: ежедневный бэкап 3x-ui (создано backup-3xui.sh --install-cron)"
        echo "SHELL=/bin/bash"
        echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        echo "${CRON_TIME#*:} ${CRON_TIME%:*} * * * root $INSTALL_PATH --quiet$args >> $LOG_FILE 2>&1"
    } > "$CRON_FILE"
    chmod 644 "$CRON_FILE"
    ok "Бэкап по расписанию: каждый день в $CRON_TIME (скрипт: $INSTALL_PATH, лог: $LOG_FILE)"
}

do_remove_cron() {
    need_root
    rm -f "$CRON_FILE" "$INSTALL_PATH"
    ok "Расписание убрано (архивы в $BACKUP_DIR не тронуты)"
}

# ----- Восстановление -----
do_restore() {
    need_root
    local file="$ARG_FILE"
    [[ -f "$file" ]] || fail "Файл не найден: $file"
    tar -tzf "$file" >/dev/null 2>&1 || fail "Не удалось прочитать архив (повреждён?)"
    if tar -tzf "$file" | grep -qE '(^/|(^|/)\.\.(/|$))'; then
        fail "В архиве есть небезопасные пути (абсолютные или с ..). Восстановление отменено."
    fi

    echo -e "${BLUE}Восстановление из: $file${NC}"
    echo "Будут перезаписаны файлы:"
    tar -tzf "$file" | grep -v '/$' | grep -v 'backup-info.txt' | sed 's#^\./#  /#'
    echo ""
    echo "Перед этим будет сделана резервная копия текущего состояния и остановлен x-ui."
    if [[ $YES -eq 0 ]]; then
        local ans=""
        if ! read -r -p "Продолжить? [y/N] " ans 2>/dev/null </dev/tty; then
            fail "Нет терминала для подтверждения. Запустите с --yes."
        fi
        if [[ "$ans" != "y" && "$ans" != "Y" && "$ans" != "yes" ]]; then info "Отменено."; return 0; fi
    fi

    ensure_sqlite
    local safety
    make_archive prerestore-3xui
    safety="$ARCHIVE_PATH"
    ok "Копия текущего состояния: $safety"

    systemctl stop x-ui 2>/dev/null || warn "Не удалось остановить x-ui (возможно, он не запущен)"
    rm -f "${XUI_DB}-wal" "${XUI_DB}-shm"
    # --no-overwrite-dir: не менять права и владельца уже существующих каталогов (/, /etc, /root...)
    tar -xzf "$file" -C / --no-same-owner --no-overwrite-dir --exclude='./backup-info.txt'
    chmod 600 "$XUI_DB" 2>/dev/null || true
    if systemctl start x-ui 2>/dev/null && systemctl is-active --quiet x-ui; then
        ok "Восстановлено, x-ui запущен"
    else
        warn "Файлы восстановлены, но x-ui не запустился. Проверьте: systemctl status x-ui"
        warn "Вернуть прежнее состояние: $0 --restore $safety"
    fi
}

echo_header() {
    if [[ $QUIET -eq 0 ]]; then
        echo -e "${BLUE}============================================${NC}"
        echo -e "${BLUE}  Backup 3x-ui${NC}"
        echo -e "${BLUE}============================================${NC}"
    fi
}

echo_header
case "$ACTION" in
    backup)         do_backup ;;
    setup-telegram) do_setup_telegram ;;
    install-cron)   do_install_cron ;;
    remove-cron)    do_remove_cron ;;
    list)           do_list ;;
    restore)        do_restore ;;
esac
