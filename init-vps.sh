#!/bin/bash
# ============================================================
# Init VPS — первичная настройка свежего Ubuntu VPS одной командой.
# Обновления, (опционально) sudo-пользователь и SSH-ключ, swap, BBR,
# fail2ban, файрвол ufw. Вход по паролю отключается ПОСЛЕДНИМ и только
# если на сервере есть рабочий SSH-ключ.
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
err()  { echo -e "${RED}[✗] $*${NC}" >&2; }
fail() { err "$*"; exit 1; }

BASE="${VPS_TOOLS_BASE:-https://raw.githubusercontent.com/igor-chelapin/vps-tools/vps-tools}"

# Пути можно переопределить (нестандартные системы, тесты)
SWAPFILE="${SWAPFILE:-/swapfile}"
FSTAB="${FSTAB:-/etc/fstab}"
SUDOERS_DIR="${SUDOERS_DIR:-/etc/sudoers.d}"
SSHD_DROPIN_DIR="${SSHD_DROPIN_DIR:-/etc/ssh/sshd_config.d}"
APT_AUTO_CONF="${APT_AUTO_CONF:-/etc/apt/apt.conf.d/20auto-upgrades}"
SYSCTL_DIR="${SYSCTL_DIR:-/etc/sysctl.d}"

ALL_STEPS=(update user swap bbr fail2ban ufw password)

YES=0
DRY=0
SKIP=""
ONLY=""
USER_NAME=""
SSH_KEY=""
SSH_KEY_FILE=""
SWAP_ARG="auto"
TUNE=0
DISABLE_ROOT=0
KEEP_PASSWORD=0
ALLOW=()

usage() {
    cat <<'EOF'
Использование: init-vps.sh [опции]

Шаги выполняются по порядку:
  update    обновление системы, автоматические обновления безопасности
  user      создание sudo-пользователя (только с --user)
  swap      файл подкачки для серверов с малым объёмом памяти
  bbr       включение BBR            (enable-bbr.sh)
  fail2ban  защита SSH от перебора   (install-fail2ban.sh)
  ufw       файрвол                  (setup-ufw.sh)
  password  отключение входа по паролю (disable-ssh-password.sh), всегда последним

Опции:
  --user NAME            создать пользователя NAME с правом sudo
  --ssh-key "KEY"        добавить этот публичный SSH-ключ
  --ssh-key-file FILE    добавить ключи из файла (например ~/.ssh/id_ed25519.pub)
  --disable-root-login   запретить вход под root (только вместе с --user)
  --swap SIZE            размер swap: 512M, 1G, 2G..., 0 — не создавать;
                         по умолчанию auto (по объёму памяти)
  --tune                 дополнительная настройка TCP вместе с BBR
  --allow PORT[/proto]   открыть дополнительный порт в ufw (можно несколько раз)
  --keep-password        не отключать вход по паролю
  --skip LIST            пропустить шаги (через запятую): --skip swap,bbr
  --only LIST            выполнить только эти шаги
  --yes                  не задавать вопросов (подтверждает и отключение пароля!)
  --dry-run              показать план, ничего не меняя
  -h, --help             эта справка

Без --ssh-key и без ключа на сервере скрипт спросит ключ. Если ключа нет совсем,
вход по паролю НЕ отключается.
EOF
}

need_arg() { if [[ $2 -lt 2 ]]; then echo "$1 требует аргумент" >&2; exit 2; fi; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)         need_arg "$1" $#; USER_NAME="$2"; shift ;;
        --ssh-key)      need_arg "$1" $#; SSH_KEY="$2"; shift ;;
        --ssh-key-file) need_arg "$1" $#; SSH_KEY_FILE="$2"; shift ;;
        --swap)         need_arg "$1" $#; SWAP_ARG="$2"; shift ;;
        --allow)        need_arg "$1" $#; ALLOW+=("$2"); shift ;;
        --skip)         need_arg "$1" $#; SKIP="$2"; shift ;;
        --only)         need_arg "$1" $#; ONLY="$2"; shift ;;
        --disable-root-login) DISABLE_ROOT=1 ;;
        --tune)         TUNE=1 ;;
        --keep-password) KEEP_PASSWORD=1 ;;
        --yes|-y)       YES=1 ;;
        --dry-run)      DRY=1 ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "Неизвестная опция: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# ----- Проверка аргументов -----
valid_step() {
    local s
    for s in "${ALL_STEPS[@]}"; do [[ "$s" == "$1" ]] && return 0; done
    return 1
}
for list in "$SKIP" "$ONLY"; do
    IFS=',' read -r -a _items <<< "$list"
    for it in "${_items[@]+"${_items[@]}"}"; do
        [[ -z "$it" ]] && continue
        valid_step "$it" || { echo "Неизвестный шаг: $it (доступны: ${ALL_STEPS[*]})" >&2; exit 2; }
    done
done
if [[ -n "$USER_NAME" ]] && ! [[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo "Некорректное имя пользователя: $USER_NAME" >&2; exit 2
fi
if [[ "$SWAP_ARG" != "auto" && "$SWAP_ARG" != "0" ]] && ! [[ "$SWAP_ARG" =~ ^[1-9][0-9]*[MG]$ ]]; then
    echo "--swap: нужно auto, 0 или размер вроде 512M, 1G" >&2; exit 2
fi
if [[ $DISABLE_ROOT -eq 1 && -z "$USER_NAME" ]]; then
    echo "--disable-root-login требует --user: иначе войти на сервер будет нельзя" >&2; exit 2
fi
if [[ -n "$SSH_KEY_FILE" && ! -r "$SSH_KEY_FILE" ]]; then
    echo "Файл с ключами не найден: $SSH_KEY_FILE" >&2; exit 2
fi

in_list() {
    # in_list ITEM "a,b,c"
    [[ ",$2," == *",$1,"* ]]
}

step_enabled() {
    local s="$1"
    if [[ -n "$ONLY" ]] && ! in_list "$s" "$ONLY"; then return 1; fi
    if [[ -n "$SKIP" ]] && in_list "$s" "$SKIP"; then return 1; fi
    case "$s" in
        user)     [[ -n "$USER_NAME" ]] || return 1 ;;
        password) [[ $KEEP_PASSWORD -eq 0 ]] || return 1 ;;
    esac
    return 0
}

# ----- Загрузка вспомогательных скриптов -----
TMP_DIR=""
cleanup() { if [[ -n "$TMP_DIR" ]]; then rm -rf "$TMP_DIR"; fi; }
trap cleanup EXIT

SELF_DIR=""
if [[ -f "$0" && "$0" != /dev/fd/* && "$0" != /proc/* ]]; then
    SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

fetch_script() {
    # Печатает путь к скрипту: рядом с init-vps.sh или скачанный
    local name="$1" path
    if [[ -n "$SELF_DIR" && -f "$SELF_DIR/$name" ]]; then
        echo "$SELF_DIR/$name"
        return 0
    fi
    if [[ -z "$TMP_DIR" ]]; then TMP_DIR="$(mktemp -d /tmp/vps-tools-init.XXXXXX)"; fi
    path="$TMP_DIR/$name"
    if [[ ! -f "$path" ]]; then
        curl -fsSL "$BASE/$name" -o "$path" || { err "Не удалось скачать $BASE/$name"; return 1; }
        if ! head -1 "$path" | grep -qE '^#!.*(bash|sh)' || [[ "$(wc -c < "$path")" -lt 200 ]]; then
            err "Скачан неожиданный файл: $name"; return 1
        fi
    fi
    echo "$path"
}

run_sub() {
    local name="$1" path
    shift
    path="$(fetch_script "$name")" || return 1
    bash "$path" "$@"
}

# ----- Ключи -----
KEY_RE='(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/=]+'

key_is_valid() {
    # Проверка отдельной строки публичного ключа через ssh-keygen
    local line="$1" tmp rc=0
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        grep -qE "^$KEY_RE" <<< "$line"   # без ssh-keygen проверяем только формат
        return
    fi
    tmp="$(mktemp)"
    printf '%s\n' "$line" > "$tmp"
    ssh-keygen -l -f "$tmp" >/dev/null 2>&1 || rc=1
    rm -f "$tmp"
    return $rc
}

count_keys() {
    # Сколько строк с ключами в файле authorized_keys
    local f="$1"
    [[ -f "$f" ]] || { echo 0; return 0; }
    grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null | grep -cE "$KEY_RE" || true
}

NEW_KEYS=()
collect_keys() {
    local line
    if [[ -n "$SSH_KEY" ]]; then NEW_KEYS+=("$SSH_KEY"); fi
    if [[ -n "$SSH_KEY_FILE" ]]; then
        while IFS= read -r line; do
            [[ -z "${line// }" || "$line" == \#* ]] && continue
            NEW_KEYS+=("$line")
        done < "$SSH_KEY_FILE"
    fi
    local valid=() k
    for k in "${NEW_KEYS[@]+"${NEW_KEYS[@]}"}"; do
        if key_is_valid "$k"; then
            valid+=("$k")
        else
            warn "Ключ не прошёл проверку и пропущен: ${k:0:40}..."
        fi
    done
    NEW_KEYS=("${valid[@]+"${valid[@]}"}")
}

install_keys_for() {
    # install_keys_for USER HOME KEY...
    local user="$1" home="$2" dir file k added=0
    shift 2
    dir="$home/.ssh"
    file="$dir/authorized_keys"
    mkdir -p "$dir"
    touch "$file"
    for k in "$@"; do
        if ! grep -qxF "$k" "$file"; then
            printf '%s\n' "$k" >> "$file"
            added=$((added + 1))
        fi
    done
    chmod 700 "$dir"
    chmod 600 "$file"
    chown -R "$user:$(id -gn "$user")" "$dir"
    echo "$added"
}

home_of() {
    if [[ "$1" == "root" && -n "${ROOT_HOME:-}" ]]; then echo "$ROOT_HOME"; return 0; fi
    getent passwd "$1" | cut -d: -f6
}

# ----- Шаги -----
declare -A RESULT=()

step_update() {
    export DEBIAN_FRONTEND=noninteractive
    local apt_opts=(-y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o DPkg::Lock::Timeout=180)
    info "Обновление списка пакетов и системы..."
    apt-get update -qq
    apt-get "${apt_opts[@]}" upgrade
    apt-get "${apt_opts[@]}" install unattended-upgrades curl ca-certificates sqlite3
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' > "$APT_AUTO_CONF"
    ok "Система обновлена, автоматические обновления безопасности включены"
}

step_user() {
    local home k keys=() added
    if id "$USER_NAME" >/dev/null 2>&1; then
        info "Пользователь $USER_NAME уже существует"
    else
        adduser --disabled-password --gecos "" "$USER_NAME" >/dev/null
        ok "Пользователь $USER_NAME создан"
    fi
    usermod -aG sudo "$USER_NAME"

    # sudo без пароля: у пользователя нет пароля, а вход только по ключу
    local sf="$SUDOERS_DIR/90-vps-tools-$USER_NAME"
    mkdir -p "$SUDOERS_DIR"
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$USER_NAME" > "$sf"
    chmod 440 "$sf"
    if command -v visudo >/dev/null 2>&1 && ! visudo -cf "$sf" >/dev/null 2>&1; then
        rm -f "$sf"
        err "Файл sudoers не прошёл проверку, удалён"
        return 1
    fi
    ok "Пользователь $USER_NAME добавлен в sudo (без пароля)"

    home="$(home_of "$USER_NAME")"
    keys=("${NEW_KEYS[@]+"${NEW_KEYS[@]}"}")
    if [[ ${#keys[@]} -eq 0 ]]; then
        # Ключей не передали: берём ключи root
        local rf; rf="$(home_of root)/.ssh/authorized_keys"
        if [[ -f "$rf" ]]; then
            while IFS= read -r k; do
                [[ -z "${k// }" || "$k" == \#* ]] && continue
                keys+=("$k")
            done < <(grep -vE '^[[:space:]]*(#|$)' "$rf" | grep -E "$KEY_RE" || true)
        fi
    fi
    if [[ ${#keys[@]} -gt 0 ]]; then
        added="$(install_keys_for "$USER_NAME" "$home" "${keys[@]}")"
        ok "Ключей для $USER_NAME добавлено: $added (всего: $(count_keys "$home/.ssh/authorized_keys"))"
    else
        warn "Для $USER_NAME нет ни одного ключа: войти получится только после добавления ключа"
    fi
}

TARGET_USER=""
TARGET_KEYS=0
step_keys() {
    # Убеждаемся, что у учётной записи, под которой вы входите, есть ключ
    TARGET_USER="${USER_NAME:-root}"
    local home file
    home="$(home_of "$TARGET_USER")"
    if [[ -z "$home" ]]; then
        warn "Пользователь $TARGET_USER не найден, ключи проверить нельзя"
        TARGET_KEYS=0
        return 0
    fi
    file="$home/.ssh/authorized_keys"

    if [[ -z "$USER_NAME" && ${#NEW_KEYS[@]} -gt 0 ]]; then
        local added
        added="$(install_keys_for root "$home" "${NEW_KEYS[@]}")"
        ok "Ключей для root добавлено: $added"
    fi

    TARGET_KEYS="$(count_keys "$file")"
    if [[ "$TARGET_KEYS" -eq 0 && $YES -eq 0 && $DRY -eq 0 ]]; then
        local pasted=""
        echo "У $TARGET_USER на сервере нет SSH-ключей."
        if read -r -p "Вставьте публичный ключ (ssh-ed25519 AAAA...) или Enter, чтобы пропустить: " pasted 2>/dev/null </dev/tty && [[ -n "$pasted" ]]; then
            if key_is_valid "$pasted"; then
                install_keys_for "$TARGET_USER" "$home" "$pasted" >/dev/null
                TARGET_KEYS="$(count_keys "$file")"
                ok "Ключ добавлен"
            else
                warn "Это не похоже на корректный публичный ключ"
            fi
        fi
    fi

    if [[ "$TARGET_KEYS" -gt 0 ]]; then
        ok "SSH-ключей у $TARGET_USER: $TARGET_KEYS"
    else
        warn "У $TARGET_USER нет SSH-ключей — вход по паролю отключён не будет"
    fi
}

step_swap() {
    local ram_mb size="" size_mb avail_mb
    if swapon --show 2>/dev/null | grep -q .; then
        info "Swap уже настроен, пропускаю"
        return 0
    fi
    if [[ -e "$SWAPFILE" ]]; then
        info "Файл $SWAPFILE уже существует, пропускаю"
        return 0
    fi
    ram_mb="$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)"
    case "$SWAP_ARG" in
        0)    info "Swap отключён опцией --swap 0"; return 0 ;;
        auto)
            if   (( ram_mb <= 1100 )); then size="2G"
            elif (( ram_mb <= 2200 )); then size="1G"
            else info "Памяти достаточно (${ram_mb} МБ), swap не нужен"; return 0
            fi ;;
        *)    size="$SWAP_ARG" ;;
    esac
    size_mb="${size%[MG]}"
    if [[ "$size" == *G ]]; then size_mb=$((size_mb * 1024)); fi
    avail_mb="$(df -Pm "$(dirname "$SWAPFILE")" | awk 'NR==2{print $4}')"
    if (( avail_mb < size_mb + 1024 )); then
        warn "Мало места на диске для swap ${size} (свободно ${avail_mb} МБ), пропускаю"
        return 0
    fi

    info "Создаю swap $size..."
    fallocate -l "$size" "$SWAPFILE" 2>/dev/null || dd if=/dev/zero of="$SWAPFILE" bs=1M count="$size_mb" status=none
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE" >/dev/null
    if ! swapon "$SWAPFILE" 2>/dev/null; then
        rm -f "$SWAPFILE"
        warn "Не удалось включить swap (контейнерный VPS?), пропускаю"
        return 0
    fi
    if ! grep -qs "^$SWAPFILE " "$FSTAB"; then
        printf '%s none swap sw 0 0\n' "$SWAPFILE" >> "$FSTAB"
    fi
    mkdir -p "$SYSCTL_DIR"
    printf '# Создано vps-tools/init-vps.sh\nvm.swappiness = 10\n' > "$SYSCTL_DIR/99-vps-tools-swap.conf"
    sysctl -w vm.swappiness=10 >/dev/null 2>&1 || true
    ok "Swap $size включён (swappiness=10), сохранится после перезагрузки"
}

step_bbr() {
    local args=()
    if [[ $TUNE -eq 1 ]]; then args+=(--tune); fi
    run_sub enable-bbr.sh "${args[@]+"${args[@]}"}"
}

step_fail2ban() {
    run_sub install-fail2ban.sh
}

step_ufw() {
    local args=() a
    if [[ $YES -eq 1 ]]; then args+=(--yes); fi
    for a in "${ALLOW[@]+"${ALLOW[@]}"}"; do args+=(--allow "$a"); done
    run_sub setup-ufw.sh "${args[@]+"${args[@]}"}"
}

restart_ssh() {
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null
}

disable_root_login() {
    local f="$SSHD_DROPIN_DIR/00-vps-tools-root-login.conf"
    mkdir -p "$SSHD_DROPIN_DIR"
    printf '# Создано vps-tools/init-vps.sh\nPermitRootLogin no\n' > "$f"
    if command -v sshd >/dev/null 2>&1 && ! sshd -t 2>/dev/null; then
        rm -f "$f"
        err "Конфиг SSH не прошёл проверку, запрет входа root отменён"
        return 1
    fi
    restart_ssh || { err "Не удалось перезапустить SSH"; return 1; }
    ok "Вход под root по SSH запрещён (файл $f)"
}

step_password() {
    if [[ "$TARGET_KEYS" -eq 0 ]]; then
        warn "Пароль НЕ отключён: у $TARGET_USER нет SSH-ключа. Добавьте ключ и запустите: init-vps.sh --only password"
        RESULT[password]="skip"
        return 0
    fi

    if [[ $YES -eq 0 ]]; then
        echo ""
        echo -e "${YELLOW}Сейчас будет отключён вход по паролю. После этого войти можно только по SSH-ключу.${NC}"
        echo "Откройте НОВОЕ окно терминала и проверьте, что вход по ключу работает:"
        echo "    ssh $TARGET_USER@$(hostname -I 2>/dev/null | awk '{print $1}')"
        local ans=""
        if ! read -r -p "Вход по ключу работает? Введите yes, чтобы продолжить: " ans 2>/dev/null </dev/tty; then
            err "Нет терминала для подтверждения. Для отключения пароля запустите с --yes."
            RESULT[password]="skip"
            return 0
        fi
        if [[ "$ans" != "yes" ]]; then
            info "Пароль оставлен включённым. Позже: init-vps.sh --only password"
            RESULT[password]="skip"
            return 0
        fi
    fi

    if [[ $DISABLE_ROOT -eq 1 ]]; then disable_root_login || return 1; fi
    run_sub disable-ssh-password.sh
}

# ----- План -----
describe_swap() {
    local ram_mb
    ram_mb="$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)"
    case "$SWAP_ARG" in
        0) echo "не создавать" ;;
        auto)
            if   (( ram_mb <= 1100 )); then echo "авто: 2G (память ${ram_mb} МБ)"
            elif (( ram_mb <= 2200 )); then echo "авто: 1G (память ${ram_mb} МБ)"
            else echo "авто: не нужен (память ${ram_mb} МБ)"; fi ;;
        *) echo "$SWAP_ARG" ;;
    esac
}

print_plan() {
    echo ""
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}  ПЛАН${NC}"
    echo -e "${BLUE}============================================${NC}"
    local s
    for s in "${ALL_STEPS[@]}"; do
        if ! step_enabled "$s"; then continue; fi
        case "$s" in
            update)   echo "  • update    обновление системы и автообновления безопасности" ;;
            user)     echo "  • user      пользователь $USER_NAME с sudo$([[ $DISABLE_ROOT -eq 1 ]] && echo ', вход под root будет запрещён')" ;;
            swap)     echo "  • swap      $(describe_swap)" ;;
            bbr)      echo "  • bbr       включение BBR$([[ $TUNE -eq 1 ]] && echo ' + настройка TCP')" ;;
            fail2ban) echo "  • fail2ban  защита SSH (бан на неограниченное время после 5 неудач)" ;;
            ufw)      echo "  • ufw       файрвол: порты определяются автоматически, список покажу перед включением" ;;
            password) echo "  • password  отключение входа по паролю (последним, только при наличии SSH-ключа)" ;;
        esac
    done
    echo -e "${BLUE}============================================${NC}"
    echo ""
}

confirm_plan() {
    if [[ $YES -eq 1 ]]; then return 0; fi
    local ans=""
    if ! read -r -p "Начать? [y/N] " ans 2>/dev/null </dev/tty; then
        fail "Нет терминала для подтверждения. Запустите с --yes."
    fi
    [[ "$ans" == "y" || "$ans" == "Y" || "$ans" == "yes" ]]
}

run_step() {
    local s="$1" fn="step_$1"
    echo ""
    echo -e "${BLUE}── $s ──${NC}"
    if "$fn"; then
        if [[ -z "${RESULT[$s]:-}" ]]; then RESULT[$s]="ok"; fi
    else
        RESULT[$s]="fail"
        err "Шаг $s завершился с ошибкой"
        return 1
    fi
}

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  Init VPS${NC}"
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

print_plan

if [[ $DRY -eq 1 ]]; then
    info "[dry-run] ничего не изменяется. Проверяю то, что умеет пробный режим:"
    for s in bbr ufw; do
        if step_enabled "$s"; then
            echo ""
            echo -e "${BLUE}── $s (dry-run) ──${NC}"
            case "$s" in
                bbr) run_sub enable-bbr.sh --dry-run || true ;;
                ufw)
                    args=(--dry-run)
                    for a in "${ALLOW[@]+"${ALLOW[@]}"}"; do args+=(--allow "$a"); done
                    run_sub setup-ufw.sh "${args[@]}" || true ;;
            esac
        fi
    done
    exit 0
fi

if ! confirm_plan; then info "Отменено, ничего не изменено."; exit 0; fi

collect_keys

FAILED=0
for s in update user swap; do
    if step_enabled "$s"; then run_step "$s" || FAILED=1; else RESULT[$s]="skip"; fi
done

# Ключи нужны для решения об отключении пароля (или когда их передали явно)
if step_enabled password || [[ ${#NEW_KEYS[@]} -gt 0 ]]; then
    echo ""
    echo -e "${BLUE}── ключи SSH ──${NC}"
    step_keys || FAILED=1
fi

for s in bbr fail2ban ufw; do
    if step_enabled "$s"; then run_step "$s" || FAILED=1; else RESULT[$s]="skip"; fi
done

if step_enabled password; then
    if [[ $FAILED -eq 1 && "${RESULT[user]:-}" == "fail" ]]; then
        warn "Шаг user завершился ошибкой: вход по паролю не отключаю"
        RESULT[password]="skip"
    else
        run_step password || FAILED=1
    fi
else
    RESULT[password]="skip"
fi

# ----- Итог -----
echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  ИТОГ${NC}"
echo -e "${BLUE}============================================${NC}"
for s in "${ALL_STEPS[@]}"; do
    case "${RESULT[$s]:-skip}" in
        ok)   echo -e "  ${GREEN}[✓]${NC} $s" ;;
        fail) echo -e "  ${RED}[✗]${NC} $s" ;;
        *)    echo -e "  ${YELLOW}[–]${NC} $s (пропущен)" ;;
    esac
done
echo -e "${BLUE}============================================${NC}"

if [[ -f /var/run/reboot-required ]]; then
    warn "Для применения обновлений нужна перезагрузка: reboot"
fi
if [[ "${RESULT[password]:-skip}" == "ok" ]]; then
    warn "Не закрывайте эту сессию, пока не проверите вход по ключу в новом окне."
fi
echo ""
info "Дальше: установите 3x-ui, затем настройте бэкап (backup-3xui.sh --install-cron) и мониторинг (monitor.sh --install-cron)."

if [[ $FAILED -eq 1 ]]; then exit 1; fi
