#!/usr/bin/env bash

snippets_seed_builtin() {
  local source file target
  source="${RN_ROOT}/templates/snippets"
  [[ -d "$source" ]] || return 0
  for file in "$source"/*.json; do
    [[ -f "$file" ]] || continue; target="${RN_SNIPPET_DIR}/$(basename "$file")"
    [[ -f "$target" ]] || cp "$file" "$target"
  done
}

snippet_file() { printf '%s/%s.json' "$RN_SNIPPET_DIR" "$1"; }
snippet_validate_file() {
  local file="$1"
  jq -e '
    type=="object" and
    (.id|type=="string" and test("^[a-z0-9][a-z0-9._-]*$")) and
    (.name|type=="string") and
    (.type=="outbound" or .type=="routing" or .type=="dns" or .type=="policy") and
    (.version|type=="number") and (.enabled|type=="boolean") and
    (.managedBy=="remnanode-manager") and (.config|type=="object") and
    ((.requires // [])|type=="array")' "$file" >/dev/null
}

snippets_list_json() { jq -s 'sort_by(.type,.id)|map({id,name,type,version,enabled,requires:(.requires//[])})' "$RN_SNIPPET_DIR"/*.json 2>/dev/null || printf '[]\n'; }
snippets_list() { if [[ "${RN_JSON:-0}" == 1 ]]; then snippets_list_json; else snippets_list_json | jq -r '.[]|"\(.enabled|if . then "[on] " else "[off]" end) \(.type)\t\(.id)\t\(.name)"'; fi; }
snippet_show() {
  local file; file="$(snippet_file "$1")"; [[ -f "$file" ]] || rn_die "Snippet not found: $1"
  if jq -e '.secret==true' "$file" >/dev/null 2>&1; then
    jq 'walk(if type=="object" and has("secretKey") then .secretKey="[REDACTED]" else . end)' "$file"
  else jq . "$file"; fi
}
snippet_export() { local file; file="$(snippet_file "$1")"; [[ -f "$file" ]] || rn_die "Snippet not found"; jq '.config' "$file" >"${2:-${1}.json}"; }

snippet_dependencies_ok() {
  local file="$1" dependency depfile
  while IFS= read -r dependency; do
    dependency="${dependency%$'\r'}"
    depfile="$(snippet_file "$dependency")"
    [[ -f "$depfile" ]] || { rn_error "Required dependency missing: $dependency"; return 1; }
    jq -e '.enabled==true' "$depfile" >/dev/null || { rn_error "Required dependency disabled: $dependency"; return 1; }
  done < <(jq -r '.requires[]?' "$file")
}

snippet_set_enabled() {
  local id="$1" state="$2" file tmp dependency depfile
  file="$(snippet_file "$id")"; [[ -f "$file" ]] || rn_die "Snippet not found: $id"
  if [[ "$state" == true ]]; then
    while IFS= read -r dependency; do
      dependency="${dependency%$'\r'}"
      depfile="$(snippet_file "$dependency")"; [[ -f "$depfile" ]] || rn_die "Required dependency missing: $dependency"
      if ! jq -e '.enabled' "$depfile" >/dev/null; then
        rn_confirm "Enable required dependency $dependency?" yes || rn_die "Dependency not enabled"
        snippet_set_enabled "$dependency" true
      fi
    done < <(jq -r '.requires[]?' "$file")
  else
    local dependent
    dependent="$(jq -r --arg id "$id" 'select(.enabled and ((.requires//[])|index($id)))|.id' "$RN_SNIPPET_DIR"/*.json 2>/dev/null | head -n1)"
    [[ -z "$dependent" ]] || rn_die "Cannot disable: enabled snippet $dependent depends on $id"
  fi
  tmp="$(mktemp)"; jq --argjson state "$state" '.enabled=$state' "$file" >"$tmp"
  [[ "${RN_DRY_RUN:-0}" == 1 ]] && { rn_preview_diff "$file" "$tmp"; rm -f "$tmp"; return; }
  mv "$tmp" "$file"
}

snippets_validate_all() {
  local file failed=0
  for file in "$RN_SNIPPET_DIR"/*.json; do
    snippet_validate_file "$file" || { rn_error "Invalid snippet: $file"; failed=1; continue; }
    if jq -e '.enabled' "$file" >/dev/null; then
      snippet_dependencies_ok "$file" || failed=1
    fi
  done
  ((failed == 0)) || return 1
  snippets_detect_conflicts
}

snippets_detect_conflicts() {
  local enabled duplicates references available tag
  enabled="$(mktemp)"; jq -s '[.[]|select(.enabled)]' "$RN_SNIPPET_DIR"/*.json >"$enabled"
  duplicates="$(jq -r '[.[].config.outbounds[]?.tag]|group_by(.)[]|select(length>1)|.[0]' "$enabled")"
  [[ -z "$duplicates" ]] || { rm -f "$enabled"; rn_die "Duplicate outbound tag(s): $duplicates"; }
  available="$(jq -r '[.[].config.outbounds[]?.tag,"DIRECT","BLOCK"]|unique[]' "$enabled" | tr -d '\r')"
  while IFS= read -r tag; do
    tag="${tag%$'\r'}"
    [[ -z "$tag" ]] && continue
    grep -Fxq "$tag" <<<"$available" || { rm -f "$enabled"; rn_die "Routing rule references missing outboundTag: $tag"; }
  done < <(jq -r '.[].config.routing.rules[]?.outboundTag // empty' "$enabled")
  references="$(jq -r '[.[].config.routing.rules[]?|select((has("outboundTag")|not) and (has("balancerTag")|not))]|length' "$enabled")"
  references="${references%$'\r'}"
  rm -f "$enabled"; ((references == 0)) || rn_die "Routing rule is missing outboundTag/balancerTag"
}

snippets_merge_into() {
  local base="$1" output="$2" snippets conflicts
  snippets="$(mktemp)"; jq -s '[.[]|select(.enabled)|.config]' "$RN_SNIPPET_DIR"/*.json >"$snippets"
  conflicts="$(jq -nr --slurpfile base "$base" --slurpfile snippets "$snippets" '
    def conflicting_tags($items):
      [$items[] | select(.tag != null)]
      | group_by(.tag)
      | map(select((map(tojson) | unique | length) > 1) | .[0].tag);
    (conflicting_tags([$base[0].outbounds[]?, $snippets[0][].outbounds[]?])
     + conflicting_tags([$base[0].inbounds[]?, $snippets[0][].inbounds[]?]))
    | unique | join(",")' | tr -d '\r')"
  if [[ -n "$conflicts" ]]; then
    rm -f "$snippets"
    rn_die "Base profile conflicts with snippet tag(s): $conflicts"
    return 1
  fi
  jq --slurpfile snippets "$snippets" '
    reduce $snippets[0][] as $s (.;
      .outbounds = (((.outbounds // []) + ($s.outbounds // [])) | unique_by(.tag)) |
      .inbounds = (((.inbounds // []) + ($s.inbounds // [])) | unique_by(.tag)) |
      .routing = ((.routing // {}) * ($s.routing // {})) |
      .routing.rules = ((.routing.rules // []) + ($s.routing.rules // [])) |
      .dns = ((.dns // {}) * ($s.dns // {})) |
      .dns.servers = ((.dns.servers // []) + ($s.dns.servers // []) | unique) |
      .policy = ((.policy // {}) * ($s.policy // {})))' "$base" >"$output"
  rm -f "$snippets"; jq empty "$output"
}

snippets_command() {
  case "${1:-list}" in
    list) snippets_list ;;
    show|print) [[ -n "${2:-}" ]] || rn_die "Snippet id required"; snippet_show "$2" ;;
    enable) snippet_set_enabled "$2" true ;;
    disable) snippet_set_enabled "$2" false ;;
    export) snippet_export "$2" "${3:-}" ;;
    validate) snippets_validate_all; rn_info "All snippets are valid and conflict-free." ;;
    merge) config_generate ;;
    *) rn_die "Unknown snippet action: ${1:-}" ;;
  esac
}
snippets_menu() { ui_simple_menu "XRAY SNIPPETS" "Installed: $(snippets_list_json|jq length)" "Enabled: $(snippets_list_json|jq '[.[]|select(.enabled)]|length')"; snippets_list; ui_pause; }
