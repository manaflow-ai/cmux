#!/usr/bin/env bash
# scripts/ios-live/host.sh person slots and supervision, against a fake `xcrun simctl` and `launchctl` on
# PATH (runs on Linux, no Xcode): who may drive a person slot (NAME and NAME/*, nobody else), that
# drivers queue on the slot's lock, and that `supervise` relaunches a dead app (with its launch env and
# its live Swift patch), boots a shut down or wedged device, leaves free slots and busy slots alone, and
# records every restart in state.json for `status`.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_SH="$ROOT_DIR/scripts/ios-live/host.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" IOS_LIVE_ROOT="$WORK/home/ios-live" FAKE_SIM="$WORK/sim.json" FAKE_LOG="$WORK/calls.log"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_CONFIG_NOSYSTEM=1
unset IOS_LIVE_SLOT IOS_LIVE_PERSON IOS_LIVE_LOCKED
mkdir -p "$HOME" "$WORK/bin"
: >"$FAKE_LOG"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

# xcrun simctl: devices per set in $FAKE_SIM. FAKE_BOOT_FAILS=N makes the next N boots never finish.
cat >"$WORK/bin/xcrun" <<'FAKE'
#!/usr/bin/env python3
import json, os, sys, uuid
a = sys.argv[1:]
assert a[0] == "simctl", a
a = a[1:]
path = os.environ["FAKE_SIM"]
try: db = json.load(open(path))
except Exception: db = {"sets": {}, "boot_fails": 0}
open(os.environ["FAKE_LOG"], "a").write(" ".join(a) + "\n")
dset = "default"
if a and a[0] == "--set": dset, a = a[1], a[2:]
devs = db["sets"].setdefault(dset, {})
def save(): json.dump(db, open(path, "w"))
def dev(u):
    if u not in devs: sys.stderr.write("Invalid device: %s\n" % u); sys.exit(148)
    return devs[u]
sub = a[0]
if sub == "list":
    if "runtimes" in a: print(json.dumps({"runtimes": [{"platform": "iOS", "isAvailable": True, "identifier": "rt.iOS-27-2"}]}))
    elif "devicetypes" in a: print(json.dumps({"devicetypes": [{"name": "iPhone 17 Pro", "identifier": "dt.iPhone-17-Pro"}]}))
    elif "-j" in a: print(json.dumps({"devices": {"rt.iOS-27-2": [{"name": d["name"], "udid": u, "state": d["state"], "isAvailable": True} for u, d in devs.items()]}}))
    else:
        for u, d in devs.items(): print("    %s (%s) (%s)" % (d["name"], u, d["state"]))
elif sub == "create":
    u = str(uuid.uuid4()).upper(); devs[u] = {"name": a[1], "state": "Shutdown", "apps": {}}; save(); print(u)
elif sub == "boot":
    d = dev(a[1])
    if db.get("boot_fails", 0) > 0: db["boot_fails"] -= 1; d["state"] = "Booting"
    else: d["state"] = "Booted"
    save()
elif sub == "bootstatus":
    sys.exit(0 if dev(a[1])["state"] == "Booted" else 1)
elif sub == "shutdown":
    d = dev(a[1]); d["state"] = "Shutdown"; d["apps"] = {}; save()
elif sub in ("ui", "install", "io", "erase"):
    dev(a[1])
elif sub == "spawn":
    d = dev(a[1])
    if a[2] == "launchctl":
        print("PID\tStatus\tLabel")
        for b in d["apps"]: print("4242\t0\tUIKitApplication:%s[a1b2][rb-legacy]" % b)
elif sub == "launch":
    d = dev(a[1])
    if d["state"] != "Booted": sys.stderr.write("device is not booted\n"); sys.exit(149)
    env = sorted(k + "=" + v for k, v in os.environ.items() if k.startswith("SIMCTL_CHILD_"))
    d["apps"][a[2]] = env; save(); print("%s: 4242" % a[2])
elif sub == "terminate":
    dev(a[1])["apps"].pop(a[2], None); save()
else:
    sys.exit("fake simctl: unknown " + sub)
FAKE
cat >"$WORK/bin/launchctl" <<'FAKE'
#!/usr/bin/env bash
echo "launchctl $*" >>"$FAKE_LOG"
case "$1" in
  print) [[ -f "$HOME/.fake-loaded" ]] ;;
  bootstrap) touch "$HOME/.fake-loaded" ;;
  bootout) rm -f "$HOME/.fake-loaded" ;;
esac
FAKE
chmod +x "$WORK/bin/xcrun" "$WORK/bin/launchctl"
export PATH="$WORK/bin:$PATH"

sim() { python3 -I -c 'import json, sys
db = json.load(open(sys.argv[1]))
for s in db["sets"].values():
    for u, d in s.items():
        if d["name"] == sys.argv[2]: exec(sys.argv[3])' "$FAKE_SIM" "$@"; }
sim_set() {  # sim_set NAME PYTHON: change a fake device
  python3 -I -c 'import json, sys
db = json.load(open(sys.argv[1]))
for s in db["sets"].values():
    for u, d in s.items():
        if d["name"] == sys.argv[2]: exec(sys.argv[3])
json.dump(db, open(sys.argv[1], "w"))' "$FAKE_SIM" "$@"; }
restarts() { python3 -I -c 'import json, sys; print(len(json.load(open(sys.argv[1])).get("restarts") or []))' "$1/state.json"; }
last_restart() { python3 -I -c 'import json, sys; r = json.load(open(sys.argv[1]))["restarts"][-1]; print(r[sys.argv[2]])' "$1/state.json" "$2"; }

aziz="$IOS_LIVE_ROOT/people/aziz"

# --- create --------------------------------------------------------------------------------------
out="$(IOS_LIVE_PERSON=aziz bash "$HOST_SH" person-create aziz/mac 2>&1)" || fail "person-create: $out"
[[ -f "$aziz/person.json" ]] || fail "no person.json"
[[ "$(sim cmux-ios-live-aziz 'print(d["state"])')" == Booted ]] || fail "the person's device is not booted"
grep -q 'supervisor: loaded' <<<"$out" || fail "person-create did not load the supervisor: $out"
plist="$HOME/Library/LaunchAgents/com.cmux.ios-live.supervise.plist"
grep -q '<integer>15</integer>' "$plist" || fail "StartInterval is not 15 s"
grep -q "$IOS_LIVE_ROOT/bin/supervise-host.sh" "$plist" || fail "the agent does not run its own copy"
cmp -s "$HOST_SH" "$IOS_LIVE_ROOT/bin/supervise-host.sh" || fail "supervise-host.sh is not this host.sh"
out="$(IOS_LIVE_PERSON=aziz bash "$HOST_SH" supervise-install)"
[[ "$out" == *"already running"* ]] || fail "supervise-install is not idempotent: $out"
pass "person-create: device cmux-ios-live-aziz booted, supervisor installed once"

out="$(IOS_LIVE_PERSON=nobody bash "$HOST_SH" status 2>&1)" && fail "status of a missing person succeeded"
[[ "$out" == *"ios-live person create nobody"* ]] || fail "missing person message: $out"
[[ ! -d "$IOS_LIVE_ROOT/people/nobody" ]] || fail "a missing person's call made its folder"
pass "a missing person slot is refused without making one"

# A built app, as `up` leaves it (plain build: install + launch), with a launch env.
cat >"$aziz/state.json" <<'JSON'
{"base": "0000000000000000000000000000000000000000", "bundle_id": "dev.cmux.test", "app": "/nowhere/App.app", "build_kind": "plain"}
JSON
printf 'CMUX_MOBILE_STACK_ENVIRONMENT=production\n' >"$aziz/launch.env"

# --- admission -------------------------------------------------------------------------------------
for who in aziz aziz/agent-3 aziz/mac; do
  IOS_LIVE_PERSON=aziz bash "$HOST_SH" relaunch "$who" >/dev/null 2>&1 || fail "$who was refused"
done
pass "aziz, aziz/agent-3 and aziz/mac may drive aziz's slot"
for who in bob azizx azizx/agent "" "bob/aziz"; do
  out="$(IOS_LIVE_PERSON=aziz bash "$HOST_SH" relaunch "$who" 2>&1)" && fail "'$who' was admitted"
  [[ "$out" == *"only aziz or aziz/* may drive it"* || -z "$who" ]] || fail "refusal for '$who': $out"
done
out="$(IOS_LIVE_PERSON=aziz bash "$HOST_SH" lease release aziz 2>&1)"
[[ "$out" == *"never released or reset"* ]] || fail "release of a person slot: $out"
[[ -f "$aziz/state.json" ]] || fail "release reset the person slot"
pass "bob, azizx, bob/aziz refused; release never resets it"

# --- the drive lock serializes drivers ----------------------------------------------------------------
python3 -I -c 'import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT); fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close(); time.sleep(2)' "$aziz/lease/drive.lock" "$WORK/locked" &
holder=$!
while [[ ! -f "$WORK/locked" ]]; do sleep 0.05; done
t0=$(date +%s%N)
IOS_LIVE_PERSON=aziz bash "$HOST_SH" relaunch aziz/agent-3 >/dev/null 2>&1 || fail "queued relaunch failed"
waited=$(( ($(date +%s%N) - t0) / 1000000 ))
(( waited >= 1200 )) || fail "a second driver did not wait for the lock (${waited} ms)"
out="$(IOS_LIVE_PERSON=aziz bash "$HOST_SH" lease show)"
[[ "$out" == *'"drive_lock": "free"'* && "$out" == *'"aziz/*"'* ]] || fail "lease show: $out"
wait "$holder"
pass "a second driver queued on the slot's lock (${waited} ms)"

# --- supervise: a dead app ----------------------------------------------------------------------------
sim_set cmux-ios-live-aziz 'd["apps"] = {}'
bash "$HOST_SH" supervise >"$WORK/sup.log" 2>&1 || fail "supervise: $(cat "$WORK/sup.log")"
[[ "$(sim cmux-ios-live-aziz 'print(" ".join(d["apps"].get("dev.cmux.test", ["dead"])))')" == "SIMCTL_CHILD_CMUX_MOBILE_STACK_ENVIRONMENT=production" ]] \
  || fail "the app was not relaunched with its launch env: $(cat "$WORK/sup.log")"
[[ "$(restarts "$aziz")" == 1 && "$(last_restart "$aziz" cause)" == "app not running" && "$(last_restart "$aziz" result)" == ok ]] \
  || fail "restart record: $(cat "$aziz/state.json")"
grep -q 'erase' "$FAKE_LOG" && fail "supervise erased a device"
pass "supervise relaunched the dead app with its launch env and recorded it"

bash "$HOST_SH" supervise >/dev/null 2>&1
[[ "$(restarts "$aziz")" == 1 ]] || fail "supervise restarted a healthy slot"
pass "a healthy slot is left alone"

# --- supervise: a shut down device ------------------------------------------------------------------
sim_set cmux-ios-live-aziz 'd["state"] = "Shutdown"; d["apps"] = {}'
bash "$HOST_SH" supervise >/dev/null 2>&1
[[ "$(sim cmux-ios-live-aziz 'print(d["state"], "dev.cmux.test" in d["apps"])')" == "Booted True" ]] || fail "device not booted with its app"
[[ "$(last_restart "$aziz" cause)" == "device Shutdown; app not running" && "$(last_restart "$aziz" how)" == "boot; relaunch" ]] \
  || fail "restart record: $(cat "$aziz/state.json")"
pass "supervise booted the shut down device and relaunched the app"

# --- supervise: a wedged device (boot never finishes): shutdown, boot -----------------------------------
sim_set cmux-ios-live-aziz 'd["state"] = "Shutdown"; d["apps"] = {}'
python3 -I -c 'import json, sys; db = json.load(open(sys.argv[1])); db["boot_fails"] = 1; json.dump(db, open(sys.argv[1], "w"))' "$FAKE_SIM"
bash "$HOST_SH" supervise >/dev/null 2>&1
[[ "$(last_restart "$aziz" how)" == "shutdown, boot; relaunch" && "$(last_restart "$aziz" result)" == ok ]] \
  || fail "wedge recovery: $(cat "$aziz/state.json")"
pass "a device whose boot never finished was shut down and booted"

# --- supervise skips a slot whose lock is held (a swap is running) --------------------------------------
sim_set cmux-ios-live-aziz 'd["apps"] = {}'
python3 -I -c 'import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT); fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close(); time.sleep(3)' "$aziz/lease/drive.lock" "$WORK/locked2" &
holder=$!
while [[ ! -f "$WORK/locked2" ]]; do sleep 0.05; done
bash "$HOST_SH" supervise >/dev/null 2>&1
[[ "$(restarts "$aziz")" == 3 ]] || fail "supervise touched a slot mid-swap"
wait "$holder"
bash "$HOST_SH" supervise >/dev/null 2>&1
[[ "$(restarts "$aziz")" == 4 ]] || fail "supervise did not come back to it"
pass "supervise waits out a running swap"

# --- shared slots: held ones are supervised, free ones are not ----------------------------------------
for n in 1 2; do
  IOS_LIVE_SLOT=$n bash "$HOST_SH" udid >/dev/null
  printf '{"bundle_id": "dev.cmux.test", "app": "/nowhere/App.app", "build_kind": "plain"}\n' >"$IOS_LIVE_ROOT/slots/$n/state.json"
  sim_set "cmux-ios-live-$n" 'd["apps"] = {}'
done
IOS_LIVE_SLOT=1 bash "$HOST_SH" slot-take agent-x 20 >/dev/null
bash "$HOST_SH" supervise >/dev/null 2>&1
[[ "$(restarts "$IOS_LIVE_ROOT/slots/1")" == 1 ]] || fail "a held slot was not supervised"
[[ "$(restarts "$IOS_LIVE_ROOT/slots/2")" == 0 ]] || fail "a free slot was supervised"
pass "a held slot is supervised, a free one is not"

# --- live Swift patches come back after a relaunch ------------------------------------------------------
src="$aziz/src"
mkdir -p "$src/scripts/live-code" "$src/cmux-next-ios"
cat >"$src/scripts/live-code/ios-sim.sh" <<'FAKE'
#!/usr/bin/env bash
echo "ios-sim.sh $*" >>"$FAKE_LOG"
case "$1" in
  run) env SIMCTL_CHILD_CMUX_LIVE_CODE_DIR="$2/live" xcrun simctl --set "$IOS_SIM_SET" launch "$3" dev.cmux.test >/dev/null ;;
esac
FAKE
echo 'let a = 1' >"$src/cmux-next-ios/A.swift"
git -C "$src" init -q && git -C "$src" add -A && git -C "$src" commit -qm base
base="$(git -C "$src" rev-parse HEAD)"
echo 'let a = 2' >"$src/cmux-next-ios/A.swift"
mkdir -p "$aziz/live-patches"; git -C "$src" diff >"$aziz/live-patches/100.patch"
echo 'let a = 3' >"$src/cmux-next-ios/A.swift"; git -C "$src" diff >"$aziz/live-patches/200.patch"
git -C "$src" checkout -q -- .
printf '{"base": "%s", "bundle_id": "dev.cmux.test", "app": "/nowhere/App.app", "build_kind": "live-code"}\n' "$base" >"$aziz/state.json"
sim_set cmux-ios-live-aziz 'd["apps"] = {}'
: >"$FAKE_LOG"
bash "$HOST_SH" supervise >"$WORK/sup.log" 2>&1
grep -q "ios-sim.sh run $aziz/live" "$FAKE_LOG" || fail "not relaunched through ios-sim.sh run: $(cat "$FAKE_LOG")"
grep -q "ios-sim.sh patch $aziz/live $src/cmux-next-ios/A.swift" "$FAKE_LOG" || fail "live patch not re-applied: $(cat "$FAKE_LOG") $(cat "$aziz/logs/supervise-launch.log")"
[[ "$(cat "$src/cmux-next-ios/A.swift")" == "let a = 3" ]] || fail "re-applied the older patch, not the newest"
[[ "$(last_restart "$aziz" how)" == "relaunch; live patch 200.patch re-applied" ]] || fail "record: $(cat "$aziz/state.json")"
pass "the newest live Swift patch was re-applied after the relaunch"

# --- status shows the restarts and the device's memory -------------------------------------------------
out="$(IOS_LIVE_PERSON=aziz bash "$HOST_SH" status)"
[[ "$out" == *"restarts: 1 recorded, the last 1:"* && "$out" == *"app not running -> relaunch; live patch 200.patch"* ]] || fail "status restarts: $out"
[[ "$out" == *"device: cmux-ios-live-aziz Booted, RSS "*" MB"* && "$out" == *"drivers: aziz, aziz/* (no lease)"* ]] || fail "status device line: $out"
out="$(bash "$HOST_SH" people)"
[[ "$out" == aziz$'\t'*Booted* ]] || fail "people: $out"
pass "status lists the restarts and the device's RSS; people lists aziz"

echo "PASS: ios-live person slots and supervision"
