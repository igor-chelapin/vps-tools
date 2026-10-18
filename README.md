# vps-tools

Набор утилит для автоматической настройки Ubuntu VPS. Это ветка `vps-tools`; на ветке `main` лежит [vpn-key-checker](https://github.com/igor-chelapin/vps-tools) — проверка VPN-ключей через Xray.

| Скрипт | Что делает |
| --- | --- |
| [`install-fail2ban.sh`](#install-fail2bansh) | устанавливает Fail2ban, который блокирует SSH-ботов навсегда |
| [`disable-ssh-password.sh`](#disable-ssh-passwordsh) | отключает вход по паролю в SSH, остаётся только вход по ключу |
| [`enable-bbr.sh`](#enable-bbrsh) | включает TCP BBR и fq, ускоряет сеть VPN-сервера |

---

## install-fail2ban.sh

Скрипт для установки и настройки Fail2ban, который блокирует SSH-ботов навсегда.

### Что делает

- устанавливает fail2ban через apt
- создаёт конфигурацию для защиты SSH
- включает автозапуск fail2ban
- проверяет корректность конфигурации
- показывает текущий статус jail `sshd`

### Быстрая установка

```bash
bash <(curl -sSL https://raw.githubusercontent.com/igor-chelapin/vps-tools/vps-tools/install-fail2ban.sh)
```

### Установка вручную

```bash
git clone -b vps-tools https://github.com/igor-chelapin/vps-tools.git
cd vps-tools
chmod +x install-fail2ban.sh
sudo ./install-fail2ban.sh
```

### Проверка статуса

```bash
sudo fail2ban-client status sshd
```

### Разбанить IP

```bash
sudo fail2ban-client set sshd unbanip IP
```

> Внимание: собственные IP тоже могут попасть в бан. Если это произошло, разбанить адрес можно через консоль хостера.

---

## disable-ssh-password.sh

Скрипт, который отключает вход по паролю в SSH и проверяет, что настройка действительно применилась. После него на сервер можно войти только по SSH-ключу, и перебирать пароли становится бессмысленно.

> **Важно: сначала убедитесь, что вход по ключу работает.** Скрипт не проверяет, добавлен ли ваш ключ на сервер. Если ключа нет, после запуска вы потеряете SSH-доступ и сможете войти только через консоль хостера.
>
> Проверьте в **отдельном** окне терминала, что `ssh root@IP` пускает вас без пароля, и только потом запускайте скрипт. Текущую сессию после запуска не закрывайте, пока не проверите вход в новом окне.

### Что делает

- проверяет, что скрипт запущен от root
- делает бэкап `/etc/ssh/sshd_config` с датой в имени (`sshd_config.bak.ГГГГММДД-ЧЧММСС`)
- в `sshd_config` ставит `PasswordAuthentication no`, `KbdInteractiveAuthentication no` и `ChallengeResponseAuthentication no` (в том числе раскомментирует закомментированные строки)
- ищет файлы в `/etc/ssh/sshd_config.d/*.conf`, где пароль включён (`yes`), и меняет на `no`; перед этим делает бэкап файла
- проверяет синтаксис командой `sshd -t`; если конфиг сломан, сам восстанавливает бэкап и ничего не перезапускает
- перезапускает SSH (`ssh`, `sshd` или `rc-service`, что найдётся)
- показывает итоговые значения из `sshd -T` и сообщает, отключён ли пароль на самом деле

### Требования

- права root
- Ubuntu, Debian или CentOS (перезапуск через `rc-service` предусмотрен и для систем с OpenRC)
- добавленный на сервер SSH-ключ

### Быстрая установка

Запускать от root:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/igor-chelapin/vps-tools/vps-tools/disable-ssh-password.sh)
```

Если вы вошли не под root:

```bash
curl -sSL https://raw.githubusercontent.com/igor-chelapin/vps-tools/vps-tools/disable-ssh-password.sh | sudo bash
```

### Установка вручную

```bash
git clone -b vps-tools https://github.com/igor-chelapin/vps-tools.git
cd vps-tools
chmod +x disable-ssh-password.sh
sudo ./disable-ssh-password.sh
```

### Проверка результата

В конце скрипт пишет `ПАРОЛЬ ОТКЛЮЧЁН`, если `PasswordAuthentication` и `KbdInteractiveAuthentication` равны `no`. Проверить самостоятельно:

```bash
sudo sshd -T | grep -iE 'passwordauthentication|kbdinteractiveauthentication'
```

Попытка войти по паролю должна заканчиваться отказом:

```bash
ssh -o PreferredAuthentications=password root@IP
# Ожидаемо: Permission denied (publickey).
```

Если скрипт сообщил `ПАРОЛЬ ВСЁ ЕЩЁ ВКЛЮЧЁН`, значит параметр задан где-то ещё или его нет в `sshd_config` совсем (скрипт только заменяет существующие строки, в том числе закомментированные, но не добавляет новые). Найти:

```bash
grep -r -i 'passwordauthentication' /etc/ssh/
```

### Откат

Вернуть пароль можно из бэкапа (подставьте дату из имени файла):

```bash
sudo cp /etc/ssh/sshd_config.bak.ГГГГММДД-ЧЧММСС /etc/ssh/sshd_config
sudo systemctl restart ssh    # или sshd
```

Если скрипт правил файлы в `/etc/ssh/sshd_config.d/`, рядом с ними лежат бэкапы вида `имя.conf.bak.ГГГГММДД-ЧЧММСС`. Верните нужный файл на место командой `cp` так же, как выше. Если доступа по SSH уже нет, сделайте это через консоль хостера.

---

## enable-bbr.sh

Включает алгоритм управления перегрузкой TCP **BBR** и очередь `fq`. На VPN-серверах это обычно даёт заметный прирост скорости и стабильности, особенно на каналах с потерями пакетов. Скрипт безопасен для повторного запуска.

В меню `x-ui` тоже есть пункт BBR. Этот скрипт нужен, когда панель ещё не установлена, когда нужен откат или дополнительная настройка TCP (`--tune`). Если BBR уже включён (в том числе через x-ui), скрипт ничего не меняет.

### Что делает

- проверяет ядро (нужно 4.9+) и предупреждает о контейнерных VPS (OpenVZ/LXC), где параметры ядра часто менять нельзя
- загружает модуль `tcp_bbr` и проверяет, что ядро предлагает BBR
- записывает настройки в `/etc/sysctl.d/99-vps-tools-bbr.conf` и в `/etc/modules-load.d/`, чтобы они пережили перезагрузку
- применяет их сразу и проверяет результат; если BBR не включился, откатывает изменения

### Быстрая установка

Запускать от root:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/igor-chelapin/vps-tools/vps-tools/enable-bbr.sh)
```

### Опции

Чтобы передать опции при запуске через `curl`, добавьте их после скрипта: `bash <(curl -sSL URL) --tune`.

| Опция | Описание |
| --- | --- |
| `--tune` | дополнительно применить умеренную настройку TCP: `tcp_fastopen`, `tcp_mtu_probing`, `tcp_slow_start_after_idle`, `somaxconn`, `tcp_max_syn_backlog` |
| `--status` | показать текущий алгоритм, очередь и доступные варианты |
| `--disable` | вернуть cubic и убрать настройки скрипта |
| `--dry-run` | только показать, что будет сделано |

### Проверка

```bash
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
# net.ipv4.tcp_congestion_control = bbr
# net.core.default_qdisc = fq
```

### Откат

```bash
sudo ./enable-bbr.sh --disable
```

Если BBR включали и через меню `x-ui`, у него есть свой файл `/etc/sysctl.d/99-bbr-x-ui.conf`: после `--disable` BBR вернётся при перезагрузке, пока вы не отключите его в меню `x-ui` (BBR → Disable BBR). Скрипт сам об этом предупредит.

---

## Лицензия

Проект распространяется по лицензии MIT.
