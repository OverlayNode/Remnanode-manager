#!/usr/bin/env bash

config_base_profile() {
  local output="$1" legacy="${RN_BASE_DIR}/profiles/xray-profile.json"
  if [[ -f "$legacy" ]]; then cp "$legacy" "$output"; else printf '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[],"routing":{"rules":[]}}\n' >"$output"; fi
  if [[ -f "$RN_REALITY_FILE" && -n "${DOMAIN:-}" ]]; then :; fi
}

config_generate() {
  rn_require_command jq; snippets_validate_all
  local base output
  base="$(mktemp)"; output="${RN_GENERATED_DIR}/profile.json.new"
  config_base_profile "$base"
  snippets_merge_into "$base" "$output"; rm -f "$base"
  xray_validate_file "$output" || { rm -f "$output"; rn_die "Generated profile failed Xray validation"; }
  mv "$output" "${RN_GENERATED_DIR}/profile.json"; chmod 600 "${RN_GENERATED_DIR}/profile.json"
  cp "${RN_GENERATED_DIR}/profile.json" "${RN_GENERATED_DIR}/routing.json"
  [[ -f "$RN_REALITY_FILE" ]] && jq '{publicKey,shortIds}' "$RN_REALITY_FILE" >"${RN_GENERATED_DIR}/reality.json"
  rn_info "Config Profile generated successfully: ${RN_GENERATED_DIR}/profile.json"
}
config_print() { jq . "${RN_GENERATED_DIR}/profile.json"; }
config_apply() {
  local target="${REMNANODE_XRAY_CONFIG:-${RN_BASE_DIR}/profiles/xray-profile.json}"
  [[ -f "${RN_GENERATED_DIR}/profile.json" ]] || config_generate
  rn_atomic_apply "${RN_GENERATED_DIR}/profile.json" "$target" xray_validate_file node_post_config_healthcheck
}
node_post_config_healthcheck() { [[ -f "$RN_COMPOSE_FILE" ]] && node_compose restart remnanode >/dev/null; [[ "$(node_health_state)" != OFFLINE ]]; }
config_copy_osc52() { local encoded; encoded="$(base64 -w0 "${RN_GENERATED_DIR}/profile.json")"; printf '\033]52;c;%s\a' "$encoded"; }
config_command() {
  case "${1:-print}" in
    generate) config_generate ;;
    print|view) config_print ;;
    edit) "${EDITOR:-nano}" "${RN_GENERATED_DIR}/profile.json" ;;
    copy) if [[ -t 1 && "${TERM:-}" != dumb ]]; then config_copy_osc52; else config_print; fi ;;
    export) [[ -n "${2:-}" ]] || rn_die "Export path required"; cp "${RN_GENERATED_DIR}/profile.json" "$2" ;;
    apply) config_apply ;;
    *) rn_die "Unknown config action" ;;
  esac
}
config_menu() { ui_simple_menu "Config Profile" "Run: remnanode config generate|view|copy|edit|export|apply"; ui_pause; }
