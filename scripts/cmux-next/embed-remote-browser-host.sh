#!/usr/bin/env bash
# Xcode "Embed remote browser host" phase of the cmux-next target, after
# "Embed CEF". DEV builds only: puts the pinned remote browser host where
# LocalRemoteBrowserHostLocator finds it with no CMUX_NEXT_RB_HOST:
#
#   Contents/Helpers/cmux-remote-browser-host.app        (remote-browser-host-layout.sh)
#     Contents/Frameworks/Chromium Embedded Framework.framework
#       -> ../../../../Frameworks/Chromium Embedded Framework.framework
#
# The framework is a relative symlink to the app's own CEF (no ~390 MB copy).
# codesign --verify --deep --strict passes on the app; a strict verify of the
# host app alone rejects the symlink, so a notarized release needs the host to
# load CEF from an explicit path first (tracker cx-0y2y). Until then:
#   - the Release configuration (nightly, RC, stable) embeds nothing and
#     removes a host left by an earlier build;
#   - only arm64 (the published host is arm64);
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
LAYOUT="rbh-1-cef-symlink"
OPT_OUT_FILE="RemoteBrowserHostOptOut.txt"

app="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}"
dest="$app/Contents/Helpers/$RBH_NAME.app"
stamp="${TARGET_TEMP_DIR:-$TARGET_BUILD_DIR}/embed-remote-browser-host.stamp"
opt_out="$app/Contents/Resources/$OPT_OUT_FILE"
rm -f "$opt_out"

skip() { # <reason>
  echo "note: not embedding the remote browser host: $1"
  rm -rf "$dest" "$stamp"
  rmdir "$app/Contents/Helpers" 2>/dev/null || true
  exit 0
}
fail() { # <message>
  echo "error: $1" >&2
  echo "error: this DEV build would lack the remote browser host (\"Open Remote Browser Tab\" fails). Restore the pinned artifact, or opt out explicitly with CMUX_NEXT_SKIP_RB_HOST=1 (recorded in the log and in About)." >&2
  rm -rf "$dest" "$stamp"
  exit 1
}

[[ "${CONFIGURATION:-}" == "Release" ]] && skip "Release configuration (DEV builds only)"
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

identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[[ -z "$identity" ]] && identity="-"
want="$LAYOUT $(json_field "$pin" sha256) $identity"
if [[ -f "$stamp" && "$(cat "$stamp")" == "$want" && -L "$dest/Contents/Frameworks/$FW_NAME" ]] &&
  codesign --verify "$dest/Contents/MacOS/$RBH_NAME" 2>/dev/null; then
  echo "note: remote browser host already embedded ($want)"
  exit 0
fi

mkdir -p "$app/Contents/Helpers"
tmp="$(mktemp -d "$app/Contents/Helpers/.rbh.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
staged="$tmp/$RBH_NAME.app"
rbh_write_bundle "$bin" "$staged"
ln -s "../../../../Frameworks/$FW_NAME" "$staged/Contents/Frameworks/$FW_NAME"
rbh_sign "$staged" "$identity"
rm -rf "$dest"
mv "$staged" "$dest"
printf '%s' "$want" > "$stamp"
echo "note: embedded the remote browser host ($(json_field "$pin" sha256 | cut -c1-12), signed by $identity)"
