#!/usr/bin/env bash

RN_PING_SYSCTL_FILE="${REMNANODE_PING_SYSCTL:-/etc/sysctl.d/99-remnanode-ping.conf}"
RN_PROC_SYS="${REMNANODE_PROC_SYS:-/proc/sys}"

firewall_preview() { ufw status numbered 2>/dev/null || true; }
firewall_allow() {
  rn_require_root; local port="$1" source="${2:-}"
  [[ "$port" =~ ^[0-9]+/(tcp|udp)$ ]] || rn_die "Use PORT/tcp or PORT/udp"
  rn_warn "Current firewall:"; firewall_preview
  [[ "${RN_DRY_RUN:-0}" == 1 ]] && { printf 'ufw allow from %q to any port %q proto %q\n' "${source:-any}" "${port%/*}" "${port#*/}"; return; }
  local ssh_port; ssh_port="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2;exit}')"; ufw allow "${ssh_port:-22}/tcp" comment remnanode-manager >/dev/null
  if [[ -n "$source" ]]; then ufw allow from "$source" to any port "${port%/*}" proto "${port#*/}" comment remnanode-manager; else ufw allow "$port" comment remnanode-manager; fi
}
firewall_ping_value() {
  local family="$1" path
  case "$family" in
    4) path="${RN_PROC_SYS}/net/ipv4/icmp_echo_ignore_all" ;;
    6) path="${RN_PROC_SYS}/net/ipv6/icmp/echo_ignore_all" ;;
    *) return 2 ;;
  esac
  [[ -r "$path" ]] && tr -d '[:space:]' <"$path" || printf unsupported
}

firewall_ping_label() {
  case "$1" in 0) printf ENABLED;; 1) printf DISABLED;; *) printf UNSUPPORTED;; esac
}

firewall_ping_status() {
  local ipv4 ipv6
  ipv4="$(firewall_ping_value 4)"; ipv6="$(firewall_ping_value 6)"
  if [[ "${RN_JSON:-0}" == 1 ]]; then
    jq -n --arg ipv4 "$ipv4" --arg ipv6 "$ipv6" --arg config "$RN_PING_SYSCTL_FILE" \
      '{ipv4:{supported:($ipv4!="unsupported"),respondsToEcho:($ipv4=="0")},ipv6:{supported:($ipv6!="unsupported"),respondsToEcho:($ipv6=="0")},configFile:$config}'
  else
    printf 'IPv4 ping: %s\n' "$(firewall_ping_label "$ipv4")"
    printf 'IPv6 ping: %s\n' "$(firewall_ping_label "$ipv6")"
    printf 'Managed config: %s\n' "$([[ -f "$RN_PING_SYSCTL_FILE" ]] && echo "$RN_PING_SYSCTL_FILE" || echo none)"
  fi
}

firewall_ping_disable() {
  rn_require_root
  local candidate backup=""
  candidate="$(mktemp)"
  {
    printf '# Managed by RemnaNode Manager. Ignore ICMP echo requests only.\n'
    printf 'net.ipv4.icmp_echo_ignore_all = 1\n'
    [[ -e "${RN_PROC_SYS}/net/ipv6/icmp/echo_ignore_all" ]] && printf 'net.ipv6.icmp.echo_ignore_all = 1\n'
  } >"$candidate"
  rn_preview_diff "$RN_PING_SYSCTL_FILE" "$candidate"
  if [[ "${RN_DRY_RUN:-0}" == 1 ]]; then rm -f "$candidate"; rn_info "Dry run: ping settings unchanged."; return 0; fi
  rn_warn "The server will stop answering ICMP echo requests. TCP/UDP services and essential ICMP errors remain enabled."
  rn_confirm "Disable IPv4/IPv6 ping replies?" no || { rm -f "$candidate"; rn_die "Cancelled."; return 1; }
  backup="$(rn_backup_file "$RN_PING_SYSCTL_FILE" ping 2>/dev/null || true)"
  install -D -m 644 "$candidate" "$RN_PING_SYSCTL_FILE"; rm -f "$candidate"
  if ! sysctl -p "$RN_PING_SYSCTL_FILE" >/dev/null; then
    if [[ -n "$backup" && -f "${backup}/$(basename "$RN_PING_SYSCTL_FILE")" ]]; then cp -a "${backup}/$(basename "$RN_PING_SYSCTL_FILE")" "$RN_PING_SYSCTL_FILE"; else rm -f "$RN_PING_SYSCTL_FILE"; fi
    rn_die "Could not apply ping settings; managed config was rolled back."
    return 1
  fi
  firewall_ping_status
}

firewall_ping_enable() {
  rn_require_root
  rn_preview_diff "$RN_PING_SYSCTL_FILE" /dev/null
  if [[ "${RN_DRY_RUN:-0}" == 1 ]]; then rn_info "Dry run: ping settings unchanged."; return 0; fi
  rn_confirm "Enable IPv4/IPv6 ping replies?" yes || { rn_die "Cancelled."; return 1; }
  rn_backup_file "$RN_PING_SYSCTL_FILE" ping >/dev/null 2>&1 || true
  sysctl -w net.ipv4.icmp_echo_ignore_all=0 >/dev/null
  [[ -e "${RN_PROC_SYS}/net/ipv6/icmp/echo_ignore_all" ]] && sysctl -w net.ipv6.icmp.echo_ignore_all=0 >/dev/null
  rm -f "$RN_PING_SYSCTL_FILE"
  firewall_ping_status
}

firewall_ping_command() {
  case "${1:-status}" in
    status) firewall_ping_status ;;
    disable) firewall_ping_disable ;;
    enable) firewall_ping_enable ;;
    *) rn_die "Use: remnanode firewall ping status|disable|enable" ;;
  esac
}

firewall_command() {
  case "${1:-status}" in
    status) firewall_preview ;;
    allow) [[ -n "${2:-}" ]] || rn_die "Port/protocol required"; firewall_allow "$2" "${3:-}" ;;
    ping) firewall_ping_command "${2:-status}" ;;
    *) rn_die "Unknown firewall action" ;;
  esac
}

firewall_menu() {
  while true; do
    ui_simple_menu "Firewall" "1. UFW status" "2. Ping status" "3. Disable ping replies" "4. Enable ping replies" "B. Back"
    local choice; read -r -p "> " choice
    case "${choice,,}" in
      1) firewall_preview; ui_pause ;;
      2) firewall_ping_status; ui_pause ;;
      3) firewall_ping_disable; ui_pause ;;
      4) firewall_ping_enable; ui_pause ;;
      b) return ;;
      *) rn_warn "Unknown selection" ;;
    esac
  done
}
