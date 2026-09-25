#!/usr/bin/env bash

security_assert_permissions() {
  local file="$1" mode; [[ -e "$file" ]] || return 0
  mode="$(stat -c '%a' "$file")"; [[ "$mode" == 600 || "$mode" == 700 ]] || { rn_warn "Tightening permissions on $file"; chmod go-rwx "$file"; }
}
security_validate_download() { local file="$1" expected="$2"; [[ "$(sha256sum "$file"|awk '{print $1}')" == "$expected" ]]; }
