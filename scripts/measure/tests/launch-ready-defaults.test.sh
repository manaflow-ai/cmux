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

# snapshot=foreign: the donor's saved snapshot path is planted in side a's own plist and printed for check --allow.
mkdir -p "$root/donor/home" && echo '{}' >"$root/donor/home/launch-snapshot.json"
side_defaults "$out" load "$a" "$root/donor/defaults.plist"
defaults write com.example.shared "$key" "$root/donor/home/launch-snapshot.json"
side_defaults "$out" save "$a" "$root/donor/defaults.plist"
python3 -I "$out/defaults.py" plant "$root/a/defaults.plist" "$root/b/defaults.plist" >/dev/null \
  && fail "a donor whose snapshot file does not exist was planted"
planted="$(python3 -I "$out/defaults.py" plant "$root/a/defaults.plist" "$root/donor/defaults.plist")"
[[ "$planted" == "$key=$root/donor/home/launch-snapshot.json" ]] || fail "plant printed '$planted'"
side_defaults "$out" load "$a" "$root/a/defaults.plist"
got="$(defaults read com.example.shared)"
[[ "$got" == "$key=$root/donor/home/launch-snapshot.json" ]] || fail "side a's planted launch read '$got'"
side_defaults "$out" save "$a" "$root/a/defaults.plist"
# The planted key passes check only with --allow naming exactly it; any other foreign key or path still fails.
python3 -I "$out/defaults.py" check "$root/a/defaults.plist" "$root/a/home/" >/dev/null \
  && fail "the planted path passed check without --allow"
[[ -z "$(python3 -I "$out/defaults.py" check "$root/a/defaults.plist" "$root/a/home/" --allow "$planted")" ]] \
  || fail "the planted path was named with --allow"
cross="$(python3 -I "$out/defaults.py" check "$root/a/defaults.plist" "$root/a/home/" \
  --allow "$key=$root/b/home/launch-snapshot.json" || true)"
[[ "$cross" == *"$root/donor/home/launch-snapshot.json"* ]] || fail "--allow of another path let the planted one pass: '$cross'"
defaults write com.example.shared cmuxNext.launchSnapshotPath.other "$root/b/home/launch-snapshot.json"
side_defaults "$out" save "$a" "$root/a/defaults.plist"
cross="$(python3 -I "$out/defaults.py" check "$root/a/defaults.plist" "$root/a/home/" --allow "$planted" || true)"
[[ "$cross" == *cmuxNext.launchSnapshotPath.other* && "$cross" != *"$root/donor/"* ]] \
  || fail "a foreign key other than the planted one was not named, or the planted one was: '$cross'"

# stale_reason reads the verdict from the app's log line; stale_verdict prints LR-STALE-SNAPSHOT and fails a launch
# that did not show Home or made a workspace.
cat >"$root/bin/log" <<'STUB'
#!/usr/bin/env bash
[[ -z "${LOG_FAIL:-}" ]] || exit 1
[[ "$*" == *"processIdentifier == 42 "* ]] && echo "2026-11-17 Df cmux[42:1] [com.cmuxterm.app.next:window-rules] launch snapshot stale (otherSession): launching as with nothing to restore"
exit 0
STUB
chmod +x "$root/bin/log"
[[ "$(stale_reason 42 "2026-11-17 00:00:00")" == otherSession ]] || fail "stale_reason did not read otherSession"
[[ "$(stale_reason 43 "2026-11-17 00:00:00")" == none ]] || fail "stale_reason named a verdict the app did not log"
[[ "$(LOG_FAIL=1 stale_reason 42 "2026-11-17 00:00:00")" == unknown ]] || fail "an unread log was not unknown"
v="$root/verdict" && mkdir -p "$v"
row() { # LABEL TOP WORKSPACES SHOWN_MS TREE_MS
  local marks="{}"
  [[ -n "$4" ]] && marks="{\"launch_snapshot_shown\": $4, \"daemon.first_tree_applied\": $5}"
  echo "{\"side\": \"head\", \"label\": \"$1\", \"front\": {\"top_page\": \"$2\", \"workspaces\": $3}, \"marks\": $marks}"
}
{
  row prime home 1 "" ""; row run1 home 1 100 140; row run2 home 1 100 120; row run3 home 1 "" ""
  row run4 home 1 100 200; row run5 home 1 100 110
  echo '{"side": "foreign-head", "label": "prime", "front": {"top_page": "home", "workspaces": 1}, "marks": {}}'
} >"$v/runs.jsonl"
for i in 1 2 3 4 5; do printf 'head\trun%s\totherSession\n' "$i"; done >"$v/stale.tsv"
got="$(stale_verdict "$v" 5)" || fail "five Home launches failed the verdict: $got"
[[ "$got" == *"LR-STALE-SNAPSHOT head shown=Home reason=otherSession flash_ms=20.0 flash_ms_max=100.0 drawn=4/5 n=5"* ]] \
  || fail "the verdict line was '$got'"
[[ "$got" != *foreign-head* ]] || fail "the donor was given a verdict: $got"
row run6 pane 2 "" "" >>"$v/runs.jsonl"
got="$(stale_verdict "$v" 5)" && fail "a launch that showed a pane and made a workspace passed: $got"
[[ "$got" == *"LR-FAIL head run6 stale snapshot launch showed pane and made a workspace"* ]] || fail "no LR-FAIL for run6: $got"
[[ "$got" == *"reason=otherSession,unknown"* ]] || fail "run6's unread reason was not unknown: $got"
head -4 "$v/runs.jsonl" >"$v/short" && mv "$v/short" "$v/runs.jsonl"
stale_verdict "$v" 5 >/dev/null && fail "three launches passed a verdict that wants five"

# A put-back that fails is a failure (the step exits 4), and the copy stays for the next run to put back.
DEFAULTS_FAIL_IMPORT=1 defaults_restore "$out" && fail "a failed put-back returned success"

# At exit the account's defaults come back as they were.
defaults_restore "$out"
got="$(defaults read com.example.shared)"
[[ "$got" == "mine=yes" ]] || fail "the account's defaults came back as '$got'"
echo "launch-ready defaults: each side reads only its own, a planted foreign snapshot passes only by name, and the account's come back"
