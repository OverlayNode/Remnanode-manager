#!/usr/bin/env bash

diagnostics_check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then printf '%-24s OK\n' "$name"; return 0; else printf '%-24s FAIL\n' "$name"; return 1; fi; }
diagnostics_doctor() {
  local export_file=""; [[ "${1:-}" == --export ]] && export_file="${2:-${RN_GENERATED_DIR}/diagnostic-report.txt}"
  local report; report="$(mktemp)"
  {
    printf 'RemnaNode Manager doctor %s\nGenerated: %s\n' "$RN_VERSION" "$(date -u +%FT%TZ)"
    diagnostics_check OS test -r /etc/os-release || true
    diagnostics_check Docker docker info || true
    diagnostics_check Compose docker compose version || true
    diagnostics_check 'Node container' docker_service_running remnanode || true
    diagnostics_check 'Node health' test "$(node_health_state)" = ONLINE || true
    diagnostics_check Xray xray_running || true
    diagnostics_check DNS getent hosts github.com || true
    diagnostics_check IPv4 test -n "$(network_public_ipv4)" || true
    diagnostics_check IPv6 test -n "$(network_public_ipv6)" || true
    diagnostics_check Snippets snippets_validate_all || true
    diagnostics_check Firewall command -v ufw || true
    diagnostics_check TLS test -r "${RN_BASE_DIR}/ssl/fullchain.pem" || true
    diagnostics_check Selfsteal test -S /dev/shm/nginx.sock || true
    if [[ "$(warp_status_json | jq -r .installed)" == true ]]; then printf '%-24s OK\n' WARP; else printf '%-24s FAIL\n' WARP; fi
    printf '\n'; system_status
  } >"$report" 2>&1
  diagnostics_sanitize "$report" "${report}.safe"
  cat "${report}.safe"
  if [[ -n "$export_file" ]]; then cp "${report}.safe" "$export_file"; chmod 600 "$export_file"; rn_info "Sanitized report: $export_file"; fi
  rm -f "$report" "${report}.safe"
}

diagnostics_sanitize() {
  sed -E \
    -e 's/((API_?TOKEN|TOKEN|PASSWORD|SECRET(_KEY)?|PRIVATE_?KEY|Authorization|Cookie)[" =:]+)[^ ,"}]*/\1[REDACTED]/Ig' \
    -e 's/(Bearer )[A-Za-z0-9._~+\/-]+/\1[REDACTED]/Ig' \
    -e 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}/[REDACTED-UUID]/g' "$1" >"$2"
}
