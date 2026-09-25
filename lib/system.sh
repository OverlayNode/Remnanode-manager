#!/usr/bin/env bash

system_cpu_percent() {
  if [[ -r /proc/stat ]]; then
    local _cpu user nice sys idle iowait irq soft steal total busy
    read -r _cpu user nice sys idle iowait irq soft steal _ </proc/stat
    total=$((user+nice+sys+idle+iowait+irq+soft+steal)); busy=$((total-idle-iowait))
    sleep 0.1
    local _cpu2 user2 nice2 sys2 idle2 iowait2 irq2 soft2 steal2 total2 busy2 delta
    read -r _cpu2 user2 nice2 sys2 idle2 iowait2 irq2 soft2 steal2 _ </proc/stat
    total2=$((user2+nice2+sys2+idle2+iowait2+irq2+soft2+steal2)); busy2=$((total2-idle2-iowait2)); delta=$((total2-total))
    ((delta > 0)) && printf '%d%%' "$(((busy2-busy)*100/delta))" || printf '0%%'
  else printf 'n/a'; fi
}

system_memory_summary() {
  if [[ -r /proc/meminfo ]]; then
    local total available used
    total="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"; available="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)"
    used=$((total-available)); printf '%s / %s' "$(numfmt --to=iec $((used*1024)) 2>/dev/null || echo "$((used/1024))M")" "$(numfmt --to=iec $((total*1024)) 2>/dev/null || echo "$((total/1024))M")"
  else printf 'n/a'; fi
}
system_disk_percent() { df -P "${RN_BASE_DIR}" 2>/dev/null | awk 'NR==2{print $5}' || printf 'n/a'; }
system_uptime() { uptime -p 2>/dev/null | sed 's/^up //' || printf 'n/a'; }
system_load() { awk '{print $1" "$2" "$3}' /proc/loadavg 2>/dev/null || printf 'n/a'; }

system_status() {
  local json="${1:-}"
  [[ "$json" == --json ]] && RN_JSON=1
  local host os kernel arch cpu_model cores cpu_pct load memory swap disk uptime docker_v compose_v node_v xray_v ipv4 ipv6 node_state
  host="$(hostname 2>/dev/null || echo unknown)"; os="$(rn_read_os_release)"; kernel="$(uname -r)"; arch="$(uname -m)"
  cpu_model="$(awk -F: '/model name/{gsub(/^[ \t]+/,"",$2);print $2;exit}' /proc/cpuinfo 2>/dev/null || true)"
  cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0)"; cpu_pct="$(system_cpu_percent)"; load="$(system_load)"
  memory="$(system_memory_summary)"; swap="$(free -h 2>/dev/null | awk '/^Swap:/{print $3" / "$2}' || echo n/a)"
  disk="$(system_disk_percent)"; uptime="$(system_uptime)"; docker_v="$(docker_version)"; compose_v="$(docker_compose_version)"
  node_v="$(node_version)"; xray_v="$(xray_version)"; ipv4="$(network_public_ipv4 | paste -sd, -)"; ipv6="$(network_public_ipv6 | paste -sd, -)"; node_state="$(node_health_state)"
  if [[ "${RN_JSON:-0}" == 1 ]]; then
    jq -n --arg hostname "$host" --arg os "$os" --arg kernel "$kernel" --arg architecture "$arch" --arg cpuModel "$cpu_model" --argjson cpuCores "$cores" --arg cpuUsage "$cpu_pct" --arg load "$load" --arg memory "$memory" --arg swap "$swap" --arg disk "$disk" --arg uptime "$uptime" --arg docker "$docker_v" --arg compose "$compose_v" --arg nodeVersion "$node_v" --arg xrayVersion "$xray_v" --arg nodeStatus "$node_state" --arg ipv4 "$ipv4" --arg ipv6 "$ipv6" '{hostname:$hostname,os:$os,kernel:$kernel,architecture:$architecture,cpu:{model:$cpuModel,cores:$cpuCores,usage:$cpuUsage,load:$load},memory:$memory,swap:$swap,disk:$disk,uptime:$uptime,docker:$docker,compose:$compose,node:{status:$nodeStatus,version:$nodeVersion},xray:{version:$xrayVersion},ip:{ipv4:($ipv4|split(",")|map(select(length>0))),ipv6:($ipv6|split(",")|map(select(length>0)))}}'
  else
    printf 'Host: %s | OS: %s | Kernel: %s | Arch: %s\n' "$host" "$os" "$kernel" "$arch"
    printf 'CPU: %s (%s cores), usage %s, load %s\n' "$cpu_model" "$cores" "$cpu_pct" "$load"
    printf 'RAM: %s | Swap: %s | Disk: %s | Uptime: %s\n' "$memory" "$swap" "$disk" "$uptime"
    printf 'Docker: %s | Compose: %s\nNode: %s (%s) | Xray: %s\nIPv4: %s\nIPv6: %s\n' "$docker_v" "$compose_v" "$node_state" "$node_v" "$xray_v" "${ipv4:-none}" "${ipv6:-none}"
  fi
}

resource_monitor() { system_status; }
scheduled_tasks_menu() { ui_simple_menu "Scheduled tasks" "Run: remnanode schedule install|status"; scheduled_tasks_command status 2>/dev/null || true; ui_pause; }
manager_settings_menu() { ui_simple_menu "Manager settings" "State: $RN_STATE_DIR" "Generated: $RN_GENERATED_DIR"; ui_pause; }
server_reboot() { rn_require_root; rn_confirm "Reboot server now?" no || return; printf '%s\n' "reboot requested $(date -u +%FT%TZ)" >"$RN_STATE_DIR/pending-operation"; systemctl reboot; }
