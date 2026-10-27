#!/usr/bin/env bash
# The Chromium host app (Debug-only prototype, build-chromium-host.sh) is not
# part of the Chromium runtime pack, so an edit to its sources must leave the
# pack key of cef-runtime-pack.sh unchanged: a new key makes every NIGHTLY and
# Release user download the whole engine again. An edit to a shim source still
# changes the key. The host sources are found by name wherever they live, so
# this fails on f8d6cd0139e, where they sat in CEFShim/src.
#
# Not in CI (lead, 2026-10-23: no new CI tests); run it when you move the host
# or change what the pack key hashes.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
pack="$here/../cef-runtime-pack.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/chromium-host-pack-key.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The key's inputs, copied from this checkout into a tree the test may edit.
fixture="$work/repo"
header_dir="Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim"
mkdir -p "$fixture/scripts/cmux-next" "$fixture/$header_dir"
cp "$root/scripts/cmux-next/cef-manifest.json" "$root/scripts/cmux-next/embed-cef.sh" \
  "$root/scripts/cmux-next/build-cef-shim.sh" "$fixture/scripts/cmux-next/"
cp "$root/$header_dir/cmux_cef_shim.h" "$fixture/$header_dir/"
cp -R "$root/Packages/macOS/CmuxNext/CEFShim" "$fixture/Packages/macOS/CmuxNext/"
if [[ -d "$root/Packages/macOS/CmuxNext/ChromiumHost" ]]; then
  cp -R "$root/Packages/macOS/CmuxNext/ChromiumHost" "$fixture/Packages/macOS/CmuxNext/"
fi

make_app() { # <dir> -> a signed-engine stand-in, as cef-runtime-pack.test.sh builds it
  local app="$1/cmux TEST.app" fw h
  fw="$app/Contents/Frameworks"
  mkdir -p "$fw/Chromium Embedded Framework.framework/Versions/A" "$app/Contents/MacOS"
  printf 'framework' > "$fw/Chromium Embedded Framework.framework/Versions/A/Chromium Embedded Framework"
  ln -s A "$fw/Chromium Embedded Framework.framework/Versions/Current"
  ln -s "Versions/Current/Chromium Embedded Framework" "$fw/Chromium Embedded Framework.framework/Chromium Embedded Framework"
  printf 'shim' > "$fw/libcmux_cef_shim.dylib"
  for h in "cmux TEST Helper.app" "cmux TEST Helper (GPU).app"; do
    mkdir -p "$fw/$h/Contents/MacOS"
    printf 'helper' > "$fw/$h/Contents/MacOS/${h%.app}"
  done
  cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.cmuxterm.app.test</string></dict></plist>
PLIST
  echo "$app"
}
key_of() { # <name> -> the pack key of a fresh stand-in app against the fixture tree
  local app
  app="$(make_app "$work/app-$1")"
  CMUX_CEF_RUNTIME_REPO_ROOT="$fixture" "$pack" split "$app" "$work/out-$1" --base-url https://files.example.com > /dev/null
  /usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["key"])' "$work/out-$1/cef-runtime.json"
}

base="$(key_of base)"
[[ "$(key_of again)" == "$base" ]] || fail "the key is not stable for the same inputs"

hosts=()
while IFS= read -r -d '' file; do hosts+=("$file"); done \
  < <(find "$fixture/Packages" -type f \( -name 'browser_host_main.mm' -o -name 'chromium_host_wire.h' \) -print0)
(( ${#hosts[@]} == 2 )) || fail "expected the host's two sources, found ${#hosts[@]}"
for file in "${hosts[@]}"; do printf '\n// edited by the test\n' >> "$file"; done
[[ "$(key_of host)" == "$base" ]] || fail "an edit to the Chromium host changes the runtime pack key: ${hosts[*]#"$fixture/"}"

printf '\n// edited by the test\n' >> "$fixture/Packages/macOS/CmuxNext/CEFShim/src/shim_client.mm"
[[ "$(key_of shim)" != "$base" ]] || fail "an edit to the shim no longer changes the runtime pack key"
echo "chromium-host-pack-key tests: ok"
