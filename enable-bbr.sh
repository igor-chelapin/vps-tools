#!/bin/bash
# ============================================================
# Enable BBR — включает TCP BBR и очередь fq на Ubuntu.
# Идемпотентен: если BBR уже включён, ничего не меняет.
# Совместим с x-ui (меню BBR) — не конфликтует с его настройкой.
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

SYSCTL_CONF="${SYSCTL_CONF:-/etc/sysctl.d/99-vps-tools-bbr.conf}"
MODULES_CONF="${MODULES_CONF:-/etc/modules-load.d/vps-tools-bbr.conf}"
XUI_BBR_CONF="/etc/sysctl.d/99-bbr-x-ui.conf"

ACTION="enable"
TUNE=0
DRY=0

usage() {
    cat <<'EOF'
Использование: enable-bbr.sh [опции]

  (без опций)   включить BBR + fq
  --tune        дополнительно применить умеренную настройку TCP
                (tcp_fastopen, mtu_probing, slow_start_after_idle, somaxconn, syn_backlog)
  --status      показать текущее состояние и выйти
  --disable     вернуть cubic и убрать настройки этого скрипта
  --dry-run     только показать, что будет сделано
  -h, --help    эта справка
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tune)    TUNE=1 ;;
        --status)  ACTION="status" ;;
        --disable) ACTION="disable" ;;
        --dry-run) DRY=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Неизвестная опция: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

cur_cc()  { sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?"; }
cur_qd()  { sysctl -n net.core.default_qdisc 2>/dev/null || echo "?"; }
avail_cc() { sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo ""; }

bbr_active() {
    [[ "$(cur_cc)" == "bbr" ]] && [[ "$(cur_qd)" =~ ^(fq|cake)$ ]]
}

need_root() {
    if [[ $DRY -eq 0 && $EUID -ne 0 ]]; then
        fail "Запусти скрипт от root"
    fi
}

show_status() {
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}  BBR: состояние${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo "Алгоритм (tcp_congestion_control): $(cur_cc)"
    echo "Очередь  (default_qdisc):          $(cur_qd)"
    echo "Доступные алгоритмы:               $(avail_cc)"
    [[ -f "$SYSCTL_CONF" ]] && echo "Конфиг скрипта:                    $SYSCTL_CONF"
    [[ -f "$XUI_BBR_CONF" ]] && echo "Конфиг x-ui:                       $XUI_BBR_CONF"
    if bbr_active; then
        ok "BBR включён"
    else
        warn "BBR не включён"
    fi
}

check_environment() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        if [[ "${ID:-}" != "ubuntu" ]]; then
            warn "Скрипт рассчитан на Ubuntu, найдено: ${PRETTY_NAME:-неизвестно}. Продолжаю."
        fi
    fi

    local kv major minor
    kv="$(uname -r | cut -d. -f1,2)"
    major="${kv%%.*}"
    minor="${kv##*.}"
    if [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]]; then
        if (( major < 4 || (major == 4 && minor < 9) )); then
            fail "Ядро $(uname -r) слишком старое: BBR нужно ядро 4.9 или новее"
        fi
    fi

    if command -v systemd-detect-virt >/dev/null 2>&1; then
        local virt
        virt="$(systemd-detect-virt -c 2>/dev/null || true)"
        if [[ "$virt" == "openvz" || "$virt" == "lxc" || "$virt" == "lxc-libvirt" ]]; then
            warn "Виртуализация уровня контейнера ($virt): сетевые параметры ядра часто нельзя менять из гостя."
            warn "Если ниже появится ошибка, включить BBR можно только на стороне хостера."
        fi
    fi
}

render_conf() {
    cat <<'EOF'
# Создано vps-tools/enable-bbr.sh
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    if [[ $TUNE -eq 1 ]]; then
        cat <<'EOF'

# Умеренная настройка TCP (опция --tune)
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
EOF
    fi
}

do_enable() {
    check_environment

    if bbr_active && [[ $TUNE -eq 0 ]]; then
        ok "BBR уже включён ($(cur_cc) + $(cur_qd)). Ничего менять не нужно."
        [[ -f "$XUI_BBR_CONF" ]] && info "Настройка сохранена x-ui в $XUI_BBR_CONF, она переживёт перезагрузку."
        return 0
    fi

    if [[ $DRY -eq 1 ]]; then
        info "[dry-run] modprobe tcp_bbr; запись $MODULES_CONF"
        info "[dry-run] будет записан $SYSCTL_CONF:"
        render_conf | sed 's/^/    /'
        info "[dry-run] sysctl -p $SYSCTL_CONF"
        return 0
    fi

    need_root

    info "Загрузка модуля tcp_bbr..."
    modprobe tcp_bbr 2>/dev/null || true
    if ! avail_cc | tr ' ' '\n' | grep -qx bbr; then
        fail "Ядро не предлагает BBR (доступно: $(avail_cc)). Возможно, это контейнерный VPS."
    fi

    # Прежнее содержимое храним в памяти, чтобы откатиться без лишних файлов
    local had_prev=0 prev=""
    if [[ -f "$SYSCTL_CONF" ]]; then
        had_prev=1
        prev="$(cat "$SYSCTL_CONF")"
    fi
    rollback() {
        if [[ $had_prev -eq 1 ]]; then
            printf '%s\n' "$prev" > "$SYSCTL_CONF"
        else
            rm -f "$SYSCTL_CONF" "$MODULES_CONF"
        fi
    }

    mkdir -p "$(dirname "$SYSCTL_CONF")" "$(dirname "$MODULES_CONF")"
    render_conf > "$SYSCTL_CONF"
    echo "tcp_bbr" > "$MODULES_CONF"
    ok "Настройки записаны: $SYSCTL_CONF"

    info "Применение настроек..."
    if ! sysctl -p "$SYSCTL_CONF" >/dev/null; then
        warn "sysctl вернул ошибку, откатываю изменения"
        rollback
        fail "Не удалось применить настройки"
    fi

    if bbr_active; then
        ok "BBR включён: $(cur_cc) + $(cur_qd)"
        if [[ $TUNE -eq 1 ]]; then
            ok "Дополнительная настройка TCP применена"
        fi
        info "Настройки сохранятся после перезагрузки."
    else
        rollback
        fail "BBR не включился (сейчас: $(cur_cc) + $(cur_qd)). Изменения отменены."
    fi
}

do_disable() {
    if [[ $DRY -eq 1 ]]; then
        info "[dry-run] будут удалены $SYSCTL_CONF и $MODULES_CONF, затем cubic + fq_codel"
        return 0
    fi
    need_root
    local changed=0
    for f in "$SYSCTL_CONF" "$MODULES_CONF"; do
        if [[ -f "$f" ]]; then rm -f "$f"; ok "Удалён $f"; changed=1; fi
    done
    [[ $changed -eq 0 ]] && info "Файлов этого скрипта нет, нечего удалять."

    if sysctl -w net.ipv4.tcp_congestion_control=cubic net.core.default_qdisc=fq_codel >/dev/null; then
        ok "Сейчас: $(cur_cc) + $(cur_qd)"
    else
        warn "Не удалось переключить алгоритм на лету"
    fi

    if [[ -f "$XUI_BBR_CONF" ]]; then
        warn "Остался файл x-ui: $XUI_BBR_CONF — после перезагрузки BBR включится снова."
        warn "Отключить его можно в меню x-ui (пункт BBR → Disable BBR)."
    fi
    if [[ $TUNE -eq 1 ]]; then
        info "Опция --tune при --disable не нужна; значения вернутся к умолчанию после перезагрузки."
    fi
}

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  Enable BBR${NC}"
echo -e "${BLUE}============================================${NC}"

case "$ACTION" in
    status)  show_status ;;
    disable) do_disable ;;
    enable)  do_enable ;;
esac
