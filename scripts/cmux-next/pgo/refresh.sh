#!/usr/bin/env bash
# refresh.sh [--ref SHA] [--base BRANCH] [--remote NAME] [--out DIR] [--timeout SECONDS] [--no-publish | --publish-bundle FILE]
#
# The manual refresh of the cmux-next Swift PGO profile and the Release order file (plans/cmux-next/chrome-parity/
# p08-startup.md, section F, task 054; plans/cmux-next/startup-DESIGN.md section 11). The builds run as one fleet
# step at one commit; the fleet step has no bucket credentials, so it stops after the check and returns one file:
#
#   cmux-ci run --class isolated --script scripts/cmux-next/pgo/refresh.sh --ref SHA \
#     --arg=--no-publish --artifact artifacts/pgo-refresh/SHA.tar.gz
#   cmux-ci artifact STEP_ID pgo-refresh-SHA.tar.gz
#   scripts/cmux-next/pgo/refresh.sh --publish-bundle pgo-refresh-SHA.tar.gz     # where gh and the credentials are
#
#   1 profile build  pgo/build-profile.sh --no-launch: the instrumented build of SHA (reload.sh --config profile, 049)
#   2 stage 1        run-scenarios.py --stage profile: the launches, cmux-next.profdata and its sha256 (050)
#   3 use build      reload.sh --config bench with that profile through pgo/release-env.sh, the Release builds' own
#                    PGO path (052), and the companions committed in Resources/build/cmux-next.pgo.conf; its link
#                    map (051) is kept in OUT/use/link-map.txt
#   4 stage 2        run-scenarios.py --stage order on that build: cmux-next.order bound to the profdata sha256 (109)
#   5 check          pgo/check.py on that build: coverage, binding and link map of the new order (053); with
#                    --no-publish the run ends here and writes the bundle artifacts/pgo-refresh/<sha>.tar.gz
#   6 upload         the profile to the bucket at pgo/cmux-next/<sha256>.profdata, the object fetch-profdata.sh reads,
#                    then fetch-profdata.sh fetches it back from the public URL and checks its sha256
#   7 pull request   one commit on REMOTE/BASE that replaces the pin line of Resources/build/cmux-next.profdata.sha256
#                    and Resources/build/cmux-next.order, pushed to pgo-refresh/<sha12>, and a PR into BASE
#
# Chrome refreshes its profile the same way: tools/pgo/generate_profile.py makes it on a chrome_pgo_phase=1 build,
# it is uploaded to the profile bucket by name, and a roll changes only chrome/build/mac-arm.pgo.txt, which
# tools/update_pgo_profiles.py reads to fetch it (docs/pgo.md). The switch (Resources/build/cmux-next.pgo.conf) is
# not changed here: turning PGO on stays its own reviewed commit.
#
# A run that builds refuses a checkout with changes (tracked or untracked): the builds compile the checkout, and
# the PR must say which commit the profile is of. HEAD must be --ref (default HEAD). Publishing needs the commit
# on REMOTE/BASE. --publish-bundle publishes the commit the bundle names, whatever HEAD is, and runs no build.
#
# Idempotent, and a rerun does not need the folder of the run before it (a fleet step's checkout is removed after
# the step). On one host, every stage keeps its outputs in OUT (default artifacts/pgo-refresh/<sha>) and is skipped
# when they are complete. The record that survives is the branch pgo-refresh/<sha12>: a publishing run looks at it
# before any build, and when it is there and is a refresh of SHA whose profile fetches back by its sha256, the run
# only opens or reports its PR: no build, no upload, no fleet. The upload is by content (an existing object is
# kept); the branch is pushed only when it does not exist, never forced; a run whose own checked profile or order
# differs from the branch's is refused; an open PR of the branch is reported, not opened again; a BASE that already
# pins this profile and order stops the run with exit 0.
#
#   --base      the PR's base branch (default feat-cmux-next)
#   --remote    the remote of BASE and of the pushed branch (default origin)
#   --out       the run folder (default artifacts/pgo-refresh/<sha>, ignored by git)
#   --timeout   seconds for one launch of a stage (default 180)
#   --no-publish      stop after the check: no upload, branch or PR; write the bundle
#                     artifacts/pgo-refresh/<sha>.tar.gz (in the checkout, for cmux-ci run --artifact)
#   --publish-bundle  verify a --no-publish bundle and publish it (steps 6 and 7), with no build and no fleet
#
# The bundle holds commit, cmux-next.profdata and its .sha256, cmux-next.order, check.passed and evidence.txt (the
# host and Xcode, the PGO-STAGE lines of both stages and the PGO-CHECK line). The PR body is made from the
# evidence that the branch's commit message carries, so a resumed run writes the same body.
#
# Upload credentials, as scripts/ci/r2-cache.sh save: CI_CACHE_R2_ENDPOINT, CI_CACHE_R2_BUCKET, AWS_ACCESS_KEY_ID,
# AWS_SECRET_ACCESS_KEY; CI_CACHE_R2_PUBLIC_URL (default https://ci-cache.cmux.com) for the fetch back.
#
# Exit codes: 0 the PR is open or BASE is current (or --no-publish finished), 1 a stage failed, a bundle or the
# branch does not verify, 2 usage or a refused precondition (a changed checkout, HEAD is not --ref, not on the fleet,
# no credentials).
#
# Seams (tests only): CMUX_PGO_BUILD_PROFILE replaces pgo/build-profile.sh, CMUX_PGO_RELOAD scripts/reload.sh (as in
# build-profile.sh), CMUX_PGO_RUNNER `python3 pgo/run-scenarios.py`, CMUX_PGO_CHECK `python3 pgo/check.py`,
# CMUX_PGO_UPLOAD the bucket upload (called as `UPLOAD FILE SHA256`), CMUX_PGO_GH gh.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd "$script_dir/../../.." && pwd -P)"
pin_rel=Resources/build/cmux-next.profdata.sha256
order_rel=Resources/build/cmux-next.order
bundle_members=(commit cmux-next.profdata cmux-next.profdata.sha256 cmux-next.order check.passed evidence.txt)

usage() {
  sed -n '2,2p' "${BASH_SOURCE[0]}" | sed 's/^# /usage: /' >&2
  exit 2
}
refuse() { echo "pgo-refresh: $*" >&2; exit 2; }
die() { echo "pgo-refresh: error: $*" >&2; exit 1; }
say() { echo "==> pgo-refresh: $*"; }
git_() { git -C "$root" "$@"; }

ref=""
base=feat-cmux-next
remote=origin
out=""
timeout=180
publish=1
bundle_in=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) [[ $# -ge 2 ]] || usage; ref="$2"; shift 2 ;;
    --base) [[ $# -ge 2 ]] || usage; base="$2"; shift 2 ;;
    --remote) [[ $# -ge 2 ]] || usage; remote="$2"; shift 2 ;;
    --out) [[ $# -ge 2 ]] || usage; out="$2"; shift 2 ;;
    --timeout) [[ $# -ge 2 ]] || usage; timeout="$2"; shift 2 ;;
    --no-publish) publish=0; shift ;;
    --publish-bundle) [[ $# -ge 2 ]] || usage; bundle_in="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "pgo-refresh: unknown argument: $1" >&2; usage ;;
  esac
done
[[ "$timeout" =~ ^[1-9][0-9]*$ ]] || refuse "--timeout takes a positive number of seconds (got '$timeout')"
[[ -z "$bundle_in" ]] || (( publish )) || refuse "--publish-bundle publishes; it does not go with --no-publish"

# --- the commit ---------------------------------------------------------------------------------------------------
if [[ -n "$bundle_in" ]]; then
  [[ -f "$bundle_in" ]] || refuse "--publish-bundle $bundle_in is not a file"
  bundle_in="$(cd "$(dirname "$bundle_in")" && pwd -P)/$(basename "$bundle_in")"
  sha="$(tar -xOzf "$bundle_in" commit 2>/dev/null | head -n 1)" || sha=""
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || refuse "$bundle_in is not a refresh.sh --no-publish bundle (no commit in it)"
  if [[ -n "$ref" ]]; then
    ref_sha="$(git_ rev-parse --verify --quiet "$ref^{commit}")" || refuse "--ref $ref is not a commit here"
    [[ "$ref_sha" == "$sha" ]] || refuse "the bundle is of $sha, not --ref $ref ($ref_sha)"
  fi
else
  changes="$(git_ status --porcelain)"
  if [[ -n "$changes" ]]; then
    printf '%s\n' "$changes" | head -n 20 >&2
    refuse "the checkout has changes; the builds compile it and the PR names its commit, so commit or remove them first"
  fi
  sha="$(git_ rev-parse --verify 'HEAD^{commit}')"
  if [[ -n "$ref" ]]; then
    ref_sha="$(git_ rev-parse --verify --quiet "$ref^{commit}")" || refuse "--ref $ref is not a commit here"
    [[ "$ref_sha" == "$sha" ]] || refuse "HEAD is $sha, not --ref $ref ($ref_sha); run at the ref (cmux-ci run --ref)"
  fi
fi
short="${sha:0:12}"

out="${out:-$root/artifacts/pgo-refresh/$sha}"
mkdir -p "$out"
out="$(cd "$out" && pwd -P)"
if [[ "$out/" == "$root/"* ]] && ! git_ check-ignore -q "$out"; then
  refuse "--out $out is in the checkout and not ignored, so a rerun would refuse the changed checkout"
fi
profile_dir="$out/profile"
use_dir="$out/use"
order_dir="$out/order"
publish_dir="$out/publish"
bundle_rel="artifacts/pgo-refresh/$sha.tar.gz"
branch="pgo-refresh/$short"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}
pin_sha() { # FILE: the sha256 of the first line that is no comment, empty when there is none
  [[ -f "$1" ]] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$1" | head -n 1 | awk '$1 ~ /^[0-9a-f]{64}$/ { print $1 }'
}
order_sha() { # FILE: the `# profdata sha256 <hex>` of the order header (run-scenarios.py --stage order)
  [[ -f "$1" ]] || return 0
  sed -n 's/^#[[:space:]]*profdata sha256[[:space:]]\{1,\}\([0-9a-f]\{64\}\)[[:space:]]*$/\1/p' "$1" | head -n 1
}
plist_value() { # PLIST KEY
  python3 -I -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb")).get(sys.argv[2], ""))' "$1" "$2"
}
run_scenarios() {
  if [[ -n "${CMUX_PGO_RUNNER:-}" ]]; then "$CMUX_PGO_RUNNER" "$@"; else python3 "$script_dir/run-scenarios.py" "$@"; fi
}
run_check() {
  if [[ -n "${CMUX_PGO_CHECK:-}" ]]; then "$CMUX_PGO_CHECK" "$@"; else python3 "$script_dir/check.py" "$@"; fi
}
gh_() { (cd "$root" && "${CMUX_PGO_GH:-gh}" "$@"); }
blob_at() { git_ rev-parse --verify --quiet "$1:$2" || true; }

# --- what is already done -----------------------------------------------------------------------------------------
profile_sha() { # stage 1's sha256 when its outputs are complete and the profdata matches it; empty otherwise
  local pinned
  [[ -s "$profile_dir/cmux-next.profdata" && -s "$profile_dir/launch-functions.txt" \
    && -f "$profile_dir/stage-profile.json" ]] || return 0
  pinned="$(pin_sha "$profile_dir/cmux-next.profdata.sha256")"
  [[ -n "$pinned" && "$(sha256_of "$profile_dir/cmux-next.profdata")" == "$pinned" ]] && printf '%s\n' "$pinned"
  return 0
}
use_done() { # the -profile-use build of this profile, its app and link map
  [[ "$(cat "$use_dir/built" 2>/dev/null)" == "$1" && -d "$(cat "$use_dir/app" 2>/dev/null)" && -s "$use_dir/link-map.txt" ]]
}
order_done() {
  [[ -f "$order_dir/stage-order.json" && "$(order_sha "$order_dir/cmux-next.order")" == "$1" ]]
}
checked() { # DIR PASSED: the profile sha256 that PASSED records check.py passed with DIR/cmux-next.order; else empty
  local passed
  [[ -f "$1/cmux-next.order" ]] || return 0
  passed="$(cat "$2" 2>/dev/null || true)"
  [[ "$passed" == *" $(sha256_of "$1/cmux-next.order")" ]] && printf '%s\n' "${passed%% *}"
  return 0
}
check_done() { # check.py passed on this profile and this order
  [[ -n "$1" && "$(checked "$order_dir" "$out/check.passed")" == "$1" ]]
}

# The result to publish: from the bundle, or from OUT once its check has passed; empty until then.
candidate_sha=""
candidate_order_blob=""
profdata_sha=""
if [[ -n "$bundle_in" ]]; then
  bundle_dir="$out/bundle"
  rm -rf "$bundle_dir"
  mkdir -p "$bundle_dir"
  tar -xzf "$bundle_in" -C "$bundle_dir" "${bundle_members[@]}" \
    || die "$bundle_in does not hold ${bundle_members[*]}"
  for member in "${bundle_members[@]}"; do
    [[ -f "$bundle_dir/$member" && ! -L "$bundle_dir/$member" ]] || die "the bundle's $member is not a file"
  done
  profdata_file="$bundle_dir/cmux-next.profdata"
  candidate_pin="$bundle_dir/cmux-next.profdata.sha256"
  order_file="$bundle_dir/cmux-next.order"
  evidence_file="$bundle_dir/evidence.txt"
  candidate_sha="$(pin_sha "$candidate_pin")"
  [[ -n "$candidate_sha" && "$(sha256_of "$profdata_file")" == "$candidate_sha" ]] \
    || die "the bundle's profile does not match its sha256 file"
  [[ "$(order_sha "$order_file")" == "$candidate_sha" ]] || die "the bundle's order is not bound to its profile"
  [[ "$(checked "$bundle_dir" "$bundle_dir/check.passed")" == "$candidate_sha" ]] \
    || die "the bundle's check.passed is not of its profile and order"
  say "bundle of $sha verified: profile $candidate_sha"
else
  profdata_file="$profile_dir/cmux-next.profdata"
  candidate_pin="$profile_dir/cmux-next.profdata.sha256"
  order_file="$order_dir/cmux-next.order"
  evidence_file="$out/evidence.txt"
  profdata_sha="$(profile_sha)"
  if check_done "$profdata_sha"; then candidate_sha="$profdata_sha"; fi
fi
[[ -z "$candidate_sha" ]] || candidate_order_blob="$(git_ hash-object "$order_file")"

# --- publish preconditions and the branch, before an hour of builds -----------------------------------------------
base_tip=""
branch_head=""
branch_sha=""
if (( publish )); then
  gh_ auth status >/dev/null 2>&1 || refuse "gh is not signed in, so no PR can be opened; sign in, or pass --no-publish"
  git_ var GIT_COMMITTER_IDENT >/dev/null 2>&1 || refuse "git has no committer identity (user.name, user.email)"
  git_ fetch --quiet "$remote" "+refs/heads/$base:refs/remotes/$remote/$base" \
    || refuse "cannot fetch $base from $remote"
  base_tip="$(git_ rev-parse --verify "refs/remotes/$remote/$base^{commit}")"
  git_ cat-file -e "$sha^{commit}" 2>/dev/null || refuse "$sha is not a commit here or on $remote/$base"
  git_ merge-base --is-ancestor "$sha" "$base_tip" \
    || refuse "$sha is not on $remote/$base: a profile of a commit the base does not have would pin code it does not build"
  git_ cat-file -e "$base_tip:$pin_rel" 2>/dev/null \
    || refuse "$remote/$base has no $pin_rel (task 052); there is nothing to refresh"
  mkdir -p "$publish_dir"
  git_ show "$base_tip:$pin_rel" >"$publish_dir/base.sha256"

  # The branch is the run's record off the step: when it is there, only its PR is left.
  branch_head="$(git_ ls-remote --heads "$remote" "refs/heads/$branch" | awk '{ print $1 }')"
  if [[ -n "$branch_head" ]]; then
    git_ fetch --quiet "$remote" "+refs/heads/$branch:refs/remotes/$remote/$branch" || die "cannot fetch $branch"
    parents="$(git_ rev-list --parents -n 1 "$branch_head" | awk '{ print NF - 1 }')"
    [[ "$parents" == 1 ]] || die "$remote/$branch is not one commit on $base; it is no refresh of $short"
    changed="$(git_ diff --name-only "$branch_head^" "$branch_head" | LC_ALL=C sort | tr '\n' ' ')"
    [[ "$changed" == "$order_rel $pin_rel " ]] \
      || die "$remote/$branch changes '$changed', not only the pin and the order; it is no refresh of $short"
    git_ merge-base --is-ancestor "$sha" "$branch_head^" || die "$remote/$branch is not based on $sha"
    git_ log -1 --format=%B "$branch_head" | grep -qF "refresh.sh (p08-startup-054) from $sha:" \
      || die "$remote/$branch does not say it is a refresh of $sha"
    git_ show "$branch_head:$pin_rel" >"$publish_dir/branch.sha256"
    git_ show "$branch_head:$order_rel" >"$publish_dir/branch.order"
    branch_sha="$(pin_sha "$publish_dir/branch.sha256")"
    [[ -n "$branch_sha" && "$(order_sha "$publish_dir/branch.order")" == "$branch_sha" ]] \
      || die "$remote/$branch pins no profile its order is bound to"
    if [[ -n "$candidate_sha" ]] \
      && [[ "$candidate_sha" != "$branch_sha" || "$candidate_order_blob" != "$(blob_at "$branch_head" "$order_rel")" ]]; then
      die "$remote/$branch holds another profile or order ($branch_sha, an earlier refresh of $short); close its PR and delete the branch, or publish that run's bundle"
    fi
    say "$remote/$branch has the profile $branch_sha: only its PR is left"
  elif [[ -z "${CMUX_PGO_UPLOAD:-}" ]]; then
    for name in CI_CACHE_R2_ENDPOINT CI_CACHE_R2_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
      [[ -n "${!name:-}" ]] || refuse "$name is not set, so the profile cannot be uploaded; set the bucket credentials, or pass --no-publish and publish its bundle with --publish-bundle"
    done
  fi
fi

if [[ -z "$branch_head" && -z "$candidate_sha" ]]; then
  # shellcheck source=SCRIPTDIR/../lib/fleet-only.sh
  source "$script_dir/../lib/fleet-only.sh"
  cmux_next_require_fleet pgo/refresh.sh "xcodebuild (reload.sh --config profile and bench) and app launches" \
    "none, a cmux-ci fleet step" \
    "cmux-ci run --class isolated --script scripts/cmux-next/pgo/refresh.sh --ref $sha --arg=--no-publish --artifact $bundle_rel"
fi

# --- 1 to 5: the builds, the stages and the check ------------------------------------------------------------------
derived_root="$HOME/Library/Developer/Xcode/DerivedData"

use_build() {
  local utag="pgo-use-$short" uderived app map config setting
  local -a maps=()
  uderived="$derived_root/cmux-$utag"
  # A new DerivedData: every CmuxNext compile must run with the flag, so the log below proves it reached them.
  rm -rf "$uderived" "$use_dir"
  mkdir -p "$use_dir"
  (
    # The Release builds' PGO path, with this run's profile instead of the pinned one and the committed companions.
    unset CMUX_PGO_COMPANIONS CMUX_PGO_CONF CMUX_PGO_PROFDATA
    export CMUX_NEXT_PGO_USE=1 CMUX_PGO_PIN="$candidate_pin" CMUX_PGO_SOURCE="$profdata_file" \
      CMUX_PGO_CACHE_DIR="$use_dir/profdata"
    # shellcheck source=SCRIPTDIR/release-env.sh
    source "$script_dir/release-env.sh"
    cmux_pgo_release_env || exit 2
    [[ -n "${CMUX_PGO_PROFDATA:-}" ]] || { echo "pgo-refresh: release-env.sh did not take $profdata_file" >&2; exit 1; }
    # The companions' xcodebuild settings (LLVM_LTO for thinlto) go in as lto-ab.sh's variants do: Release only.
    if [[ ${#CMUX_PGO_BUILD_SETTINGS[@]} -gt 0 ]]; then
      for setting in "${CMUX_PGO_BUILD_SETTINGS[@]}"; do
        printf '%s[config=Release] = %s\n' "${setting%%=*}" "${setting#*=}"
      done >"$use_dir/release.xcconfig"
      export XCODE_XCCONFIG_FILE="$use_dir/release.xcconfig"
    fi
    rc=0
    CMUX_DEV_BACKEND_MODE=local "${CMUX_PGO_RELOAD:-$root/scripts/reload.sh}" --tag "$utag" --config bench \
      --derived-data "$uderived" --no-global-cli-links >"$use_dir/reload.out" 2>&1 || rc=$?
    cp "/tmp/cmux-reload-$utag.log" "$use_dir/reload.log" 2>/dev/null || : >"$use_dir/reload.log"
    if (( rc != 0 )); then
      echo "pgo-refresh: reload.sh exited $rc; see $use_dir/reload.out and $use_dir/reload.log" >&2
      exit 1
    fi
    if ! grep -qF -- "-profile-use=$CMUX_PGO_PROFDATA" "$use_dir/reload.log"; then
      echo "pgo-refresh: no compile in $use_dir/reload.log has -profile-use=$CMUX_PGO_PROFDATA" >&2
      exit 1
    fi
  ) || die "the -profile-use build failed"

  app="$uderived/Build/Products/Release/cmux DEV $utag.app"
  [[ -d "$app" ]] || die "no bench build at $app"
  config="$(plist_value "$app/Contents/Info.plist" CMUXBuildConfiguration)"
  [[ "$config" == bench ]] || die "$app was built with --config '$config', not bench"
  # The cmux target writes one map per architecture (LD_GENERATE_MAP_FILE, 051); the launches run this host's.
  while IFS= read -r -d '' map; do maps+=("$map"); done < <(
    find "$uderived/Build/Intermediates.noindex" -path '*/Release/*' -name "*-LinkMap-normal-$(uname -m).txt" -print0 2>/dev/null
  )
  [[ ${#maps[@]} -eq 1 ]] || die "expected one $(uname -m) link map of the Release link in $uderived, found ${#maps[@]}"
  cp "${maps[0]}" "$use_dir/link-map.txt"
  printf '%s\n' "$app" >"$use_dir/app"
  printf '%s\n' "$profdata_sha" >"$use_dir/built"
}

write_evidence() { # the lines the bundle, the commit message and so the PR body carry
  local stage_profile stage_order check_line made_on
  stage_profile="$(grep -h '^PGO-STAGE ' "$out/stage-profile.log" 2>/dev/null | tail -n 1 || true)"
  stage_order="$(grep -h '^PGO-STAGE ' "$out/stage-order.log" 2>/dev/null | tail -n 1 || true)"
  check_line="$(grep -h '^PGO-CHECK ' "$out/check.log" 2>/dev/null | tail -n 1 || true)"
  made_on="$(head -n 1 "$out/made-on" 2>/dev/null || true)"
  {
    printf 'Made-on: %s\n' "${made_on:-a host the run folder does not name}"
    printf '%s\n' "${stage_profile:-PGO-STAGE profile (no line)}" "${stage_order:-PGO-STAGE order (no line)}" \
      "${check_line:-PGO-CHECK (no line)}"
  } >"$evidence_file"
}

if [[ -z "$branch_head" && -z "$bundle_in" ]]; then
  if [[ -z "$profdata_sha" ]]; then
    ptag="pgo-prof-$short"
    pderived="$derived_root/cmux-$ptag"
    papp="$pderived/Build/Products/Release/cmux DEV $ptag.app"
    say "1/7 profile build of $sha (tag $ptag)"
    printf '%s, %s\n' "$(scutil --get LocalHostName 2>/dev/null || hostname -s)" \
      "$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/ *$//' || true)" >"$out/made-on"
    CMUX_DERIVED_DATA="$pderived" "${CMUX_PGO_BUILD_PROFILE:-$script_dir/build-profile.sh}" --tag "$ptag" --no-launch \
      || die "the profile build failed"
    say "2/7 stage 1: the scenarios on $papp"
    rm -rf "$profile_dir"
    run_scenarios --stage profile --app "$papp" --out "$profile_dir" --timeout "$timeout" \
      | tee "$out/stage-profile.log" || die "stage 1 failed; see $out/stage-profile.log"
    profdata_sha="$(profile_sha)"
    [[ -n "$profdata_sha" ]] || die "stage 1 left no complete profile in $profile_dir"
  else
    say "1-2/7 kept: stage 1's profile $profdata_sha"
  fi

  if ! check_done "$profdata_sha"; then
    if use_done "$profdata_sha"; then
      say "3/7 kept: the -profile-use build $(cat "$use_dir/app")"
    else
      say "3/7 -profile-use build of $sha with $profdata_sha"
      use_build
    fi
    use_app="$(cat "$use_dir/app")"
    if order_done "$profdata_sha"; then
      say "4/7 kept: stage 2's order"
    else
      say "4/7 stage 2: the order on $use_app"
      rm -rf "$order_dir"
      run_scenarios --stage order --app "$use_app" --link-map "$use_dir/link-map.txt" --profile-dir "$profile_dir" \
        --profdata-sha256 "$candidate_pin" --out "$order_dir" --timeout "$timeout" \
        | tee "$out/stage-order.log" || die "stage 2 failed; see $out/stage-order.log"
      order_done "$profdata_sha" || die "stage 2 left no order bound to $profdata_sha in $order_dir"
    fi
    say "5/7 check.py on $use_app"
    run_check --app "$use_app" --order "$order_file" --link-map "$use_dir/link-map.txt" \
      --profdata "$profdata_file" --pinned "$candidate_pin" --json "$out/check.json" \
      | tee "$out/check.log" || die "check.py refused the new order; see $out/check.log"
    printf '%s %s\n' "$profdata_sha" "$(sha256_of "$order_file")" >"$out/check.passed"
  else
    say "3-5/7 kept: the order and its passed check"
  fi
  candidate_sha="$profdata_sha"
  write_evidence
fi

if (( ! publish )); then
  # One file the fleet step can return: cmux-ci run --artifact takes one file by its path in the checkout.
  bundle="$root/$bundle_rel"
  staging="$out/bundle-staging"
  rm -rf "$staging"
  mkdir -p "$staging" "$(dirname "$bundle")"
  printf '%s\n' "$sha" >"$staging/commit"
  cp "$profdata_file" "$candidate_pin" "$order_file" "$out/check.passed" "$evidence_file" "$staging/"
  tar -czf "$bundle.partial" -C "$staging" "${bundle_members[@]}"
  mv -f "$bundle.partial" "$bundle"
  rm -rf "$staging"
  say "done without publishing: $profdata_file and $order_file in $out"
  say "bundle: $bundle_rel (return it with cmux-ci run --artifact $bundle_rel)"
  say "publish with: scripts/cmux-next/pgo/refresh.sh --publish-bundle FILE"
  exit 0
fi

# --- 6 and 7: upload and pull request -----------------------------------------------------------------------------
fetch_back() { # PIN: the profile it names fetches from the public URL and matches its sha256
  rm -rf "$publish_dir/fetched"
  env -u CMUX_PGO_SOURCE "$script_dir/fetch-profdata.sh" --pin "$1" --cache "$publish_dir/fetched" >/dev/null \
    || die "the uploaded profile does not fetch back by its sha256 from ${CI_CACHE_R2_PUBLIC_URL:-https://ci-cache.cmux.com}"
}
base_is_current() { # PIN_SHA ORDER_BLOB
  [[ "$(pin_sha "$publish_dir/base.sha256")" == "$1" && "$(blob_at "$base_tip" "$order_rel")" == "$2" ]]
}

if [[ -n "$branch_head" ]]; then
  if base_is_current "$branch_sha" "$(blob_at "$branch_head" "$order_rel")"; then
    say "$remote/$base already pins $branch_sha with this order; nothing to publish"
    exit 0
  fi
  say "6/7 kept: the upload; fetching $branch_sha back"
  fetch_back "$publish_dir/branch.sha256"
  say "7/7 kept: $remote/$branch"
else
  {
    # The pin keeps the base's comment lines; only its one profile line changes.
    grep -E '^[[:space:]]*(#|$)' "$publish_dir/base.sha256" || true
    printf '%s  cmux-next.profdata\n' "$candidate_sha"
  } >"$publish_dir/cmux-next.profdata.sha256"
  pin_blob="$(git_ hash-object -w "$publish_dir/cmux-next.profdata.sha256")"
  order_blob="$(git_ hash-object -w "$order_file")"
  if base_is_current "$candidate_sha" "$order_blob"; then
    say "$remote/$base already pins $candidate_sha with this order; nothing to publish"
    exit 0
  fi

  s3_request() { # curl ARGS...: prints the HTTP status
    printf 'user = "%s:%s"\n' "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" \
      | curl --config - --silent --show-error --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 1800 \
        --aws-sigv4 "aws:amz:auto:s3" -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" \
        -o /dev/null -w '%{http_code}' "$@"
  }
  upload_profile() { # FILE SHA256: the object is named by its content, so one that exists is the same file
    local url status
    if [[ -n "${CMUX_PGO_UPLOAD:-}" ]]; then
      "$CMUX_PGO_UPLOAD" "$1" "$2"
      return
    fi
    url="${CI_CACHE_R2_ENDPOINT%/}/$CI_CACHE_R2_BUCKET/pgo/cmux-next/$2.profdata"
    status="$(s3_request --head "$url")" || status=000
    case "$status" in
      200) say "the bucket already has pgo/cmux-next/$2.profdata"; return 0 ;;
      404) ;;
      *) echo "pgo-refresh: HEAD $url answered HTTP $status" >&2; return 1 ;;
    esac
    status="$(s3_request -H 'If-None-Match: *' -H 'content-type: application/octet-stream' -T "$1" "$url")" || status=000
    # 412: another run uploaded the same name, so the same content, in between.
    [[ "$status" == 200 || "$status" == 412 ]] || { echo "pgo-refresh: PUT $url answered HTTP $status" >&2; return 1; }
  }

  say "6/7 upload of $candidate_sha"
  upload_profile "$profdata_file" "$candidate_sha" || die "the upload failed"
  fetch_back "$candidate_pin"

  say "7/7 branch $branch and the PR into $base"
  index="$publish_dir/index"
  rm -f "$index"
  GIT_INDEX_FILE="$index" git_ read-tree "$base_tip"
  GIT_INDEX_FILE="$index" git_ update-index --cacheinfo "100644,$pin_blob,$pin_rel" \
    --cacheinfo "100644,$order_blob,$order_rel"
  tree="$(GIT_INDEX_FILE="$index" git_ write-tree)"
  {
    printf 'perf(startup): refresh the cmux-next PGO profile and order file at %s\n\n' "$short"
    printf 'Made by scripts/cmux-next/pgo/refresh.sh (p08-startup-054) from %s:\n' "$sha"
    printf 'the profile %s (pgo/cmux-next/%s.profdata in the bucket)\n' "$candidate_sha" "$candidate_sha"
    printf 'and the order of its -profile-use bench build, checked by pgo/check.py.\n\n'
    cat "$evidence_file"
  } >"$publish_dir/commit-message.txt"
  commit="$(git_ commit-tree "$tree" -p "$base_tip" -F "$publish_dir/commit-message.txt")"
  # A new branch only: one that another run pushed in between makes this push fail; it is never overwritten.
  git_ push "$remote" "$commit:refs/heads/$branch" || die "cannot push $branch to $remote"
  branch_head="$commit"
  branch_sha="$candidate_sha"
fi

pr_url="$(gh_ pr list --head "$branch" --base "$base" --state open --json url --jq '.[0].url // empty')" \
  || die "gh cannot list the PRs of $branch"
if [[ -n "$pr_url" ]]; then
  say "the PR is already open: $pr_url"
  exit 0
fi

# The body comes from the branch's commit, so a run that resumes from the branch writes the same one.
message="$(git_ log -1 --format=%B "$branch_head")"
made_on="$(sed -n 's/^Made-on: //p' <<<"$message" | head -n 1)"
evidence="$(grep -E '^PGO-(STAGE|CHECK) ' <<<"$message" || true)"
cat >"$publish_dir/pr.md" <<EOF
Refreshes the cmux-next Swift PGO profile and the Release order file from $sha.

\`$pin_rel\` now pins \`$branch_sha\`, uploaded to \`pgo/cmux-next/$branch_sha.profdata\`. \`$order_rel\` is
stage 2's order from the \`-profile-use\` bench build of that profile, with the companions committed in
\`Resources/build/cmux-next.pgo.conf\`. The switch in that file is unchanged.

Made by \`scripts/cmux-next/pgo/refresh.sh\` on ${made_on:-a host the commit does not name}.

## Changelog

none

### Observed / Not run

Observed, in the run folder on that host:

\`\`\`
${evidence:-PGO-STAGE (no lines in the commit message)}
\`\`\`

Not run: check.py's launch-window check, which needs a Release link with this order and a fresh launch profile
(the first Release build after this merges); the cold-launch A/B.
EOF
pr_url="$(gh_ pr create --base "$base" --head "$branch" \
  --title "perf(startup): refresh the cmux-next PGO profile and order file at $short" \
  --body-file "$publish_dir/pr.md")" || die "gh cannot open the PR of $branch"
say "opened $pr_url"
