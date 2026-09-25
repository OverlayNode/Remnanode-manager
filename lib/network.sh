#!/usr/bin/env bash

network_is_public_ipv4() {
  local ip="$1" a b c d
  IFS=. read -r a b c d <<<"$ip"
  [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
  ((a<=255 && b<=255 && c<=255 && d<=255)) || return 1
  ((a==0 || a==10 || a==127 || a>=224)) && return 1
  ((a==100 && b>=64 && b<=127)) && return 1
  ((a==169 && b==254)) && return 1
  ((a==172 && b>=16 && b<=31)) && return 1
  ((a==192 && b==168)) && return 1
  ((a==198 && (b==18 || b==19))) && return 1
  return 0
}

network_is_public_ipv6() {
  local ip="${1,,}"
  [[ "$ip" == *:* ]] || return 1
  [[ "$ip" == ::1 || "$ip" == :: || "$ip" == fe8* || "$ip" == fe9* || "$ip" == fea* || "$ip" == feb* || "$ip" == fc* || "$ip" == fd* ]] && return 1
  return 0
}

network_public_ipv4() {
  local ip
  while read -r ip; do network_is_public_ipv4 "$ip" && printf '%s\n' "$ip"; done < <(ip -o -4 addr show scope global 2>/dev/null | awk '{sub(/\/.*/,"",$4);print $4}')
}
network_public_ipv6() {
  local ip
  while read -r ip; do network_is_public_ipv6 "$ip" && printf '%s\n' "$ip"; done < <(ip -o -6 addr show scope global 2>/dev/null | awk '{sub(/\/.*/,"",$4);print $4}')
}
network_status() { ip -brief address 2>/dev/null || true; printf 'Public IPv4:\n'; network_public_ipv4; printf 'Public IPv6:\n'; network_public_ipv6; ip route show default 2>/dev/null || true; }
network_connections() { ss -tulpn 2>/dev/null || true; }
network_diagnostics() { ip route show default; getent hosts github.com || true; getent hosts registry-1.docker.io || true; ip link | awk '/mtu/{print $2,$5}'; }
