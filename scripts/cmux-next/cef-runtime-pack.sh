#!/usr/bin/env bash
# Chromium on demand (plans/cmux-next/bundle-size-DESIGN.md section 6.6):
# moves the signed Chromium engine out of a cmux-next app into a runtime pack
# the app downloads on first use, and writes the pin the app reads.
#
# Usage:
#   cef-runtime-pack.sh split <app> <out-dir> --base-url URL [--reuse-published]
#
# Run after scripts/cmux-next/sign-cef.sh signed the engine and before the
# outer app is signed (scripts/sign-cmux-bundle.sh does both when
# CMUX_NEXT_CEF_ON_DEMAND=1). It:
#   1. computes the pack key from what the engine is made of: the CEF artifact
#      (cef-manifest.json), the embed layout, the shim sources and ABI, the
#      product, the bundle id, the signing team and the architectures. The key
#      changes when the engine changes, not on every nightly;
#   2. moves the framework, the shim and the helper apps into one flat folder
#      "<Product> Chromium" (side by side, as the helpers expect; not an app
#      bundle: the helper sandbox can read only this folder, through the
#      cmux_runtime_outside_bundle CEF patch, so the app stays Chromium's main
#      bundle);
#   3. writes <out-dir>/cef-runtime-<key>.tar.xz (the folder plus
#      cef-runtime.json) and the pin <out-dir>/cef-runtime.json:
#      {schema, key, cef, chromium, shim_abi, sha256, size, url, team_id, folder};
#   4. copies the pin to <app>/Contents/Resources/cef-runtime.json.
# With --reuse-published, a pin already published for the key
# (<base-url>/cef-runtime/<key>/cef-runtime.json) is used instead and no pack
# is written (<out-dir>/reused names the key): users download the engine
# again only when it changed.
#
# Env: CMUX_CEF_RUNTIME_REPO_ROOT overrides the repository root (tests).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CMUX_CEF_RUNTIME_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
FRAMEWORK="Chromium Embedded Framework.framework"
SHIM="libcmux_cef_shim.dylib"

usage() { echo "usage: $0 split <app> <out-dir> --base-url URL [--reuse-published]" >&2; exit 2; }
die() { echo "cef-runtime-pack: $*" >&2; exit 1; }

[[ "${1:-}" == split ]] || usage
app="${2:-}"; out="${3:-}"
[[ -n "$app" && -n "$out" ]] || usage
shift 3
base_url=""; reuse=0
while (( $# )); do
  case "$1" in
    --base-url) base_url="${2:-}"; shift 2 ;;
    --reuse-published) reuse=1; shift ;;
    *) usage ;;
  esac
done
[[ "$base_url" == https://* || "$base_url" == http://127.0.0.1* || "$base_url" == http://localhost* ]] \
  || die "--base-url must be https (or http to localhost for tests): '$base_url'"
base_url="${base_url%/}"

frameworks="$app/Contents/Frameworks"
[[ -d "$frameworks/$FRAMEWORK" ]] || die "no $FRAMEWORK in $frameworks"
[[ -f "$frameworks/$SHIM" ]] || die "no $SHIM in $frameworks"
helpers=()
while IFS= read -r -d '' helper; do helpers+=("$helper"); done \
  < <(find "$frameworks" -mindepth 1 -maxdepth 1 -type d -name '* Helper*.app' -print0 | sort -z)
base_helper=""
for helper in "${helpers[@]}"; do
  case "$(basename "$helper")" in *" Helper.app") base_helper="$(basename "$helper")" ;; esac
done
[[ -n "$base_helper" ]] || die "no base helper (<Product> Helper.app) in $frameworks"
product="${base_helper% Helper.app}"
folder="$product Chromium"

# macOS (where packs are signed and published) uses PlistBuddy and bsdtar and
# refuses to run without them; plistlib and GNU tar serve only other hosts
# (the script tests run on Linux CI).
darwin=0
if [[ "$(uname -s)" == Darwin ]]; then
  darwin=1
  [[ -x /usr/libexec/PlistBuddy ]] || die "no /usr/libexec/PlistBuddy on this Mac"
  [[ "$(/usr/bin/tar --version 2>/dev/null || true)" == *bsdtar* ]] || die "/usr/bin/tar is not bsdtar on this Mac"
fi
plist() {
  if (( darwin )); then
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
  else
    /usr/bin/python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1], "rb")).get(sys.argv[2], ""))' "$1" "$2" 2>/dev/null || true
  fi
}
bundle_id="$(plist "$app/Contents/Info.plist" CFBundleIdentifier)"
[[ -n "$bundle_id" ]] || die "no CFBundleIdentifier in $app/Contents/Info.plist"
# An unsigned engine (tests) makes codesign fail: no team.
team="$( { /usr/bin/codesign -dv "$frameworks/$FRAMEWORK" 2>&1 || true; } | sed -n 's/^TeamIdentifier=//p')"
[[ "$team" == "not set" ]] && team=""
binary="$frameworks/$FRAMEWORK/Chromium Embedded Framework"
archs="$( { /usr/bin/lipo -archs "$binary" 2>/dev/null || echo unknown; } | tr ' ' '\n' | sort | tr '\n' ' ')"

manifest="$REPO_ROOT/scripts/cmux-next/cef-manifest.json"
header="$REPO_ROOT/Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim/cmux_cef_shim.h"
[[ -f "$manifest" && -f "$header" ]] || die "missing $manifest or $header"
read -r cef_version chromium_version < <(/usr/bin/python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m["cef"], m["chromium"])' "$manifest")
shim_abi="$(shasum -a 256 "$header" | awk '{print $1}')"
layout="$(sed -n 's/^LAYOUT="\(.*\)"$/\1/p' "$REPO_ROOT/scripts/cmux-next/embed-cef.sh")"
key="$(
  {
    echo "manifest $(shasum -a 256 "$manifest" | awk '{print $1}')"
    echo "layout $layout"
    echo "abi $shim_abi"
    find "$REPO_ROOT/Packages/macOS/CmuxNext/CEFShim" -type f \( -name '*.h' -o -name '*.mm' \) -print0 2>/dev/null \
      | sort -z | xargs -0 shasum -a 256 2>/dev/null | awk '{print $1}'
    [[ -f "$REPO_ROOT/scripts/cmux-next/build-cef-shim.sh" ]] && shasum -a 256 "$REPO_ROOT/scripts/cmux-next/build-cef-shim.sh" | awk '{print $1}'
    echo "product $product"
    echo "bundle $bundle_id"
    echo "team $team"
    echo "archs $archs"
  } | shasum -a 256 | awk '{print substr($1, 1, 16)}'
)"

mkdir -p "$out"
pin="$out/cef-runtime.json"
rm -f "$out/reused" "$pin" "$out"/cef-runtime-*.tar.xz

remove_engine() {
  rm -rf "${frameworks:?}/$FRAMEWORK" "${frameworks:?}/$SHIM"
  for helper in "${helpers[@]}"; do rm -rf "$helper"; done
}

write_pin() { # <sha256> <size> <url> <file>
  /usr/bin/python3 - "$4" "$key" "$cef_version" "$chromium_version" "$shim_abi" "$1" "$2" "$3" "$team" "$folder" <<'PY'
import json, sys
path, key, cef, chromium, abi, sha, size, url, team, folder = sys.argv[1:]
pin = {"schema": 1, "key": key, "cef": cef, "chromium": chromium, "shim_abi": abi,
       "sha256": sha, "size": int(size), "url": url, "folder": folder}
if team:
    pin["team_id"] = team
with open(path, "w") as f:
    json.dump(pin, f, indent=2, sort_keys=True)
    f.write("\n")
PY
}

install_pin() {
  mkdir -p "$app/Contents/Resources"
  cp "$pin" "$app/Contents/Resources/cef-runtime.json"
}

if (( reuse )); then
  published="$out/.published-pin.json"
  if curl -fsSL --retry 3 -o "$published" "$base_url/cef-runtime/$key/cef-runtime.json" 2>/dev/null; then
    if /usr/bin/python3 - "$published" "$key" "$shim_abi" "$folder" "$team" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
key, abi, folder, team = sys.argv[2:]
ok = p.get("key") == key and p.get("shim_abi") == abi and p.get("folder") == folder and (p.get("team_id") or "") == team
sys.exit(0 if ok else 1)
PY
    then
      mv "$published" "$pin"
      remove_engine
      install_pin
      echo "$key" > "$out/reused"
      echo "==> reused the published Chromium runtime $key"
      exit 0
    fi
    echo "==> the published pin for $key does not match this build; packing again" >&2
  fi
  rm -f "$published"
fi

stage="$(mktemp -d "${TMPDIR:-/tmp}/cef-runtime-pack.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
runtime="$stage/$folder"
mkdir -p "$runtime"
# mv keeps the signatures (and their extended attributes) as sign-cef.sh wrote them.
mv "$frameworks/$FRAMEWORK" "$frameworks/$SHIM" "$runtime/"
for helper in "${helpers[@]}"; do mv "$helper" "$runtime/"; done
echo '{"schema": 1, "key": "'"$key"'"}' > "$stage/cef-runtime.json"

asset="cef-runtime-$key.tar.xz"
if (( darwin )); then
  COPYFILE_DISABLE=1 /usr/bin/tar --options xz:compression-level=9 -cJf "$out/$asset" -C "$stage" "$folder" cef-runtime.json
else # GNU tar (Linux CI) has no --options; xz reads its level from XZ_OPT.
  XZ_OPT=-9 /usr/bin/tar -cJf "$out/$asset" -C "$stage" "$folder" cef-runtime.json
fi
sha="$(shasum -a 256 "$out/$asset" | awk '{print $1}')"
size="$(wc -c < "$out/$asset" | tr -d ' ')"
write_pin "$sha" "$size" "$base_url/cef-runtime/$key/$asset" "$pin"
install_pin
echo "==> Chromium runtime $key: $out/$asset ($size bytes)"
