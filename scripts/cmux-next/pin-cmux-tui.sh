#!/usr/bin/env bash
# Fetch the hosted macOS arm64 cmux-tui that the cmux-next app bundles.
#
# Two modes. Dogfood, tagged, fleet and nightly builds use tree mode; only
# release and RC builds use the pin.
#
# tree (default): the daemon built from this checkout's own cmux-tui source.
#   The key is a git tree hash of the binary's source inputs
#   (scripts/cmux-next/cmux-tui-tree-inputs.txt: the cmux-tui tree, the
#   ghostty-next gitlink and the reducer FFI build script), computed by
#   scripts/ci/cmux_tui_tree_key.py (`pin-cmux-tui.sh key`). That is key v2.
#   Key v1 also hashed the classic `ghostty` gitlink, which no cmux-tui binary
#   builds from since 0c9d74bc3ea (CMUX-TUI-TREE-KEY-V2). Until v1 goes away,
#   fetch and resolve-commit take the v2 publication, else the v1 publication
#   of the same commit (`key --version v1`), and the workflow publishes both.
#   The `cmux-tui artifacts` workflow runs on every push to feat-cmux-next,
#   feat-cmux-next-acpmux and cmux-tui-pin-* that touches cmux-tui, ghostty or ghostty-next.
#   After the hosted build and the cmux_next_ daemon tests pass on that commit,
#   it publishes https://files.cmux.com/cmux-tui/tree/<key>/ with
#   cmux-tui-aarch64-apple-darwin, cmux-tui-aarch64-apple-darwin.sha256 and
#   source.json (the commit and run that built it). `fetch` downloads it to
#   cmux-tui/target/hosted/tree/<key>/cmux-tui and checks the published
#   sha256. When the key is not published yet it waits, printing progress, up
#   to CMUX_TUI_TREE_WAIT_SECONDS (default 2700), then fails. It never falls
#   back to another binary. In CI the wait also reads the cmux-tui artifacts
#   runs of CMUX_TUI_TREE_PUBLISHER_SHA (the pushed commit; needs GH_TOKEN with
#   actions: read) every CMUX_TUI_TREE_RUN_CHECK_SECONDS (default 300) and fails
#   fast when two checks in a row find no active run: the runs were cancelled,
#   superseded (finished without publishing) or never started. An active run, or
#   an API it cannot read, keeps the bounded wait. A fleet build that already compiled this source
#   (the cmux recipe's cmux_tui_client phase sets CMUX_TUI_CLIENT_LOCAL)
#   is used instead when its build commit has the same key: `fetch` then
#   downloads nothing, and the bundle phase records source=tree-local-build.
#   To publish the tree of an unmerged branch:
#     git push origin HEAD:refs/heads/cmux-tui-pin-<short-sha>
#     gh workflow run cmux-tui-artifacts.yml --ref cmux-tui-pin-<short-sha>
#   (dispatch only when the push started no run: a push starts one only when
#   commits new to the repository change cmux-tui, ghostty or the workflow).
#   Uncommitted changes under cmux-tui/ (or a ghostty checkout that differs
#   from the gitlink) are not in the published binary, so `fetch` refuses
#   them unless CMUX_NEXT_TUI_ALLOW_DIRTY=1. CMUX_NEXT_TUI_BIN=<path> bundles a
#   local build instead.
#
# pin (release and RC builds only; `--pin` or CMUX_NEXT_TUI_MODE=pin):
#   scripts/cmux-next/cmux-tui.pin names one commit, its public
#   commit-addressed binary, the publishing run (run=), the cmux-tui.yml run
#   that verified it (verified_run=) and the binary's sha256. Release jobs
#   install that commit's universal client. Dogfood builds do not need a pin
#   bump. Refresh the pin only for a release:
#     1. ./scripts/verify-cmux-tui-hosted.sh --filter cmux_next_ on the commit.
#     2. Publish that commit's binaries: git push origin <sha>:refs/heads/cmux-tui-pin-<short>
#        and, when the push starts no run, gh workflow run cmux-tui-artifacts.yml --ref cmux-tui-pin-<short>.
#     3. ./scripts/cmux-next/pin-cmux-tui.sh pin --commit <sha> --verified-run <run-id>
#     4. Commit scripts/cmux-next/cmux-tui.pin; delete the helper branch.
#     5. GPLv3 source availability: tag the pinned commit (and every commit a
#        vendor pins) with an annotated tag and push it:
#          git tag -a cmux-tui-src-<first 11 of sha> <full sha> -m "source for vendored cmux-tui crates"
#          git push origin refs/tags/cmux-tui-src-<first 11 of sha>
#        Never move or delete these tags.
#     6. Third-party notices: when cmux-tui.pin moves, regenerate them with
#        ./scripts/cmux-next/generate-third-party-notices.sh and commit
#        THIRD_PARTY_LICENSES.md (and cmux-tui/build-support/notices/REVIEW.md
#        when it changes) with the pin. The cmux-tui-src-<first 11 of sha> tag
#        from step 5 must exist first; the generator refuses without it.
#
# App host (cmux-app-host, apps-v1): both modes also fetch the app host the
#   same build published, cmux-tui-app-host-<target> in the commit-addressed
#   manifest of the commit that built the binary (source.json's commit in tree
#   mode; app_host_url= and app_host_sha256= in the pin). It goes next to the
#   binary as cmux-app-host, sha256-checked. A build that published none bundles
#   none (tree mode records `none` in cmux-app-host.sha256; a pin without the
#   app_host fields stays valid), and the daemon then does not serve apps-v1.
#   The first-party Cloud app server rides the same way: cmux-tui-cloud-server-<target>
#   goes beside it as cmux-cloud (cmux-cloud.sha256; cloud_server_url= and
#   cloud_server_sha256= in the pin); without it the supervisor answers
#   apps.server_missing for cmux/cloud.
#   The browser host rides the same way too: cmux-tui-browser-host-<target> goes
#   beside it as cmux-browser-host (cmux-browser-host.sha256; browser_host_url=
#   and browser_host_sha256= in the pin), where the daemon looks for it (the
#   sibling of its own executable); without it the daemon has no browser host.
#
# No mode needs GitHub credentials: downloads are public and sha256-checked.
#
# Usage: pin-cmux-tui.sh fetch [--tree|--pin] | path [--tree|--pin] | key [--version v1|v2] [--rev <rev>]
#        | app-host-path [--tree|--pin] (where fetch puts the app host)
#        | cloud-server-path [--tree|--pin] (where fetch puts cmux-cloud)
#        | browser-host-path [--tree|--pin] (where fetch puts cmux-browser-host)
#        | resolve-commit (the commit that published this tree, for nightly)
#        | local-build <binary> (exit 0 when that build has this checkout's key)
#        | show | pin --commit <sha> [--verified-run <id>]
set -euo pipefail

TARGET="aarch64-apple-darwin"
BASE="${CMUX_TUI_PIN_BASE:-https://files.cmux.com/cmux-tui}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
pin_file="$script_dir/cmux-tui.pin"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
pin_field() { awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/, ""); print; exit}' "$pin_file"; }

read_pin() {
  [[ -f "$pin_file" ]] || { echo "error: no pin at $pin_file" >&2; exit 1; }
  pin_commit="$(pin_field commit)"
  pin_run="$(pin_field run)"
  pin_url="$(pin_field url)"
  pin_sha256="$(pin_field sha256)"
  [[ "$pin_commit" =~ ^[0-9a-f]{40}$ && "$pin_sha256" =~ ^[0-9a-f]{64}$ && "$pin_url" == https://* ]] || {
    echo "error: malformed pin $pin_file (needs commit=, url=https://..., sha256=)" >&2; exit 1; }
  pin_app_host_url="$(pin_field app_host_url)"
  pin_app_host_sha256="$(pin_field app_host_sha256)"
  if [[ -n "$pin_app_host_url$pin_app_host_sha256" ]]; then
    [[ "$pin_app_host_url" == https://* && "$pin_app_host_sha256" =~ ^[0-9a-f]{64}$ ]] || {
      echo "error: malformed pin $pin_file (app_host_url= and app_host_sha256= go together)" >&2; exit 1; }
  fi
  pin_cloud_server_url="$(pin_field cloud_server_url)"
  pin_cloud_server_sha256="$(pin_field cloud_server_sha256)"
  if [[ -n "$pin_cloud_server_url$pin_cloud_server_sha256" ]]; then
    [[ "$pin_cloud_server_url" == https://* && "$pin_cloud_server_sha256" =~ ^[0-9a-f]{64}$ ]] || {
      echo "error: malformed pin $pin_file (cloud_server_url= and cloud_server_sha256= go together)" >&2; exit 1; }
  fi
  pin_browser_host_url="$(pin_field browser_host_url)"
  pin_browser_host_sha256="$(pin_field browser_host_sha256)"
  if [[ -n "$pin_browser_host_url$pin_browser_host_sha256" ]]; then
    [[ "$pin_browser_host_url" == https://* && "$pin_browser_host_sha256" =~ ^[0-9a-f]{64}$ ]] || {
      echo "error: malformed pin $pin_file (browser_host_url= and browser_host_sha256= go together)" >&2; exit 1; }
  fi
}

# Downloads $1 to $2 with retries; never follows to a non-HTTPS URL.
download() {
  curl -fsSL --proto '=https' --retry 4 --retry-delay 2 --connect-timeout 20 --max-time 600 -o "$2" "$1"
}

# The tree key of <rev> (default HEAD) is derived from
# cmux-tui-tree-inputs.txt. That one list is also the trusted workflow's PR
# path filter, so changes such as the layout-reducer FFI build script cannot
# silently reuse a stale publication.
tree_key() {
  python3 "$repo_root/scripts/ci/cmux_tui_tree_key.py" --version v2 "${1:-HEAD}"
}
# The v1 key of <rev> (with the classic ghostty gitlink): trees published
# before CMUX-TUI-TREE-KEY-V2 exist only under it.
# Empty when <rev> has no v1 key (a revision without the classic gitlink).
legacy_tree_key() {
  python3 "$repo_root/scripts/ci/cmux_tui_tree_key.py" --version v1 "${1:-HEAD}" 2>/dev/null || true
}

mode_from_args() {
  mode="${CMUX_NEXT_TUI_MODE:-tree}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tree) mode=tree ;;
      --pin) mode=pin ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  [[ "$mode" == tree || "$mode" == pin ]] || { echo "error: CMUX_NEXT_TUI_MODE must be tree or pin, not '$mode'" >&2; exit 2; }
}

tree_dir() { echo "$repo_root/cmux-tui/target/hosted/tree/$1"; }

# Refuses a checkout whose cmux-tui source differs from the committed tree:
# the published binary would not contain those edits.
refuse_dirty_source() {
  [[ "${CMUX_NEXT_TUI_ALLOW_DIRTY:-}" == 1 ]] && return 0
  local dirty
  dirty="$(git -C "$repo_root" status --porcelain --ignore-submodules=dirty -- cmux-tui ghostty-next 2>/dev/null || true)"
  [[ -z "$dirty" ]] && return 0
  {
    echo "error: uncommitted cmux-tui source changes are not in any published cmux-tui binary:"
    printf '%s\n' "$dirty" | head -n 20 | sed 's/^/  /'
    echo "  Commit and push them (see --help to publish the tree), bundle a local build with"
    echo "  CMUX_NEXT_TUI_BIN=<path>, or set CMUX_NEXT_TUI_ALLOW_DIRTY=1 to bundle the committed tree."
    echo "  On an nx-remote host: warm trees are dirty by design (nx-remote copies your local"
    echo "  worktree files over a warm tree whose git HEAD is older); for a tagged build that"
    echo "  bundles cmux-tui, use \`nx-remote --ref <pushed sha>\` (a fresh tree)."
  } >&2
  exit 1
}

# Prints the state of the cmux-tui artifacts runs for commit <sha>, one line:
#   active               a run is queued, waiting or in progress
#   ended <runs>         every run completed; <runs> lists conclusion: url
#   none                 no run exists for the commit
#   unknown              the API could not be read (the caller keeps waiting)
artifacts_runs_state() {
  local sha="$1" url body
  url="${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_REPOSITORY:-manaflow-ai/cmux}/actions/workflows/cmux-tui-artifacts.yml/runs?head_sha=$sha&per_page=20"
  body="$(curl -fsSL --connect-timeout 10 --max-time 30 \
    -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" "$url" 2>/dev/null)" || { echo unknown; return 0; }
  python3 -c '
import json, sys
try:
    runs = json.loads(sys.stdin.read())["workflow_runs"]
except Exception:
    print("unknown"); sys.exit(0)
if not runs:
    print("none")
elif any(r.get("status") != "completed" for r in runs):
    print("active")
else:
    print("ended " + ", ".join("%s: %s" % (r.get("conclusion") or "unknown", r.get("html_url") or r.get("id")) for r in runs))
' <<<"$body" 2>/dev/null || echo unknown
}

# Exits 1 with the reason when no cmux-tui artifacts run will publish tree <key>.
fail_unpublishable_tree() {
  local key="$1" sha="$2" state="$3" elapsed="$4"
  {
    echo "error: no cmux-tui artifacts run will publish tree $key (checked after ${elapsed}s, not the full wait)."
    case "$state" in
      none)
        echo "  no cmux-tui artifacts run exists for $sha." ;;
      *success*)
        echo "  The runs for $sha ended without publishing it: ${state#ended }."
        echo "  A run that finds a newer branch head skips the build: this commit was superseded." ;;
      *)
        echo "  The runs for $sha ended without publishing it: ${state#ended }." ;;
    esac
    echo "  A superseded commit needs no tree; the newest push publishes its own."
    echo "  To publish this commit's tree anyway: gh workflow run cmux-tui-artifacts.yml --ref <its branch>,"
    echo "  or for an unmerged commit push it to cmux-tui-pin-${sha:0:12} (see pin-cmux-tui.sh --help)."
  } >&2
  exit 1
}

# Downloads the published sha256 file of tree <key> to <file>, waiting up to
# CMUX_TUI_TREE_WAIT_SECONDS while the artifacts workflow publishes it. With
# CMUX_TUI_TREE_PUBLISHER_SHA and GH_TOKEN set, it fails fast when two run
# checks in a row find no active artifacts run for that commit.
# Waits until tree <key> (v2) or <legacy> (the v1 key of the same commit) is
# published, writes its sha256 file to <out>, and sets published_key to the
# key that was found and published to its sha256.
wait_for_tree() {
  local key="$1" out="$2" legacy="${3:-}" sha_url legacy_url wait_seconds poll_seconds started elapsed
  local publisher="${CMUX_TUI_TREE_PUBLISHER_SHA:-}" check_seconds next_check=0 ended_checks=0 state=""
  sha_url="$BASE/tree/$key/cmux-tui-$TARGET.sha256"
  legacy_url=""
  [[ -n "$legacy" && "$legacy" != "$key" ]] && legacy_url="$BASE/tree/$legacy/cmux-tui-$TARGET.sha256"
  published_key="$key"
  wait_seconds="${CMUX_TUI_TREE_WAIT_SECONDS:-2700}"
  poll_seconds="${CMUX_TUI_TREE_POLL_SECONDS:-30}"
  check_seconds="${CMUX_TUI_TREE_RUN_CHECK_SECONDS:-300}"
  [[ "$wait_seconds" =~ ^[0-9]+$ && "$poll_seconds" =~ ^[1-9][0-9]*$ && "$check_seconds" =~ ^[1-9][0-9]*$ ]] || {
    echo "error: CMUX_TUI_TREE_WAIT_SECONDS, CMUX_TUI_TREE_POLL_SECONDS and CMUX_TUI_TREE_RUN_CHECK_SECONDS must be whole seconds" >&2; exit 2; }
  if [[ -n "$publisher" ]]; then
    if [[ ! "$publisher" =~ ^[0-9a-f]{40}$ || -z "${GH_TOKEN:-}" ]]; then
      echo "note: run check off (CMUX_TUI_TREE_PUBLISHER_SHA needs a 40-hex sha and GH_TOKEN)" >&2
      publisher=""
    elif [[ "$(tree_key "$publisher" 2>/dev/null)" != "$key" ]]; then
      echo "note: run check off: $publisher does not have tree $key" >&2
      publisher=""
    fi
  fi
  started="$(date +%s)"
  # The query string bypasses a cached 404 at the CDN edge.
  until curl -fsSL --proto '=https' --connect-timeout 20 --max-time 60 -o "$out" "$sha_url?t=$(date +%s)" 2>/dev/null \
    || { [[ -n "$legacy_url" ]] \
      && curl -fsSL --proto '=https' --connect-timeout 20 --max-time 60 -o "$out" "$legacy_url?t=$(date +%s)" 2>/dev/null \
      && published_key="$legacy" && sha_url="$legacy_url"; }; do
    elapsed=$(( $(date +%s) - started ))
    if [[ -n "$publisher" ]] && (( elapsed >= next_check )); then
      next_check=$(( elapsed + check_seconds ))
      state="$(artifacts_runs_state "$publisher")"
      case "$state" in
        active|unknown) ended_checks=0 ;;
        *) ended_checks=$(( ended_checks + 1 )) ;;
      esac
      echo "cmux-tui artifacts runs for $publisher: $state" >&2
      # Two checks in a row: a failed publish requeues its run, and a new
      # push's run can appear a moment after the push.
      (( ended_checks >= 2 )) && fail_unpublishable_tree "$key" "$publisher" "$state" "$elapsed"
    fi
    if (( elapsed >= wait_seconds )); then
      {
        echo "error: cmux-tui for this checkout's tree $key is not published after $((elapsed / 60)) min ($sha_url)."
        echo "  The cmux-tui artifacts workflow publishes a tree after its build and cmux_next_ daemon tests pass"
        echo "  on a pushed commit of feat-cmux-next, feat-cmux-next-acpmux or cmux-tui-pin-*."
        echo "  Check its runs: https://github.com/manaflow-ai/cmux/actions/workflows/cmux-tui-artifacts.yml"
        echo "  For an unmerged branch: git push origin HEAD:refs/heads/cmux-tui-pin-$(git -C "$repo_root" rev-parse --short=12 HEAD),"
        echo "  then gh workflow run cmux-tui-artifacts.yml --ref cmux-tui-pin-$(git -C "$repo_root" rev-parse --short=12 HEAD) only if the push started no run"
        echo "  (a pull request checks its merge with the base: merge the base into the branch first)."
        echo "  When the last run for this tree failed, rerun it: gh workflow run cmux-tui-artifacts.yml --ref <that branch>."
        echo "  Or bundle a local build: CMUX_NEXT_TUI_BIN=<path>. No older binary is used instead."
      } >&2
      exit 1
    fi
    echo "waiting for the same-tree cmux-tui $key (${elapsed}s of ${wait_seconds}s): $sha_url is not published yet;" \
      "the cmux-tui artifacts workflow publishes it after the build and cmux_next_ tests pass" >&2
    sleep "$poll_seconds"
  done
  published="$(awk 'NR==1{print $1}' "$out")"
  [[ "$published" =~ ^[0-9a-f]{64}$ ]] || { echo "error: $sha_url is not a sha256 file" >&2; exit 1; }
}

# Pull-request checks use a synthetic merge commit. When the merge does not
# change cmux-tui or either Ghostty gitlink, its tree key is exactly the first
# parent (the base branch) key. Keep that base key explicit in the log and wait
# for its publication instead of treating the PR as an unpublished tree.
pull_request_base_key() {
  [[ "${GITHUB_EVENT_NAME:-}" == "pull_request" ]] || return 1
  local base_rev=""
  if git -C "$repo_root" rev-parse --verify -q HEAD^1 >/dev/null; then
    base_rev="HEAD^1"
  elif [[ "${GITHUB_BASE_SHA:-}" =~ ^[0-9a-f]{40}$ ]]; then
    base_rev="$GITHUB_BASE_SHA"
  else
    return 1
  fi
  tree_key "$base_rev"
}

# On a developer checkout, waiting is pointless when the last commit that
# changed the binary's inputs is on no remote branch: nothing will publish
# it. CI and fleet checkouts may lack remote-tracking refs, so they wait.
# Local remote-tracking refs can be stale (an `nx-remote --ref` tree fetches
# its commit by SHA into a host mirror), so before refusing, the branch heads
# origin has now are checked too.
refuse_unpushed_source() {
  [[ -n "${GITHUB_ACTIONS:-}" || -n "${CI_JOB_DIR:-}" ]] && return 0
  [[ "$(git -C "$repo_root" rev-parse --is-shallow-repository 2>/dev/null)" == false ]] || return 0
  [[ -n "$(git -C "$repo_root" for-each-ref --count=1 refs/remotes 2>/dev/null)" ]] || return 0
  local last
  last="$(git -C "$repo_root" rev-list -1 HEAD -- cmux-tui ghostty-next 2>/dev/null)" || return 0
  [[ -n "$last" ]] || return 0
  [[ -n "$(git -C "$repo_root" branch -r --contains "$last" 2>/dev/null | head -n 1)" ]] && return 0
  on_origin_branch "$last" && return 0
  {
    echo "error: commit $last, the last change to cmux-tui or ghostty-next here, is on no remote branch,"
    echo "  so no workflow will publish its cmux-tui. Push it (to feat-cmux-next, feat-cmux-next-acpmux or"
    echo "  cmux-tui-pin-<short-sha>), or bundle a local build with CMUX_NEXT_TUI_BIN=<path>."
  } >&2
  exit 1
}

# True when a branch head on origin now (git ls-remote, no fetch) contains
# <commit>. Heads this clone lacks the objects for are skipped. When origin
# cannot be reached the answer is false: the local refs decide, as before.
on_origin_branch() {
  local commit="$1" heads sha
  heads="$(git -C "$repo_root" ls-remote --heads origin 2>/dev/null)" || return 1
  while read -r sha _; do
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || continue
    git -C "$repo_root" cat-file -e "$sha^{commit}" 2>/dev/null || continue
    git -C "$repo_root" merge-base --is-ancestor "$commit" "$sha" 2>/dev/null && return 0
  done <<<"$heads"
  return 1
}

# True when <binary> reports a build commit whose tree key is this
# checkout's: the fleet compiled it from this source.
local_build_matches() {
  local binary="$1" commit
  [[ -n "$binary" && -x "$binary" ]] || return 1
  commit="$("$binary" --version 2>/dev/null | head -n 1 | sed -n 's/.*(\([0-9a-f]\{40\}\).*/\1/p')"
  [[ -n "$commit" ]] || return 1
  [[ "$(tree_key "$commit" 2>/dev/null)" == "$(tree_key HEAD)" ]]
}

# Fetches a companion binary of tree <key> into <dir>: cmux-tui-<artifact>-<target>
# (app-host -> cmux-app-host, cloud-server -> cmux-cloud, browser-host ->
# cmux-browser-host) that the commit named by
# <dir>/source.json published in its attested commit-addressed manifest. Records its
# sha256, or `none` when that build published none, in <dir>/<file>.sha256.
fetch_tree_companion() {
  local key="$1" dir="$2" artifact="$3" file="$4" state owner want temp asset
  state="$dir/$file.sha256"
  asset="cmux-tui-$artifact-$TARGET"
  if [[ -f "$state" ]]; then
    want="$(cat "$state")"
    if [[ "$want" == none ]] || [[ -f "$dir/$file" && "$(sha256_of "$dir/$file")" == "$want" ]]; then
      return 0
    fi
  fi
  owner="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("commit") or "")' "$dir/source.json" 2>/dev/null || true)"
  if [[ ! "$owner" =~ ^[0-9a-f]{40}$ ]]; then
    echo "warning: tree $key names no source commit, so its $file is unknown; bundling none" >&2
    return 0
  fi
  temp="$(mktemp -d "$dir/.$artifact.XXXXXX")"
  download "$BASE/$owner/manifest.json" "$temp/manifest.json" || {
    rm -rf "$temp"; echo "error: could not download $BASE/$owner/manifest.json" >&2; exit 1; }
  want="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["binaries"].get(sys.argv[2]) or "none")' "$temp/manifest.json" "$asset")"
  if [[ "$want" == none ]]; then
    rm -rf "$temp"
    rm -f "$dir/$file"
    printf 'none\n' > "$state"
    echo "note: ${owner:0:12} published no $file for tree $key"
    return 0
  fi
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || { rm -rf "$temp"; echo "error: $BASE/$owner/manifest.json has a malformed $file sha256" >&2; exit 1; }
  download "$BASE/$owner/$asset" "$temp/$file" || {
    rm -rf "$temp"; echo "error: could not download $BASE/$owner/$asset" >&2; exit 1; }
  [[ "$(sha256_of "$temp/$file")" == "$want" ]] || {
    rm -rf "$temp"; echo "error: $BASE/$owner/$asset does not match its manifest" >&2; exit 1; }
  chmod 755 "$temp/$file"
  # Rename into place: a rewritten Mach-O keeps a stale code signature.
  mv -f "$temp/$file" "$dir/$file"
  rm -rf "$temp"
  printf '%s\n' "$want" > "$state"
  echo "fetched same-tree $file $key to $dir/$file"
}

fetch_tree_companions() {
  fetch_tree_companion "$1" "$2" app-host cmux-app-host
  fetch_tree_companion "$1" "$2" cloud-server cmux-cloud
  fetch_tree_companion "$1" "$2" browser-host cmux-browser-host
}

fetch_tree() {
  local key base_key wait_key dir binary url actual temp_dir
  key="$(tree_key HEAD)"
  if local_build_matches "${CMUX_TUI_CLIENT_LOCAL:-}"; then
    echo "same-tree cmux-tui $key: using the local build of this source, $CMUX_TUI_CLIENT_LOCAL"
    return 0
  fi
  refuse_dirty_source
  dir="$(tree_dir "$key")"
  binary="$dir/cmux-tui"
  if [[ -f "$binary" && -f "$dir/cmux-tui.sha256" && "$(sha256_of "$binary")" == "$(cat "$dir/cmux-tui.sha256")" ]]; then
    echo "same-tree cmux-tui $key already present: $binary"
    fetch_tree_companions "$key" "$dir"
    return 0
  fi
  url="$BASE/tree/$key/cmux-tui-$TARGET"
  mkdir -p "$dir"
  temp_dir="$(mktemp -d "$dir/.fetch.XXXXXX")"
  # shellcheck disable=SC2064 # expand now: the trap must remove this temp dir
  trap "rm -rf '$temp_dir'" EXIT
  refuse_unpushed_source
  wait_key="$key"
  if base_key="$(pull_request_base_key 2>/dev/null)"; then
    if [[ "$base_key" == "$key" ]]; then
      echo "pull-request cmux-tui tree $key matches base tree; waiting for the base publication (bounded)" >&2
    else
      echo "pull-request cmux-tui tree $key differs from base tree $base_key; waiting for its own publication (bounded)" >&2
    fi
  fi
  wait_for_tree "$wait_key" "$temp_dir/sha256" "$(legacy_tree_key HEAD)"
  if [[ "$published_key" != "$key" ]]; then
    echo "same-tree cmux-tui $key: using its v1 publication $published_key (CMUX-TUI-TREE-KEY-V2)" >&2
    url="$BASE/tree/$published_key/cmux-tui-$TARGET"
  fi
  download "$url" "$temp_dir/cmux-tui" || { echo "error: could not download $url" >&2; exit 1; }
  actual="$(sha256_of "$temp_dir/cmux-tui")"
  [[ "$actual" == "$published" ]] || { echo "error: $url has sha256 $actual, but $url.sha256 publishes $published" >&2; exit 1; }
  download "$BASE/tree/$published_key/source.json" "$temp_dir/source.json" 2>/dev/null || echo '{}' > "$temp_dir/source.json"
  chmod 755 "$temp_dir/cmux-tui"
  # Rename into place: a rewritten Mach-O keeps a stale code signature.
  mv -f "$temp_dir/source.json" "$dir/source.json"
  mv -f "$temp_dir/cmux-tui" "$binary"
  printf '%s\n' "$published" > "$dir/cmux-tui.sha256"
  echo "fetched same-tree cmux-tui $key to $binary"
  fetch_tree_companions "$key" "$dir"
}

# Prints the commit whose attested commit-addressed artifacts carry this
# checkout's tree binary (nightly installs that commit's universal client).
resolve_tree_commit() {
  local key temp_dir commit manifest_sha
  key="$(tree_key HEAD)"
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-tui-tree.XXXXXX")"
  # shellcheck disable=SC2064 # expand now: the trap must remove this temp dir
  trap "rm -rf '$temp_dir'" EXIT
  wait_for_tree "$key" "$temp_dir/sha256" "$(legacy_tree_key HEAD)"
  download "$BASE/tree/$published_key/source.json" "$temp_dir/source.json" || {
    echo "error: $BASE/tree/$published_key/source.json is missing" >&2; exit 1; }
  commit="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("commit") or "")' "$temp_dir/source.json")"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "error: tree $key names no source commit" >&2; exit 1; }
  download "$BASE/$commit/manifest.json" "$temp_dir/manifest.json" || {
    echo "error: $BASE/$commit/manifest.json is missing" >&2; exit 1; }
  manifest_sha="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["binaries"].get(sys.argv[2], ""))' "$temp_dir/manifest.json" "cmux-tui-$TARGET")"
  [[ "$manifest_sha" == "$published" ]] || {
    echo "error: commit $commit published cmux-tui-$TARGET $manifest_sha, not tree $key's $published" >&2; exit 1; }
  echo "$commit"
}

# fetch_pinned <url> <sha256> <destination> <label>
fetch_pinned() {
  local url="$1" want="$2" dest="$3" label="$4" temp actual
  if [[ -f "$dest" && "$(sha256_of "$dest")" == "$want" ]]; then
    echo "pinned $label ${pin_commit:0:12} already present: $dest"
    return 0
  fi
  temp="$(mktemp "$(dirname "$dest")/.$label.XXXXXX")"
  if ! download "$url" "$temp"; then
    rm -f "$temp"
    echo "error: could not download the pinned $label from $url" >&2
    exit 1
  fi
  actual="$(sha256_of "$temp")"
  if [[ "$actual" != "$want" ]]; then
    rm -f "$temp"
    echo "error: $url has sha256 $actual, but $pin_file pins $want" >&2
    exit 1
  fi
  chmod 755 "$temp"
  # Rename into place: a rewritten Mach-O keeps a stale code signature.
  mv -f "$temp" "$dest"
  echo "fetched pinned $label ${pin_commit:0:12} to $dest"
}

fetch_pin() {
  read_pin
  local dir
  dir="$repo_root/cmux-tui/target/hosted/$pin_commit"
  mkdir -p "$dir"
  fetch_pinned "$pin_url" "$pin_sha256" "$dir/cmux-tui" cmux-tui
  if [[ -n "$pin_app_host_url" ]]; then
    fetch_pinned "$pin_app_host_url" "$pin_app_host_sha256" "$dir/cmux-app-host" cmux-app-host
  else
    rm -f "$dir/cmux-app-host"
  fi
  if [[ -n "$pin_cloud_server_url" ]]; then
    fetch_pinned "$pin_cloud_server_url" "$pin_cloud_server_sha256" "$dir/cmux-cloud" cmux-cloud
  else
    rm -f "$dir/cmux-cloud"
  fi
  if [[ -n "$pin_browser_host_url" ]]; then
    fetch_pinned "$pin_browser_host_url" "$pin_browser_host_sha256" "$dir/cmux-browser-host" cmux-browser-host
  else
    rm -f "$dir/cmux-browser-host"
  fi
}

cmd="${1:-}"
shift || true
case "$cmd" in
  pin)
    commit=""
    verified_run=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --commit) commit="${2:?}"; shift 2 ;;
        --verified-run) verified_run="${2:?}"; shift 2 ;;
        *) usage >&2; exit 2 ;;
      esac
    done
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "error: pin needs --commit <40-hex sha>" >&2; exit 2; }
    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-tui-pin.XXXXXX")"
    # shellcheck disable=SC2064 # expand now: the trap must remove this temp dir
    trap "rm -rf '$temp_dir'" EXIT
    manifest_url="$BASE/$commit/manifest.json"
    download "$manifest_url" "$temp_dir/manifest.json" || {
      echo "error: $manifest_url is not published; run the cmux-tui artifacts workflow on $commit (see --help)" >&2; exit 1; }
    read -r manifest_commit sha256 run app_host_sha256 cloud_server_sha256 browser_host_sha256 < <(python3 - "$temp_dir/manifest.json" "cmux-tui-$TARGET" "cmux-tui-app-host-$TARGET" "cmux-tui-cloud-server-$TARGET" "cmux-tui-browser-host-$TARGET" <<'PY'
import json, re, sys
m = json.load(open(sys.argv[1]))
run = re.search(r"/actions/runs/(\d+)", m.get("attestationUrl") or "")
binaries = m.get("binaries", {})
print(m.get("sourceCommit", ""), binaries.get(sys.argv[2], ""), run.group(1) if run else "-", binaries.get(sys.argv[3], "") or "-", binaries.get(sys.argv[4], "") or "-", binaries.get(sys.argv[5], "") or "-")
PY
)
    [[ "$run" == - ]] && run=""
    [[ "$app_host_sha256" == - ]] && app_host_sha256=""
    [[ "$cloud_server_sha256" == - ]] && cloud_server_sha256=""
    [[ "$browser_host_sha256" == - ]] && browser_host_sha256=""
    [[ "$manifest_commit" == "$commit" && "$sha256" =~ ^[0-9a-f]{64}$ ]] || {
      echo "error: $manifest_url does not describe cmux-tui-$TARGET for $commit" >&2; exit 1; }
    url="$BASE/$commit/cmux-tui-$TARGET"
    download "$url" "$temp_dir/cmux-tui"
    [[ "$(sha256_of "$temp_dir/cmux-tui")" == "$sha256" ]] || { echo "error: $url does not match its manifest" >&2; exit 1; }
    chmod 755 "$temp_dir/cmux-tui"
    version="$("$temp_dir/cmux-tui" --version 2>/dev/null | head -n 1 || true)"
    [[ "$version" == *"${commit:0:7}"* ]] || { echo "error: $url reports '$version', not commit $commit" >&2; exit 1; }
    app_host_url=""
    if [[ "$app_host_sha256" =~ ^[0-9a-f]{64}$ ]]; then
      app_host_url="$BASE/$commit/cmux-tui-app-host-$TARGET"
      download "$app_host_url" "$temp_dir/cmux-app-host"
      [[ "$(sha256_of "$temp_dir/cmux-app-host")" == "$app_host_sha256" ]] || {
        echo "error: $app_host_url does not match its manifest" >&2; exit 1; }
    else
      echo "note: $commit published no app host; the pin bundles none (apps unavailable)"
    fi
    cloud_server_url=""
    if [[ "$cloud_server_sha256" =~ ^[0-9a-f]{64}$ ]]; then
      cloud_server_url="$BASE/$commit/cmux-tui-cloud-server-$TARGET"
      download "$cloud_server_url" "$temp_dir/cmux-cloud"
      [[ "$(sha256_of "$temp_dir/cmux-cloud")" == "$cloud_server_sha256" ]] || {
        echo "error: $cloud_server_url does not match its manifest" >&2; exit 1; }
    else
      echo "note: $commit published no cmux-cloud; the pin bundles none"
    fi
    browser_host_url=""
    if [[ "$browser_host_sha256" =~ ^[0-9a-f]{64}$ ]]; then
      browser_host_url="$BASE/$commit/cmux-tui-browser-host-$TARGET"
      download "$browser_host_url" "$temp_dir/cmux-browser-host"
      [[ "$(sha256_of "$temp_dir/cmux-browser-host")" == "$browser_host_sha256" ]] || {
        echo "error: $browser_host_url does not match its manifest" >&2; exit 1; }
    else
      echo "note: $commit published no cmux-browser-host; the pin bundles none"
    fi
    {
      echo "# Hosted cmux-tui that release and RC builds bundle (dogfood builds use the same-tree binary). Refresh: scripts/cmux-next/pin-cmux-tui.sh --help"
      echo "commit=$commit"
      echo "url=$url"
      echo "run=$run"
      [[ -n "$verified_run" ]] && echo "verified_run=$verified_run"
      echo "sha256=$sha256"
      if [[ -n "$app_host_url" ]]; then
        echo "app_host_url=$app_host_url"
        echo "app_host_sha256=$app_host_sha256"
      fi
      if [[ -n "$cloud_server_url" ]]; then
        echo "cloud_server_url=$cloud_server_url"
        echo "cloud_server_sha256=$cloud_server_sha256"
      fi
      if [[ -n "$browser_host_url" ]]; then
        echo "browser_host_url=$browser_host_url"
        echo "browser_host_sha256=$browser_host_sha256"
      fi
    } > "$pin_file"
    echo "pinned $commit ($version)"
    cat "$pin_file"
    ;;
  fetch)
    mode_from_args "$@"
    if [[ "$mode" == tree ]]; then fetch_tree; else fetch_pin; fi
    ;;
  path)
    mode_from_args "$@"
    if [[ "$mode" == tree ]]; then
      echo "$(tree_dir "$(tree_key HEAD)")/cmux-tui"
    else
      read_pin
      echo "$repo_root/cmux-tui/target/hosted/$pin_commit/cmux-tui"
    fi
    ;;
  app-host-path)
    mode_from_args "$@"
    if [[ "$mode" == tree ]]; then
      echo "$(tree_dir "$(tree_key HEAD)")/cmux-app-host"
    else
      read_pin
      echo "$repo_root/cmux-tui/target/hosted/$pin_commit/cmux-app-host"
    fi
    ;;
  cloud-server-path)
    mode_from_args "$@"
    if [[ "$mode" == tree ]]; then
      echo "$(tree_dir "$(tree_key HEAD)")/cmux-cloud"
    else
      read_pin
      echo "$repo_root/cmux-tui/target/hosted/$pin_commit/cmux-cloud"
    fi
    ;;
  browser-host-path)
    mode_from_args "$@"
    if [[ "$mode" == tree ]]; then
      echo "$(tree_dir "$(tree_key HEAD)")/cmux-browser-host"
    else
      read_pin
      echo "$repo_root/cmux-tui/target/hosted/$pin_commit/cmux-browser-host"
    fi
    ;;
  resolve-commit)
    resolve_tree_commit
    ;;
  local-build)
    local_build_matches "${1:-}"
    ;;
  key)
    rev=HEAD
    version=v2
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --rev) rev="${2:?--rev needs a revision}"; shift 2 ;;
        --version) version="${2:?--version needs v1 or v2}"; shift 2 ;;
        *) usage >&2; exit 2 ;;
      esac
    done
    python3 "$repo_root/scripts/ci/cmux_tui_tree_key.py" --version "$version" "$rev"
    ;;
  show)
    read_pin
    echo "tree key=$(tree_key HEAD) url=$BASE/tree/$(tree_key HEAD)/cmux-tui-$TARGET"
    echo "pin commit=$pin_commit run=$pin_run sha256=$pin_sha256 url=$pin_url"
    ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
