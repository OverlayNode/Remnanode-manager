#!/usr/bin/env bash
# Globals below are consumed by sourced manager modules.
# shellcheck disable=SC2034
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export RN_ROOT="$PROJECT_DIR"
export REMNANODE_HOME="$TEST_DIR/node"
export REMNANODE_ETC="$TEST_DIR/etc"
export REMNANODE_STATE="$TEST_DIR/state"
export REMNANODE_BACKUPS="$TEST_DIR/backups"
export REMNANODE_GENERATED="$TEST_DIR/generated"
export REMNANODE_SNIPPETS="$TEST_DIR/snippets"
export REMNANODE_LOG="$TEST_DIR/manager.log"
export REMNANODE_PROC_SYS="$TEST_DIR/proc-sys"
export REMNANODE_PING_SYSCTL="$TEST_DIR/99-remnanode-ping.conf"

# shellcheck source=../lib/common.sh
source "$PROJECT_DIR/lib/common.sh"
# shellcheck source=../lib/network.sh
source "$PROJECT_DIR/lib/network.sh"
# shellcheck source=../lib/reality.sh
source "$PROJECT_DIR/lib/reality.sh"
# shellcheck source=../lib/snippets.sh
source "$PROJECT_DIR/lib/snippets.sh"
# shellcheck source=../lib/firewall.sh
source "$PROJECT_DIR/lib/firewall.sh"

RN_JSON=0 RN_DRY_RUN=0 RN_ASSUME_YES=1
rn_init
mkdir -p "$REMNANODE_PROC_SYS/net/ipv4" "$REMNANODE_PROC_SYS/net/ipv6/icmp"
printf '0\n' >"$REMNANODE_PROC_SYS/net/ipv4/icmp_echo_ignore_all"
printf '1\n' >"$REMNANODE_PROC_SYS/net/ipv6/icmp/echo_ignore_all"
[[ "$(firewall_ping_value 4)" == 0 ]]
[[ "$(firewall_ping_value 6)" == 1 ]]
[[ "$(firewall_ping_label 0)" == ENABLED ]]
[[ "$(firewall_ping_label 1)" == DISABLED ]]

for good in aa 0123 abcdef 0123456789abcdef; do validate_short_id "$good"; done
for bad in '' a abc ABCD 0123456789abcdef00 zz; do ! validate_short_id "$bad"; done

for _ in 1 2 3 4 5; do
  ids="$(reality_generate_shortids)"
  count="$(jq length <<<"$ids")"
  ((count >= 3 && count <= 12))
  [[ "$(jq 'unique|length' <<<"$ids")" == "$count" ]]
  while IFS= read -r id; do id="${id%$'\r'}"; validate_short_id "$id"; done < <(jq -r '.[]' <<<"$ids")
done

fixed="$(reality_generate_shortids 32)"
[[ "$(jq length <<<"$fixed")" == 32 ]]
printf '%s\n' "$fixed" >"$TEST_DIR/fixed.json"
validate_short_ids_json "$TEST_DIR/fixed.json"

snippets_validate_all
snippet_set_enabled google-dns true
jq -e '.enabled==true' "$RN_SNIPPET_DIR/google-dns.json" >/dev/null
snippet_set_enabled google-dns false

cat >"$TEST_DIR/base.json" <<'JSON'
{"inbounds":[],"outbounds":[{"tag":"DIRECT","protocol":"freedom"}],"routing":{"rules":[]}}
JSON
snippets_merge_into "$TEST_DIR/base.json" "$TEST_DIR/merged.json"
[[ "$(jq '[.outbounds[]|select(.tag=="DIRECT")]|length' "$TEST_DIR/merged.json")" == 1 ]]

cat >"$TEST_DIR/conflict.json" <<'JSON'
{"inbounds":[],"outbounds":[{"tag":"DIRECT","protocol":"socks","settings":{}}],"routing":{"rules":[]}}
JSON
! snippets_merge_into "$TEST_DIR/conflict.json" "$TEST_DIR/should-not-exist.json" 2>/dev/null

printf 'Manager tests passed.\n'
