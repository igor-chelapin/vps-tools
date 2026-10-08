# vps-tools

Набор утилит для автоматической настройки Ubuntu VPS. Включает скрипт для установки и настройки Fail2ban, который блокирует SSH-ботов навсегда.

## Что делает

- устанавливает fail2ban через apt
- создаёт конфигурацию для защиты SSH
- включает автозапуск fail2ban
- проверяет корректность конфигурации
- показывает текущий статус jail `sshd`

## Быстрая установка

```bash
bash <(curl -sSL https://raw.githubusercontent.com/igor-chelapin/vps-tools/main/install-fail2ban.sh)
```

## Установка вручную

```bash
git clone https://github.com/igor-chelapin/vps-tools.git
cd vps-tools
chmod +x install-fail2ban.sh
sudo ./install-fail2ban.sh
```

## Проверка статуса

```bash
sudo fail2ban-client status sshd
```

## Разбанить IP

```bash
sudo fail2ban-client set sshd unbanip IP
```

> Внимание: собственные IP тоже могут попасть в бан. Если это произошло, разбанить адрес можно через консоль хостера.

## Лицензия

Проект распространяется по лицензии MIT.

