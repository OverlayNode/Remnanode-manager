#!/usr/bin/env bash

session_ensure_tmux() {
  [[ -n "${TMUX:-}" || ! -t 0 || "${REMNANODE_NO_TMUX:-0}" == 1 ]] && return 0
  command -v tmux >/dev/null 2>&1 || return 0
  exec tmux new-session -A -s remnanode-manager "$RN_ROOT/remnanode menu"
}
