#!/usr/bin/env bash
# relaunch-restore.sh build=SHA and instant-new-surfaces.sh --build=SHA build the app at another commit (a pull
# request's head or base) with that commit's own reload.sh, while the driver stays the checkout's: the controller runs
# a measure script only at a landed commit. A stand-in repo: commit A's reload.sh and drivers print "A", commit B's
# "B"; the checkout sits at B. A bad sha is refused with exit 2 before anything builds, and with no build= each
# script builds its own checkout as before.
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
cp "$measure/relaunch-restore.sh" "$measure/instant-new-surfaces.sh" "$measure/app-at-commit.sh" \
  "$measure/require-chromium.sh" "$repo/scripts/measure/"
# The host probes relaunch-restore.sh prints first (macOS tools).
for tool in sysctl sw_vers launchctl; do
  printf '#!/usr/bin/env bash\necho stub\n' >"$root/bin/$tool"
  chmod +x "$root/bin/$tool"
done
export PATH="$root/bin:$PATH"
fail() { echo "measure-build-sha: $*" >&2; exit 1; }

side() { # side NAME: a commit whose reload.sh makes the app NAME.app and whose drivers record "NAME args"
  cat >"$repo/scripts/reload.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$root/$1.app"
echo "\$*" >"$root/$1.reload-args"
echo "App path:"
echo "  $root/$1.app"
EOF
  chmod +x "$repo/scripts/reload.sh"
  for driver in ci/relaunch_restore_check.py cmux-next/instant-new-surfaces-bench.py; do
    cat >"$repo/scripts/$driver" <<EOF
import sys
open("$root/driver", "w").write("$1 " + " ".join(sys.argv[1:]))
EOF
  done
  printf '' >"$repo/scripts/cmux-next/tag_teardown.py"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$1"
}
side A
a="$(git -C "$repo" rev-parse HEAD)"
side B
b="$(git -C "$repo" rev-parse HEAD)"
# The checkout's own build finds its submodules and GhosttyKit in place (a step fetches them).
mkdir -p "$repo/ghostty/.git" "$repo/ghostty-next/.git" "$repo/GhosttyKit.xcframework"
touch "$repo/GhosttyKit.xcframework/Info.plist"
reset() { rm -rf "$root"/*.app "$root"/*.reload-args "$root/driver" "$root/log"; }

# Bad shas: exit 2, nothing built, no driver run.
for script in relaunch-restore.sh instant-new-surfaces.sh; do
  for bad in deadbeef "${a^^}" "${a}0" "g${a:1}"; do
    reset
    if [[ "$script" == relaunch-restore.sh ]]; then args=(dmg=build "build=$bad"); else args=(--runs=2 "--build=$bad"); fi
    status=0
    (cd "$repo" && bash "scripts/measure/$script" "${args[@]}") >"$root/log" 2>&1 || status=$?
    [[ "$status" == 2 ]] || fail "$script ${args[*]}: exit $status, want 2: $(cat "$root/log")"
    [[ ! -e "$root/driver" && ! -e "$root/A.app" && ! -e "$root/B.app" ]] || fail "$script ${args[*]}: built or ran"
  done
done
# build=SHA without dmg=build is refused too (a nightly or a URL is not built).
reset
status=0
(cd "$repo" && bash scripts/measure/relaunch-restore.sh "build=$a") >"$root/log" 2>&1 || status=$?
[[ "$status" == 2 ]] || fail "relaunch-restore.sh build= without dmg=build: exit $status, want 2"

# relaunch-restore.sh default dmg=build: the checkout (B) builds, as before.
reset
(cd "$repo" && bash scripts/measure/relaunch-restore.sh dmg=build rounds=2) >"$root/log" 2>&1 || fail "default build: $(cat "$root/log")"
grep -q "^L5 build $b config bench\$" "$root/log" || fail "default build: no 'L5 build $b' line: $(cat "$root/log")"
[[ "$(cat "$root/B.reload-args")" == "--tag l5relaunch --no-global-cli-links --config bench" ]] \
  || fail "default build: reload.sh got '$(cat "$root/B.reload-args")'"
[[ "$(cat "$root/driver")" == "B --app $root/B.app --out $repo/.build/relaunch-restore/run --rounds 2" ]] \
  || fail "default build: driver ran as '$(cat "$root/driver")'"
[[ ! -e "$root/A.app" ]] || fail "default build: built commit A"

# relaunch-restore.sh build=A: A's reload.sh builds, B's check drives it.
reset
(cd "$repo" && bash scripts/measure/relaunch-restore.sh dmg=build "build=$a" config=Release) >"$root/log" 2>&1 \
  || fail "build=A: $(cat "$root/log")"
grep -q "^L5 build $a config Release\$" "$root/log" || fail "build=A: no 'L5 build $a' line: $(cat "$root/log")"
grep -q "^L5 driver $b\$" "$root/log" || fail "build=A: no 'L5 driver $b' line"
[[ "$(cat "$root/A.reload-args")" == "--tag l5relaunch --derived-data $repo/.build/DerivedData/cmux-measure-at --no-global-cli-links --release" ]] \
  || fail "build=A: reload.sh got '$(cat "$root/A.reload-args")'"
[[ "$(cat "$root/driver")" == "B --app $root/A.app --out $repo/.build/relaunch-restore/run" ]] \
  || fail "build=A: driver ran as '$(cat "$root/driver")'"
[[ ! -e "$root/B.app" ]] || fail "build=A: built the checkout too"
tar -tzf "$repo/.build/relaunch-restore/report.tgz" | grep -q 'scripts/reload.sh' && fail "build=A: report.tgz holds A's tree"

# instant-new-surfaces.sh default: the checkout (B) builds; every argument but --config goes to the bench.
reset
(cd "$repo" && bash scripts/measure/instant-new-surfaces.sh --runs=2 --config=bench) >"$root/log" 2>&1 \
  || fail "instant default: $(cat "$root/log")"
grep -q "^instant-new-surfaces: build $b\$" "$root/log" || fail "instant default: no built-commit line"
[[ "$(cat "$root/B.reload-args")" == "--tag instantnew --config bench" ]] || fail "instant default: reload.sh got '$(cat "$root/B.reload-args")'"
[[ "$(cat "$root/driver")" == "B --tag instantnew --app $root/B.app --out "*" --json artifacts/instant-new-surfaces.json --page-engine=cef --runs=2" ]] \
  || fail "instant default: bench ran as '$(cat "$root/driver")'"

# instant-new-surfaces.sh --build=A (and --build-at=A): A's reload.sh builds, B's bench runs, --build is not passed on.
for flag in --build --build-at; do
  reset
  (cd "$repo" && bash scripts/measure/instant-new-surfaces.sh --runs=2 "$flag=$a") >"$root/log" 2>&1 \
    || fail "instant $flag=A: $(cat "$root/log")"
  grep -q "^instant-new-surfaces: build $a (bench at $b)\$" "$root/log" || fail "instant $flag=A: no built-commit line"
  [[ "$(cat "$root/A.reload-args")" == "--tag instantnew --derived-data $repo/.build/DerivedData/cmux-measure-at" ]] \
    || fail "instant $flag=A: reload.sh got '$(cat "$root/A.reload-args")'"
  [[ "$(cat "$root/driver")" == "B --tag instantnew --app $root/A.app --out "*" --json artifacts/instant-new-surfaces.json --page-engine=cef --runs=2" ]] \
    || fail "instant $flag=A: bench ran as '$(cat "$root/driver")'"
  [[ ! -e "$root/B.app" ]] || fail "instant $flag=A: built the checkout too"
done
echo "measure-build-sha: build=SHA builds that commit with the landed driver; bad shas exit 2; defaults unchanged"
