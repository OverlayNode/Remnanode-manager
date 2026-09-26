#!/usr/bin/env bash
# Variables below are consumed by functions sourced from install.sh.
# shellcheck disable=SC2034
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../install.sh
source "${PROJECT_DIR}/install.sh"
trap - ERR
for module in $RNM_MODULES; do
  load_module "$module"
done

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
INSTALL_LOG="${TEST_DIR}/test.log"
FAILURES=0

assert_ok() {
  "$@" >/dev/null || {
    printf 'FAIL: expected success: %s\n' "$*" >&2
    FAILURES=$((FAILURES + 1))
  }
}

assert_fail() {
  if "$@" >/dev/null 2>&1; then
    printf 'FAIL: expected failure: %s\n' "$*" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

assert_eq() {
  local expected="$1" actual="$2" message="$3"
  if [[ "$expected" != "$actual" ]]; then
    printf 'FAIL: %s: expected [%s], got [%s]\n' "$message" "$expected" "$actual" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

# jq в Windows может печатать CRLF — нормализуем для локального запуска.
jqn() { jq "$@" | tr -d '\r'; }

# --- Валидаторы ---------------------------------------------------------------
assert_ok validate_domain node.example.com
assert_fail validate_domain invalid_domain
assert_ok validate_email admin@example.com
assert_fail validate_email admin-at-example.com
assert_ok validate_port 443
assert_fail validate_port 0
assert_fail validate_port 65536
assert_ok validate_service_name 'Example Cloud'
assert_fail validate_service_name '<script>alert(1)</script>'
assert_ok validate_xhttp_path '/assets/abc-123'
assert_fail validate_xhttp_path 'assets/abc-123'
assert_ok validate_panel_network '192.0.2.10/32'
assert_ok validate_panel_network '2001:db8::/32'
assert_fail validate_panel_network '192.0.2.999/24'
assert_ok validate_image_ref 'remnawave/node:2.1.3'
assert_ok validate_image_ref "remnawave/node@sha256:$(printf 'a%.0s' {1..64})"
assert_fail validate_image_ref 'remnawave/node:2.1.3; rm -rf /'
assert_ok validate_image_tag '2.1.3'
assert_fail validate_image_tag '../latest'
assert_ok is_public_ipv4 185.10.20.30
assert_fail is_public_ipv4 10.0.0.1
assert_fail is_public_ipv4 100.64.1.1
assert_ok is_public_ipv6 2a01:4f8::1
assert_fail is_public_ipv6 fd00::1
assert_fail is_public_ipv6 fe80::1

# --- Модули ------------------------------------------------------------------
for module in $RNM_MODULES; do
  assert_ok test -f "${PROJECT_DIR}/modules/${module}.sh"
  assert_ok module_version_ok "${PROJECT_DIR}/modules/${module}.sh"
done
assert_eq "$(ls "${PROJECT_DIR}"/modules/*.sh | wc -l | tr -d ' ')" "$(wc -w <<<"$RNM_MODULES" | tr -d ' ')" "every module file is listed in RNM_MODULES"
assert_fail bash -c 'source "$1"; load_module "../evil"' _ "${PROJECT_DIR}/install.sh"
assert_ok grep -q 'zapret2' "${PROJECT_DIR}/modules/zapret.sh"
assert_fail grep -qE 'bol-van/zapret[^2]' "${PROJECT_DIR}/modules/zapret.sh"

# --- DNS ---------------------------------------------------------------------
assert_ok validate_dns_list "77.88.8.8,77.88.8.1"
assert_ok validate_dns_list "https://1.1.1.1/dns-query,https://8.8.8.8/dns-query"
assert_ok validate_dns_list "tcp://9.9.9.9:53,localhost"
assert_fail validate_dns_list ""
assert_fail validate_dns_list "77.88.8.8;rm -rf /"
assert_fail validate_dns_list "http://1.1.1.1/dns-query"

# --- Состояние ---------------------------------------------------------------
STATE_FILE="${TEST_DIR}/installer.conf"
cat > "$STATE_FILE" <<'EOF'
SCRIPT_VERSION=0.1.0
INSTALL_MODE=basic
EOF

load_state
assert_eq "4.1.0" "$SCRIPT_VERSION" "running version wins over state"
assert_eq "basic" "$INSTALL_MODE" "install mode loaded"
assert_eq "remnawave/node:latest" "$NODE_IMAGE" "default node image"

BASE_DIR="${TEST_DIR}/node"
mkdir -p "$BASE_DIR"
RU_POLICY="direct"
save_state
RU_POLICY="block"
load_state
assert_eq "direct" "$RU_POLICY" "RU_POLICY survives save/load"

# --- APT и Compose (с заглушками) --------------------------------------------
mkdir -p "${TEST_DIR}/bin"
APT_CAPTURE="${TEST_DIR}/apt.args"
export APT_CAPTURE
cat > "${TEST_DIR}/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$APT_CAPTURE"
EOF
cat > "${TEST_DIR}/bin/fuser" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "${TEST_DIR}/bin/docker" <<'EOF'
#!/usr/bin/env bash
# compose config проходит, inspect — «контейнера нет».
[[ "${1:-}" == "compose" ]] && exit 0
exit 1
EOF
chmod +x "${TEST_DIR}/bin/apt-get" "${TEST_DIR}/bin/fuser" "${TEST_DIR}/bin/docker"
PATH="${TEST_DIR}/bin:${PATH}"

APT_LOCK_TIMEOUT=42
apt_get_wait install -y jq
assert_ok grep -Fq -- '-o DPkg::Lock::Timeout=42 install -y jq' "$APT_CAPTURE"

NODE_COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
SECRET_KEY="test-secret-key"
NODE_PORT="2222"
NODE_IMAGE="remnawave/node:2.1.3"

write_basic_compose
assert_ok grep -Fq "SECRET_KEY: 'test-secret-key'" "$NODE_COMPOSE_FILE"
assert_ok grep -Fq "image: remnawave/node:2.1.3" "$NODE_COMPOSE_FILE"
assert_fail grep -q 'env_file' "$NODE_COMPOSE_FILE"

write_selfsteal_compose
assert_ok grep -Fq "nginx-selfsteal" "$NODE_COMPOSE_FILE"
assert_ok grep -Fq "condition: service_healthy" "$NODE_COMPOSE_FILE"

# --- Reality Short IDs -------------------------------------------------------
ids="$(generate_shortids_json)"
count="$(jqn length <<<"$ids")"
assert_ok test "$count" -ge 3 -a "$count" -le 12
assert_eq "$count" "$(jqn 'unique|length' <<<"$ids")" "short ids are unique"
assert_ok validate_shortids_json "$ids"

migrated="$(ensure_shortids_json '' 'deadbeef')"
assert_ok jq -e 'index("deadbeef") == 0 and length >= 3 and length <= 12' <<<"$migrated"

# --- Routing ----------------------------------------------------------------
ROUTING_DIR="${TEST_DIR}/routing"
GEO_DIR="${TEST_DIR}/geo"
ensure_routing_lists
assert_ok test -f "${ROUTING_DIR}/warp.list"
assert_eq '["regexp:\\.onion$"]' "$(routing_list_json tor)" "tor list parsed without comments"

GEO_ENABLED=0 RU_POLICY=block BLOCK_ADS=0 WARP_OUTBOUND=0 PSIPHON_OUTBOUND=0 TOR_OUTBOUND=0
routing="$(build_routing_json)"
assert_ok jq -e '.rules[] | select(.protocol == ["bittorrent"] and .outboundTag == "BLOCK")' <<<"$routing"
assert_ok jq -e '.rules[] | select(.ip == ["geoip:ru"] and .outboundTag == "BLOCK")' <<<"$routing"
assert_ok jq -e '.rules[] | select(.ip == ["geoip:private"] and .outboundTag == "BLOCK")' <<<"$routing"
assert_eq "IPIfNonMatch" "$(jqn -r .domainStrategy <<<"$routing")" "domain strategy"

RU_POLICY=direct
routing="$(build_routing_json)"
assert_ok jq -e '.rules[] | select(.ip == ["geoip:ru"] and .outboundTag == "DIRECT")' <<<"$routing"

# RU через WARP без WARP outbound безопасно деградирует в BLOCK.
RU_POLICY=warp
assert_eq "BLOCK" "$(ru_policy_tag)" "warp policy without warp outbound falls back to BLOCK"
WARP_OUTBOUND=1
assert_eq "WARP" "$(ru_policy_tag)" "warp policy with warp outbound"
routing="$(build_routing_json)"
assert_ok jq -e '.rules[] | select(.outboundTag == "WARP" and (.domain | index("domain:openai.com")))' <<<"$routing"

GEO_ENABLED=1 RU_POLICY=block BLOCK_ADS=1 TOR_OUTBOUND=1 PSIPHON_OUTBOUND=1
printf 'domain:example.org\n' >> "${ROUTING_DIR}/psiphon.list"
routing="$(build_routing_json)"
assert_ok jq -e '.rules[] | select(.domain == ["ext:roscom-geosite.dat:category-ru", "ext:roscom-geosite.dat:whitelist"] and .outboundTag == "BLOCK")' <<<"$routing"
assert_ok jq -e '.rules[] | select(.ip == ["ext:roscom-geoip.dat:direct", "ext:roscom-geoip.dat:whitelist"])' <<<"$routing"
assert_ok jq -e '.rules[] | select(.domain == ["ext:roscom-geosite.dat:torrent"] and .outboundTag == "BLOCK")' <<<"$routing"
assert_ok jq -e '.rules[] | select(.outboundTag == "PSIPHON" and .network == "tcp")' <<<"$routing"
assert_ok jq -e '.rules[] | select(.outboundTag == "TOR")' <<<"$routing"

# Торренты блокируются раньше правил модулей и РФ.
torrent_index="$(jqn '[.rules[] | .protocol == ["bittorrent"]] | index(true)' <<<"$routing")"
ru_index="$(jqn '[.rules[] | (.domain // []) | index("ext:roscom-geosite.dat:category-ru") != null] | index(true)' <<<"$routing")"
assert_ok test "$torrent_index" -lt "$ru_index"

outbounds="$(build_outbounds_json)"
assert_eq "DIRECT,BLOCK,dns-out,WARP,PSIPHON,TOR" "$(jqn -r '[.[].tag] | join(",")' <<<"$outbounds")" "outbound order"
assert_eq "warp" "$(jqn -r '.[] | select(.tag == "WARP") | .streamSettings.sockopt.interface' <<<"$outbounds")" "warp interface"

# DNS: собственный резолвер Xray идёт напрямую первым правилом, клиентский DNS
# перехватывается до блокировок.
assert_eq "dns-internal" "$(jqn -r '.rules[0].inboundTag[0]' <<<"$routing")" "resolver rule is first"
assert_eq "DIRECT" "$(jqn -r '.rules[0].outboundTag' <<<"$routing")" "resolver goes direct"
assert_eq "dns-out" "$(jqn -r '.rules[1].outboundTag' <<<"$routing")" "client DNS hijacked"

DNS_RU="77.88.8.8,77.88.8.1" DNS_FOREIGN="https://1.1.1.1/dns-query"
dns="$(build_dns_json)"
assert_eq "dns-internal" "$(jqn -r .tag <<<"$dns")" "dns tag"
assert_eq "2" "$(jqn '[.servers[] | objects | select(.skipFallback)] | length' <<<"$dns")" "two RU resolvers"
assert_ok jq -e '.servers[0].domains | index("ext:roscom-geosite.dat:category-ru")' <<<"$dns"
assert_ok jq -e '.servers[0].expectIPs | index("ext:roscom-geoip.dat:direct")' <<<"$dns"
assert_eq "https://1.1.1.1/dns-query" "$(jqn -r '.servers[-1]' <<<"$dns")" "foreign DoH is the fallback"

GEO_ENABLED=0
dns="$(build_dns_json)"
assert_ok jq -e '.servers[0].expectIPs == ["geoip:ru"]' <<<"$dns"

DNS_HIJACK=0
assert_fail jq -e '.[] | select(.tag == "dns-out")' <<<"$(build_outbounds_json)"
assert_fail jq -e '.rules[] | select(.outboundTag == "dns-out")' <<<"$(build_routing_json)"
DNS_HIJACK=1
GEO_ENABLED=1

# Hysteria2: BBR всегда, Salamander — только с паролем; JSON для Host в Panel.
DOMAIN=node.example.com RAW_ENABLED=0 XHTTP_ENABLED=0 HY2_ENABLED=1 HY2_PORT=443
HY2_OBFS_PASSWORD=""
hy2="$(build_inbounds_json)"
assert_ok jq -e '.[0].protocol == "hysteria" and .[0].streamSettings.network == "hysteria" and .[0].streamSettings.security == "tls"' <<<"$hy2"
assert_ok jq -e '.[0].streamSettings.finalmask == {quicParams: {debug: false, congestion: "bbr"}}' <<<"$hy2"
assert_eq "" "$(hy2_host_finalmask_json)" "no host finalmask without obfs"
HY2_OBFS_PASSWORD="abc123"
hy2="$(build_inbounds_json)"
assert_ok jq -e '.[0].streamSettings.finalmask.udp == [{type: "salamander", settings: {password: "abc123"}}]' <<<"$hy2"
assert_ok jq -e '.[0].streamSettings.finalmask.quicParams.congestion == "bbr"' <<<"$hy2"
assert_eq '{"udp":[{"type":"salamander","settings":{"password":"abc123"}}]}' "$(hy2_host_finalmask_json | tr -d '')" "host finalmask json"
HY2_OBFS_PASSWORD="" HY2_ENABLED=0 DOMAIN=""

# --- Генерация профиля (basic: без inbound'ов) --------------------------------
PROFILE_DIR="${TEST_DIR}/profiles"
PROFILE_FILE="${PROFILE_DIR}/xray-profile.json"
PROFILE_INFO="${PROFILE_DIR}/profile-info.txt"
CLIENT_ROUTING_FILE="${PROFILE_DIR}/client-routing-happ.json"
CLIENT_RULES_FILE="${PROFILE_DIR}/client-routing-xray-rules.json"
CLIENT_DNS_FILE="${PROFILE_DIR}/client-dns-xray.json"
CLIENT_APPS_FILE="${PROFILE_DIR}/client-ru-apps.txt"
INSTALL_MODE=basic DOMAIN="" RAW_ENABLED=0 XHTTP_ENABLED=0 HY2_ENABLED=0
GEO_ENABLED=1  # geo-файлов нет — генератор должен откатиться на встроенные
generate_xray_profile 1 >/dev/null
assert_ok jq -e '.inbounds == [] and (.outbounds | length) >= 2' "$PROFILE_FILE"
assert_fail grep -q 'ext:roscom' "$PROFILE_FILE"
assert_ok grep -q 'merge' "$PROFILE_INFO"
assert_ok jq -e '.DirectSites | index("geosite:category-ru")' "$CLIENT_ROUTING_FILE"
assert_ok jq -e '.BlockSites | index("geosite:torrent")' "$CLIENT_ROUTING_FILE"
assert_ok jq -e '.GlobalProxy == "true"' "$CLIENT_ROUTING_FILE"
assert_ok jq -e '.[-1].outboundTag == "proxy"' "$CLIENT_RULES_FILE"
assert_ok jq -e '.dns.servers | length >= 2' "$PROFILE_FILE"
assert_ok jq -e '.DomesticDNSIP == "77.88.8.8" and .RemoteDNSDomain == "https://1.1.1.1/dns-query"' "$CLIENT_ROUTING_FILE"
assert_ok jq -e '.servers[0].expectIPs == ["geoip:ru"] and .servers[1] == "https://1.1.1.1/dns-query"' "$CLIENT_DNS_FILE"
assert_ok grep -qx 'ru.sberbankmobile' "$CLIENT_APPS_FILE"

assert_eq '"privateKey": "[REDACTED]"' "$(printf '"privateKey": "abc123"' | redact_secrets)" "private key redaction"

# --- Шаблоны сайтов ----------------------------------------------------------
TEMPLATES_ROOT="${PROJECT_DIR}/templates/sites"
mapfile -t TEMPLATE_NAMES < <(templates_names "$TEMPLATES_ROOT")
assert_ok test "${#TEMPLATE_NAMES[@]}" -ge 10

for name in "${TEMPLATE_NAMES[@]}"; do
  src="${TEMPLATES_ROOT}/${name}"
  out="${TEST_DIR}/site-${name}"
  assert_ok test -f "${src}/preview.png"
  assert_ok jq -e '.name and .title and .description' "${src}/manifest.json"

  site_render_template "$src" "$out" "Test Brand" "node.example.com"
  assert_ok test -f "${out}/index.html"
  assert_ok test -f "${out}/404.html"
  assert_ok test -f "${out}/robots.txt"
  assert_ok test -f "${out}/favicon.svg"
  assert_fail test -e "${out}/manifest.json"
  assert_fail test -e "${out}/preview.png"
  assert_fail grep -rEq '__[A-Z0-9_]+__' "$out"

  # CSP nginx: без inline-скриптов, inline-стилей и форм.
  assert_fail grep -rEiq '<script>|<script [^>]*>[^<]' "$out" --include='*.html'
  assert_fail grep -rEiq ' style=|<style' "$out" --include='*.html'
  assert_fail grep -rEiq '<form|type="password"' "$out" --include='*.html'

  # Все абсолютные ссылки на ресурсы существуют.
  while IFS= read -r ref; do
    [[ -f "${out}${ref}" ]] || { printf 'FAIL: %s: missing %s\n' "$name" "$ref" >&2; FAILURES=$((FAILURES + 1)); }
  done < <(grep -rhoE '(src|href)="/[^"#?]+\.[a-z0-9]+"' "$out" --include='*.html' | sed -E 's/^[a-z]+="//; s/"$//' | sort -u)
done

# Два рендера одного шаблона не совпадают ни по именам файлов, ни по содержимому.
site_render_template "${TEMPLATES_ROOT}/status-page" "${TEST_DIR}/r1" "Brand" "node.example.com"
site_render_template "${TEMPLATES_ROOT}/status-page" "${TEST_DIR}/r2" "Brand" "node.example.com"
assert_fail cmp -s "${TEST_DIR}/r1/index.html" "${TEST_DIR}/r2/index.html"
assert_fail diff -q <(cd "${TEST_DIR}/r1" && find . -type f | sort) <(cd "${TEST_DIR}/r2" && find . -type f | sort)

if ((FAILURES > 0)); then
  printf '%d test assertion(s) failed.\n' "$FAILURES" >&2
  exit 1
fi
printf 'All tests passed.\n'
