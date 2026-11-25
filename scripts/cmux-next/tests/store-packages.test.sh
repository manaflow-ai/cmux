#!/usr/bin/env bash
# The App Store packages (AppPlatform/store) are build output (Leo, 2026-10-21: "don't commit
# generatable files"). In a scratch tree with fixture apps (a STORE first-party app with a manifest
# v2 cmux-app.json, a BUNDLED one that also has STORE, a STORE sample):
#   - sync-app-runtime.sh --store writes the STORE packages and only them; --store --check passes on
#     them and fails on a missing or stray package; --check (the committed copies) ignores store/;
#   - a first-party app and a sample with the same store name, or a STORE app with no manifest v2, fail;
#   - build-web-bundles.sh writes store/ on a dev build even without bun, and --verify (the Xcode
#     phase) refuses a tree whose store/ is missing;
#   - check-app-bundle.sh passes a built app that holds every package and fails, naming the file,
#     one that lacks a package or a file its manifest names;
#   - the real checkout gitignores store/ and its committed copies are current.
# Bash and python3 only (no bun, no app build). Run: bash scripts/cmux-next/tests/store-packages.test.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$@" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$1"; }

# A scratch root with the scripts under test.
tree="$TMP/tree"
mkdir -p "$tree/scripts/cmux-next"
for f in sync-app-runtime.sh build-web-bundles.sh check-app-bundle.sh; do
  cp "$ROOT/scripts/cmux-next/$f" "$tree/scripts/cmux-next/$f"
done

fixture_app() { # dir manifest-file id
  mkdir -p "$1/dist" "$1/assets"
  printf '{\n  "manifestVersion": 2,\n  "id": "%s",\n  "runtime": { "main": "dist/main.js" },\n  "icon": "assets/icon.svg"\n}\n' "$3" > "$1/$2"
  printf 'function render() {}\n' > "$1/dist/main.js"
  printf '<svg/>\n' > "$1/assets/icon.svg"
}
fp="$tree/first-party-apps"
fixture_app "$fp/widget-fixture" cmux-app.json cmux/widget-fixture
touch "$fp/widget-fixture/STORE"
fixture_app "$fp/default-fixture" cmux-app.v2.json cmux/default-fixture
touch "$fp/default-fixture/STORE" "$fp/default-fixture/BUNDLED"
fixture_app "$tree/samples/apps/sample-fixture" cmux-app.v2.json acme/sample-fixture
touch "$tree/samples/apps/sample-fixture/STORE"

sync="$tree/scripts/cmux-next/sync-app-runtime.sh"
platform="$tree/Packages/macOS/CmuxNext/Sources/CmuxNextApps/Resources/AppPlatform"
store="$platform/store"

# 1. A full sync writes the committed copies and store/; --store writes the STORE packages only.
"$sync" >/dev/null
[[ -f "$platform/first-party/default-fixture/cmux-app.v2.json" ]] || fail "the BUNDLED app is a first-party copy"
[[ -f "$store/widget-fixture/cmux-app.v2.json" ]] || fail "the STORE first-party app's cmux-app.json lands as cmux-app.v2.json"
[[ -f "$store/widget-fixture/dist/main.js" && -f "$store/widget-fixture/assets/icon.svg" ]] || fail "its dist and assets"
[[ -f "$store/sample-fixture/cmux-app.v2.json" ]] || fail "the STORE sample"
[[ ! -e "$store/default-fixture" ]] || fail "a BUNDLED app is not a store package"
rm -rf "$store"
"$sync" --store >/dev/null
[[ -f "$store/widget-fixture/dist/main.js" ]] || fail "--store rewrites store/"
pass "sync writes the STORE packages, BUNDLED apps stay first-party"

# 2. The checks: --store --check judges store/, --check never does.
"$sync" --store --check >/dev/null || fail "--store --check passes on a fresh store/"
"$sync" --check >/dev/null || fail "--check passes on the fresh committed copies"
mkdir -p "$store/stray" && touch "$store/stray/cmux-app.v2.json"
"$sync" --check >/dev/null || fail "--check ignores what a build left in store/"
if "$sync" --store --check >/dev/null 2>&1; then fail "--store --check passes with a stray package"; fi
rm -rf "$store/widget-fixture"
if "$sync" --store --check >/dev/null 2>&1; then fail "--store --check passes with a package missing"; fi
rm -rf "$store"
if out=$("$sync" --store --check 2>&1); then fail "--store --check passes with no store/"; fi
[[ "$out" == *"sync-app-runtime.sh --store"* ]] || fail "the failure names the command: $out"
"$sync" --check >/dev/null || fail "--check passes with no store/ at all (a fresh checkout)"
pass "--store --check judges store/; --check ignores it"

# 3. Refusals: one store name twice, a STORE app without a manifest v2.
fixture_app "$tree/samples/apps/widget-fixture" cmux-app.v2.json acme/widget-fixture
touch "$tree/samples/apps/widget-fixture/STORE"
if out=$("$sync" --store 2>&1); then fail "two store packages named widget-fixture"; fi
[[ "$out" == *"both App Store packages named widget-fixture"* ]] || fail "the collision message: $out"
rm -rf "$tree/samples/apps/widget-fixture"
mkdir -p "$fp/v1-fixture" && printf '{ "id": "cmux/v1" }\n' > "$fp/v1-fixture/cmux-app.json" && touch "$fp/v1-fixture/STORE"
if out=$("$sync" --store 2>&1); then fail "a STORE app with a v1 manifest"; fi
[[ "$out" == *"has a STORE marker but no manifest v2"* ]] || fail "the v1 message: $out"
rm -rf "$fp/v1-fixture"
printf '{ "manifestVersion": "2", "id": "cmux/v1s" }\n' > "$TMP/v1s.json"
mkdir -p "$fp/v1s-fixture" && cp "$TMP/v1s.json" "$fp/v1s-fixture/cmux-app.json" && touch "$fp/v1s-fixture/STORE"
if "$sync" --store >/dev/null 2>&1; then fail "a STORE app whose manifestVersion is the string \"2\""; fi
rm -rf "$fp/v1s-fixture"
pass "a name clash and a v1 STORE app are refused"

# 3b. A manifest v2 cmux-app.json is read as JSON: spaces around the colon and line breaks still count.
mkdir -p "$fp/spaced-fixture/dist"
printf '{\n  "id": "cmux/spaced",\n  "manifestVersion"\n    :\n    2\n}\n' > "$fp/spaced-fixture/cmux-app.json"
printf 'function render() {}\n' > "$fp/spaced-fixture/dist/main.js"
touch "$fp/spaced-fixture/STORE"
"$sync" --store >/dev/null || fail "a manifest v2 cmux-app.json formatted with spaces and newlines"
[[ -f "$store/spaced-fixture/cmux-app.v2.json" ]] || fail "the spaced manifest lands as cmux-app.v2.json"
rm -rf "$fp/spaced-fixture" "$store/spaced-fixture"
"$sync" --store >/dev/null
pass "a manifest v2 cmux-app.json is parsed, not matched as text"

# 4. build-web-bundles.sh: --verify refuses a missing store/; a dev build writes it even without bun.
bundles="$tree/scripts/cmux-next/build-web-bundles.sh"
rm -rf "$store"
if out=$("$bundles" --verify 2>&1); then fail "--verify passes with no store/"; fi
[[ "$out" == *"App Store packages are missing or stale"* ]] || fail "--verify names the store packages: $out"
nobun="$TMP/nobun"
mkdir -p "$nobun"
for tool in bash sh python3 git cp mkdir rm diff ls sort grep find dirname basename mktemp cat cut touch; do
  ln -s "$(command -v "$tool")" "$nobun/$tool"
done
PATH="$nobun" CMUX_WEB_BUNDLES_TOOLS_OPTIONAL=1 "$bundles" >/dev/null 2>&1 \
  || fail "a dev build without bun exits 0 (it ships what it has)"
[[ -f "$store/widget-fixture/dist/main.js" ]] || fail "build-web-bundles.sh writes store/ before it needs bun"
if out=$("$bundles" --verify 2>&1); then fail "--verify passes with no web bundle stamp"; fi
[[ "$out" != *"App Store packages"* ]] || fail "--verify passes the store packages once written: $out"
pass "build-web-bundles.sh writes store/, --verify refuses a tree without it"
# A scratch tree with only the bundle scripts (the --from and ensure-web-bundles tests) has no app
# platform: no store step runs there (cmux#45083 review P2-F1).
bare="$TMP/bare"
mkdir -p "$bare/scripts/cmux-next"
cp "$ROOT/scripts/cmux-next/build-web-bundles.sh" "$bare/scripts/cmux-next/"
if out=$("$bare/scripts/cmux-next/build-web-bundles.sh" --verify 2>&1); then fail "--verify passes a bare tree with no stamp"; fi
[[ "$out" != *"sync-app-runtime"* && "$out" != *"App Store packages"* ]] || fail "a bare tree runs no store step: $out"
pass "a tree without sync-app-runtime.sh runs no store step"

# 5. check-app-bundle.sh on a built app's layout.
app="$TMP/cmux DEV fixture.app"
res="$app/Contents/Resources/CmuxNext_CmuxNextApps.bundle/Contents/Resources"
mkdir -p "$res"
cp -R "$platform" "$res/AppPlatform"
check="$tree/scripts/cmux-next/check-app-bundle.sh"
out=$("$check" "$app") || fail "check-app-bundle passes a complete app: $out"
[[ "$out" == *"App Store packages present (sample-fixture, widget-fixture)"* ]] || fail "it names the packages: $out"
rm "$res/AppPlatform/store/widget-fixture/dist/main.js"
if out=$("$check" "$app" 2>&1); then fail "check-app-bundle passes an app whose store package lacks its script"; fi
[[ "$out" == *"widget-fixture: Contents/Resources/CmuxNext_CmuxNextApps.bundle/Contents/Resources/AppPlatform/store/widget-fixture/dist/main.js"* ]] \
  || fail "it names the missing script: $out"
rm -rf "$res/AppPlatform/store/widget-fixture"
if out=$("$check" "$app" 2>&1); then fail "check-app-bundle passes an app without a store package"; fi
[[ "$out" == *"widget-fixture: App Store package"* ]] || fail "it names the missing package: $out"
pass "check-app-bundle fails an app that lacks a store package or its files"

# 6. The real checkout: store/ is ignored, nothing in it is tracked, and the committed copies are current.
probe=Packages/macOS/CmuxNext/Sources/CmuxNextApps/Resources/AppPlatform/store/any-app/dist/main.js
git -C "$ROOT" check-ignore -q --no-index "$probe" || fail "$probe is not gitignored"
[[ -z "$(git -C "$ROOT" ls-files -- Packages/macOS/CmuxNext/Sources/CmuxNextApps/Resources/AppPlatform/store)" ]] \
  || fail "git still tracks AppPlatform/store"
"$ROOT/scripts/cmux-next/sync-app-runtime.sh" --check >/dev/null || fail "the committed copies are stale"
pass "the checkout ignores store/ and its committed copies are current"
echo "store-packages: all cases passed"
