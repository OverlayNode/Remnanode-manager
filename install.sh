#!/usr/bin/env bash
set -Eeuo pipefail

# Remnawave Node Manager
# Generic bootstrap/management script for Ubuntu/Debian Remnawave nodes.
#
# Features:
# - RemnaNode install/update/remove
# - Docker + UFW bootstrap
# - acme.sh SSL issuance/renewal
# - Nginx selfsteal via /dev/shm/nginx.sock
# - Generic cloud landing page (no credential submission)
# - VLESS RAW + REALITY
# - VLESS XHTTP + REALITY
# - Hysteria2 (Xray "hysteria", version 2)
# - diagnostics and generated Remnawave Xray profile
#
# Run as root.

SCRIPT_VERSION="2.0.0"

BASE_DIR="/opt/remnanode"
STATE_FILE="${BASE_DIR}/installer.conf"
ENV_FILE="${BASE_DIR}/.env"
REALITY_FILE="${BASE_DIR}/reality.env"
PROFILE_DIR="${BASE_DIR}/profiles"
PROFILE_FILE="${PROFILE_DIR}/xray-profile.json"
PROFILE_INFO="${PROFILE_DIR}/profile-info.txt"

NODE_PORT="2222"
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
C_BOLD='\033[1m'

# Runtime defaults. State file overrides these when it exists.
INSTALL_MODE=""
DOMAIN=""
SERVICE_NAME=""
ACME_EMAIL=""
PANEL_IP=""

RAW_ENABLED="0"
RAW_PORT="443"

XHTTP_ENABLED="0"
XHTTP_PORT="8443"
XHTTP_MODE="stream-one"
XHTTP_PATH=""

HY2_ENABLED="0"
HY2_PORT="443"

REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
RAW_SHORT_ID=""
XHTTP_SHORT_ID=""

log() {
  printf '%b\n' "$*" | tee -a "$INSTALL_LOG"
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
  read -r -p "Нажми Enter для продолжения..." _
}

confirm() {
  local prompt="${1:-Продолжить?}"
  local answer
  read -r -p "$prompt [Y/n]: " answer
  case "${answer:-Y}" in
    Y|y|YES|yes|Yes|Д|д) return 0 ;;
    *) return 1 ;;
  esac
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

validate_service_name() {
  local value="$1"
  # Deliberately restrictive because the value is written to HTML.
  [[ "$value" =~ ^[[:alnum:]][[:alnum:]\ ._-]{0,79}$ ]]
}

validate_xhttp_path() {
  local value="$1"
  [[ "$value" =~ ^/[A-Za-z0-9._~:/@%+,-]{1,180}$ ]]
}

backup_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    cp -a "$file" "${file}.backup-${stamp}"
    info "Backup: ${file}.backup-${stamp}"
  fi
}

shell_quote() {
  printf '%q' "$1"
}

save_state() {
  mkdir -p "$BASE_DIR"
  umask 077
  {
    printf 'SCRIPT_VERSION=%q\n' "$SCRIPT_VERSION"
    printf 'INSTALL_MODE=%q\n' "$INSTALL_MODE"
    printf 'DOMAIN=%q\n' "$DOMAIN"
    printf 'SERVICE_NAME=%q\n' "$SERVICE_NAME"
    printf 'ACME_EMAIL=%q\n' "$ACME_EMAIL"
    printf 'PANEL_IP=%q\n' "$PANEL_IP"
    printf 'NODE_PORT=%q\n' "$NODE_PORT"

    printf 'RAW_ENABLED=%q\n' "$RAW_ENABLED"
    printf 'RAW_PORT=%q\n' "$RAW_PORT"

    printf 'XHTTP_ENABLED=%q\n' "$XHTTP_ENABLED"
    printf 'XHTTP_PORT=%q\n' "$XHTTP_PORT"
    printf 'XHTTP_MODE=%q\n' "$XHTTP_MODE"
    printf 'XHTTP_PATH=%q\n' "$XHTTP_PATH"

    printf 'HY2_ENABLED=%q\n' "$HY2_ENABLED"
    printf 'HY2_PORT=%q\n' "$HY2_PORT"
  } > "$STATE_FILE"

  chmod 600 "$STATE_FILE"
}

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
}

save_reality() {
  umask 077
  {
    printf 'REALITY_PRIVATE_KEY=%q\n' "$REALITY_PRIVATE_KEY"
    printf 'REALITY_PUBLIC_KEY=%q\n' "$REALITY_PUBLIC_KEY"
    printf 'RAW_SHORT_ID=%q\n' "$RAW_SHORT_ID"
    printf 'XHTTP_SHORT_ID=%q\n' "$XHTTP_SHORT_ID"
  } > "$REALITY_FILE"
  chmod 600 "$REALITY_FILE"
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
    "$PROFILE_DIR"

  chmod 700 "${BASE_DIR}/ssl"
}

install_base_packages() {
  info "Устанавливаю базовые пакеты..."
  export DEBIAN_FRONTEND=noninteractive

  apt-get update -y
  apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    openssl \
    dnsutils \
    ufw \
    cron \
    iproute2 \
    jq

  systemctl enable --now cron >/dev/null 2>&1 || true
  ok "Базовые пакеты установлены."
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker и Docker Compose уже установлены."
    systemctl enable --now docker >/dev/null 2>&1 || true
    return
  fi

  info "Устанавливаю Docker Engine из официального Docker repository..."

  install -m 0755 -d /etc/apt/keyrings

  if [[ "$OS_ID" == "ubuntu" ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      -o /etc/apt/keyrings/docker.asc

    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${OS_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  else
    curl -fsSL https://download.docker.com/linux/debian/gpg \
      -o /etc/apt/keyrings/docker.asc

    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${OS_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  fi

  chmod a+r /etc/apt/keyrings/docker.asc

  apt-get update -y
  apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  systemctl enable --now docker
  docker compose version >/dev/null
  ok "Docker установлен."
}

prompt_secret_and_panel() {
  echo
  read -r -s -p "SECRET_KEY из Remnawave Panel: " SECRET_KEY
  echo
  [[ -n "$SECRET_KEY" ]] || die "SECRET_KEY не может быть пустым."

  if [[ "$SECRET_KEY" == *"'"* || "$SECRET_KEY" == *$'\n'* ]]; then
    die "SECRET_KEY содержит неподдерживаемый символ."
  fi

  read -r -p "IP/CIDR сервера панели для ${NODE_PORT}/tcp (Enter = открыть всем): " PANEL_IP

  if [[ -z "$PANEL_IP" ]]; then
    warn "${NODE_PORT}/tcp будет открыт для всего интернета."
  fi
}

write_env() {
  umask 077
  cat > "$ENV_FILE" <<EOF
NODE_PORT='${NODE_PORT}'
SECRET_KEY='${SECRET_KEY}'
EOF
  chmod 600 "$ENV_FILE"
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

ufw_allow_if_missing() {
  local rule="$1"
  # shellcheck disable=SC2086
  ufw $rule >/dev/null
}

configure_firewall() {
  local mode="$1"
  local ssh_port
  ssh_port="$(detect_ssh_port)"

  info "Настройка UFW."

  if confirm "Сбросить существующие правила UFW и оставить правила этой ноды?"; then
    ufw --force reset >/dev/null
  else
    warn "Существующие правила UFW будут сохранены."
  fi

  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null

  # User requested OpenSSH/22 to remain reachable.
  ufw allow 22/tcp >/dev/null

  if [[ "$ssh_port" != "22" ]]; then
    ufw allow "${ssh_port}/tcp" >/dev/null
    warn "sshd также слушает ${ssh_port}/tcp — порт сохранён."
  fi

  if [[ -n "$PANEL_IP" ]]; then
    ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp >/dev/null
  else
    ufw allow "${NODE_PORT}/tcp" >/dev/null
  fi

  if [[ "$mode" == "basic" ]]; then
    # Useful default for a later VLESS inbound.
    ufw allow 443/tcp >/dev/null
  else
    # HTTP-01 for acme.sh renewal.
    ufw allow 80/tcp >/dev/null

    if [[ "$RAW_ENABLED" == "1" ]]; then
      ufw allow "${RAW_PORT}/tcp" >/dev/null
    fi

    if [[ "$XHTTP_ENABLED" == "1" ]]; then
      ufw allow "${XHTTP_PORT}/tcp" >/dev/null
    fi

    if [[ "$HY2_ENABLED" == "1" ]]; then
      ufw allow "${HY2_PORT}/udp" >/dev/null
    fi
  fi

  ufw --force enable >/dev/null
  ufw reload >/dev/null

  ok "UFW настроен."
  ufw status verbose
}

write_basic_compose() {
  backup_file "${BASE_DIR}/docker-compose.yml"

  cat > "${BASE_DIR}/docker-compose.yml" <<'EOF'
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
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

    env_file:
      - .env
EOF
}

write_selfsteal_compose() {
  backup_file "${BASE_DIR}/docker-compose.yml"

  cat > "${BASE_DIR}/docker-compose.yml" <<'EOF'
services:
  nginx-selfsteal:
    container_name: nginx-selfsteal
    hostname: nginx-selfsteal
    image: nginx:alpine
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
    image: remnawave/node:latest
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
      # Makes the node-local certificate available to Xray/Hysteria2.
      - /opt/remnanode/ssl:/opt/remnanode/ssl:ro

    env_file:
      - .env
EOF
}

write_nginx_conf() {
  local domain="$1"

  cat > "${BASE_DIR}/nginx.conf" <<EOF
server_names_hash_bucket_size 64;

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_session_timeout 1d;
ssl_session_cache shared:SelfStealSSL:10m;
ssl_session_tickets off;

server {
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;

    server_name ${domain};

    ssl_certificate "/etc/nginx/ssl/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/fullchain.pem";

    root /var/www/html;
    index index.html;

    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header X-Frame-Options "DENY" always;
    add_header Content-Security-Policy "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; font-src 'self'; frame-ancestors 'none'; form-action 'self'" always;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location = /robots.txt {
        access_log off;
    }

    location = /health {
        default_type text/plain;
        return 200 "ok\\n";
    }
}

server {
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol default_server;

    server_name _;

    ssl_reject_handshake on;
    return 444;
}
EOF
}

write_site_files() {
  local domain="$1"
  local service_name="$2"
  local current_year
  current_year="$(date +%Y)"

  mkdir -p "${BASE_DIR}/html"

  cat > "${BASE_DIR}/html/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="robots" content="noindex,nofollow,noarchive">
  <meta name="theme-color" content="#f4f7fb">
  <title>${service_name} Cloud</title>
  <link rel="icon" href="/favicon.svg" type="image/svg+xml">
  <link rel="stylesheet" href="/style.css">
</head>
<body>
  <div class="ambient ambient-a"></div>
  <div class="ambient ambient-b"></div>

  <header class="topbar">
    <a class="brand" href="/" aria-label="${service_name} Cloud">
      <span class="brandmark" aria-hidden="true">
        <svg viewBox="0 0 32 32"><path d="M9.25 23.75h13.6a5.4 5.4 0 0 0 .5-10.77A7.85 7.85 0 0 0 8.5 10.6a6.55 6.55 0 0 0 .75 13.15Z"/></svg>
      </span>
      <span class="brandcopy">
        <strong>${service_name}</strong>
        <small>Cloud</small>
      </span>
    </a>

    <div class="service-status">
      <span class="status-dot"></span>
      All systems operational
    </div>
  </header>

  <main class="layout">
    <section class="hero">
      <span class="eyebrow">SECURE CLOUD WORKSPACE</span>
      <h1>One secure place<br>for your work.</h1>
      <p class="lead">Access private applications, files and managed cloud resources through a protected workspace.</p>

      <div class="gateway-pill">
        <span>Gateway</span>
        <strong>${domain}</strong>
      </div>

      <div class="benefits">
        <article>
          <span class="check">✓</span>
          <div><strong>Protected session</strong><small>Encrypted connection to private resources</small></div>
        </article>
        <article>
          <span class="check">✓</span>
          <div><strong>Managed access</strong><small>Workspace access for authorized users</small></div>
        </article>
        <article>
          <span class="check">✓</span>
          <div><strong>Distributed infrastructure</strong><small>Reliable regional cloud gateways</small></div>
        </article>
      </div>
    </section>

    <section class="auth-card" aria-label="Workspace sign in">
      <div class="card-head">
        <div class="cloud-icon" aria-hidden="true">
          <svg viewBox="0 0 48 48"><path d="M14 35h21a8 8 0 0 0 .8-15.96A12 12 0 0 0 13 15.5 10 10 0 0 0 14 35Z"/></svg>
        </div>
        <h2>Sign in</h2>
        <p>Continue to ${service_name} Cloud</p>
      </div>

      <form id="loginForm" autocomplete="off" novalidate>
        <label for="account">Account</label>
        <div class="field">
          <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8Zm7 8a7 7 0 0 0-14 0"/></svg>
          <input id="account" type="text" autocomplete="off" placeholder="name@company">
        </div>

        <label for="password">Password</label>
        <div class="field">
          <svg viewBox="0 0 24 24" aria-hidden="true"><rect x="5" y="10" width="14" height="10" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/></svg>
          <input id="password" type="password" autocomplete="new-password" placeholder="Enter password">
        </div>

        <div class="form-row">
          <label class="remember"><input type="checkbox"><span>Remember this device</span></label>
          <button class="link-button" type="button" id="helpButton">Need help?</button>
        </div>

        <button class="primary" type="submit">Sign in</button>
      </form>

      <div id="notice" class="notice" role="status" aria-live="polite">
        <span class="notice-icon">i</span>
        <div>
          <strong>Authentication temporarily unavailable</strong>
          <p>This gateway does not accept interactive sign-ins. Contact your workspace administrator.</p>
        </div>
      </div>

      <div class="card-footer">
        <span>${domain}</span>
        <span class="sep">•</span>
        <span>Secure Cloud Gateway</span>
      </div>
    </section>
  </main>

  <footer class="footer">
    <span>© ${current_year} ${service_name} Cloud</span>
    <nav><span>Security</span><span>Privacy</span><span>Status</span></nav>
  </footer>

  <script src="/app.js"></script>
</body>
</html>
EOF

  cat > "${BASE_DIR}/html/style.css" <<'EOF'
:root {
  color-scheme: light;
  --ink: #101828;
  --muted: #667085;
  --faint: #98a2b3;
  --line: #e4e7ec;
  --blue: #315fde;
  --blue-2: #5c82ef;
  --surface: rgba(255,255,255,.80);
  --shadow: 0 30px 80px rgba(16,24,40,.10);
}
* { box-sizing: border-box; }
html, body { margin: 0; min-height: 100%; }
body {
  min-height: 100vh;
  font-family: Inter, ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Arial, sans-serif;
  color: var(--ink);
  background: linear-gradient(135deg,#f5f7fb 0%,#edf3fb 52%,#f8fafc 100%);
  display: flex;
  flex-direction: column;
  overflow-x: hidden;
}
.ambient { position: fixed; border-radius: 50%; filter: blur(22px); pointer-events: none; z-index: 0; }
.ambient-a {
  width: 560px; height: 560px; left: -220px; top: -260px;
  background: radial-gradient(circle,rgba(64,112,245,.20),rgba(64,112,245,0) 70%);
}
.ambient-b {
  width: 650px; height: 650px; right: -260px; bottom: -330px;
  background: radial-gradient(circle,rgba(85,115,220,.14),rgba(85,115,220,0) 70%);
}
.topbar {
  position: relative; z-index: 2; min-height: 78px; padding: 0 42px;
  display: flex; align-items: center; justify-content: space-between;
}
.brand { display: flex; align-items: center; gap: 11px; color: inherit; text-decoration: none; }
.brandmark {
  width: 40px; height: 40px; border-radius: 12px; display: grid; place-items: center;
  background: #111827; box-shadow: 0 8px 20px rgba(17,24,39,.12);
}
.brandmark svg { width: 24px; fill: none; stroke: #fff; stroke-width: 1.7; }
.brandcopy { display: grid; line-height: 1.05; }
.brandcopy strong { font-size: 15px; letter-spacing: -.2px; }
.brandcopy small { margin-top: 4px; font-size: 11px; color: var(--muted); }
.service-status {
  display: inline-flex; align-items: center; gap: 8px; font-size: 12px; color: #475467;
  border: 1px solid rgba(16,24,40,.08); background: rgba(255,255,255,.58);
  padding: 8px 12px; border-radius: 999px; backdrop-filter: blur(14px);
}
.status-dot {
  width: 7px; height: 7px; border-radius: 50%; background: #12b76a;
  box-shadow: 0 0 0 3px rgba(18,183,106,.10);
}
.layout {
  position: relative; z-index: 1; width: 100%; max-width: 1120px; margin: auto;
  padding: 58px 38px 92px; display: grid; grid-template-columns: minmax(0,1fr) 420px;
  gap: 105px; align-items: center;
}
.eyebrow {
  display: inline-flex; padding: 7px 11px; border-radius: 8px;
  background: rgba(49,95,222,.07); color: #3456c5; font-size: 11px;
  font-weight: 750; letter-spacing: .85px;
}
.hero h1 {
  margin: 20px 0 20px; max-width: 600px; font-size: clamp(42px,5vw,64px);
  line-height: 1.02; letter-spacing: -3px; font-weight: 720;
}
.lead { max-width: 520px; margin: 0; color: var(--muted); font-size: 17px; line-height: 1.68; }
.gateway-pill {
  width: fit-content; margin-top: 24px; padding: 9px 12px;
  border: 1px solid rgba(16,24,40,.08); border-radius: 10px;
  background: rgba(255,255,255,.58); font-size: 11px; color: var(--muted);
}
.gateway-pill span { margin-right: 8px; }
.gateway-pill strong { color: #344054; font-weight: 650; }
.benefits { margin-top: 34px; display: grid; gap: 18px; }
.benefits article { display: flex; align-items: flex-start; gap: 12px; }
.check {
  width: 24px; height: 24px; flex: 0 0 24px; display: grid; place-items: center;
  border-radius: 50%; color: #4169e1; background: #e8efff; font-size: 12px; font-weight: 800;
}
.benefits strong, .benefits small { display: block; }
.benefits strong { font-size: 13px; color: #344054; }
.benefits small { margin-top: 4px; font-size: 12px; color: var(--faint); }
.auth-card {
  padding: 34px; border-radius: 23px; border: 1px solid rgba(16,24,40,.08);
  background: var(--surface); box-shadow: var(--shadow); backdrop-filter: blur(22px);
}
.cloud-icon {
  width: 48px; height: 48px; margin-bottom: 20px; border-radius: 14px;
  display: grid; place-items: center; background: linear-gradient(135deg,var(--blue),var(--blue-2));
  box-shadow: 0 10px 25px rgba(49,95,222,.23);
}
.cloud-icon svg { width: 28px; fill: none; stroke: #fff; stroke-width: 1.6; }
.card-head h2 { margin: 0; font-size: 25px; letter-spacing: -.7px; }
.card-head p { margin: 7px 0 28px; font-size: 13px; color: var(--muted); }
form > label { display: block; margin-bottom: 7px; font-size: 12px; font-weight: 650; color: #344054; }
.field { position: relative; margin-bottom: 19px; }
.field svg {
  position: absolute; left: 14px; top: 50%; transform: translateY(-50%);
  width: 17px; fill: none; stroke: var(--faint); stroke-width: 1.7;
}
.field input {
  width: 100%; height: 47px; padding: 0 14px 0 42px; border: 1px solid #d0d5dd;
  border-radius: 10px; outline: none; background: rgba(255,255,255,.9); color: var(--ink);
  font: inherit; font-size: 13px; transition: border-color .15s, box-shadow .15s;
}
.field input:focus { border-color: #6b8bf0; box-shadow: 0 0 0 3px rgba(74,112,226,.11); }
.form-row { margin: 1px 0 22px; display: flex; align-items: center; justify-content: space-between; gap: 12px; }
.remember { display: flex; align-items: center; gap: 7px; color: var(--muted); font-size: 11px; cursor: pointer; }
.remember input { accent-color: var(--blue); }
.link-button { border: 0; padding: 0; background: none; color: #4169e1; font: inherit; font-size: 11px; cursor: pointer; }
.primary {
  width: 100%; height: 47px; border: 0; border-radius: 10px;
  background: linear-gradient(135deg,var(--blue),#486fe5); color: #fff;
  font-size: 13px; font-weight: 700; cursor: pointer;
  box-shadow: 0 9px 22px rgba(49,95,222,.20); transition: transform .12s, box-shadow .12s;
}
.primary:hover { transform: translateY(-1px); box-shadow: 0 12px 26px rgba(49,95,222,.25); }
.notice {
  display: none; margin-top: 18px; padding: 13px; gap: 10px;
  border: 1px solid var(--line); border-radius: 10px; background: #f8fafc;
}
.notice.visible { display: flex; }
.notice-icon {
  width: 21px; height: 21px; flex: 0 0 21px; border-radius: 50%;
  background: #e7edfb; color: #4169e1; display: grid; place-items: center; font-size: 11px; font-weight: 800;
}
.notice strong { display: block; font-size: 11px; }
.notice p { margin: 4px 0 0; color: var(--muted); font-size: 10px; line-height: 1.45; }
.card-footer {
  margin-top: 27px; padding-top: 19px; border-top: 1px solid #eaecf0;
  text-align: center; color: var(--faint); font-size: 10px;
}
.sep { margin: 0 6px; }
.footer {
  position: relative; z-index: 1; min-height: 62px; padding: 0 42px 22px;
  display: flex; justify-content: space-between; align-items: flex-end;
  color: var(--faint); font-size: 10px;
}
.footer nav { display: flex; gap: 20px; }
@media (max-width: 850px) {
  .layout { max-width: 520px; grid-template-columns: 1fr; padding-top: 32px; }
  .hero { display: none; }
}
@media (max-width: 520px) {
  .topbar { min-height: 68px; padding: 0 20px; }
  .service-status { display: none; }
  .layout { padding: 30px 16px 60px; }
  .auth-card { padding: 26px; border-radius: 19px; }
  .footer { padding: 0 20px 18px; }
  .footer nav { display: none; }
}
EOF

  cat > "${BASE_DIR}/html/app.js" <<'EOF'
(() => {
  const form = document.getElementById('loginForm');
  const notice = document.getElementById('notice');
  const password = document.getElementById('password');
  const help = document.getElementById('helpButton');

  const showNotice = () => {
    // Deliberately do not read, submit, persist or transmit credentials.
    if (password) password.value = '';
    notice?.classList.add('visible');
  };

  form?.addEventListener('submit', (event) => {
    event.preventDefault();
    showNotice();
  });

  help?.addEventListener('click', showNotice);
})();
EOF

  cat > "${BASE_DIR}/html/favicon.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <rect width="64" height="64" rx="16" fill="#111827"/>
  <path d="M18 44h27a10 10 0 0 0 1-19.9A15 15 0 0 0 17.4 19 12 12 0 0 0 18 44Z"
        fill="none" stroke="#fff" stroke-width="3"/>
</svg>
EOF

  cat > "${BASE_DIR}/html/robots.txt" <<'EOF'
User-agent: *
Disallow: /
EOF

  cat > "${BASE_DIR}/html/404.html" <<EOF
<!doctype html>
<meta charset="utf-8">
<title>${service_name} Cloud</title>
<style>
body{font-family:system-ui;margin:0;display:grid;place-items:center;min-height:100vh;background:#f5f7fb;color:#101828}
main{text-align:center}p{color:#667085}
</style>
<main><h1>Page unavailable</h1><p>The requested cloud resource is not available on ${domain}.</p></main>
EOF
}

install_acme() {
  local email="$1"

  if [[ ! -x "$ACME_BIN" ]]; then
    info "Устанавливаю acme.sh..."
    curl -fsSL https://get.acme.sh | sh -s "email=${email}"
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
    --keylength ec-256

  install_cert_files "$domain"
  ok "Сертификат установлен в ${BASE_DIR}/ssl."
}

renew_certificate() {
  local force="${1:-0}"

  load_state
  [[ "$INSTALL_MODE" == "selfsteal" ]] || die "SSL не настроен этим manager."
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

random_xhttp_path() {
  printf '/assets/%s' "$(openssl rand -hex 12)"
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
  echo -e "${C_BOLD}Какие inbound'ы создать в Xray profile?${C_RESET}"
  echo "1. VLESS RAW + REALITY + Selfsteal"
  echo "2. VLESS XHTTP + REALITY + Selfsteal"
  echo "3. Hysteria2 (UDP + TLS)"
  echo "4. Все"
  echo
  echo "Можно указать несколько: 1,2,3"
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
  fi

  if [[ "$RAW_ENABLED" != "1" && "$XHTTP_ENABLED" != "1" ]]; then
    warn "Выбран только Hysteria2: cloud-заглушка Nginx будет создана, но без Reality inbound она не будет доступна через fallback."
  fi
}

tune_hysteria_udp() {
  if [[ "$HY2_ENABLED" != "1" ]]; then
    rm -f /etc/sysctl.d/99-remnanode-hysteria.conf 2>/dev/null || true
    return 0
  fi

  cat > /etc/sysctl.d/99-remnanode-hysteria.conf <<'EOF'
# Remnawave Node Manager - larger UDP buffers for QUIC/Hysteria2
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF

  sysctl --system >/dev/null || true
  ok "UDP buffers tuned for Hysteria2."
}

generate_reality_material() {
  load_reality

  if [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]]; then
    [[ -n "$RAW_SHORT_ID" ]] || RAW_SHORT_ID="$(openssl rand -hex 8)"
    [[ -n "$XHTTP_SHORT_ID" ]] || XHTTP_SHORT_ID="$(openssl rand -hex 8)"
    save_reality
    return 0
  fi

  [[ -f "${BASE_DIR}/docker-compose.yml" ]] || die "docker-compose.yml отсутствует."
  docker inspect remnanode >/dev/null 2>&1 || die "Контейнер remnanode не запущен."

  local output
  output="$(docker exec remnanode xray x25519 2>/dev/null || true)"
  [[ -n "$output" ]] || die "xray x25519 не вернул ключи."

  REALITY_PRIVATE_KEY="$(printf '%s\n' "$output" | awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}')"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "$output" | awk -F': *' 'tolower($1) ~ /(public|password)/ {print $2; exit}')"

  [[ -n "$REALITY_PRIVATE_KEY" ]] || die "Не удалось определить Reality Private Key."
  [[ -n "$REALITY_PUBLIC_KEY" ]] || warn "Не удалось автоматически определить Reality Public Key/Password."

  RAW_SHORT_ID="$(openssl rand -hex 8)"
  XHTTP_SHORT_ID="$(openssl rand -hex 8)"

  save_reality
  ok "Reality keypair и Short IDs сгенерированы."
}

rotate_reality_keys() {
  load_state

  if [[ "$RAW_ENABLED" != "1" && "$XHTTP_ENABLED" != "1" ]]; then
    die "В текущем профиле нет REALITY inbound."
  fi

  confirm "Сгенерировать НОВУЮ Reality keypair? Клиентские конфиги после этого нужно обновить." || return 0

  rm -f "$REALITY_FILE"
  REALITY_PRIVATE_KEY=""
  REALITY_PUBLIC_KEY=""
  RAW_SHORT_ID=""
  XHTTP_SHORT_ID=""

  generate_reality_material
  generate_xray_profile

  warn "Новый profile нужно сохранить/запушить в Remnawave Panel."
}

join_by_comma() {
  local IFS=,
  echo "$*"
}

generate_xray_profile() {
  load_state

  [[ "$INSTALL_MODE" == "selfsteal" ]] || die "Профиль Selfsteal не настроен."
  [[ -n "$DOMAIN" ]] || die "DOMAIN отсутствует."

  mkdir -p "$PROFILE_DIR"

  local inbounds=()

  if [[ "$RAW_ENABLED" == "1" || "$XHTTP_ENABLED" == "1" ]]; then
    generate_reality_material
    load_reality
  fi

  if [[ "$RAW_ENABLED" == "1" ]]; then
    inbounds+=("$(cat <<EOF
{
  "tag": "VLESS_RAW_REALITY",
  "port": ${RAW_PORT},
  "listen": "0.0.0.0",
  "protocol": "vless",
  "settings": {
    "clients": [],
    "decryption": "none"
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"]
  },
  "streamSettings": {
    "network": "raw",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "xver": 1,
      "target": "/dev/shm/nginx.sock",
      "spiderX": "",
      "shortIds": ["${RAW_SHORT_ID}"],
      "privateKey": "${REALITY_PRIVATE_KEY}",
      "serverNames": ["${DOMAIN}"],
      "minClientVer": "0.0.0"
    }
  }
}
EOF
)")
  fi

  if [[ "$XHTTP_ENABLED" == "1" ]]; then
    inbounds+=("$(cat <<EOF
{
  "tag": "VLESS_XHTTP_REALITY",
  "port": ${XHTTP_PORT},
  "listen": "0.0.0.0",
  "protocol": "vless",
  "settings": {
    "clients": [],
    "decryption": "none"
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"]
  },
  "streamSettings": {
    "network": "xhttp",
    "security": "reality",
    "xhttpSettings": {
      "path": "${XHTTP_PATH}",
      "mode": "${XHTTP_MODE}"
    },
    "realitySettings": {
      "show": false,
      "xver": 1,
      "target": "/dev/shm/nginx.sock",
      "spiderX": "",
      "shortIds": ["${XHTTP_SHORT_ID}"],
      "privateKey": "${REALITY_PRIVATE_KEY}",
      "serverNames": ["${DOMAIN}"],
      "minClientVer": "0.0.0"
    }
  }
}
EOF
)")
  fi

  if [[ "$HY2_ENABLED" == "1" ]]; then
    inbounds+=("$(cat <<EOF
{
  "tag": "HYSTERIA2",
  "port": ${HY2_PORT},
  "listen": "0.0.0.0",
  "protocol": "hysteria",
  "settings": {
    "clients": [],
    "version": 2
  },
  "streamSettings": {
    "network": "hysteria",
    "security": "tls",
    "finalmask": {
      "quicParams": {
        "debug": false,
        "congestion": "bbr"
      }
    },
    "tlsSettings": {
      "alpn": ["h3"],
      "serverName": "${DOMAIN}",
      "certificates": [
        {
          "keyFile": "/opt/remnanode/ssl/privkey.pem",
          "certificateFile": "/opt/remnanode/ssl/fullchain.pem"
        }
      ]
    },
    "hysteriaSettings": {
      "version": 2
    }
  }
}
EOF
)")
  fi

  local inbound_json
  inbound_json="$(join_by_comma "${inbounds[@]}")"

  cat > "$PROFILE_FILE" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "dns": {
    "servers": [
      "1.1.1.1",
      "1.0.0.1"
    ]
  },
  "inbounds": [
${inbound_json}
  ],
  "outbounds": [
    {
      "tag": "DIRECT",
      "protocol": "freedom"
    },
    {
      "tag": "BLOCK",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "rules": [
      {
        "ip": ["geoip:private"],
        "outboundTag": "BLOCK"
      },
      {
        "domain": ["geosite:private"],
        "outboundTag": "BLOCK"
      },
      {
        "protocol": ["bittorrent"],
        "outboundTag": "BLOCK"
      }
    ]
  }
}
EOF

  jq empty "$PROFILE_FILE" || die "Сгенерирован некорректный JSON profile."
  chmod 600 "$PROFILE_FILE"

  {
    echo "Remnawave Node Manager ${SCRIPT_VERSION}"
    echo
    echo "Domain: ${DOMAIN}"
    echo "Service name: ${SERVICE_NAME}"
    echo

    if [[ "$RAW_ENABLED" == "1" ]]; then
      echo "[VLESS RAW + REALITY]"
      echo "Tag: VLESS_RAW_REALITY"
      echo "TCP port: ${RAW_PORT}"
      echo "SNI: ${DOMAIN}"
      echo "Short ID: ${RAW_SHORT_ID}"
      echo "Public Key / Password: ${REALITY_PUBLIC_KEY}"
      echo "Target: /dev/shm/nginx.sock"
      echo
    fi

    if [[ "$XHTTP_ENABLED" == "1" ]]; then
      echo "[VLESS XHTTP + REALITY]"
      echo "Tag: VLESS_XHTTP_REALITY"
      echo "TCP port: ${XHTTP_PORT}"
      echo "SNI: ${DOMAIN}"
      echo "Short ID: ${XHTTP_SHORT_ID}"
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
      echo
    fi

    echo "Profile: ${PROFILE_FILE}"
  } > "$PROFILE_INFO"

  chmod 600 "$PROFILE_INFO"
  ok "Xray profile сгенерирован: ${PROFILE_FILE}"

  validate_generated_profile || true
}

validate_generated_profile() {
  docker inspect remnanode >/dev/null 2>&1 || return 0

  info "Проверяю сгенерированный Xray JSON текущим Xray внутри remnanode..."

  docker cp "$PROFILE_FILE" remnanode:/tmp/remnanode-manager-profile.json >/dev/null

  if docker exec remnanode xray run -test -config /tmp/remnanode-manager-profile.json >/dev/null 2>&1; then
    ok "Xray принимает сгенерированный profile."
  elif docker exec remnanode xray -test -config /tmp/remnanode-manager-profile.json >/dev/null 2>&1; then
    ok "Xray принимает сгенерированный profile."
  else
    warn "Автотест Xray profile не прошёл. Версия Xray или конкретный inbound может требовать корректировки."
    warn "Проверь вручную перед push в Panel: ${PROFILE_FILE}"
  fi

  docker exec remnanode rm -f /tmp/remnanode-manager-profile.json >/dev/null 2>&1 || true
}

start_stack() {
  cd "$BASE_DIR"
  docker compose config >/dev/null
  docker compose pull
  docker compose up -d --remove-orphans
}

verify_basic() {
  echo
  info "Проверка RemnaNode..."
  docker compose -f "${BASE_DIR}/docker-compose.yml" ps

  docker inspect remnanode --format 'remnanode: {{.State.Status}}' 2>/dev/null || true

  if ss -lntp 2>/dev/null | grep -q ":${NODE_PORT}"; then
    ok "Node API слушает TCP ${NODE_PORT}."
  else
    warn "TCP ${NODE_PORT} пока не виден. Проверь docker logs remnanode."
  fi
}

verify_selfsteal_local() {
  docker inspect nginx-selfsteal >/dev/null 2>&1 || {
    warn "nginx-selfsteal не запущен."
    return 1
  }

  docker exec nginx-selfsteal nginx -t

  test -S /dev/shm/nginx.sock || die "Не найден /dev/shm/nginx.sock на хосте."

  docker exec remnanode test -S /dev/shm/nginx.sock \
    || die "RemnaNode не видит /dev/shm/nginx.sock."

  ok "Nginx и Unix socket работают."
}

show_remote_certificate() {
  local port="$1"

  echo | timeout 10 openssl s_client \
    -connect "${DOMAIN}:${port}" \
    -servername "$DOMAIN" \
    -showcerts 2>/dev/null \
    | openssl x509 \
      -noout \
      -subject \
      -issuer \
      -dates \
      -ext subjectAltName 2>/dev/null
}

diagnostics() {
  load_state
  load_reality

  echo
  echo -e "${C_BOLD}=== Remnawave Node diagnostics ===${C_RESET}"
  echo "Manager: ${SCRIPT_VERSION}"
  echo "Mode: ${INSTALL_MODE:-unknown}"
  echo

  if command -v docker >/dev/null 2>&1; then
    ok "Docker: $(docker --version)"
    docker compose version || true
  else
    err "Docker не установлен."
  fi

  echo
  echo "--- Containers ---"
  if [[ -f "${BASE_DIR}/docker-compose.yml" ]]; then
    (cd "$BASE_DIR" && docker compose ps) || true
  else
    warn "docker-compose.yml отсутствует."
  fi

  echo
  echo "--- Firewall ---"
  ufw status verbose || true

  echo
  echo "--- Listening sockets ---"
  ss -lntup | grep -E "(:22 |:${NODE_PORT} |:${RAW_PORT:-0} |:${XHTTP_PORT:-0} |:${HY2_PORT:-0} )" || true

  if [[ "$INSTALL_MODE" == "selfsteal" ]]; then
    echo
    echo "--- DNS ---"
    dig +short A "$DOMAIN" || true
    dig +short AAAA "$DOMAIN" || true

    echo
    echo "--- Local certificate ---"
    if [[ -f "${BASE_DIR}/ssl/fullchain.pem" ]]; then
      openssl x509 \
        -in "${BASE_DIR}/ssl/fullchain.pem" \
        -noout -subject -issuer -dates -ext subjectAltName || true
    else
      err "Нет ${BASE_DIR}/ssl/fullchain.pem"
    fi

    echo
    echo "--- Nginx / socket ---"
    if docker inspect nginx-selfsteal >/dev/null 2>&1; then
      docker exec nginx-selfsteal nginx -t || true
      docker exec nginx-selfsteal ls -lah /etc/nginx/ssl/ || true
    else
      err "nginx-selfsteal не существует."
    fi

    ls -lah /dev/shm/nginx.sock 2>/dev/null || true
    docker exec remnanode ls -lah /dev/shm/nginx.sock 2>/dev/null || true

    if [[ "$RAW_ENABLED" == "1" ]]; then
      echo
      echo "--- Remote TLS via RAW Reality fallback :${RAW_PORT} ---"
      show_remote_certificate "$RAW_PORT" || warn "Сертификат через RAW port не получен."
    fi

    if [[ "$XHTTP_ENABLED" == "1" ]]; then
      echo
      echo "--- Remote TLS via XHTTP Reality fallback :${XHTTP_PORT} ---"
      show_remote_certificate "$XHTTP_PORT" || warn "Сертификат через XHTTP port не получен."
    fi

    echo
    echo "--- acme.sh ---"
    if [[ -x "$ACME_BIN" ]]; then
      "$ACME_BIN" --info -d "$DOMAIN" --ecc 2>/dev/null || true
    else
      warn "acme.sh не найден."
    fi

    echo
    echo "--- Generated profile ---"
    if [[ -f "$PROFILE_FILE" ]]; then
      jq empty "$PROFILE_FILE" && ok "JSON profile syntax OK." || err "JSON profile invalid."
      validate_generated_profile || true
    else
      warn "Profile ещё не создан."
    fi
  fi

  echo
  echo "--- Recent RemnaNode log ---"
  docker logs --tail 40 remnanode 2>&1 || true

  if docker inspect nginx-selfsteal >/dev/null 2>&1; then
    echo
    echo "--- Recent nginx-selfsteal log ---"
    docker logs --tail 40 nginx-selfsteal 2>&1 || true
  fi

  echo
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

  if confirm "Показать PRIVATE Reality key?"; then
    echo "Reality Private Key: ${REALITY_PRIVATE_KEY}"
  fi

  echo
  echo "Xray profile: ${PROFILE_FILE}"
}

configure_inbounds_existing() {
  load_state

  [[ "$INSTALL_MODE" == "selfsteal" ]] || die "Inbound manager доступен после установки режима SSL/Selfsteal."

  prompt_inbounds
  tune_hysteria_udp
  save_state

  configure_firewall "selfsteal"
  generate_xray_profile

  warn "Manager только генерирует профиль. Его нужно сохранить/запушить в Remnawave Panel."
}

prompt_domain_and_site() {
  local default_domain="${1:-}"
  local default_service="${2:-}"

  local domain_input
  read -r -p "Домен ноды${default_domain:+ [${default_domain}]}: " domain_input
  DOMAIN="${domain_input:-$default_domain}"
  validate_domain "$DOMAIN" || die "Некорректный домен: ${DOMAIN}"

  local service_input
  read -r -p "Название сервиса для cloud-заглушки${default_service:+ [${default_service}]} (Enter = домен): " service_input

  if [[ -n "$service_input" ]]; then
    SERVICE_NAME="$service_input"
  elif [[ -n "$default_service" ]]; then
    SERVICE_NAME="$default_service"
  else
    SERVICE_NAME="$DOMAIN"
  fi

  validate_service_name "$SERVICE_NAME" || die "Название сервиса содержит неподдерживаемые символы."

  local email_input
  read -r -p "Email Let's Encrypt/acme.sh${ACME_EMAIL:+ [${ACME_EMAIL}]}: " email_input
  ACME_EMAIL="${email_input:-$ACME_EMAIL}"
  validate_email "$ACME_EMAIL" || die "Некорректный email."
}

change_domain() {
  load_state

  [[ "$INSTALL_MODE" == "selfsteal" ]] || die "Домен не настроен этим manager."

  local old_domain="$DOMAIN"
  local old_service="$SERVICE_NAME"

  echo "Текущий домен: ${old_domain}"
  echo "Текущее название: ${old_service}"

  prompt_domain_and_site "$old_domain" "$old_service"

  if [[ "$DOMAIN" == "$old_domain" && "$SERVICE_NAME" == "$old_service" ]]; then
    warn "Изменений нет."
    return 0
  fi

  check_domain_dns "$DOMAIN"

  if [[ "$DOMAIN" != "$old_domain" ]]; then
    issue_certificate "$DOMAIN" "$ACME_EMAIL"
  fi

  write_nginx_conf "$DOMAIN"
  write_site_files "$DOMAIN" "$SERVICE_NAME"
  save_state
  generate_xray_profile

  docker restart nginx-selfsteal >/dev/null 2>&1 || true

  if [[ "$DOMAIN" != "$old_domain" && -x "$ACME_BIN" ]]; then
    if confirm "Убрать старый ${old_domain} из acme.sh auto-renew?"; then
      "$ACME_BIN" --remove -d "$old_domain" --ecc || true
    fi
  fi

  ok "Домен/название изменены."
  warn "Не забудь обновить serverNames/Host в Remnawave Panel новым profile."
}

ssl_menu() {
  load_state

  [[ "$INSTALL_MODE" == "selfsteal" ]] || {
    err "SSL/Selfsteal не настроен."
    pause
    return
  }

  while true; do
    clear || true
    echo -e "${C_BOLD}SSL / acme.sh${C_RESET}"
    echo
    echo "Domain: ${DOMAIN}"
    echo
    echo "1. Показать сертификат"
    echo "2. Renew если пора"
    echo "3. Принудительный renew"
    echo "4. Повторно установить сертификат в /opt/remnanode/ssl"
    echo "5. Показать acme.sh --info"
    echo
    echo "0. Назад"
    echo

    local choice
    read -r -p "Выбор: " choice

    case "$choice" in
      1)
        openssl x509 -in "${BASE_DIR}/ssl/fullchain.pem" \
          -noout -subject -issuer -dates -ext subjectAltName
        pause
        ;;
      2)
        renew_certificate "0"
        pause
        ;;
      3)
        renew_certificate "1"
        pause
        ;;
      4)
        install_cert_files "$DOMAIN"
        pause
        ;;
      5)
        "$ACME_BIN" --info -d "$DOMAIN" --ecc || true
        pause
        ;;
      0) return 0 ;;
      *) ;;
    esac
  done
}

update_node() {
  [[ -f "${BASE_DIR}/docker-compose.yml" ]] || die "Нода не установлена в ${BASE_DIR}."

  info "Обновляю Docker images..."
  (
    cd "$BASE_DIR"
    docker compose pull
    docker compose up -d --remove-orphans
  )

  ok "Контейнеры обновлены."
  verify_basic
}

remove_node() {
  load_state

  warn "Будут остановлены контейнеры RemnaNode/Nginx и при подтверждении удалён ${BASE_DIR}."
  echo
  read -r -p "Для продолжения введи DELETE: " token
  [[ "$token" == "DELETE" ]] || {
    warn "Отменено."
    return 0
  }

  if [[ -f "${BASE_DIR}/docker-compose.yml" ]]; then
    (cd "$BASE_DIR" && docker compose down --remove-orphans) || true
  fi

  if [[ "$INSTALL_MODE" == "selfsteal" && -n "$DOMAIN" && -x "$ACME_BIN" ]]; then
    if confirm "Убрать ${DOMAIN} из списка renew acme.sh?"; then
      "$ACME_BIN" --remove -d "$DOMAIN" --ecc || true
    fi
  fi

  rm -f "$RELOAD_HELPER"

  if confirm "Удалить все файлы ${BASE_DIR}?"; then
    rm -rf "$BASE_DIR"
  fi

  warn "Docker, UFW и правило SSH не удалялись."
  ok "RemnaNode installation removed."
}

install_node_basic() {
  prompt_secret_and_panel
  install_base_packages
  install_docker

  ensure_base_dirs

  INSTALL_MODE="basic"
  DOMAIN=""
  SERVICE_NAME=""
  ACME_EMAIL=""

  RAW_ENABLED="0"
  XHTTP_ENABLED="0"
  HY2_ENABLED="0"

  write_env
  write_basic_compose
  save_state
  configure_firewall "basic"

  start_stack
  verify_basic

  ok "Remna Node установлен."
}

install_node_selfsteal() {
  prompt_secret_and_panel

  ACME_EMAIL=""
  prompt_domain_and_site "" ""

  echo
  prompt_inbounds

  install_base_packages
  install_docker
  ensure_base_dirs

  INSTALL_MODE="selfsteal"

  write_env
  write_site_files "$DOMAIN" "$SERVICE_NAME"
  write_nginx_conf "$DOMAIN"
  write_selfsteal_compose

  tune_hysteria_udp
  save_state

  configure_firewall "selfsteal"

  issue_certificate "$DOMAIN" "$ACME_EMAIL"

  start_stack
  verify_basic
  verify_selfsteal_local

  generate_xray_profile

  echo
  ok "Remna Node + SSL + Selfsteal установлен."
  echo
  echo "Generated profile: ${PROFILE_FILE}"
  echo "Connection info:    ${PROFILE_INFO}"
  echo
  warn "Следующий шаг: добавь ${PROFILE_FILE} в Remnawave Panel и назначь профиль этой ноде."
}

show_files() {
  echo
  echo "${BASE_DIR}/"
  echo "├── docker-compose.yml"
  echo "├── .env"
  echo "├── installer.conf"
  echo "├── nginx.conf"
  echo "├── reality.env"
  echo "├── ssl/"
  echo "│   ├── fullchain.pem"
  echo "│   └── privkey.pem"
  echo "├── html/"
  echo "│   ├── index.html"
  echo "│   ├── style.css"
  echo "│   ├── app.js"
  echo "│   ├── favicon.svg"
  echo "│   ├── robots.txt"
  echo "│   └── 404.html"
  echo "└── profiles/"
  echo "    ├── xray-profile.json"
  echo "    └── profile-info.txt"
}

show_menu() {
  clear || true

  load_state

  echo -e "${C_BOLD}Remnawave Node Manager${C_RESET} ${C_CYAN}v${SCRIPT_VERSION}${C_RESET}"

  if [[ -n "${INSTALL_MODE:-}" ]]; then
    echo "Installed: ${INSTALL_MODE}${DOMAIN:+ | ${DOMAIN}}"
  fi

  echo
  echo "1. Установить Remna Node"
  echo "2. Установить Remna Node + SSL / Selfsteal"
  echo
  echo "3. Обновить RemnaNode / контейнеры"
  echo "4. SSL / сертификаты"
  echo "5. Диагностика Node / Selfsteal"
  echo "6. Показать Reality keys / параметры профиля"
  echo "7. Настроить inbound'ы / пересобрать Xray profile"
  echo "8. Изменить домен / название cloud-заглушки"
  echo "9. Сгенерировать новую Reality keypair"
  echo "10. Показать структуру файлов"
  echo "11. Удалить Node"
  echo
  echo "0. Выход"
  echo
}

main() {
  require_root
  detect_os

  touch "$INSTALL_LOG"
  chmod 600 "$INSTALL_LOG"

  while true; do
    show_menu

    local choice
    read -r -p "Выбери пункт: " choice

    case "$choice" in
      1)
        install_node_basic
        pause
        ;;
      2)
        install_node_selfsteal
        pause
        ;;
      3)
        update_node
        pause
        ;;
      4)
        ssl_menu
        ;;
      5)
        diagnostics
        pause
        ;;
      6)
        show_profile_info
        pause
        ;;
      7)
        configure_inbounds_existing
        pause
        ;;
      8)
        change_domain
        pause
        ;;
      9)
        rotate_reality_keys
        pause
        ;;
      10)
        show_files
        pause
        ;;
      11)
        remove_node
        pause
        ;;
      0)
        exit 0
        ;;
      *)
        warn "Неизвестный пункт."
        sleep 1
        ;;
    esac
  done
}

main "$@"
