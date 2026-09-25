#!/usr/bin/env bash
# Globals and colors are intentionally shared by sourced modules.
# shellcheck disable=SC2034

RN_VERSION="$(<"${RN_ROOT}/VERSION")"
RN_BASE_DIR="${REMNANODE_HOME:-/opt/remnanode}"
RN_ETC_DIR="${REMNANODE_ETC:-/etc/remnanode-manager}"
RN_STATE_DIR="${REMNANODE_STATE:-${RN_BASE_DIR}/manager-state}"
RN_BACKUP_DIR="${REMNANODE_BACKUPS:-${RN_BASE_DIR}/backups}"
RN_GENERATED_DIR="${REMNANODE_GENERATED:-${RN_BASE_DIR}/generated}"
RN_SNIPPET_DIR="${REMNANODE_SNIPPETS:-${RN_STATE_DIR}/snippets}"
RN_LOG_FILE="${REMNANODE_LOG:-/var/log/remnanode-manager.log}"
RN_COMPOSE_FILE="${REMNANODE_COMPOSE:-${RN_BASE_DIR}/docker-compose.yml}"

rn_colors() {
  RN_RESET='' RN_RED='' RN_GREEN='' RN_YELLOW='' RN_BLUE='' RN_BOLD=''
  if [[ -t 1 && "${NO_COLOR:-}" == "" && "${TERM:-dumb}" != dumb ]]; then
    RN_RESET=$'\033[0m'; RN_RED=$'\033[31m'; RN_GREEN=$'\033[32m'
    RN_YELLOW=$'\033[33m'; RN_BLUE=$'\033[34m'; RN_BOLD=$'\033[1m'
  fi
}

rn_init() {
  rn_colors
  umask 077
  mkdir -p "$RN_STATE_DIR" "$RN_BACKUP_DIR" "$RN_GENERATED_DIR" "$RN_SNIPPET_DIR"
  chmod 700 "$RN_STATE_DIR" "$RN_BACKUP_DIR" "$RN_GENERATED_DIR" "$RN_SNIPPET_DIR" 2>/dev/null || true
  snippets_seed_builtin
}

rn_log() {
  local level="$1"; shift
  local line
  line="[$(date -u +%FT%TZ)] [${level}] $*"
  if [[ "${RN_JSON:-0}" != 1 ]]; then printf '%s\n' "$line" >&2; fi
  mkdir -p "$(dirname "$RN_LOG_FILE")" 2>/dev/null || true
  printf '%s\n' "$line" >>"$RN_LOG_FILE" 2>/dev/null || true
}
rn_info() { rn_log INFO "$@"; }
rn_warn() { rn_log WARN "$@"; }
rn_error() { rn_log ERROR "$@"; }
rn_die() { rn_error "$@"; return 1; }

rn_require_root() {
  ((EUID == 0)) || rn_die "This operation requires root privileges."
}

rn_require_command() {
  command -v "$1" >/dev/null 2>&1 || rn_die "Required command is missing: $1"
}

rn_apt_get() {
  local timeout="${APT_LOCK_TIMEOUT:-600}"
  [[ "$timeout" =~ ^[0-9]+$ ]] || rn_die "APT_LOCK_TIMEOUT must be a number of seconds"
  if command -v fuser >/dev/null 2>&1 && fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock /var/lib/apt/lists/lock >/dev/null 2>&1; then
    rn_info "APT/dpkg is busy; waiting up to ${timeout} seconds for the package manager lock."
  fi
  apt-get -o "DPkg::Lock::Timeout=${timeout}" "$@"
}

rn_confirm() {
  local prompt="$1" default="${2:-no}" answer
  [[ "${RN_ASSUME_YES:-0}" == 1 ]] && return 0
  [[ -t 0 ]] || return 1
  if [[ "$default" == yes ]]; then
    read -r -p "${prompt} [Y/n] " answer
    [[ "${answer:-y}" =~ ^[Yy]$ ]]
  else
    read -r -p "${prompt} [y/N] " answer
    [[ "${answer:-n}" =~ ^[Yy]$ ]]
  fi
}

rn_json_bool() { [[ "$1" == 1 ]] && printf true || printf false; }

rn_backup_file() {
  local file="$1" scope="${2:-config}" dest
  [[ -e "$file" ]] || return 0
  dest="${RN_BACKUP_DIR}/$(date +%Y-%m-%d_%H-%M-%S)-${scope}"
  mkdir -p "$dest"
  cp -a "$file" "$dest/"
  printf '%s\n' "$dest"
}

rn_preview_diff() {
  local old="$1" new="$2"
  if [[ -e "$old" ]]; then diff -u -- "$old" "$new" || [[ $? == 1 ]]; else sed 's/^/+/' "$new"; fi
}

rn_atomic_apply() {
  local candidate="$1" target="$2" validator="${3:-}" healthcheck="${4:-}" backup=""
  [[ -f "$candidate" ]] || rn_die "Candidate does not exist: $candidate"
  [[ -z "$validator" ]] || "$validator" "$candidate" || rn_die "Validation failed; target unchanged."
  rn_preview_diff "$target" "$candidate"
  if [[ "${RN_DRY_RUN:-0}" == 1 ]]; then rn_info "Dry run: target unchanged."; return 0; fi
  rn_confirm "Apply this change?" no || rn_die "Cancelled."
  backup="$(rn_backup_file "$target" atomic 2>/dev/null || true)"
  mkdir -p "$(dirname "$target")"
  local staged="${target}.new.$$"
  cp -a "$candidate" "$staged"
  mv -f "$staged" "$target"
  if [[ -n "$healthcheck" ]] && ! "$healthcheck"; then
    if [[ -n "$backup" && -f "${backup}/$(basename "$target")" ]]; then
      cp -a "${backup}/$(basename "$target")" "$target"
    fi
    rn_die "Healthcheck failed; previous file restored."
  fi
}

rn_read_os_release() {
  if [[ -r /etc/os-release ]]; then . /etc/os-release; printf '%s' "${PRETTY_NAME:-${ID:-unknown}}"; else printf unknown; fi
}
