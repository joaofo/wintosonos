#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SRC_REPO="https://github.com/joaofo/artifacts.git"
SRC_SUBDIR="sonos_redirector"

printf 'Cloning source repository...\n'
git clone --depth 1 "$SRC_REPO" "$TMP_DIR/artifacts"

if [[ ! -d "$TMP_DIR/artifacts/$SRC_SUBDIR" ]]; then
  echo "Source subdirectory '$SRC_SUBDIR' not found in artifacts repo" >&2
  exit 1
fi

printf 'Syncing files into %s ...\n' "$ROOT_DIR"
rsync -a --delete \
  --exclude='.git/' \
  --exclude='scripts/move_from_artifacts_sonos_redirector.sh' \
  "$TMP_DIR/artifacts/$SRC_SUBDIR/" "$ROOT_DIR/"

printf '\nDone. Review changes with:\n'
printf '  git -C %q status\n' "$ROOT_DIR"
printf '  git -C %q diff\n' "$ROOT_DIR"
