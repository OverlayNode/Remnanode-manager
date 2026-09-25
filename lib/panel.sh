#!/usr/bin/env bash

RN_PANEL_ENV="${RN_ETC_DIR}/panel.env"
panel_configured() { [[ -r "$RN_PANEL_ENV" ]] && grep -q '^PANEL_URL=' "$RN_PANEL_ENV" && grep -q '^PANEL_TOKEN=' "$RN_PANEL_ENV"; }
panel_load() {
  panel_configured || return 1
  set -a
  # shellcheck disable=SC1090
  source "$RN_PANEL_ENV"
  set +a
}
panel_request() {
  local method="$1" path="$2" data="${3:-}"
  panel_load || rn_die "Panel is not configured"
  local -a request=(curl -fsS --connect-timeout 5 --max-time 15 -X "$method" -H "Authorization: Bearer ${PANEL_TOKEN}" -H 'Content-Type: application/json')
  [[ -n "$data" ]] && request+=(-d "$data")
  request+=("${PANEL_URL%/}${path}"); "${request[@]}"
}
panel_test_connection() { panel_request GET /api/system/health | jq -e . >/dev/null; }
panel_status() {
  if ! panel_configured; then printf 'NOT CONFIGURED\n'; return 1; fi
  if panel_test_connection; then printf 'CONNECTED\n'; else printf 'UNREACHABLE\n'; return 1; fi
}
panel_profiles_list() { panel_request GET /api/config-profiles | jq '.response.configProfiles'; }
panel_nodes_list() { panel_request GET /api/nodes | jq '.response.nodes'; }
panel_configure() {
  rn_require_root
  local url="$1" token="${2:-}" old_umask
  [[ "$url" =~ ^https?://[^[:space:]]+$ ]] || rn_die "Panel URL must start with http:// or https://"
  if [[ -z "$token" ]]; then [[ -t 0 ]] || rn_die "Token required in non-interactive mode"; read -r -s -p 'Panel API token: ' token; printf '\n'; fi
  [[ -n "$token" ]] || rn_die "Token must not be empty"
  mkdir -p "$RN_ETC_DIR"; chmod 700 "$RN_ETC_DIR"; old_umask="$(umask)"; umask 077
  printf 'PANEL_URL=%q\nPANEL_TOKEN=%q\n' "$url" "$token" >"$RN_PANEL_ENV"; chmod 600 "$RN_PANEL_ENV"; umask "$old_umask"
  panel_test_connection || { rn_warn "Credentials saved, but the Panel health endpoint did not respond."; return 1; }
}
panel_profile_update() {
  local uuid="$1" generated="${RN_GENERATED_DIR}/profile.json" current payload
  [[ -f "$generated" ]] || config_generate
  current="$(mktemp)"; panel_request GET "/api/config-profiles/${uuid}" >"$current"
  mkdir -p "$RN_BACKUP_DIR/panel"; chmod 700 "$RN_BACKUP_DIR/panel"; cp "$current" "$RN_BACKUP_DIR/panel/${uuid}-$(date +%s).json"
  jq '.response.config' "$current" >"${current}.config"; rn_preview_diff "${current}.config" "$generated"
  rn_confirm "Update this Panel Config Profile?" no || { rm -f "$current" "${current}.config"; rn_die "Cancelled"; }
  if [[ "${RN_DRY_RUN:-0}" == 1 ]]; then rm -f "$current" "${current}.config"; rn_info "Dry run: Panel unchanged."; return 0; fi
  payload="$(jq -n --arg uuid "$uuid" --slurpfile config "$generated" '{uuid:$uuid,config:$config[0]}')"
  panel_request PATCH /api/config-profiles "$payload" | jq .
  rm -f "$current" "${current}.config"
}
panel_command() { case "${1:-status}" in status|test) panel_status;; configure) [[ -n "${2:-}" ]] || rn_die "Panel URL required"; panel_configure "$2" "${3:-}";; profiles) panel_profiles_list;; nodes) panel_nodes_list;; update-profile) [[ -n "${2:-}" ]] || rn_die "Profile UUID required"; panel_profile_update "$2";; remove-credentials) rn_require_root; rn_confirm "Remove Panel credentials?" no && rm -f "$RN_PANEL_ENV";; *) rn_die "Unknown panel action";; esac; }
panel_menu() { ui_simple_menu "Panel integration" "Status: $(panel_status 2>/dev/null || true)" "Only documented /api/system/health and /api/config-profiles endpoints are used."; ui_pause; }
