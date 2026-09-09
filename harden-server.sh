#!/usr/bin/env bash
# harden-server.sh — Debian/Ubuntu server hardening with 3x-ui style menu
# Secrets are printed once only and never written to disk/logs/history.

set -euo pipefail

# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${CYAN}[INF]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC}  $*" >&2; }

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "Запустите от root: bash $0"
    err "Если есть sudo: sudo bash $0"
    exit 1
  fi
}

ensure_sudo_installed() {
  if command -v sudo >/dev/null 2>&1; then
    return 0
  fi
  log "Пакет sudo не найден — устанавливаю..."
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sudo >/dev/null 2>&1; then
      ok "sudo установлен"
      return 0
    fi
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y sudo >/dev/null 2>&1 && ok "sudo установлен" && return 0
  elif command -v yum >/dev/null 2>&1; then
    yum install -y sudo >/dev/null 2>&1 && ok "sudo установлен" && return 0
  fi
  warn "Не удалось установить sudo автоматически — поставьте вручную: apt-get install -y sudo"
  return 1
}

pause() {
  read -r -p "Нажмите Enter для продолжения..." _
}

# ---------------------------------------------------------------------------
# Runtime state (in-memory only; never persisted)
# ---------------------------------------------------------------------------
ROOT_PASS=""
SYS_USER=""
SYS_PASS=""
SSH_PORT_NEW=""
XUI_USER=""
XUI_PASS=""
XUI_URL=""
XUI_API_TOKEN=""
RAN_ALL=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
detect_os_user() {
  local id_like="" id_name=""
  # shellcheck disable=SC1091
  source /etc/os-release
  id_name="${ID:-}"
  id_like="${ID_LIKE:-}"
  if [[ "$id_name" == "ubuntu" || "$id_like" == *"ubuntu"* ]]; then
    echo "ubuntu"
  else
    echo "debian"
  fi
}

# OS passwords: long, with specials (for root / system user via chpasswd)
gen_password_60() {
  local alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()-_=+[]{};:,.<>/?'
  local pass="" i idx
  # Prefer openssl; fallback to /dev/urandom
  if command -v openssl >/dev/null 2>&1; then
    for ((i = 0; i < 60; i++)); do
      idx=$(openssl rand -hex 2)
      idx=$((16#$idx % ${#alphabet}))
      pass+="${alphabet:$idx:1}"
    done
  else
    local bytes
    bytes=$(head -c 240 /dev/urandom | base64 | tr -d '\n')
    for ((i = 0; i < 60; i++)); do
      idx=$(printf '%d' "'${bytes:$i:1}")
      idx=$((idx % ${#alphabet}))
      pass+="${alphabet:$idx:1}"
    done
  fi
  printf '%s' "$pass"
}

# Panel credentials: alphanumeric only (как в официальном 3x-ui) — спецсимволы
# в веб-форме часто ломают логин / копипаст.
gen_alnum() {
  local length="${1:-16}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 $((length * 2)) | tr -dc 'a-zA-Z0-9' | head -c "$length"
  else
    tr -dc 'a-zA-Z0-9' </dev/urandom | head -c "$length"
  fi
}

gen_username() {
  gen_alnum 12
}

port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tuln | awk '{print $5}' | grep -E "[:.]${port}$" >/dev/null 2>&1
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tuln 2>/dev/null | awk '{print $4}' | grep -E "[:.]${port}$" >/dev/null 2>&1
  else
    return 1
  fi
}

pick_free_ssh_port() {
  local port tries=0
  while ((tries < 50)); do
    port=$((20000 + RANDOM % 40001)) # 20000..60000
    if ! port_in_use "$port"; then
      echo "$port"
      return 0
    fi
    ((tries++)) || true
  done
  return 1
}

set_user_password() {
  local user="$1" pass="$2"
  # Avoid shell history: use chpasswd via FD, not echo in argv of shell history helpers
  printf '%s:%s\n' "$user" "$pass" | chpasswd
}

has_authorized_keys() {
  local user="$1" home keys
  home=$(getent passwd "$user" | cut -d: -f6 || true)
  [[ -n "$home" ]] || return 1
  keys="$home/.ssh/authorized_keys"
  [[ -f "$keys" ]] || return 1
  # non-empty, non-comment line
  grep -Eqv '^\s*(#|$)' "$keys"
}

# Copy root SSH public keys to system user so key login keeps working
copy_root_authorized_keys_to_user() {
  local user="$1" home src="/root/.ssh/authorized_keys" dst_dir dst
  home=$(getent passwd "$user" | cut -d: -f6 || true)
  if [[ -z "$home" || ! -d "$home" ]]; then
    err "Домашняя директория пользователя ${user} не найдена"
    return 1
  fi
  if [[ ! -f "$src" ]] || ! grep -Eqv '^\s*(#|$)' "$src"; then
    warn "У root нет ${src} — копировать нечего. Добавьте ключ вручную в ${home}/.ssh/authorized_keys"
    return 1
  fi
  dst_dir="${home}/.ssh"
  dst="${dst_dir}/authorized_keys"
  mkdir -p "$dst_dir"
  cp -f "$src" "$dst"
  chmod 700 "$dst_dir"
  chmod 600 "$dst"
  chown -R "${user}:${user}" "$dst_dir"
  ok "SSH-ключи скопированы: ${src} → ${dst}"
}

ssh_service_name() {
  if systemctl list-unit-files 2>/dev/null | grep -qE '^ssh\.service'; then
    echo ssh
  elif systemctl list-unit-files 2>/dev/null | grep -qE '^sshd\.service'; then
    echo sshd
  elif systemctl list-units --all 2>/dev/null | grep -qE 'sshd\.service'; then
    echo sshd
  else
    echo ssh
  fi
}

ssh_listening_on_port() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tln | awk '{print $4}' | grep -E "[:.]${port}$" >/dev/null 2>&1
  else
    return 1
  fi
}

# Port changes require full restart. Also disable socket activation (ssh.socket),
# otherwise systemd keeps listening on :22 and ignores Port in sshd_config until reboot.
disable_ssh_socket_activation() {
  local sock
  for sock in ssh.socket sshd.socket; do
    if systemctl list-unit-files 2>/dev/null | grep -qE "^${sock}"; then
      log "Отключаю ${sock} (socket activation мешает смене Port)..."
      systemctl stop "$sock" 2>/dev/null || true
      systemctl disable "$sock" 2>/dev/null || true
      systemctl mask "$sock" 2>/dev/null || true
    fi
  done
  # Drop-in overrides for ListenStream if socket somehow re-enabled later
  if [[ -f /lib/systemd/system/ssh.socket ]] || [[ -f /usr/lib/systemd/system/ssh.socket ]]; then
    mkdir -p /etc/systemd/system/ssh.socket.d
    cat >/etc/systemd/system/ssh.socket.d/override.conf <<EOF
[Socket]
ListenStream=
EOF
  fi
}

validate_sshd_config() {
  if command -v sshd >/dev/null 2>&1; then
    sshd -t
    return $?
  fi
  # Some builds only have /usr/sbin/sshd
  if [[ -x /usr/sbin/sshd ]]; then
    /usr/sbin/sshd -t
    return $?
  fi
  warn "sshd -t недоступен — пропускаю валидацию конфига"
  return 0
}

# Hard apply sshd settings without rebooting the whole server
apply_ssh_now() {
  local want_port="${1:-}"
  local svc
  svc=$(ssh_service_name)

  disable_ssh_socket_activation
  validate_sshd_config || {
    err "sshd_config невалиден — SSH не перезапускаю"
    return 1
  }

  systemctl daemon-reload 2>/dev/null || true

  # Prefer restart over reload: Port / Auth changes often ignored by SIGHUP/reload
  log "Жёсткий restart ${svc}.service (не reload)..."
  systemctl enable "$svc" 2>/dev/null || true
  systemctl restart "$svc"

  # Give daemon a moment to bind
  sleep 1
  local i
  for i in 1 2 3 4 5; do
    if [[ -n "$want_port" ]]; then
      if ssh_listening_on_port "$want_port"; then
        ok "SSH слушает TCP ${want_port}"
        return 0
      fi
    elif systemctl is-active --quiet "$svc"; then
      ok "${svc} active"
      return 0
    fi
    sleep 1
    systemctl restart "$svc" 2>/dev/null || true
  done

  if [[ -n "$want_port" ]] && ! ssh_listening_on_port "$want_port"; then
    err "После restart порт ${want_port} всё ещё не слушается"
    systemctl status "$svc" --no-pager -l 2>/dev/null | tail -20 || true
    ss -tlnp | grep -E 'ssh|sshd' || true
    return 1
  fi
  return 0
}

# Back-compat name used elsewhere
reload_ssh() {
  apply_ssh_now
}

ensure_ssh_setting() {
  # ensure_ssh_setting Key Value
  local key="$1" value="$2"
  local main="/etc/ssh/sshd_config"
  local drop="/etc/ssh/sshd_config.d/99-harden.conf"
  mkdir -p /etc/ssh/sshd_config.d

  # Comment duplicates in main config
  if [[ -f "$main" ]]; then
    sed -i -E "s/^[#[:space:]]*${key}[[:space:]].*/#&/I" "$main" || true
  fi

  touch "$drop"
  if grep -Eq "^[#[:space:]]*${key}[[:space:]]+" "$drop"; then
    sed -i -E "s/^[#[:space:]]*${key}[[:space:]].*/${key} ${value}/I" "$drop"
  else
    printf '%s %s\n' "$key" "$value" >>"$drop"
  fi
}

open_firewall_port() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi 'Status: active'; then
    ufw allow "${port}/tcp" comment 'harden-ssh' >/dev/null || true
    ok "UFW: разрешён TCP ${port}"
    return
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null || true
    firewall-cmd --reload >/dev/null || true
    ok "firewalld: разрешён TCP ${port}"
    return
  fi
  if command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q 'hook input'; then
    # Best-effort: do not invent complex nft policy; just inform
    warn "Обнаружен nftables. Убедитесь, что TCP ${port} открыт вручную при необходимости."
    return
  fi
  if command -v iptables >/dev/null 2>&1; then
    if iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
      ok "iptables: TCP ${port} уже разрешён"
    else
      iptables -I INPUT -p tcp --dport "$port" -j ACCEPT || true
      ok "iptables: добавлен ACCEPT TCP ${port}"
    fi
  fi
}

print_secret_once_banner() {
  echo
  echo -e "${YELLOW}${BOLD}⚠  Скопируйте данные сейчас. Повторно они не будут показаны и никуда не сохраняются.${NC}"
  echo
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
change_root_password() {
  log "Генерация и смена пароля root..."
  ROOT_PASS=$(gen_password_60)
  set_user_password root "$ROOT_PASS"
  ok "Пароль root обновлён"
  if [[ "$RAN_ALL" -eq 0 ]]; then
    print_secret_once_banner
    echo -e "${BOLD}root password:${NC} ${ROOT_PASS}"
    echo
  fi
}

create_system_user() {
  SYS_USER=$(detect_os_user)
  log "Системный пользователь: ${SYS_USER}"

  ensure_sudo_installed || true

  if id "$SYS_USER" >/dev/null 2>&1; then
    warn "Пользователь ${SYS_USER} уже существует — обновляю пароль/группы"
  else
    useradd -m -s /bin/bash "$SYS_USER"
    ok "Создан пользователь ${SYS_USER}"
  fi

  if getent group sudo >/dev/null 2>&1; then
    usermod -aG sudo "$SYS_USER"
    ok "${SYS_USER} добавлен в группу sudo"
  elif getent group wheel >/dev/null 2>&1; then
    usermod -aG wheel "$SYS_USER"
    ok "${SYS_USER} добавлен в группу wheel"
  else
    warn "Группа sudo/wheel не найдена — пользователь без прав повышения привилегий"
  fi

  # Passwordless-less NOPASSWD not set; ensure sudoers.d allows group if needed
  if [[ -d /etc/sudoers.d ]] && getent group sudo >/dev/null 2>&1; then
    if [[ ! -f /etc/sudoers.d/90-harden-sudo ]]; then
      printf '%%sudo ALL=(ALL:ALL) ALL\n' >/etc/sudoers.d/90-harden-sudo
      chmod 440 /etc/sudoers.d/90-harden-sudo
    fi
  fi

  # Ensure unique password vs root
  while :; do
    SYS_PASS=$(gen_password_60)
    [[ "$SYS_PASS" != "$ROOT_PASS" ]] && break
  done
  set_user_password "$SYS_USER" "$SYS_PASS"
  ok "Пароль ${SYS_USER} обновлён"

  # Без этого после отключения root/password SSH вход по ключу ломается
  copy_root_authorized_keys_to_user "$SYS_USER" || true

  if [[ "$RAN_ALL" -eq 0 ]]; then
    print_secret_once_banner
    echo -e "${BOLD}user:${NC}     ${SYS_USER}"
    echo -e "${BOLD}password:${NC} ${SYS_PASS}"
    echo
  fi
}

change_ssh_port() {
  log "Смена SSH-порта..."
  local port
  port=$(pick_free_ssh_port) || {
    err "Не удалось подобрать свободный порт"
    return 1
  }
  SSH_PORT_NEW="$port"

  ensure_ssh_setting Port "$SSH_PORT_NEW"
  # Also force Port in main file if Include is missing / ignored
  if [[ -f /etc/ssh/sshd_config ]] && ! grep -Eq '^\s*Include\s+.*/sshd_config\.d/' /etc/ssh/sshd_config; then
    if grep -Eq '^[#[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config; then
      sed -i -E "s/^[#[:space:]]*Port[[:space:]].*/Port ${SSH_PORT_NEW}/I" /etc/ssh/sshd_config
    else
      printf '\nPort %s\n' "$SSH_PORT_NEW" >>/etc/ssh/sshd_config
    fi
  fi

  open_firewall_port "$SSH_PORT_NEW"

  if ! apply_ssh_now "$SSH_PORT_NEW"; then
    err "Порт в конфиге записан (${SSH_PORT_NEW}), но сервис не слушает его"
    return 1
  fi

  # Effective port from running daemon
  local effective
  effective=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)
  if [[ -n "$effective" && "$effective" != "$SSH_PORT_NEW" ]]; then
    err "sshd -T показывает port=${effective}, ожидали ${SSH_PORT_NEW}"
    return 1
  fi

  ok "SSH порт применён без reboot: ${SSH_PORT_NEW} (старый 22 не закрывался фаерволом)"
  warn "Проверьте вход на новом порту во второй сессии, прежде чем закрывать текущую."

  if [[ "$RAN_ALL" -eq 0 ]]; then
    print_secret_once_banner
    echo -e "${BOLD}SSH port:${NC} ${SSH_PORT_NEW}"
    echo
  fi
}

disable_password_auth() {
  log "Отключение SSH password authentication..."
  local target_user keys_ok=0
  target_user=$(detect_os_user)

  if has_authorized_keys root || has_authorized_keys "$target_user"; then
    keys_ok=1
  fi

  if [[ "$keys_ok" -eq 0 ]]; then
    warn "Не найден authorized_keys у root или ${target_user}."
    echo -ne "${YELLOW}Отключить вход по паролю всё равно? Это может заблокировать доступ. [y/N]: ${NC}"
    read -r ans
    if [[ ! "${ans,,}" =~ ^y(es)?$ ]]; then
      warn "Пропущено: PasswordAuthentication не отключён"
      return 0
    fi
  fi

  # Keys must already be on the system user before locking root out
  if ! has_authorized_keys "$target_user"; then
    copy_root_authorized_keys_to_user "$target_user" || true
  fi

  ensure_ssh_setting PasswordAuthentication no
  ensure_ssh_setting KbdInteractiveAuthentication no
  ensure_ssh_setting ChallengeResponseAuthentication no
  ensure_ssh_setting PermitRootLogin no
  # Pubkey must stay on
  ensure_ssh_setting PubkeyAuthentication yes

  if command -v sshd >/dev/null 2>&1 || [[ -x /usr/sbin/sshd ]]; then
    validate_sshd_config || return 1
  fi
  apply_ssh_now "${SSH_PORT_NEW:-}" || apply_ssh_now
  ok "PasswordAuthentication=no, PermitRootLogin=no (root SSH запрещён)"
}


find_xui_binary() {
  if [[ -x /usr/local/x-ui/x-ui ]]; then
    echo /usr/local/x-ui/x-ui
    return 0
  fi
  if command -v x-ui >/dev/null 2>&1; then
    # /usr/bin/x-ui is often the menu script; prefer real binary beside it
    local real
    real=$(command -v x-ui)
    if [[ -x /usr/local/x-ui/x-ui ]]; then
      echo /usr/local/x-ui/x-ui
    elif file "$real" 2>/dev/null | grep -qi 'elf\|executable'; then
      echo "$real"
    else
      return 1
    fi
    return 0
  fi
  return 1
}

read_xui_url_hint() {
  XUI_URL=""
  if [[ -f /etc/x-ui/install-result.env ]]; then
    # shellcheck disable=SC1091
    source /etc/x-ui/install-result.env
    XUI_URL="${XUI_ACCESS_URL:-}"
  fi
  # Fallback: ask binary for port/base path without printing secrets
  local bin port path
  bin=$(find_xui_binary 2>/dev/null || true)
  if [[ -n "$bin" && -z "$XUI_URL" ]]; then
    # -show may print multiple lines; best-effort parse
    local shown
    shown=$("$bin" setting -show 2>/dev/null || true)
    port=$(printf '%s\n' "$shown" | grep -iE 'port' | head -1 | grep -oE '[0-9]{2,5}' | head -1 || true)
    path=$(printf '%s\n' "$shown" | grep -iE 'webBasePath|base.?path' | head -1 | awk -F'[=: ]+' '{print $NF}' | tr -d '[:space:]' || true)
    if [[ -n "$port" ]]; then
      XUI_URL="https://<SERVER_IP>:${port}/${path#/}"
    fi
  fi
}

restart_xui_panel() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^x-ui\.service'; then
    systemctl restart x-ui
    return $?
  fi
  if command -v x-ui >/dev/null 2>&1; then
    # non-interactive restart if menu script supports it poorly — try systemctl only
    warn "systemctl unit x-ui не найден — перезапустите панель вручную"
    return 1
  fi
  return 1
}

stop_xui_panel() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^x-ui\.service'; then
    systemctl stop x-ui || true
    sleep 1
    return 0
  fi
  return 1
}

read_xui_api_token() {
  # Existing panel UI tokens are hashed — CLI regenerates a fallback token and prints it once.
  XUI_API_TOKEN=""
  local bin raw
  bin=$(find_xui_binary 2>/dev/null || true)
  [[ -n "$bin" ]] || return 1
  raw=$("$bin" setting -getApiToken 2>&1 || true)
  XUI_API_TOKEN=$(printf '%s\n' "$raw" | awk -F': ' '/^apiToken:/{print $2; exit}' | tr -d '[:space:]')
  if [[ -z "$XUI_API_TOKEN" ]]; then
    XUI_API_TOKEN=$(printf '%s\n' "$raw" | grep -oE 'apiToken:[[:space:]]*[^[:space:]]+' | awk '{print $2; exit}' || true)
  fi
  [[ -n "$XUI_API_TOKEN" ]]
}

reset_xui_credentials() {
  log "Сброс логина/пароля 3x-ui..."
  local bin out shown got_user
  bin=$(find_xui_binary) || {
    err "Бинарник /usr/local/x-ui/x-ui не найден — пункт пропущен"
    return 0
  }

  XUI_USER=$(gen_alnum 12)
  XUI_PASS=$(gen_alnum 60)
  XUI_API_TOKEN=""

  # Менять БД при работающей панели опасно (sqlite WAL) — сначала stop
  log "Останавливаю x-ui перед сменой credentials..."
  stop_xui_panel || warn "Не удалось остановить x-ui — пробую сменить credentials на горячую"

  # Direct CLI (как x-ui.sh reset_user) + сброс 2FA
  out=$("$bin" setting -username "$XUI_USER" -password "$XUI_PASS" -resetTwoFactor=true 2>&1) || {
    err "Не удалось выполнить setting: $out"
    XUI_USER=""; XUI_PASS=""; XUI_API_TOKEN=""
    restart_xui_panel || true
    return 1
  }

  # Проверка, что username реально записался
  shown=$("$bin" setting -show 2>&1 || true)
  got_user=$(printf '%s\n' "$shown" | grep -iE 'username' | head -1 | awk -F'[=: ]+' '{print $NF}' | tr -d '[:space:]' || true)
  if [[ -n "$got_user" && "$got_user" != "$XUI_USER" ]]; then
    err "В БД username=${got_user}, ожидали ${XUI_USER} — credentials могли не сохраниться"
    XUI_USER=""; XUI_PASS=""; XUI_API_TOKEN=""
    restart_xui_panel || true
    return 1
  fi

  # API token: старые UI-токены в plaintext недоступны — CLI выдаёт новый fallback
  if read_xui_api_token; then
    ok "API token получен (предыдущий CLI fallback больше недействителен)"
  else
    warn "Не удалось получить API token через setting -getApiToken"
  fi

  restart_xui_panel || true
  sleep 1
  read_xui_url_hint
  ok "Учётные данные панели 3x-ui сброшены (2FA сброшен)"

  if [[ "$RAN_ALL" -eq 0 ]]; then
    print_secret_once_banner
    echo -e "${BOLD}3x-ui username:${NC}  ${XUI_USER}"
    echo -e "${BOLD}3x-ui password:${NC}  ${XUI_PASS}"
    [[ -n "$XUI_API_TOKEN" ]] && echo -e "${BOLD}3x-ui api key:${NC}   ${XUI_API_TOKEN}"
    [[ -n "$XUI_URL" ]] && echo -e "${BOLD}3x-ui URL:${NC}       ${XUI_URL}"
    echo -e "${YELLOW}Логин/пароль только a-zA-Z0-9 — копируйте целиком, без пробелов.${NC}"
    echo
  fi
}

password_auth_status() {
  if sshd -T 2>/dev/null | grep -qi '^passwordauthentication no'; then
    echo "no"
  elif grep -REqi '^\s*PasswordAuthentication\s+no' /etc/ssh/sshd_config /etc/ssh/sshd_config.d 2>/dev/null; then
    echo "no"
  else
    echo "yes/unknown"
  fi
}

print_summary_once() {
  print_secret_once_banner
  echo -e "${BOLD}========== SUMMARY (once) ==========${NC}"
  [[ -n "$ROOT_PASS" ]] && echo -e "root password:     ${ROOT_PASS}"
  [[ -n "$SYS_USER" ]] && echo -e "system user:       ${SYS_USER}"
  [[ -n "$SYS_PASS" ]] && echo -e "system password:   ${SYS_PASS}"
  [[ -n "$SSH_PORT_NEW" ]] && echo -e "SSH port:          ${SSH_PORT_NEW}"
  echo -e "PasswordAuth:      $(password_auth_status)"
  [[ -n "$XUI_USER" ]] && echo -e "3x-ui username:    ${XUI_USER}"
  [[ -n "$XUI_PASS" ]] && echo -e "3x-ui password:    ${XUI_PASS}"
  [[ -n "$XUI_API_TOKEN" ]] && echo -e "3x-ui api key:     ${XUI_API_TOKEN}"
  [[ -n "$XUI_URL" ]] && echo -e "3x-ui URL:         ${XUI_URL}"
  echo -e "${BOLD}====================================${NC}"
  echo
  # Clear from shell memory variables after display? Keep until process exits.
}

run_all() {
  echo -ne "${YELLOW}Выполнить ВСЕ шаги 2–6? Это изменит root/SSH/3x-ui. [y/N]: ${NC}"
  read -r ans
  if [[ ! "${ans,,}" =~ ^y(es)?$ ]]; then
    warn "Отменено"
    return 0
  fi
  RAN_ALL=1
  change_root_password
  create_system_user
  change_ssh_port
  disable_password_auth
  reset_xui_credentials || true
  print_summary_once
  # Prevent accidental reprint if user continues in menu
  ROOT_PASS=""; SYS_PASS=""; XUI_PASS=""; XUI_API_TOKEN=""
  RAN_ALL=0
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
show_menu() {
  clear
  local os_pretty
  os_pretty=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")
  echo -e "${BLUE}${BOLD}"
  cat <<'EOF'
╔────────────────────────────────────────────────╗
│           Server Harden Script                 │
│  0. Exit                                       │
│────────────────────────────────────────────────│
│  1. Run ALL (2–6)                              │
│  2. Change root password                       │
│  3. Create system user + password              │
│  4. Change SSH port (random)                   │
│  5. Disable SSH password auth                  │
│  6. Reset 3x-ui username & password            │
╚────────────────────────────────────────────────╝
EOF
  echo -e "${NC}"
  echo -e "OS: ${os_pretty}"
  echo -e "${YELLOW}Секреты показываются один раз и никуда не сохраняются.${NC}"
  echo
}

main() {
  require_root
  # Reduce accidental secret leakage into shell history for this process
  unset HISTFILE
  set +o history 2>/dev/null || true

  while true; do
    show_menu
    echo -n "Please enter your selection [0-6]: "
    read -r choice
    case "$choice" in
      0) echo "Bye."; exit 0 ;;
      1) run_all; pause ;;
      2) change_root_password; ROOT_PASS=""; pause ;;
      3) create_system_user; SYS_PASS=""; pause ;;
      4) change_ssh_port; pause ;;
      5) disable_password_auth; pause ;;
      6) reset_xui_credentials; XUI_PASS=""; XUI_API_TOKEN=""; pause ;;
      *) err "Неверный выбор"; sleep 1 ;;
    esac
  done
}

main "$@"
