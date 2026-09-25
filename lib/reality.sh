#!/usr/bin/env bash

RN_REALITY_FILE="${RN_STATE_DIR}/reality.json"

validate_short_id() {
  local value="$1"
  [[ "$value" =~ ^[0-9a-f]+$ ]] && ((${#value} >= 2 && ${#value} <= 16 && ${#value} % 2 == 0))
}

validate_short_ids_json() {
  local file="$1" value count unique
  jq -e 'type=="array" and length>=1 and length<=32' "$file" >/dev/null || return 1
  while IFS= read -r value; do value="${value%$'\r'}"; validate_short_id "$value" || return 1; done < <(jq -r '.[]' "$file")
  count="$(jq length "$file")"; unique="$(jq 'unique|length' "$file")"; [[ "$count" == "$unique" ]]
}

reality_random_int() {
  local min="$1" max="$2" hex value span
  span=$((max-min+1))
  hex="$(openssl rand -hex 4)" || return 1; value=$((16#$hex)); printf '%d' "$((min + value % span))"
}

reality_generate_shortids() {
  local count="${1:-}" length candidate tmp
  [[ -n "$count" ]] || count="$(reality_random_int 3 12)"
  [[ "$count" =~ ^[0-9]+$ ]] && ((count>=1 && count<=32)) || rn_die "Short ID count must be 1..32"
  tmp="$(mktemp)"; printf '[]\n' >"$tmp"
  while (($(jq length "$tmp") < count)); do
    length=$((2 * $(reality_random_int 1 8)))
    candidate="$(openssl rand -hex $((length/2)))"
    jq --arg id "$candidate" 'if index($id) then . else .+[$id] end' "$tmp" >"${tmp}.new" && mv "${tmp}.new" "$tmp"
  done
  if ! validate_short_ids_json "$tmp"; then rm -f "$tmp"; rn_die "Generated Short IDs failed validation"; return 1; fi
  cat "$tmp"; rm -f "$tmp"
}

reality_import_legacy() {
  local legacy="${RN_BASE_DIR}/reality.env" private="" public=""
  [[ -f "$RN_REALITY_FILE" || ! -r "$legacy" ]] && return 0
  private="$(sed -n 's/^REALITY_PRIVATE_KEY=//p' "$legacy" | tr -d "'\"")"; public="$(sed -n 's/^REALITY_PUBLIC_KEY=//p' "$legacy" | tr -d "'\"")"
  local shortids; shortids="$(reality_generate_shortids)"
  jq -n --arg privateKey "$private" --arg publicKey "$public" --argjson shortIds "$shortids" '{privateKey:$privateKey,publicKey:$publicKey,shortIds:$shortIds,createdAt:(now|todate),source:"legacy-migration"}' >"$RN_REALITY_FILE"
  chmod 600 "$RN_REALITY_FILE"
}

reality_generate_keys() {
  local output private public
  output="$(docker exec "$(xray_container)" xray x25519 2>/dev/null)" || rn_die "xray x25519 failed"
  private="$(awk -F': *' 'tolower($1)~/private/{print $2;exit}' <<<"$output")"
  public="$(awk -F': *' 'tolower($1)~/(public|password)/{print $2;exit}' <<<"$output")"
  [[ "$private" =~ ^[A-Za-z0-9_=-]{32,128}$ && "$public" =~ ^[A-Za-z0-9_=-]{32,128}$ ]] || rn_die "Unexpected Xray key output"
  printf '%s\n%s\n' "$private" "$public"
}

reality_generate() {
  reality_import_legacy
  if [[ -f "$RN_REALITY_FILE" ]]; then rn_info "Reality material already exists; it was not changed."; return 0; fi
  local keys private public shortids tmp
  keys="$(reality_generate_keys)"; private="$(sed -n 1p <<<"$keys")"; public="$(sed -n 2p <<<"$keys")"; shortids="$(reality_generate_shortids)"
  tmp="$(mktemp)"; jq -n --arg privateKey "$private" --arg publicKey "$public" --argjson shortIds "$shortids" '{privateKey:$privateKey,publicKey:$publicKey,shortIds:$shortIds,createdAt:(now|todate)}' >"$tmp"
  mv "$tmp" "$RN_REALITY_FILE"; chmod 600 "$RN_REALITY_FILE"
  rn_info "Reality keys and $(jq '.shortIds|length' "$RN_REALITY_FILE") Short IDs created. Private key was not printed."
}

reality_shortids_list() { reality_import_legacy; [[ -f "$RN_REALITY_FILE" ]] || rn_die "Reality material is not initialized"; jq '.shortIds' "$RN_REALITY_FILE"; }
reality_shortids_regenerate() {
  local count="${1:-}" tmp ids
  [[ -f "$RN_REALITY_FILE" ]] || reality_generate
  rn_confirm "Existing clients using previous Reality shortIds may stop connecting. Continue?" no || rn_die "Cancelled."
  ids="$(reality_generate_shortids "$count")"; tmp="$(mktemp)"
  jq --argjson ids "$ids" '.shortIds=$ids | .shortIdsUpdatedAt=(now|todate)' "$RN_REALITY_FILE" >"$tmp"
  validate_short_ids_json <(jq '.shortIds' "$tmp") || { rm -f "$tmp"; rn_die "Validation failed"; }
  backup_create pre-shortid-rotation >/dev/null; mv "$tmp" "$RN_REALITY_FILE"; chmod 600 "$RN_REALITY_FILE"; jq '.shortIds' "$RN_REALITY_FILE"
}

reality_command() {
  case "${1:-}" in
    generate) reality_generate ;;
    shortids) case "${2:-list}" in list) reality_shortids_list;; regenerate) reality_shortids_regenerate "${3:-}";; *) rn_die "Unknown shortids action";; esac ;;
    keys) [[ "${2:-}" == regenerate ]] || rn_die "Use: reality keys regenerate"; rn_confirm "Regenerate Reality keys? Existing clients will stop connecting." no || rn_die "Cancelled"; mv "$RN_REALITY_FILE" "${RN_REALITY_FILE}.old.$(date +%s)"; reality_generate ;;
    *) rn_die "Use: reality generate|shortids|keys" ;;
  esac
}
reality_menu() { ui_simple_menu "Reality" "Run: remnanode reality generate" "     remnanode reality shortids list|regenerate [COUNT]"; ui_pause; }
