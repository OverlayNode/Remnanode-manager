# Remnawave Node Manager

Интерактивный скрипт для автоматической установки и управления Remnawave Node.

Менеджер предназначен для отдельного VPS-сервера с Ubuntu или Debian и поддерживает как обычную установку RemnaNode, так и полностью автономную ноду с локальными TLS-сертификатами, Nginx Selfsteal и автоматической генерацией профилей Xray.

## Возможности

- Установка Docker Engine + Docker Compose
- Установка и настройка UFW
- Сохранение доступа по OpenSSH (`22/tcp`)
- Ограничение доступа к API Remnawave Node (`2222/tcp`) только IP/CIDR сервера панели
- Установка и обновление `remnawave/node:latest`
- Выпуск локальных Let's Encrypt сертификатов через `acme.sh`
- Автоматическое продление сертификатов
- Автоматический перезапуск `nginx-selfsteal` после обновления сертификата
- Nginx Selfsteal через `/dev/shm/nginx.sock`
- Универсальная Cloud-страница-заглушка с автоматической подстановкой домена и названия сервиса
- Форма входа на странице-заглушке **не отправляет и не сохраняет логины или пароли**
- Генерация профилей Remnawave/Xray для:
  - VLESS RAW + REALITY
  - VLESS XHTTP + REALITY
  - Hysteria2 (UDP/TLS)
- Обновление контейнеров
- Управление SSL-сертификатами
- Диагностика ноды
- Изменение домена и названия Cloud-страницы
- Ротация Reality-ключей
- Изменение inbound'ов и повторная генерация Xray-профиля
- Удаление установленного стека Node

## Быстрый запуск

Скачать и запустить от имени `root`:

```bash
curl -fsSL https://raw.githubusercontent.com/OverlayNode/Remnanode-manager/main/install.sh \
  -o /root/remnanode-manager.sh

chmod +x /root/remnanode-manager.sh
/root/remnanode-manager.sh
```

Или запустить одной командой:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/OverlayNode/Remnanode-manager/main/install.sh)
```

## Меню

```text
1. Установить Remna Node
2. Установить Remna Node + SSL / Selfsteal

3. Обновить RemnaNode / контейнеры
4. SSL / сертификаты
5. Диагностика Node / Selfsteal
6. Показать Reality-ключи / параметры профиля
7. Настроить inbound'ы / пересобрать Xray-профиль
8. Изменить домен / название Cloud-страницы
9. Сгенерировать новую Reality keypair
10. Показать структуру файлов
11. Удалить Node

0. Выход
```

## Установка Selfsteal

При установке скрипт запросит:

- `SECRET_KEY`, который выдаёт Remnawave Panel при создании Node
- IP или CIDR сервера панели для доступа к TCP-порту `2222`
- домен ноды, например:

```text
de01.example.com
```

- название сервиса, которое будет отображаться на Cloud-странице
  - если оставить поле пустым, будет использоваться сам домен
- Email для Let's Encrypt / `acme.sh`
- inbound'ы, которые необходимо создать

### Выбор inbound'ов

Можно выбрать один или несколько вариантов:

```text
1. VLESS RAW + REALITY + Selfsteal
2. VLESS XHTTP + REALITY + Selfsteal
3. Hysteria2 (UDP + TLS)
4. Все
```

Если одновременно включены RAW и XHTTP, менеджер использует разные TCP-порты, так как это отдельные Xray inbound'ы.

Стандартная схема портов:

| Компонент | Порт по умолчанию |
|---|---:|
| SSH | TCP 22 |
| RemnaNode API | TCP 2222 |
| ACME HTTP-01 | TCP 80 |
| VLESS RAW / REALITY | TCP 443 |
| VLESS XHTTP / REALITY при одновременно включённом RAW | TCP 8443 |
| Hysteria2 | UDP 443 |

TCP `443` и UDP `443` не конфликтуют друг с другом, поэтому VLESS/REALITY и Hysteria2 могут одновременно использовать порт `443`.

## XHTTP

Менеджер автоматически генерирует случайный XHTTP path и позволяет выбрать режим работы:

- `stream-one` — используется по умолчанию
- `stream-up`
- `packet-up`
- `auto`

Для XHTTP inbound не используется `xtls-rprx-vision`.

Настройки клиента должны соответствовать параметрам, созданным менеджером:

- XHTTP path
- XHTTP mode
- SNI
- Reality Public Key
- Short ID
- порт

## Hysteria2

Менеджер генерирует Hysteria2 inbound для Xray в формате:

```json
"protocol": "hysteria",
"version": 2,
"network": "hysteria",
"security": "tls"
```

Локальный сертификат ноды монтируется внутрь контейнера RemnaNode:

```text
/opt/remnanode/ssl/fullchain.pem
/opt/remnanode/ssl/privkey.pem
```

Hysteria2 использует UDP.

Поэтому, кроме UFW на самой ноде, необходимо убедиться, что выбранный UDP-порт разрешён также во внешнем firewall/security group вашего VPS-провайдера.

## SSL-сертификаты

Сертификаты выпускаются непосредственно на самой ноде через `acme.sh`.

Пример:

```bash
~/.acme.sh/acme.sh --issue \
  --standalone \
  -d node.example.com \
  --server letsencrypt
```

Production-копии сертификатов сохраняются в:

```text
/opt/remnanode/ssl/fullchain.pem
/opt/remnanode/ssl/privkey.pem
```

Менеджер автоматически настраивает deploy-hook.

После успешного обновления сертификата выполняется перезапуск:

```bash
docker restart nginx-selfsteal
```

Для проверки домена через HTTP-01 TCP-порт `80` должен быть доступен из интернета.

Это необходимо не только при первом выпуске сертификата, но и при последующих автоматических продлениях.

## Структура файлов

После установки структура выглядит примерно так:

```text
/opt/remnanode/
├── docker-compose.yml
├── .env
├── installer.conf
├── nginx.conf
├── reality.env
├── ssl/
│   ├── fullchain.pem
│   └── privkey.pem
├── html/
│   ├── index.html
│   ├── style.css
│   ├── app.js
│   ├── favicon.svg
│   ├── robots.txt
│   └── 404.html
└── profiles/
    ├── xray-profile.json
    └── profile-info.txt
```

Файлы:

```text
.env
reality.env
ssl/
profiles/xray-profile.json
profiles/profile-info.txt
```

могут содержать секретные данные и **не должны публиковаться в GitHub**.

## Cloud-страница / Selfsteal-заглушка

Страница-заглушка сделана универсальной и не привязана к конкретному проекту или бренду.

Например, при установке указаны:

```text
Domain: de01.example.com
Service name: Example
```

На странице будет отображаться:

```text
Example Cloud
Gateway: de01.example.com
```

Если название сервиса оставить пустым, в качестве названия будет использоваться сам домен.

Например:

```text
de01.example.com Cloud
```

Страница содержит визуальную форму авторизации для создания реалистичного Cloud-интерфейса.

При этом форма является исключительно визуальной:

- данные формы не отправляются на сервер
- логины не сохраняются
- пароли не сохраняются
- данные не передаются через JavaScript
- backend авторизации отсутствует

После попытки входа пользователю отображается сообщение о недоступности интерактивной авторизации.

## Remnawave Panel

После завершения установки менеджер создаёт готовый Xray-профиль:

```bash
cat /opt/remnanode/profiles/xray-profile.json
```

Его необходимо добавить в:

```text
Remnawave Panel
→ Config Profiles
```

и назначить нужной Node.

Параметры подключения сохраняются отдельно:

```bash
cat /opt/remnanode/profiles/profile-info.txt
```

В этом файле можно найти:

- домен
- Reality Public Key
- Short ID
- XHTTP path
- XHTTP mode
- используемые порты
- SNI
- параметры Hysteria2

Важно следить за тем, чтобы на одной Node одновременно не были назначены разные профили с inbound'ами, использующими один и тот же TCP или UDP порт.

Например, два отдельных TCP inbound не смогут одновременно слушать:

```text
0.0.0.0:443
```

## Firewall

Менеджер использует UFW.

Во время установки можно разрешить менеджеру сбросить существующие правила UFW и создать только необходимые для Node.

Основные правила:

```text
22/tcp
```

OpenSSH.

```text
2222/tcp
```

Remnawave Node API.

Рекомендуется разрешать `2222/tcp` **только с IP или CIDR сервера Remnawave Panel**.

Например:

```text
Panel IP
    ↓
TCP 2222
    ↓
RemnaNode
```

Для Selfsteal дополнительно используется:

```text
80/tcp
```

для Let's Encrypt HTTP-01.

VLESS RAW / REALITY обычно использует:

```text
443/tcp
```

XHTTP может использовать:

```text
8443/tcp
```

Hysteria2 обычно использует:

```text
443/udp
```

Если VPS-провайдер использует собственный Firewall / Security Group, необходимые порты необходимо открыть также там.

## Диагностика

В меню доступен отдельный режим диагностики:

```text
5. Диагностика Node / Selfsteal
```

Он проверяет:

- установлен ли Docker
- состояние Docker Compose
- состояние контейнеров
- правила UFW
- открытые TCP/UDP-порты
- DNS A-запись
- DNS AAAA-запись
- локальный TLS-сертификат
- срок действия сертификата
- Nginx-конфигурацию
- наличие `/dev/shm/nginx.sock`
- доступность Unix socket внутри RemnaNode
- сертификат, который реально отдаётся через REALITY fallback
- настройки `acme.sh`
- корректность JSON Xray-профиля
- возможность загрузки профиля текущей версией Xray
- последние логи RemnaNode
- последние логи nginx-selfsteal

## Обновление Node

Для обновления контейнеров используется пункт:

```text
3. Обновить RemnaNode / контейнеры
```

Менеджер выполняет:

```bash
docker compose pull
docker compose up -d --remove-orphans
```

Это обновляет используемые Docker images, включая:

```text
remnawave/node:latest
nginx:alpine
```

## Изменение inbound'ов

После установки можно изменить набор inbound'ов без полной переустановки Node.

Используйте:

```text
7. Настроить inbound'ы / пересобрать Xray profile
```

После изменения менеджер:

- обновит конфигурацию
- настроит UFW
- при необходимости настроит UDP buffers
- сгенерирует новый Xray profile
- обновит `profile-info.txt`

После этого новый профиль необходимо вручную сохранить или отправить в Remnawave Panel.

## Reality-ключи

Менеджер автоматически генерирует:

- Reality Private Key
- Reality Public Key
- Short ID для RAW
- Short ID для XHTTP

Параметры сохраняются локально.

Для просмотра:

```text
6. Показать Reality keys / параметры профиля
```

Для полной ротации Reality keypair:

```text
9. Сгенерировать новую Reality keypair
```

После смены Reality keypair необходимо обновить профиль в Remnawave Panel и клиентские конфигурации.

## Изменение домена

Для изменения домена используется:

```text
8. Изменить домен / название cloud-заглушки
```

Менеджер может:

- изменить домен
- изменить название Cloud-сервиса
- проверить DNS
- выпустить новый сертификат
- обновить Nginx
- пересоздать Cloud-страницу
- обновить Xray-profile
- удалить старый сертификат из списка автоматического renewal `acme.sh`

После изменения домена необходимо также обновить Host и Config Profile в Remnawave Panel.

## Удаление Node

Используйте:

```text
11. Удалить Node
```

Для защиты от случайного удаления менеджер запросит подтверждение:

```text
DELETE
```

При удалении:

- останавливаются контейнеры
- удаляется Docker Compose stack
- при подтверждении удаляются файлы `/opt/remnanode`
- при подтверждении домен удаляется из auto-renew `acme.sh`

При этом менеджер **не удаляет**:

- Docker
- UFW
- OpenSSH
- системные SSH-настройки

## Безопасность

Не публикуйте следующие файлы:

```text
/opt/remnanode/.env
/opt/remnanode/reality.env
/opt/remnanode/ssl/
/opt/remnanode/profiles/xray-profile.json
/opt/remnanode/profiles/profile-info.txt
```

Они могут содержать:

- `SECRET_KEY`
- Reality Private Key
- TLS Private Key
- Short ID
- другие параметры подключения

Если Reality Private Key был опубликован или скомпрометирован, рекомендуется сразу выполнить его ротацию.

Если TLS Private Key был опубликован, необходимо перевыпустить сертификат.

Cloud-страница предназначена исключительно для отображения нейтральной страницы-заглушки и не должна использоваться для имитации сторонних брендов или сбора чужих учётных данных.

## Рекомендуемый `.gitignore`

```gitignore
.env
*.key
*.pem
reality.env
profiles/*.json
profiles/*.txt
```

## Структура GitHub-репозитория

Для публикации самого менеджера достаточно:

```text
Remnanode-manager/
├── install.sh
├── README.md
└── .gitignore
```

При этом runtime-файлы Node создаются уже непосредственно на сервере в:

```text
/opt/remnanode/
```

и в GitHub не попадают.

## Пример запуска с GitHub

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/OverlayNode/Remnanode-manager/main/install.sh)
```

Или:

```bash
curl -fsSL https://raw.githubusercontent.com/OverlayNode/Remnanode-manager/main/install.sh \
  -o /root/install.sh

chmod +x /root/install.sh

/root/install.sh
```
