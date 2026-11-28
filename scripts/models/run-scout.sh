#!/usr/bin/env bash
# The cmux automation `models-scout` runs this every 6 h. On a team Cloud machine (no Mac needs to be awake):
#   cmux automation create models-scout --command 'bash scripts/models/run-scout.sh' \
#     --repo manaflow-ai/cmux --ref feat-cmux-next --every 6h --timeout 20m --catch-up latest --target cloud \
#     --machine 'Cloud Machine 2'
#   cmux automation secret set models-scout NAME --target cloud   # each name scout.ts lists
# The Cloud runner fetches the newest feat-cmux-next into its own checkout before each run. On a Mac's
# runner (--command 'bash ~/cmux-worktrees/models-scout/scripts/models/run-scout.sh'), this script moves
# its own worktree (named models-scout, never a shared checkout) to the newest feat-cmux-next instead.
# Exit codes are the scout's: 0 ok, 3 a failed check (the runner shows and notifies it), 1 a crash.
set -euo pipefail
here="$(cd "$(dirname "$0")/../.." && pwd)"
export PATH="$HOME/.bun/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
# Only this worktree (made for the scout) is moved; a checkout someone works in is left alone.
if [ "$(basename "$here")" = models-scout ] && [ -z "$(git -C "$here" status --porcelain)" ]; then
  if git -C "$here" fetch --no-recurse-submodules -q origin feat-cmux-next; then
    git -C "$here" checkout -q --detach FETCH_HEAD
  else
    echo "fetch failed; running the scout this worktree has" >&2
  fi
fi
# A fresh Cloud machine may have no Bun: fetch the release CI pins (1.4.4) once into ~/.bun/bin. The zip is
# opened with unzip, bsdtar or python3, whichever the machine has (Bun's own installer needs unzip).
if ! command -v bun >/dev/null 2>&1; then
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) asset=bun-linux-x64 ;; Linux-aarch64|Linux-arm64) asset=bun-linux-aarch64 ;;
    Darwin-arm64) asset=bun-darwin-aarch64 ;; Darwin-x86_64) asset=bun-darwin-x64 ;;
    *) echo "no Bun build for $(uname -sm)" >&2; exit 1 ;;
  esac
  echo "installing bun 1.4.4 ($asset) into ~/.bun/bin" >&2
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/bun.zip" "https://github.com/oven-sh/bun/releases/download/bun-v1.4.4/$asset.zip" || { echo "bun download failed" >&2; exit 1; }
  if command -v unzip >/dev/null 2>&1; then unzip -q "$tmp/bun.zip" -d "$tmp"
  elif command -v bsdtar >/dev/null 2>&1; then bsdtar -xf "$tmp/bun.zip" -C "$tmp"
  else python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$tmp/bun.zip" "$tmp"; fi
  mkdir -p "$HOME/.bun/bin" && install -m 755 "$tmp/$asset/bun" "$HOME/.bun/bin/bun" && rm -rf "$tmp"
  bun --version >/dev/null || { echo "bun install failed" >&2; exit 1; }
fi
exec bun "$here/scripts/models/scout.ts" "$@"
