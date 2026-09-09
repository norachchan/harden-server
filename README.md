# ImageCat Deploy

Автоматический деплой VPN «белые списки»: **entry (RU)** + **exit (EU bridge)**, 3x-ui, nginx, подписки Happ, Docker.

```
Клиент (Happ)
    → static.imagecat.ru (CDN)
    → entry: nginx → xray (whitelist inbounds)
    → exit: se-bridge (Reality) → интернет
```

Подробная ручная настройка: [MANUAL-SETUP.md](MANUAL-SETUP.md).

---

## Требования

- Ubuntu 22.04 / 24.04, root
- Домен с A-записью на entry-сервер
- CDN (Yandex) → origin entry:443, path VPN
- Exit-сервер (EU) с SSH и x-ui bridge на :443
- SSH-ключ exit в `imagecat_deploy/nl-srv02`

---

## Быстрый старт (новый сервер)

```bash
# 1. Положить пакет в /home/ubuntu/imagecat_deploy
# 2. Положить ключ exit:
chmod 600 /home/ubuntu/imagecat_deploy/nl-srv02

# 3. Создать /etc/imagecat/deploy.json (или через menu → пункт 5)
# 4. Установка одной командой:
sudo bash /home/ubuntu/imagecat_deploy/deploy.sh install
```

Скрипт сам:
- ставит зависимости и **Docker** (если нет);
- собирает образ и запускает контейнер `imagecat-deploy`;
- спрашивает режим БД (с нуля / restore / оставить);
- синхронизирует bridge-ключи с exit по SSH;
- выполняет полный пайплайн: certs → panel → nginx → subs → xray.

**Интерактивное меню:**

```bash
sudo bash /home/ubuntu/imagecat_deploy/deploy.sh menu
```

---

## Команды deploy.sh

| Команда | Назначение |
|---------|------------|
| `install` | Полная установка в Docker (по умолчанию) |
| `install --fresh` | С нуля: бэкап старой БД → новая x-ui |
| `install --restore=/path/x-ui-….db` | Восстановить панель/клиентов из бэкапа |
| `install --keep` | Не трогать БД, применить стек |
| `up` | Поднять контейнер после reboot (без redeploy) |
| `backup` | Бэкап x-ui.db → `/etc/imagecat/backups/` |
| `repair` | **Только аварийное** восстановление nginx/subs/xray |
| `menu` | Интерактивное меню |
| `pack` | Собрать `imagecat-deploy.tar.gz` для переноса |

Примеры:

```bash
sudo bash deploy.sh install
sudo bash deploy.sh install --restore=/etc/imagecat/backups/x-ui-20260819-182530-manual.db
sudo bash deploy.sh backup
sudo bash deploy.sh up
```

---

## Режим БД при install

```
=== База x-ui: режим деплоя ===
  1) С нуля (новая БД, переустановка x-ui)
  2) Восстановить из бэкапа
  3) Оставить текущую БД          ← если БД уже на сервере
```

Бэкапы: `/etc/imagecat/backups/x-ui-*.db` (+ `deploy-*.json` при наличии).

---

## Миграция на новый entry (сервер заблокировали)

Exit (`45.82.64.248`) **не переезжает** — меняется только entry.

### На старом сервере (до блокировки)

```bash
sudo bash deploy.sh backup
sudo tar czf /root/imagecat-migrate.tar.gz \
  /etc/imagecat \
  /home/ubuntu/imagecat_deploy
scp /root/imagecat-migrate.tar.gz root@NEW_IP:/root/
```

### На новом сервере

```bash
mkdir -p /home/ubuntu && cd /home/ubuntu
tar xzf /root/imagecat-migrate.tar.gz
chmod 600 imagecat_deploy/nl-srv02
```

**DNS / CDN:** A `@` → NEW_IP, CDN origin → NEW_IP:443.

```bash
sudo bash imagecat_deploy/deploy.sh install --restore=/etc/imagecat/backups/x-ui-YYYYMMDD-….db
```

Клиенты сохраняют те же `subId` и UUID — достаточно обновить подписку в Happ.

---

## Конфигурация

| Файл | Содержимое |
|------|------------|
| `/etc/imagecat/deploy.json` | домен, CDN, exit SSH, bridge, nginx |
| `/etc/imagecat/runtime-apply.env` | пароль панели для hooks |
| `/etc/imagecat/backups/` | бэкапы x-ui.db |
| `/etc/x-ui/x-ui.db` | SQLite 3x-ui |

Пример exit в `deploy.json`:

```json
"exit": {
  "host": "45.82.64.248",
  "ssh_port": 39059,
  "ssh_user": "root",
  "ssh_key": "/home/ubuntu/imagecat_deploy/nl-srv02",
  "bridge": { "mode": "auto" }
}
```

Ключ exit ищется автоматически: `deploy.json` → `nl-srv02` → `/etc/imagecat/exit_ssh_key`.

---

## Меню (deploy.sh menu)

| # | Действие |
|---|----------|
| 1 | Полный деплой: exit (SSH) → entry |
| 2 | Только EXIT — bridge на EU |
| 3 | Только ENTRY — x-ui + inbounds + nginx |
| 4 | Переприменить entry stack |
| r | Repair (аварийное восстановление) |
| b | Бэкап x-ui БД сейчас |
| 5 | Мастер: домен, CDN, версия x-ui |
| 6–9 | Импорт учёток, SSH-проверка exit |
| g, w | GitHub auth, gallery-сайт |

---

## Docker

Сервисы работают **внутри контейнера** `imagecat-deploy` (systemd + host network):

- nginx, x-ui, whitelist-sub — в контейнере
- на хосте эти unit'ы отключены (порты 80/443 занимает контейнер)

Volumes (данные переживают пересборку образа):

```
/home/ubuntu/imagecat_deploy   — код
/etc/imagecat                  — конфиг и бэкапы
/etc/x-ui, /usr/local/x-ui     — панель и xray
/etc/nginx, /etc/letsencrypt   — nginx и LE-сертификаты
/etc/ssl/imagecat              — CDN self-signed (fallback)
```

Переменные окружения:

```bash
IMAGECAT_DOCKER_CONTAINER=imagecat-deploy
IMAGECAT_DOCKER_IMAGE=imagecat-deploy:latest
IMAGECAT_DB_MODE=fresh|restore|keep
IMAGECAT_DB_BACKUP=/path/to/backup.db
```

---

## После деплоя (вручную)

1. **DNS:** `imagecat.ru` A → IP entry; `static.imagecat.ru` → CDN
2. **Yandex CDN:** origin = entry IP, HTTPS :443
3. **CDN path:** `{vpn_path}` из deploy.json (например `/assets/…/sync`)
4. Проверка подписки: `curl -skI https://imagecat.ru/subs/<subId>`

> **LTE / мобильный интернет:** URL подписки — `https://imagecat.ru/subs/` (прямой entry), **не** CDN.
> CDN (`static.imagecat.ru`) — только VPN-трафик; с LTE подписка через CDN часто не открывается.

---

## Архитектура пайплайна

```
install
  ├─ bootstrap (apt, docker)
  ├─ choose_db_mode (fresh / restore / keep)
  ├─ docker build + container
  └─ run_deploy()
       ├─ sync bridge keys (SSH → exit)
       ├─ deploy_entry_full     ← fresh / первый раз
       └─ apply_entry_stack     ← restore / keep
            ├─ certs + assets
            ├─ finish-panel-setup (inbounds, xhttp, se-bridge)
            ├─ nginx + whitelist-sub
            └─ xray runtime guard
```

`repair` — отдельная команда, **не** часть нормального install.

---

## Полезные команды

```bash
# Health-check
sudo docker exec imagecat-deploy python3 -m imagecat_deploy.health run

# Подписка клиента
sudo docker exec imagecat-deploy python3 -m imagecat_deploy.subscription print --sub-id SUB_ID

# Статус сервисов
sudo docker exec imagecat-deploy systemctl is-active x-ui nginx whitelist-sub

# Логи x-ui
sudo docker exec imagecat-deploy journalctl -u x-ui -n 50 --no-pager
```

---

## Структура пакета

```
imagecat_deploy/
  deploy.sh                 — главный launcher
  Dockerfile
  finish-panel-setup.py     — panel / xray / inbounds
  nl-srv02                  — SSH-ключ exit (не коммитить!)
  cli/                      — menu, db_mode
  core/                     — config, urls, runtime
  ops/
    deploy_pipeline.py      — run_deploy() — правильный install
    entry_stack.py          — apply_entry_stack / repair_stack
  panel/
    bridge_sync.py          — sync pbk/uuid с exit
    db_backup.py            — backup / restore x-ui.db
    xray_guard.py           — защита se-bridge
  nginx/                    — vhosts, gallery
  subscription/             — Happ JSON subs :8098
  roles/                    — entry.py, exit.py
  remote/exit_setup.py      — скрипт на exit через SSH
  scripts/container-init.sh — старт контейнера (без redeploy)
  assets/vpn-whitelist.json — шаблон Happ
```

---

## Упаковка для переноса

```bash
sudo bash deploy.sh pack
# → imagecat-deploy.tar.gz

# На новом сервере:
mkdir -p /home/ubuntu && cd /home/ubuntu
tar xzf imagecat-deploy.tar.gz
sudo bash deploy.sh install
```

---

## Troubleshooting

| Симптом | Действие |
|---------|----------|
| Happ `n/a` | `deploy.sh repair`; проверить bridge: exit SSH + pbk sync |
| `/subs/` 404 | `repair` — nginx proxy_pass |
| REALITY errors | bridge keys не совпадают → `repair` или `install --keep` |
| После reboot | `deploy.sh up` |
| Всё сломалось | `deploy.sh repair` или restore из backup |

---

## Связанные скрипты

- `finish-panel-setup.py` — оркестратор entry (внутри пакета)
- `python3 -m imagecat_deploy` — интерактивное меню
- `python3 -m imagecat_deploy.subscription serve` — HTTP подписок
