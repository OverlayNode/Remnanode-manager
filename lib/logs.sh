#!/usr/bin/env bash

logs_command() {
  local source="${1:-node}" range="${2:-100}" lines=100 follow=0 since=""
  case "$range" in 50|100|500) lines="$range";; live) follow=1;; 1h|24h) since="$range";; *) rn_die "Range: 50|100|500|live|1h|24h";; esac
  local -a docker_args=(logs --tail "$lines"); ((follow)) && docker_args+=(-f); [[ -n "$since" ]] && docker_args+=(--since "$since")
  case "$source" in
    node|docker) node_compose "${docker_args[@]}" remnanode ;;
    selfsteal) node_compose "${docker_args[@]}" nginx-selfsteal ;;
    xray-access) docker exec "$(xray_container)" tail -n "$lines" /var/log/xray/access.log ;;
    xray-error) docker exec "$(xray_container)" tail -n "$lines" /var/log/xray/error.log ;;
    system) journalctl -n "$lines" ${since:+--since=-$since} ;;
    ufw) journalctl -u ufw -n "$lines" ${since:+--since=-$since} ;;
    warp) journalctl -u warp-svc -n "$lines" ${since:+--since=-$since} ;;
    manager) tail -n "$lines" "$RN_LOG_FILE" ;;
    *) rn_die "Unknown log source: $source" ;;
  esac
}
