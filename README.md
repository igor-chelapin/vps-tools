# vpn-key-checker

Консольная утилита, которая проверяет VPN-ключи через ядро [Xray](https://github.com/XTLS/Xray-core): запускает Xray под каждый ключ, ходит через него в интернет, замеряет пинг и скорость и оставляет только рабочие.

**Поддерживаются:** `vless://`, `trojan://`, `hysteria2://` (`hy2://`), а также ссылки-подписки (обычный текст или base64).
Транспорты для vless/trojan: tcp, ws, grpc, httpupgrade, xhttp. Безопасность: none, tls, reality. Hysteria2: в том числе с obfs salamander. Hysteria v1 не поддерживается (в Xray её нет).

## Быстрый старт

**Linux / macOS**

```bash
git clone https://github.com/igor-chelapin/vps-tools.git
cd vps-tools
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# скачайте Xray под свою систему: https://github.com/XTLS/Xray-core/releases
# и положите файл xray в эту папку, затем:
chmod +x xray
python -m vpncheck --sub https://ваша-подписка --max 5
```

**Windows (PowerShell)**

```powershell
git clone https://github.com/igor-chelapin/vps-tools.git
cd vps-tools
python -m venv .venv; .venv\Scripts\activate
pip install -r requirements.txt

# скачайте Xray-windows-64.zip: https://github.com/XTLS/Xray-core/releases
# распакуйте xray.exe в эту папку, затем:
python -m vpncheck --sub https://ваша-подписка --max 5
```

Готово: рабочие ключи будут в `working.txt`, подробный отчёт в `report.csv`. Уберите `--max 5`, чтобы проверить всё.

## Установка

Нужны Python 3.9+ и бинарник Xray ([релизы](https://github.com/XTLS/Xray-core/releases)). Используйте свежую версию: Hysteria2 появился в Xray сравнительно недавно. Сборка конфигов проверена командой `xray run -test` на Xray 26.3.27 и 26.9.9.

```bash
git clone https://github.com/igor-chelapin/vps-tools.git
cd vps-tools
python -m venv .venv && source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

Положите `xray` (`xray.exe`) в папку проекта или в `PATH`, либо укажите путь через `--xray`.

## Использование

```bash
# подписка
python -m vpncheck --sub https://example.com/sub/token

# файл со ссылками (по одной в строке) или с подпиской
python -m vpncheck --file keys.txt

# несколько источников сразу, быстрее и без замера скорости
python -m vpncheck --sub URL1 --sub URL2 --file keys.txt -c 50 --no-speed
```

Результат:

- `working.txt`: рабочие ключи (исходные ссылки), отсортированные по пингу или скорости;
- `report.csv`: все ключи с пингом, скоростью и причиной отказа.

## Параметры

| Параметр | Описание |
| --- | --- |
| `--sub URL` | ссылка на подписку (можно несколько раз) |
| `--file PATH` | файл со ссылками, `-` читает stdin |
| `--xray PATH` | путь к бинарнику Xray |
| `-c, --concurrency N` | одновременных проверок (по умолчанию 20) |
| `--timeout SEC` | таймаут запросов (по умолчанию 8) |
| `--no-speed` | не измерять скорость |
| `--speed-time SEC` | длительность замера скорости (по умолчанию 5) |
| `--speed-workers N` | одновременных замеров скорости (по умолчанию 2) |
| `--sort ping\|speed` | порядок в `working.txt` |
| `--max N` | проверить только первые N ключей |
| `--out-dir DIR` | куда писать результаты |
| `--test-url`, `--speed-url` | свои адреса для проверки связи и скорости |

## Ключи с самоподписанным сертификатом (insecure=1)

В Xray 26.3+ опцию `allowInsecure` удалили, вместо неё нужен отпечаток сертификата (`pinnedPeerCertSha256`). Поэтому:

- **vless/trojan поверх TLS с `insecure=1`**: утилита сама снимает отпечаток сертификата сервера и подставляет его в конфиг.
- **hysteria2 с `insecure=1`**: по QUIC отпечаток сами не снимаем, такой ключ получит пометку в `report.csv`. Если в ссылке есть параметр `pinSHA256=...`, ключ проверится нормально.

## Как это работает

1. Парсер разбирает ссылки и подписки, убирает дубли.
2. Для каждого ключа генерируется конфиг Xray: локальный SOCKS на `127.0.0.1` со свободным портом и один исходящий прокси.
3. Xray запускается как подпроцесс, через его SOCKS идёт запрос на `--test-url`. Первый запрос прогревает туннель, пинг считается как медиана следующих трёх.
4. Если включён замер скорости, через тот же туннель скачивается файл, и считается Мбит/с.
5. Процесс Xray останавливается, результаты сортируются и записываются.

Замер скорости делается с ограниченным параллелизмом (`--speed-workers`), чтобы проверки не мешали друг другу.

## Разработка

```bash
pip install -r requirements-dev.txt
pytest
```

## Безопасность

Не публикуйте свои `keys.txt`, `working.txt` и `report.csv`: ключи дают доступ к серверам. Эти файлы уже добавлены в `.gitignore`. Утилита ходит только на `--test-url` и `--speed-url` и не отправляет ключи никуда, кроме вашего локального Xray.

## Другие утилиты

Скрипты для настройки Ubuntu VPS (fail2ban, отключение входа по паролю в SSH) лежат в ветке [`vps-tools`](https://github.com/igor-chelapin/vps-tools/tree/vps-tools).

## Лицензия

MIT
