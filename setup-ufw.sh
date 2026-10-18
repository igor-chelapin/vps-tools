#!/bin/bash
# ============================================================
# Setup UFW — настраивает файрвол для VPN-сервера с 3x-ui (Ubuntu).
# Сам находит нужные порты: SSH, 80/443, панель, подписки и все
# включённые inbound'ы из базы 3x-ui. Перед включением показывает
# список и просит подтверждение, чтобы не отрезать вас от сервера.
# ============================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[✓] $*${NC}"; }
info() { echo -e "${YELLOW}[*] $*${NC}"; }
warn() { echo -e "${YELLOW}[!] $*${NC}"; }
fail() { echo -e "${RED}[✗] $*${NC}" >&2; exit 1; }

# Пути можно переопределить переменными окружения (нестандартная установка)
XUI_DB="${XUI_DB:-/etc/x-ui/x-ui.db}"
XUI_BIN="${XUI_BIN:-/usr/local/x-ui/x-ui}"
XUI_ENV_FILE="${XUI_ENV_FILE:-/etc/default/x-ui}"

YES=0
DRY=0
WEB=1
EXTRA=()

usage() {
    cat <<'EOF'
Использование: setup-ufw.sh [опции]

  --allow PORT[/tcp|/udp]  открыть дополнительный порт (можно несколько раз);
                           без протокола открываются tcp и udp
  --no-web                 не открывать 80 и 443
  --yes                    не спрашивать подтверждение
  --dry-run                только показать план, ничего не менять
  -h, --help               эта справка

Переменные окружения: XUI_DB, XUI_BIN, XUI_ENV_FILE (пути 3x-ui, если они нестандартные).
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --allow)
            [[ $# -ge 2 ]] || { echo "--allow требует аргумент" >&2; exit 2; }
            EXTRA+=("$2"); shift ;;
        --no-web)  WEB=0 ;;
        --yes|-y)  YES=1 ;;
        --dry-run) DRY=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Неизвестная опция: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# ----- Список правил: ключ "порт/протокол" -> причина -----
declare -A REASON=()
ORDER=()
SSH_FOUND=0

add_rule() {
    local port="$1" proto="$2" reason="$3" key
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        warn "Пропускаю некорректный порт: $port"
        return 0
    fi
    key="$port/$proto"
    if [[ -z "${REASON[$key]+x}" ]]; then
        ORDER+=("$key")
        REASON[$key]="$reason"
    elif [[ "${REASON[$key]}" != *"$reason"* ]]; then
        REASON[$key]+=", $reason"
    fi
}

sql() {
    sqlite3 -readonly -cmd ".timeout 3000" "$XUI_DB" "$1"
}

is_postgres() {
    [[ -r "$XUI_ENV_FILE" ]] && grep -q '^XUI_DB_TYPE=postgres' "$XUI_ENV_FILE"
}

setting() {
    # setting KEY DEFAULT -> значение из базы или значение по умолчанию 3x-ui
    local key="$1" def="$2" val
    val="$(sql "SELECT value FROM settings WHERE \"key\"='$key' LIMIT 1;" 2>/dev/null || true)"
    echo "${val:-$def}"
}

is_local_listen() {
    case "$1" in
        127.*|::1|localhost|@*) return 0 ;;
        *) return 1 ;;
    esac
}

# ----- Сбор портов -----
detect_ssh() {
    local p
    while read -r p; do
        [[ -n "$p" ]] && { add_rule "$p" tcp "SSH"; SSH_FOUND=1; }
    done < <(sshd -T 2>/dev/null | awk '$1=="port"{print $2}')

    # Порт текущего подключения (на случай нестандартной схемы)
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        p="${SSH_CONNECTION##* }"
        if [[ "$p" =~ ^[0-9]+$ ]]; then add_rule "$p" tcp "SSH (текущее подключение)"; SSH_FOUND=1; fi
    fi

    if [[ $SSH_FOUND -eq 0 ]]; then
        info "Порт SSH определить не удалось, использую 22"
        add_rule 22 tcp "SSH (по умолчанию)"
        SSH_FOUND=1
    fi
}

detect_xui() {
    if [[ ! -f "$XUI_DB" && ! -x "$XUI_BIN" ]]; then
        info "3x-ui не найден, открываю только SSH и веб-порты"
        return 0
    fi
    if is_postgres; then
        warn "3x-ui работает на PostgreSQL: порты inbound'ов автоматически не читаются."
        warn "Добавьте их вручную: --allow ПОРТ/tcp (или /udp)."
        return 0
    fi
    if [[ ! -f "$XUI_DB" ]]; then
        warn "База $XUI_DB не найдена, порты 3x-ui не определены"
        return 0
    fi
    if ! command -v sqlite3 >/dev/null 2>&1; then
        if [[ $DRY -eq 1 ]]; then
            warn "[dry-run] нет sqlite3, порты 3x-ui не прочитаны (при реальном запуске он будет установлен)"
            return 0
        fi
        info "Устанавливаю sqlite3 для чтения базы 3x-ui..."
        apt-get install -y -qq sqlite3 >/dev/null || fail "Не удалось установить sqlite3"
    fi

    # Панель
    local web_listen web_port
    web_listen="$(setting webListen "")"
    web_port="$(setting webPort 2053)"
    if is_local_listen "$web_listen"; then
        info "Панель слушает только локально ($web_listen), порт $web_port не открываю"
    else
        add_rule "$web_port" tcp "панель 3x-ui"
    fi

    # Подписки
    if [[ "$(setting subEnable true)" == "true" ]]; then
        local sub_listen sub_port
        sub_listen="$(setting subListen "")"
        sub_port="$(setting subPort 2096)"
        if is_local_listen "$sub_listen"; then
            info "Подписки слушают только локально ($sub_listen), порт $sub_port не открываю"
        else
            add_rule "$sub_port" tcp "подписки 3x-ui"
        fi
    fi

    # Inbound'ы
    local rows
    if ! rows="$(sql "SELECT port, IFNULL(listen,''), protocol,
        CASE WHEN json_valid(stream_settings) THEN IFNULL(json_extract(stream_settings,'\$.network'),'') ELSE '' END,
        CASE WHEN json_valid(stream_settings) THEN IFNULL(json_extract(stream_settings,'\$.tlsSettings.alpn'),'') ELSE '' END,
        IFNULL(remark,'')
        FROM inbounds WHERE enable=1 AND port>0 ORDER BY port;" 2>&1)"; then
        warn "Не удалось прочитать inbound'ы из базы: $rows"
        return 0
    fi

    local port listen protocol network alpn remark label proto_mode
    while IFS='|' read -r port listen protocol network alpn remark; do
        [[ -n "$port" ]] || continue
        label="inbound ${protocol}${remark:+ \"$remark\"}"
        if is_local_listen "$listen"; then
            info "Inbound $port ($protocol) слушает локально ($listen), пропускаю"
            continue
        fi
        # Какие протоколы нужны
        proto_mode="tcp"
        case "$protocol" in
            hysteria|wireguard|tuic|amneziawg|masque) proto_mode="udp" ;;
            shadowsocks|tunnel|mixed) proto_mode="both" ;;
        esac
        case "$network" in
            kcp|mkcp|hysteria|quic|masque) proto_mode="udp" ;;
        esac
        if [[ "$alpn" == *h3* && "$proto_mode" == "tcp" ]]; then
            proto_mode="both"   # HTTP/3 идёт по QUIC (UDP)
        fi
        case "$proto_mode" in
            tcp)  add_rule "$port" tcp "$label" ;;
            udp)  add_rule "$port" udp "$label" ;;
            both) add_rule "$port" tcp "$label"; add_rule "$port" udp "$label" ;;
        esac
    done <<< "$rows"
}

# ----- Отображение и применение -----
rule_cmd() {
    local key="$1" port proto
    port="${key%/*}"; proto="${key#*/}"
    if [[ "$proto" == "any" ]]; then echo "$port"; else echo "$port/$proto"; fi
}

print_plan() {
    local key
    echo ""
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}  ПЛАН: будут открыты порты${NC}"
    echo -e "${BLUE}============================================${NC}"
    for key in "${ORDER[@]}"; do
        printf '  %-12s %s\n' "$(rule_cmd "$key")" "${REASON[$key]}"
    done
    echo -e "${BLUE}============================================${NC}"
    echo "  Всё остальное входящее будет закрыто, исходящее разрешено."
    echo ""
}

confirm() {
    [[ $YES -eq 1 ]] && return 0
    local ans=""
    # Читаем с терминала, а не из stdin: так работает и при запуске через pipe
    if ! read -r -p "Применить? [y/N] " ans 2>/dev/null </dev/tty; then
        fail "Нет терминала для подтверждения. Запустите с --yes."
    fi
    [[ "$ans" == "y" || "$ans" == "Y" || "$ans" == "yes" ]]
}

apply() {
    if ! command -v ufw >/dev/null 2>&1; then
        info "Устанавливаю ufw..."
        apt-get update -qq
        apt-get install -y -qq ufw >/dev/null
    fi

    if grep -qi '^IPV6=no' /etc/default/ufw 2>/dev/null; then
        warn "В /etc/default/ufw отключён IPv6 (IPV6=no): правила не будут действовать на IPv6."
    fi

    local was_active=0 key
    if ufw status | grep -q "^Status: active"; then
        was_active=1
        info "ufw уже включён: добавляю недостающие правила, существующие не трогаю"
    else
        ufw default deny incoming >/dev/null
        ufw default allow outgoing >/dev/null
        ok "Политика по умолчанию: входящие закрыты, исходящие открыты"
    fi

    for key in "${ORDER[@]}"; do
        ufw allow "$(rule_cmd "$key")" comment "vps-tools: ${REASON[$key]}" >/dev/null
    done
    ok "Правила добавлены: ${#ORDER[@]}"

    if [[ $was_active -eq 0 ]]; then
        ufw --force enable >/dev/null
        ok "ufw включён"
    fi

    echo ""
    ufw status verbose
}

# ----- Запуск -----
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  Setup UFW${NC}"
echo -e "${BLUE}============================================${NC}"

if [[ $DRY -eq 0 && $EUID -ne 0 ]]; then
    fail "Запусти скрипт от root"
fi

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
        warn "Скрипт рассчитан на Ubuntu, найдено: ${PRETTY_NAME:-неизвестно}. Продолжаю."
    fi
fi

detect_ssh
if [[ $WEB -eq 1 ]]; then
    add_rule 80 tcp "HTTP"
    add_rule 443 tcp "HTTPS"
fi
detect_xui

for item in "${EXTRA[@]+"${EXTRA[@]}"}"; do
    port="${item%%/*}"
    proto="any"
    [[ "$item" == */* ]] && proto="${item#*/}"
    if [[ "$proto" != "any" && "$proto" != "tcp" && "$proto" != "udp" ]]; then
        fail "Неверный протокол в --allow $item (нужно tcp или udp)"
    fi
    add_rule "$port" "$proto" "вручную (--allow)"
done

if command -v docker >/dev/null 2>&1; then
    warn "Найден Docker: порты контейнеров, опубликованные через -p, ufw не фильтрует."
fi

print_plan

if [[ $DRY -eq 1 ]]; then
    info "[dry-run] ничего не изменено. Команды, которые будут выполнены:"
    echo "    ufw default deny incoming; ufw default allow outgoing"
    for key in "${ORDER[@]}"; do
        echo "    ufw allow $(rule_cmd "$key")"
    done
    echo "    ufw --force enable"
    exit 0
fi

if ! confirm; then
    info "Отменено, ничего не изменено."
    exit 0
fi

apply

echo ""
warn "Не закрывайте текущую SSH-сессию: откройте новое окно и убедитесь, что вход работает."
warn "Если доступ потерян, отключите файрвол через консоль хостера: ufw disable"
