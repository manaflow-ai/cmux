#!/usr/bin/env bash
# Verify every changed pinned asset manifest resolves to bytes in the release asset store.
#
# The caller supplies the previous revision (or this defaults to HEAD^1).  The
# checkout is the source of truth for the repository and the store client is
# selected by the pin type; there is no repository-specific controller API in
# this check.  A fresh cache is required so an old worker-local copy cannot
# hide a missing publication.
set -euo pipefail

SCRIPT_DIR="${PIN_ASSET_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
ROOT="${PIN_ASSET_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
BASE="${1:-HEAD^1}"
CACHE_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cmux-pinned-asset-check"

if ! git -C "$ROOT" rev-parse --verify "$BASE^{commit}" >/dev/null 2>&1; then
  echo "error: cannot resolve base revision $BASE" >&2
  exit 2
fi

changed_pins=()
while IFS= read -r relative; do
  [[ -n "$relative" ]] && changed_pins[${#changed_pins[@]}]="$relative"
done < <(
  git -C "$ROOT" diff --no-renames --name-only --diff-filter=AM "$BASE" HEAD -- ':(glob)**/*.pin.json' \
    scripts/cmux-next/cef-manifest.json
)

if ((${#changed_pins[@]} == 0)); then
  echo "No changed pinned asset manifests; store check skipped."
  exit 0
fi

verify_pin() {
  local relative="$1"
  case "$relative" in
    scripts/cmux-next/remote-browser-host.pin.json)
      echo "Checking $relative in the controller/R2 store"
      CMUX_NEXT_RB_HOST_CACHE_DIR="$CACHE_ROOT/remote-browser-host" \
        "$SCRIPT_DIR/ensure-remote-browser-host.sh" >/dev/null
      ;;
    scripts/cmux-next/cua-driver-sdk.pin.json|scripts/cmux-next/cua-helper-dev.pin.json)
      echo "Checking $relative in the controller/R2 store"
      CMUX_CUA_ASSET_CACHE_DIR="$CACHE_ROOT/cua" \
        "$SCRIPT_DIR/ensure-cua-pinned-asset.sh" "$ROOT/$relative" >/dev/null
      ;;
    scripts/cmux-next/cef-manifest.json)
      # The engine bytes must exist in R2, and their Chromium legal notices
      # must survive embed. cmux#33361 reverted a crash fix because the new
      # CEF archive had no CREDITS.html and the nightly signer then failed.
      local arch chromium cef_dir
      chromium="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["chromium"])' "$ROOT/$relative")"
      for arch in arm64 x86_64; do
        [[ "$arch" == x86_64 ]] && ! grep -q '"x86_64"' "$ROOT/$relative" && continue
        echo "Checking $relative ($arch) in R2 and Chromium credits"
        cef_dir="$(
          CMUX_CEF_MANIFEST="$ROOT/$relative" CMUX_CEF_CACHE_DIR="$CACHE_ROOT/cef" \
            CMUX_CEF_NO_STORE=1 CMUX_CEF_NO_GITHUB=1 \
            "$SCRIPT_DIR/ensure-cef.sh" --arch "$arch"
        )"
        (
          credits_probe="$(mktemp -d "${TMPDIR:-/tmp}/cmux-cef-credits.XXXXXX")"
          trap 'rm -rf "$credits_probe"' EXIT
          "$SCRIPT_DIR/install-cef-credits.sh" "$cef_dir" "$credits_probe" "$chromium"
          "$SCRIPT_DIR/check-cef-credits.sh" "$credits_probe/CREDITS.html"
        )
      done
      ;;
    *)
      echo "error: no pinned-asset verifier is registered for $relative" >&2
      return 1
      ;;
  esac
}

for relative in "${changed_pins[@]}"; do
  verify_pin "$relative"
done

echo "All changed pinned asset manifests resolve to verified store bytes and notices."
