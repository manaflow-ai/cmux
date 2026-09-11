#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$ROOT_DIR/chromium-patches/aws-m1-ultra-verified-owl-host.json"
CHROMIUM_SRC="${CHROMIUM_SRC:-$HOME/chromium/src}"
MODE="applied"

usage() {
  cat >&2 <<EOF
usage: $0 [--chromium-src <path>] [--manifest <path>] [--mode applied|clean-apply|fork-remote]

Modes:
  applied      Verify the checkout is the recorded fork commit, or the legacy
               recorded base plus recorded patch.
  clean-apply  Verify the recorded patch applies to the recorded base in a temp clone.
  fork-remote  Verify the recorded fork branch exists at the recorded commit.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --chromium-src)
      shift
      [ "$#" -gt 0 ] || { usage; exit 2; }
      CHROMIUM_SRC="$1"
      ;;
    --manifest)
      shift
      [ "$#" -gt 0 ] || { usage; exit 2; }
      MANIFEST="$1"
      ;;
    --mode)
      shift
      [ "$#" -gt 0 ] || { usage; exit 2; }
      MODE="$1"
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
  shift
done

if [ "$MODE" != "fork-remote" ] && [ ! -d "$CHROMIUM_SRC/.git" ]; then
  echo "missing Chromium checkout: $CHROMIUM_SRC" >&2
  exit 1
fi

if [ ! -f "$MANIFEST" ]; then
  echo "missing manifest: $MANIFEST" >&2
  exit 1
fi

read_manifest() {
  /usr/bin/python3 - "$MANIFEST" "$ROOT_DIR" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
root = pathlib.Path(sys.argv[2])
patch = root / manifest["patchFile"]
print(manifest["chromiumBaseCommit"])
print(manifest.get("chromiumForkRepo", ""))
print(manifest.get("chromiumForkBranch", ""))
print(manifest.get("chromiumForkCommit", ""))
print(patch)
print(manifest["patchSHA256"])
print(manifest["patchLineCount"])
print("\n".join(manifest.get("requiredBuildOutputs", [])))
PY
}

manifest_values_file="$(mktemp "${TMPDIR:-/tmp}/owl-chromium-manifest.XXXXXX")"
read_manifest > "$manifest_values_file"
EXPECTED_BASE="$(sed -n '1p' "$manifest_values_file")"
FORK_REPO="$(sed -n '2p' "$manifest_values_file")"
FORK_BRANCH="$(sed -n '3p' "$manifest_values_file")"
EXPECTED_FORK_COMMIT="$(sed -n '4p' "$manifest_values_file")"
PATCH_FILE="$(sed -n '5p' "$manifest_values_file")"
EXPECTED_PATCH_SHA="$(sed -n '6p' "$manifest_values_file")"
EXPECTED_PATCH_LINES="$(sed -n '7p' "$manifest_values_file")"
REQUIRED_OUTPUTS=()
while IFS= read -r output; do
  REQUIRED_OUTPUTS+=("$output")
done < <(sed -n '8,$p' "$manifest_values_file")
rm -f "$manifest_values_file"

actual_patch_sha="$(shasum -a 256 "$PATCH_FILE" | awk '{print $1}')"
actual_patch_lines="$(wc -l < "$PATCH_FILE" | tr -d ' ')"

if [ "$actual_patch_sha" != "$EXPECTED_PATCH_SHA" ]; then
  echo "patch sha mismatch: expected $EXPECTED_PATCH_SHA got $actual_patch_sha" >&2
  exit 1
fi

if [ "$actual_patch_lines" != "$EXPECTED_PATCH_LINES" ]; then
  echo "patch line-count mismatch: expected $EXPECTED_PATCH_LINES got $actual_patch_lines" >&2
  exit 1
fi

check_required_outputs() {
  for output in "${REQUIRED_OUTPUTS[@]}"; do
    if [ ! -e "$CHROMIUM_SRC/$output" ]; then
      echo "missing required build output: $CHROMIUM_SRC/$output" >&2
      exit 1
    fi
  done
}

case "$MODE" in
  applied)
    actual_head="$(git -C "$CHROMIUM_SRC" rev-parse HEAD)"
    if [ -n "$EXPECTED_FORK_COMMIT" ] && [ "$actual_head" = "$EXPECTED_FORK_COMMIT" ]; then
      if [ -n "$(git -C "$CHROMIUM_SRC" status --porcelain)" ]; then
        echo "Chromium checkout is at the fork commit but has source changes" >&2
        exit 1
      fi
      check_required_outputs
      SOURCE_KIND="fork"
    else
      if [ "$actual_head" != "$EXPECTED_BASE" ]; then
        echo "Chromium HEAD mismatch: expected fork $EXPECTED_FORK_COMMIT or base $EXPECTED_BASE, got $actual_head" >&2
        exit 1
      fi
      actual_diff_sha="$(git -C "$CHROMIUM_SRC" diff --binary | shasum -a 256 | awk '{print $1}')"
      actual_diff_lines="$(git -C "$CHROMIUM_SRC" diff --binary | wc -l | tr -d ' ')"
      if [ "$actual_diff_sha" != "$EXPECTED_PATCH_SHA" ]; then
        echo "Chromium diff sha mismatch: expected $EXPECTED_PATCH_SHA got $actual_diff_sha" >&2
        exit 1
      fi
      if [ "$actual_diff_lines" != "$EXPECTED_PATCH_LINES" ]; then
        echo "Chromium diff line-count mismatch: expected $EXPECTED_PATCH_LINES got $actual_diff_lines" >&2
        exit 1
      fi
      check_required_outputs
      SOURCE_KIND="base-plus-patch"
    fi
    ;;
  clean-apply)
    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/owl-chromium-patch-check.XXXXXX")"
    cleanup() {
      rm -rf "$temp_dir"
    }
    trap cleanup EXIT
    git clone --shared --no-checkout "$CHROMIUM_SRC" "$temp_dir/chromium-src" >/dev/null 2>&1
    git -C "$temp_dir/chromium-src" checkout --detach "$EXPECTED_BASE" >/dev/null 2>&1
    git -C "$temp_dir/chromium-src" apply --check "$PATCH_FILE"
    SOURCE_KIND="clean-apply"
    ;;
  fork-remote)
    if [ -z "$FORK_REPO" ] || [ -z "$FORK_BRANCH" ] || [ -z "$EXPECTED_FORK_COMMIT" ]; then
      echo "manifest does not record chromiumForkRepo, chromiumForkBranch, and chromiumForkCommit" >&2
      exit 1
    fi
    actual_remote_commit="$(git ls-remote "$FORK_REPO" "refs/heads/$FORK_BRANCH" | awk '{print $1}')"
    if [ "$actual_remote_commit" != "$EXPECTED_FORK_COMMIT" ]; then
      echo "fork branch mismatch: expected $EXPECTED_FORK_COMMIT got ${actual_remote_commit:-missing}" >&2
      exit 1
    fi
    SOURCE_KIND="fork-remote"
    ;;
  *)
    usage
    exit 2
    ;;
esac

echo "Chromium OWL patch check passed"
echo "mode: $MODE"
echo "source: ${SOURCE_KIND:-unknown}"
echo "chromium: $CHROMIUM_SRC"
echo "base: $EXPECTED_BASE"
if [ -n "$EXPECTED_FORK_COMMIT" ]; then
  echo "fork-repo: $FORK_REPO"
  echo "fork-branch: $FORK_BRANCH"
  echo "fork-commit: $EXPECTED_FORK_COMMIT"
fi
echo "patch-sha256: $EXPECTED_PATCH_SHA"
