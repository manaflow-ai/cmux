#!/usr/bin/env bash
# Stages the optional agent screen detector of one macOS target for publication
# (cmux-tui-build-package.yml "Stage binary", scripts/ci/macos-cross.sh hosts):
# copies <release-dir>/cmux-agent-screen-detection to <dest>, or, when that
# build produced none, removes a stale <dest> and prints a GitHub warning
# annotation. The detector never blocks publication; the app then runs no
# default detector (cmux-tui spec/plugins.md, "Bundled default").
# Bash 3.2 compatible (macOS runners).
#
# usage: stage-agent-detector.sh <release-dir> <target> <dest>
set -euo pipefail
[[ $# -eq 3 ]] || { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
release_dir="$1" target="$2" dest="$3"
if [[ -f "$release_dir/cmux-agent-screen-detection" ]]; then
  mkdir -p "$(dirname "$dest")"
  # Remove first: overwriting a Mach-O in place keeps a stale signature.
  rm -f "$dest"
  cp "$release_dir/cmux-agent-screen-detection" "$dest"
  chmod 755 "$dest"
else
  rm -f "$dest"
  echo "::warning title=agent screen detector missing::$target"
fi
