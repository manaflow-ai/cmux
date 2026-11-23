#!/usr/bin/env bash
# Xcode "Embed remote browser host" phase of the cmux-next target, after
# "Embed CEF". Every configuration (Release too, since the iPhone host streams
# the phone's browser tabs from it): puts the pinned remote browser host where
# LocalRemoteBrowserHostLocator finds it with no CMUX_NEXT_RB_HOST:
#
#   Contents/Helpers/cmux-remote-browser-host.app        (remote-browser-host-layout.sh)
#     Contents/Frameworks/Chromium Embedded Framework.framework
#       -> ../../../../Frameworks/Chromium Embedded Framework.framework
#
# The framework is a relative symlink to the app's own CEF (no ~390 MB copy).
# The five helper apps run cmux-rb-host-helper, a small Chromium subprocess
# binary that build-cef-shim.sh builds from the app's own (arm64) CEF, as it
# builds the app's helpers; before, each was a copy of the 3.6 MB host
# (cmux#42190). CMUX_NEXT_RB_HOST_HELPER=<binary> names a prebuilt one. When
# it cannot be built, the helpers fall back to copies of the host binary,
# which runs the same subprocess path, with a warning.
# codesign --verify --deep --strict passes on the app; a strict verify of the
# host app alone rejects the symlink, so a notarized release needs the host to
# load CEF from an explicit path first (tracker cx-0y2y; unproven either way,
# see cmux-next-ios/SECURITY.md `browser`). Also:
#   - a Release build that cannot embed it (no pinned artifact reachable, a CEF
#     pin mismatch) builds without it and says so, unless
#     CMUX_NEXT_REQUIRE_RB_HOST=1; a DEV build fails, as below;
#   - only arm64 (the published host is arm64; an Intel Mac never starts it);
#   - the host pin's cef_sha256 must equal cef-manifest.json's sha256 (the host
#     links the same CEF fork build); otherwise the build fails;
#   - the host binary comes from ensure-remote-browser-host.sh, checked against
#     the pin sha256; a mismatch fails the build, and so does an unavailable
#     binary (no tailnet controller, no R2 read credentials). The error names
#     the artifact and its pinned digest. A silent skip shipped DEV apps whose
#     "Open Remote Browser Tab" could not work (2026-10-09).
# Signs with the build's identity (EXPANDED_CODE_SIGN_IDENTITY, ad hoc when
# empty), the same identity sign-cef.sh gives the app's CEF; Xcode then signs
# the outer app.
#
# The only opt-out is explicit: CMUX_NEXT_SKIP_RB_HOST=1 embeds nothing, prints
# a warning in the build log and writes Contents/Resources/$OPT_OUT_FILE, which
# About cmux shows (AboutPanelCredits). Any later embed removes that file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/remote-browser-host-layout.sh"
FW_NAME="Chromium Embedded Framework.framework"
LAYOUT="rbh-2-cef-symlink-small-helper"
OPT_OUT_FILE="RemoteBrowserHostOptOut.txt"

app="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}"
dest="$app/Contents/Helpers/$RBH_NAME.app"
stamp="${TARGET_TEMP_DIR:-$TARGET_BUILD_DIR}/embed-remote-browser-host.stamp"
rm -f "$stamp"
opt_out="$app/Contents/Resources/$OPT_OUT_FILE"
rm -f "$opt_out"

skip() { # <reason>
  echo "note: not embedding the remote browser host: $1"
  rm -rf "$dest"
  mkdir -p "$(dirname "$stamp")"
  printf 'skipped:%s\n' "$1" > "$stamp"
  rmdir "$app/Contents/Helpers" 2>/dev/null || true
  exit 0
}
fail() { # <message>
  if [[ "${CONFIGURATION:-}" == "Release" && "${CMUX_NEXT_REQUIRE_RB_HOST:-0}" != "1" ]]; then
    echo "warning: $1" >&2
    skip "Release build without the remote browser host (phone browser tabs are off on this build)"
  fi
  echo "error: $1" >&2
  echo "error: this DEV build would lack the remote browser host (\"Open Remote Browser Tab\" fails). Restore the pinned artifact, or opt out explicitly with CMUX_NEXT_SKIP_RB_HOST=1 (recorded in the log and in About)." >&2
  rm -rf "$dest" "$stamp"
  exit 1
}

if [[ "${CMUX_NEXT_SKIP_RB_HOST:-0}" == "1" ]]; then
  echo "warning: CMUX_NEXT_SKIP_RB_HOST=1: this DEV build has NO remote browser host; \"Open Remote Browser Tab\" will not work (recorded in Contents/Resources/$OPT_OUT_FILE and About)"
  mkdir -p "$app/Contents/Resources"
  printf 'Built without the remote browser host (CMUX_NEXT_SKIP_RB_HOST=1).\n' > "$opt_out"
  skip "CMUX_NEXT_SKIP_RB_HOST=1"
fi
[[ " ${ARCHS:-arm64} " == *" arm64 "* ]] || skip "ARCHS=${ARCHS:-} has no arm64"
[[ -d "$app/Contents/Frameworks/$FW_NAME" ]] || skip "the app embeds no CEF framework"

pin="${CMUX_NEXT_RB_HOST_PIN:-$SCRIPT_DIR/remote-browser-host.pin.json}"
manifest="${CMUX_CEF_MANIFEST:-$SCRIPT_DIR/cef-manifest.json}"
[[ -f "$pin" ]] || fail "no remote browser host pin file $pin"
json_field() { # <file> <key>
  /usr/bin/python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get(sys.argv[2]); print("" if v is None else v)' "$1" "$2"
}
host_cef="$(json_field "$pin" cef_sha256)"
app_cef="$(json_field "$manifest" sha256)"
if [[ -n "${CMUX_CEF_PATH:-}" ]]; then
  echo "warning: CMUX_CEF_PATH is set; the app's CEF is a local dist, so the host's CEF pin is not checked"
elif [[ "$host_cef" != "$app_cef" ]]; then
  fail "CEF pin mismatch: the remote browser host ($pin) was built against CEF sha256 ${host_cef:-?}, the app embeds CEF sha256 $app_cef; publish a host for the app's CEF (scripts/cmux-next/publish-remote-browser-host.sh)"
fi

host_sha="$(json_field "$pin" sha256)"
host_asset="$(json_field "$pin" asset)"
# ensure-remote-browser-host.sh fails on an unavailable binary and on a sha256 mismatch.
bin="$("$SCRIPT_DIR/ensure-remote-browser-host.sh")" ||
  fail "the pinned remote browser host $host_asset sha256:$host_sha could not be fetched and verified (see above)"
[[ -n "$bin" && -f "$bin" ]] || fail "the pinned remote browser host $host_asset sha256:$host_sha is unavailable"
lipo -archs "$bin" | tr ' ' '\n' | grep -qx arm64 || { echo "error: $bin has no arm64 slice" >&2; exit 1; }

# The helpers' subprocess binary: the arm64 build of the app's CEF shim (the
# host is arm64 only). embed-cef.sh built that entry already, so this is a
# cache hit (a universal build's arm64 half included).
helper_bin="${CMUX_NEXT_RB_HOST_HELPER:-}"
if [[ -z "$helper_bin" ]]; then
  cef_arm="$("$SCRIPT_DIR/ensure-cef.sh" --optional 2>/dev/null)" || cef_arm=""
  if [[ -n "$cef_arm" ]]; then
    shim="$(CMUX_CEF_ARCH=arm64 "$SCRIPT_DIR/build-cef-shim.sh" "$cef_arm" "$("$SCRIPT_DIR/cef-cache-root.sh")/shim" | tail -n 1)" || shim=""
    if [[ -n "$shim" ]]; then helper_bin="$shim/cmux-rb-host-helper"; fi
  fi
fi
if [[ -n "$helper_bin" && -x "$helper_bin" ]] && lipo -archs "$helper_bin" | tr ' ' '\n' | grep -qx arm64; then
  helper_sha="$(shasum -a 256 "$helper_bin" | cut -c1-16)"
else
  echo "warning: no arm64 cmux-rb-host-helper (${helper_bin:-none built}); the remote browser host's helpers are copies of the 3.6 MB host binary (cmux#42190)"
  helper_bin=""
  helper_sha="host"
fi

identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[[ -z "$identity" ]] && identity="-"
want="$LAYOUT $(json_field "$pin" sha256) $helper_sha $identity"
if [[ -f "$stamp" && "$(cat "$stamp")" == "$want" && -L "$dest/Contents/Frameworks/$FW_NAME" ]] &&
  codesign --verify "$dest/Contents/MacOS/$RBH_NAME" 2>/dev/null; then
  echo "note: remote browser host already embedded ($want)"
  exit 0
fi

mkdir -p "$app/Contents/Helpers"
tmp="$(mktemp -d "$app/Contents/Helpers/.rbh.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
staged="$tmp/$RBH_NAME.app"
rbh_write_bundle "$bin" "$staged" "$helper_bin"
ln -s "../../../../Frameworks/$FW_NAME" "$staged/Contents/Frameworks/$FW_NAME"
rbh_sign "$staged" "$identity"
rm -rf "$dest"
mv "$staged" "$dest"
printf '%s' "$want" > "$stamp"
echo "note: embedded the remote browser host ($(json_field "$pin" sha256 | cut -c1-12), signed by $identity)"
