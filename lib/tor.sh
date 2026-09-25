#!/usr/bin/env bash

tor_install() { rn_require_root; rn_apt_get update; rn_apt_get install -y tor; systemctl enable --now tor; rn_info "Tor installed. Routing was not enabled."; }
tor_create_outbound() {
  local tag="${1:-tor-main}" file
  file="$(snippet_file "$tag")"
  jq -n --arg id "$tag" --arg tag "$tag" '{id:$id,name:"Tor SOCKS outbound",type:"outbound",version:1,enabled:true,managedBy:"remnanode-manager",requires:[],config:{outbounds:[{tag:$tag,protocol:"socks",settings:{servers:[{address:"127.0.0.1",port:9050}]}}]}}' >"$file"
}
tor_create_onion_routing() { local tag="${1:-tor-main}"; jq -n --arg tag "$tag" '{id:"onion-via-tor",name:".onion via Tor",type:"routing",version:1,enabled:false,managedBy:"remnanode-manager",requires:[$tag],config:{routing:{rules:[{type:"field",domain:["regexp:.*\\.onion$"],outboundTag:$tag}]}}}' >"$(snippet_file onion-via-tor)"; }
tor_command() { case "${1:-status}" in status) systemctl is-active tor 2>/dev/null || true;; install) tor_install;; outbound) tor_create_outbound "${2:-tor-main}";; routing) tor_create_onion_routing "${2:-tor-main}";; *) rn_die "Unknown Tor action";; esac; }
tor_menu() { ui_simple_menu "Tor" "Installation and routing are separate actions." "remnanode tor install|outbound|routing"; ui_pause; }
