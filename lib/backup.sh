#!/usr/bin/env bash

backup_create() {
  local reason="${1:-manual}" stamp destination metadata
  stamp="$(date +%Y-%m-%d_%H-%M-%S)"; destination="${RN_BACKUP_DIR}/${stamp}-${reason//[^a-zA-Z0-9._-]/_}"
  mkdir -p "$destination"
  local path rel
  for path in "$RN_COMPOSE_FILE" "${RN_BASE_DIR}/nginx.conf" "${RN_BASE_DIR}/installer.conf" "$RN_GENERATED_DIR" "$RN_SNIPPET_DIR" "${RN_BASE_DIR}/html" "${RN_STATE_DIR}/routing"; do
    [[ -e "$path" ]] || continue
    rel="$(basename "$path")"; cp -a "$path" "$destination/$rel"
  done
  metadata="${destination}/metadata.json"
  jq -n --arg created "$(date -u +%FT%TZ)" --arg reason "$reason" --arg managerVersion "$RN_VERSION" --arg nodeVersion "$(node_version)" --arg xrayVersion "$(xray_version)" '{created:$created,reason:$reason,managerVersion:$managerVersion,nodeVersion:$nodeVersion,xrayVersion:$xrayVersion}' >"$metadata"
  chmod -R go-rwx "$destination"
  printf '%s\n' "$destination"
}
backup_list() { find "$RN_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r; }
backup_restore() {
  rn_require_root
  local source="$1" safety
  [[ -d "$source" ]] || source="${RN_BACKUP_DIR}/${source}"
  [[ -d "$source" && -f "$source/metadata.json" ]] || rn_die "Invalid backup: $source"
  rn_confirm "Restore backup $(basename "$source")?" no || rn_die "Cancelled."
  safety="$(backup_create pre-restore)"; rn_info "Safety backup: $safety"
  [[ -f "$source/docker-compose.yml" ]] && cp -a "$source/docker-compose.yml" "$RN_COMPOSE_FILE"
  [[ -f "$source/nginx.conf" ]] && cp -a "$source/nginx.conf" "${RN_BASE_DIR}/nginx.conf"
  [[ -f "$source/installer.conf" ]] && cp -a "$source/installer.conf" "${RN_BASE_DIR}/installer.conf"
  [[ -d "$source/generated" ]] && cp -a "$source/generated/." "$RN_GENERATED_DIR/"
  [[ -d "$source/snippets" ]] && cp -a "$source/snippets/." "$RN_SNIPPET_DIR/"
  rn_info "Backup restored. Services were not restarted automatically."
}
backup_command() { case "${1:-list}" in create) backup_create "${2:-manual}";; list) backup_list;; restore) [[ -n "${2:-}" ]] || rn_die "Backup path required"; backup_restore "$2";; *) rn_die "Unknown backup action";; esac; }
backup_menu() { ui_simple_menu "Backup & Restore" "Run: remnanode backup create|list|restore PATH"; backup_list; ui_pause; }
