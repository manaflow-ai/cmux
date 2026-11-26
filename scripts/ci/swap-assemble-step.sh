#!/usr/bin/env bash
# A dev build served as the base build's bundle plus this commit's web and daemon layers.
#
# Leo, 2026-11-24: "if byte for byte you'd literally just get the same shit with the copy. then just do that.
# don't even bother telling them".
#
#   swap-assemble-step.sh BASE_JOB SHA TAG
#
# A cmuxterm-hq ci-step (the controller's allowlist, class isolated; cmux-ci build starts it once swap_serve.py's
# sampled checks are clean). Assembles BASE_JOB's published bundle, swaps SHA's web and daemon layers in with
# scripts/cmux-next/hot-apply.py, and writes the swapped per-file manifest to $OUT/swapped.manifest.json for the
# sampled check (swap_assemble.py sample). Publishing the app as TAG is the next piece (bundle_store.py publish).
set -euo pipefail
[[ $# -eq 3 ]] || { echo "usage: $0 BASE_JOB SHA TAG" >&2; exit 2; }
base_job=$1 sha=$2 tag=$3
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "SHA must be 40 lowercase hex" >&2; exit 2; }
[[ -z "$tag" || "$tag" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || { echo "bad TAG" >&2; exit 2; }
root=$(cd "$(dirname "$0")/../.." && pwd)
# The fleet client's install (client_install.py ships swap_assemble.py beside ci-client.py). A step's launchd domain
# need not have cmux-ci on PATH, so the installed default is tried too; a miss says so instead of exiting silently.
client=${CMUX_CI_CLIENT:-$(command -v cmux-ci || true)}
[[ -n "$client" ]] || client="$HOME/.local/bin/cmux-ci"
client=$(readlink -f "$client" 2>/dev/null || true)
tools=$(dirname "${client:-/nonexistent/x}")
[[ -f "$tools/swap_assemble.py" ]] || {
  echo "swap-assemble: no swap_assemble.py beside the fleet client (${client:-none found}); update the client" >&2
  exit 1
}
out=${CMUX_CI_ARTIFACT_DIR:-$(mktemp -d)}
CMUX_HOT_APPLY="$root/scripts/cmux-next/hot-apply.py" \
  python3 "$tools/swap_assemble.py" step --base-job "$base_job" --sha "$sha" --out "$out"
echo "swap-assemble: $out/swapped.manifest.json tag=${tag:-none}"
