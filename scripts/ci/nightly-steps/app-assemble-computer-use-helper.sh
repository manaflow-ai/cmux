#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Assemble the Computer Use helper". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# The Computer Use helper that onboarding grants (cx-urd.6, D19). Only a
# com.cmuxterm.cua app at Contents/Library with the team's Developer ID
# signature is used, so it is assembled here for Codesign apps to sign and
# notarize-nightly-dmg.sh to notarize. It builds with the reviewed rustc
# that cmux-tui pins: the notices check (rust-std) needs a reviewed rustc.
#
# Prebuilt first. The unsigned helper is the same bytes for every build of one input key
# (scripts/cmux-cua-helper-key.sh: the cmux-cua pin, its patches, the build script, the toolchain, Xcode
# and the SDK). When scripts/cmux-next/cmux-cua-helper.pin.json names this key, the helper comes from the
# host cache, then the controller store (the cache SSD first), then the private cmux-cef R2 bucket with
# the read-only key, checked against the pin's sha256 (ensure-cua-pinned-asset.sh). It is stored unsigned
# (ad-hoc only); Codesign apps signs it with the team identity as before. Any miss builds from source.
# A source build uses the pinned cmux-cua git bundle (cmux-cua-source.pin.json, same stores) when the
# runner has no clone, so an empty cache never clones cmux-cua over the internet first (run 44232805509:
# a full clone on a runner timed out after 9.5 minutes). A source build leaves the unsigned helper and its
# key in $RUNNER_TEMP/cmux-cua-helper-prebuilt for the next step to upload; publish-cmux-cua-helper.sh
# turns that artifact into the pin.
set -euo pipefail
app="build-universal/Build/Products/Release/cmux.app"
helper="$app/Contents/Library/cmux Computer Use.app"
helper_pin="scripts/cmux-next/cmux-cua-helper.pin.json"
source_pin="scripts/cmux-next/cmux-cua-source.pin.json"
# Only the slices a variant ships: nightly-next and fast builds are arm64.
archs="${HELPER_ARCHS}"
started=$SECONDS
note() { echo "$*"; [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "$*" >> "$GITHUB_STEP_SUMMARY"; return 0; }
pin_field() { /usr/bin/python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$1" "$2"; }

key="$(./scripts/cmux-cua-helper-key.sh --archs "$archs")"
echo "Computer Use helper input key: $key"
./scripts/cmux-cua-helper-key.sh --archs "$archs" --fields | sed 's/^/  /'

# Prints the path of the verified prebuilt zip, or nothing (and why on stderr).
prebuilt_zip() {
  [[ -f "$helper_pin" ]] || { echo "no $helper_pin" >&2; return 0; }
  local want; want="$(pin_field "$helper_pin" input_key)"
  [[ "$want" == "$key" ]] || { echo "the pin is for input key ${want:-none}" >&2; return 0; }
  local zip status=0
  zip="$(scripts/cmux-next/ensure-cua-pinned-asset.sh "$helper_pin" --allow-no-source)" || status=$?
  case "$status" in
    0) printf '%s\n' "$zip" ;;
    3) echo "no store had it" >&2 ;;
    *) echo "::warning::the pinned prebuilt Computer Use helper did not verify (exit $status); building from source" >&2 ;;
  esac
}

install_prebuilt() {
  local zip="$1" work
  work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/cmux-cua-helper.XXXXXX")"
  ditto -x -k "$zip" "$work" || { rm -rf "$work"; return 1; }
  local entries; entries="$(cd "$work" && ls -A)"
  [[ "$entries" == "cmux Computer Use.app" && -d "$work/cmux Computer Use.app" && ! -L "$work/cmux Computer Use.app" ]] \
    || { echo "error: the prebuilt zip holds '$entries', expected one cmux Computer Use.app" >&2; rm -rf "$work"; return 1; }
  # Inside `if`, set -e is off: every check returns on its own.
  /usr/bin/codesign --verify --deep --strict "$work/cmux Computer Use.app" || { rm -rf "$work"; return 1; }
  "$work/cmux Computer Use.app/Contents/MacOS/cmux-cua" --version >/dev/null || { rm -rf "$work"; return 1; }
  mkdir -p "$app/Contents/Library"
  rm -rf "$helper"
  mv "$work/cmux Computer Use.app" "$helper"
  rm -rf "$work"
}

zip="$(prebuilt_zip)"
if [[ -n "$zip" ]] && install_prebuilt "$zip"; then
  ./scripts/ci/verify-computer-use-helper.sh layout "$app"
  note "Computer Use helper: prebuilt $(pin_field "$helper_pin" sha256) for key $key in $((SECONDS - started)) s"
  exit 0
fi

# A source build. The pinned bundle seeds an empty cmux-cua cache (build-cmux-cua.sh CMUX_CUA_SOURCE_BUNDLE).
if [[ -f "$source_pin" ]]; then
  if bundle="$(scripts/cmux-next/ensure-cua-pinned-asset.sh "$source_pin" --allow-no-source)" && [[ -n "$bundle" ]]; then
    export CMUX_CUA_SOURCE_BUNDLE="$bundle"
  else
    echo "note: no pinned cmux-cua source bundle; build-cmux-cua.sh clones from GitHub if this runner has no clone"
  fi
fi
toolchain="$(sed -n 's/^channel = "\(.*\)"$/\1/p' cmux-tui/rust-toolchain.toml)"
# shellcheck source=scripts/lib/rust-targets.sh
source scripts/lib/rust-targets.sh
ensure_rust_toolchain "$toolchain" --profile minimal
RUSTUP_TOOLCHAIN="$toolchain" ./scripts/build-cmux-cua.sh \
  --output "$app/Contents/Resources/bin/cmux-cua" --helper-app --archs "$archs"
# The helper app is what ships; build-cmux-cua.sh's bin copy is scratch.
rm -f "$app/Contents/Resources/bin/cmux-cua" "$app/Contents/Resources/bin/cmux-cua-LICENSE.md"
./scripts/ci/verify-computer-use-helper.sh layout "$app"
note "Computer Use helper: built from source for key $key in $((SECONDS - started)) s"

# Keep the unsigned helper (ad-hoc signed, before Codesign apps) and its key for the upload step.
if [[ -n "${RUNNER_TEMP:-}" ]]; then
  out="$RUNNER_TEMP/cmux-cua-helper-prebuilt"
  rm -rf "$out" && mkdir -p "$out"
  asset="cmux-computer-use-unsigned-macos-${archs// /-}.zip"
  ditto -c -k --norsrc --keepParent "$helper" "$out/$asset"
  {
    echo "input_key=$key"
    echo "asset=$asset"
    echo "sha256=$(shasum -a 256 "$out/$asset" | awk '{print $1}')"
    ./scripts/cmux-cua-helper-key.sh --archs "$archs" --fields
  } > "$out/key.txt"
fi
