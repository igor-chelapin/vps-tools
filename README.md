# vps-tools

Набор утилит для автоматической настройки Ubuntu VPS. Это ветка `vps-tools`; на ветке `main` лежит [vpn-key-checker](https://github.com/igor-chelapin/vps-tools) — проверка VPN-ключей через Xray.

| Скрипт | Что делает |
| --- | --- |
| [`install-fail2ban.sh`](#install-fail2bansh) | устанавливает Fail2ban, который блокирует SSH-ботов навсегда |
| [`disable-ssh-password.sh`](#disable-ssh-passwordsh) | отключает вход по паролю в SSH, остаётся только вход по ключу |
| [`enable-bbr.sh`](#enable-bbrsh) | включает TCP BBR и fq, ускоряет сеть VPN-сервера |
| [`setup-ufw.sh`](#setup-ufwsh) | настраивает файрвол ufw, сам находит порты SSH, панели и inbound'ов 3x-ui |
| [`backup-3xui.sh`](#backup-3xuish) | бэкап базы и настроек 3x-ui: ротация, Telegram, cron, восстановление |

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

## setup-ufw.sh

Настраивает файрвол **ufw** для VPN-сервера с [3x-ui](https://github.com/MHSanaei/3x-ui): входящие соединения закрыты, открыто только нужное. Нужные порты скрипт находит сам, а перед включением показывает список и спрашивает подтверждение.

Встроенный файрвол в меню `x-ui` жёстко открывает порты 2053 и 2096. Этот скрипт читает реальные настройки: порт панели, порт подписок и порты ваших inbound'ов.

### Что открывает

- **SSH**: порт из `sshd -T`, а также порт текущего SSH-подключения, чтобы не отрезать вас от сервера
- **80 и 443** (отключается флагом `--no-web`)
- **порт панели** и **порт подписок** 3x-ui, если они слушают не только локально
- **порты всех включённых inbound'ов** из базы 3x-ui, с нужным протоколом: для hysteria, wireguard, tuic, mKCP, shadowsocks и HTTP/3 открывается UDP, для остальных TCP
- любые дополнительные порты через `--allow`

Пропускаются отключённые inbound'ы и те, что слушают только `127.0.0.1` (например, за nginx).

### Требования

- права root
- Ubuntu; 3x-ui с базой SQLite (стандартная установка). `sqlite3` скрипт установит сам. Для PostgreSQL порты inbound'ов не читаются, укажите их через `--allow`

### Быстрая установка

Запускать от root:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/igor-chelapin/vps-tools/vps-tools/setup-ufw.sh)
```

Сначала посмотрите план без изменений:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/igor-chelapin/vps-tools/vps-tools/setup-ufw.sh) --dry-run
```

### Опции

| Опция | Описание |
| --- | --- |
| `--allow PORT[/tcp\|/udp]` | открыть дополнительный порт (можно несколько раз); без протокола открываются tcp и udp |
| `--no-web` | не открывать 80 и 443 |
| `--yes` | не спрашивать подтверждение |
| `--dry-run` | только показать план и команды |

Если 3x-ui установлен нестандартно, укажите пути переменными окружения: `XUI_DB`, `XUI_BIN`, `XUI_ENV_FILE`.

### Важно

- Не закрывайте текущую SSH-сессию. Откройте новое окно и убедитесь, что вход работает.
- Если ufw уже включён, скрипт только добавляет недостающие правила и ничего не удаляет.
- Docker публикует порты в обход ufw. Если 3x-ui или другие сервисы запущены в Docker с `-p`, ufw их не фильтрует.
- Если доступ потерян, отключите файрвол через консоль хостера: `ufw disable`.

### Проверка

```bash
sudo ufw status verbose
```

---

## backup-3xui.sh

Делает бэкап базы и настроек [3x-ui](https://github.com/MHSanaei/3x-ui): хранит последние копии, по желанию отправляет архив в Telegram, ставится в cron и умеет восстанавливать панель из архива.

В 3x-ui есть и своя отправка бэкапа через Telegram-бота панели. Этот скрипт дополняет её: делает копии на самом сервере с ротацией, сохраняет конфиг Xray и файлы, которые вы добавите (например, сертификаты), и умеет восстанавливать одной командой.

### Что попадает в архив

- база `/etc/x-ui/x-ui.db`: консистентная копия через `sqlite3 .backup`, поэтому работающая панель не мешает, а свежие записи не теряются
- остальные файлы из `/etc/x-ui` (кроме логов)
- `/etc/default/x-ui` и `/usr/local/x-ui/bin/config.json`
- всё, что указано через `--include`

Архивы лежат в `/var/backups/3x-ui` (права 700/600), хранятся последние 14 штук.

### Требования

- права root, Ubuntu, 3x-ui с базой SQLite. `sqlite3` скрипт установит сам
- при PostgreSQL сама база не копируется (скрипт предупредит): делайте `pg_dump` отдельно

### Быстрая установка

Запускать от root:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/igor-chelapin/vps-tools/vps-tools/backup-3xui.sh)
```

Бэкап с сертификатами, хранить 30 копий:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/igor-chelapin/vps-tools/vps-tools/backup-3xui.sh) --include /root/cert --keep 30
```

### Telegram (по желанию)

Без настройки архив просто остаётся на сервере, а результат пишется в лог `/var/log/vps-tools.log`. Чтобы получать копии в Telegram:

```bash
sudo ./backup-3xui.sh --setup-telegram
```

Скрипт попросит токен бота от @BotFather, сам определит ваш chat id (нужно один раз написать боту `/start`) и отправит тестовое сообщение. Токен сохраняется в `/etc/vps-tools/telegram.conf` с правами 600 и в репозиторий не попадает. Telegram принимает файлы до 50 МБ: большие архивы остаются только на сервере.

Отключить отправку: удалите `/etc/vps-tools/telegram.conf` или запускайте с `--no-telegram`.

### Расписание

```bash
sudo ./backup-3xui.sh --install-cron              # каждый день в 03:15
sudo ./backup-3xui.sh --install-cron --time 05:30 # другое время
sudo ./backup-3xui.sh --remove-cron               # убрать
```

Скрипт копируется в `/usr/local/sbin/vps-tools-backup-3xui`, расписание записывается в `/etc/cron.d/vps-tools-backup`. Опции `--keep`, `--dir` и `--include`, указанные вместе с `--install-cron`, попадут в расписание.

### Восстановление

```bash
sudo ./backup-3xui.sh --list
sudo ./backup-3xui.sh --restore /var/backups/3x-ui/3xui-ИМЯ-ДАТА.tar.gz
```

Перед восстановлением скрипт показывает, какие файлы будут перезаписаны, делает копию текущего состояния (`prerestore-3xui-…`), останавливает `x-ui`, разворачивает архив и запускает панель. Архивы с абсолютными путями или `..` отклоняются.

### Все опции

| Опция | Описание |
| --- | --- |
| `--dir DIR` | каталог для архивов |
| `--keep N` | сколько последних архивов хранить (по умолчанию 14) |
| `--include PATH` | добавить файл или каталог в архив (можно несколько раз) |
| `--no-telegram` | не отправлять этот архив |
| `--setup-telegram` | сохранить токен и chat id |
| `--install-cron`, `--time HH:MM`, `--remove-cron` | расписание |
| `--list`, `--restore FILE` | список и восстановление |
| `--dry-run`, `--quiet`, `--yes` | пробный запуск, тихий режим, без подтверждений |

---

## Лицензия

Проект распространяется по лицензии MIT.
