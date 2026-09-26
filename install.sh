#!/usr/bin/env bash
set -Eeuo pipefail

# RemnaNode Manager — монолитный скрипт установки и администрирования Remnawave Node.
#
# Запуск без установки:
#   bash <(curl -Ls https://raw.githubusercontent.com/OverlayNode/Remnanode-manager/main/install.sh)
#
# Возможности:
# - RemnaNode (Docker) без Selfsteal, с Selfsteal, Selfsteal для уже установленной Node
# - управление версией Node: обновление, выбор тега, откат по digest
# - сайты-заглушки из каталога шаблонов с уникальным отпечатком при каждом деплое
# - Reality (RAW / XHTTP), Hysteria2, SSL через acme.sh
# - routing: roscomvpn geosite/geoip, RU/whitelist, блокировка торрентов
# - модули: WARP, Psiphon, Tor, Zapret2
# - мониторинг и администрирование сервера
# - Remnawave Panel API: обновление Config Profile с diff и backup
#
# Запускать от root. Поддерживаются Ubuntu и Debian.

SCRIPT_VERSION="4.2.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || pwd)"
APT_LOCK_TIMEOUT="${APT_LOCK_TIMEOUT:-600}"

RNM_REPO="${RNM_REPO:-OverlayNode/Remnanode-manager}"
RNM_REF="${RNM_REF:-main}"
RNM_RAW_URL="https://raw.githubusercontent.com/${RNM_REPO}/${RNM_REF}"
RNM_COMMAND_PATH="/usr/local/bin/remnanode"
RNM_LIB_DIR="/usr/local/lib/remnanode/modules"
# shellcheck disable=SC2034 # используется модулем admin и тестами
RNM_MODULES="sites routing panel warp psiphon tor zapret monitor admin"

NODE_IMAGE_REPO="remnawave/node"
REMNAWAVE_IMAGE="${REMNAWAVE_IMAGE:-${NODE_IMAGE_REPO}:latest}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:alpine}"

BASE_DIR="/opt/remnanode"
STATE_FILE="${BASE_DIR}/installer.conf"
REALITY_FILE="${BASE_DIR}/reality.env"
PANEL_ENV_FILE="${BASE_DIR}/panel.env"
UFW_STATE_FILE="${BASE_DIR}/ufw.rules"
NODE_COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
PROFILE_DIR="${BASE_DIR}/profiles"
PROFILE_FILE="${PROFILE_DIR}/xray-profile.json"
PROFILE_INFO="${PROFILE_DIR}/profile-info.txt"
CLIENT_ROUTING_FILE="${PROFILE_DIR}/client-routing-happ.json"
CLIENT_RULES_FILE="${PROFILE_DIR}/client-routing-xray-rules.json"
CLIENT_DNS_FILE="${PROFILE_DIR}/client-dns-xray.json"
CLIENT_APPS_FILE="${PROFILE_DIR}/client-ru-apps.txt"
GEO_DIR="${BASE_DIR}/geo"
ROUTING_DIR="${BASE_DIR}/routing"
BACKUP_DIR="${BASE_DIR}/backups"
# shellcheck disable=SC2034 # используется модулем sites
CACHE_DIR="${BASE_DIR}/.cache"
RUNTIME_CACHE="/run/remnanode-manager"

GEO_UPDATER="/usr/local/sbin/remnanode-geo-update"
GEO_SITE_FILE="roscom-geosite.dat"
GEO_IP_FILE="roscom-geoip.dat"
GEO_SITE_URL="${GEO_SITE_URL:-https://github.com/hydraponique/roscomvpn-geosite/releases/latest/download/geosite.dat}"
GEO_IP_URL="${GEO_IP_URL:-https://github.com/hydraponique/roscomvpn-geoip/releases/latest/download/geoip.dat}"
XRAY_ASSET_DIR="/usr/local/share/xray"

WARP_INSTALL_URL="${WARP_INSTALL_URL:-https://raw.githubusercontent.com/Chara-Freedom/vps-warp/main/warp_install.sh}"
PSIPHON_INSTALL_URL="${PSIPHON_INSTALL_URL:-https://raw.githubusercontent.com/Chara-Freedom/vps-psiphon/main/psiphon_install.sh}"

NODE_PORT="2222"
NODE_SERVICE_NAME="remnanode"
ADDED_SHM_VOLUME="0"
ADDED_SSL_VOLUME="0"
ADDED_NGINX_DEPENDENCY="0"
ACME_HOME="/root/.acme.sh"
ACME_BIN="${ACME_HOME}/acme.sh"
RELOAD_HELPER="/usr/local/sbin/reload-nginx-selfsteal"
INSTALL_LOG="/var/log/remnanode-manager.log"

C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'
C_GRAY='\033[0;90m'
C_BOLD='\033[1m'

# Значения по умолчанию. Файл состояния переопределяет их, если существует.
INSTALL_MODE=""
DOMAIN=""
SERVICE_NAME=""
ACME_EMAIL=""
PANEL_IP=""
SECRET_KEY=""

NODE_IMAGE="$REMNAWAVE_IMAGE"
NODE_PREV_IMAGE=""
SITE_TEMPLATE=""

RAW_ENABLED="0"
RAW_PORT="443"

XHTTP_ENABLED="0"
XHTTP_PORT="8443"
XHTTP_MODE="stream-one"
XHTTP_PATH=""

HY2_ENABLED="0"
HY2_PORT="443"
HY2_OBFS_PASSWORD=""     # Salamander: пусто = обфускация выключена

# Routing.
GEO_ENABLED="0"
RU_POLICY="block"        # block | direct | warp
BLOCK_ADS="0"
WARP_OUTBOUND="0"
PSIPHON_OUTBOUND="0"
PSIPHON_ADDR="127.0.0.1"
PSIPHON_PORT="1080"
TOR_OUTBOUND="0"
# DNS: РФ-домены — через РФ-резолверы, остальное — через зарубежный DoH.
DNS_RU="77.88.8.8,77.88.8.1"
DNS_FOREIGN="https://1.1.1.1/dns-query,https://8.8.8.8/dns-query"
DNS_HIJACK="1"           # перехват клиентского DNS (порт 53) внутри туннеля
PANEL_PROFILE_UUID=""

REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
RAW_SHORT_ID=""
XHTTP_SHORT_ID=""
RAW_SHORT_IDS_JSON=""
XHTTP_SHORT_IDS_JSON=""

log() {
  printf '%b\n' "$*" | tee -a "$INSTALL_LOG" 2>/dev/null || printf '%b\n' "$*"
}

info() { log "${C_BLUE}[INFO]${C_RESET} $*"; }
ok()   { log "${C_GREEN}[OK]${C_RESET} $*"; }
warn() { log "${C_YELLOW}[WARN]${C_RESET} $*"; }
err()  { log "${C_RED}[ERROR]${C_RESET} $*"; }
die()  { err "$*"; exit 1; }

trap 'err "Ошибка на строке ${LINENO}. Журнал: ${INSTALL_LOG}"' ERR

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Запусти скрипт от root."
}

detect_os() {
  [[ -r /etc/os-release ]] || die "Не найден /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release

  case "${ID:-}" in
    ubuntu|debian) ;;
    *) die "Поддерживаются Ubuntu и Debian. Обнаружено: ${ID:-unknown}" ;;
  esac

  OS_ID="$ID"
  OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
  [[ -n "$OS_CODENAME" ]] || die "Не удалось определить codename ОС."
}

pause() {
  echo
  read -r -p "Нажми Enter для продолжения..." _ || true
}

confirm() {
  local prompt="${1:-Продолжить?}"
  local answer
  read -r -p "$prompt [Y/n]: " answer || return 1
  case "${answer:-Y}" in
    Y|y|YES|yes|Yes|Д|д) return 0 ;;
    *) return 1 ;;
  esac
}

confirm_no_default() {
  local prompt="${1:-Продолжить?}"
  local answer
  read -r -p "$prompt [y/N]: " answer || return 1
  case "${answer:-N}" in
    Y|y|YES|yes|Yes|Д|д) return 0 ;;
    *) return 1 ;;
  esac
}

# Запускает действие меню в subshell: die внутри действия возвращает в меню,
# а не завершает весь скрипт.
run_action() {
  local status=0
  ( "$@" ) || status=$?
  if ((status != 0)); then
    warn "Действие завершилось с ошибкой (код ${status}). Подробности: ${INSTALL_LOG}"
  fi
  return 0
}

is_selfsteal_mode() {
  [[ "$INSTALL_MODE" == "selfsteal" || "$INSTALL_MODE" == "selfsteal-existing" ]]
}

validate_domain() {
  local value="$1"
  [[ "$value" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

validate_email() {
  local value="$1"
  [[ "$value" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

validate_port() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 ))
}

validate_panel_network() {
  local value="$1"

  [[ -z "$value" ]] && return 0

  if [[ "$value" == *.* ]]; then
    local address="${value%/*}"
    local prefix="32"
    [[ "$value" == */* ]] && prefix="${value##*/}"
    [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    [[ "$prefix" =~ ^[0-9]+$ ]] && ((prefix >= 0 && prefix <= 32)) || return 1

    local octet
    local -a octets=()
    IFS=. read -r -a octets <<< "$address"
    for octet in "${octets[@]}"; do
      ((10#$octet >= 0 && 10#$octet <= 255)) || return 1
    done
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    local status
    if python3 - "$value" 2>/dev/null <<'PY'
import ipaddress
import sys

try:
    ipaddress.ip_network(sys.argv[1], strict=False)
except ValueError:
    raise SystemExit(1)
PY
    then
      return 0
    else
      status=$?
      # Код 1 — адрес некорректен. Любой другой код значит, что python3
      # не смог выполниться (126/127, заглушки и т. п.) — используем fallback.
      ((status != 1)) || return 1
    fi
  fi

  # Консервативный fallback для минимальных систем до установки python3.
  local prefix="128"
  local address="${value%/*}"
  [[ "$value" == */* ]] && prefix="${value##*/}"
  [[ "$address" == *:* && "$address" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
  [[ "$prefix" =~ ^[0-9]+$ ]] && ((prefix >= 0 && prefix <= 128))
}

validate_service_name() {
  local value="$1"
  # Намеренно строго: значение пишется в HTML и в sed-подстановки.
  [[ "$value" =~ ^[[:alnum:]][[:alnum:]\ ._-]{0,79}$ ]]
}

validate_xhttp_path() {
  local value="$1"
  [[ "$value" =~ ^/[A-Za-z0-9._~:/@%+,-]{1,180}$ ]]
}

# DNS-сервер Xray: IP, https://…/dns-query (DoH), tcp://IP[:порт] или localhost.
validate_dns_server() {
  local value="$1"
  [[ "$value" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && return 0
  [[ "$value" =~ ^[0-9A-Fa-f]*:[0-9A-Fa-f:]+$ ]] && return 0
  [[ "$value" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]] && return 0
  [[ "$value" =~ ^tcp://[0-9A-Za-z.:-]+$ ]] && return 0
  [[ "$value" == "localhost" ]]
}

validate_dns_list() {
  local list="$1" item
  [[ -n "$list" ]] || return 1
  local -a items=()
  IFS=, read -r -a items <<<"$list"
  ((${#items[@]} > 0)) || return 1
  for item in "${items[@]}"; do
    validate_dns_server "$item" || return 1
  done
}

validate_image_tag() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]
}

validate_image_ref() {
  local value="$1"
  [[ "$value" =~ ^[a-z0-9./_-]+(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}|@sha256:[0-9a-f]{64})$ ]]
}

backup_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S-%N)"
    cp -a "$file" "${file}.backup-${stamp}"
    info "Backup: ${file}.backup-${stamp}"
  fi
}

shell_quote() {
  printf '%q' "$1"
}

save_state() {
  local old_umask tmp_file
  old_umask="$(umask)"
  mkdir -p "$BASE_DIR"
  umask 077
  tmp_file="$(mktemp "${STATE_FILE}.tmp.XXXXXX")"
  {
    printf 'INSTALLED_CONFIG_VERSION=%q\n' "$SCRIPT_VERSION"
    printf 'INSTALL_MODE=%q\n' "$INSTALL_MODE"
    printf 'DOMAIN=%q\n' "$DOMAIN"
    printf 'SERVICE_NAME=%q\n' "$SERVICE_NAME"
    printf 'ACME_EMAIL=%q\n' "$ACME_EMAIL"
    printf 'PANEL_IP=%q\n' "$PANEL_IP"
    printf 'NODE_PORT=%q\n' "$NODE_PORT"
    printf 'NODE_COMPOSE_FILE=%q\n' "$NODE_COMPOSE_FILE"
    printf 'NODE_SERVICE_NAME=%q\n' "$NODE_SERVICE_NAME"
    printf 'ADDED_SHM_VOLUME=%q\n' "$ADDED_SHM_VOLUME"
    printf 'ADDED_SSL_VOLUME=%q\n' "$ADDED_SSL_VOLUME"
    printf 'ADDED_NGINX_DEPENDENCY=%q\n' "$ADDED_NGINX_DEPENDENCY"

    printf 'NODE_IMAGE=%q\n' "$NODE_IMAGE"
    printf 'NODE_PREV_IMAGE=%q\n' "$NODE_PREV_IMAGE"
    printf 'SITE_TEMPLATE=%q\n' "$SITE_TEMPLATE"

    printf 'RAW_ENABLED=%q\n' "$RAW_ENABLED"
    printf 'RAW_PORT=%q\n' "$RAW_PORT"

    printf 'XHTTP_ENABLED=%q\n' "$XHTTP_ENABLED"
    printf 'XHTTP_PORT=%q\n' "$XHTTP_PORT"
    printf 'XHTTP_MODE=%q\n' "$XHTTP_MODE"
    printf 'XHTTP_PATH=%q\n' "$XHTTP_PATH"

    printf 'HY2_ENABLED=%q\n' "$HY2_ENABLED"
    printf 'HY2_PORT=%q\n' "$HY2_PORT"
    printf 'HY2_OBFS_PASSWORD=%q\n' "$HY2_OBFS_PASSWORD"

    printf 'GEO_ENABLED=%q\n' "$GEO_ENABLED"
    printf 'RU_POLICY=%q\n' "$RU_POLICY"
    printf 'BLOCK_ADS=%q\n' "$BLOCK_ADS"
    printf 'WARP_OUTBOUND=%q\n' "$WARP_OUTBOUND"
    printf 'PSIPHON_OUTBOUND=%q\n' "$PSIPHON_OUTBOUND"
    printf 'PSIPHON_ADDR=%q\n' "$PSIPHON_ADDR"
    printf 'PSIPHON_PORT=%q\n' "$PSIPHON_PORT"
    printf 'TOR_OUTBOUND=%q\n' "$TOR_OUTBOUND"
    printf 'DNS_RU=%q\n' "$DNS_RU"
    printf 'DNS_FOREIGN=%q\n' "$DNS_FOREIGN"
    printf 'DNS_HIJACK=%q\n' "$DNS_HIJACK"
    printf 'PANEL_PROFILE_UUID=%q\n' "$PANEL_PROFILE_UUID"
  } > "$tmp_file"

  chmod 600 "$tmp_file"
  mv -f "$tmp_file" "$STATE_FILE"
  umask "$old_umask"
}

load_state() {
  local running_version="$SCRIPT_VERSION"
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
  # Старые файлы состояния хранили SCRIPT_VERSION. Версия запущенного скрипта важнее.
  SCRIPT_VERSION="$running_version"
  [[ -n "${NODE_IMAGE:-}" ]] || NODE_IMAGE="$REMNAWAVE_IMAGE"
}

save_reality() {
  local old_umask tmp_file
  old_umask="$(umask)"
  umask 077
  tmp_file="$(mktemp "${REALITY_FILE}.tmp.XXXXXX")"
  {
    printf 'REALITY_PRIVATE_KEY=%q\n' "$REALITY_PRIVATE_KEY"
    printf 'REALITY_PUBLIC_KEY=%q\n' "$REALITY_PUBLIC_KEY"
    printf 'RAW_SHORT_ID=%q\n' "$RAW_SHORT_ID"
    printf 'XHTTP_SHORT_ID=%q\n' "$XHTTP_SHORT_ID"
    printf 'RAW_SHORT_IDS_JSON=%q\n' "$RAW_SHORT_IDS_JSON"
    printf 'XHTTP_SHORT_IDS_JSON=%q\n' "$XHTTP_SHORT_IDS_JSON"
  } > "$tmp_file"
  chmod 600 "$tmp_file"
  mv -f "$tmp_file" "$REALITY_FILE"
  umask "$old_umask"
}

load_reality() {
  if [[ -f "$REALITY_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$REALITY_FILE"
  fi
}

ensure_base_dirs() {
  mkdir -p \
    "$BASE_DIR" \
    "${BASE_DIR}/ssl" \
    "${BASE_DIR}/html" \
    "$PROFILE_DIR" \
    "$BACKUP_DIR"

  chmod 755 "$BASE_DIR" "${BASE_DIR}/html" "$PROFILE_DIR"
  chmod 700 "${BASE_DIR}/ssl" "$BACKUP_DIR"
}

apt_lock_is_held() {
  command -v fuser >/dev/null 2>&1 || return 1
  fuser \
    /var/lib/dpkg/lock-frontend \
    /var/lib/dpkg/lock \
    /var/cache/apt/archives/lock \
    /var/lib/apt/lists/lock >/dev/null 2>&1
}

apt_get_wait() {
  [[ "$APT_LOCK_TIMEOUT" =~ ^[0-9]+$ ]] || die "APT_LOCK_TIMEOUT должен быть числом секунд."
  if apt_lock_is_held; then
    info "APT/dpkg занят другим процессом (например, unattended-upgrades). Жду до ${APT_LOCK_TIMEOUT} секунд..."
  fi
  apt-get -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT}" "$@"
}

install_base_packages() {
  info "Устанавливаю базовые пакеты..."
  export DEBIAN_FRONTEND=noninteractive

  apt_get_wait update -y
  apt_get_wait install -y \
    ca-certificates \
    curl \
    gnupg \
    openssl \
    dnsutils \
    ufw \
    cron \
    iproute2 \
    jq \
    tmux \
    psmisc \
    python3-minimal \
    python3-yaml

  systemctl enable --now cron >/dev/null 2>&1 || true
  ok "Базовые пакеты установлены."
}

# Мягкая версия: доустанавливает только отсутствующие утилиты для меню и мониторинга.
ensure_runtime_tools() {
  local -a missing=()
  command -v jq >/dev/null 2>&1 || missing+=(jq)
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v openssl >/dev/null 2>&1 || missing+=(openssl)
  command -v ss >/dev/null 2>&1 || missing+=(iproute2)
  ((${#missing[@]} == 0)) && return 0
  info "Доустанавливаю: ${missing[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt_get_wait update -y >/dev/null
  apt_get_wait install -y "${missing[@]}" >/dev/null
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker и Docker Compose уже установлены."
    systemctl enable --now docker >/dev/null 2>&1 || true
    return
  fi

  info "Устанавливаю Docker Engine из официального Docker repository..."

  install -m 0755 -d /etc/apt/keyrings

  curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" \
    -o /etc/apt/keyrings/docker.asc

  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/${OS_ID}
Suites: ${OS_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  chmod a+r /etc/apt/keyrings/docker.asc

  apt_get_wait update -y
  apt_get_wait install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  systemctl enable --now docker
  docker compose version >/dev/null
  ok "Docker установлен."
}

secure_random_int() {
  local minimum="$1" maximum="$2" value span
  value=$((16#$(openssl rand -hex 4)))
  span=$((maximum - minimum + 1))
  printf '%d' "$((minimum + value % span))"
}

random_hex() {
  openssl rand -hex "${1:-4}"
}

# Выбирает случайный элемент из аргументов.
random_pick() {
  local -a items=("$@")
  local index
  index="$(secure_random_int 0 $((${#items[@]} - 1)))"
  printf '%s' "${items[$index]}"
}

human_bytes() {
  local bytes="${1:-0}"
  awk -v b="$bytes" 'BEGIN {
    split("B KB MB GB TB PB", u, " "); i = 1;
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    if (i <= 3) printf "%d %s", b + 0.5, u[i]; else printf "%.1f %s", b, u[i]
  }' | sed -E 's/\.0 / /'
}

# ---------------------------------------------------------------------------
# Firewall и порты
# ---------------------------------------------------------------------------

prompt_secret_and_panel() {
  echo
  read -r -s -p "SECRET_KEY из Remnawave Panel: " SECRET_KEY
  echo
  [[ -n "$SECRET_KEY" ]] || die "SECRET_KEY не может быть пустым."

  [[ "$SECRET_KEY" =~ ^[A-Za-z0-9._=-]+$ ]] \
    || die "SECRET_KEY содержит неподдерживаемые символы."

  local port_input
  read -r -p "NODE_PORT (порт API ноды для панели) [${NODE_PORT}]: " port_input
  NODE_PORT="${port_input:-$NODE_PORT}"
  validate_port "$NODE_PORT" || die "Некорректный NODE_PORT: ${NODE_PORT}"

  prompt_panel_network
}

prompt_panel_network() {
  read -r -p "IP/CIDR сервера панели для ${NODE_PORT}/tcp (Enter = открыть всем): " PANEL_IP

  validate_panel_network "$PANEL_IP" || die "Некорректный IP или CIDR сервера панели: ${PANEL_IP}"

  if [[ -z "$PANEL_IP" ]]; then
    warn "${NODE_PORT}/tcp будет открыт для всего интернета."
  fi
}

detect_ssh_port() {
  local ssh_port="22"

  if command -v sshd >/dev/null 2>&1; then
    local detected
    detected="$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' || true)"
    if [[ "$detected" =~ ^[0-9]+$ ]]; then
      ssh_port="$detected"
    fi
  fi

  printf '%s' "$ssh_port"
}

remove_managed_ufw_rules() {
  local -a rule_numbers=()
  mapfile -t rule_numbers < <(
    ufw status numbered 2>/dev/null \
      | awk '/remnanode-manager/ {number=$1; gsub(/[^0-9]/, "", number); if (number != "") print number}' \
      | sort -rn
  )

  local number
  for number in "${rule_numbers[@]}"; do
    ufw --force delete "$number" >/dev/null 2>&1 || true
  done

  rm -f "$UFW_STATE_FILE"
}

apply_managed_ufw_rule() {
  local rule="$1"
  local -a args=()
  read -r -a args <<< "$rule"
  ufw "${args[@]}" comment remnanode-manager >/dev/null
}

save_managed_ufw_rules() {
  local tmp_file
  tmp_file="$(mktemp "${UFW_STATE_FILE}.tmp.XXXXXX")"
  printf '%s\n' "$@" > "$tmp_file"
  chmod 600 "$tmp_file"
  mv -f "$tmp_file" "$UFW_STATE_FILE"
}

configure_firewall() {
  local mode="$1"
  local ssh_port
  local -a managed_rules=()
  local -a previous_rules=()
  ssh_port="$(detect_ssh_port)"

  if [[ -f "$UFW_STATE_FILE" ]]; then
    mapfile -t previous_rules < "$UFW_STATE_FILE"
  fi

  info "Настройка UFW."

  if confirm_no_default "Сбросить существующие правила UFW и оставить правила этой ноды?"; then
    ufw --force reset >/dev/null
  else
    warn "Существующие правила UFW будут сохранены."
    remove_managed_ufw_rules
  fi

  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null

  # OpenSSH/22 остаётся доступным всегда, текущий порт sshd — тоже.
  ufw allow 22/tcp >/dev/null

  if [[ "$ssh_port" != "22" ]]; then
    ufw allow "${ssh_port}/tcp" >/dev/null
    warn "sshd также слушает ${ssh_port}/tcp — порт сохранён."
  fi

  if [[ -n "$PANEL_IP" ]]; then
    managed_rules+=("allow from ${PANEL_IP} to any port ${NODE_PORT} proto tcp")
  else
    managed_rules+=("allow ${NODE_PORT}/tcp")
  fi

  if [[ "$mode" != "basic" ]]; then
    # HTTP-01 для выпуска и renew acme.sh.
    managed_rules+=("allow 80/tcp")

    if [[ "$RAW_ENABLED" == "1" ]]; then
      managed_rules+=("allow ${RAW_PORT}/tcp")
    fi

    if [[ "$XHTTP_ENABLED" == "1" ]]; then
      managed_rules+=("allow ${XHTTP_PORT}/tcp")
    fi

    if [[ "$HY2_ENABLED" == "1" ]]; then
      managed_rules+=("allow ${HY2_PORT}/udp")
    fi
  fi

  local rule
  for rule in "${managed_rules[@]}"; do
    if ! apply_managed_ufw_rule "$rule"; then
      err "Не удалось добавить правило UFW: ${rule}"
      remove_managed_ufw_rules
      local previous_rule
      for previous_rule in "${previous_rules[@]}"; do
        [[ -n "$previous_rule" ]] && apply_managed_ufw_rule "$previous_rule" || true
      done
      ((${#previous_rules[@]} == 0)) || save_managed_ufw_rules "${previous_rules[@]}"
      die "Новые правила UFW не применены; выполнена попытка восстановить предыдущие."
    fi
  done
  save_managed_ufw_rules "${managed_rules[@]}"

  ufw --force enable >/dev/null
  ufw reload >/dev/null

  ok "UFW настроен."
  ufw status verbose
}

validate_selected_port_plan() {
  local ssh_port
  ssh_port="$(detect_ssh_port)"

  local -A reserved_tcp=(
    ["$NODE_PORT"]="RemnaNode API"
    ["$ssh_port"]="SSH"
    ["80"]="ACME HTTP-01"
  )

  if [[ "$RAW_ENABLED" == "1" ]]; then
    [[ -z "${reserved_tcp[$RAW_PORT]:-}" ]] \
      || die "TCP ${RAW_PORT} уже зарезервирован для ${reserved_tcp[$RAW_PORT]}."
    reserved_tcp["$RAW_PORT"]="VLESS RAW"
  fi

  if [[ "$XHTTP_ENABLED" == "1" ]]; then
    [[ -z "${reserved_tcp[$XHTTP_PORT]:-}" ]] \
      || die "TCP ${XHTTP_PORT} уже зарезервирован для ${reserved_tcp[$XHTTP_PORT]}."
    reserved_tcp["$XHTTP_PORT"]="VLESS XHTTP"
  fi
}

ensure_selected_ports_free() {
  local port
  local -a tcp_ports=("$NODE_PORT")

  [[ "$RAW_ENABLED" == "1" ]] && tcp_ports+=("$RAW_PORT")
  [[ "$XHTTP_ENABLED" == "1" ]] && tcp_ports+=("$XHTTP_PORT")

  for port in "${tcp_ports[@]}"; do
    if ss -H -lnt "( sport = :${port} )" 2>/dev/null | grep -q .; then
      die "TCP ${port} уже занят. Освободи порт перед установкой."
    fi
  done

  if [[ "$HY2_ENABLED" == "1" ]] \
    && ss -H -lnu "( sport = :${HY2_PORT} )" 2>/dev/null | grep -q .; then
    die "UDP ${HY2_PORT} уже занят. Освободи порт перед установкой."
  fi
}

ensure_fresh_install_target() {
  if [[ -f "$NODE_COMPOSE_FILE" ]]; then
    die "В ${BASE_DIR} уже есть установка. Используй обновление или сначала удали существующую ноду."
  fi
}

# ---------------------------------------------------------------------------
# Docker Compose
# ---------------------------------------------------------------------------

write_basic_compose() {
  local compose_file="$NODE_COMPOSE_FILE"
  local tmp_file
  tmp_file="$(mktemp "${compose_file}.tmp.XXXXXX")"

  cat > "$tmp_file" <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: ${NODE_IMAGE}
    network_mode: host
    restart: always

    cap_add:
      - NET_ADMIN

    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576

    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "3"

    volumes:
      - /dev/shm:/dev/shm:rw

    environment:
      NODE_PORT: '${NODE_PORT}'
      SECRET_KEY: '${SECRET_KEY}'
EOF

  docker compose -f "$tmp_file" config >/dev/null
  backup_file "$compose_file"
  mv -f "$tmp_file" "$compose_file"
  chmod 600 "$compose_file"
}

write_selfsteal_compose() {
  local compose_file="$NODE_COMPOSE_FILE"
  local tmp_file
  tmp_file="$(mktemp "${compose_file}.tmp.XXXXXX")"

  cat > "$tmp_file" <<EOF
services:
  nginx-selfsteal:
    container_name: nginx-selfsteal
    hostname: nginx-selfsteal
    image: ${NGINX_IMAGE}
    restart: always

    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "3"

    volumes:
      - /dev/shm:/dev/shm:rw
      - /opt/remnanode/ssl:/etc/nginx/ssl:ro
      - /opt/remnanode/nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /opt/remnanode/html:/var/www/html:ro

    command: >
      /bin/sh -c "
      rm -f /dev/shm/nginx.sock &&
      exec nginx -g 'daemon off;'
      "

    healthcheck:
      test: ["CMD-SHELL", "test -S /dev/shm/nginx.sock || exit 1"]
      interval: 5s
      timeout: 3s
      retries: 12
      start_period: 3s

  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: ${NODE_IMAGE}
    network_mode: host
    restart: always

    depends_on:
      nginx-selfsteal:
        condition: service_healthy

    cap_add:
      - NET_ADMIN

    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576

    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "3"

    volumes:
      - /dev/shm:/dev/shm:rw
      # Сертификат ноды для Xray/Hysteria2.
      - /opt/remnanode/ssl:/opt/remnanode/ssl:ro

    environment:
      NODE_PORT: '${NODE_PORT}'
      SECRET_KEY: '${SECRET_KEY}'
EOF

  docker compose -f "$tmp_file" config >/dev/null
  backup_file "$compose_file"
  mv -f "$tmp_file" "$compose_file"
  chmod 600 "$compose_file"
}

detect_existing_compose() {
  docker inspect remnanode >/dev/null 2>&1 \
    || die "Контейнер remnanode не найден. Для этого режима Node должна быть уже запущена."

  local detected_file detected_service
  detected_file="$(docker inspect remnanode \
    --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' 2>/dev/null || true)"
  detected_service="$(docker inspect remnanode \
    --format '{{ index .Config.Labels "com.docker.compose.service" }}' 2>/dev/null || true)"

  detected_file="${detected_file%%,*}"
  [[ "$detected_file" == "<no value>" ]] && detected_file=""
  [[ "$detected_service" == "<no value>" ]] && detected_service=""

  if [[ -z "$detected_file" && -f "$NODE_COMPOSE_FILE" ]]; then
    detected_file="$NODE_COMPOSE_FILE"
  fi

  local compose_input
  read -r -p "Путь к docker-compose.yml существующей Node${detected_file:+ [${detected_file}]}: " compose_input
  NODE_COMPOSE_FILE="${compose_input:-$detected_file}"
  [[ -f "$NODE_COMPOSE_FILE" ]] || die "Compose-файл существующей Node не найден: ${NODE_COMPOSE_FILE:-не указан}"

  NODE_SERVICE_NAME="${detected_service:-remnanode}"
  [[ "$NODE_SERVICE_NAME" =~ ^[a-zA-Z0-9._-]+$ ]] \
    || die "Некорректное имя Compose-сервиса Node: ${NODE_SERVICE_NAME}"

  docker compose -f "$NODE_COMPOSE_FILE" config --services \
    | grep -Fxq "$NODE_SERVICE_NAME" \
    || die "Сервис ${NODE_SERVICE_NAME} отсутствует в ${NODE_COMPOSE_FILE}."

  local existing_node_port
  existing_node_port="$(docker inspect remnanode --format '{{range .Config.Env}}{{println .}}{{end}}' \
    | awk -F= '$1 == "NODE_PORT" {print $2; exit}')"
  if [[ -n "$existing_node_port" ]]; then
    validate_port "$existing_node_port" || die "У существующей Node некорректный NODE_PORT: ${existing_node_port}"
    NODE_PORT="$existing_node_port"
  fi

  NODE_IMAGE="$(compose_node_image 2>/dev/null || printf '%s' "$REMNAWAVE_IMAGE")"
}

# Безопасное редактирование Compose через PyYAML.
# Действия: selfsteal-add, selfsteal-remove, geo-add, geo-remove, set-image.
compose_edit() {
  local action="$1"
  local argument="${2:-}"
  local tmp_file metadata
  command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null \
    || die "Нужны python3 и python3-yaml (apt install python3-yaml)."

  tmp_file="$(mktemp "${NODE_COMPOSE_FILE}.tmp.XXXXXX")"

  if ! metadata="$(python3 - \
    "$NODE_COMPOSE_FILE" \
    "$tmp_file" \
    "$action" \
    "$NODE_SERVICE_NAME" \
    "$NGINX_IMAGE" \
    "$ADDED_SHM_VOLUME" \
    "$ADDED_SSL_VOLUME" \
    "$ADDED_NGINX_DEPENDENCY" \
    "$argument" \
    "$XRAY_ASSET_DIR" \
    "$GEO_SITE_FILE" \
    "$GEO_IP_FILE" <<'PY'
import sys

import yaml

(source, output, action, node_name, nginx_image,
 remove_shm, remove_ssl, remove_dependency, argument,
 asset_dir, geo_site, geo_ip) = sys.argv[1:13]

with open(source, "r", encoding="utf-8") as stream:
    document = yaml.safe_load(stream) or {}

services = document.get("services")
if not isinstance(services, dict):
    raise SystemExit("Compose-файл не содержит корректную секцию services.")

node = services.get(node_name)
if not isinstance(node, dict):
    raise SystemExit(f"Compose-сервис {node_name} не найден.")

def volume_parts(entry):
    if isinstance(entry, str):
        parts = entry.split(":", 2)
        if len(parts) >= 2:
            return parts[0], parts[1]
    elif isinstance(entry, dict):
        return entry.get("source"), entry.get("target")
    return None, None

def ensure_volume(volumes, source_path, target_path, read_only=False):
    for entry in volumes:
        current_source, current_target = volume_parts(entry)
        if current_target == target_path:
            if current_source != source_path:
                raise SystemExit(
                    f"Mount target {target_path} уже использует другой source: {current_source}"
                )
            return False

    volume = {
        "type": "bind",
        "source": source_path,
        "target": target_path,
    }
    if read_only:
        volume["read_only"] = True
    volumes.append(volume)
    return True

def remove_volume(volumes, source_path, target_path):
    result = []
    for entry in volumes:
        current_source, current_target = volume_parts(entry)
        if current_source == source_path and current_target == target_path:
            continue
        result.append(entry)
    return result

def node_volumes():
    volumes = node.setdefault("volumes", [])
    if not isinstance(volumes, list):
        raise SystemExit("Секция volumes сервиса Node должна быть списком.")
    return volumes

result = ""

if action == "selfsteal-add":
    if "nginx-selfsteal" in services:
        raise SystemExit("Сервис nginx-selfsteal уже существует в Compose-файле.")

    volumes = node_volumes()
    added_shm = ensure_volume(volumes, "/dev/shm", "/dev/shm")
    added_ssl = ensure_volume(
        volumes, "/opt/remnanode/ssl", "/opt/remnanode/ssl", read_only=True
    )

    depends_on = node.get("depends_on")
    if depends_on is None:
        depends_on = {}
    elif isinstance(depends_on, list):
        depends_on = {name: {"condition": "service_started"} for name in depends_on}
    elif not isinstance(depends_on, dict):
        raise SystemExit("Секция depends_on сервиса Node имеет неподдерживаемый формат.")

    added_dependency = "nginx-selfsteal" not in depends_on
    depends_on["nginx-selfsteal"] = {"condition": "service_healthy"}
    node["depends_on"] = depends_on

    services["nginx-selfsteal"] = {
        "container_name": "nginx-selfsteal",
        "hostname": "nginx-selfsteal",
        "image": nginx_image,
        "restart": "always",
        "logging": {
            "driver": "json-file",
            "options": {"max-size": "20m", "max-file": "3"},
        },
        "volumes": [
            {"type": "bind", "source": "/dev/shm", "target": "/dev/shm"},
            {
                "type": "bind",
                "source": "/opt/remnanode/ssl",
                "target": "/etc/nginx/ssl",
                "read_only": True,
            },
            {
                "type": "bind",
                "source": "/opt/remnanode/nginx.conf",
                "target": "/etc/nginx/conf.d/default.conf",
                "read_only": True,
            },
            {
                "type": "bind",
                "source": "/opt/remnanode/html",
                "target": "/var/www/html",
                "read_only": True,
            },
        ],
        "command": "/bin/sh -c \"rm -f /dev/shm/nginx.sock && exec nginx -g 'daemon off;'\"",
        "healthcheck": {
            "test": ["CMD-SHELL", "test -S /dev/shm/nginx.sock || exit 1"],
            "interval": "5s",
            "timeout": "3s",
            "retries": 12,
            "start_period": "3s",
        },
    }
    result = f"{int(added_shm)} {int(added_ssl)} {int(added_dependency)}"

elif action == "selfsteal-remove":
    services.pop("nginx-selfsteal", None)

    if remove_dependency == "1":
        depends_on = node.get("depends_on")
        if isinstance(depends_on, dict):
            depends_on.pop("nginx-selfsteal", None)
            if depends_on:
                node["depends_on"] = depends_on
            else:
                node.pop("depends_on", None)
        elif isinstance(depends_on, list):
            node["depends_on"] = [name for name in depends_on if name != "nginx-selfsteal"]

    volumes = node.get("volumes")
    if isinstance(volumes, list):
        if remove_shm == "1":
            volumes = remove_volume(volumes, "/dev/shm", "/dev/shm")
        if remove_ssl == "1":
            volumes = remove_volume(
                volumes, "/opt/remnanode/ssl", "/opt/remnanode/ssl"
            )
        if volumes:
            node["volumes"] = volumes
        else:
            node.pop("volumes", None)

elif action in ("geo-add", "geo-remove"):
    geo_dir = argument
    pairs = [
        (f"{geo_dir}/{geo_site}", f"{asset_dir}/{geo_site}"),
        (f"{geo_dir}/{geo_ip}", f"{asset_dir}/{geo_ip}"),
    ]
    if action == "geo-add":
        volumes = node_volumes()
        for host_path, container_path in pairs:
            ensure_volume(volumes, host_path, container_path, read_only=True)
    else:
        volumes = node.get("volumes")
        if isinstance(volumes, list):
            for host_path, container_path in pairs:
                volumes = remove_volume(volumes, host_path, container_path)
            if volumes:
                node["volumes"] = volumes
            else:
                node.pop("volumes", None)

elif action == "set-image":
    if not argument:
        raise SystemExit("Не указан image.")
    node["image"] = argument

else:
    raise SystemExit(f"Неизвестное действие: {action}")

with open(output, "w", encoding="utf-8", newline="\n") as stream:
    yaml.safe_dump(document, stream, sort_keys=False, allow_unicode=True)

print(result)
PY
  )"; then
    rm -f "$tmp_file"
    die "Не удалось изменить Compose-файл (${action})."
  fi

  docker compose -f "$tmp_file" config >/dev/null \
    || {
      rm -f "$tmp_file"
      die "Изменённый Compose-файл не прошёл проверку Docker Compose."
    }

  chmod --reference="$NODE_COMPOSE_FILE" "$tmp_file"
  chown --reference="$NODE_COMPOSE_FILE" "$tmp_file"
  backup_file "$NODE_COMPOSE_FILE"
  mv -f "$tmp_file" "$NODE_COMPOSE_FILE"

  if [[ "$action" == "selfsteal-add" ]]; then
    read -r ADDED_SHM_VOLUME ADDED_SSL_VOLUME ADDED_NGINX_DEPENDENCY <<< "$metadata"
  fi
}

# Совместимость со старым именем функции.
update_existing_compose() {
  case "$1" in
    add) compose_edit selfsteal-add ;;
    remove) compose_edit selfsteal-remove ;;
    *) die "Неизвестное действие: $1" ;;
  esac
}

compose_node_image() {
  [[ -f "$NODE_COMPOSE_FILE" ]] || return 1
  docker compose -f "$NODE_COMPOSE_FILE" config --format json 2>/dev/null \
    | jq -r --arg service "$NODE_SERVICE_NAME" '.services[$service].image // empty'
}

manager_compose() {
  docker compose -f "$NODE_COMPOSE_FILE" "$@"
}

start_stack() {
  manager_compose config >/dev/null
  manager_compose pull
  manager_compose up -d --remove-orphans
}

verify_basic() {
  echo
  info "Проверка RemnaNode..."
  manager_compose ps

  local state=""
  for _ in {1..15}; do
    state="$(docker inspect remnanode --format '{{.State.Status}}' 2>/dev/null || true)"
    [[ "$state" == "running" ]] && break
    sleep 2
  done

  [[ "$state" == "running" ]] || die "Контейнер remnanode не перешёл в состояние running."
  ok "Контейнер remnanode запущен."

  local listening=0
  for _ in {1..10}; do
    if ss -H -lnt "( sport = :${NODE_PORT} )" 2>/dev/null | grep -q .; then
      listening=1
      break
    fi
    sleep 2
  done

  if ((listening)); then
    ok "Node API слушает TCP ${NODE_PORT}."
  else
    warn "TCP ${NODE_PORT} пока не виден. Проверь docker logs remnanode."
  fi
}

# ---------------------------------------------------------------------------
# Nginx Selfsteal
# ---------------------------------------------------------------------------

write_nginx_conf() {
  local domain="$1"
  local nginx_file="${BASE_DIR}/nginx.conf"
  local tmp_file
  tmp_file="$(mktemp "${nginx_file}.tmp.XXXXXX")"

  cat > "$tmp_file" <<EOF
server_names_hash_bucket_size 64;
server_tokens off;

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_session_timeout 1d;
ssl_session_cache shared:SelfStealSSL:10m;
ssl_session_tickets off;

server {
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    http2 on;

    server_name ${domain};

    ssl_certificate "/etc/nginx/ssl/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/fullchain.pem";

    root /var/www/html;
    index index.html;

    gzip on;
    gzip_types text/css application/javascript image/svg+xml application/json;

    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header X-Frame-Options "DENY" always;
    add_header Content-Security-Policy "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; form-action 'self'" always;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~* \.(css|js|svg|png|jpg|jpeg|webp|ico|woff2)$ {
        expires 7d;
        add_header Cache-Control "public, max-age=604800" always;
        add_header X-Content-Type-Options "nosniff" always;
        try_files \$uri =404;
    }

    location = /robots.txt {
        access_log off;
    }

    location = /health {
        default_type text/plain;
        return 200 "ok\\n";
    }

    error_page 404 /404.html;
}

server {
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol default_server;
    http2 on;

    server_name _;

    ssl_reject_handshake on;
    return 444;
}
EOF

  chmod 644 "$tmp_file"
  backup_file "$nginx_file"
  mv -f "$tmp_file" "$nginx_file"
}

verify_selfsteal_local() {
  docker inspect nginx-selfsteal >/dev/null 2>&1 || {
    warn "nginx-selfsteal не запущен."
    return 1
  }

  docker exec nginx-selfsteal nginx -t

  local health=""
  for _ in {1..12}; do
    health="$(docker inspect nginx-selfsteal --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')"
    [[ "$health" == "healthy" ]] && break
    sleep 2
  done
  [[ "$health" == "healthy" ]] || die "nginx-selfsteal не прошёл healthcheck: ${health}."

  test -S /dev/shm/nginx.sock || die "Не найден /dev/shm/nginx.sock на хосте."

  docker exec remnanode test -S /dev/shm/nginx.sock \
    || die "RemnaNode не видит /dev/shm/nginx.sock."

  ok "Nginx и Unix socket работают."
}

reload_selfsteal_nginx() {
  if docker inspect nginx-selfsteal >/dev/null 2>&1; then
    docker exec nginx-selfsteal nginx -t >/dev/null 2>&1 \
      && docker exec nginx-selfsteal nginx -s reload >/dev/null 2>&1 \
      || docker restart nginx-selfsteal >/dev/null
  fi
}

# ---------------------------------------------------------------------------
# SSL / acme.sh
# ---------------------------------------------------------------------------

install_acme() {
  local email="$1"

  if [[ ! -x "$ACME_BIN" ]]; then
    info "Устанавливаю acme.sh..."
    local installer
    installer="$(mktemp)"
    if ! curl --proto '=https' --tlsv1.2 -fsSL https://get.acme.sh -o "$installer"; then
      rm -f "$installer"
      die "Не удалось скачать установщик acme.sh."
    fi
    if ! sh "$installer" "email=${email}"; then
      rm -f "$installer"
      die "Установщик acme.sh завершился с ошибкой."
    fi
    rm -f "$installer"
  else
    ok "acme.sh уже установлен."
  fi

  [[ -x "$ACME_BIN" ]] || die "acme.sh не найден."

  "$ACME_BIN" --set-default-ca --server letsencrypt >/dev/null
  "$ACME_BIN" --register-account -m "$email" --server letsencrypt >/dev/null 2>&1 || true

  systemctl enable --now cron >/dev/null 2>&1 || true
}

check_domain_dns() {
  local domain="$1"
  local a_record aaaa_record

  a_record="$(dig +short A "$domain" | paste -sd ',' - || true)"
  aaaa_record="$(dig +short AAAA "$domain" | paste -sd ',' - || true)"

  [[ -n "$a_record" || -n "$aaaa_record" ]] || die "DNS для ${domain} не резолвится."

  info "DNS A: ${a_record:-нет}"
  info "DNS AAAA: ${aaaa_record:-нет}"

  local server_ipv4
  server_ipv4="$(public_ipv4)"
  if [[ -n "$server_ipv4" && -n "$a_record" && ",${a_record}," != *",${server_ipv4},"* ]]; then
    warn "A-запись (${a_record}) не совпадает с IPv4 сервера (${server_ipv4}). HTTP-01 может не пройти."
  fi

  if [[ -n "$aaaa_record" ]]; then
    warn "Для домена существует AAAA. IPv6 должен вести на эту же ноду и корректно обслуживать inbound."
  fi
}

ensure_port80_free() {
  if ss -lnt '( sport = :80 )' 2>/dev/null | grep -q LISTEN; then
    ss -lntp | grep ':80' || true
    die "Порт 80 занят. Для acme.sh --standalone HTTP-01 он должен быть свободен."
  fi
}

write_reload_helper() {
  cat > "$RELOAD_HELPER" <<'EOF'
#!/usr/bin/env bash
set -e
if docker inspect nginx-selfsteal >/dev/null 2>&1; then
  docker restart nginx-selfsteal >/dev/null
fi
if docker inspect remnanode >/dev/null 2>&1; then
  # Hysteria2 читает сертификат при старте Xray.
  docker restart remnanode >/dev/null || true
fi
exit 0
EOF
  chmod 755 "$RELOAD_HELPER"
}

install_cert_files() {
  local domain="$1"

  mkdir -p "${BASE_DIR}/ssl"
  chmod 700 "${BASE_DIR}/ssl"

  write_reload_helper

  "$ACME_BIN" --install-cert \
    -d "$domain" \
    --ecc \
    --key-file "${BASE_DIR}/ssl/privkey.pem" \
    --fullchain-file "${BASE_DIR}/ssl/fullchain.pem" \
    --reloadcmd "$RELOAD_HELPER"

  chmod 600 "${BASE_DIR}/ssl/privkey.pem"
  chmod 644 "${BASE_DIR}/ssl/fullchain.pem"

  openssl x509 \
    -in "${BASE_DIR}/ssl/fullchain.pem" \
    -noout -subject -issuer -dates -ext subjectAltName
}

issue_certificate() {
  local domain="$1"
  local email="$2"

  install_acme "$email"
  check_domain_dns "$domain"
  ensure_port80_free

  info "Выпускаю ECC сертификат Let's Encrypt для ${domain}..."

  "$ACME_BIN" --issue \
    --standalone \
    -d "$domain" \
    --server letsencrypt \
    --keylength ec-256 \
    || [[ $? == 2 ]]

  install_cert_files "$domain"
  ok "Сертификат установлен в ${BASE_DIR}/ssl."
}

renew_certificate() {
  local force="${1:-0}"

  load_state
  is_selfsteal_mode || die "SSL не настроен этим manager."
  [[ -n "$DOMAIN" ]] || die "Неизвестен домен."
  [[ -x "$ACME_BIN" ]] || die "acme.sh не установлен."

  ensure_port80_free

  if [[ "$force" == "1" ]]; then
    warn "Принудительный renew расходует лимиты CA."
    confirm "Принудительно перевыпустить ${DOMAIN}?" || return 0

    "$ACME_BIN" --renew \
      -d "$DOMAIN" \
      --ecc \
      --server letsencrypt \
      --force
  else
    "$ACME_BIN" --renew \
      -d "$DOMAIN" \
      --ecc \
      --server letsencrypt || true
  fi

  install_cert_files "$DOMAIN"
}

cert_days_left() {
  local cert="${BASE_DIR}/ssl/fullchain.pem" end_date end_epoch
  [[ -r "$cert" ]] || return 1
  end_date="$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)"
  end_epoch="$(date -d "$end_date" +%s 2>/dev/null)" || return 1
  printf '%d' $(( (end_epoch - $(date +%s)) / 86400 ))
}

# ---------------------------------------------------------------------------
# Inbound'ы и Reality
# ---------------------------------------------------------------------------

random_xhttp_path() {
  printf '/%s/%s' "$(random_pick assets static cdn media api files)" "$(openssl rand -hex 12)"
}

prompt_port() {
  local prompt="$1"
  local default="$2"
  local value

  read -r -p "${prompt} [${default}]: " value
  value="${value:-$default}"
  validate_port "$value" || die "Некорректный порт: ${value}"
  printf '%s' "$value"
}

prompt_inbounds() {
  RAW_ENABLED="0"
  XHTTP_ENABLED="0"
  HY2_ENABLED="0"

  echo
  echo -e "${C_BOLD}Какие протоколы создать в Xray profile?${C_RESET}"
  echo "1. VLESS TCP (RAW) + REALITY + Vision   — TCP 443, Selfsteal-сайт как маскировка"
  echo "2. VLESS XHTTP + REALITY                 — TCP 8443 (или 443 без RAW)"
  echo "3. Hysteria2                             — UDP 443, TLS-сертификат домена"
  echo "4. Все три"
  echo
  echo "Можно указать один или несколько через запятую: 1  |  1,3  |  2,3  |  1,2,3"
  echo

  local selection normalized
  read -r -p "Выбор [1]: " selection
  selection="${selection:-1}"
  normalized="${selection// /,}"

  if [[ "$selection" == "4" ]]; then
    RAW_ENABLED="1"
    XHTTP_ENABLED="1"
    HY2_ENABLED="1"
  else
    [[ ",${normalized}," == *",1,"* ]] && RAW_ENABLED="1"
    [[ ",${normalized}," == *",2,"* ]] && XHTTP_ENABLED="1"
    [[ ",${normalized}," == *",3,"* ]] && HY2_ENABLED="1"
  fi

  if [[ "$RAW_ENABLED" != "1" && "$XHTTP_ENABLED" != "1" && "$HY2_ENABLED" != "1" ]]; then
    die "Не выбран ни один inbound."
  fi

  if [[ "$RAW_ENABLED" == "1" ]]; then
    RAW_PORT="$(prompt_port "TCP порт VLESS RAW/REALITY" "443")"
  fi

  if [[ "$XHTTP_ENABLED" == "1" ]]; then
    local default_xhttp="443"
    [[ "$RAW_ENABLED" == "1" ]] && default_xhttp="8443"

    XHTTP_PORT="$(prompt_port "TCP порт VLESS XHTTP/REALITY" "$default_xhttp")"

    if [[ "$RAW_ENABLED" == "1" && "$XHTTP_PORT" == "$RAW_PORT" ]]; then
      die "RAW и XHTTP не могут быть отдельными inbound'ами на одном TCP-порту."
    fi

    echo
    echo "XHTTP mode:"
    echo "1. stream-one (рекомендуемый предсказуемый режим)"
    echo "2. stream-up"
    echo "3. packet-up"
    echo "4. auto"
    local mode_choice
    read -r -p "Выбор [1]: " mode_choice
    case "${mode_choice:-1}" in
      1) XHTTP_MODE="stream-one" ;;
      2) XHTTP_MODE="stream-up" ;;
      3) XHTTP_MODE="packet-up" ;;
      4) XHTTP_MODE="auto" ;;
      *) die "Некорректный XHTTP mode." ;;
    esac

    local generated_path path_input
    generated_path="$(random_xhttp_path)"
    read -r -p "XHTTP path [${generated_path}]: " path_input
    XHTTP_PATH="${path_input:-$generated_path}"
    validate_xhttp_path "$XHTTP_PATH" || die "Некорректный XHTTP path."
  fi

  if [[ "$HY2_ENABLED" == "1" ]]; then
    HY2_PORT="$(prompt_port "UDP порт Hysteria2" "443")"

    echo
    echo "Обфускация Salamander маскирует Hysteria2 под случайный UDP вместо QUIC/HTTP3."
    echo "Нужна, если клиенты подключаются из РФ: ТСПУ режет QUIC на UDP 443 к зарубежным IP."
    echo "Пароль обфускации нужно будет вставить в Host этой ноды в Panel (поле Final mask)."
    if confirm "Включить Salamander?"; then
      [[ -n "$HY2_OBFS_PASSWORD" ]] || HY2_OBFS_PASSWORD="$(openssl rand -hex 16)"
    else
      HY2_OBFS_PASSWORD=""
    fi
  fi

  if [[ "$RAW_ENABLED" != "1" && "$XHTTP_ENABLED" != "1" ]]; then
    warn "Выбран только Hysteria2: сайт-заглушка будет создан, но без Reality inbound он не будет доступен через fallback."
  fi
}

tune_hysteria_udp() {
  if [[ "$HY2_ENABLED" != "1" ]]; then
    rm -f /etc/sysctl.d/99-remnanode-hysteria.conf 2>/dev/null || true
    return 0
  fi

  cat > /etc/sysctl.d/99-remnanode-hysteria.conf <<'EOF'
# RemnaNode Manager — увеличенные UDP-буферы для QUIC/Hysteria2
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF

  sysctl --system >/dev/null || true
  ok "UDP buffers tuned for Hysteria2."
}

validate_short_id() {
  local value="$1"
  [[ "$value" =~ ^[0-9a-f]+$ ]] \
    && ((${#value} >= 2 && ${#value} <= 16 && ${#value} % 2 == 0))
}

validate_shortids_json() {
  local json="$1" value count unique
  jq -e 'type == "array" and length >= 1 and length <= 32' <<<"$json" >/dev/null || return 1
  while IFS= read -r value; do
    value="${value%$'\r'}"
    validate_short_id "$value" || return 1
  done < <(jq -r '.[]' <<<"$json")
  count="$(jq 'length' <<<"$json")"
  unique="$(jq 'unique | length' <<<"$json")"
  [[ "$count" == "$unique" ]]
}

generate_shortids_json() {
  local count="${1:-}" length candidate result='[]'
  [[ -n "$count" ]] || count="$(secure_random_int 3 12)"
  [[ "$count" =~ ^[0-9]+$ ]] && ((count >= 1 && count <= 32)) \
    || die "Количество Reality Short IDs должно быть от 1 до 32."
  while (($(jq 'length' <<<"$result") < count)); do
    length=$((2 * $(secure_random_int 1 8)))
    candidate="$(openssl rand -hex $((length / 2)))"
    result="$(jq -c --arg id "$candidate" 'if index($id) then . else . + [$id] end' <<<"$result")"
  done
  validate_shortids_json "$result" || die "Сгенерированные Reality Short IDs не прошли проверку."
  printf '%s' "$result"
}

# Сохраняет существующий список; при миграции одиночный legacy ID остаётся первым.
ensure_shortids_json() {
  local current="${1:-}" legacy="${2:-}" target result
  if [[ -n "$current" ]] && validate_shortids_json "$current"; then
    printf '%s' "$current"
    return 0
  fi
  target="$(secure_random_int 3 12)"
  result='[]'
  if [[ -n "$legacy" ]] && validate_short_id "$legacy"; then
    result="$(jq -cn --arg id "$legacy" '[$id]')"
  fi
  while (($(jq 'length' <<<"$result") < target)); do
    local length candidate
    length=$((2 * $(secure_random_int 1 8)))
    candidate="$(openssl rand -hex $((length / 2)))"
    result="$(jq -c --arg id "$candidate" 'if index($id) then . else . + [$id] end' <<<"$result")"
  done
  printf '%s' "$result"
}

generate_reality_material() {
  load_reality

  if [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]]; then
    RAW_SHORT_IDS_JSON="$(ensure_shortids_json "${RAW_SHORT_IDS_JSON:-}" "${RAW_SHORT_ID:-}")"
    XHTTP_SHORT_IDS_JSON="$(ensure_shortids_json "${XHTTP_SHORT_IDS_JSON:-}" "${XHTTP_SHORT_ID:-}")"
    RAW_SHORT_ID="$(jq -r '.[0]' <<<"$RAW_SHORT_IDS_JSON")"
    XHTTP_SHORT_ID="$(jq -r '.[0]' <<<"$XHTTP_SHORT_IDS_JSON")"
    save_reality
    return 0
  fi

  docker inspect remnanode >/dev/null 2>&1 || die "Контейнер remnanode не запущен."

  local output
  output="$(node_xray_exec x25519 2>/dev/null || true)"
  [[ -n "$output" ]] || die "xray x25519 не вернул ключи."

  REALITY_PRIVATE_KEY="$(printf '%s\n' "$output" | awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}')"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "$output" | awk -F': *' 'tolower($1) ~ /(public|password)/ {print $2; exit}')"

  [[ -n "$REALITY_PRIVATE_KEY" ]] || die "Не удалось определить Reality Private Key."
  [[ -n "$REALITY_PUBLIC_KEY" ]] || die "Не удалось определить Reality Public Key/Password."
  [[ "$REALITY_PRIVATE_KEY" =~ ^[A-Za-z0-9_=-]{32,128}$ ]] \
    || die "Xray вернул Reality Private Key в неожиданном формате."
  [[ "$REALITY_PUBLIC_KEY" =~ ^[A-Za-z0-9_=-]{32,128}$ ]] \
    || die "Xray вернул Reality Public Key в неожиданном формате."

  RAW_SHORT_IDS_JSON="$(generate_shortids_json)"
  XHTTP_SHORT_IDS_JSON="$(generate_shortids_json)"
  RAW_SHORT_ID="$(jq -r '.[0]' <<<"$RAW_SHORT_IDS_JSON")"
  XHTTP_SHORT_ID="$(jq -r '.[0]' <<<"$XHTTP_SHORT_IDS_JSON")"

  save_reality
  ok "Reality keypair и Short IDs сгенерированы."
}

rotate_reality_keys() {
  load_state

  if [[ "$RAW_ENABLED" != "1" && "$XHTTP_ENABLED" != "1" ]]; then
    die "В текущем профиле нет REALITY inbound."
  fi

  confirm_no_default "Сгенерировать НОВУЮ Reality keypair? Клиентские конфиги после этого нужно обновить." || return 0

  backup_file "$REALITY_FILE"
  rm -f "$REALITY_FILE"
  REALITY_PRIVATE_KEY=""
  REALITY_PUBLIC_KEY=""
  RAW_SHORT_ID=""
  XHTTP_SHORT_ID=""
  RAW_SHORT_IDS_JSON=""
  XHTTP_SHORT_IDS_JSON=""

  generate_reality_material
  generate_xray_profile 1

  warn "Новый profile нужно сохранить/запушить в Remnawave Panel."
}

regenerate_short_ids() {
  load_state
  load_reality
  [[ -n "$REALITY_PRIVATE_KEY" ]] || die "Reality ещё не настроен."

  echo "RAW Short IDs:   ${RAW_SHORT_IDS_JSON:-нет}"
  echo "XHTTP Short IDs: ${XHTTP_SHORT_IDS_JSON:-нет}"
  echo
  warn "Клиенты со старыми Short IDs перестанут подключаться после применения профиля в Panel."
  confirm_no_default "Сгенерировать новые Short IDs?" || return 0

  local count
  read -r -p "Количество (Enter = случайно 3–12): " count
  backup_file "$REALITY_FILE"
  RAW_SHORT_IDS_JSON="$(generate_shortids_json "$count")"
  XHTTP_SHORT_IDS_JSON="$(generate_shortids_json "$count")"
  RAW_SHORT_ID="$(jq -r '.[0]' <<<"$RAW_SHORT_IDS_JSON")"
  XHTTP_SHORT_ID="$(jq -r '.[0]' <<<"$XHTTP_SHORT_IDS_JSON")"
  save_reality
  generate_xray_profile 1
}

# ---------------------------------------------------------------------------
# Routing: списки доменов модулей и geo-файлы roscomvpn
# ---------------------------------------------------------------------------

geo_files_present() {
  [[ -s "${GEO_DIR}/${GEO_SITE_FILE}" && -s "${GEO_DIR}/${GEO_IP_FILE}" ]]
}

# Префикс для правил: roscomvpn через ext:, иначе встроенные geosite/geoip Xray.
geo_site_ref() {
  local category="$1"
  if [[ "$GEO_ENABLED" == "1" ]]; then
    printf 'ext:%s:%s' "$GEO_SITE_FILE" "$category"
  else
    printf 'geosite:%s' "$category"
  fi
}

geo_ip_ref() {
  local category="$1"
  if [[ "$GEO_ENABLED" == "1" ]]; then
    printf 'ext:%s:%s' "$GEO_IP_FILE" "$category"
  else
    printf 'geoip:%s' "$category"
  fi
}

default_routing_list() {
  case "$1" in
    warp)
      cat <<'EOF'
# Домены через WARP (по одному на строку: domain:, full:, keyword:, regexp:, geosite:, ext:)
domain:openai.com
domain:chatgpt.com
domain:oaistatic.com
domain:oaiusercontent.com
domain:anthropic.com
domain:claude.ai
domain:gemini.google.com
domain:aistudio.google.com
domain:generativelanguage.googleapis.com
domain:notebooklm.google.com
EOF
      ;;
    psiphon)
      cat <<'EOF'
# Домены через Psiphon (только TCP)
EOF
      ;;
    tor)
      cat <<'EOF'
# Домены через Tor
regexp:\.onion$
EOF
      ;;
  esac
}

routing_list_file() {
  printf '%s/%s.list' "$ROUTING_DIR" "$1"
}

ensure_routing_lists() {
  mkdir -p "$ROUTING_DIR"
  chmod 700 "$ROUTING_DIR"
  local name file
  for name in warp psiphon tor; do
    file="$(routing_list_file "$name")"
    [[ -f "$file" ]] || default_routing_list "$name" > "$file"
  done
}

# Печатает JSON-массив доменов из файла списка (без комментариев и пустых строк).
routing_list_json() {
  local file
  file="$(routing_list_file "$1")"
  [[ -f "$file" ]] || { printf '[]'; return 0; }
  grep -vE '^[[:space:]]*(#|$)' "$file" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' \
    | jq -R . | jq -cs .
}

edit_routing_list() {
  local name="$1" file
  ensure_routing_lists
  file="$(routing_list_file "$name")"
  "${EDITOR:-nano}" "$file" || vi "$file"
}

# ---------------------------------------------------------------------------
# Генерация Xray Config Profile
# ---------------------------------------------------------------------------

# finalmask для Hysteria2 на ноде: BBR и, если задан пароль, Salamander.
hy2_finalmask_json() {
  jq -cn --arg password "$HY2_OBFS_PASSWORD" '
    {quicParams: {debug: false, congestion: "bbr"}}
    + (if $password == "" then {} else {udp: [{type: "salamander", settings: {password: $password}}]} end)'
}

# JSON для поля Final mask у Host в Panel — из него Remnawave добавляет
# obfs=salamander в ссылку hysteria2:// для клиентов.
hy2_host_finalmask_json() {
  [[ -n "$HY2_OBFS_PASSWORD" ]] || return 0
  jq -cn --arg password "$HY2_OBFS_PASSWORD" '{udp: [{type: "salamander", settings: {password: $password}}]}'
}

build_inbounds_json() {
  local result='[]'

  if [[ "$RAW_ENABLED" == "1" ]]; then
    result="$(jq -c \
      --argjson port "$RAW_PORT" \
      --argjson shortIds "$RAW_SHORT_IDS_JSON" \
      --arg privateKey "$REALITY_PRIVATE_KEY" \
      --arg domain "$DOMAIN" \
      '. + [{
        tag: "VLESS_RAW_REALITY",
        port: $port,
        listen: "0.0.0.0",
        protocol: "vless",
        settings: {clients: [], decryption: "none"},
        sniffing: {enabled: true, destOverride: ["http", "tls", "quic"]},
        streamSettings: {
          network: "raw",
          security: "reality",
          realitySettings: {
            show: false,
            xver: 1,
            target: "/dev/shm/nginx.sock",
            spiderX: "",
            shortIds: $shortIds,
            privateKey: $privateKey,
            serverNames: [$domain],
            minClientVer: "0.0.0"
          }
        }
      }]' <<<"$result")"
  fi

  if [[ "$XHTTP_ENABLED" == "1" ]]; then
    result="$(jq -c \
      --argjson port "$XHTTP_PORT" \
      --argjson shortIds "$XHTTP_SHORT_IDS_JSON" \
      --arg privateKey "$REALITY_PRIVATE_KEY" \
      --arg domain "$DOMAIN" \
      --arg path "$XHTTP_PATH" \
      --arg mode "$XHTTP_MODE" \
      '. + [{
        tag: "VLESS_XHTTP_REALITY",
        port: $port,
        listen: "0.0.0.0",
        protocol: "vless",
        settings: {clients: [], decryption: "none"},
        sniffing: {enabled: true, destOverride: ["http", "tls", "quic"]},
        streamSettings: {
          network: "xhttp",
          security: "reality",
          xhttpSettings: {path: $path, mode: $mode},
          realitySettings: {
            show: false,
            xver: 1,
            target: "/dev/shm/nginx.sock",
            spiderX: "",
            shortIds: $shortIds,
            privateKey: $privateKey,
            serverNames: [$domain],
            minClientVer: "0.0.0"
          }
        }
      }]' <<<"$result")"
  fi

  if [[ "$HY2_ENABLED" == "1" ]]; then
    result="$(jq -c \
      --argjson port "$HY2_PORT" \
      --arg domain "$DOMAIN" \
      --argjson finalmask "$(hy2_finalmask_json)" \
      '. + [{
        tag: "HYSTERIA2",
        port: $port,
        listen: "0.0.0.0",
        protocol: "hysteria",
        settings: {clients: [], version: 2},
        streamSettings: {
          network: "hysteria",
          security: "tls",
          finalmask: $finalmask,
          tlsSettings: {
            alpn: ["h3"],
            serverName: $domain,
            certificates: [{
              keyFile: "/opt/remnanode/ssl/privkey.pem",
              certificateFile: "/opt/remnanode/ssl/fullchain.pem"
            }]
          },
          hysteriaSettings: {version: 2}
        }
      }]' <<<"$result")"
  fi

  printf '%s' "$result"
}

build_outbounds_json() {
  local result
  result='[{"tag":"DIRECT","protocol":"freedom"},{"tag":"BLOCK","protocol":"blackhole"}]'

  # Перехваченные DNS-запросы клиентов обрабатывает DNS-модуль Xray.
  if [[ "$DNS_HIJACK" == "1" ]]; then
    result="$(jq -c '. + [{tag: "dns-out", protocol: "dns"}]' <<<"$result")"
  fi

  if [[ "$WARP_OUTBOUND" == "1" ]]; then
    result="$(jq -c '. + [{
      tag: "WARP",
      protocol: "freedom",
      settings: {domainStrategy: "UseIPv4"},
      streamSettings: {sockopt: {interface: "warp", tcpFastOpen: true}}
    }]' <<<"$result")"
  fi

  if [[ "$PSIPHON_OUTBOUND" == "1" ]]; then
    result="$(jq -c --arg address "$PSIPHON_ADDR" --argjson port "$PSIPHON_PORT" '. + [{
      tag: "PSIPHON",
      protocol: "socks",
      settings: {address: $address, port: $port}
    }]' <<<"$result")"
  fi

  if [[ "$TOR_OUTBOUND" == "1" ]]; then
    result="$(jq -c '. + [{
      tag: "TOR",
      protocol: "socks",
      settings: {address: "127.0.0.1", port: 9050}
    }]' <<<"$result")"
  fi

  printf '%s' "$result"
}

ru_policy_tag() {
  case "$RU_POLICY" in
    direct) printf 'DIRECT' ;;
    warp)
      if [[ "$WARP_OUTBOUND" == "1" ]]; then
        printf 'WARP'
      else
        printf 'BLOCK'
      fi
      ;;
    *) printf 'BLOCK' ;;
  esac
}

# Домены и IP «РФ + белые списки» — общие для DNS и routing.
ru_domain_matchers() {
  if [[ "$GEO_ENABLED" == "1" ]]; then
    jq -cn --arg ru "$(geo_site_ref category-ru)" --arg wl "$(geo_site_ref whitelist)" '[$ru, $wl]'
  else
    jq -cn '["geosite:category-ru", "regexp:\\.ru$", "regexp:\\.su$", "regexp:\\.xn--p1ai$"]'
  fi
}

ru_ip_matchers() {
  if [[ "$GEO_ENABLED" == "1" ]]; then
    jq -cn --arg direct "$(geo_ip_ref direct)" --arg whitelist "$(geo_ip_ref whitelist)" '[$direct, $whitelist]'
  else
    jq -cn '["geoip:ru"]'
  fi
}

# Список "a,b,c" → JSON-массив.
csv_to_json() {
  tr ',' '\n' <<<"$1" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | grep -v '^$' | jq -R . | jq -cs .
}

# Split DNS. РФ-домены резолвятся РФ-серверами, и ответ принимается, только
# если указывает на РФ-адрес (expectIPs) — иначе запрос уходит дальше.
# Остальные домены — через зарубежный DoH, который не видят провайдер и ТСПУ.
build_dns_json() {
  jq -cn \
    --argjson ruDomains "$(ru_domain_matchers)" \
    --argjson ruIps "$(ru_ip_matchers)" \
    --argjson ruServers "$(csv_to_json "$DNS_RU")" \
    --argjson foreign "$(csv_to_json "$DNS_FOREIGN")" \
    '{
      tag: "dns-internal",
      queryStrategy: "UseIPv4",
      disableFallbackIfMatch: true,
      servers: (
        [$ruServers[] | {address: ., domains: $ruDomains, expectIPs: $ruIps, skipFallback: true}]
        + $foreign
      )
    }'
}

build_routing_json() {
  local rules='[]' list ru_tag

  # 0. DNS. Собственные запросы резолвера Xray идут напрямую — иначе запрос
  #    к РФ-DNS попал бы под правило geoip:ru → BLOCK. Клиентский DNS внутри
  #    туннеля перехватывается и обрабатывается той же split-схемой (без утечек).
  rules="$(jq -c '. + [{type: "field", inboundTag: ["dns-internal"], outboundTag: "DIRECT"}]' <<<"$rules")"
  if [[ "$DNS_HIJACK" == "1" ]]; then
    rules="$(jq -c '. + [{type: "field", port: "53", outboundTag: "dns-out"}]' <<<"$rules")"
  fi

  # 1. Локальные сети: никогда не проксировать внутрь инфраструктуры сервера.
  rules="$(jq -c '. + [
    {type: "field", ip: ["geoip:private"], outboundTag: "BLOCK"},
    {type: "field", domain: ["geosite:private"], outboundTag: "BLOCK"}
  ]' <<<"$rules")"

  # 2. Торренты: протокол и трекеры блокируются полностью.
  rules="$(jq -c '. + [{type: "field", protocol: ["bittorrent"], outboundTag: "BLOCK"}]' <<<"$rules")"
  if [[ "$GEO_ENABLED" == "1" ]]; then
    rules="$(jq -c --arg torrent "$(geo_site_ref torrent)" \
      '. + [{type: "field", domain: [$torrent], outboundTag: "BLOCK"}]' <<<"$rules")"
  fi

  # 3. Реклама и телеметрия (опционально).
  if [[ "$BLOCK_ADS" == "1" ]]; then
    if [[ "$GEO_ENABLED" == "1" ]]; then
      rules="$(jq -c --arg ads "$(geo_site_ref category-ads)" --arg spy "$(geo_site_ref win-spy)" \
        '. + [{type: "field", domain: [$ads, $spy], outboundTag: "BLOCK"}]' <<<"$rules")"
    else
      rules="$(jq -c '. + [{type: "field", domain: ["geosite:category-ads-all"], outboundTag: "BLOCK"}]' <<<"$rules")"
    fi
  fi

  # 4. Модули: выбранные домены через WARP / Psiphon / Tor.
  if [[ "$TOR_OUTBOUND" == "1" ]]; then
    list="$(routing_list_json tor)"
    [[ "$list" != "[]" ]] && rules="$(jq -c --argjson d "$list" \
      '. + [{type: "field", domain: $d, outboundTag: "TOR"}]' <<<"$rules")"
  fi
  if [[ "$PSIPHON_OUTBOUND" == "1" ]]; then
    list="$(routing_list_json psiphon)"
    [[ "$list" != "[]" ]] && rules="$(jq -c --argjson d "$list" \
      '. + [{type: "field", network: "tcp", domain: $d, outboundTag: "PSIPHON"}]' <<<"$rules")"
  fi
  if [[ "$WARP_OUTBOUND" == "1" ]]; then
    list="$(routing_list_json warp)"
    [[ "$list" != "[]" ]] && rules="$(jq -c --argjson d "$list" \
      '. + [{type: "field", domain: $d, outboundTag: "WARP"}]' <<<"$rules")"
  fi

  # 5. РФ-сайты и белые списки. Клиент должен ходить к ним напрямую;
  #    если трафик всё же пришёл на ноду — применяется политика RU_POLICY.
  ru_tag="$(ru_policy_tag)"
  rules="$(jq -c --arg tag "$ru_tag" \
    --argjson domains "$(ru_domain_matchers)" --argjson ips "$(ru_ip_matchers)" \
    '. + [
      {type: "field", domain: $domains, outboundTag: $tag},
      {type: "field", ip: $ips, outboundTag: $tag}
    ]' <<<"$rules")"

  # 6. Всё остальное уходит в первый outbound (DIRECT) — обычный выход ноды.
  jq -cn --argjson rules "$rules" '{domainStrategy: "IPIfNonMatch", rules: $rules}'
}

generate_xray_profile() {
  local use_current_state="${1:-0}"
  [[ "$use_current_state" == "1" ]] || load_state

  mkdir -p "$PROFILE_DIR"
  ensure_routing_lists

  if [[ "$GEO_ENABLED" == "1" ]] && ! geo_files_present; then
    warn "Geo-файлы roscomvpn не найдены — используются встроенные geosite/geoip Xray."
    GEO_ENABLED="0"
  fi

  if [[ "$RAW_ENABLED" == "1" || "$XHTTP_ENABLED" == "1" ]]; then
    [[ -n "$DOMAIN" ]] || die "DOMAIN отсутствует — Reality inbound без Selfsteal невозможен."
    generate_reality_material
    load_reality
  fi
  if [[ "$HY2_ENABLED" == "1" ]]; then
    [[ -n "$DOMAIN" ]] || die "DOMAIN отсутствует — Hysteria2 требует сертификат."
  fi

  validate_dns_list "$DNS_RU" || die "Некорректный список РФ-DNS: ${DNS_RU}"
  validate_dns_list "$DNS_FOREIGN" || die "Некорректный список зарубежных DNS: ${DNS_FOREIGN}"

  local inbounds outbounds routing dns profile_tmp profile_info_tmp
  inbounds="$(build_inbounds_json)"
  outbounds="$(build_outbounds_json)"
  routing="$(build_routing_json)"
  dns="$(build_dns_json)"

  profile_tmp="$(mktemp "${PROFILE_FILE}.tmp.XXXXXX")"
  profile_info_tmp="$(mktemp "${PROFILE_INFO}.tmp.XXXXXX")"

  jq -n \
    --argjson inbounds "$inbounds" \
    --argjson outbounds "$outbounds" \
    --argjson routing "$routing" \
    --argjson dns "$dns" \
    '{
      log: {loglevel: "warning"},
      dns: $dns,
      inbounds: $inbounds,
      outbounds: $outbounds,
      routing: $routing
    }' > "$profile_tmp" || { rm -f "$profile_tmp" "$profile_info_tmp"; die "Не удалось собрать JSON profile."; }

  chmod 600 "$profile_tmp"
  [[ -f "$PROFILE_FILE" ]] && cp -a "$PROFILE_FILE" "${PROFILE_FILE}.prev"
  mv -f "$profile_tmp" "$PROFILE_FILE"

  {
    echo "RemnaNode Manager ${SCRIPT_VERSION}"
    echo
    echo "Mode: ${INSTALL_MODE:-unknown}"
    echo "Domain: ${DOMAIN:-нет}"
    echo "Routing: geo=$([[ "$GEO_ENABLED" == 1 ]] && echo roscomvpn || echo builtin), RU=${RU_POLICY}, ads=${BLOCK_ADS}"
    echo "DNS: РФ-домены → ${DNS_RU}; остальное → ${DNS_FOREIGN}; перехват клиентского DNS: $([[ "$DNS_HIJACK" == 1 ]] && echo вкл || echo выкл)"
    echo "Outbounds: $(jq -r '[.[].tag] | join(", ")' <<<"$outbounds")"
    echo

    if [[ "$RAW_ENABLED" == "1" ]]; then
      echo "[VLESS RAW + REALITY]"
      echo "Tag: VLESS_RAW_REALITY"
      echo "TCP port: ${RAW_PORT}"
      echo "SNI: ${DOMAIN}"
      echo "Short IDs: $(jq -c . <<<"$RAW_SHORT_IDS_JSON")"
      echo "Public Key / Password: ${REALITY_PUBLIC_KEY}"
      echo "Flow: xtls-rprx-vision"
      echo "Target: /dev/shm/nginx.sock"
      echo
    fi

    if [[ "$XHTTP_ENABLED" == "1" ]]; then
      echo "[VLESS XHTTP + REALITY]"
      echo "Tag: VLESS_XHTTP_REALITY"
      echo "TCP port: ${XHTTP_PORT}"
      echo "SNI: ${DOMAIN}"
      echo "Short IDs: $(jq -c . <<<"$XHTTP_SHORT_IDS_JSON")"
      echo "Public Key / Password: ${REALITY_PUBLIC_KEY}"
      echo "Path: ${XHTTP_PATH}"
      echo "Mode: ${XHTTP_MODE}"
      echo "Target: /dev/shm/nginx.sock"
      echo "Important: do not use xtls-rprx-vision flow for XHTTP."
      echo
    fi

    if [[ "$HY2_ENABLED" == "1" ]]; then
      echo "[Hysteria2]"
      echo "Tag: HYSTERIA2"
      echo "UDP port: ${HY2_PORT}"
      echo "SNI: ${DOMAIN}"
      echo "TLS certificate: /opt/remnanode/ssl/fullchain.pem"
      if [[ -n "$HY2_OBFS_PASSWORD" ]]; then
        echo "Obfuscation: salamander"
        echo "Panel → Hosts → хост HYSTERIA2 → Final mask (без этого клиенты не подключатся):"
        echo "  $(hy2_host_finalmask_json)"
      else
        echo "Obfuscation: нет (при подключении из РФ QUIC на UDP может блокироваться)"
      fi
      echo
    fi

    if [[ "$(jq 'length' <<<"$inbounds")" == "0" ]]; then
      echo "Inbound'ов нет: это routing-профиль. Примени его в Panel режимом «merge»"
      echo "(сохраняются inbound'ы панели, заменяются outbounds/routing/dns)."
      echo
    fi

    echo "Profile: ${PROFILE_FILE}"
    [[ "$GEO_ENABLED" == "1" ]] && echo "ВНИМАНИЕ: профиль использует ext:${GEO_SITE_FILE}/ext:${GEO_IP_FILE} — geo-файлы должны быть на КАЖДОЙ ноде с этим профилем."
  } > "$profile_info_tmp"

  chmod 600 "$profile_info_tmp"
  mv -f "$profile_info_tmp" "$PROFILE_INFO"
  ok "Xray profile сгенерирован: ${PROFILE_FILE}"

  generate_client_routing
  validate_generated_profile || true
}

validate_generated_profile() {
  local file="${1:-$PROFILE_FILE}"
  docker inspect remnanode >/dev/null 2>&1 || return 0

  info "Проверяю Xray JSON текущим Xray внутри remnanode..."

  if ! docker exec remnanode sh -c 'command -v xray || command -v rw-core' >/dev/null 2>&1; then
    warn "В контейнере нет бинарника Xray; выполнена только проверка синтаксиса JSON."
    return 0
  fi

  docker cp "$file" remnanode:/tmp/remnanode-manager-profile.json >/dev/null

  local result=0
  if node_xray_exec run -test -config /tmp/remnanode-manager-profile.json >/dev/null 2>&1; then
    ok "Xray принимает сгенерированный profile."
  elif node_xray_exec -test -config /tmp/remnanode-manager-profile.json >/dev/null 2>&1; then
    ok "Xray принимает сгенерированный profile."
  else
    warn "Автотест Xray profile не прошёл. Вывод Xray:"
    node_xray_exec run -test -config /tmp/remnanode-manager-profile.json 2>&1 | tail -n 8 || true
    warn "Проверь вручную перед push в Panel: ${file}"
    result=1
  fi

  docker exec remnanode rm -f /tmp/remnanode-manager-profile.json >/dev/null 2>&1 || true
  return "$result"
}

show_profile_info() {
  load_state
  load_reality

  if [[ -f "$PROFILE_INFO" ]]; then
    cat "$PROFILE_INFO"
  else
    warn "profile-info.txt отсутствует."
  fi

  echo
  if [[ -n "$REALITY_PUBLIC_KEY" ]]; then
    echo "Reality Public Key / Password: ${REALITY_PUBLIC_KEY}"
  fi

  if [[ -n "$REALITY_PRIVATE_KEY" ]] && confirm_no_default "Показать PRIVATE Reality key?"; then
    echo "Reality Private Key: ${REALITY_PRIVATE_KEY}"
  fi

  echo
  echo "Xray profile: ${PROFILE_FILE}"
}

print_profile_json() {
  [[ -f "$PROFILE_FILE" ]] || die "Profile ещё не создан."
  jq . "$PROFILE_FILE"
}

# ---------------------------------------------------------------------------
# Клиентская маршрутизация (подписка / Happ)
# ---------------------------------------------------------------------------

# Первый IP из списка РФ-DNS и первый DoH из зарубежного — для клиентов.
client_domestic_dns_ip() {
  local item
  local -a items=()
  IFS=, read -r -a items <<<"$DNS_RU"
  for item in "${items[@]}"; do
    [[ "$item" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { printf '%s' "$item"; return 0; }
  done
  printf '77.88.8.8'
}

client_remote_doh() {
  local item
  local -a items=()
  IFS=, read -r -a items <<<"$DNS_FOREIGN"
  for item in "${items[@]}"; do
    [[ "$item" == https://* ]] && { printf '%s' "$item"; return 0; }
  done
  printf 'https://1.1.1.1/dns-query'
}

# Популярные РФ-приложения (Android package name) для раздельного
# туннелирования: исключённые из VPN приложения не видят VPN-интерфейс
# и ходят в сеть с домашнего IP.
write_client_ru_apps() {
  cat > "$CLIENT_APPS_FILE" <<'APPS'
# Android-приложения, которые стоит исключить из VPN (Happ / v2rayNG:
# «Раздельное туннелирование» / «Per-app proxy» → режим «в обход»).
# Проверь названия пакетов в своём клиенте и дополни список.
ru.sberbankmobile
com.idamob.tinkoff.android
ru.vtb24.mobilebanking.android
ru.alfabank.mobile.android
ru.rostel
ru.yandex.searchplugin
ru.yandex.yandexmaps
ru.yandex.taxi
com.yandex.browser
ru.ozon.app.android
com.wildberries.ru
com.avito.android
com.vkontakte.android
ru.mail.mailapp
APPS
}

generate_client_routing() {
  mkdir -p "$PROFILE_DIR"

  local block_sites='["geosite:torrent"]'
  [[ "$BLOCK_ADS" == "1" ]] && block_sites='["geosite:torrent","geosite:category-ads","geosite:win-spy"]'

  local domestic_ip remote_doh remote_host remote_ip
  domestic_ip="$(client_domestic_dns_ip)"
  remote_doh="$(client_remote_doh)"
  remote_host="${remote_doh#https://}"
  remote_host="${remote_host%%/*}"
  remote_host="${remote_host%%:*}"
  remote_ip="$remote_host"
  [[ "$remote_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || remote_ip="1.1.1.1"

  # Happ: РФ + белые списки напрямую с РФ-DNS, остальное через прокси с DoH
  # внутри туннеля — зарубежные DNS-запросы не уходят мимо VPN.
  jq -n \
    --arg geoip "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geoip/release/geoip.dat" \
    --arg geosite "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/geosite.dat" \
    --arg updated "$(date +%s)" \
    --argjson block "$block_sites" \
    --arg domesticIp "$domestic_ip" \
    --arg remoteDoh "$remote_doh" \
    --arg remoteIp "$remote_ip" \
    '{
      Name: "RemnaNode RU-direct",
      GlobalProxy: "true",
      UseChunkFiles: "true",
      RemoteDns: $remoteIp,
      DomesticDns: $domesticIp,
      RemoteDNSType: "DoH",
      RemoteDNSDomain: $remoteDoh,
      RemoteDNSIP: $remoteIp,
      DomesticDNSType: "DoH",
      DomesticDNSDomain: ("https://" + $domesticIp + "/dns-query"),
      DomesticDNSIP: $domesticIp,
      Geoipurl: $geoip,
      Geositeurl: $geosite,
      LastUpdated: $updated,
      DnsHosts: {},
      RouteOrder: "block-direct-proxy",
      DirectSites: ["geosite:private", "geosite:category-ru", "geosite:whitelist"],
      DirectIp: ["geoip:private", "geoip:direct", "geoip:whitelist"],
      ProxySites: [],
      ProxyIp: [],
      BlockSites: $block,
      BlockIp: [],
      DomainStrategy: "IPIfNonMatch",
      FakeDNS: "false"
    }' > "$CLIENT_ROUTING_FILE"

  # Xray JSON-шаблон подписки Remnawave (теги proxy/direct/block, стандартные
  # geo-файлы клиента): routing.rules и dns.
  local client_block='[{"type":"field","protocol":["bittorrent"],"outboundTag":"block"}]'
  [[ "$BLOCK_ADS" == "1" ]] && client_block='[{"type":"field","protocol":["bittorrent"],"outboundTag":"block"},{"type":"field","domain":["geosite:category-ads-all"],"outboundTag":"block"}]'
  jq -n --argjson block "$client_block" --arg domesticIp "$domestic_ip" '$block + [
    {type: "field", ip: ["geoip:private"], outboundTag: "direct"},
    {type: "field", ip: [$domesticIp], outboundTag: "direct"},
    {type: "field", domain: ["geosite:private", "geosite:category-ru", "regexp:\\.ru$", "regexp:\\.su$", "regexp:\\.xn--p1ai$"], outboundTag: "direct"},
    {type: "field", ip: ["geoip:ru"], outboundTag: "direct"},
    {type: "field", network: "tcp,udp", outboundTag: "proxy"}
  ]' > "$CLIENT_RULES_FILE"

  jq -n --arg domesticIp "$domestic_ip" --arg remoteDoh "$remote_doh" '{
    queryStrategy: "UseIPv4",
    disableFallbackIfMatch: true,
    servers: [
      {
        address: ("https://" + $domesticIp + "/dns-query"),
        domains: ["geosite:category-ru", "regexp:\\.ru$", "regexp:\\.su$", "regexp:\\.xn--p1ai$"],
        expectIPs: ["geoip:ru"],
        skipFallback: true
      },
      $remoteDoh
    ]
  }' > "$CLIENT_DNS_FILE"

  write_client_ru_apps
  chmod 644 "$CLIENT_ROUTING_FILE" "$CLIENT_RULES_FILE" "$CLIENT_DNS_FILE" "$CLIENT_APPS_FILE"
}

# ---------------------------------------------------------------------------
# Remnawave Panel API
# ---------------------------------------------------------------------------

panel_load() {
  PANEL_URL=""
  PANEL_TOKEN=""
  [[ -r "$PANEL_ENV_FILE" ]] || return 1
  PANEL_URL="$(sed -n 's/^PANEL_URL=//p' "$PANEL_ENV_FILE" | head -n1)"
  PANEL_TOKEN="$(sed -n 's/^PANEL_TOKEN=//p' "$PANEL_ENV_FILE" | head -n1)"
  [[ -n "$PANEL_URL" && -n "$PANEL_TOKEN" ]]
}

panel_configured() {
  [[ -r "$PANEL_ENV_FILE" ]] && grep -q '^PANEL_TOKEN=.' "$PANEL_ENV_FILE"
}

panel_request() {
  local method="$1" path="$2" data="${3:-}"
  panel_load || die "Panel API не настроен."
  local -a request=(curl -fsS --connect-timeout 5 --max-time 20 -X "$method"
    -H "Authorization: Bearer ${PANEL_TOKEN}"
    -H 'Content-Type: application/json'
    -H 'X-Forwarded-Proto: https'
    -H 'X-Forwarded-For: 127.0.0.1')
  [[ -n "$data" ]] && request+=(--data-binary "@${data}")
  request+=("${PANEL_URL%/}${path}")
  "${request[@]}"
}

# ---------------------------------------------------------------------------
# Состояние Node / Xray / Selfsteal / Panel
# ---------------------------------------------------------------------------

# Результат кешируется в пределах процесса: шапка вызывает проверку много раз.
DOCKER_AVAILABLE_CACHE=""
docker_available() {
  if [[ -z "$DOCKER_AVAILABLE_CACHE" ]]; then
    if command -v docker >/dev/null 2>&1 && docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
      DOCKER_AVAILABLE_CACHE="1"
    else
      DOCKER_AVAILABLE_CACHE="0"
    fi
  fi
  [[ "$DOCKER_AVAILABLE_CACHE" == "1" ]]
}

node_exists() {
  docker_available && docker inspect remnanode >/dev/null 2>&1
}

node_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' remnanode 2>/dev/null)" == "true" ]]
}

# Запускает бинарник Xray в контейнере ноды (xray или rw-core в новых образах).
node_xray_exec() {
  docker exec remnanode sh -c 'b="$(command -v xray || command -v rw-core || true)"; [ -n "$b" ] || exit 127; exec "$b" "$@"' sh "$@"
}

xray_running() {
  pgrep -x xray >/dev/null 2>&1 || pgrep -x rw-core >/dev/null 2>&1
}

runtime_cache_get() {
  local key="$1" ttl="$2" file="${RUNTIME_CACHE}/${1}"
  [[ -f "$file" ]] || return 1
  if [[ "$ttl" != "0" ]]; then
    local age=$(( $(date +%s) - $(stat -c %Y "$file" 2>/dev/null || echo 0) ))
    ((age <= ttl)) || return 1
  fi
  cat "$file"
  : "$key"
}

runtime_cache_put() {
  mkdir -p "$RUNTIME_CACHE" 2>/dev/null || return 0
  printf '%s' "$2" > "${RUNTIME_CACHE}/${1}" 2>/dev/null || true
}

# Ключ кеша версий меняется при пересоздании/перезапуске контейнера.
node_cache_key() {
  docker inspect -f '{{.Id}}{{.State.StartedAt}}' remnanode 2>/dev/null | md5sum | cut -c1-12
}

node_image_ref() {
  docker inspect -f '{{.Config.Image}}' remnanode 2>/dev/null || true
}

node_version() {
  node_exists || { printf '—'; return 0; }
  local key cached ref tag version image_id
  key="node-version-$(node_cache_key)"
  if cached="$(runtime_cache_get "$key" 0)"; then
    printf '%s' "$cached"
    return 0
  fi

  ref="$(node_image_ref)"
  tag=""
  if [[ "$ref" != *@* && "${ref##*/}" == *:* ]]; then
    tag="${ref##*:}"
  fi

  version=""
  if [[ -n "$tag" && "$tag" != "latest" && "$tag" =~ [0-9] ]]; then
    version="${tag#v}"
  else
    image_id="$(docker inspect -f '{{.Image}}' remnanode 2>/dev/null || true)"
    version="$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$image_id" 2>/dev/null || true)"
    [[ "$version" == "<no value>" ]] && version=""
    if [[ -z "$version" ]] && node_running; then
      version="$(docker exec remnanode sh -c 'cat /opt/app/package.json /app/package.json 2>/dev/null' 2>/dev/null \
        | jq -r 'select(.version) | .version' 2>/dev/null | head -n1 || true)"
    fi
  fi
  version="${version:-unknown}"
  runtime_cache_put "$key" "$version"
  printf '%s' "$version"
}

xray_version() {
  node_running || { printf '—'; return 0; }
  local key cached version
  key="xray-version-$(node_cache_key)"
  if cached="$(runtime_cache_get "$key" 0)"; then
    printf '%s' "$cached"
    return 0
  fi
  version="$(node_xray_exec version 2>/dev/null | awk 'NR==1 {print $2}' || true)"
  version="${version:-unknown}"
  runtime_cache_put "$key" "$version"
  printf '%s' "$version"
}

node_api_listening() {
  local port="${NODE_PORT:-2222}"
  ss -H -lnt "( sport = :${port} )" 2>/dev/null | grep -q .
}

# ONLINE | DEGRADED | OFFLINE | NOT INSTALLED | NO DOCKER
node_state() {
  docker_available || { printf 'NO DOCKER'; return 0; }
  node_exists || { printf 'NOT INSTALLED'; return 0; }
  node_running || { printf 'OFFLINE'; return 0; }
  if node_api_listening && xray_running; then
    printf 'ONLINE'
  elif node_api_listening; then
    # API поднят, но Panel ещё не отправила конфиг Xray.
    printf 'WAITING'
  else
    printf 'DEGRADED'
  fi
}

# HEALTHY | DEGRADED | DOWN | NOT INSTALLED
selfsteal_state() {
  docker_available || { printf 'NOT INSTALLED'; return 0; }
  docker inspect nginx-selfsteal >/dev/null 2>&1 || { printf 'NOT INSTALLED'; return 0; }
  local running health
  running="$(docker inspect -f '{{.State.Running}}' nginx-selfsteal 2>/dev/null || true)"
  [[ "$running" == "true" ]] || { printf 'DOWN'; return 0; }
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' nginx-selfsteal 2>/dev/null || true)"
  if [[ -S /dev/shm/nginx.sock && ( "$health" == "healthy" || "$health" == "none" ) ]]; then
    printf 'HEALTHY'
  else
    printf 'DEGRADED'
  fi
}

panel_link_active() {
  local port="${NODE_PORT:-2222}"
  ss -H -tn state established "( sport = :${port} )" 2>/dev/null | grep -q .
}

# Проверка токена кешируется на 60 секунд, чтобы не нагружать панель.
panel_api_status() {
  panel_configured || { printf 'none'; return 0; }
  local cached status
  if cached="$(runtime_cache_get panel.status 60)"; then
    printf '%s' "$cached"
    return 0
  fi
  if ( panel_request GET /api/config-profiles ) 2>/dev/null | jq -e '.response' >/dev/null 2>&1; then
    status="ok"
  else
    status="fail"
  fi
  runtime_cache_put panel.status "$status"
  printf '%s' "$status"
}

# CONNECTED | NO LINK | NOT INSTALLED
panel_state() {
  node_exists || { printf 'NOT INSTALLED'; return 0; }
  # Xray стартует только после получения конфигурации от Panel.
  if panel_link_active || xray_running; then
    printf 'CONNECTED'
  else
    printf 'NO LINK'
  fi
}

# ---------------------------------------------------------------------------
# Метрики сервера
# ---------------------------------------------------------------------------

cpu_usage_percent() {
  local -a a b
  read -r -a a < <(grep '^cpu ' /proc/stat)
  sleep 0.3
  read -r -a b < <(grep '^cpu ' /proc/stat)
  local idle_a=$((a[4] + a[5])) idle_b=$((b[4] + b[5]))
  local total_a=0 total_b=0 i
  for i in 1 2 3 4 5 6 7 8; do
    total_a=$((total_a + ${a[$i]:-0}))
    total_b=$((total_b + ${b[$i]:-0}))
  done
  local total=$((total_b - total_a)) idle=$((idle_b - idle_a))
  ((total > 0)) || { printf '0'; return 0; }
  printf '%d' $(( (100 * (total - idle)) / total ))
}

memory_summary() {
  local total available
  total="$(awk '/^MemTotal:/ {print $2 * 1024}' /proc/meminfo)"
  available="$(awk '/^MemAvailable:/ {print $2 * 1024}' /proc/meminfo)"
  printf '%s / %s' "$(human_bytes $((total - available)))" "$(human_bytes "$total")"
}

swap_summary() {
  local total free
  total="$(awk '/^SwapTotal:/ {print $2 * 1024}' /proc/meminfo)"
  free="$(awk '/^SwapFree:/ {print $2 * 1024}' /proc/meminfo)"
  if ((total == 0)); then
    printf 'нет'
  else
    printf '%s / %s' "$(human_bytes $((total - free)))" "$(human_bytes "$total")"
  fi
}

disk_percent() {
  df -P / 2>/dev/null | awk 'NR==2 {print $5}'
}

load_average() {
  awk '{print $1}' /proc/loadavg
}

uptime_human() {
  local seconds days hours minutes
  seconds="$(awk '{print int($1)}' /proc/uptime)"
  days=$((seconds / 86400))
  hours=$(((seconds % 86400) / 3600))
  minutes=$(((seconds % 3600) / 60))
  if ((days > 0)); then
    printf '%dd %dh' "$days" "$hours"
  else
    printf '%dh %dm' "$hours" "$minutes"
  fi
}

docker_state() {
  command -v docker >/dev/null 2>&1 || { printf 'NOT INSTALLED'; return 0; }
  if systemctl is-active --quiet docker 2>/dev/null; then
    printf 'RUNNING'
  else
    printf 'STOPPED'
  fi
}

is_public_ipv4() {
  local ip="$1" a b c d
  IFS=. read -r a b c d <<<"$ip"
  [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
  ((a == 0 || a == 10 || a == 127 || a >= 224)) && return 1
  ((a == 100 && b >= 64 && b <= 127)) && return 1
  ((a == 169 && b == 254)) && return 1
  ((a == 172 && b >= 16 && b <= 31)) && return 1
  ((a == 192 && b == 168)) && return 1
  ((a == 198 && (b == 18 || b == 19))) && return 1
  return 0
}

is_public_ipv6() {
  local ip="${1,,}"
  [[ "$ip" == *:* ]] || return 1
  [[ "$ip" == ::1 || "$ip" == :: || "$ip" == fe[89ab]* || "$ip" == f[cd]* ]] && return 1
  return 0
}

# Сначала адреса интерфейсов; при NAT — внешний сервис (результат кешируется на час).
public_ipv4() {
  local ip cached
  while read -r ip; do
    is_public_ipv4 "$ip" && { printf '%s' "$ip"; return 0; }
  done < <(ip -o -4 addr show scope global 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4}')
  if cached="$(runtime_cache_get public.ipv4 3600)"; then
    printf '%s' "$cached"
    return 0
  fi
  ip="$(curl -4 -fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)"
  is_public_ipv4 "$ip" || ip=""
  runtime_cache_put public.ipv4 "$ip"
  printf '%s' "$ip"
}

public_ipv6() {
  local ip
  while read -r ip; do
    is_public_ipv6 "$ip" && { printf '%s' "$ip"; return 0; }
  done < <(ip -o -6 addr show scope global 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4}')
  return 0
}

state_color() {
  case "$1" in
    ONLINE|RUNNING|HEALTHY|CONNECTED|ACTIVE) printf '%s' "$C_GREEN" ;;
    DEGRADED|WAITING|"NO LINK"|STOPPED|DOWN) printf '%s' "$C_YELLOW" ;;
    OFFLINE|FAILED) printf '%s' "$C_RED" ;;
    *) printf '%s' "$C_GRAY" ;;
  esac
}

status_line() {
  local name="$1" state="$2" extra="${3:-}" color
  color="$(state_color "$state")"
  printf ' %b●%b %-11s %b%-14s%b %s\n' "$color" "$C_RESET" "$name" "$color" "$state" "$C_RESET" "$extra"
}

print_header() {
  # Docker мог быть установлен в предыдущем действии меню.
  DOCKER_AVAILABLE_CACHE=""
  load_state 2>/dev/null || true
  local node selfsteal panel docker_s cpu mem disk load up ipv4 ipv6 xray_state panel_extra site_extra days

  node="$(node_state)"
  if xray_running; then xray_state="RUNNING"; else xray_state="STOPPED"; fi
  [[ "$node" == "NOT INSTALLED" || "$node" == "NO DOCKER" ]] && xray_state="N/A"
  selfsteal="$(selfsteal_state)"
  panel="$(panel_state)"
  docker_s="$(docker_state)"
  cpu="$(cpu_usage_percent)"
  mem="$(memory_summary)"
  disk="$(disk_percent)"
  load="$(load_average)"
  up="$(uptime_human)"
  ipv4="$(public_ipv4)"
  ipv6="$(public_ipv6)"

  site_extra="nginx"
  if [[ "$selfsteal" != "NOT INSTALLED" ]]; then
    [[ -n "${SITE_TEMPLATE:-}" ]] && site_extra+=" · ${SITE_TEMPLATE}"
    if days="$(cert_days_left 2>/dev/null)"; then
      site_extra+=" · SSL ${days}d"
    fi
  else
    site_extra=""
  fi

  panel_extra=""
  case "$(panel_api_status)" in
    ok) panel_extra="API ✓" ;;
    fail) panel_extra="API ✗" ;;
  esac

  echo -e "${C_BOLD}${C_CYAN}RemnaNode Manager${C_RESET} ${C_GRAY}v${SCRIPT_VERSION}${C_RESET}   ${C_GRAY}$(hostname 2>/dev/null) · ${INSTALL_MODE:-not installed}${C_RESET}"
  echo -e "${C_GRAY}──────────────────────────────────────────────────────────────${C_RESET}"
  status_line "Node" "$node" "Ver: $(node_version)"
  status_line "Xray" "$xray_state" "Ver: $(xray_version)"
  status_line "Selfsteal" "$selfsteal" "$site_extra"
  status_line "Panel" "$panel" "$panel_extra"
  echo
  printf ' %-5s %-9s %-4s %-19s %-4s %s\n' "CPU" "${cpu}%" "RAM" "$mem" "Disk" "${disk:-?}"
  printf ' %-5s %-9s %-6s %-17s %-6s %b%s%b\n' "Load" "$load" "Uptime" "$up" "Docker" "$(state_color "$docker_s")" "$docker_s" "$C_RESET"
  echo
  printf ' %-5s %s\n' "IPv4" "${ipv4:-— нет}"
  printf ' %-5s %s\n' "IPv6" "${ipv6:-— нет}"
  echo -e "${C_GRAY}──────────────────────────────────────────────────────────────${C_RESET}"
}

# ---------------------------------------------------------------------------
# Управление Node: версии, обновление, откат
# ---------------------------------------------------------------------------

require_compose() {
  load_state
  [[ -f "$NODE_COMPOSE_FILE" ]] || die "Compose-файл Node отсутствует: ${NODE_COMPOSE_FILE}"
}

# Digest текущего образа — позволяет откатиться даже с тега latest.
node_current_digest_ref() {
  local image_id digest
  image_id="$(docker inspect -f '{{.Image}}' remnanode 2>/dev/null || true)"
  [[ -n "$image_id" ]] || return 1
  digest="$(docker image inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$image_id" 2>/dev/null \
    | grep -m1 "^${NODE_IMAGE_REPO}@sha256:" || true)"
  [[ -n "$digest" ]] || return 1
  printf '%s' "$digest"
}

node_list_tags() {
  info "Получаю список тегов ${NODE_IMAGE_REPO} с Docker Hub..."
  curl -fsS --max-time 15 \
    "https://hub.docker.com/v2/repositories/${NODE_IMAGE_REPO}/tags?page_size=60&ordering=last_updated" \
    | jq -r '.results[] | "\(.name)\t\(.last_updated[0:10])"' \
    | grep -E '^(latest|dev|v?[0-9]+\.[0-9]+(\.[0-9]+)?)\b' \
    | head -n 25
}

node_wait_healthy() {
  local state=""
  for _ in {1..20}; do
    state="$(node_state)"
    [[ "$state" == "ONLINE" || "$state" == "WAITING" ]] && return 0
    sleep 3
  done
  return 1
}

node_apply_image() {
  local new_image="$1"
  validate_image_ref "$new_image" || die "Некорректный image: ${new_image}"

  local previous
  previous="$(node_current_digest_ref || node_image_ref)"

  info "Текущий образ: ${previous:-unknown}"
  info "Новый образ:   ${new_image}"

  docker pull "$new_image" || die "Не удалось скачать ${new_image}."
  compose_edit set-image "$new_image"

  NODE_PREV_IMAGE="$previous"
  NODE_IMAGE="$new_image"
  save_state

  manager_compose up -d --remove-orphans "$NODE_SERVICE_NAME"

  if node_wait_healthy; then
    ok "Node запущена на ${new_image} (версия $(node_version))."
  else
    err "Node не перешла в рабочее состояние."
    if [[ -n "$previous" ]] && confirm "Откатиться на ${previous}?"; then
      node_rollback
    fi
  fi
}

node_update() {
  require_compose
  local current previous
  current="$(compose_node_image || printf '%s' "$NODE_IMAGE")"
  previous="$(node_current_digest_ref || true)"

  info "Обновляю образы (${current})..."
  manager_compose pull
  manager_compose up -d --remove-orphans

  if [[ -n "$previous" ]]; then
    local now
    now="$(node_current_digest_ref || true)"
    if [[ "$now" != "$previous" ]]; then
      NODE_PREV_IMAGE="$previous"
      save_state
      info "Для отката сохранён предыдущий digest: ${previous}"
    else
      ok "Node уже на последней версии для ${current}."
    fi
  fi

  verify_basic
}

node_select_version() {
  require_compose
  echo
  node_list_tags | awk -F'\t' '{printf "  %-16s %s\n", $1, $2}' || warn "Не удалось получить теги с Docker Hub."
  echo
  local tag
  read -r -p "Тег образа (например 2.1.3 или latest): " tag
  [[ -n "$tag" ]] || return 0
  validate_image_tag "$tag" || die "Некорректный тег."
  node_apply_image "${NODE_IMAGE_REPO}:${tag}"
}

node_rollback() {
  require_compose
  [[ -n "$NODE_PREV_IMAGE" ]] || die "Нет сохранённой предыдущей версии для отката."
  info "Откат на ${NODE_PREV_IMAGE}"
  node_apply_image "$NODE_PREV_IMAGE"
}

node_pin_current() {
  require_compose
  local digest
  digest="$(node_current_digest_ref)" || die "Не удалось определить digest текущего образа."
  confirm "Закрепить текущую версию (${digest})? Обновления перестанут менять образ." || return 0
  compose_edit set-image "$digest"
  NODE_IMAGE="$digest"
  save_state
  ok "Версия закреплена."
}

node_restart() {
  require_compose
  manager_compose restart "$NODE_SERVICE_NAME"
  node_wait_healthy && ok "Node перезапущена." || warn "Node перезапущена, но ещё не в состоянии ONLINE."
}

node_stop() {
  require_compose
  confirm_no_default "Остановить Node? Клиенты будут отключены." || return 0
  manager_compose stop "$NODE_SERVICE_NAME"
}

node_start() {
  require_compose
  manager_compose up -d
}

node_show_status() {
  load_state
  echo -e "${C_BOLD}RemnaNode${C_RESET}"
  echo "Состояние:     $(node_state)"
  echo "Версия:        $(node_version)"
  echo "Образ:         $(node_image_ref)"
  echo "Digest:        $(node_current_digest_ref 2>/dev/null || echo '—')"
  echo "Для отката:    ${NODE_PREV_IMAGE:-—}"
  echo "Xray:          $(xray_version)"
  echo "NODE_PORT:     ${NODE_PORT}"
  echo "Compose:       ${NODE_COMPOSE_FILE}"
  echo
  [[ -f "$NODE_COMPOSE_FILE" ]] && manager_compose ps 2>/dev/null || true
}

node_menu() {
  while true; do
    clear || true
    print_header
    echo -e "${C_BOLD}Управление Node${C_RESET}"
    echo
    echo "1. Подробный статус"
    echo "2. Перезапустить Node"
    echo "3. Остановить / 4. Запустить"
    echo "5. Обновить до последней версии текущего тега"
    echo "6. Выбрать версию (тег Docker Hub)"
    echo "7. Откатиться на предыдущую версию"
    echo "8. Закрепить текущую версию по digest"
    echo "9. Логи Node (последние 100 строк)"
    echo
    echo "0. Назад"
    echo
    local choice
    read -r -p "Выбор: " choice
    case "$choice" in
      1) run_action node_show_status; pause ;;
      2) run_action node_restart; pause ;;
      3) run_action node_stop; pause ;;
      4) run_action node_start; pause ;;
      5) run_action node_update; pause ;;
      6) run_action node_select_version; pause ;;
      7) run_action node_rollback; pause ;;
      8) run_action node_pin_current; pause ;;
      9) docker logs --tail 100 remnanode 2>&1 | less -R +G || true ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Модули: загрузка по требованию
# ---------------------------------------------------------------------------

# Модуль ищется рядом со скриптом (клон репозитория), затем в каталоге
# установленной команды remnanode, затем скачивается из GitHub во временный
# кеш. Версия модуля должна совпадать с версией ядра.
RNM_MODULES_LOADED=" "

module_version_ok() {
  grep -qx "RNM_MODULE_VERSION=\"${SCRIPT_VERSION}\"" "$1" 2>/dev/null
}

# Кеш скачанных модулей живёт один запуск скрипта: при каждом запуске через
# curl модули скачиваются заново и соответствуют текущему main, даже если
# версия не менялась. Подоболочки run_action наследуют ID сессии.
RNM_SESSION="${RNM_SESSION:-$$}"

module_cache_cleanup() {
  [[ -d "${RUNTIME_CACHE}/modules" ]] || return 0
  find "${RUNTIME_CACHE}/modules" -mindepth 1 -maxdepth 1 -type d -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
}

module_path() {
  local name="$1" dir file cache_dir tmp
  local -a dirs=("${SCRIPT_DIR}/modules")
  # Модули установленной команды — только для неё самой: ядро, запущенное
  # через curl, не должно подхватывать устаревшие модули той же версии.
  [[ "$SCRIPT_DIR" == "$(dirname "$RNM_COMMAND_PATH")" ]] && dirs+=("$RNM_LIB_DIR")
  for dir in "${dirs[@]}"; do
    file="${dir}/${name}.sh"
    if [[ -f "$file" ]] && module_version_ok "$file"; then
      printf '%s' "$file"
      return 0
    fi
  done

  cache_dir="${RUNTIME_CACHE}/modules/session-${RNM_SESSION}"
  file="${cache_dir}/${name}.sh"
  if [[ -f "$file" ]] && module_version_ok "$file"; then
    printf '%s' "$file"
    return 0
  fi

  mkdir -p "$cache_dir" && chmod 700 "${RUNTIME_CACHE}/modules" "$cache_dir" 2>/dev/null || true
  tmp="$(mktemp "${cache_dir}/.${name}.XXXXXX")" || return 1
  if ! curl --proto '=https' --tlsv1.2 -fsSL "${RNM_RAW_URL}/modules/${name}.sh" -o "$tmp"; then
    rm -f "$tmp"
    err "Не удалось скачать модуль ${name} из ${RNM_REPO}@${RNM_REF}."
    return 1
  fi
  if ! bash -n "$tmp" || ! module_version_ok "$tmp"; then
    rm -f "$tmp"
    err "Модуль ${name} не совпадает с версией ${SCRIPT_VERSION}. Обнови скрипт (или команду remnanode)."
    return 1
  fi
  mv -f "$tmp" "$file"
  printf '%s' "$file"
}

load_module() {
  local name="$1" file
  [[ "$RNM_MODULES_LOADED" == *" ${name} "* ]] && return 0
  [[ "$name" =~ ^[a-z0-9-]+$ ]] || die "Некорректное имя модуля: ${name}"
  file="$(module_path "$name")" || die "Модуль ${name} недоступен."
  # shellcheck source=/dev/null
  source "$file"
  RNM_MODULES_LOADED+="${name} "
}

# Загружает модуль и открывает его меню. Если модуль недоступен (нет сети,
# несовпадение версии), остаёмся в главном меню.
open_module_menu() {
  local module="$1" menu="$2"
  if ( load_module "$module" ) >/dev/null; then
    load_module "$module"
    "$menu"
  else
    pause
  fi
}

# Загружает модуль и вызывает его функцию (для run_action).
with_module() {
  local module="$1"
  shift
  load_module "$module"
  "$@"
}

# Скачивает сторонний установщик во временный файл, показывает источник и
# sha256 и запускает только после подтверждения.
run_remote_installer() {
  local url="$1"
  shift
  local tmp
  tmp="$(mktemp /tmp/remnanode-module.XXXXXX.sh)"
  curl --proto '=https' --tlsv1.2 -fsSL "$url" -o "$tmp" || { rm -f "$tmp"; die "Не удалось скачать ${url}"; }
  bash -n "$tmp" || { rm -f "$tmp"; die "Скачанный скрипт не прошёл проверку синтаксиса."; }
  echo
  info "Источник: ${url}"
  info "SHA256:   $(sha256sum "$tmp" | cut -d' ' -f1)"
  warn "Это сторонний скрипт; он будет выполнен от root."
  if ! confirm "Запустить установщик?"; then
    rm -f "$tmp"
    return 1
  fi
  local status=0
  bash "$tmp" "$@" || status=$?
  rm -f "$tmp"
  return "$status"
}

# Включает/выключает outbound модуля в профиле без удаления самого модуля.
toggle_outbound() {
  local variable="$1"
  load_state
  if [[ "${!variable}" == "1" ]]; then
    printf -v "$variable" '%s' 0
  else
    printf -v "$variable" '%s' 1
  fi
  [[ "$WARP_OUTBOUND" != "1" && "$RU_POLICY" == "warp" ]] && RU_POLICY="block"
  save_state
  ok "${variable}=${!variable}"
  generate_xray_profile 1
}

# ---------------------------------------------------------------------------
# Сценарии установки
# ---------------------------------------------------------------------------

prompt_domain_and_site() {
  local default_domain="${1:-}"

  local domain_input
  read -r -p "Домен ноды${default_domain:+ [${default_domain}]}: " domain_input
  DOMAIN="${domain_input:-$default_domain}"
  validate_domain "$DOMAIN" || die "Некорректный домен: ${DOMAIN}"

  local email_input
  read -r -p "Email Let's Encrypt/acme.sh${ACME_EMAIL:+ [${ACME_EMAIL}]}: " email_input
  ACME_EMAIL="${email_input:-$ACME_EMAIL}"
  validate_email "$ACME_EMAIL" || die "Некорректный email."

  local dir
  load_module sites
  dir="$(templates_dir)" || die "Каталог шаблонов недоступен."
  SITE_TEMPLATE="$(select_template "$dir")"
  prompt_brand "$SERVICE_NAME"
}

offer_geo_routing() {
  echo
  info "Routing: РФ + белые списки → напрямую у клиента, торренты → блок, остальное → прокси."
  if confirm "Подключить roscomvpn geosite/geoip на ноде (ежедневное автообновление)?"; then
    load_module routing
    geo_enable || warn "Geo не подключён — используются встроенные geosite/geoip."
  fi
}

install_node_basic() {
  ensure_fresh_install_target
  prompt_secret_and_panel
  install_base_packages
  validate_panel_network "$PANEL_IP" || die "Некорректный IP или CIDR сервера панели: ${PANEL_IP}"
  install_docker

  ensure_base_dirs

  INSTALL_MODE="basic"
  DOMAIN=""
  SERVICE_NAME=""
  ACME_EMAIL=""
  SITE_TEMPLATE=""

  RAW_ENABLED="0"
  XHTTP_ENABLED="0"
  HY2_ENABLED="0"

  ensure_selected_ports_free

  write_basic_compose
  configure_firewall "basic"

  start_stack
  verify_basic
  save_state

  ok "Remna Node установлена."
  offer_geo_routing
  generate_xray_profile 1 || true
  echo
  warn "Inbound'ы для этой ноды настраиваются в Panel. Routing-профиль ${PROFILE_FILE} можно применить к профилю панели режимом merge (меню Panel API)."
}

install_node_selfsteal() {
  ensure_fresh_install_target
  prompt_secret_and_panel

  ACME_EMAIL=""
  prompt_domain_and_site ""

  echo
  prompt_inbounds

  install_base_packages
  validate_panel_network "$PANEL_IP" || die "Некорректный IP или CIDR сервера панели: ${PANEL_IP}"
  install_docker
  ensure_base_dirs

  validate_selected_port_plan
  ensure_selected_ports_free

  INSTALL_MODE="selfsteal"

  deploy_site "$SITE_TEMPLATE" "$DOMAIN"
  write_nginx_conf "$DOMAIN"
  write_selfsteal_compose
  save_state

  tune_hysteria_udp

  configure_firewall "selfsteal"

  issue_certificate "$DOMAIN" "$ACME_EMAIL"

  start_stack
  verify_basic
  verify_selfsteal_local

  save_state
  offer_geo_routing
  generate_xray_profile 1
  save_state

  echo
  ok "Remna Node + SSL + Selfsteal установлена."
  echo
  echo "Generated profile: ${PROFILE_FILE}"
  echo "Connection info:    ${PROFILE_INFO}"
  echo
  warn "Следующий шаг: добавь ${PROFILE_FILE} в Remnawave Panel (или меню «Remnawave Panel API») и назначь профиль этой ноде."
}

install_selfsteal_for_existing_node() {
  command -v docker >/dev/null 2>&1 || die "Docker не установлен. Существующая RemnaNode не найдена."
  docker compose version >/dev/null 2>&1 || die "Docker Compose не установлен."
  detect_os

  detect_existing_compose
  prompt_panel_network

  ACME_EMAIL=""
  prompt_domain_and_site ""

  echo
  prompt_inbounds

  install_base_packages
  validate_panel_network "$PANEL_IP" || die "Некорректный IP или CIDR сервера панели: ${PANEL_IP}"
  ensure_base_dirs
  validate_selected_port_plan

  INSTALL_MODE="selfsteal-existing"

  deploy_site "$SITE_TEMPLATE" "$DOMAIN"
  write_nginx_conf "$DOMAIN"
  compose_edit selfsteal-add
  save_state

  tune_hysteria_udp
  configure_firewall "selfsteal"
  issue_certificate "$DOMAIN" "$ACME_EMAIL"

  start_stack
  verify_basic
  verify_selfsteal_local

  save_state
  offer_geo_routing
  generate_xray_profile 1
  save_state

  echo
  ok "SSL / Selfsteal добавлен к существующей RemnaNode."
  echo "Compose:            ${NODE_COMPOSE_FILE}"
  echo "Generated profile:  ${PROFILE_FILE}"
  echo "Connection info:    ${PROFILE_INFO}"
  echo
  warn "Следующий шаг: добавь ${PROFILE_FILE} в Remnawave Panel и назначь профиль этой ноде."
}

configure_inbounds_existing() {
  load_state

  is_selfsteal_mode || die "Inbound manager доступен после установки режима SSL/Selfsteal."

  prompt_inbounds
  validate_selected_port_plan
  tune_hysteria_udp

  configure_firewall "selfsteal"
  generate_xray_profile 1
  save_state

  warn "Manager только генерирует профиль. Его нужно сохранить/запушить в Remnawave Panel."
}

change_domain() {
  load_state

  is_selfsteal_mode || die "Домен не настроен этим manager."

  local old_domain="$DOMAIN"
  local domain_input email_input

  echo "Текущий домен: ${old_domain}"
  read -r -p "Новый домен [${old_domain}]: " domain_input
  DOMAIN="${domain_input:-$old_domain}"
  validate_domain "$DOMAIN" || die "Некорректный домен: ${DOMAIN}"

  if [[ "$DOMAIN" == "$old_domain" ]]; then
    warn "Изменений нет."
    return 0
  fi

  read -r -p "Email Let's Encrypt [${ACME_EMAIL}]: " email_input
  ACME_EMAIL="${email_input:-$ACME_EMAIL}"
  validate_email "$ACME_EMAIL" || die "Некорректный email."

  check_domain_dns "$DOMAIN"
  issue_certificate "$DOMAIN" "$ACME_EMAIL"

  write_nginx_conf "$DOMAIN"
  load_module sites
  deploy_site "${SITE_TEMPLATE:-}" "$DOMAIN"
  generate_xray_profile 1
  save_state

  docker restart nginx-selfsteal >/dev/null 2>&1 || true

  if [[ -x "$ACME_BIN" ]] && confirm "Убрать старый ${old_domain} из acme.sh auto-renew?"; then
    "$ACME_BIN" --remove -d "$old_domain" --ecc || true
  fi

  ok "Домен изменён."
  warn "Обнови serverNames/SNI в Remnawave Panel новым profile."
}

ssl_menu() {
  load_state

  is_selfsteal_mode || die "SSL/Selfsteal не настроен."

  while true; do
    clear || true
    echo -e "${C_BOLD}Домен и SSL / acme.sh${C_RESET}"
    echo
    echo "Domain: ${DOMAIN}   Осталось дней: $(cert_days_left 2>/dev/null || echo '?')"
    echo
    echo "1. Показать сертификат"
    echo "2. Renew если пора"
    echo "3. Принудительный renew"
    echo "4. Повторно установить сертификат в /opt/remnanode/ssl"
    echo "5. Показать acme.sh --info"
    echo "6. Изменить домен"
    echo
    echo "0. Назад"
    echo

    local choice
    read -r -p "Выбор: " choice

    case "$choice" in
      1)
        openssl x509 -in "${BASE_DIR}/ssl/fullchain.pem" \
          -noout -subject -issuer -dates -ext subjectAltName || true
        pause
        ;;
      2) run_action renew_certificate "0"; pause ;;
      3) run_action renew_certificate "1"; pause ;;
      4) run_action install_cert_files "$DOMAIN"; pause ;;
      5) "$ACME_BIN" --info -d "$DOMAIN" --ecc || true; pause ;;
      6) run_action change_domain; load_state; pause ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}

remove_node() {
  load_state

  if [[ "$INSTALL_MODE" == "selfsteal-existing" ]]; then
    warn "Будет удалён Selfsteal/Nginx. Существующая RemnaNode и её Compose-файл останутся на месте."
  else
    warn "Будут остановлены контейнеры RemnaNode/Nginx и при подтверждении удалён ${BASE_DIR}."
  fi
  echo
  local token
  read -r -p "Для продолжения введи DELETE: " token
  [[ "$token" == "DELETE" ]] || {
    warn "Отменено."
    return 0
  }

  if [[ "$INSTALL_MODE" == "selfsteal-existing" ]]; then
    docker rm -f nginx-selfsteal >/dev/null 2>&1 || true
    compose_edit selfsteal-remove
    manager_compose up -d "$NODE_SERVICE_NAME" || true
  elif [[ -f "$NODE_COMPOSE_FILE" ]]; then
    manager_compose down --remove-orphans || true
  fi

  if is_selfsteal_mode && [[ -n "$DOMAIN" && -x "$ACME_BIN" ]]; then
    if confirm "Убрать ${DOMAIN} из списка renew acme.sh?"; then
      "$ACME_BIN" --remove -d "$DOMAIN" --ecc || true
    fi
  fi

  rm -f "$RELOAD_HELPER"
  rm -f /etc/sysctl.d/99-remnanode-hysteria.conf
  sysctl --system >/dev/null 2>&1 || true

  if [[ "$INSTALL_MODE" != "selfsteal-existing" ]]; then
    systemctl disable --now remnanode-geo-update.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/remnanode-geo-update.{service,timer} "$GEO_UPDATER"
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  if [[ -f "$UFW_STATE_FILE" ]] || ufw status 2>/dev/null | grep -q remnanode-manager; then
    remove_managed_ufw_rules
    ufw reload >/dev/null 2>&1 || true
    ok "Управляемые правила UFW удалены."
  fi

  if [[ "$INSTALL_MODE" == "selfsteal-existing" ]]; then
    rm -f \
      "$STATE_FILE" \
      "$REALITY_FILE" \
      "$UFW_STATE_FILE" \
      "${BASE_DIR}/nginx.conf" \
      "$PROFILE_FILE" \
      "$PROFILE_INFO"
    ok "Selfsteal отключён; существующая Node и её данные сохранены."
  elif confirm_no_default "Удалить все файлы ${BASE_DIR} (включая бэкапы)?"; then
    rm -rf "$BASE_DIR"
  fi

  warn "Docker, WARP/Psiphon/Tor/Zapret2 и общие правила UFW/SSH не удалялись. Правила с меткой remnanode-manager удалены."
  ok "Удаление завершено."
}

profile_menu() {
  while true; do
    clear || true
    load_state
    print_header
    echo -e "${C_BOLD}Xray profile и inbound'ы${C_RESET}"
    echo
    echo "RAW: $([[ "$RAW_ENABLED" == 1 ]] && echo "${RAW_PORT}/tcp" || echo выкл)   XHTTP: $([[ "$XHTTP_ENABLED" == 1 ]] && echo "${XHTTP_PORT}/tcp ${XHTTP_MODE}" || echo выкл)   Hysteria2: $([[ "$HY2_ENABLED" == 1 ]] && echo "${HY2_PORT}/udp" || echo выкл)"
    echo
    echo "1. Параметры подключения (profile-info)"
    echo "2. Показать JSON профиля"
    echo "3. Настроить inbound'ы заново"
    echo "4. Пересобрать профиль"
    echo "5. Проверить профиль Xray внутри ноды"
    echo "6. Отправить профиль в Panel"
    echo "7. Сгенерировать новую Reality keypair"
    echo "8. Сгенерировать новые Short IDs"
    echo "9. Проверить Hysteria2"
    echo "10. Hysteria2: обфускация Salamander вкл/выкл"
    echo
    echo "0. Назад"
    echo
    local choice
    read -r -p "Выбор: " choice
    case "$choice" in
      1) run_action show_profile_info; pause ;;
      2) run_action print_profile_json | less -R || true ;;
      3) run_action configure_inbounds_existing; pause ;;
      4) run_action generate_xray_profile; pause ;;
      5) run_action validate_generated_profile; pause ;;
      6) run_action with_module panel panel_push_profile; pause ;;
      7) run_action rotate_reality_keys; pause ;;
      8) run_action regenerate_short_ids; pause ;;
      9) run_action with_module monitor hy2_diagnose; pause ;;
      10) run_action with_module monitor hy2_toggle_obfs; pause ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Главное меню и CLI
# ---------------------------------------------------------------------------

show_menu() {
  clear || true
  print_header
  cat <<'EOF'
 УСТАНОВКА                               NODE
  1. RemnaNode (только нода)              5. Управление Node: версии, обновление, откат
  2. RemnaNode + Selfsteal + SSL          6. Xray profile, inbound'ы, Reality
  3. Selfsteal к установленной Node       7. Домен и SSL
  4. Удалить стек / Selfsteal             8. Сайт-заглушка: шаблоны и отпечаток

 ROUTING И МОДУЛИ                        СЕРВЕР
  9. Routing: roscomvpn, РФ, торренты    15. Мониторинг и логи
 10. WARP                                16. Администрирование
 11. Psiphon                             17. Бэкапы
 12. Tor
 13. Zapret2
 14. Remnawave Panel API

  0. Выход
EOF
  echo
}

main_menu() {
  touch "$INSTALL_LOG" 2>/dev/null || true
  chmod 600 "$INSTALL_LOG" 2>/dev/null || true
  mkdir -p "$RUNTIME_CACHE" 2>/dev/null || true
  module_cache_cleanup

  while true; do
    show_menu

    local choice
    read -r -p "Выбери пункт: " choice || exit 0

    case "$choice" in
      1) run_action install_node_basic; pause ;;
      2) run_action install_node_selfsteal; pause ;;
      3) run_action install_selfsteal_for_existing_node; pause ;;
      4) run_action remove_node; pause ;;
      5) node_menu ;;
      6) profile_menu ;;
      7) run_action ssl_menu ;;
      8) open_module_menu sites site_menu ;;
      9) open_module_menu routing routing_menu ;;
      10) open_module_menu warp warp_menu ;;
      11) open_module_menu psiphon psiphon_menu ;;
      12) open_module_menu tor tor_menu ;;
      13) open_module_menu zapret zapret_menu ;;
      14) open_module_menu panel panel_menu ;;
      15) open_module_menu monitor monitoring_menu ;;
      16) open_module_menu admin admin_menu ;;
      17) open_module_menu admin backup_menu ;;
      0|q|Q) exit 0 ;;
      *) ;;
    esac
  done
}

usage() {
  cat <<EOF
RemnaNode Manager ${SCRIPT_VERSION}

Использование: install.sh [КОМАНДА]

  menu              интерактивное меню (по умолчанию)
  status            шапка со статусом Node/Xray/Selfsteal/Panel и метриками
  install-command   установить команду remnanode в /usr/local/bin
  geo-update        обновить roscomvpn geo-файлы
  site-refresh      перегенерировать сайт-заглушку с новым отпечатком
  profile           пересобрать Xray profile
  help              эта справка
EOF
}

main() {
  local command="${1:-menu}"

  case "$command" in
    help|-h|--help) usage; return 0 ;;
  esac

  require_root
  detect_os

  case "$command" in
    menu) ensure_runtime_tools; main_menu ;;
    status) print_header ;;
    install-command|install-manager) load_module admin; install_command ;;
    geo-update) load_module routing; geo_update_now ;;
    site-refresh) load_module sites; load_state; deploy_site "${SITE_TEMPLATE:-}" "$DOMAIN" ;;
    profile) generate_xray_profile ;;
    *) usage >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
