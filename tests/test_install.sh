#!/usr/bin/env bash
# Variables below are consumed by functions sourced from install.sh.
# shellcheck disable=SC2034
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../install.sh
source "${PROJECT_DIR}/install.sh"

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
INSTALL_LOG="${TEST_DIR}/test.log"

assert_ok() {
  "$@" || {
    printf 'FAIL: expected success: %s\n' "$*" >&2
    return 1
  }
}

assert_fail() {
  if "$@"; then
    printf 'FAIL: expected failure: %s\n' "$*" >&2
    return 1
  fi
}

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

STATE_FILE="${TEST_DIR}/installer.conf"
cat > "$STATE_FILE" <<'EOF'
SCRIPT_VERSION=0.1.0
INSTALL_MODE=basic
EOF

load_state
[[ "$SCRIPT_VERSION" == "3.0.0" ]]
[[ "$INSTALL_MODE" == "basic" ]]

mkdir -p "${TEST_DIR}/bin"
cat > "${TEST_DIR}/bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${TEST_DIR}/bin/docker"
PATH="${TEST_DIR}/bin:${PATH}"

BASE_DIR="${TEST_DIR}/node"
mkdir -p "$BASE_DIR"
NODE_COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
SECRET_KEY="test-secret-key"
NODE_PORT="2222"

write_basic_compose
grep -Fq "SECRET_KEY: 'test-secret-key'" "$NODE_COMPOSE_FILE"
assert_fail grep -q 'env_file' "$NODE_COMPOSE_FILE"

write_site_files node.example.com Example
[[ -f "${BASE_DIR}/html/index.html" ]]
[[ -f "${BASE_DIR}/html/style.css" ]]
[[ ! -e "${BASE_DIR}/html/app.js" ]]
assert_fail grep -qi 'type="password"' "${BASE_DIR}/html/index.html"
assert_fail grep -qi '<form' "${BASE_DIR}/html/index.html"

ids="$(generate_shortids_json)"
count="$(jq length <<<"$ids")"
((count >= 3 && count <= 12))
[[ "$(jq 'unique|length' <<<"$ids")" == "$count" ]]
validate_shortids_json "$ids"

migrated="$(ensure_shortids_json '' 'deadbeef')"
jq -e 'index("deadbeef") != null and length >= 3 and length <= 12' <<<"$migrated" >/dev/null

printf 'All tests passed.\n'
