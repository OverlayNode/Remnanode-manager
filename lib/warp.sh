#!/usr/bin/env bash

RN_WARP_DIR="${RN_STATE_DIR}/warp"
RN_WARP_PROFILE="${RN_WARP_DIR}/wgcf-profile.conf"

warp_parse_value() { awk -F= -v section="$1" -v key="$2" '$0=="["section"]"{inside=1;next} /^\[/{inside=0} inside && $1~"^[[:space:]]*"key"[[:space:]]*$"{gsub(/^[ \t]+|[ \t]+$/,"",$2);print $2;exit}' "$RN_WARP_PROFILE"; }
warp_status_json() {
  local account=false config=false snippet=false
  [[ -f "${RN_WARP_DIR}/wgcf-account.toml" ]] && account=true; [[ -f "$RN_WARP_PROFILE" ]] && config=true; [[ -f "$(snippet_file warp-main)" ]] && snippet=true
  jq -n --arg mode XRAY_OUTBOUND --argjson account "$account" --argjson wireguardConfig "$config" --argjson outboundSnippet "$snippet" '{installed:($account and $wireguardConfig),mode:$mode,account:$account,wireguardConfig:$wireguardConfig,outboundSnippet:$outboundSnippet,systemDefaultRouteChanged:false}'
}
warp_status() { if [[ "${RN_JSON:-0}" == 1 ]]; then warp_status_json; else warp_status_json | jq -r '"WARP account      \(if .account then "OK" else "MISSING" end)\nWireGuard config  \(if .wireguardConfig then "OK" else "MISSING" end)\nXray outbound     \(if .outboundSnippet then "CONFIGURED" else "MISSING" end)\nMode              \(.mode)\nDefault route     unchanged"'; fi; }

warp_generate_outbound() {
  local tag="${1:-warp-main}" private public endpoint ipv4 ipv6 file tmp
  [[ "$tag" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || rn_die "Invalid outbound tag"
  [[ -r "$RN_WARP_PROFILE" ]] || rn_die "WARP WireGuard profile is missing"
  private="$(warp_parse_value Interface PrivateKey)"; ipv4="$(warp_parse_value Interface Address | cut -d, -f1 | xargs)"
  ipv6="$(warp_parse_value Interface Address | cut -s -d, -f2 | xargs)"; public="$(warp_parse_value Peer PublicKey)"; endpoint="$(warp_parse_value Peer Endpoint)"
  [[ -n "$private" && -n "$public" && -n "$endpoint" ]] || rn_die "Incomplete WireGuard profile"
  file="$(snippet_file "$tag")"; tmp="$(mktemp)"
  jq -n --arg id "$tag" --arg name "WARP outbound ($tag)" --arg tag "$tag" --arg privateKey "$private" --arg publicKey "$public" --arg endpoint "$endpoint" --arg ipv4 "$ipv4" --arg ipv6 "$ipv6" '{id:$id,name:$name,type:"outbound",version:1,enabled:true,managedBy:"remnanode-manager",requires:[],secret:true,config:{outbounds:[{tag:$tag,protocol:"wireguard",settings:{secretKey:$privateKey,address:([$ipv4,$ipv6]|map(select(length>0))),peers:[{publicKey:$publicKey,endpoint:$endpoint}]} }]}}' >"$tmp"
  snippet_validate_file "$tmp" || { rm -f "$tmp"; rn_die "Generated WARP snippet is invalid"; }
  [[ -f "$file" ]] && rn_preview_diff "$file" "$tmp"; mv "$tmp" "$file"; chmod 600 "$file"
  rn_info "WARP outbound '$tag' generated. The operating-system route was not changed."
}

warp_install() {
  rn_require_root; rn_require_command wgcf
  mkdir -p "$RN_WARP_DIR"; chmod 700 "$RN_WARP_DIR"
  if [[ ! -f "${RN_WARP_DIR}/wgcf-account.toml" ]]; then (cd "$RN_WARP_DIR" && wgcf register --accept-tos); fi
  if [[ ! -f "$RN_WARP_PROFILE" ]]; then (cd "$RN_WARP_DIR" && wgcf generate); fi
  chmod 600 "$RN_WARP_DIR"/*
  warp_generate_outbound "${1:-warp-main}"
  printf 'WARP installed\nMode: Xray outbound\nOutbound tag: %s\nDefault system route: unchanged\nRESULT: SUCCESS\n' "${1:-warp-main}"
}
warp_test() {
  warp_status_json | jq -e '.account and .wireguardConfig and .outboundSnippet' >/dev/null || rn_die "WARP is not fully configured"
  local tag="${1:-warp-main}" file id test_config trace pid
  file="$(snippet_file "$tag")"; [[ -f "$file" ]] || rn_die "WARP snippet not found: $tag"
  id="$(xray_container 2>/dev/null || true)"; [[ -n "$id" ]] || rn_die "Node/Xray container is not running"
  test_config="$(mktemp)"; trace="$(mktemp)"
  jq --arg tag "$tag" '{log:{loglevel:"warning"},inbounds:[{tag:"manager-warp-probe",listen:"127.0.0.1",port:19090,protocol:"socks",settings:{auth:"noauth",udp:false}}],outbounds:.config.outbounds,routing:{rules:[{type:"field",inboundTag:["manager-warp-probe"],outboundTag:$tag}]}}' "$file" >"$test_config"
  xray_validate_file "$test_config" || { rm -f "$test_config" "$trace"; rn_die "WARP probe config is invalid"; return 1; }
  docker cp "$test_config" "$id:/tmp/manager-warp-test.json" >/dev/null
  pid="$(docker exec "$id" sh -c 'xray run -config /tmp/manager-warp-test.json >/tmp/manager-warp-test.log 2>&1 & echo $!' | tr -d '\r')"
  sleep 1
  if docker exec "$id" sh -c 'command -v curl >/dev/null' && docker exec "$id" curl -fsS --max-time 15 --socks5-hostname 127.0.0.1:19090 https://www.cloudflare.com/cdn-cgi/trace >"$trace"; then
    docker exec "$id" kill "$pid" >/dev/null 2>&1 || true; docker exec "$id" rm -f /tmp/manager-warp-test.json /tmp/manager-warp-test.log >/dev/null 2>&1 || true
    rm -f "$test_config"
    if grep -q '^warp=on' "$trace"; then grep -E '^(ip|loc|warp)=' "$trace"; rm -f "$trace"; return 0; fi
    rm -f "$trace"; rn_die "Probe reached Cloudflare, but WARP was not detected"; return 1
  fi
  docker exec "$id" kill "$pid" >/dev/null 2>&1 || true; docker exec "$id" rm -f /tmp/manager-warp-test.json /tmp/manager-warp-test.log >/dev/null 2>&1 || true; rm -f "$test_config" "$trace"
  rn_die "Real outbound probe failed or curl is unavailable in the Node container"
}
warp_command() { case "${1:-status}" in status) warp_status;; install) warp_install "${2:-warp-main}";; outbound) warp_generate_outbound "${2:-warp-main}";; test) warp_test "${2:-warp-main}";; remove) rn_require_root; rn_confirm "Remove WARP credentials and snippets?" no || return; rn_warn "Remove individual WARP snippets first; credentials kept to prevent accidental lockout.";; *) rn_die "Unknown WARP action";; esac; }
warp_menu() { ui_simple_menu "WARP" "Default mode: XRAY_OUTBOUND" "No wg-quick/system default-route operation is performed."; warp_status; ui_pause; }
