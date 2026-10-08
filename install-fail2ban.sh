#!/usr/bin/env bash

# Fail2ban installer for Ubuntu
# Logs each major step with [+], [!], and [-] prefixes.

log_ok() {
  printf '[+] %s\n' "$1"
}

log_warn() {
  printf '[!] %s\n' "$1"
}

log_err() {
  printf '[-] %s\n' "$1" >&2
}

if [[ $(id -u) -ne 0 ]]; then
  log_err "Скрипт должен запускаться от root. Используйте: sudo $0"
  exit 1
fi

OS_INFO=""
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  OS_INFO="${PRETTY_NAME:-unknown}"
fi

if [[ "${ID:-}" != "ubuntu" ]]; then
  log_warn "Обнаружена ОС: ${OS_INFO}. Скрипт рассчитан на Ubuntu, но продолжает работу."
else
  log_ok "Обнаружена ОС: ${OS_INFO}"
fi

log_ok "Установка fail2ban..."
apt install -y fail2ban

log_ok "Создание конфигурации /etc/fail2ban/jail.local..."
cat > /etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
bantime = -1
findtime = 10m
maxretry = 5
EOF

log_ok "Включение автозапуска fail2ban..."
systemctl enable fail2ban

log_ok "Перезапуск fail2ban..."
systemctl restart fail2ban

log_ok "Проверка конфигурации fail2ban..."
if ! fail2ban-client -t; then
  log_err "Проверка конфигурации завершилась с ошибкой."
  exit 1
fi

bantime_value="$(fail2ban-client get sshd bantime 2>/dev/null || echo 'unknown')"
if [[ "$bantime_value" != "-1" ]]; then
  log_err "Проверка bantime не прошла: ожидалось '-1', получено '$bantime_value'."
  exit 1
fi

log_ok "Проверка значения bantime для sshd: $bantime_value"

log_ok "Статус fail2ban для sshd:"
fail2ban-client status sshd || true

printf '\n\033[32m[+] Fail2ban успешно установлен и настроен на %s.\033[0m\n' "${OS_INFO}"
