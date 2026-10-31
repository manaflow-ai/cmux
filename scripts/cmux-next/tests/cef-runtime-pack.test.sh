#!/usr/bin/env bash
# cef-runtime-pack.sh split (Chromium on demand, bundle-size-DESIGN.md 6.6):
# moves the engine out of the app into the flat folder "<Product> Chromium"
# inside a tar.xz with only safe entries, writes a pin whose sha256, size and URL match
# the pack, puts the pin in the app, keeps the key stable for the same inputs
# and changes it with the bundle id, reuses a published pin for the same key,
# and refuses an app without the base helper.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pack="$here/../cef-runtime-pack.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/cef-runtime-pack-test.XXXXXX")"
server=""
cleanup() { [[ -n "$server" ]] && kill "$server" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

make_app() { # <dir> <bundle id> [no-base-helper]
  local app="$1/cmux TEST.app" fw
  fw="$app/Contents/Frameworks"
  mkdir -p "$fw/Chromium Embedded Framework.framework/Versions/A" "$app/Contents/MacOS"
  printf 'framework' > "$fw/Chromium Embedded Framework.framework/Versions/A/Chromium Embedded Framework"
  ln -s A "$fw/Chromium Embedded Framework.framework/Versions/Current"
  ln -s "Versions/Current/Chromium Embedded Framework" "$fw/Chromium Embedded Framework.framework/Chromium Embedded Framework"
  printf 'shim' > "$fw/libcmux_cef_shim.dylib"
  mkdir -p "$fw/Sparkle.framework"
  local helpers=("cmux TEST Helper (GPU).app" "cmux TEST Helper (Renderer).app")
  [[ "${3:-}" == no-base-helper ]] || helpers+=("cmux TEST Helper.app")
  for h in "${helpers[@]}"; do
    mkdir -p "$fw/$h/Contents/MacOS"
    printf 'helper' > "$fw/$h/Contents/MacOS/${h%.app}"
  done
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>$2</string></dict></plist>
PLIST
  echo "$app"
}
field() { /usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$1" "$2"; }

# 1. Split.
app="$(make_app "$work/a" com.cmuxterm.app.test)"
"$pack" split "$app" "$work/out" --base-url https://files.example.com/ > /dev/null
fw="$app/Contents/Frameworks"
[[ ! -e "$fw/Chromium Embedded Framework.framework" && ! -e "$fw/libcmux_cef_shim.dylib" ]] || fail "the engine is still in the app"
for left in "$fw"/*Helper*; do [[ -e "$left" ]] && fail "a helper is still in the app: $left"; done
[[ -d "$fw/Sparkle.framework" ]] || fail "another framework was moved"
pin="$work/out/cef-runtime.json"
key="$(field "$pin" key)"
[[ "$key" =~ ^[0-9a-f]{16}$ ]] || fail "key '$key'"
asset="$work/out/cef-runtime-$key.tar.xz"
[[ -f "$asset" ]] || fail "no pack $asset"
[[ "$(field "$pin" sha256)" == "$(shasum -a 256 "$asset" | awk '{print $1}')" ]] || fail "pin sha256"
[[ "$(field "$pin" size)" == "$(wc -c < "$asset" | tr -d ' ')" ]] || fail "pin size"
[[ "$(field "$pin" url)" == "https://files.example.com/cef-runtime/$key/cef-runtime-$key.tar.xz" ]] || fail "pin url $(field "$pin" url)"
[[ "$(field "$pin" folder)" == "cmux TEST Chromium" ]] || fail "pin folder"
[[ -z "$(field "$pin" team_id)" ]] || fail "an unsigned pack has no team"
[[ "$(field "$pin" schema)" == 1 && -n "$(field "$pin" shim_abi)" && -n "$(field "$pin" cef)" ]] || fail "pin fields"
cmp -s "$pin" "$app/Contents/Resources/cef-runtime.json" || fail "the app's pin differs"
# A file, not a here-string: grep reads it directly.
tar -tf "$asset" > "$work/entries"
if grep -vE '^(cmux TEST Chromium/|cef-runtime\.json$)' "$work/entries" > "$work/unexpected"; then
  fail "unexpected entries: $(head -3 "$work/unexpected")"
fi
for want in "Chromium Embedded Framework.framework/Versions/A/Chromium Embedded Framework" \
            "libcmux_cef_shim.dylib" "cmux TEST Helper.app/Contents/MacOS/cmux TEST Helper" \
            "cmux TEST Helper (GPU).app/"; do
  grep -qF "cmux TEST Chromium/$want" "$work/entries" || fail "missing $want"
done
grep -q 'Info.plist$' "$work/entries" && grep -v 'Helper' "$work/entries" | grep -q 'Info.plist$' && fail "the pack is a bundle, not a flat folder"
mkdir "$work/x" && tar -xf "$asset" -C "$work/x"
[[ -L "$work/x/cmux TEST Chromium/Chromium Embedded Framework.framework/Versions/Current" ]] || fail "framework symlinks"

# 2. Same inputs, same key; another bundle id, another key.
app2="$(make_app "$work/b" com.cmuxterm.app.test)"
"$pack" split "$app2" "$work/out2" --base-url https://files.example.com > /dev/null
[[ "$(field "$work/out2/cef-runtime.json" key)" == "$key" ]] || fail "the key changed for the same inputs"
app3="$(make_app "$work/c" com.cmuxterm.app.other)"
"$pack" split "$app3" "$work/out3" --base-url https://files.example.com > /dev/null
[[ "$(field "$work/out3/cef-runtime.json" key)" != "$key" ]] || fail "the key ignores the bundle id"

# 3. A published pin for the key is reused: no pack, the engine still leaves the app.
mkdir -p "$work/site/cef-runtime/$key"
cp "$pin" "$work/site/cef-runtime/$key/cef-runtime.json"
port=$(( 20000 + RANDOM % 20000 ))
/usr/bin/python3 -m http.server "$port" --bind 127.0.0.1 --directory "$work/site" > /dev/null 2>&1 &
server=$!
for _ in $(seq 50); do curl -fs -o /dev/null "http://127.0.0.1:$port/cef-runtime/$key/cef-runtime.json" && break; sleep 0.1; done
app4="$(make_app "$work/d" com.cmuxterm.app.test)"
"$pack" split "$app4" "$work/out4" --base-url "http://127.0.0.1:$port" --reuse-published > /dev/null
[[ "$(cat "$work/out4/reused")" == "$key" ]] || fail "the published pin was not reused"
ls "$work/out4"/cef-runtime-*.tar.xz > /dev/null 2>&1 && fail "a reused pack was written again"
cmp -s "$pin" "$app4/Contents/Resources/cef-runtime.json" || fail "the reused pin is not the published one"
[[ ! -e "$app4/Contents/Frameworks/Chromium Embedded Framework.framework" ]] || fail "reuse kept the engine in the app"

# 4. No base helper: refused, the app untouched.
app5="$(make_app "$work/e" com.cmuxterm.app.test no-base-helper)"
if "$pack" split "$app5" "$work/out5" --base-url https://files.example.com > /dev/null 2>&1; then fail "split accepted an app without its base helper"; fi
[[ -d "$app5/Contents/Frameworks/Chromium Embedded Framework.framework" ]] || fail "a refused split changed the app"

echo "PASS cef-runtime-pack"
