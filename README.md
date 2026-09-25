# Remnawave Node Manager

Интерактивный менеджер для установки и обслуживания Remnawave Node на Ubuntu и Debian.

Скрипт умеет:

- установить RemnaNode;
- установить RemnaNode вместе с локальным TLS и Nginx Selfsteal;
- добавить TLS, Selfsteal и страницу-заглушку к уже установленной RemnaNode;
- настроить UFW;
- выпустить и продлевать сертификаты Let's Encrypt через `acme.sh`;
- создать профили Xray для VLESS RAW, VLESS XHTTP и Hysteria2;
- обновить контейнеры, изменить домен, заменить Reality-ключи и выполнить диагностику.

## Требования

- Ubuntu или Debian;
- запуск от пользователя `root`;
- установленная RemnaNode должна использовать контейнер с именем `remnanode`;
- для TLS нужен домен с A-записью, направленной на сервер;
- если у домена есть AAAA-запись, она также должна вести на этот сервер;
- TCP-порт `80` должен быть доступен из интернета для выпуска и продления сертификата.

## Запуск

```bash
curl -fsSL https://raw.githubusercontent.com/OverlayNode/Remnanode-manager/main/install.sh \
  -o /root/remnanode-manager.sh

chmod +x /root/remnanode-manager.sh
/root/remnanode-manager.sh
```

## Главное меню

```text
1. Установить Remna Node
2. Установить Remna Node + SSL / Selfsteal / сайт-заглушку
3. Добавить SSL / Selfsteal / сайт-заглушку к установленной Remna Node

4. Обновить RemnaNode / контейнеры
5. SSL / сертификаты
6. Диагностика Node / Selfsteal
7. Показать Reality keys / параметры профиля
8. Настроить inbound'ы / пересобрать Xray profile
9. Изменить домен / название cloud-заглушки
10. Сгенерировать новую Reality keypair
11. Показать структуру файлов
12. Удалить установленный стек / Selfsteal

0. Выход
```

## Новая RemnaNode

Пункт `1` устанавливает только RemnaNode.

Пункт `2` устанавливает полный стек:

- RemnaNode;
- Nginx Selfsteal;
- TLS-сертификат;
- страницу-заглушку;
- выбранные inbound'ы и Xray-профиль.

При новой установке скрипт запросит `SECRET_KEY`, полученный в Remnawave Panel. Ключ записывается непосредственно в `/opt/remnanode/docker-compose.yml`:

```yaml
environment:
  NODE_PORT: '2222'
  SECRET_KEY: 'ваш-secret-key'
```

Compose-файл содержит секрет и создаётся с доступом только для `root`.

## Уже установленная RemnaNode

Пункт `3` добавляет Selfsteal к работающему контейнеру `remnanode`. Повторно вводить `SECRET_KEY` не требуется: скрипт сохраняет уже указанное значение в существующем Compose-файле.

Менеджер определяет исходный Compose-файл через Docker labels. Если путь определить не удалось, его нужно указать вручную.

Перед изменением создаётся резервная копия исходного Compose-файла. Затем менеджер непосредственно в нём:

- добавляет сервис `nginx-selfsteal`;
- подключает `/dev/shm` к Nginx и RemnaNode;
- подключает локальные сертификаты к обоим контейнерам;
- запускает RemnaNode после успешного healthcheck Nginx.

Изменённый файл проверяется командой `docker compose config`, после чего стек применяется обычной командой:

```bash
docker compose -f /путь/к/docker-compose.yml up -d
```

Если исходный Compose использует другое имя сервиса, менеджер получает его из label `com.docker.compose.service`.

## Данные, запрашиваемые при настройке Selfsteal

- IP или CIDR сервера Remnawave Panel;
- домен Node;
- название страницы-заглушки;
- email для Let's Encrypt;
- нужные inbound'ы;
- порты RAW, XHTTP и Hysteria2;
- режим и путь XHTTP.

Доступны следующие inbound'ы:

```text
1. VLESS RAW + REALITY + Selfsteal
2. VLESS XHTTP + REALITY + Selfsteal
3. Hysteria2 (UDP + TLS)
4. Все
```

Порты по умолчанию:

| Назначение | Порт |
|---|---:|
| SSH | `22/tcp` |
| RemnaNode API | `2222/tcp` |
| Let's Encrypt HTTP-01 | `80/tcp` |
| VLESS RAW | `443/tcp` |
| VLESS XHTTP вместе с RAW | `8443/tcp` |
| Hysteria2 | `443/udp` |

TCP `443` и UDP `443` могут использоваться одновременно.

## Remnawave Panel

После настройки Selfsteal создаются:

```text
/opt/remnanode/profiles/xray-profile.json
/opt/remnanode/profiles/profile-info.txt
```

Содержимое `xray-profile.json` нужно добавить в Remnawave Panel в разделе `Config Profiles`, после чего назначить профиль нужной Node.

`profile-info.txt` содержит домен, порты, SNI, Reality Public Key, Short ID, XHTTP path и другие параметры подключения.

## Сертификаты

Сертификаты сохраняются в:

```text
/opt/remnanode/ssl/fullchain.pem
/opt/remnanode/ssl/privkey.pem
```

`acme.sh` автоматически продлевает сертификат. После обновления сертификата выполняется перезапуск `nginx-selfsteal`.

TCP-порт `80` должен оставаться доступным для последующих HTTP-01 проверок.

## Firewall

Менеджер сохраняет SSH-доступ и открывает порты, выбранные при настройке. Доступ к API Node можно ограничить IP или CIDR сервера панели. Если оставить адрес панели пустым, `2222/tcp` будет открыт для всех адресов.

Сброс существующих правил UFW отключён по умолчанию. Правила менеджера получают комментарий `remnanode-manager`, обновляются при изменении inbound'ов и удаляются при удалении стека.

Внешний Firewall или Security Group VPS-провайдера настраивается отдельно.

## Файлы

```text
/opt/remnanode/
├── docker-compose.yml
├── installer.conf
├── ufw.rules
├── nginx.conf
├── reality.env
├── ssl/
│   ├── fullchain.pem
│   └── privkey.pem
├── html/
│   ├── index.html
│   ├── style.css
│   ├── favicon.svg
│   ├── robots.txt
│   └── 404.html
└── profiles/
    ├── xray-profile.json
    └── profile-info.txt
```

При установке поверх существующей Node файл `docker-compose.yml` может находиться в другом каталоге. Его путь сохраняется в `installer.conf`.

Файлы `docker-compose.yml`, `reality.env`, `installer.conf`, сертификаты и профили могут содержать секретные данные. Их нельзя публиковать или передавать посторонним.

## Удаление

Для Node, установленной самим менеджером, удаление останавливает весь созданный Compose-стек и предлагает удалить `/opt/remnanode`.

Для ранее существовавшей Node удаляется сервис `nginx-selfsteal`, а добавленные менеджером mounts и зависимость удаляются из исходного Compose-файла. Контейнер `remnanode`, его `SECRET_KEY` и остальные параметры сохраняются.
