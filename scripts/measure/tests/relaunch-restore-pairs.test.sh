#!/usr/bin/env bash
# relaunch-restore.sh base=SHA head=SHA: both commits build (tags l5b and l5h) and run as interleaved pairs on one
# host, base then head each round, one relaunch per check, the 1-minute load read before each; L5-PAIR rows and an
# L5-PAIRS summary (relaunch-restore-pairs.py) come out. A stand-in repo: commit A's check reports slower rounds than
# commit B's; the checkout (the driver) sits at B. Bad arguments exit 2 before anything builds, and a relaunch that
# did not restore fails the step while a round over the budget does not.
set -euo pipefail

# shellcheck source=scripts/cmux-next/tests/lib/git-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../cmux-next/tests/lib/git-fixture.sh"  # drops inherited GIT_DIR/GIT_CONFIG redirects; turns off background maintenance
measure="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The physical path: macOS's mktemp answers /var/folders/..., and the scripts name /private/var/... (pwd -P).
root="$(cd "$(mktemp -d)" && pwd -P)"
git_fixture_trap_exit 'rm -rf "$root"'
repo="$root/repo"
mkdir -p "$repo/scripts/measure" "$repo/scripts/ci" "$repo/scripts/cmux-next" "$root/bin"
git_fixture_init "$repo"
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
cp "$measure/relaunch-restore.sh" "$measure/app-at-commit.sh" "$measure/relaunch-restore-pairs.py" "$repo/scripts/measure/"
for tool in sw_vers launchctl; do
  printf '#!/usr/bin/env bash\necho stub\n' >"$root/bin/$tool"
  chmod +x "$root/bin/$tool"
done
# vm.loadavg as macOS prints it; anything else as the host probe reads it.
cat >"$root/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "-n vm.loadavg" ]]; then echo "{ 1.50 1.20 1.00 }"; else echo stub; fi
EOF
chmod +x "$root/bin/sysctl"
export PATH="$root/bin:$PATH"
fail() { echo "relaunch-restore-pairs: $*" >&2; exit 1; }

side() { # side NAME QUIT_MS: a commit whose reload.sh makes NAME.app and whose check reports QUIT_MS per relaunch
  cat >"$repo/scripts/reload.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$root/$1.app"
echo "\$*" >"$root/$1.reload-args"
echo "App path:"
echo "  $root/$1.app"
EOF
  chmod +x "$repo/scripts/reload.sh"
  # The check run is the driver's (the checkout's), so its numbers follow the app it is given.
  cat >"$repo/scripts/ci/relaunch_restore_check.py" <<'EOF'
import json, os, sys
args = sys.argv[1:]
app = args[args.index("--app") + 1]
root = os.path.dirname(app)
with open(os.path.join(root, "calls"), "a") as fh:
    fh.write(" ".join(args) + "\n")
broken = os.path.exists(os.path.join(root, "broken")) and app.endswith("/B.app")
quit_ms = None if broken else (3000 if app.endswith("/A.app") else 2000)
row = {"round": 1, "front": "chat", "quit_to_usable_ms": quit_ms,
       "launch_to_usable_ms": None if broken else quit_ms - 400, "relaunch_ms": 300 if app.endswith("/A.app") else 250}
print("L5-ROUND " + json.dumps(row))
print("L5 " + json.dumps({"verdict": "fail" if broken else "pass"}))
sys.exit(1 if broken else 0)
EOF
  printf '' >"$repo/scripts/cmux-next/tag_teardown.py"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$1"
}
side A
a="$(git -C "$repo" rev-parse HEAD)"
side B
b="$(git -C "$repo" rev-parse HEAD)"
reset() { rm -rf "$root"/*.app "$root"/*.reload-args "$root/calls" "$root/log" "$root/broken"; }

# Bad arguments: exit 2, nothing built.
for args in "dmg=build base=$a" "dmg=build head=$b" "base=$a head=$b" "dmg=build base=deadbeef head=$b" \
  "dmg=build base=$a head=$b build=$a" "dmg=build base=$a head=$b rounds=0" "dmg=build base=$a head=$b rounds=x"; do
  reset
  status=0
  # shellcheck disable=SC2086 # each case is a word list
  (cd "$repo" && bash scripts/measure/relaunch-restore.sh $args) >"$root/log" 2>&1 || status=$?
  [[ "$status" == 2 ]] || fail "$args: exit $status, want 2: $(cat "$root/log")"
  [[ ! -e "$root/A.app" && ! -e "$root/B.app" && ! -e "$root/calls" ]] || fail "$args: built or ran"
done

# base=A head=B, 3 pairs: both build with their own tags; the check alternates A, B, A, B, A, B.
reset
(cd "$repo" && bash scripts/measure/relaunch-restore.sh dmg=build "base=$a" "head=$b" rounds=3 fronts=chat) \
  >"$root/log" 2>&1 || fail "pairs: $(cat "$root/log")"
grep -q "^L5 pairs base $a head $b config bench rounds 3\$" "$root/log" || fail "pairs: no 'L5 pairs' line: $(cat "$root/log")"
[[ "$(cat "$root/A.reload-args")" == "--tag l5b --derived-data $repo/.build/DerivedData/cmux-measure-at --no-global-cli-links --config bench" ]] \
  || fail "pairs: base reload.sh got '$(cat "$root/A.reload-args")'"
[[ "$(cat "$root/B.reload-args")" == "--tag l5h --derived-data $repo/.build/DerivedData/cmux-measure-at --no-global-cli-links --config bench" ]] \
  || fail "pairs: head reload.sh got '$(cat "$root/B.reload-args")'"
[[ "$(grep -o -- '--app [^ ]*' "$root/calls" | sed 's#.*/##' | tr '\n' ' ')" == "A.app B.app A.app B.app A.app B.app " ]] \
  || fail "pairs: not interleaved: $(cat "$root/calls")"
grep -q -- "--fronts chat --rounds 1\$" "$root/calls" || fail "pairs: each check is not one round: $(cat "$root/calls")"
[[ "$(grep -c '^L5-PAIR base [123] 1.50 ' "$root/log")" == 3 && "$(grep -c '^L5-PAIR head [123] 1.50 ' "$root/log")" == 3 ]] \
  || fail "pairs: want 3 L5-PAIR rows per side with the load: $(cat "$root/log")"
grep -q '^L5-PAIRS quit_to_usable_ms: base 3000 head 2000 diff -1000 head faster 3/3$' "$root/log" \
  || fail "pairs: summary: $(grep '^L5-PAIRS' "$root/log")"
grep -q '^L5-PAIRS relaunch_ms: base 300 head 250 diff -50 head faster 3/3$' "$root/log" || fail "pairs: relaunch_ms summary"
grep -q '"max_load_1m": 1.5' "$root/log" || fail "pairs: no max load"

# A relaunch that did not restore fails the step (a round over the budget, A's 3000 ms at the default 3000, does not).
reset
touch "$root/broken"
status=0
(cd "$repo" && bash scripts/measure/relaunch-restore.sh dmg=build "base=$a" "head=$b" rounds=2) >"$root/log" 2>&1 || status=$?
[[ "$status" == 1 ]] || fail "broken head: exit $status, want 1: $(cat "$root/log")"
grep -q '"head round 1: did not restore"' "$root/log" || fail "broken head: problem not named: $(grep '^L5-PAIRS' "$root/log")"
echo "relaunch-restore-pairs: base=SHA head=SHA builds both, interleaves one-relaunch checks with the load, summarizes"
