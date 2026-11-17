#!/usr/bin/env bash
# launch-ready.sh's two sides share one bundle id, and cfprefsd keeps app defaults in the console user's real
# ~/Library/Preferences, so a default one side wrote (cmuxNext.launchSnapshotPath.<session>) reached the other
# side's next launch. The run sets the account's domain aside through DefaultsAside (defaults_aside) and puts it back
# at the end (defaults_restore); side_defaults gives each side its own: load clears the domain and imports that side's
# plist, save exports it; launch-ready-defaults.py check names a snapshot path outside the side's home. A stand-in for
# defaults keeps one plist per bundle id; one for plutil names the bundle.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/bin" "$root/a/x.app/Contents" "$root/b/x.app/Contents" "$root/out" "$root/store" "$root/locks"
cat >"$root/bin/plutil" <<'STUB'
#!/usr/bin/env bash
echo com.example.shared
STUB
cat >"$root/bin/defaults" <<'STUB'
#!/usr/bin/env python3
import os, plistlib, sys
verb, bundle, rest = sys.argv[1], sys.argv[2], sys.argv[3:]
store = os.path.join(os.environ["DEFAULTS_STORE"], bundle + ".plist")
domain = plistlib.load(open(store, "rb")) if os.path.exists(store) else None
if verb == "import" and os.environ.get("DEFAULTS_FAIL_IMPORT"):
    sys.exit(1)
if verb == "delete":
    sys.exit(0 if domain is not None and not os.remove(store) else 1)
if verb == "export":
    plistlib.dump(domain or {}, open(rest[0], "wb"), fmt=plistlib.FMT_BINARY)
elif verb == "import":
    plistlib.dump({**(domain or {}), **plistlib.load(open(rest[0], "rb"))}, open(store, "wb"))
elif verb == "write":
    plistlib.dump({**(domain or {}), rest[0]: rest[1]}, open(store, "wb"))
elif verb == "read":
    print(" ".join(f"{k}={v}" for k, v in sorted((domain or {}).items())))
STUB
chmod +x "$root/bin/plutil" "$root/bin/defaults"
export PATH="$root/bin:$PATH" DEFAULTS_STORE="$root/store" CMUX_FRESH_SMOKE_DEFAULTS_TOOL="$root/bin/defaults" \
  CMUX_FRESH_SMOKE_LOCK_DIR="$root/locks"
fail() { echo "launch-ready defaults: $*" >&2; exit 1; }

cd "$here/../.."
# shellcheck source=../launch-ready.sh
source "$here/launch-ready.sh"
out="$root/out" a="$root/a/x.app" b="$root/b/x.app"
cp scripts/measure/launch-ready-defaults.py "$out/defaults.py" # as main copies them
cp scripts/ci/fresh_home_launch_smoke.py "$out/fresh_home_launch_smoke.py"
key=cmuxNext.launchSnapshotPath.cmux-app

# The account's own defaults are set aside for the run, once per bundle id.
defaults write com.example.shared mine yes
LR_ASIDE=""
defaults_aside "$out" "$a" && defaults_aside "$out" "$b"
[[ "$LR_ASIDE" == " com.example.shared" ]] || fail "set aside '$LR_ASIDE', want the bundle once"
[[ -z "$(defaults read com.example.shared)" ]] || fail "the account's defaults were not set aside"

# Side a launches and writes its snapshot path; then side b launches.
side_defaults "$out" load "$a" "$root/a/defaults.plist"
defaults write com.example.shared "$key" "$root/a/home/launch-snapshot.json"
side_defaults "$out" save "$a" "$root/a/defaults.plist"
side_defaults "$out" load "$b" "$root/b/defaults.plist"
got="$(defaults read com.example.shared)"
[[ -z "$got" ]] || fail "side b's first launch read side a's defaults: $got"
defaults write com.example.shared "$key" "$root/b/home/launch-snapshot.json"
side_defaults "$out" save "$b" "$root/b/defaults.plist"

# Side a's next launch reads its own, not side b's.
side_defaults "$out" load "$a" "$root/a/defaults.plist"
got="$(defaults read com.example.shared)"
[[ "$got" == "$key=$root/a/home/launch-snapshot.json" ]] || fail "side a's relaunch read '$got', want its own snapshot path"

# A snapshot path in the other side's home is named; one in the side's own home is not.
[[ -z "$(python3 -I "$out/defaults.py" check "$root/a/defaults.plist" "$root/a/home/")" ]] || fail "side a's own path was named"
cross="$(python3 -I "$out/defaults.py" check "$root/b/defaults.plist" "$root/a/home/" || true)"
[[ "$cross" == *"$root/b/home/launch-snapshot.json"* ]] || fail "side b's path read from side a's home was not named: '$cross'"

# A put-back that fails is a failure (the step exits 4), and the copy stays for the next run to put back.
DEFAULTS_FAIL_IMPORT=1 defaults_restore "$out" && fail "a failed put-back returned success"

# At exit the account's defaults come back as they were.
defaults_restore "$out"
got="$(defaults read com.example.shared)"
[[ "$got" == "mine=yes" ]] || fail "the account's defaults came back as '$got'"
echo "launch-ready defaults: each side reads only its own, and the account's come back"
