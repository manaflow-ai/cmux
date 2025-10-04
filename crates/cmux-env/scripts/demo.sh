#!/usr/bin/env bash
set -euo pipefail

# Demo script that runs inside Docker. It builds an image with envd/envctl and
# opens an interactive shell (bash/zsh/fish) with hooks installed.

here_dir() { cd -- "$(dirname -- "$0")/.." && pwd; }
ROOT_DIR="$(here_dir)"
cd "$ROOT_DIR"

SHELL_CHOICE="${1:-bash}"

echo "[cmux-env] Building demo image (this may take a minute the first time)..."
docker build --progress=plain -t cmux-env:demo -f Dockerfile.demo .

echo "[cmux-env] Starting demo container (shell: $SHELL_CHOICE)"
exec docker run --rm -it \
  -e DEMO_SHELL="$SHELL_CHOICE" \
  cmux-env:demo
