#!/usr/bin/env bash

ui_main_menu() {
  [[ -t 0 && -t 1 ]] || { system_status; return; }
  while true; do
    clear || true
    system_dashboard
    cat <<'EOF'

SYSTEM & MONITORING             NODE
 1. Server status               7. RemnaNode management
 2. Resource monitoring         8. Xray management
 3. Network                     9. Reality / Inbounds
 4. Ports & connections        10. Config Profile generator
 5. Logs                       11. Xray snippets
 6. Diagnostics                12. Selfsteal / SSL

NETWORK & ROUTING              ADMINISTRATION
14. WARP                       20. Updates
15. Tor                        21. Backup & Restore
16. Routing datasets           22. Scheduled tasks
17. Routing presets            23. Manager settings
18. Firewall                   24. Restart server
19. Network diagnostics

 R. Refresh                     Q. Exit
EOF
    local choice
    read -r -p "> " choice
    case "${choice,,}" in
      1|2) system_status; ui_pause ;;
      3) network_status; ui_pause ;;
      4) network_connections; ui_pause ;;
      5) logs_command node 100; ui_pause ;;
      6) diagnostics_doctor; ui_pause ;;
      7) node_menu ;;
      8) xray_menu ;;
      9) reality_menu ;;
      10) config_menu ;;
      11) snippets_menu ;;
      12) selfsteal_menu ;;
      14) warp_menu ;;
      15) tor_menu ;;
      16|17) routing_menu ;;
      18) firewall_menu ;;
      19) network_diagnostics; ui_pause ;;
      20) update_menu ;;
      21) backup_menu ;;
      22) scheduled_tasks_menu ;;
      23) manager_settings_menu ;;
      24) server_reboot ;;
      r) ;;
      q) return ;;
      *) rn_warn "Unknown selection"; sleep 1 ;;
    esac
  done
}

ui_pause() { read -r -p "Press Enter to continue..." _; }

ui_simple_menu() {
  local title="$1"; shift
  printf '\n%s%s%s\n' "$RN_BOLD" "$title" "$RN_RESET"
  printf '%s\n' "$@"
}

system_dashboard() {
  local status node_version xray_version cpu mem disk uptime ip4 ip6
  status="$(node_health_state)"; node_version="$(node_version)"; xray_version="$(xray_version)"
  cpu="$(system_cpu_percent)"; mem="$(system_memory_summary)"; disk="$(system_disk_percent)"
  uptime="$(system_uptime)"; ip4="$(network_public_ipv4 | head -n1)"; ip6="$(network_public_ipv6 | head -n1)"
  printf '%sREMNANODE MANAGER%s v%s\n' "$RN_BOLD" "$RN_RESET" "$RN_VERSION"
  printf 'Node %-10s %-18s Xray %s\n' "$status" "$node_version" "$xray_version"
  printf 'CPU %-8s RAM %-20s Disk %s\n' "$cpu" "$mem" "$disk"
  printf 'Load %-18s Uptime %s\n' "$(system_load)" "$uptime"
  printf 'IPv4 %s\nIPv6 %s\n' "${ip4:-unavailable}" "${ip6:-unavailable}"
}
