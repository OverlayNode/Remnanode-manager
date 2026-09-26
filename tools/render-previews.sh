#!/usr/bin/env bash
# Рендерит все шаблоны templates/sites/* той же функцией, что и install.sh,
# и снимает скриншоты preview.png через headless Chrome/Chromium.
#
# Использование: tools/render-previews.sh [ШАБЛОН...]
# Переменные: CHROME=/path/to/chrome, PORT=8765, WIDTH=1440, HEIGHT=900
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-8765}"
WIDTH="${WIDTH:-1440}"
HEIGHT="${HEIGHT:-900}"

find_chrome() {
  local candidate
  for candidate in \
    "${CHROME:-}" \
    "/c/Program Files/Google/Chrome/Application/chrome.exe" \
    "/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe" \
    "$(command -v google-chrome 2>/dev/null || true)" \
    "$(command -v chromium 2>/dev/null || true)" \
    "$(command -v chromium-browser 2>/dev/null || true)"; do
    [[ -n "$candidate" && -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
  done
  return 1
}

find_python() {
  local candidate
  for candidate in python3 python; do
    # В Windows python3 может оказаться заглушкой Microsoft Store.
    command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import http.server' >/dev/null 2>&1 \
      && { command -v "$candidate"; return 0; }
  done
  return 1
}

# shellcheck source=../install.sh
source "${PROJECT_DIR}/install.sh"
export INSTALL_LOG=/dev/null
trap - ERR
load_module sites

CHROME_BIN="$(find_chrome)" || { echo "Chrome/Chromium не найден (задай CHROME=...)" >&2; exit 1; }
PYTHON_BIN="$(find_python)" || { echo "python3 не найден" >&2; exit 1; }

WORK_DIR="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mapfile -t TEMPLATES < <(if (($#)); then printf '%s\n' "$@"; else templates_names "${PROJECT_DIR}/templates/sites"; fi)

for name in "${TEMPLATES[@]}"; do
  src="${PROJECT_DIR}/templates/sites/${name}"
  out="${WORK_DIR}/${name}"
  site_render_template "$src" "$out" "$(random_brand)" "node.example.com"

  (cd "$out" && exec "$PYTHON_BIN" -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
  SERVER_PID=$!
  for _ in {1..30}; do
    curl -fsS "http://127.0.0.1:${PORT}/" >/dev/null 2>&1 && break
    sleep 0.2
  done

  png="${src}/preview.png"
  png_native="$png"
  command -v cygpath >/dev/null 2>&1 && png_native="$(cygpath -w "$png")"
  "$CHROME_BIN" --headless=new --disable-gpu --hide-scrollbars --no-first-run \
    --force-device-scale-factor=1 --virtual-time-budget=4000 \
    --window-size="${WIDTH},${HEIGHT}" --screenshot="$png_native" \
    "http://127.0.0.1:${PORT}/" >/dev/null 2>&1 || true

  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=""

  if [[ -s "$png" ]]; then
    printf 'OK   %-18s %s\n' "$name" "$png"
  else
    printf 'FAIL %-18s\n' "$name" >&2
  fi
done
