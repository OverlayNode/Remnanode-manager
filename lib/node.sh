#!/usr/bin/env bash

node_version() {
  local image id version
  id="$(docker_service_container remnanode 2>/dev/null || true)"
  if [[ -n "$id" ]]; then
    image="$(docker inspect -f '{{.Config.Image}}' "$id" 2>/dev/null || true)"
    version="${image##*:}"
    [[ "$version" != "$image" && "$version" != latest ]] && { printf '%s' "$version"; return; }
    version="$(docker exec "$id" sh -c 'node -p "require(\"/app/package.json\").version" 2>/dev/null || remnanode --version 2>/dev/null || true' 2>/dev/null | head -n1)"
    [[ -n "$version" ]] && { printf '%s' "$version"; return; }
  fi
  printf unknown
}

node_api_responds() {
  local port=2222
  [[ -r "${RN_BASE_DIR}/installer.conf" ]] && port="$(awk -F= '$1=="NODE_PORT"{gsub(/[^0-9]/,"",$2);print $2}' "${RN_BASE_DIR}/installer.conf" | tail -n1)"
  port="${port:-2222}"
  curl -ksS --connect-timeout 2 --max-time 3 "https://127.0.0.1:${port}/" >/dev/null 2>&1 || curl -sS --connect-timeout 2 --max-time 3 "http://127.0.0.1:${port}/" >/dev/null 2>&1
}

node_health_state() {
  command -v docker >/dev/null 2>&1 || { printf UNKNOWN; return; }
  docker_service_running remnanode || { printf OFFLINE; return; }
  local health; health="$(docker_service_health remnanode)"
  [[ "$health" == unhealthy ]] && { printf DEGRADED; return; }
  xray_running || { printf DEGRADED; return; }
  [[ "$health" == healthy ]] || node_api_responds || { printf DEGRADED; return; }
  if panel_configured && ! panel_test_connection >/dev/null 2>&1; then printf DEGRADED; return; fi
  printf ONLINE
}

node_status() {
  local state version health image
  state="$(node_health_state)"; version="$(node_version)"; health="$(docker_service_health remnanode)"
  image="$(docker inspect -f '{{.Config.Image}}' "$(docker_service_container remnanode)" 2>/dev/null || echo unknown)"
  if [[ "${RN_JSON:-0}" == 1 ]]; then jq -n --arg status "$state" --arg version "$version" --arg image "$image" --arg health "$health" '{status:$status,version:$version,image:$image,health:$health}'; else printf 'Status: %s\nVersion: %s\nImage: %s\nHealth: %s\n' "$state" "$version" "$image" "$health"; fi
}

node_compose() { docker compose -f "$RN_COMPOSE_FILE" "$@"; }
node_mutate() { rn_require_root; [[ -f "$RN_COMPOSE_FILE" ]] || rn_die "Compose file not found: $RN_COMPOSE_FILE"; node_compose "$@"; }
node_update() {
  rn_require_root
  if [[ "${RN_DRY_RUN:-0}" == 1 ]]; then printf 'docker compose -f %q pull\ndocker compose -f %q up -d --remove-orphans\n' "$RN_COMPOSE_FILE" "$RN_COMPOSE_FILE"; return; fi
  backup_create pre-node-update >/dev/null
  node_compose pull
  node_compose up -d --remove-orphans
  [[ "$(node_health_state)" != OFFLINE ]] || rn_die "Node update healthcheck failed. Use backup restore."
}
node_validate_compose() { docker compose -f "$1" config >/dev/null; }
node_post_compose_healthcheck() { node_compose up -d --remove-orphans >/dev/null && [[ "$(node_health_state)" != OFFLINE ]]; }
node_select_version() {
  rn_require_root
  local version="$1" candidate
  [[ "$version" =~ ^[vV]?[0-9]+([.][0-9]+){1,3}([-+._a-zA-Z0-9]*)?$ ]] || rn_die "Invalid Node version tag"
  [[ -f "$RN_COMPOSE_FILE" ]] || rn_die "Compose file not found"
  candidate="$(mktemp)"; cp "$RN_COMPOSE_FILE" "$candidate"
  sed -E "s#(^[[:space:]]*image:[[:space:]]*['\"]?remnawave/node:)[^'\"[:space:]]+(['\"]?[[:space:]]*)$#\\1${version}\\2#" "$RN_COMPOSE_FILE" >"$candidate"
  cmp -s "$candidate" "$RN_COMPOSE_FILE" && { rm -f "$candidate"; rn_die "remnawave/node image line was not found or already uses this tag"; return 1; }
  rn_atomic_apply "$candidate" "$RN_COMPOSE_FILE" node_validate_compose node_post_compose_healthcheck
  rm -f "$candidate"
}
node_rollback() {
  rn_require_root
  local backup="${1:-}" candidate
  if [[ -z "$backup" ]]; then backup="$(find "$RN_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d \( -name '*node-update*' -o -name '*atomic*' \) 2>/dev/null | sort -r | head -n1)"; fi
  [[ -d "$backup" ]] || backup="${RN_BACKUP_DIR}/${backup}"
  candidate="${backup}/docker-compose.yml"; [[ -f "$candidate" ]] || rn_die "Backup has no docker-compose.yml: $backup"
  rn_atomic_apply "$candidate" "$RN_COMPOSE_FILE" node_validate_compose node_post_compose_healthcheck
}
node_command() {
  case "${1:-status}" in
    status) node_status ;;
    start) node_mutate up -d ;;
    stop) node_mutate stop ;;
    restart) node_mutate restart remnanode ;;
    update) node_update ;;
    select-version) [[ -n "${2:-}" ]] || rn_die "Version required"; node_select_version "$2" ;;
    rollback) node_rollback "${2:-}" ;;
    logs) node_compose logs --tail="${2:-100}" remnanode ;;
    inspect) docker inspect "$(docker_service_container remnanode)" ;;
    *) rn_die "Unknown node action: ${1:-}" ;;
  esac
}
node_menu() { ui_simple_menu "RemnaNode" "Run: remnanode node status|start|stop|restart|update|select-version|rollback|logs|inspect"; node_status; ui_pause; }
