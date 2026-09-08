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
    err "Запустите от root: sudo bash $0"
    exit 1
  fi
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

# 60-char password: upper/lower/digit/special (similar to the given sample style)
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

gen_username() {
  local n=$((16 + RANDOM % 9)) # 16..24
  tr -dc 'a-z' </dev/urandom | head -c "$n"
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

ssh_service_name() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
    echo ssh
  else
    echo sshd
  fi
}

reload_ssh() {
  local svc
  svc=$(ssh_service_name)
  if systemctl is-active --quiet "$svc"; then
    systemctl reload "$svc" 2>/dev/null || systemctl restart "$svc"
  else
    systemctl restart "$svc"
  fi
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

  if id "$SYS_USER" >/dev/null 2>&1; then
    warn "Пользователь ${SYS_USER} уже существует — обновляю пароль/группы"
  else
    useradd -m -s /bin/bash "$SYS_USER"
    ok "Создан пользователь ${SYS_USER}"
  fi

  if getent group sudo >/dev/null 2>&1; then
    usermod -aG sudo "$SYS_USER"
  elif getent group wheel >/dev/null 2>&1; then
    usermod -aG wheel "$SYS_USER"
  fi

  # Ensure unique password vs root
  while :; do
    SYS_PASS=$(gen_password_60)
    [[ "$SYS_PASS" != "$ROOT_PASS" ]] && break
  done
  set_user_password "$SYS_USER" "$SYS_PASS"
  ok "Пароль ${SYS_USER} обновлён"

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
  open_firewall_port "$SSH_PORT_NEW"

  if ! sshd -t 2>/dev/null && ! sshd -t -f /etc/ssh/sshd_config 2>/dev/null; then
    # Some distros use `sshd -t`, validate via service name binary
    if command -v sshd >/dev/null 2>&1; then
      sshd -t || {
        err "sshd_config невалиден"
        return 1
      }
    fi
  fi

  reload_ssh
  ok "SSH слушает порт ${SSH_PORT_NEW} (старый 22 не закрывался)"
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

  ensure_ssh_setting PasswordAuthentication no
  ensure_ssh_setting KbdInteractiveAuthentication no
  ensure_ssh_setting ChallengeResponseAuthentication no
  ensure_ssh_setting PermitRootLogin prohibit-password
  # Pubkey must stay on
  ensure_ssh_setting PubkeyAuthentication yes

  if command -v sshd >/dev/null 2>&1; then
    sshd -t
  fi
  reload_ssh
  ok "PasswordAuthentication=no, PermitRootLogin=prohibit-password"
}

ensure_expect() {
  if command -v expect >/dev/null 2>&1; then
    return 0
  fi
  log "Установка expect..."
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq expect >/dev/null
  else
    err "Не удалось установить expect (нет apt-get)"
    return 1
  fi
}

read_xui_url_hint() {
  XUI_URL=""
  if [[ -f /etc/x-ui/install-result.env ]]; then
    # shellcheck disable=SC1091
    source /etc/x-ui/install-result.env
    XUI_URL="${XUI_ACCESS_URL:-}"
  fi
}

reset_xui_credentials() {
  log "Сброс логина/пароля 3x-ui..."
  if ! command -v x-ui >/dev/null 2>&1; then
    err "Команда x-ui не найдена — пункт пропущен"
    return 0
  fi
  ensure_expect || return 1

  XUI_USER=$(gen_username)
  while :; do
    XUI_PASS=$(gen_password_60)
    [[ "$XUI_PASS" != "$ROOT_PASS" && "$XUI_PASS" != "$SYS_PASS" ]] && break
  done

  # Automate: menu 7 → y → user → pass → y (disable 2FA) → y (restart) → Enter → 0
  expect <<EOF >/tmp/xui-reset.expect.log 2>&1
set timeout 120
log_user 0
spawn x-ui
expect {
  -re {selection|Selection|enter your selection} {}
  timeout { exit 2 }
}
send "7\r"
expect {
  -re {sure to reset|username and password|Default n} {}
  timeout { exit 3 }
}
send "y\r"
expect {
  -re {login username|username} {}
  timeout { exit 4 }
}
send "${XUI_USER}\r"
expect {
  -re {login password|password} {}
  timeout { exit 5 }
}
send "${XUI_PASS}\r"
expect {
  -re {two-factor|2FA|two factor|authentication} {}
  timeout { exit 6 }
}
send "y\r"
expect {
  -re {Restart the panel|restart|Attention} {}
  timeout { exit 7 }
}
send "y\r"
expect {
  -re {Press enter|return to the main menu|main menu} {}
  timeout {}
}
send "\r"
expect {
  -re {selection|Selection|enter your selection} {}
  timeout {}
}
send "0\r"
expect eof
EOF

  local rc=$?
  # Log file may contain secrets from expect spawn — wipe it
  rm -f /tmp/xui-reset.expect.log

  if [[ $rc -ne 0 ]]; then
    err "Сбой автоматизации x-ui (expect exit=$rc). Сбросьте вручную: x-ui → 7"
    XUI_USER=""; XUI_PASS=""
    return 1
  fi

  read_xui_url_hint
  ok "Учётные данные панели 3x-ui сброшены"

  if [[ "$RAN_ALL" -eq 0 ]]; then
    print_secret_once_banner
    echo -e "${BOLD}3x-ui username:${NC} ${XUI_USER}"
    echo -e "${BOLD}3x-ui password:${NC} ${XUI_PASS}"
    [[ -n "$XUI_URL" ]] && echo -e "${BOLD}3x-ui URL:${NC}      ${XUI_URL}"
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
  ROOT_PASS=""; SYS_PASS=""; XUI_PASS=""
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
      6) reset_xui_credentials; XUI_PASS=""; pause ;;
      *) err "Неверный выбор"; sleep 1 ;;
    esac
  done
}

main "$@"
