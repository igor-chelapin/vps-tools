#!/bin/bash
# ============================================================
# Universal SSH Password Disable Script
# Отключает вход по паролю, исправляет все override-файлы,
# проверяет результат. Работает на Ubuntu/Debian/CentOS.
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  SSH Password Disable Script${NC}"
echo -e "${BLUE}============================================${NC}"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[✗] Запусти скрипт от root${NC}"
    exit 1
fi
echo -e "${GREEN}[✓] Запуск от root${NC}"

BACKUP="/etc/ssh/sshd_config.bak.$(date +%Y%m%d-%H%M%S)"
cp /etc/ssh/sshd_config "$BACKUP"
echo -e "${GREEN}[✓] Бэкап создан: $BACKUP${NC}"

echo -e "${YELLOW}[*] Правка /etc/ssh/sshd_config...${NC}"
sed -i -E 's/^[[:space:]]*#?[[:space:]]*PasswordAuthentication[[:space:]]+.*/PasswordAuthentication no/I' /etc/ssh/sshd_config
sed -i -E 's/^[[:space:]]*#?[[:space:]]*KbdInteractiveAuthentication[[:space:]]+.*/KbdInteractiveAuthentication no/I' /etc/ssh/sshd_config
sed -i -E 's/^[[:space:]]*#?[[:space:]]*ChallengeResponseAuthentication[[:space:]]+.*/ChallengeResponseAuthentication no/I' /etc/ssh/sshd_config
echo -e "${GREEN}[✓] Основной конфиг обновлён${NC}"

echo -e "${YELLOW}[*] Поиск override в /etc/ssh/sshd_config.d/...${NC}"
if [[ -d /etc/ssh/sshd_config.d ]]; then
    for f in /etc/ssh/sshd_config.d/*.conf; do
        [[ -f "$f" ]] || continue
        if grep -qiE '^[[:space:]]*PasswordAuthentication[[:space:]]+yes' "$f"; then
            cp "$f" "${f}.bak.$(date +%Y%m%d-%H%M%S)"
            sed -i -E 's/^[[:space:]]*PasswordAuthentication[[:space:]]+yes/PasswordAuthentication no/I' "$f"
            echo -e "${GREEN}[✓] Исправлен: $f${NC}"
        fi
        if grep -qiE '^[[:space:]]*KbdInteractiveAuthentication[[:space:]]+yes' "$f"; then
            sed -i -E 's/^[[:space:]]*KbdInteractiveAuthentication[[:space:]]+yes/KbdInteractiveAuthentication no/I' "$f"
            echo -e "${GREEN}[✓] Исправлен: $f${NC}"
        fi
    done
else
    echo -e "${YELLOW}[!] /etc/ssh/sshd_config.d/ не найден${NC}"
fi

echo -e "${YELLOW}[*] Проверка синтаксиса SSH...${NC}"
if ! sshd -t; then
    echo -e "${RED}[✗] Ошибка в конфиге SSH! Восстанавливаю бэкап...${NC}"
    cp "$BACKUP" /etc/ssh/sshd_config
    echo -e "${YELLOW}[!] Бэкап восстановлен.${NC}"
    exit 1
fi
echo -e "${GREEN}[✓] Конфиг валиден${NC}"

echo -e "${YELLOW}[*] Перезапуск SSH...${NC}"
if systemctl restart ssh 2>/dev/null; then
    echo -e "${GREEN}[✓] SSH перезапущен (ssh.service)${NC}"
elif systemctl restart sshd 2>/dev/null; then
    echo -e "${GREEN}[✓] SSH перезапущен (sshd.service)${NC}"
elif rc-service sshd restart 2>/dev/null; then
    echo -e "${GREEN}[✓] SSH перезапущен (rc-service)${NC}"
else
    echo -e "${RED}[✗] Не удалось перезапустить SSH${NC}"
    exit 1
fi

echo -e "${YELLOW}[*] Проверка эффективного конфига...${NC}"
EFFECTIVE=$(sshd -T 2>/dev/null | grep -i "^passwordauthentication" | awk '{print $2}')
KBD=$(sshd -T 2>/dev/null | grep -i "^kbdinteractiveauthentication" | awk '{print $2}')

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  РЕЗУЛЬТАТ${NC}"
echo -e "${BLUE}============================================${NC}"
echo -e "PasswordAuthentication:         ${EFFECTIVE}"
echo -e "KbdInteractiveAuthentication:   ${KBD}"
echo -e "${BLUE}============================================${NC}"

if [[ "$EFFECTIVE" == "no" && "$KBD" == "no" ]]; then
    echo -e "${GREEN}[✓] ПАРОЛЬ ОТКЛЮЧЁН. Сервер защищён.${NC}"
    echo -e "${YELLOW}[!] НЕ ЗАКРЫВАЙ текущую сессию!${NC}"
    echo -e "${YELLOW}[!] Открой НОВОЕ окно и проверь вход по ключу.${NC}"
    echo ""
    echo -e "${BLUE}Проверка:${NC}"
    echo -e "  ssh -o PreferredAuthentications=password root@$(hostname -I | awk '{print $1}')"
    echo -e "  Ожидаемо: Permission denied (publickey)."
    exit 0
else
    echo -e "${RED}[✗] ПАРОЛЬ ВСЁ ЕЩЁ ВКЛЮЧЁН!${NC}"
    echo -e "${YELLOW}Ищи override вручную:${NC}"
    echo -e "  grep -r -i 'passwordauthentication' /etc/ssh/ 2>/dev/null"
    exit 1
fi
