#!/usr/bin/env bash

ssl_status() {
  local cert="${RN_BASE_DIR}/ssl/fullchain.pem" expiry epoch now days issuer subject state
  [[ -r "$cert" ]] || { printf 'TLS: NOT CONFIGURED\n'; return 1; }
  expiry="$(openssl x509 -in "$cert" -noout -enddate | cut -d= -f2)"; issuer="$(openssl x509 -in "$cert" -noout -issuer | sed 's/^issuer=//')"; subject="$(openssl x509 -in "$cert" -noout -subject | sed 's/^subject=//')"
  epoch="$(date -d "$expiry" +%s)"; now="$(date +%s)"; days=$(((epoch-now)/86400)); state=OK; ((days<30)) && state=WARN; ((days<7)) && state=CRITICAL
  printf 'TLS: %s (%s days)\nSubject: %s\nIssuer: %s\nExpiry: %s\n' "$state" "$days" "$subject" "$issuer" "$expiry"
}
ssl_command() { case "${1:-status}" in status) ssl_status;; *) rn_die "Unknown SSL action";; esac; }
ssl_menu() { ssl_status || true; ui_pause; }
