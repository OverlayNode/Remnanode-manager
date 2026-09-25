#!/usr/bin/env bash

selfsteal_status() { local socket=/dev/shm/nginx.sock; [[ -S "$socket" ]] && printf HEALTHY || printf NOT_CONFIGURED; }
selfsteal_generate() {
  local theme="${1:-developer-platform}" out="${RN_BASE_DIR}/html" company product accent suffix
  jq -e --arg theme "$theme" '.themes|index($theme)' "${RN_ROOT}/data/templates.json" >/dev/null || rn_die "Unknown template theme"
  company="$(printf '%s\n' Northstar Meridian Vertex Nimbus Altura | shuf -n1)"; product="$(printf '%s\n' Cloud Edge Platform Network Systems | shuf -n1)"; accent="#$(openssl rand -hex 3)"; suffix="$(openssl rand -hex 4)"
  mkdir -p "$out/assets"; backup_create pre-selfsteal-site >/dev/null
  sed -e "s/{{COMPANY}}/$company/g" -e "s/{{PRODUCT}}/$product/g" -e "s/{{THEME}}/$theme/g" -e "s/{{YEAR}}/$(date +%Y)/g" -e "s/{{ACCENT}}/$accent/g" -e "s/{{SUFFIX}}/$suffix/g" "${RN_ROOT}/templates/selfsteal/index.html" >"$out/index.html"
  chmod 644 "$out/index.html"; rn_info "Selfsteal template generated: $theme"
}
selfsteal_doctor() { printf 'nginx: '; systemctl is-active nginx 2>/dev/null || docker inspect nginx-selfsteal --format '{{.State.Status}}' 2>/dev/null || true; printf 'socket: '; [[ -S /dev/shm/nginx.sock ]] && echo OK || echo MISSING; ssl_status; }
selfsteal_command() { case "${1:-status}" in status) selfsteal_status; echo;; generate) selfsteal_generate "${2:-developer-platform}";; doctor) selfsteal_doctor;; *) rn_die "Unknown selfsteal action";; esac; }
selfsteal_menu() { ui_simple_menu "SELFSTEAL" "Status: $(selfsteal_status)" "15 randomized corporate themes are available."; ui_pause; }
