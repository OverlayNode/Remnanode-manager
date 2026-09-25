#!/usr/bin/env bash

docker_version() { docker version --format '{{.Server.Version}}' 2>/dev/null || printf unavailable; }
docker_compose_version() { docker compose version --short 2>/dev/null || printf unavailable; }
docker_service_container() {
  local service="${1:-remnanode}"
  docker compose -f "$RN_COMPOSE_FILE" ps -q "$service" 2>/dev/null | head -n1
}
docker_service_running() {
  local id; id="$(docker_service_container "${1:-remnanode}")"; [[ -n "$id" ]] && [[ "$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null)" == true ]]
}
docker_service_health() {
  local id health; id="$(docker_service_container "${1:-remnanode}")"
  [[ -n "$id" ]] || { printf absent; return; }
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id" 2>/dev/null || echo unknown)"
  printf '%s' "$health"
}
