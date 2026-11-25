#!/usr/bin/env bash
# Sign cmux-tui/<commit>/release.json for the commits of this run's window that share a published tree
# and have none (an alias of cmux-tui/tree/<key>/release.json; scripts/ci/cmux-machine-channel.py alias),
# then move the Linux release channel when the alias is newer (scripts/ci/cmux-machine-channel-point.sh).
# A commit whose run adopted an earlier commit's tree built nothing, so no run signed its release file.
#
# Used by mark-tree-commits in .github/workflows/cmux-tui-artifacts.yml, after the tree-commit markers.
#
# usage: scripts/ci/cmux-linux-release-aliases.sh DIR [--window N] [--channel C]
#
# Walks `git rev-list --first-parent -n N HEAD`, oldest first, without HEAD itself: HEAD's own run signs
# it when it built (point-machine-channel), else the next push's walk does. Each commit's tree key is
# computed here from the source (cmux_tui_tree_key.py --version v2, only when the commit's key script
# and input list are this checkout's), never read from the unsigned tree-commit marker. The tree's
# release.json must verify and name that key (cmux-machine-channel.py alias checks both).
#
# DIR is a private scratch directory (mode 700). Reads SIGNING_KEY, R2_ENDPOINT and the R2 credentials
# (AWS_*) from the environment, for cmux-machine-channel-point.sh. Delivery, not a gate: a commit that
# fails is a warning and the walk goes on; the exit status is 0 unless the arguments are wrong.
set -euo pipefail
dir=${1:-}
[[ -n "$dir" && -d "$dir" ]] || { echo "usage: $0 DIR [--window N] [--channel C]" >&2; exit 2; }
shift
window=40 channel=feat-cmux-next
while [[ $# -gt 0 ]]; do
  case "$1" in
    --window) window="${2:-}"; shift 2 ;;
    --channel) channel="${2:-}"; shift 2 ;;
    *) echo "error: unknown argument $1" >&2; exit 2 ;;
  esac
done
[[ "$window" =~ ^[1-9][0-9]?$ ]] || { echo "error: --window must be 1 to 99" >&2; exit 2; }
[[ "$channel" =~ ^[a-z0-9-]+$ ]] || { echo "error: bad --channel" >&2; exit 2; }
files=${CMUX_FILES_URL:-https://files.cmux.com}
ptr=scripts/cmux-next/web-ota-pointer.py
keys=Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Resources/web-update-keys.json

key_definition() { # REV: the blobs that define the tree key at REV (as tree-commit-marker.sh)
  local script inputs
  script="$(git rev-parse --verify -q "$1:scripts/ci/cmux_tui_tree_key.py")" || return 1
  inputs="$(git rev-parse --verify -q "$1:scripts/cmux-next/cmux-tui-tree-inputs.txt")" || return 1
  echo "$script $inputs"
}
fetch() { # URL OUT: 200, 404, or another code (a read failure; 000 when curl got no answer)
  local code
  code="$(curl -sS --max-time 60 -o "$2" -w '%{http_code}' "$1?alias=${GITHUB_RUN_ID:-local}" 2>/dev/null)" || true
  [[ "$code" =~ ^[0-9]{3}$ ]] && printf '%s' "$code" || printf 000
}

key_def="$(key_definition HEAD)" || { echo "::warning::no tree key definition in this checkout; no aliases signed"; exit 0; }
head="$(git rev-parse HEAD)"
git rev-list --first-parent -n "$window" HEAD > "$dir/revs" \
  || { echo "::warning::could not list HEAD's first-parent history; no aliases signed"; exit 0; }
signed=0 skipped=0 failed=0
while read -r rev; do
  [[ "$rev" == "$head" ]] && continue
  work="$dir/${rev:0:12}"
  mkdir -p "$work" && chmod 700 "$work"
  code="$(fetch "$files/cmux-tui/$rev/release.json" "$work/own.json")"
  if [[ "$code" == 200 ]]; then continue; fi
  if [[ "$code" != 404 ]]; then
    echo "::warning::could not read the release file of ${rev:0:12} (HTTP $code); not signing it this run"
    failed=$((failed + 1)); continue
  fi
  if [[ "$(key_definition "$rev" 2>/dev/null)" != "$key_def" ]]; then
    skipped=$((skipped + 1)); continue
  fi
  key="$(scripts/ci/timeout.sh 90 python3 scripts/ci/cmux_tui_tree_key.py --version v2 "$rev" 2>/dev/null)" || key=""
  [[ "$key" =~ ^[0-9a-f]{40}$ ]] || { skipped=$((skipped + 1)); continue; }
  code="$(fetch "$files/cmux-tui/tree/$key/release.json" "$work/tree.json")"
  if [[ "$code" == 404 ]]; then skipped=$((skipped + 1)); continue; fi
  if [[ "$code" != 200 ]]; then
    echo "::warning::could not read the release file of tree ${key:0:12} (HTTP $code); not signing ${rev:0:12} this run"
    failed=$((failed + 1)); continue
  fi
  # sequence orders the channel: above the published pointer's (0 when missing or unverifiable).
  curl -sS --max-time 60 -o "$work/current.json" \
    "$files/cmux-tui/channels/linux-$channel.json?alias=${GITHUB_RUN_ID:-local}" 2>/dev/null || true
  current="$(python3 "$ptr" sequence --pointer "$work/current.json" --keys "$keys" --channel "$channel" 2>/dev/null)" || current=0
  [[ "$current" =~ ^[0-9]+$ ]] || current=0
  if ! python3 scripts/ci/cmux-machine-channel.py alias --tree-release "$work/tree.json" --keys "$keys" \
      --tree-key "$key" --channel "$channel" --commit "$rev" --committed-at "$(git show -s --format=%ct "$rev")" \
      --min-sequence "$((current + 1))" --out "$work/payload.json"; then
    echo "::warning::could not make the release file of ${rev:0:12} from tree ${key:0:12}"
    failed=$((failed + 1)); continue
  fi
  if scripts/ci/cmux-machine-channel-point.sh "$work/payload.json" "$work"; then
    echo "signed the release file of ${rev:0:12} (tree ${key:0:12})"
    signed=$((signed + 1))
  else
    echo "::warning::the release file of ${rev:0:12} (tree ${key:0:12}) was not published"
    failed=$((failed + 1))
  fi
done < <(tac "$dir/revs")
echo "Linux release aliases: $signed signed, $skipped without a signed tree or key, $failed failed, window $window"
