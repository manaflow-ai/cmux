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

# Slots (IOS_LIVE_SLOT=N, set by the client in slot mode): many devices on one host, each its own
# driver. Slot N lives in IOS_LIVE_ROOT/slots/N with the same layout as above (its own checkout,
# DerivedData, device set, lease and state), and its iPhone is cmux-ios-live-N. The pinned tools
# are shared. With no IOS_LIVE_SLOT nothing changes: one device, cmux-ios-live, in IOS_LIVE_ROOT.
#
# Person slots (IOS_LIVE_PERSON=NAME): one person's own device, kept for them and their agents.
# IOS_LIVE_ROOT/people/NAME has the same layout, its iPhone is cmux-ios-live-NAME, and it never
# lapses, is never reset on release and is never handed to anyone else. Owners NAME and NAME/*
# (aziz, aziz/agent-3, aziz/mac) may drive it; there is no timed lease: commands that change it
# take the slot's lock (lease/drive.lock) for as long as they run, so they queue instead.
#
# Supervision (`supervise`, every ~15 s from the launchd agent `supervise-install` writes): every
# person slot and every held slot stays Booted with its app running. A dead app is relaunched with
# the slot's launch env and its live Swift patches applied again; a wedged device is shut down and
# booted (last resort: only that device's own launchd_sim tree is killed). Devices are never
# erased, so the keychain sign-in survives. Each restart is in state.json `restarts`.
base_root="${IOS_LIVE_ROOT:-$HOME/ios-live}"
slot="${IOS_LIVE_SLOT:-}"
person="${IOS_LIVE_PERSON:-}"
slot_count="${IOS_LIVE_SLOTS_PER_HOST:-3}"
root="$base_root"
repo_url="https://github.com/manaflow-ai/cmux.git"
branch="feat-cmux-next"
device_name="cmux-ios-live"
pooled=""  # a slot or a person slot: slimmed device, animations off
if [[ -n "$person" ]]; then
  [[ "$person" =~ ^[a-z0-9][a-z0-9._-]{0,31}$ ]] || { echo "ios-live: bad person name $person (a-z 0-9 . _ -)" >&2; exit 1; }
  [[ -z "$slot" ]] || { echo "ios-live: IOS_LIVE_PERSON and IOS_LIVE_SLOT are exclusive" >&2; exit 1; }
  root="$base_root/people/$person"
  device_name="cmux-ios-live-$person"
  pooled=1
  if [[ ! -f "$root/person.json" && "${1:-}" != person-create ]]; then
    echo "ios-live: no person slot $person on $(hostname -s) (ios-live person create $person)" >&2; exit 4
  fi
elif [[ -n "$slot" ]]; then
  [[ "$slot" =~ ^[1-9][0-9]?$ ]] || { echo "ios-live: bad slot $slot" >&2; exit 1; }
  root="$base_root/slots/$slot"
  device_name="cmux-ios-live-$slot"
  pooled=1
fi
[[ "$slot_count" =~ ^[1-9][0-9]?$ ]] || { echo "ios-live: bad IOS_LIVE_SLOTS_PER_HOST $slot_count" >&2; exit 1; }
xcodegen_version=2.46.0
xcodegen_sha256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
jobs="${IOS_LIVE_JOBS:-4}"
src="$root/src"
sims="$root/sims"
mkdir -p "$root/logs" "$base_root/tools" "$sims" "$root/lease"

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

# --- slots: take any free one, list them -----------------------------------------------------
slots_py() {  # take OWNER MIN | list: the per-slot leases, under each slot's own lock
  python3 -I -c '
import fcntl, json, os, sys, time
base, n, sub, owner, minutes = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], min(int(sys.argv[5]), 120)
def read(i):
    d = os.path.join(base, "slots", str(i), "lease"); os.makedirs(d, exist_ok=True)
    lock = open(os.path.join(d, "lock"), "w"); fcntl.flock(lock, fcntl.LOCK_EX)
    path = os.path.join(d, "owner.json")
    try: cur = json.load(open(path))
    except Exception: cur = {}
    return lock, path, cur if cur.get("until", 0) > time.time() else {}
if sub == "list":
    for i in range(1, n + 1):
        lock, path, cur = read(i); lock.close()
        st = os.path.join(base, "slots", str(i), "state.json")
        try: base_sha = json.load(open(st)).get("base", "")[:12]
        except Exception: base_sha = "not up"
        held = "%s until %s" % (cur["owner"], time.strftime("%H:%MZ", time.gmtime(cur["until"]))) if cur else "free"
        print("%d\t%s\t%s" % (i, base_sha or "not up", held))
    sys.exit(0)
if not owner: sys.exit("ios-live: slot take needs an owner")
# Your own slot first, so a second take renews it rather than holding two.
for want_own in (True, False):
    for i in range(1, n + 1):
        lock, path, cur = read(i)
        if (cur.get("owner") == owner) if want_own else not cur:
            now = int(time.time())
            new = {"owner": owner, "since": cur.get("since", now), "until": now + 60 * minutes}
            json.dump(new, open(path + ".tmp", "w")); os.replace(path + ".tmp", path)
            print(i); sys.exit(0)
        lock.close()
sys.exit(3)
' "$base_root" "$slot_count" "$@"
}

# --- checkout, toolchain, device ---------------------------------------------------------------
pick_xcode() {
  [[ -n "${DEVELOPER_DIR:-}" ]] && return 0
  DEVELOPER_DIR="$(xcode-select -p)"; export DEVELOPER_DIR
}

ensure_xcodegen() {
  local d="$base_root/tools/xcodegen-$xcodegen_version"
  xcodegen="$d/xcodegen/bin/xcodegen"
  [[ -x "$xcodegen" ]] && return 0
  rm -rf "$d"; mkdir -p "$d"
  bash "$src/scripts/ci/fetch-xcodegen.sh" "$xcodegen_version" "$xcodegen_sha256" "$d" >/dev/null || die "xcodegen fetch failed"
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
  if [[ -f "$base_root/ffi/synced" ]]; then  # copied in by `ios-live ffi-sync` (a host with no Rust iOS targets)
    mkdir -p "$src/cmux-next-ios/CmuxMobileKit"
    rsync -a "$base_root/ffi/Frameworks" "$base_root/ffi/Sources" "$src/cmux-next-ios/CmuxMobileKit/"
    ffi_how="synced from $(cat "$base_root/ffi/synced")"; echo "$stamp" >"$root/ffi.stamp"; return 0
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
    [[ -z "$pooled" ]] || slim_device
  fi
  if ! simctl list devices | grep -F "$udid" | grep -q Booted; then
    simctl boot "$udid"
    simctl bootstatus "$udid" -b >/dev/null
    simctl ui "$udid" appearance dark >/dev/null 2>&1 || true
    [[ -z "$pooled" ]] || animations_off
  fi
}

# A slot's device is slimmed once, shut down, before its first boot: the fleet's pinned simslim
# (hq build-fleet sim_slim.go) when this host has it, keeping push and universal links.
simslim_bin=/Users/Shared/cmux-build-fleet/tools/bin/simslim
slim_device() {
  [[ -x "$simslim_bin" ]] || { echo "ios-live: no simslim on this host; $device_name stays stock" >&2; return 0; }
  local profile="$root/simslim-profile.json"
  printf '{"name": "cmux-ios-live", "description": "ios-live slot (scripts/ios-live/host.sh)", "keep": ["com.apple.apsd", "com.apple.swcd"]}\n' >"$profile"
  { "$simslim_bin" --set "$sims" on "$udid" --profile "$profile" && "$simslim_bin" --set "$sims" verify "$udid" --profile "$profile"; } \
    >"$root/logs/simslim.log" 2>&1 || echo "ios-live: simslim failed (log $root/logs/simslim.log); $device_name stays stock" >&2
}

# Animations off on a slot's device: Reduce Motion, and UIKit's animation speed-up for agents' taps.
animations_off() {
  simctl spawn "$udid" defaults write com.apple.Accessibility ReduceMotionEnabled -bool true >/dev/null 2>&1 || true
  simctl spawn "$udid" defaults write com.apple.UIKit UIAnimationDragCoefficient -float 0.01 >/dev/null 2>&1 || true
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
  rm -rf "$root/live-patches"  # the new build has none of the live patches in it
  state_set base="$base" patch="$digest" owner="$owner" udid="$udid" bundle_id="$bundle_id" app="$app" \
    build_kind="$build_kind" last_kind="$kind" ffi_how="$ffi_how" gen_how="$gen_how" \
    ffi_ms=$((t2-t1)) gen_ms=$((t3-t2)) build_ms=$((t4-t3)) install_launch_ms=$((t5-t4)) total_ms=$((t5-t0))
  cat "$root/state.json"
}

abs() { case "$1" in /*) echo "$1" ;; *) echo "$HOME/$1" ;; esac; }

# --- admission and the drive lock ----------------------------------------------------------------
# admit OWNER: may OWNER drive this device? A person slot admits NAME and NAME/* (the person and their
# agents); anything else needs the timed lease.
admit() {
  local owner="${1:-}"
  if [[ -n "$person" ]]; then
    [[ "$owner" == "$person" || "$owner" == "$person/"* ]] && return 0
    die "$device_name is $person's: only $person or $person/* may drive it (you are ${owner:-nobody})"
  fi
  lease holds "$owner"
}

# with_lock wait|try FILE CMD...: exec CMD holding FILE's flock, which CMD and its children inherit and
# which goes with the last of them. `try` exits 75 when someone else holds it.
with_lock() {
  exec python3 -I -c '
import errno, fcntl, os, sys
mode, path, argv = sys.argv[1], sys.argv[2], sys.argv[3:]
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
try: fcntl.flock(fd, fcntl.LOCK_EX | (fcntl.LOCK_NB if mode == "try" else 0))
except OSError as e:
    if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EACCES): sys.exit(75)
    raise
os.set_inheritable(fd, True)
os.environ["IOS_LIVE_LOCKED"] = path
os.execvp(argv[0], argv)' "$@"
}
drive_lock="$root/lease/drive.lock"
self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
lock_busy() { python3 -I -c '
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError: sys.exit(0)
sys.exit(1)' "$1"; }

# --- live patches that survive a relaunch ---------------------------------------------------------
# A relaunched app runs the code as built: its engine ignores the dylibs already in its live folder.
# Every `swift` patch is the whole change against the base, so the newest one is all there is to
# re-apply. live-patches/ keeps them in order: swift pushes, undo pops, a rebuild clears.
live_patch_top() { ls "$root/live-patches" 2>/dev/null | sort | tail -n 1 | sed "s|^|$root/live-patches/|" | grep . || true; }
live_patch_apply() {  # live_patch_apply PATCH: its Swift files into the running app
  local patch="$1" files=() f
  checkout "$(state_get base)" "$patch" >/dev/null
  while IFS= read -r f; do files+=("$src/$f"); done < <(git -C "$src" diff --name-only HEAD -- 'cmux-next-ios/*.swift')
  [[ ${#files[@]} -gt 0 ]] || die "the patch changes no Swift file of cmux-next-ios"
  for f in "${files[@]}"; do [[ -f "$f" ]] || die "$f is new or deleted: that needs swap"; done
  IOS_SIM_SET="$sims" bash "$src/scripts/live-code/ios-sim.sh" patch "$root/live" "${files[@]}"
}

# --- supervision ------------------------------------------------------------------------------------
# bounded SECS CMD...: CMD, killed after SECS (a wedged CoreSimulator hangs simctl). macOS has no timeout(1).
bounded() { perl -e '$s = shift; $p = fork // die; if (!$p) { exec @ARGV or exit 127 } $SIG{ALRM} = sub { kill "KILL", $p; exit 124 }; alarm $s; waitpid $p, 0; exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' "$@"; }
find_udid() { simctl list devices -j 2>/dev/null | python3 -c '
import json, sys
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["name"] == sys.argv[1] and d.get("isAvailable", True): print(d["udid"], d["state"]); raise SystemExit' "$device_name"; }
device_state() { local u s; read -r u s < <(find_udid) || true; echo "${s:-missing}"; }
app_running() {  # the app has a live process in the device's launchd
  bounded 20 xcrun simctl --set "$sims" spawn "$udid" launchctl list 2>/dev/null \
    | awk -v b="UIKitApplication:$bundle_id" 'index($3, b) == 1 && $1 ~ /^[0-9]+$/ { f = 1 } END { exit !f }'
}
# device_tree: "PID RSS_KB" of this device's launchd_sim and everything under it (every process the
# device runs). Matched by the device's UDID in launchd_sim's arguments, so never another device's.
device_tree() { ps -A -o pid=,ppid=,rss=,command= | python3 -I -c '
import sys
udid, rows = sys.argv[1], [l.split(None, 3) for l in sys.stdin]
rows = [r for r in rows if len(r) >= 3]
tree = {r[0] for r in rows if len(r) == 4 and r[3].split()[0].endswith("/launchd_sim") and udid in r[3]}
grew = True
while grew:
    more = {r[0] for r in rows if r[1] in tree} - tree
    grew = bool(more); tree |= more
for r in rows:
    if r[0] in tree: print(r[0], r[2])' "$udid"; }
device_rss_mb() { device_tree | awk '{ k += $2 } END { printf "%d\n", k / 1024 }'; }
kill_device_tree() {
  local pids; pids="$(device_tree | awk '{print $1}' | tr '\n' ' ')"
  [[ -n "${pids// }" ]] || return 0
  kill -TERM $pids 2>/dev/null || true; sleep 2; kill -KILL $pids 2>/dev/null || true
}
boot_once() {
  bounded 90 xcrun simctl --set "$sims" boot "$udid" >/dev/null 2>&1 || true  # "current state: Booting" is fine
  bounded 120 xcrun simctl --set "$sims" bootstatus "$udid" -b >/dev/null 2>&1 || return 1
  simctl ui "$udid" appearance dark >/dev/null 2>&1 || true
  animations_off
}
# recover_device: Booted again, the gentlest way that works; sets how. Never erases, never touches
# another device, never quits Simulator.
recover_device() {
  how=boot; boot_once && return 0
  how="shutdown, boot"; bounded 60 xcrun simctl --set "$sims" shutdown "$udid" >/dev/null 2>&1 || true; boot_once && return 0
  how="killed its launchd_sim, boot"; kill_device_tree
  bounded 60 xcrun simctl --set "$sims" shutdown "$udid" >/dev/null 2>&1 || true; boot_once
}
restart_record() {  # restart_record CAUSE HOW MS RESULT: appended to state.json restarts (the last 20 kept)
  python3 -I -c 'import json, os, sys, time
path = sys.argv[1]
try: s = json.load(open(path))
except Exception: s = {}
r = s.get("restarts") or []
r.append({"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "cause": sys.argv[2], "how": sys.argv[3], "ms": int(sys.argv[4]), "result": sys.argv[5]})
s["restarts"] = r[-20:]
json.dump(s, open(path + ".tmp", "w"), indent=1); os.replace(path + ".tmp", path)' "$root/state.json" "$@"
}
# supervise_one: this slot's device Booted and its app running, its live patches back on. Runs under
# the drive lock (`try`), so it never races a swap. A slot nobody has built yet is left alone.
supervise_one() {
  bundle_id="$(state_get bundle_id)"; [[ -n "$bundle_id" ]] || return 0
  local st cause="" t0 result=ok top
  read -r udid st < <(find_udid) || true
  [[ -n "${udid:-}" ]] || { echo "ios-live supervise: $device_name is missing; the next up recreates it" >&2; return 0; }
  t0=$(now_ms); how=""
  if [[ "$st" != Booted ]]; then
    cause="device $st"
    recover_device || result="device did not boot"
  fi
  if [[ "$result" == ok ]] && ! app_running; then
    cause="${cause:+$cause; }app not running"
    if ! bounded 120 bash "$self" _launch >"$root/logs/supervise-launch.log" 2>&1; then
      # Booted but no launch: a wedged device. Shut it down, boot, try once more.
      bounded 60 xcrun simctl --set "$sims" shutdown "$udid" >/dev/null 2>&1 || true
      recover_device && bounded 120 bash "$self" _launch >>"$root/logs/supervise-launch.log" 2>&1 \
        || result="launch failed (log $root/logs/supervise-launch.log)"
      how="${how:+$how; }relaunch after a failed launch"
    else
      how="${how:+$how; }relaunch"
    fi
    top="$(live_patch_top)"
    if [[ "$result" == ok && -n "$top" && "$(state_get build_kind)" == live-code ]]; then
      bounded 120 bash "$self" _reapply >>"$root/logs/supervise-launch.log" 2>&1 \
        && how="$how; live patch $(basename "$top") re-applied" || how="$how; live patch NOT re-applied (log $root/logs/supervise-launch.log)"
    fi
  fi
  [[ -n "$cause" ]] || return 0
  local ms=$(( $(now_ms) - t0 ))
  restart_record "$cause" "$how" "$ms" "$result"
  echo "ios-live supervise: $(date -u +%FT%TZ) $device_name: $cause -> $how ($ms ms, $result)"
}

# Every person slot, and every slot someone holds. Each in its own process (its own root) under its own lock.
supervise_all() {
  local d n
  for d in "$base_root"/people/*/; do
    [[ -f "$d/person.json" ]] || continue
    n="$(basename "$d")"
    (IOS_LIVE_SLOT="" IOS_LIVE_PERSON="$n" with_lock try "$d/lease/drive.lock" bash "$self" supervise-one) || true
  done
  for d in "$base_root"/slots/*/; do
    n="$(basename "$d")"
    [[ "$n" =~ ^[1-9][0-9]?$ ]] || continue
    python3 -I -c 'import json, sys, time
sys.exit(0 if json.load(open(sys.argv[1])).get("until", 0) > time.time() else 1)' "$d/lease/owner.json" 2>/dev/null || continue
    (IOS_LIVE_PERSON="" IOS_LIVE_SLOT="$n" with_lock try "$d/lease/drive.lock" bash "$self" supervise-one) || true
  done
}

# The launchd agent runs a copy of this script that only supervise-install replaces, so an older
# checkout's host.sh (any call copies its own to bin/host.sh) never takes supervision away.
plist_label=com.cmux.ios-live.supervise
supervise_install() {
  local agents="$HOME/Library/LaunchAgents" plist bin="$base_root/bin/supervise-host.sh" tmp changed=0
  plist="$agents/$plist_label.plist"
  mkdir -p "$agents" "$base_root/bin" "$base_root/logs"
  if ! cmp -s "$self" "$bin"; then cp "$self" "$bin.tmp" && mv "$bin.tmp" "$bin"; changed=1; fi
  tmp="$(mktemp)"
  cat >"$tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$plist_label</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$bin</string><string>supervise</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>IOS_LIVE_ROOT</key><string>$base_root</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StartInterval</key><integer>${IOS_LIVE_SUPERVISE_INTERVAL:-15}</integer>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$base_root/logs/supervise.log</string>
  <key>StandardErrorPath</key><string>$base_root/logs/supervise.log</string>
</dict>
</plist>
PLIST
  if ! cmp -s "$tmp" "$plist"; then mv "$tmp" "$plist"; changed=1; else rm -f "$tmp"; fi
  local domain="gui/$(id -u)"
  if [[ "$changed" == 1 ]] || ! launchctl print "$domain/$plist_label" >/dev/null 2>&1; then
    launchctl bootout "$domain/$plist_label" >/dev/null 2>&1 || true
    launchctl bootstrap "$domain" "$plist" 2>/dev/null || launchctl load -w "$plist" \
      || die "could not load $plist (is $(id -un) logged in to the GUI?)"
    echo "supervisor: loaded $plist ($bin supervise every ${IOS_LIVE_SUPERVISE_INTERVAL:-15} s; log $base_root/logs/supervise.log)"
  else
    echo "supervisor: already running ($plist)"
  fi
}

# status's last lines: the restarts, and what the device costs in memory.
status_extra() {
  python3 -I -c 'import json, sys
try: s = json.load(open(sys.argv[1]))
except Exception: s = {}
r = s.get("restarts") or []
print("restarts: %d recorded%s" % (len(r), ", the last %d:" % min(5, len(r)) if r else ""))
for x in r[-5:]: print("  %s  %s -> %s  %d ms  %s" % (x["at"], x["cause"], x["how"], x["ms"], x["result"]))' "$root/state.json"
  local u s; read -r u s < <(find_udid) || true
  if [[ -n "${u:-}" ]]; then udid="$u"; echo "device: $device_name $s, RSS $(device_rss_mb) MB"; else echo "device: none"; fi
}

cmd="${1:-status}"; shift || true

# Commands that change the device or its app run one at a time per device, under its drive lock:
# a caller who is admitted waits for the one before it (a person slot has no timed lease to wait on).
case "$cmd" in
  erase|up|swap|swift|undo|relaunch|tap|type)
    if [[ "${IOS_LIVE_LOCKED:-}" != "$drive_lock" ]]; then
      admit "${1:-}"
      with_lock wait "$drive_lock" bash "$self" "$cmd" "$@"
    fi ;;
esac

case "$cmd" in
  lease)
    if [[ -n "$person" ]]; then  # a person slot has no lease: who may drive it, and whether a command runs now
      busy=free; lock_busy "$drive_lock" && busy=busy
      printf '{"person": "%s", "admits": ["%s", "%s/*"], "drive_lock": "%s"}\n' "$person" "$person" "$person" "$busy"
      case "${1:-show}" in show) ;; release) echo "ios-live: $device_name is $person's: never released or reset" >&2 ;; *) admit "${2:-}" ;; esac
    else
      lease "$@"
    fi ;;

  slot-take)  # slot-take OWNER [MIN]: hold any free slot on this host (or renew yours); prints N, exit 3 when all are held
    slots_py take "${1:?slot-take OWNER [MIN]}" "${2:-20}" ;;
  slots)  # one line per slot: N, base, holder
    slots_py list "" 20 ;;
  erase)  # erase OWNER: a slot's device back to new (slimmed again), then booted. Only on purpose: nothing calls it for a person.
    [[ -n "$pooled" ]] || die "erase is for a slot (IOS_LIVE_SLOT or IOS_LIVE_PERSON)"
    ensure_device; simctl shutdown "$udid" >/dev/null 2>&1 || true; simctl erase "$udid"; slim_device; ensure_device
    rm -f "$root/state.json"; rm -rf "$root/live-patches"; echo "erased $device_name" ;;

  person-create)  # person-create NAME (IOS_LIVE_PERSON=NAME): the person's own slot and device, supervised
    [[ -n "$person" ]] || die "person-create needs IOS_LIVE_PERSON"
    [[ -f "$root/person.json" ]] || printf '{"name": "%s", "created": "%s", "by": "%s"}\n' \
      "$person" "$(date -u +%FT%TZ)" "${1:-}" >"$root/person.json"
    ensure_device
    supervise_install
    echo "person slot $person: $device_name ($udid) on $(hostname -s); next: ios-live --person $person up" ;;
  people)  # one line per person slot: NAME, base, device, RSS, restarts
    for d in "$base_root"/people/*/; do
      [[ -f "$d/person.json" ]] || continue
      n="$(basename "$d")"
      IOS_LIVE_PERSON="$n" IOS_LIVE_SLOT="" bash "$self" _person-line || echo "$n	?"
    done ;;
  _person-line)
    u=""; s=""; read -r u s < <(find_udid) || true; udid="$u"
    rss=-; [[ -z "$u" ]] || rss="$(device_rss_mb) MB"
    printf '%s\t%s\t%s\t%s\t%s restarts\n' "$person" "$(state_get base | cut -c1-12)" "${s:-no device}" "$rss" \
      "$(python3 -I -c 'import json,sys
try: print(len(json.load(open(sys.argv[1])).get("restarts") or []))
except Exception: print(0)' "$root/state.json")" ;;
  person-where) echo "$(hostname -s)" ;;  # answers only on the host that has the person slot (else exit 4 above)
  load)  # booted devices on this host (all sets): how the client picks the least loaded host
    ps -A -o command= | grep -c '[l]aunchd_sim ' || true ;;

  supervise) supervise_all ;;
  supervise-one) supervise_one ;;
  supervise-install) supervise_install ;;
  _launch)  # the app launched again from its last build, with the slot's launch env (supervise)
    ensure_device; app="$(state_get app)"; bundle_id="$(state_get bundle_id)"; build_kind="$(state_get build_kind)"
    install_and_launch ;;
  _reapply)  # the newest live patch into the relaunched app (supervise)
    top="$(live_patch_top)"; [[ -n "$top" ]] || exit 0
    has_live_code || die "no live code in the checkout"; read -r udid _ < <(find_udid); live_patch_apply "$top" ;;

  up)  # up OWNER [REF]: rebuild the app at REF (default origin/feat-cmux-next) with no patch
    owner="${1:?up OWNER [REF]}"; rebuild "$owner" up "${2:-origin/$branch}" ;;

  swap)  # swap OWNER BASE PATCH: the app at BASE plus PATCH (git diff --binary), rebuilt warm
    owner="${1:?}"; base="${2:?}"; patch="$(abs "${3:?}")"; rebuild "$owner" swap "$base" "$patch" ;;

  swift)  # swift OWNER BASE PATCH: apply the patch's Swift files live (no build, no relaunch)
    owner="${1:?}"; ref="${2:?}"; patch="$(abs "${3:?}")"
    has_live_code && [[ "$(state_get build_kind)" == live-code ]] || die "the running app is not a live code build: use swap"
    live_base="$(state_get base)"
    want="$(git -C "$src" rev-parse -q --verify "$ref^{commit}" 2>/dev/null || true)"
    [[ "$want" == "$live_base" ]] || die "your base ${ref:0:12} is not the running app's ${live_base:0:12}: swap once (or rebase onto it), then swift"
    t0=$(now_ms)
    live_patch_apply "$patch"
    cp "$patch" "$root/current.patch"
    mkdir -p "$root/live-patches"; cp "$patch" "$root/live-patches/$(now_ms).patch"
    state_set patch="$(shasum -a 256 "$patch" | cut -c1-12)" owner="$owner" last_kind=swift swift_ms=$(( $(now_ms) - t0 )) >/dev/null ;;

  undo)  # undo OWNER [--all]: take back live code edits; only a live code build has any
    owner="${1:?}"
    has_live_code && [[ "$(state_get build_kind)" == live-code ]] || die "the running app is not a live code build: nothing to undo (use swap)"
    IOS_SIM_SET="$sims" bash "$src/scripts/live-code/ios-sim.sh" undo "$root/live" ${2:+"$2"}
    if [[ "${2:-}" == --all ]]; then rm -rf "$root/live-patches"; else top="$(live_patch_top)"; [[ -z "$top" ]] || rm -f "$top"; fi ;;

  relaunch)
    owner="${1:?}"; ensure_device
    app="$(state_get app)"; bundle_id="$(state_get bundle_id)"; build_kind="$(state_get build_kind)"
    install_and_launch
    if [[ -n "$(live_patch_top)" && "$build_kind" == live-code ]]; then live_patch_apply "$(live_patch_top)" >/dev/null && echo "live patch re-applied"; fi
    echo relaunched ;;

  shot)  # shot OUT.png (read-only)
    out="${1:-$root/shot.png}"; ensure_device; simctl io "$udid" screenshot "$out" >/dev/null 2>&1; echo "$out" ;;

  tree)  # the accessibility tree (read-only; needs AXe)
    ensure_device; command -v axe >/dev/null || die "no axe on this host (brew install cameroncooke/axe/axe)"
    axe describe-ui --udid "$udid" ;;
  tap) ensure_device; axe tap --udid "$udid" -x "${2:?}" -y "${3:?}" ;;
  type) ensure_device; axe type "${2:?}" --udid "$udid" ;;

  window)  # open the Simulator app on this device, in the background (for a person at the host).
    # Xcode 27 ships no Simulator.app: its Device Hub (com.apple.dt.Devices) shows simulators instead.
    ensure_device
    if open -Ra Simulator 2>/dev/null; then
      open -g -a Simulator --args -DeviceSetPath "$sims" -CurrentDeviceUDID "$udid"; echo "Simulator: $device_name"
    else
      open -g -b com.apple.dt.Devices --args -DeviceSetPath "$sims" -CurrentDeviceUDID "$udid" \
        || die "neither Simulator.app nor Device Hub (com.apple.dt.Devices) is installed"
      echo "Device Hub: $device_name ($udid, set $sims)"
    fi ;;
  log) tail -n "${1:-40}" "$root/live/live/live-code.log" 2>/dev/null || echo "no live code log" ;;
  udid) ensure_device; echo "$udid"; echo "set: $sims" ;;
  status)
    echo "host: $(hostname -s)  root: $root"
    python3 -I -c 'import json, sys
try: s = json.load(open(sys.argv[1]))
except Exception: s = {"state": "not up"}
s.pop("restarts", None); print(json.dumps(s, indent=1))' "$root/state.json"
    if [[ -n "$person" ]]; then echo "drivers: $person, $person/* (no lease)"; else echo "lease: $(lease show)"; fi
    status_extra ;;
  *) die "unknown command $cmd" ;;
esac
