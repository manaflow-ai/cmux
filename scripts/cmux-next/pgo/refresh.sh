#!/usr/bin/env bash
# refresh.sh [--ref SHA] [--base BRANCH] [--remote NAME] [--out DIR] [--timeout SECONDS] [--no-publish]
#
# The manual refresh of the cmux-next Swift PGO profile and the Release order file (plans/cmux-next/chrome-parity/
# p08-startup.md, section F, task 054; plans/cmux-next/startup-DESIGN.md section 11). One command at one commit:
#
#   cmux-ci run --class isolated --script scripts/cmux-next/pgo/refresh.sh --ref SHA
#
#   1 profile build  pgo/build-profile.sh --no-launch: the instrumented build of SHA (reload.sh --config profile, 049)
#   2 stage 1        run-scenarios.py --stage profile: the launches, cmux-next.profdata and its sha256 (050)
#   3 use build      reload.sh --config bench with that profile through pgo/release-env.sh, the Release builds' own
#                    PGO path (052), and the companions committed in Resources/build/cmux-next.pgo.conf; its link
#                    map (051) is kept in OUT/use/link-map.txt
#   4 stage 2        run-scenarios.py --stage order on that build: cmux-next.order bound to the profdata sha256 (109)
#   5 check          pgo/check.py on that build: coverage, binding and link map of the new order (053)
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
# It refuses a checkout with changes (tracked or untracked): the builds compile the checkout, and the PR must say
# which commit the profile is of. HEAD must be --ref (default HEAD) and an ancestor of REMOTE/BASE.
#
# Idempotent. Every stage keeps its outputs in OUT (default artifacts/pgo-refresh/<sha>) and is skipped when they
# are complete, so a rerun resumes after a failed or cut-off step. The upload is by content (an existing object is
# kept); the branch is pushed only when it does not exist, never forced, and refused when it holds other files; an
# open PR of the branch is reported, not opened again; a BASE that already pins this profile and order stops the
# run with exit 0. The builds and launches run only as a fleet step; when only the upload and the PR are left
# (after --no-publish), a rerun with the same --out needs no fleet: copy OUT where gh and the bucket credentials are.
#
#   --base      the PR's base branch (default feat-cmux-next)
#   --remote    the remote of BASE and of the pushed branch (default origin)
#   --out       the run folder (default artifacts/pgo-refresh/<sha>, ignored by git)
#   --timeout   seconds for one launch of a stage (default 180)
#   --no-publish  stop after the check: no upload, branch or PR
#
# Upload credentials, as scripts/ci/r2-cache.sh save: CI_CACHE_R2_ENDPOINT, CI_CACHE_R2_BUCKET, AWS_ACCESS_KEY_ID,
# AWS_SECRET_ACCESS_KEY; CI_CACHE_R2_PUBLIC_URL (default https://ci-cache.cmux.com) for the fetch back.
#
# Exit codes: 0 the PR is open or BASE is current (or --no-publish finished), 1 a stage failed, 2 usage or a refused
# precondition (a changed checkout, HEAD is not --ref, not on the fleet, no credentials).
#
# Seams (tests only): CMUX_PGO_BUILD_PROFILE replaces pgo/build-profile.sh, CMUX_PGO_RELOAD scripts/reload.sh (as in
# build-profile.sh), CMUX_PGO_RUNNER `python3 pgo/run-scenarios.py`, CMUX_PGO_CHECK `python3 pgo/check.py`,
# CMUX_PGO_UPLOAD the bucket upload (called as `UPLOAD FILE SHA256`), CMUX_PGO_GH gh.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd "$script_dir/../../.." && pwd -P)"
pin_rel=Resources/build/cmux-next.profdata.sha256
order_rel=Resources/build/cmux-next.order

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
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) [[ $# -ge 2 ]] || usage; ref="$2"; shift 2 ;;
    --base) [[ $# -ge 2 ]] || usage; base="$2"; shift 2 ;;
    --remote) [[ $# -ge 2 ]] || usage; remote="$2"; shift 2 ;;
    --out) [[ $# -ge 2 ]] || usage; out="$2"; shift 2 ;;
    --timeout) [[ $# -ge 2 ]] || usage; timeout="$2"; shift 2 ;;
    --no-publish) publish=0; shift ;;
    -h|--help) usage ;;
    *) echo "pgo-refresh: unknown argument: $1" >&2; usage ;;
  esac
done
[[ "$timeout" =~ ^[1-9][0-9]*$ ]] || refuse "--timeout takes a positive number of seconds (got '$timeout')"

# --- the commit ---------------------------------------------------------------------------------------------------
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
check_done() { # check.py passed on this profile and this order
  [[ -f "$order_dir/cmux-next.order" && "$(cat "$out/check.passed" 2>/dev/null)" == "$1 $(sha256_of "$order_dir/cmux-next.order")" ]]
}

profdata_sha="$(profile_sha)"
if [[ -z "$profdata_sha" ]] || ! check_done "$profdata_sha"; then
  # shellcheck source=SCRIPTDIR/../lib/fleet-only.sh
  source "$script_dir/../lib/fleet-only.sh"
  cmux_next_require_fleet pgo/refresh.sh "xcodebuild (reload.sh --config profile and bench) and app launches" \
    "none, a cmux-ci fleet step" "cmux-ci run --class isolated --script scripts/cmux-next/pgo/refresh.sh --ref $sha"
fi

# --- publish preconditions, before an hour of builds --------------------------------------------------------------
base_tip=""
if (( publish )); then
  if [[ -z "${CMUX_PGO_UPLOAD:-}" ]]; then
    for name in CI_CACHE_R2_ENDPOINT CI_CACHE_R2_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
      [[ -n "${!name:-}" ]] || refuse "$name is not set, so the profile cannot be uploaded; set the bucket credentials, or pass --no-publish and publish later with the same --out"
    done
  fi
  gh_ auth status >/dev/null 2>&1 || refuse "gh is not signed in, so no PR can be opened; sign in, or pass --no-publish"
  git_ var GIT_COMMITTER_IDENT >/dev/null 2>&1 || refuse "git has no committer identity (user.name, user.email)"
  git_ fetch --quiet "$remote" "+refs/heads/$base:refs/remotes/$remote/$base" \
    || refuse "cannot fetch $base from $remote"
  base_tip="$(git_ rev-parse --verify "refs/remotes/$remote/$base^{commit}")"
  git_ merge-base --is-ancestor "$sha" "$base_tip" \
    || refuse "$sha is not on $remote/$base: a profile of a commit the base does not have would pin code it does not build"
  git_ cat-file -e "$base_tip:$pin_rel" 2>/dev/null \
    || refuse "$remote/$base has no $pin_rel (task 052); there is nothing to refresh"
fi

# --- 1 and 2: the profile build and stage 1 -----------------------------------------------------------------------
derived_root="$HOME/Library/Developer/Xcode/DerivedData"
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
profdata_file="$profile_dir/cmux-next.profdata"
candidate_pin="$profile_dir/cmux-next.profdata.sha256"

# --- 3: the -profile-use build ------------------------------------------------------------------------------------
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

# --- 3 to 5: the use build, stage 2 and the check -----------------------------------------------------------------
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
  run_check --app "$use_app" --order "$order_dir/cmux-next.order" --link-map "$use_dir/link-map.txt" \
    --profdata "$profdata_file" --pinned "$candidate_pin" --json "$out/check.json" \
    | tee "$out/check.log" || die "check.py refused the new order; see $out/check.log"
  printf '%s %s\n' "$profdata_sha" "$(sha256_of "$order_dir/cmux-next.order")" >"$out/check.passed"
else
  say "3-5/7 kept: the order and its passed check"
fi

if (( ! publish )); then
  say "done without publishing: $profdata_file and $order_dir/cmux-next.order in $out"
  say "publish with: scripts/cmux-next/pgo/refresh.sh --ref $sha --out $out"
  exit 0
fi

# --- 6 and 7: upload and pull request -----------------------------------------------------------------------------
mkdir -p "$publish_dir"
git_ show "$base_tip:$pin_rel" >"$publish_dir/base.sha256"
{
  # The pin keeps the base's comment lines; only its one profile line changes.
  grep -E '^[[:space:]]*(#|$)' "$publish_dir/base.sha256" || true
  printf '%s  cmux-next.profdata\n' "$profdata_sha"
} >"$publish_dir/cmux-next.profdata.sha256"
pin_blob="$(git_ hash-object -w "$publish_dir/cmux-next.profdata.sha256")"
order_blob="$(git_ hash-object -w "$order_dir/cmux-next.order")"
blob_at() { git_ rev-parse --verify --quiet "$1:$2" || true; }

if [[ "$(pin_sha "$publish_dir/base.sha256")" == "$profdata_sha" \
  && "$(blob_at "$base_tip" "$order_rel")" == "$order_blob" ]]; then
  say "$remote/$base already pins $profdata_sha with this order; nothing to publish"
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

say "6/7 upload of $profdata_sha"
upload_profile "$profdata_file" "$profdata_sha" || die "the upload failed"
rm -rf "$publish_dir/fetched"
env -u CMUX_PGO_SOURCE "$script_dir/fetch-profdata.sh" --pin "$candidate_pin" --cache "$publish_dir/fetched" >/dev/null \
  || die "the uploaded profile does not fetch back by its sha256 from ${CI_CACHE_R2_PUBLIC_URL:-https://ci-cache.cmux.com}"

branch="pgo-refresh/$short"
say "7/7 branch $branch and the PR into $base"
remote_head="$(git_ ls-remote --heads "$remote" "refs/heads/$branch" | awk '{ print $1 }')"
if [[ -n "$remote_head" ]]; then
  git_ fetch --quiet "$remote" "+refs/heads/$branch:refs/remotes/$remote/$branch" || die "cannot fetch $branch"
  if [[ "$(blob_at "$remote_head" "$pin_rel")" != "$pin_blob" || "$(blob_at "$remote_head" "$order_rel")" != "$order_blob" ]]; then
    die "$remote/$branch holds another profile or order (an earlier refresh of $short); close its PR and delete the branch, or rerun with that run's --out"
  fi
  say "$remote/$branch already has this profile and order"
else
  index="$publish_dir/index"
  rm -f "$index"
  GIT_INDEX_FILE="$index" git_ read-tree "$base_tip"
  GIT_INDEX_FILE="$index" git_ update-index --cacheinfo "100644,$pin_blob,$pin_rel" \
    --cacheinfo "100644,$order_blob,$order_rel"
  tree="$(GIT_INDEX_FILE="$index" git_ write-tree)"
  {
    printf 'perf(startup): refresh the cmux-next PGO profile and order file at %s\n\n' "$short"
    printf 'Made by scripts/cmux-next/pgo/refresh.sh (p08-startup-054) from %s:\n' "$sha"
    printf 'the profile %s (pgo/cmux-next/%s.profdata in the bucket)\n' "$profdata_sha" "$profdata_sha"
    printf 'and the order of its -profile-use bench build, checked by pgo/check.py.\n'
  } >"$publish_dir/commit-message.txt"
  commit="$(git_ commit-tree "$tree" -p "$base_tip" -F "$publish_dir/commit-message.txt")"
  git_ push "$remote" "$commit:refs/heads/$branch" || die "cannot push $branch to $remote"
fi

pr_url="$(gh_ pr list --head "$branch" --base "$base" --state open --json url --jq '.[0].url // empty')" \
  || die "gh cannot list the PRs of $branch"
if [[ -n "$pr_url" ]]; then
  say "the PR is already open: $pr_url"
  exit 0
fi

stage_line() { grep -h '^PGO-STAGE ' "$@" 2>/dev/null | tail -n 1 || true; }
check_line="$(grep -h '^PGO-CHECK ' "$out/check.log" 2>/dev/null | tail -n 1 || true)"
made_on="$(cat "$out/made-on" 2>/dev/null || echo 'a host the run folder does not name')"
stage_profile="$(stage_line "$out/stage-profile.log")"
stage_order="$(stage_line "$out/stage-order.log")"
cat >"$publish_dir/pr.md" <<EOF
Refreshes the cmux-next Swift PGO profile and the Release order file from $sha.

\`$pin_rel\` now pins \`$profdata_sha\`, uploaded to \`pgo/cmux-next/$profdata_sha.profdata\`. \`$order_rel\` is
stage 2's order from the \`-profile-use\` bench build of that profile, with the companions committed in
\`Resources/build/cmux-next.pgo.conf\`. The switch in that file is unchanged.

Made by \`scripts/cmux-next/pgo/refresh.sh\` on $made_on.

## Changelog

none

### Observed / Not run

Observed, in the run folder on that host:

\`\`\`
${stage_profile:-PGO-STAGE profile (no line)}
${stage_order:-PGO-STAGE order (no line)}
${check_line:-PGO-CHECK (no line)}
\`\`\`

Not run: check.py's launch-window check, which needs a Release link with this order and a fresh launch profile
(the first Release build after this merges); the cold-launch A/B.
EOF
pr_url="$(gh_ pr create --base "$base" --head "$branch" \
  --title "perf(startup): refresh the cmux-next PGO profile and order file at $short" \
  --body-file "$publish_dir/pr.md")" || die "gh cannot open the PR of $branch"
say "opened $pr_url"
