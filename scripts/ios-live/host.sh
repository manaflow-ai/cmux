#!/usr/bin/env bash
# ios-live host side: the always-on cmux NEXT iOS simulator (scripts/ios-live/README.md).
#
# Runs ON the live host. scripts/ios-live/ios-live copies it there as ~/ios-live/bin/host.sh and
# calls it over `reach`. The host keeps:
#   - one checkout,
#   - one warm build,
#   - one booted iPhone in its own simctl device set, with the app running.
# Agents change what runs in it in two ways:
#   swift  Edited Swift goes in live, in about 2 s, with no rebuild, reinstall or relaunch. This
#          needs scripts/live-code/ios-sim.sh in the checkout (cmux#45397).
#   swap   Anything else: warm incremental rebuild, reinstall, relaunch. The app's sign-in stays
#          in the simulator's keychain, which survives a reinstall.
#
# IOS_LIVE_ROOT (default ~/ios-live) holds:
#   src/          blobless clone of manaflow-ai/cmux, at the live base plus the current patch
#   live/         the live code build (ios-sim.sh build OUT): dd/, xcodebuild.log, live/ (patch folder)
#   dd/           plain DerivedData, used when the checkout has no ios-sim.sh
#   sims/         simctl device set with one iPhone named cmux-ios-live
#   tools/        pinned xcodegen
#   launch.env    KEY=VALUE lines passed to the app as its launch environment (its sign-in target)
#   lease/        the driver lease: one driver at a time
#   state.json    base, patch, app, timings of the last up/swap/swift
#   logs/
#
# Read-only commands (status, shot, tree, log) need no lease. Commands that change the app or
# touch it (up, swap, swift, relaunch, tap, type) need the caller to hold the lease.
set -euo pipefail

root="${IOS_LIVE_ROOT:-$HOME/ios-live}"
repo_url="https://github.com/manaflow-ai/cmux.git"
branch="feat-cmux-next"
device_name="cmux-ios-live"
xcodegen_version=2.46.0
xcodegen_sha256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
jobs="${IOS_LIVE_JOBS:-4}"
src="$root/src"
sims="$root/sims"
mkdir -p "$root/logs" "$root/tools" "$sims" "$root/lease"

die() { echo "ios-live: $*" >&2; exit 1; }
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
simctl() { xcrun simctl --set "$sims" "$@"; }
state_get() { python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))
except Exception: print("")' "$root/state.json" "$1"; }
state_set() {
  python3 -c 'import json, sys, time
path = sys.argv[1]
try: s = json.load(open(path))
except Exception: s = {}
for kv in sys.argv[2:]:
    k, _, v = kv.partition("=")
    s[k] = int(v) if v.lstrip("-").isdigit() else v
s["updated"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
json.dump(s, open(path + ".tmp", "w"), indent=1)
import os; os.replace(path + ".tmp", path)' "$root/state.json" "$@"
}

# --- lease: one driver at a time --------------------------------------------------------------
lease() {  # show | take OWNER [MIN] | beat OWNER [MIN] | release OWNER | holds OWNER
  python3 -I -c '
import fcntl, json, os, sys, time
d, sub, owner, minutes = sys.argv[1], sys.argv[2], sys.argv[3], min(int(sys.argv[4]), 120)
lock = open(os.path.join(d, "lock"), "w"); fcntl.flock(lock, fcntl.LOCK_EX)
path = os.path.join(d, "owner.json")
try: cur = json.load(open(path))
except Exception: cur = {}
holder = cur.get("owner") if cur.get("until", 0) > time.time() else None
until = lambda c: time.strftime("%H:%MZ", time.gmtime(c["until"]))
if sub == "show":
    print(json.dumps(cur if holder else {})); sys.exit(0)
if not owner: sys.exit("ios-live: lease %s needs an owner" % sub)
if sub == "holds":
    if holder == owner: sys.exit(0)
    sys.exit("ios-live: take the lease first: ios-live lease take" if not holder
             else "ios-live: the lease is held by %s until %s" % (holder, until(cur)))
if holder and holder != owner:
    sys.exit("ios-live: the lease is held by %s until %s" % (holder, until(cur)))
if sub in ("take", "beat"):
    now = int(time.time())
    cur = {"owner": owner, "since": cur.get("since", now) if holder == owner else now, "until": now + 60 * minutes}
    json.dump(cur, open(path + ".tmp", "w")); os.replace(path + ".tmp", path); print(json.dumps(cur))
elif sub == "release":
    if os.path.exists(path): os.remove(path)
    print("{}")
else:
    sys.exit("ios-live: lease show|take|beat|release")
' "$root/lease" "$1" "${2:-}" "${3:-20}"
}

# --- checkout, toolchain, device ---------------------------------------------------------------
pick_xcode() {
  [[ -n "${DEVELOPER_DIR:-}" ]] && return 0
  DEVELOPER_DIR="$(xcode-select -p)"; export DEVELOPER_DIR
}

ensure_xcodegen() {
  local d="$root/tools/xcodegen-$xcodegen_version"
  xcodegen="$d/xcodegen/bin/xcodegen"
  [[ -x "$xcodegen" ]] && return 0
  rm -rf "$d"; mkdir -p "$d"
  curl -fsSL --retry 3 -o "$d/xcodegen.zip" \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$xcodegen_version/xcodegen.zip"
  [[ "$(shasum -a 256 "$d/xcodegen.zip" | awk '{print $1}')" == "$xcodegen_sha256" ]] || die "xcodegen checksum mismatch"
  unzip -q "$d/xcodegen.zip" -d "$d"
}

# checkout BASE [PATCH]: src at BASE (fetched when absent) plus PATCH; prints the full base sha.
checkout() {
  local ref="$1" patch="${2:-}" sha
  [[ -d "$src/.git" ]] || git clone -q --filter=blob:none --no-checkout "$repo_url" "$src"
  if ! sha="$(git -C "$src" rev-parse -q --verify "$ref^{commit}" 2>/dev/null)"; then
    git -C "$src" fetch -q origin "$branch" "$ref" 2>/dev/null || git -C "$src" fetch -q origin "$branch"
    sha="$(git -C "$src" rev-parse -q --verify "$ref^{commit}")" || die "no commit $ref on origin (push it, or use a feat-cmux-next ancestor)"
  fi
  git -C "$src" checkout -q --detach -f "$sha"
  # Build products inside the tree survive: the FFI and the generated project.
  git -C "$src" clean -qfd -e cmux-next-ios/CmuxMobileKit/Frameworks -e cmux-next-ios/CmuxMobileApp.xcodeproj \
    -e cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLinkFFI
  if [[ -n "$patch" && -s "$patch" ]]; then
    git -C "$src" apply --whitespace=nowarn "$patch" || die "your patch does not apply on $sha"
  fi
  echo "$sha"
}

# The Rust FFI is the slow part (about 5 min cold). It is rebuilt only when its inputs change: from
# the fleet's FFI cache when this host has it, else by cargo; a host with no Rust iOS targets
# (a laptop) gets it copied in with `ios-live ffi-sync`.
ffi_stamp() { git -C "$src" ls-files -s cmux-next-ios/rust | git hash-object --stdin; git -C "$src" diff HEAD -- cmux-next-ios/rust | git hash-object --stdin; }
build_ffi() {
  local stamp xcf="$src/cmux-next-ios/CmuxMobileKit/Frameworks/CmuxMobileLinkFFI.xcframework"
  stamp="$(ffi_stamp | tr '\n' '-')"
  if [[ -f "$xcf/Info.plist" && "$(cat "$root/ffi.stamp" 2>/dev/null)" == "$stamp" ]]; then ffi_how=unchanged; return 0; fi
  if [[ -f "$root/ffi/synced" ]]; then  # copied in by `ios-live ffi-sync` (a host with no Rust iOS targets)
    mkdir -p "$src/cmux-next-ios/CmuxMobileKit"
    rsync -a "$root/ffi/Frameworks" "$root/ffi/Sources" "$src/cmux-next-ios/CmuxMobileKit/"
    ffi_how="synced from $(cat "$root/ffi/synced")"; echo "$stamp" >"$root/ffi.stamp"; return 0
  fi
  local key=""
  key="$(cd "$src" && python3 -I scripts/ci/ios_ffi_cache.py key "$src" "$root/logs/ffi-inputs.json" 2>/dev/null)" || key=""
  if [[ "$key" =~ ^[0-9a-f]{64}$ ]] && (cd "$src" && python3 -I scripts/ci/ios_ffi_cache.py restore "$src" "$key") >"$root/logs/ffi-cache.log" 2>&1 \
    && [[ -f "$xcf/Info.plist" ]]; then
    ffi_how="cache hit"
  elif rustup target list --installed 2>/dev/null | grep -q aarch64-apple-ios-sim; then
    (cd "$src" && JOBS="$jobs" bash cmux-next-ios/rust/scripts/build-xcframework.sh) >"$root/logs/ffi.log" 2>&1 \
      || { tail -40 "$root/logs/ffi.log"; die "FFI build failed (log $root/logs/ffi.log)"; }
    ffi_how=built
  else
    die "the Rust FFI changed and this host has no Rust iOS targets: ios-live ffi-sync FROM_HOST (a fleet host that built it)"
  fi
  echo "$stamp" >"$root/ffi.stamp"
}

project_stamp() { git -C "$src" hash-object cmux-next-ios/project.yml; { git -C "$src" ls-files cmux-next-ios/App; git -C "$src" ls-files -o --exclude-standard cmux-next-ios/App; } | git hash-object --stdin; }
gen_project() {
  local stamp; stamp="$(project_stamp | tr '\n' '-')"
  if [[ -d "$src/cmux-next-ios/CmuxMobileApp.xcodeproj" && "$(cat "$root/project.stamp" 2>/dev/null)" == "$stamp" ]]; then gen_how=unchanged; return 0; fi
  (cd "$src/cmux-next-ios" && "$xcodegen" generate -q) >"$root/logs/xcodegen.log" 2>&1 || { cat "$root/logs/xcodegen.log"; die "xcodegen failed"; }
  echo "$stamp" >"$root/project.stamp"; gen_how=generated
}

has_live_code() { [[ -x "$src/scripts/live-code/ios-sim.sh" || -f "$src/scripts/live-code/ios-sim.sh" ]]; }

build_app() {
  local log="$root/logs/build-$(date -u +%Y%m%dT%H%M%SZ).log"
  if has_live_code; then
    build_kind=live-code
    (cd "$src" && XCODEGEN="$xcodegen" JOBS="$jobs" bash scripts/live-code/ios-sim.sh build "$root/live" Demo) >"$log" 2>&1 \
      || { tail -30 "$log"; die "live code build failed (log $log)"; }
    app="$(cat "$root/live/app-path")"
  else
    build_kind=plain
    xcodebuild -project "$src/cmux-next-ios/CmuxMobileApp.xcodeproj" -scheme CmuxMobileApp -configuration Demo \
      -destination 'generic/platform=iOS Simulator' -derivedDataPath "$root/dd" -jobs "$jobs" \
      CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
      COMPILER_INDEX_STORE_ENABLE=NO \
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG CMUX_MOBILE_DEMO' build >"$log" 2>&1 \
      || { grep -E "error:" "$log" | sort -u | head -30 >&2; die "build failed (log $log)"; }
    app="$root/dd/Build/Products/Demo-iphonesimulator/CmuxMobileApp.app"
  fi
  ln -sf "$log" "$root/logs/build-latest.log"
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
}

ensure_device() {
  udid="$(simctl list devices -j | python3 -c '
import json, sys
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["name"] == sys.argv[1] and d.get("isAvailable", True): print(d["udid"]); raise SystemExit' "$device_name")"
  if [[ -z "$udid" ]]; then
    local runtime dtype
    runtime="$(xcrun simctl list -j runtimes | python3 -c '
import json, sys
r = [x for x in json.load(sys.stdin)["runtimes"] if x["platform"] == "iOS" and x["isAvailable"]]
print(r[-1]["identifier"] if r else "")')"
    [[ -n "$runtime" ]] || die "no iOS simulator runtime on this host (xcodebuild -downloadPlatform iOS)"
    dtype="$(xcrun simctl list -j devicetypes | python3 -c '
import json, sys
t = [x["identifier"] for x in json.load(sys.stdin)["devicetypes"] if x["name"].startswith("iPhone") and "Pro" in x["name"] and "Max" not in x["name"]]
print(t[-1])')"
    udid="$(simctl create "$device_name" "$dtype" "$runtime")"
  fi
  if ! simctl list devices | grep -F "$udid" | grep -q Booted; then
    simctl boot "$udid"
    simctl bootstatus "$udid" -b >/dev/null
    simctl ui "$udid" appearance dark >/dev/null 2>&1 || true
  fi
}

launch_env_args() {  # the app's launch environment, as KEY=VALUE words
  [[ -f "$root/launch.env" ]] || return 0
  grep -v '^[[:space:]]*\(#\|$\)' "$root/launch.env" || true
}

install_and_launch() {
  local words=() w
  while IFS= read -r w; do words+=("$w"); done < <(launch_env_args)
  if [[ "$build_kind" == live-code ]]; then
    IOS_SIM_SET="$sims" bash "$src/scripts/live-code/ios-sim.sh" run "$root/live" "$udid" ${words[@]+"${words[@]}"} >"$root/logs/run.log" 2>&1 \
      || { cat "$root/logs/run.log"; die "launch failed"; }
  else
    simctl install "$udid" "$app"
    simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
    local envs=()
    for w in ${words[@]+"${words[@]}"}; do envs+=("SIMCTL_CHILD_$w"); done
    env ${envs[@]+"${envs[@]}"} xcrun simctl --set "$sims" launch "$udid" "$bundle_id" >/dev/null
  fi
}

# rebuild OWNER KIND BASE [PATCH]: checkout, FFI, project, build, install, launch, timings.
rebuild() {
  local owner="$1" kind="$2" ref="$3" patch="${4:-}" t0 t1 t2 t3 t4 t5 base digest=none
  t0=$(now_ms)
  base="$(checkout "$ref" "$patch")"
  [[ -n "$patch" && -s "$patch" ]] && digest="$(shasum -a 256 "$patch" | cut -c1-12)"
  pick_xcode; ensure_xcodegen
  t1=$(now_ms); build_ffi; t2=$(now_ms); gen_project; t3=$(now_ms); build_app; t4=$(now_ms)
  ensure_device; install_and_launch; t5=$(now_ms)
  [[ -n "$patch" && -s "$patch" ]] && cp "$patch" "$root/current.patch" || rm -f "$root/current.patch"
  state_set base="$base" patch="$digest" owner="$owner" udid="$udid" bundle_id="$bundle_id" app="$app" \
    build_kind="$build_kind" last_kind="$kind" ffi_how="$ffi_how" gen_how="$gen_how" \
    ffi_ms=$((t2-t1)) gen_ms=$((t3-t2)) build_ms=$((t4-t3)) install_launch_ms=$((t5-t4)) total_ms=$((t5-t0))
  cat "$root/state.json"
}

cmd="${1:-status}"; shift || true
case "$cmd" in
  lease) lease "$@" ;;

  up)  # up OWNER [REF]: rebuild the app at REF (default origin/feat-cmux-next) with no patch
    owner="${1:?up OWNER [REF]}"; lease holds "$owner"; rebuild "$owner" up "${2:-origin/$branch}" ;;

  swap)  # swap OWNER BASE PATCH: the app at BASE plus PATCH (git diff --binary), rebuilt warm
    owner="${1:?}"; base="${2:?}"; patch="${3:?}"; lease holds "$owner"; rebuild "$owner" swap "$base" "$patch" ;;

  swift)  # swift OWNER BASE PATCH: apply the patch's Swift files live (no build, no relaunch)
    owner="${1:?}"; ref="${2:?}"; patch="${3:?}"; lease holds "$owner"
    has_live_code && [[ "$(state_get build_kind)" == live-code ]] || die "the running app is not a live code build: use swap"
    live_base="$(state_get base)"
    want="$(git -C "$src" rev-parse -q --verify "$ref^{commit}" 2>/dev/null || true)"
    [[ "$want" == "$live_base" ]] || die "your base ${ref:0:12} is not the running app's ${live_base:0:12}: swap once (or rebase onto it), then swift"
    t0=$(now_ms)
    checkout "$live_base" "$patch" >/dev/null
    files=()
    while IFS= read -r f; do files+=("$src/$f"); done < <(git -C "$src" diff --name-only HEAD -- 'cmux-next-ios/*.swift')
    [[ ${#files[@]} -gt 0 ]] || die "the patch changes no Swift file of cmux-next-ios"
    for f in "${files[@]}"; do [[ -f "$f" ]] || die "$f is new or deleted: that needs swap"; done
    IOS_SIM_SET="$sims" bash "$src/scripts/live-code/ios-sim.sh" patch "$root/live" "${files[@]}"
    cp "$patch" "$root/current.patch"
    state_set patch="$(shasum -a 256 "$patch" | cut -c1-12)" owner="$owner" last_kind=swift swift_ms=$(( $(now_ms) - t0 )) >/dev/null ;;

  undo) owner="${1:?}"; lease holds "$owner"; IOS_SIM_SET="$sims" bash "$src/scripts/live-code/ios-sim.sh" undo "$root/live" ${2:+"$2"} ;;

  relaunch)
    owner="${1:?}"; lease holds "$owner"; ensure_device
    app="$(state_get app)"; bundle_id="$(state_get bundle_id)"; build_kind="$(state_get build_kind)"
    install_and_launch; echo relaunched ;;

  shot)  # shot OUT.png (read-only)
    out="${1:-$root/shot.png}"; ensure_device; simctl io "$udid" screenshot "$out" >/dev/null 2>&1; echo "$out" ;;

  tree)  # the accessibility tree (read-only; needs AXe)
    ensure_device; command -v axe >/dev/null || die "no axe on this host (brew install cameroncooke/axe/axe)"
    axe describe-ui --udid "$udid" ;;
  tap) owner="${1:?tap OWNER X Y}"; lease holds "$owner"; ensure_device; axe tap --udid "$udid" -x "${2:?}" -y "${3:?}" ;;
  type) owner="${1:?type OWNER TEXT}"; lease holds "$owner"; ensure_device; axe type "${2:?}" --udid "$udid" ;;

  log) tail -n "${1:-40}" "$root/live/live/live-code.log" 2>/dev/null || echo "no live code log" ;;
  udid) ensure_device; echo "$udid"; echo "set: $sims" ;;
  status)
    echo "host: $(hostname -s)  root: $root"
    cat "$root/state.json" 2>/dev/null || echo '{"state": "not up"}'; echo
    echo "lease: $(lease show)"
    simctl list devices | grep -F "$device_name" || echo "no device" ;;
  *) die "unknown command $cmd" ;;
esac
