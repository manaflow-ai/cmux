#!/usr/bin/env bash
# Fleet entry for the Chromium helper check: builds a tagged cmux-next app at this checkout and runs
# scripts/cmux-next/cef-helper-check.py against it (renderer and GPU children start from their own
# "(Renderer)" / "(GPU)" helper apps, the page's JavaScript runs, no V8 CodeRange OOM). Pass
# --arg=--release-signing to sign the plain helper as a release does (hardened runtime, no
# allow-jit): a renderer started from it then dies with SIGTRAP, as in the cmux.43 NIGHTLY.
# --cef-manifest-from REF (first arguments) builds with the CEF that REF's cef-manifest.json pins (a
# pin commit not yet on feat-cmux-next): its artifacts are still checked against the manifest's sha256.
# Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --label measure --script scripts/measure/cef-helpers.sh --ref <sha> --artifact artifacts/cef-helpers.json [--arg=--cef-manifest-from --arg=<sha>] [--arg=--release-signing]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
tag="cefhelpers"
for sub in ghostty ghostty-next; do
  [ -e "$sub/.git" ] || git submodule update --init --depth 1 "$sub"
done
if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
  rm -rf GhosttyKit.xcframework
  if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
    export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
  fi
  ./scripts/download-prebuilt-ghosttykit.sh
fi
out="$(mktemp -d)"
if [ "${1:-}" = "--cef-manifest-from" ]; then
  manifest_ref="${2:?--cef-manifest-from needs a commit}"
  shift 2
  # A fleet warm checkout has no origin remote and a depth-1 fetch is a whole tree: a commit that
  # is not here yet gives its manifest from the public repository (a pushed scratch branch tip).
  case "$manifest_ref" in *[!0-9a-f]*) echo "cef-helpers: --cef-manifest-from takes a commit sha" >&2; exit 2;; esac
  if git cat-file -e "${manifest_ref}^{commit}" 2>/dev/null; then
    git show "${manifest_ref}:scripts/cmux-next/cef-manifest.json" > "$out/cef-manifest.json"
  else
    curl -fsSL --retry 3 --max-time 60 -o "$out/cef-manifest.json" \
      "https://raw.githubusercontent.com/manaflow-ai/cmux/$manifest_ref/scripts/cmux-next/cef-manifest.json"
  fi
  export CMUX_CEF_MANIFEST="$out/cef-manifest.json"
  echo "cef-helpers: CEF from $manifest_ref: $(grep -m1 '"version"' "$CMUX_CEF_MANIFEST")"
fi
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin"; do
  [ -n "$account_home" ] && [ -d "$tool_dir" ] && export PATH="$tool_dir:$PATH"
done
RUNNER_TEMP="$out" GITHUB_PATH="$out/bun-path" ./scripts/cmux-next/private-bun.sh
PATH="$(tail -n 1 "$out/bun-path"):$PATH"
export PATH
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "cef-helpers: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
mkdir -p artifacts
exec python3 scripts/cmux-next/cef-helper-check.py --tag "$tag" --app "$app" --out "$out" --json artifacts/cef-helpers.json "$@"
