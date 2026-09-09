# harden-server

Скрипт быстрого hardening для **Debian / Ubuntu**.

Секреты (пароли, логины) печатаются **один раз** в терминал и **нигде не сохраняются**.

## Быстрый старт

```bash
bash <(curl -Ls https://raw.githubusercontent.com/norachchan/harden-server/main/harden-server.sh)
```

Или локально:

```bash
sudo bash harden-server.sh
```

Нужен **root**.

## Меню

| # | Действие |
|---|----------|
| 0 | Выход |
| 1 | Выполнить всё (пункты 2–6) |
| 2 | Смена пароля `root` (60 символов) |
| 3 | Создание пользователя `ubuntu` / `debian` + пароль |
| 4 | Смена SSH-порта на случайный (20000–60000) |
| 5 | Отключение входа по паролю SSH (только ключи) + запрет root по SSH |
| 6 | Сброс логина/пароля панели 3x-ui |

## Что делает скрипт

### 2. Root password
- Генерирует криптостойкий пароль из 60 символов
- Ставит его через `chpasswd`
- Показывает пароль один раз

### 3. Системный пользователь
- Ubuntu → `ubuntu`, Debian → `debian`
- Добавляет в группу `sudo`
- Копирует `/root/.ssh/authorized_keys` → `~/.ssh/authorized_keys` (чтобы SSH по ключу не сломался)
- Показывает логин/пароль один раз

### 4. SSH-порт
- Пишет `Port` в `/etc/ssh/sshd_config.d/99-harden.conf`
- Отключает `ssh.socket` / `sshd.socket` (иначе порт часто не меняется без reboot)
- Делает **жёсткий** `systemctl restart ssh|sshd` (не `reload`)
- Проверяет, что новый порт реально слушается (`ss` / `sshd -T`)
- Открывает новый порт в firewall (UFW / firewalld / iptables), если firewall активен
- Порт **22** скрипт сам не закрывает — закройте после проверки входа на новом порту

### 5. Password auth off
- `PasswordAuthentication no`
- `PermitRootLogin no`
- Перед отключением проверяет наличие `authorized_keys`
- Если ключей нет — спрашивает подтверждение

### 6. 3x-ui
- Без интерактивного меню:  
  `/usr/local/x-ui/x-ui setting -username … -password … -resetTwoFactor=true`
- Перезапуск `systemctl restart x-ui`
- Показывает новые credentials один раз (и URL, если есть в `/etc/x-ui/install-result.env`)

## Важно

1. **Скопируйте пароли сразу** — повторно скрипт их не покажет и в файл не пишет.
2. После смены SSH-порта зайдите **второй сессией** на новый порт, и только потом закрывайте текущую.
3. Перед пунктом 5 убедитесь, что ключ есть у `ubuntu`/`debian` (пункт 3 копирует его с root).
4. Репозиторий для one-liner должен быть **Public**.

## Закрытие порта 22 вручную (после проверки)

UFW:

```bash
ufw delete allow 22/tcp
# или
ufw deny 22/tcp
ufw reload
```

## Файлы

- `harden-server.sh` — основной скрипт
- этот `README.md`

## Лицензия

Используйте на свой риск. Всегда держите запасной SSH-доступ (вторая сессия / консоль провайдера).
