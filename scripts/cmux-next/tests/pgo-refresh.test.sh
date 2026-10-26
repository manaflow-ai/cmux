#!/usr/bin/env bash
# scripts/cmux-next/pgo/refresh.sh (p08-startup-054) without a build: a sandbox clone with a bare remote, and stubs for
# build-profile.sh, reload.sh, run-scenarios.py, check.py, the upload and gh (the script's test seams). The real
# fetch-profdata.sh and release-env.sh run: the use build gets the profile through them, and the upload is fetched
# back from a file:// public URL. Checks: a changed checkout, a HEAD that is not --ref, a run off the fleet and missing
# credentials are refused before any build; a full run pushes one commit that changes only the pin line and the
# order, and opens one PR; a second run builds, pushes and opens nothing; a failed check publishes nothing; a branch
# with other files is refused, not forced; a base that already pins the profile stops with exit 0.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/pgo-refresh-test.XXXXXX")"
reload_logs=()
cleanup() {
  rm -rf "$work"
  for log in "${reload_logs[@]+"${reload_logs[@]}"}"; do rm -f "$log"; done
}
trap cleanup EXIT
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

# --- the sandbox: a repo with the scripts refresh.sh runs and the committed PGO files, and its bare remote ---------
repo="$work/repo"
mkdir -p "$repo/scripts/cmux-next/pgo" "$repo/scripts/cmux-next/lib" "$repo/Resources/build"
for f in pgo/refresh.sh pgo/fetch-profdata.sh pgo/release-env.sh lib/fleet-only.sh; do
  cp "$root/scripts/cmux-next/$f" "$repo/scripts/cmux-next/$f"
done
for f in cmux-next.order cmux-next.profdata.sha256 cmux-next.pgo.conf; do
  cp "$root/Resources/build/$f" "$repo/Resources/build/$f"
done
printf 'artifacts/\n' >"$repo/.gitignore"
git -C "$repo" init -q -b feat-cmux-next
git -C "$repo" add -A
git -C "$repo" commit -q -m base
git init -q --bare "$work/remote.git"
git -C "$repo" remote add origin "$work/remote.git"
git -C "$repo" push -q origin feat-cmux-next
sha="$(git -C "$repo" rev-parse HEAD)"
short="${sha:0:12}"
reload_logs+=("/tmp/cmux-reload-pgo-use-$short.log")

# --- stubs ----------------------------------------------------------------------------------------------------------
bin="$work/bin"
mkdir -p "$bin"
calls="$work/calls"
: >"$calls"
export STUB_CALLS="$calls"

cat >"$bin/build-profile" <<'SH'
#!/usr/bin/env bash
# Makes the profile build's bundle where build-profile.sh puts it.
echo "build-profile $*" >>"$STUB_CALLS"
tag=$2
mkdir -p "$CMUX_DERIVED_DATA/Build/Products/Release/cmux DEV $tag.app/Contents"
SH

cat >"$bin/reload" <<'SH'
#!/usr/bin/env bash
# reload.sh --tag T --config bench --derived-data D: the bench bundle, a link map per architecture and the reload log
# with the compile flag Package.swift adds from CMUX_PGO_PROFDATA.
echo "reload $* profdata=${CMUX_PGO_PROFDATA:-} xcconfig=${XCODE_XCCONFIG_FILE:-}" >>"$STUB_CALLS"
tag=$2 derived=$6
app="$derived/Build/Products/Release/cmux DEV $tag.app"
mkdir -p "$app/Contents"
python3 -I -c 'import plistlib, sys; plistlib.dump({"CMUXBuildConfiguration": "bench"}, open(sys.argv[1], "wb"))' \
  "$app/Contents/Info.plist"
objects="$derived/Build/Intermediates.noindex/cmux.build/Release/cmux.build"
mkdir -p "$objects"
for arch in arm64 x86_64; do echo "# Path: cmux DEV ($arch)" >"$objects/cmux DEV-LinkMap-normal-$arch.txt"; done
echo "SwiftCompile normal arm64 -module-name CmuxNextApp ${STUB_FLAG:--profile-use=$CMUX_PGO_PROFDATA}" \
  >"/tmp/cmux-reload-$tag.log"
SH

cat >"$bin/runner" <<'SH'
#!/usr/bin/env bash
# run-scenarios.py --stage profile|order with the outputs the stages write.
echo "runner $*" >>"$STUB_CALLS"
stage="" out="" pin=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage) stage=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --profdata-sha256) pin=$2; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$out"
if [[ "$stage" == profile ]]; then
  printf '%s' "${STUB_PROFILE:-profile one}" >"$out/cmux-next.profdata"
  sum="$(sha256sum "$out/cmux-next.profdata" | awk '{ print $1 }')"
  printf '%s  cmux-next.profdata\n' "$sum" >"$out/cmux-next.profdata.sha256"
  printf '# profdata sha256 %s\nlaunchOne\n' "$sum" >"$out/launch-functions.txt"
  echo '{}' >"$out/stage-profile.json"
  echo "PGO-STAGE {\"stage\": \"profile\", \"profdata_sha256\": \"$sum\"}"
else
  sum="$(awk '!/^#/ { print $1; exit }' "$pin")"
  printf '# cmux-next order\n# profdata sha256 %s\n_launchOne\n_faultTwo\n' "$sum" >"$out/cmux-next.order"
  echo '{}' >"$out/stage-order.json"
  echo "PGO-STAGE {\"stage\": \"order\", \"order_symbols\": 2}"
fi
SH

cat >"$bin/check" <<'SH'
#!/usr/bin/env bash
echo "check $*" >>"$STUB_CALLS"
echo "PGO-CHECK {\"passed\": $([[ "${STUB_CHECK_EXIT:-0}" == 0 ]] && echo true || echo false)}"
exit "${STUB_CHECK_EXIT:-0}"
SH

cat >"$bin/upload" <<'SH'
#!/usr/bin/env bash
# The bucket is a folder; the public URL is file:// of it.
echo "upload $2" >>"$STUB_CALLS"
mkdir -p "$STUB_BUCKET/pgo/cmux-next"
cp "$1" "$STUB_BUCKET/pgo/cmux-next/$2.profdata"
SH

cat >"$bin/gh" <<'SH'
#!/usr/bin/env bash
# auth status passes; pr list prints the open PR of the state file; pr create opens one.
echo "gh $*" >>"$STUB_CALLS"
case "$1 $2" in
  "auth status") exit 0 ;;
  "pr list") cat "$STUB_GH_PR" 2>/dev/null || true ;;
  "pr create") echo "https://github.com/example/cmux/pull/1" | tee "$STUB_GH_PR" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$bin"/*

export CMUX_PGO_BUILD_PROFILE="$bin/build-profile" CMUX_PGO_RELOAD="$bin/reload" CMUX_PGO_RUNNER="$bin/runner" \
  CMUX_PGO_CHECK="$bin/check" CMUX_PGO_UPLOAD="$bin/upload" CMUX_PGO_GH="$bin/gh"
export HOME="$work/home" STUB_BUCKET="$work/bucket" STUB_GH_PR="$work/gh-pr"
export CI_CACHE_R2_PUBLIC_URL="file://$work/bucket"
mkdir -p "$HOME"
refresh="$repo/scripts/cmux-next/pgo/refresh.sh"

run() { # NAME ARGS...: runs refresh.sh on the fleet; its exit code in $rc, its output in $work/NAME.out
  local name=$1
  shift
  rc=0
  CMUX_CI_STEP_KEY=test "$refresh" "$@" >"$work/$name.out" 2>&1 || rc=$?
}
count() { grep -c -- "$1" "$calls" || true; }
remote_branch() { git -C "$work/remote.git" rev-parse --verify --quiet "refs/heads/pgo-refresh/$short" || true; }

# --- refused before any build -------------------------------------------------------------------------------------
echo dirty >>"$repo/Resources/build/cmux-next.order"
run dirty
[[ "$rc" == 2 ]] || fail "a changed tracked file exited $rc, not 2"
grep -q 'the checkout has changes' "$work/dirty.out" || fail "no message for a changed checkout"
git -C "$repo" checkout -q -- Resources/build/cmux-next.order
touch "$repo/untracked.txt"
run untracked
[[ "$rc" == 2 ]] || fail "an untracked file exited $rc, not 2"
rm -f "$repo/untracked.txt"
run wrong-ref --ref HEAD~0^{tree}
[[ "$rc" == 2 ]] || fail "a --ref that is no commit exited $rc, not 2"
git -C "$repo" commit -q --allow-empty -m later
run behind --ref "$sha"
[[ "$rc" == 2 ]] || fail "HEAD past --ref exited $rc, not 2"
grep -q "not --ref" "$work/behind.out" || fail "no message for HEAD that is not --ref"
git -C "$repo" reset -q --hard "$sha"
rc=0
env -u CMUX_CI_STEP_KEY GITHUB_ACTIONS=false "$refresh" >"$work/off-fleet.out" 2>&1 || rc=$?
[[ "$rc" == 2 ]] || fail "a run off the fleet exited $rc, not 2"
grep -q 'runs only on the build fleet' "$work/off-fleet.out" || fail "no fleet-only message"
rc=0
CMUX_CI_STEP_KEY=test env -u CMUX_PGO_UPLOAD "$refresh" >"$work/no-creds.out" 2>&1 || rc=$?
[[ "$rc" == 2 ]] || fail "a run without bucket credentials exited $rc, not 2"
grep -q 'CI_CACHE_R2_ENDPOINT is not set' "$work/no-creds.out" || fail "no message for missing credentials"
[[ "$(count 'build-profile')" == 0 ]] || fail "a refused run called build-profile.sh"

# --- a failed check publishes nothing -----------------------------------------------------------------------------
STUB_CHECK_EXIT=1 run check-fails --out "$work/out-failed"
[[ "$rc" == 1 ]] || fail "a failed check exited $rc, not 1"
[[ "$(count '^upload')" == 0 ]] || fail "a failed check uploaded"
[[ -z "$(remote_branch)" ]] || fail "a failed check pushed a branch"
[[ ! -e "$work/out-failed/check.passed" ]] || fail "a failed check was recorded as passed"
# The rerun after the fix resumes: no build, no stage 1, no stage 2 (only the check runs again).
: >"$calls"
run check-resumes --out "$work/out-failed" --no-publish
[[ "$rc" == 0 ]] || { cat "$work/check-resumes.out" >&2; fail "the --no-publish rerun exited $rc"; }
[[ "$(count 'build-profile')" == 0 && "$(count '^reload')" == 0 && "$(count '^runner')" == 0 ]] \
  || fail "the rerun after a failed check built or ran a stage again: $(tr '\n' ';' <"$calls")"
[[ "$(count '^check')" == 1 ]] || fail "the rerun did not run the check again"

# --- the full run -------------------------------------------------------------------------------------------------
: >"$calls"
run full
[[ "$rc" == 0 ]] || { cat "$work/full.out" >&2; fail "the full run exited $rc"; }
out="$repo/artifacts/pgo-refresh/$sha"
profile_sha="$(awk '{ print $1 }' "$out/profile/cmux-next.profdata.sha256")"
[[ "$(count 'build-profile --tag pgo-prof-')" == 1 ]] || fail "no profile build"
grep -q -- "--no-launch" "$calls" || fail "the profile build launched (stage 1 launches)"
grep -q "^reload --tag pgo-use-$short --config bench .*profdata=$out/use/profdata/$profile_sha/cmux-next.profdata" "$calls" \
  || fail "the use build did not get the stage 1 profile through release-env.sh: $(grep '^reload' "$calls")"
grep -q "^runner --stage order .*--link-map $out/use/link-map.txt" "$calls" || fail "stage 2 did not get the kept link map"
grep -q "^runner --stage order .*--profdata-sha256 $out/profile/cmux-next.profdata.sha256" "$calls" \
  || fail "stage 2 was not bound to stage 1's sha256"
grep -q "^check .*--pinned $out/profile/cmux-next.profdata.sha256" "$calls" || fail "check.py did not compare the new pin"
[[ -f "$work/bucket/pgo/cmux-next/$profile_sha.profdata" ]] || fail "the profile was not uploaded under its sha256"
[[ "$(count '^gh pr create')" == 1 ]] || fail "the full run did not open one PR"
head="$(remote_branch)"
[[ -n "$head" ]] || fail "no pgo-refresh/$short branch on the remote"
if [[ -n "$head" ]]; then
  [[ "$(git -C "$work/remote.git" rev-parse "$head^")" == "$sha" ]] || fail "the commit is not on the base tip"
  changed="$(git -C "$work/remote.git" diff --name-only "$sha" "$head" | tr '\n' ' ')"
  [[ "$changed" == "Resources/build/cmux-next.order Resources/build/cmux-next.profdata.sha256 " ]] \
    || fail "the commit changes '$changed', not only the order and the pin"
  pinned="$(git -C "$work/remote.git" show "$head:Resources/build/cmux-next.profdata.sha256")"
  [[ "$(grep -v '^#' <<<"$pinned")" == "$profile_sha  cmux-next.profdata" ]] || fail "the pin line is not the new profile"
  [[ "$(grep -c '^#' <<<"$pinned")" == "$(grep -c '^#' "$repo/Resources/build/cmux-next.profdata.sha256")" ]] \
    || fail "the pin lost its comment lines"
  git -C "$work/remote.git" show "$head:Resources/build/cmux-next.order" | grep -q "^# profdata sha256 $profile_sha$" \
    || fail "the committed order is not bound to the new profile"
fi
[[ -z "$(git -C "$repo" status --porcelain)" ]] || fail "the run changed the checkout"
[[ "$(git -C "$repo" rev-parse HEAD)" == "$sha" ]] || fail "the run moved HEAD"

# --- idempotent: the second run builds, pushes and opens nothing ---------------------------------------------------
: >"$calls"
run again
[[ "$rc" == 0 ]] || { cat "$work/again.out" >&2; fail "the second run exited $rc"; }
[[ "$(count 'build-profile')" == 0 && "$(count '^reload')" == 0 && "$(count '^runner')" == 0 && "$(count '^check')" == 0 ]] \
  || fail "the second run built or ran a stage: $(tr '\n' ';' <"$calls")"
[[ "$(count '^gh pr create')" == 0 ]] || fail "the second run opened another PR"
[[ "$(remote_branch)" == "$head" ]] || fail "the second run pushed again"
grep -q 'already open' "$work/again.out" || fail "the second run did not name the open PR"

# --- a branch with another profile is refused, not forced ----------------------------------------------------------
STUB_PROFILE="profile two" run other-profile --out "$work/out-other"
[[ "$rc" == 1 ]] || fail "a branch with another profile exited $rc, not 1"
grep -q 'holds another profile or order' "$work/other-profile.out" || fail "no message for a branch with other files"
[[ "$(remote_branch)" == "$head" ]] || fail "the branch with another profile was overwritten"

# --- the base already pins it: nothing to publish -----------------------------------------------------------------
git -C "$work/remote.git" update-ref refs/heads/feat-cmux-next "$head"
rm -f "$work/gh-pr"
: >"$calls"
run current
[[ "$rc" == 0 ]] || { cat "$work/current.out" >&2; fail "a current base exited $rc"; }
grep -q 'already pins' "$work/current.out" || fail "no message for a base that already pins the profile"
[[ "$(count '^gh pr')" == 0 && "$(count '^upload')" == 0 ]] || fail "a current base listed, opened or uploaded"

# --- the use build must show -profile-use ---------------------------------------------------------------------------
STUB_FLAG="-O" STUB_PROFILE="profile three" run no-flag --out "$work/out-no-flag" --no-publish
[[ "$rc" == 1 ]] || fail "a use build without -profile-use exited $rc, not 1"
grep -q 'has -profile-use' "$work/no-flag.out" || fail "no message for a use build without the flag"

if (( failures )); then
  echo "pgo-refresh.test.sh: $failures failure(s)" >&2
  exit 1
fi
echo "pgo-refresh.test.sh: ok"
