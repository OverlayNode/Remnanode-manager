#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/bin"
ln -s "$PROJECT_DIR/remnanode" "$TEST_DIR/bin/remnanode"

if [[ ! -h "$TEST_DIR/bin/remnanode" ]]; then
  printf 'Entrypoint symlink test skipped: filesystem does not support POSIX symlinks.\n'
  exit 0
fi

output="$(bash "$TEST_DIR/bin/remnanode" --help)"
grep -Fq 'Usage: remnanode' <<<"$output"

printf 'Entrypoint symlink test passed.\n'
