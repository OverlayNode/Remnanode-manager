#!/usr/bin/env bash

routing_command() {
  case "${1:-list}" in
    list) snippets_list_json | jq '[.[]|select(.type=="routing")]' ;;
    enable) snippet_set_enabled "$2" true ;;
    disable) snippet_set_enabled "$2" false ;;
    dataset|datasets) routing_dataset_command "${@:2}" ;;
    *) rn_die "Unknown routing action" ;;
  esac
}
routing_menu() { ui_simple_menu "Routing presets" "All presets use the shared snippet/merge engine."; routing_command list; ui_pause; }
routing_dataset_add() {
  local name="$1" source="$2" expected_sha="${3:-}" dir="${RN_STATE_DIR}/datasets" tmp sha metadata
  [[ "$name" =~ ^[A-Za-z0-9._-]+\.dat$ ]] || rn_die "Dataset name must end in .dat"
  mkdir -p "$dir"; tmp="$(mktemp)"; curl -fsSL "$source" -o "$tmp"; sha="$(sha256sum "$tmp"|awk '{print $1}')"
  [[ -z "$expected_sha" || "$sha" == "$expected_sha" ]] || { rm -f "$tmp"; rn_die "SHA256 mismatch"; }
  mv "$tmp" "$dir/$name"; metadata="$dir/$name.json"; jq -n --arg name "$name" --arg source "$source" --arg sha256 "$sha" --arg path "$dir/$name" '{name:$name,source:$source,downloadDate:(now|todate),sha256:$sha256,path:$path}' >"$metadata"
}
routing_dataset_list() { local dir="${RN_STATE_DIR}/datasets"; mkdir -p "$dir"; jq -s '.' "$dir"/*.dat.json 2>/dev/null || printf '[]\n'; }
routing_dataset_remove() {
  local name="$1" dir="${RN_STATE_DIR}/datasets"
  [[ "$name" =~ ^[A-Za-z0-9._-]+\.dat$ ]] || rn_die "Invalid dataset name"
  [[ -f "$dir/$name" ]] || rn_die "Dataset not found: $name"
  rn_confirm "Remove dataset $name?" no || rn_die "Cancelled"
  [[ "${RN_DRY_RUN:-0}" == 1 ]] && { printf 'remove %s\n' "$dir/$name"; return; }
  rm -f -- "$dir/$name" "$dir/$name.json"
}
routing_dataset_update_all() {
  local dir="${RN_STATE_DIR}/datasets" metadata name source
  for metadata in "$dir"/*.dat.json; do
    [[ -f "$metadata" ]] || continue
    name="$(jq -r .name "$metadata" | tr -d '\r')"; source="$(jq -r .source "$metadata" | tr -d '\r')"
    routing_dataset_add "$name" "$source"
  done
}
routing_dataset_command() {
  case "${1:-list}" in
    list) routing_dataset_list ;;
    add) [[ -n "${2:-}" && -n "${3:-}" ]] || rn_die "Use: routing dataset add NAME.dat URL [SHA256]"; routing_dataset_add "$2" "$3" "${4:-}" ;;
    remove) routing_dataset_remove "$2" ;;
    update-all) routing_dataset_update_all ;;
    *) rn_die "Unknown dataset action" ;;
  esac
}
