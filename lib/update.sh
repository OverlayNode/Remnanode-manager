#!/usr/bin/env bash

update_command() {
  case "${1:-status}" in
    status) printf 'Manager: %s\nNode: %s\nXray: %s\n' "$RN_VERSION" "$(node_version)" "$(xray_version)" ;;
    node) node_update ;;
    self) rn_die "Self-update requires a configured, checksum-pinned release source; unsafe curl|bash is intentionally unsupported." ;;
    *) rn_die "Unknown update action" ;;
  esac
}
update_menu() { update_command status; ui_pause; }

scheduled_write_unit() {
  local name="$1" schedule="$2" command="$3" service timer
  service="/etc/systemd/system/${name}.service"; timer="/etc/systemd/system/${name}.timer"
  [[ -f "$service" ]] && rn_backup_file "$service" systemd >/dev/null
  [[ -f "$timer" ]] && rn_backup_file "$timer" systemd >/dev/null
  printf '[Unit]\nDescription=RemnaNode Manager task: %s\n\n[Service]\nType=oneshot\nExecStart=%s\n' "$name" "$command" >"$service"
  printf '[Unit]\nDescription=Schedule %s\n\n[Timer]\nOnCalendar=%s\nPersistent=true\nRandomizedDelaySec=5m\n\n[Install]\nWantedBy=timers.target\n' "$name" "$schedule" >"$timer"
  chmod 644 "$service" "$timer"
}

scheduled_tasks_install() {
  rn_require_root
  local manager
  manager="$(command -v remnanode || printf '%s/remnanode' "$RN_ROOT")"
  if [[ "${RN_DRY_RUN:-0}" == 1 ]]; then
    printf 'Would install five remnanode-*.service/timer units using manager %s\n' "$manager"
    return 0
  fi
  scheduled_write_unit remnanode-backup 'Sun *-*-* 03:15:00' "$manager backup create scheduled"
  scheduled_write_unit remnanode-healthcheck '*-*-* *:0/15:00' "$manager doctor --export ${RN_GENERATED_DIR}/scheduled-doctor.txt"
  scheduled_write_unit remnanode-datasets '*-*-* 04:20:00' "$manager routing dataset update-all"
  scheduled_write_unit remnanode-update-check '*-*-* 05:10:00' "$manager update status"
  scheduled_write_unit remnanode-ssl-renew '*-*-* 02:40:00' "/bin/sh -c 'test ! -x /root/.acme.sh/acme.sh || /root/.acme.sh/acme.sh --cron --home /root/.acme.sh'"
  systemctl daemon-reload
  systemctl enable --now remnanode-backup.timer remnanode-healthcheck.timer remnanode-datasets.timer remnanode-update-check.timer remnanode-ssl-renew.timer
}
scheduled_tasks_command() { case "${1:-status}" in install) scheduled_tasks_install;; status) systemctl list-timers 'remnanode-*' --all;; *) rn_die "Unknown schedule action";; esac; }
