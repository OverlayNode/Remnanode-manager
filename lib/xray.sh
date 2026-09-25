#!/usr/bin/env bash

xray_container() { docker_service_container remnanode; }
xray_running() {
  local id; id="$(xray_container 2>/dev/null || true)"; [[ -n "$id" ]] || return 1
  docker exec "$id" sh -c 'pgrep -x xray >/dev/null 2>&1 || xray api stats --server=127.0.0.1:10085 >/dev/null 2>&1' >/dev/null 2>&1
}
xray_version() {
  local id output; id="$(xray_container 2>/dev/null || true)"; [[ -n "$id" ]] || { printf unknown; return; }
  output="$(docker exec "$id" xray version 2>/dev/null | head -n1 || true)"
  [[ -n "$output" ]] && printf '%s' "$output" || printf unknown
}
xray_validate_file() {
  local file="$1" id remote="/tmp/remnanode-manager-test.json"
  jq empty "$file" || return 1
  id="$(xray_container 2>/dev/null || true)"; [[ -n "$id" ]] || return 0
  docker cp "$file" "${id}:${remote}" >/dev/null || return 1
  docker exec "$id" xray run -test -config "$remote" >/dev/null 2>&1 || docker exec "$id" xray -test -config "$remote" >/dev/null 2>&1
  local result=$?; docker exec "$id" rm -f "$remote" >/dev/null 2>&1 || true; return "$result"
}
xray_command() {
  case "${1:-status}" in
    status) if xray_running; then printf 'RUNNING\n'; else printf 'STOPPED\n'; return 1; fi ;;
    version) xray_version; printf '\n' ;;
    restart) rn_require_root; node_compose restart remnanode ;;
    validate) xray_validate_file "${2:-${RN_GENERATED_DIR}/profile.json}" ;;
    logs) logs_command xray-error "${2:-100}" ;;
    update) rn_die "Xray updates are image-managed; select/update the Node image explicitly." ;;
    *) rn_die "Unknown Xray action: ${1:-}" ;;
  esac
}
xray_menu() { ui_simple_menu "Xray Core" "Current: $(xray_version)" "Run: remnanode xray status|version|restart|validate|logs"; ui_pause; }
