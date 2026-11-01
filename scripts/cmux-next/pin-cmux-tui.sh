#!/usr/bin/env bash
# Fetch the hosted macOS arm64 cmux-tui that the cmux-next app bundles.
#
# Two modes. Every app build bundles the cmux-tui of its own tree: dogfood,
# tagged and fleet builds fetch it (tree mode), nightly and RC builds install
# the newest published tree and build the app at that commit
# (resolve-newest-published), and release builds install their own commit's
# tree (resolve-exact, cx-urd.9.1; release.yml and build-sign-upload.sh).
# The pin no longer picks what a release ships. It still names the daemon of
# the last hand-pinned release for the readers that need a fixed older build:
# cmux-tui.yml's upgrade-adoption test, ci-macos.yml's release-build check, the
# committed THIRD_PARTY_LICENSES.md (generate-third-party-notices.sh
# --tui-source pin) and the rust-daemon-client launcher's PIN.
#
# tree (default): the daemon built from this checkout's own cmux-tui source.
#   The key is a git tree hash of the binary's source inputs
#   (scripts/cmux-next/cmux-tui-tree-inputs.txt: the cmux-tui tree, the
#   ghostty-next gitlink, the reducer FFI build script, the macOS builder
#   switch and the Linux cross-build recipe), computed by
#   scripts/ci/cmux_tui_tree_key.py (`pin-cmux-tui.sh key`). That is key v2.
#   Key v1 also hashed the classic `ghostty` gitlink, which no cmux-tui binary
#   builds from since 0c9d74bc3ea (CMUX-TUI-TREE-KEY-V2). Until v1 goes away,
#   fetch and resolve-commit take the v2 publication, else the compatibility
#   publications of the same commit (v2-legacy, then v1).
#   The `cmux-tui artifacts` workflow runs on every trusted push to
#   feat-cmux-next and feat-cmux-next-acpmux that changes a runtime input.
#   GitHub filters pushes containing only cmux-tui/docs prose, so consumers
#   never wait for an unpublished docs-only key. Untrusted synthetic merge
#   refs are refused.
#   After the hosted build and the cmux_next_ daemon tests pass on that commit,
#   it publishes https://files.cmux.com/cmux-tui/tree/<key>/ with
#   cmux-tui-aarch64-apple-darwin, cmux-tui-aarch64-apple-darwin.sha256 and
#   source.json (the commit and run that built it). `fetch` downloads it to
#   cmux-tui/target/hosted/tree/<key>/cmux-tui and checks the published
#   sha256. When the key is not published yet it waits, printing progress, up
#   to CMUX_TUI_TREE_WAIT_SECONDS (default 2700), then fails. 0 looks once and
#   never waits, not even for an active artifacts run: the fleet suite lanes
#   (package-test-lane.sh, run-swift-testing-suites.sh) and the daemon tests
#   use it, so a miss skips their live-daemon suites at once instead of
#   holding a Mac. It never falls back to another binary. In CI the wait also
#   reads the cmux-tui artifacts runs of CMUX_TUI_TREE_PUBLISHER_SHA (the
#   pushed commit; needs GH_TOKEN with actions: read) every CMUX_TUI_TREE_RUN_CHECK_SECONDS (default 300) and fails
#   fast when two checks in a row find no active run: the runs were cancelled,
#   superseded (finished without publishing) or never started. An active run, or
#   an API it cannot read, keeps the bounded wait. A fleet build that already compiled this source
#   (the cmux recipe's cmux_tui_client phase sets CMUX_TUI_CLIENT_LOCAL)
#   is used instead when its build commit has the same key: `fetch` then
#   downloads nothing, and the bundle phase records source=tree-local-build.
#   An unmerged or synthetic merge tree is not published by an untrusted pin
#   branch. Re-run after a trusted feat-cmux-next publication, or bundle a
#   local build with CMUX_NEXT_TUI_BIN=<path>.
#   Uncommitted changes under cmux-tui/ (or a ghostty checkout that differs
#   from the gitlink) are not in the published binary, so `fetch` refuses
#   them unless CMUX_NEXT_TUI_ALLOW_DIRTY=1. CMUX_NEXT_TUI_BIN=<path> bundles a
#   local build instead.
#
# pin (`--pin` or CMUX_NEXT_TUI_MODE=pin; release builds no longer read it):
#   scripts/cmux-next/cmux-tui.pin names one commit, its public
#   commit-addressed binary, the publishing run (run=), the cmux-tui.yml run
#   that verified it (verified_run=) and the binary's sha256. No build needs
#   a pin bump; refresh it only to move the readers listed above:
#     1. ./scripts/verify-cmux-tui-hosted.sh --filter cmux_next_ on the commit.
#     2. Wait for a trusted feat-cmux-next publication of that commit's binaries.
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
#   Tree mode fetches the agent screen-detection plugin the same way:
#   cmux-tui-agent-screen-detection-<target> goes beside it as
#   cmux-agent-screen-detection (cmux-agent-screen-detection.sha256), which the
#   daemon runs by default; the pin carries no plugin fields yet (Release
#   bundles none until its notices are mapped). The slim terminal host rides
#   the same way, tree mode only: cmux-tui-host-<target> goes beside it as
#   cmux-tui-host (cmux-tui-host.sha256), which a macOS daemon runs every
#   terminal host from; without it hosts re-exec the daemon's own binary. The
#   terminal holder too: cmux-tui-holder-<target> goes beside it as cmux-holder
#   (cmux-holder.sha256), which the daemon starts every holder from; without it
#   the holder built into cmux-tui-host runs.
#
# No mode needs GitHub credentials: downloads are public and sha256-checked.
#
# Usage: pin-cmux-tui.sh fetch [--tree|--pin] | fetch-acpmux | path [--tree|--pin] | key [--version v1|v2|v2-legacy] [--rev <rev>]
#        | app-host-path [--tree|--pin] (where fetch puts the app host)
#        | cloud-server-path [--tree|--pin] (where fetch puts cmux-cloud)
#        | browser-host-path [--tree|--pin] (where fetch puts cmux-browser-host)
#        | acpmux-path (where a tree fetch puts acpmux)
#        | resolve-commit (the commit that published this tree; waits for it)
#        | resolve-exact (release and RC builds: resolve-commit for HEAD itself, printed
#          as commit=, key=, source_commit= (HEAD), tip_key=, behind=0 and behind_hours=0
#          lines like resolve-newest-published, so app and daemon come from this commit)
#        | resolve-newest-published (nightly: newest verified published tree in the last
#          CMUX_TUI_TREE_SEARCH_COMMITS commits, default 50, and CMUX_TUI_TREE_MAX_AGE_HOURS,
#          default 24; a hit never waits, and in nightly.yml a miss waits once, up to
#          CMUX_TUI_TREE_TIP_WAIT_SECONDS (3000), for the tip's active publisher; CMUX_TUI_TREE_SAME_PATHS, space-separated
#          paths, skips a commit whose copy of any of them differs from the tip's;
#          no Mac Release compile is required: the nightly compiles the app itself)
#        | runs-state <commit> (its cmux-tui artifacts runs: active, none, unknown, or "ended <conclusions>")
#        | active-publisher <key> (the head commit of an active cmux-tui artifacts run whose
#          commit has tree <key>; nothing when none; "unknown" when the runs cannot all be read)
#        | verify-key <key> (commit=<publishing commit> when tree <key> is published and its
#          manifest sha256 verifies; exit 1 not published (a 404), 3 a read failure or unverifiable)
#        | wait (wait for the tree; superseded=true output for a superseded commit)
#        | fallback-key (fleet suites: when HEAD has the tree of its base,
#          CMUX_TUI_TREE_FALLBACK_BASE (default origin/feat-cmux-next), print the newest
#          published tree's key, as CI's CMUX_TUI_TREE_BASE_FALLBACK; else exit 1)
#        With CMUX_TUI_TREE_DISPATCH=1, a missing tree is reported for trusted
#        publication or a local build; no helper ref is created.
#        | probe (the cmux-next same-tree check: look once, never wait; writes tree_state=
#          ready|deferred|superseded|failed|skipped, tree_key=, tree_fetch_key= and
#          tree_reason= to GITHUB_OUTPUT)
#        | local-build <binary> (exit 0 when that build has this checkout's key)
#        | show | pin --commit <sha> [--verified-run <id>]
set -euo pipefail

# The binary the cmux-next app bundles and the gate commands (probe, wait,
# resolve-commit, resolve-newest-published, pin) read on any host.
GATE_TARGET="aarch64-apple-darwin"
TARGET="$GATE_TARGET"
BASE="${CMUX_TUI_PIN_BASE:-https://files.cmux.com/cmux-tui}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
pin_file="$script_dir/cmux-tui.pin"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

# Git Bash on Windows has sha256sum; macOS has shasum.
sha256_of() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | awk '{print $1}'; }
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
# curl's own --retry skips many transient network failures (exit 35 "Recv
# failure", 56 "connection reset"): a fleet build fetched three companions from
# a published manifest, then lost the fourth download to one timed-out TLS read
# and failed the job (cx-4pdg, 2026-10-11). So every failure except an HTTP
# error (exit 22: the object is not there, which callers poll for) is retried
# here, with a short backoff.
download() {
  local attempt=1 rc=0
  while :; do
    rc=0
    curl -fsSL --proto '=https' --retry 4 --retry-delay 2 --connect-timeout 20 --max-time 600 -o "$2" "$1" || rc=$?
    (( rc == 0 || rc == 22 || attempt >= ${CMUX_TUI_DOWNLOAD_ATTEMPTS:-4} )) && return "$rc"
    echo "warning: download of $1 failed (curl exit $rc, attempt $attempt); retrying" >&2
    sleep "$(( attempt * ${CMUX_TUI_DOWNLOAD_BACKOFF_SECONDS:-2} ))"
    attempt=$((attempt + 1))
  done
}

# The tree key of <rev> (default HEAD) is derived from
# cmux-tui-tree-inputs.txt, so changes such as the layout-reducer FFI build
# script cannot silently reuse a stale publication.
tree_key() {
  python3 "$repo_root/scripts/ci/cmux_tui_tree_key.py" --version v2 "${1:-HEAD}"
}
# The compatibility key of <rev> using the pre-docs v2 algorithm. Trees
# published before docs-only filtering may exist only under this key.
legacy_tree_key() {
  python3 "$repo_root/scripts/ci/cmux_tui_tree_key.py" --version v2-legacy "${1:-HEAD}" 2>/dev/null || true
  python3 "$repo_root/scripts/ci/cmux_tui_tree_key.py" --version v1 "${1:-HEAD}" 2>/dev/null || true
}
# The tree this checkout fetches and bundles: its own, or CMUX_TUI_TREE_KEY.
# cmux-next path routing sets that for a pull request that changes no
# cmux-tui path and whose own tree is not published (probe's tree_fetch_key):
# the tree jobs then run against the newest published tree in its history.
checkout_tree_key() {
  if [[ -n "${CMUX_TUI_TREE_KEY:-}" ]]; then
    [[ "$CMUX_TUI_TREE_KEY" =~ ^[0-9a-f]{40}$ ]] || { echo "error: CMUX_TUI_TREE_KEY must be a 40-hex tree key" >&2; exit 2; }
    echo "$CMUX_TUI_TREE_KEY"
  else
    tree_key HEAD
  fi
}
# The checkout's compatibility keys; none for an explicit CMUX_TUI_TREE_KEY.
checkout_legacy_tree_key() {
  [[ -n "${CMUX_TUI_TREE_KEY:-}" ]] || legacy_tree_key HEAD
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

# Tree mode fetch and the *-path commands use the host's target: macOS gets the
# arm64 app daemon (its path is unchanged), Linux the static musl daemon of its
# architecture (Linux daemon mode), Windows x86_64 (Git Bash, MSYS2, Cygwin) the
# x86_64-pc-windows-gnu daemon (cmux-tui-x86_64-pc-windows-gnu.exe in the tree,
# fetched as cmux-tui.exe; published unsigned, sha256-checked like the others).
# CMUX_TUI_TREE_TARGET overrides the host.
host_tree_target() {
  if [[ -n "${CMUX_TUI_TREE_TARGET:-}" ]]; then echo "$CMUX_TUI_TREE_TARGET"; return 0; fi
  case "$(uname -s)/$(uname -m)" in
    Darwin/*) echo "$GATE_TARGET" ;;
    Linux/x86_64|Linux/amd64) echo x86_64-unknown-linux-musl ;;
    Linux/aarch64|Linux/arm64) echo aarch64-unknown-linux-musl ;;
    MINGW*/x86_64|MSYS*/x86_64|CYGWIN*/x86_64|Windows_NT/x86_64|MINGW*/amd64|MSYS*/amd64|CYGWIN*/amd64|Windows_NT/amd64)
      echo x86_64-pc-windows-gnu ;;
    *) echo "error: no cmux-tui tree target for $(uname -s) $(uname -m); set CMUX_TUI_TREE_TARGET" >&2; exit 2 ;;
  esac
}

# Windows targets publish and fetch with an .exe suffix.
exe_suffix() { [[ "$TARGET" == *-windows-* ]] && echo .exe || true; }
# The tree object of TARGET's daemon, and the file fetch writes it to.
tree_asset() { echo "cmux-tui-$TARGET$(exe_suffix)"; }
tree_binary_file() { echo "cmux-tui$(exe_suffix)"; }

tree_dir() {
  if [[ "$TARGET" == "$GATE_TARGET" ]]; then
    echo "$repo_root/cmux-tui/target/hosted/tree/$1"
  else
    echo "$repo_root/cmux-tui/target/hosted/tree/$1/$TARGET"
  fi
}

# Trees published before the Linux targets carry only the macOS binaries. On
# such a tree, fail now instead of waiting for a target that will never appear.
require_target_in_tree() {
  local key="$1" legacy="$2" target="$TARGET" gate_published=false
  [[ "$target" == "$GATE_TARGET" ]] && return 0
  TARGET="$GATE_TARGET"
  tree_published "$key" "$legacy" && gate_published=true
  TARGET="$target"
  if [[ "$gate_published" == true ]] && ! tree_published "$key" "$legacy"; then
    if [[ -n "$(exe_suffix)" ]]; then
      # Pushes never build Windows (cmux-tui-artifacts.yml build-windows): only
      # a dispatch with include_windows publishes it: say so.
      {
        echo "error: no Windows daemon published for tree $key ($(tree_asset)). Pushes publish no Windows"
        echo "  daemon; publish it with: gh workflow run cmux-tui-artifacts.yml --ref <branch> -f include_windows=true"
        echo "  (its publish-tree-windows adds it to the tree), or use a local build (CMUX2_TUI_BIN / CMUX_NEXT_TUI_BIN)."
      } >&2
      exit 1
    fi
    {
      echo "error: cmux-tui tree $key was published without $target (it predates the $target tree target)."
      echo "  Trees carry Linux binaries from the first cmux-tui change after they were added;"
      echo "  until then use a local build (CMUX2_TUI_BIN / CMUX_NEXT_TUI_BIN) or a newer tree."
    } >&2
    exit 1
  fi
}

# B2 evidence (CMUX-TUI-TREE-KEY-V2): "<key> (v2)" or
# "<key> (compatibility fallback)" for the compatibility publication actually read.
# for the publication actually read. <key> is published_key, <v2 key> the
# checkout's key.
tree_source_label() { [[ "$1" == "$2" ]] && echo "$1 (v2)" || echo "$1 (compatibility fallback)"; }

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

# GitHub API rate limits wait instead of failing. The installation's REST
# budget is shared by every workflow; when it hit 0 (2026-10-30, 06:48Z to
# 07:25Z), every feat-cmux-next push's path routing read the artifacts runs as
# unreadable and failed its same-tree cmux-tui job, run 41018375309. A refused
# read now waits for the reset GitHub names (Retry-After, else
# x-ratelimit-reset) and reads again, within CMUX_TUI_TREE_RATE_LIMIT_WAIT_SECONDS
# (default 60) for this whole invocation. A reset further off than that is
# reported as rate-limited, never as "no run" (the probe defers on it).
rate_limit_budget="${CMUX_TUI_TREE_RATE_LIMIT_WAIT_SECONDS:-60}"
[[ "$rate_limit_budget" =~ ^(0|[1-9][0-9]*)$ ]] || rate_limit_budget=60
rate_limit_deadline=$(( $(date +%s) + rate_limit_budget ))

# rate_limit_wait <status> <headers file>: with the response body on stdin,
# prints the seconds until GitHub accepts the call again when the response is a
# rate-limit refusal: HTTP 429, or 403 with x-ratelimit-remaining: 0, a
# Retry-After, or a body naming a rate limit (the secondary limit sends no
# reset; 60 s then). Exit 1 for any other response (a permission 403 included).
rate_limit_wait() {
  python3 -c '
import re, sys
status, path, now = sys.argv[1], sys.argv[2], int(sys.argv[3])
body = sys.stdin.read()
headers = {}
for line in open(path, encoding="latin-1"):
    if line.upper().startswith("HTTP/"):
        headers = {}  # a redirect: only the last response counts
        continue
    name, sep, value = line.partition(":")
    if sep:
        headers[name.strip().lower()] = value.strip()
retry = headers.get("retry-after", "")
remaining = headers.get("x-ratelimit-remaining", "")
reset = headers.get("x-ratelimit-reset", "")
named = re.search(r"rate limit|abuse detection|too many requests", body, re.IGNORECASE)
if status != "429" and not (status == "403" and (remaining == "0" or retry.isdigit() or named)):
    sys.exit(1)
if retry.isdigit():
    wait = int(retry)
elif remaining == "0" and reset.isdigit():
    wait = int(reset) - now + 1
else:
    wait = 60
print(max(1, wait))
' "$1" "$2" "$(date +%s)"
}

# github_get <url>: one GitHub REST GET (with GH_TOKEN when set), the body on
# stdout. Exit 0 read; 1 any other failure, as a plain `curl -f` read; 4 still
# refused for the rate limit because its reset is past rate_limit_deadline.
github_get() {
  local url="$1" headers body rc status wait auth=()
  [[ -n "${GH_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $GH_TOKEN")
  headers="$(mktemp "${TMPDIR:-/tmp}/cmux-tui-api.XXXXXX")" || return 1
  while :; do
    : > "$headers"
    rc=0
    body="$(curl -sSL --connect-timeout 10 --max-time 30 -D "$headers" ${auth[@]+"${auth[@]}"} \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" "$url" 2>/dev/null)" || rc=$?
    status="$(awk '{ sub(/\r$/, "") } toupper($1) ~ /^HTTP\// { code = $2 } END { print code }' "$headers" 2>/dev/null)"
    # No status line: a non-HTTP URL (the tests' file://) read by curl itself.
    if (( rc == 0 )) && [[ -z "$status" || "$status" == 2?? ]]; then
      rm -f "$headers"; printf '%s\n' "$body"; return 0
    fi
    if (( rc != 0 )) || ! wait="$(rate_limit_wait "$status" "$headers" <<<"$body")"; then
      rm -f "$headers"; return 1
    fi
    if (( $(date +%s) + wait > rate_limit_deadline )); then
      echo "note: GitHub API rate limit (HTTP $status) on ${url%%\?*}: it resets in ${wait}s, past this check's rate-limit wait (CMUX_TUI_TREE_RATE_LIMIT_WAIT_SECONDS=$rate_limit_budget)" >&2
      rm -f "$headers"; return 4
    fi
    echo "note: GitHub API rate limit (HTTP $status) on ${url%%\?*}; waiting ${wait}s for the reset, then reading again" >&2
    sleep "$wait"
  done
}

# Prints the state of the cmux-tui artifacts runs for commit <sha>, one line:
#   active               a run is queued, waiting or in progress
#   ended <runs>         every run completed; <runs> lists conclusion: url
#   none                 no run exists for the commit
#   unknown              the API could not be read (the caller keeps waiting),
#                        a rate limit past this invocation's wait included
artifacts_runs_state() {
  local state
  state="$(artifacts_runs_state_or_limited "$1")"
  [[ "$state" != rate-limited ]] || state=unknown
  echo "$state"
}

# artifacts_runs_state, except that a rate limit whose reset is past this
# invocation's wait prints rate-limited instead of unknown (the probe defers on it).
artifacts_runs_state_or_limited() {
  local sha="$1" url body rc=0
  url="${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_REPOSITORY:-manaflow-ai/cmux}/actions/workflows/cmux-tui-artifacts.yml/runs?head_sha=$sha&per_page=20"
  # manaflow-ai/cmux is public: without GH_TOKEN (a fleet host) the read is unauthenticated,
  # 60 an hour per address, and the wait checks at most every CMUX_TUI_TREE_RUN_CHECK_SECONDS.
  body="$(github_get "$url")" || rc=$?
  if (( rc == 4 )); then echo rate-limited; return 0; fi
  (( rc == 0 )) || { echo unknown; return 0; }
  python3 -c '
import json, sys
try:
    runs = json.loads(sys.stdin.read())["workflow_runs"]
    assert isinstance(runs, list) and all(isinstance(r, dict) for r in runs)
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

# Prints the newer head of the pushed branch (GITHUB_REF) when <sha> was
# superseded: every artifacts run for it ended cancelled or skipped (success
# without publishing) and the branch head has moved. Prints nothing otherwise,
# including when the head cannot be read (a failure then stays a failure).
superseded_by() {
  local sha="$1" state="$2" branch head
  [[ "$state" == ended\ * ]] || return 0
  # Any other conclusion (failure, timed_out, ...) is a real failure.
  python3 -c '
import re, sys
parts = sys.argv[1][len("ended "):].split(", ")
sys.exit(0 if parts and all(re.match(r"(cancelled|success): ", p) for p in parts) else 1)
' "$state" || return 0
  [[ "${GITHUB_REF:-}" == refs/heads/* ]] || return 0
  branch="${GITHUB_REF#refs/heads/}"
  head="$(github_get "${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_REPOSITORY:-manaflow-ai/cmux}/git/ref/heads/$branch" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["object"]["sha"])' 2>/dev/null)" || return 0
  [[ "$head" =~ ^[0-9a-f]{40}$ && "$head" != "$sha" ]] && echo "$head"
  return 0
}

# The GitHub token for dispatch: GH_TOKEN, else the authenticated gh CLI.
github_token() {
  if [[ -n "${GH_TOKEN:-}" ]]; then printf '%s\n' "$GH_TOKEN"; return 0; fi
  command -v gh >/dev/null 2>&1 && gh auth token 2>/dev/null
}

# Prints the head_sha of an active (not completed) cmux-tui artifacts run whose
# commit has tree <key>, nothing when the runs list has none, or "unknown" when
# the runs list cannot be read (rate limit, network, an unparsable body) or the
# fetch deadline passed before every run commit was compared: a caller that
# fails fast on "no publisher" must not read an unread run as none.
# Run commits missing locally are fetched together, by exact SHA (no tags, no
# ref listing), and in a shallow or partial clone with depth 1 and no blobs: the
# key reads only trees. A depth-1 fetch with blobs is the whole source tree
# (about 560 MB) per run, and a burst of lane-branch pushes lists up to 50
# active runs, so one fetch per run held cmux-next path routing past its limit
# (2026-10-27). A full clone stays full (no depth) and complete (no filter).
# All fetches share CMUX_TUI_TREE_RUN_FETCH_SECONDS (default 60); runs on the
# cmux-next branches are compared first. A commit no remote serves is skipped;
# one the deadline cut off is unread. Presence checks never lazy-fetch (a
# partial clone would otherwise fetch each missing commit outside the deadline).
active_publisher_for_key() {
  local key="$1" body candidate fetch_args=() candidates=() missing=() unread=0 deadline left
  local budget="${CMUX_TUI_TREE_RUN_FETCH_SECONDS:-60}" public
  [[ "$budget" =~ ^(0|[1-9][0-9]*)$ ]] || budget=60
  public="${CMUX_TUI_PUBLIC_GIT_URL:-https://github.com/${GITHUB_REPOSITORY:-manaflow-ai/cmux}.git}"
  body="$(github_get "${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_REPOSITORY:-manaflow-ai/cmux}/actions/workflows/cmux-tui-artifacts.yml/runs?per_page=50")" || {
    echo "note: could not list cmux-tui artifacts runs (rate limit or network): a same-tree run is unknown" >&2; echo unknown; return 0; }
  python3 -c '
import json, sys
runs = json.loads(sys.stdin.read())["workflow_runs"]
assert isinstance(runs, list) and all(isinstance(r, dict) and isinstance(r.get("status"), str) for r in runs)
' <<<"$body" 2>/dev/null || {
    echo "note: the cmux-tui artifacts runs list is unreadable: a same-tree run is unknown" >&2; echo unknown; return 0; }
  # Depth 1 only in a shallow checkout: in a full clone --depth writes
  # .git/shallow and truncates history for every worktree sharing it. The blob
  # filter likewise only where history is already incomplete (shallow or partial).
  if [[ "$(git -C "$repo_root" rev-parse --is-shallow-repository)" == true ]]; then
    fetch_args=(--depth=1 --filter=blob:none)
  elif [[ -n "$(git -C "$repo_root" config --get extensions.partialclone 2>/dev/null)" ]]; then
    fetch_args=(--filter=blob:none)
  fi
  while read -r candidate; do
    [[ "$candidate" =~ ^[0-9a-f]{40}$ ]] || continue
    candidates+=("$candidate")
    GIT_NO_LAZY_FETCH=1 git -C "$repo_root" cat-file -e "$candidate^{commit}" 2>/dev/null || missing+=("$candidate")
  done < <(python3 -c '
import json, sys
try:
    runs = json.loads(sys.stdin.read()).get("workflow_runs", [])
except Exception:
    runs = []
active = [r for r in runs if r.get("status") != "completed"]
# The cmux-next branches publish the trees other runs wait for: compare them first.
active.sort(key=lambda r: r.get("head_branch") not in ("feat-cmux-next", "feat-cmux-next-acpmux"))
seen = set()
for run in active:
    sha = run.get("head_sha", "")
    if sha not in seen:
        seen.add(sha)
        print(sha)
' <<<"$body")
  (( ${#candidates[@]} > 0 )) || return 0
  deadline=$(( $(date +%s) + budget ))
  if (( ${#missing[@]} > 0 )); then
    # One fetch for all of them from origin, then from the public repository (a
    # fleet step's origin may be a local warm checkout or the controller's depot,
    # which lack other commits; 2026-10-25: a same-tree run went unseen).
    bounded_run_fetch "$deadline" origin "${missing[@]}" \
      || bounded_run_fetch "$deadline" "$public" "${missing[@]}" || true
  fi
  for candidate in "${candidates[@]}"; do
    if ! GIT_NO_LAZY_FETCH=1 git -C "$repo_root" cat-file -e "$candidate^{commit}" 2>/dev/null; then
      # A batch fails as a whole when one commit is gone; fetch the rest alone.
      if ! bounded_run_fetch "$deadline" origin "$candidate" \
        && ! bounded_run_fetch "$deadline" "$public" "$candidate"; then
        # Cut off by the deadline (or no limiter): unread, not absent.
        if (( $(date +%s) >= deadline )) || ! command -v perl >/dev/null 2>&1; then unread=$((unread + 1))
        else echo "note: cannot read active run commit ${candidate:0:12} to compare its tree" >&2; fi
        continue
      fi
    fi
    if [[ "$(tree_key "$candidate" 2>/dev/null)" == "$key" ]]; then echo "$candidate"; return 0; fi
  done
  if (( unread > 0 )); then
    echo "note: $unread active run commits were not fetched within ${budget}s: a same-tree run is unknown" >&2
    echo unknown
  fi
  return 0
}

# bounded_run_fetch <deadline> <remote> <sha>...: fetches exactly those
# commits (fetch_args from the caller), no tags, no submodules and no
# FETCH_HEAD, stopped at <deadline> (epoch seconds): SIGTERM like timeout(1),
# so git removes its lock files, then SIGKILL 2 s later. perl does the timing
# (it ships with macOS and with git on Linux; timeout(1) does not ship with
# macOS). Without perl nothing is fetched: an unbounded fetch is what this replaces.
bounded_run_fetch() {
  local deadline="$1" remote="$2" left
  shift 2
  left=$(( deadline - $(date +%s) ))
  (( left > 0 )) || return 1
  command -v perl >/dev/null 2>&1 || return 1
  # The fetch runs in its own process group, and the whole group is signalled
  # (a transport helper outlives git otherwise); it writes to no caller's pipe.
  perl -e 'my $t = shift; my $pid = fork; defined $pid or exit 125;
    if (!$pid) { setpgrp 0, 0; exec @ARGV or exit 127 }
    $SIG{ALRM} = sub { kill "TERM", -$pid; for (1 .. 20) { last if waitpid($pid, 1) > 0; select undef, undef, undef, 0.1 }
      kill "KILL", -$pid; waitpid $pid, 0; exit 124 };
    alarm $t; waitpid $pid, 0; my $rc = $?; alarm 0; kill "KILL", -$pid;
    exit(($rc & 127) ? 128 + ($rc & 127) : $rc >> 8)' "$left" \
    git -C "$repo_root" fetch -q --no-tags --no-recurse-submodules --no-write-fetch-head \
    ${fetch_args[@]+"${fetch_args[@]}"} "$remote" "$@" </dev/null >/dev/null 2>&1
}

# ensure_tree_publisher <key> <sha> [fallback]: with CMUX_TUI_TREE_DISPATCH=1,
# report a missing tree for a trusted feat-cmux-next publication. Synthetic
# merge refs and helper branches are never created by this script.
ensure_tree_publisher() {
  local key="$1" sha="$2" current state
  tree_publisher_sha=""
  tree_publisher_action=none
  [[ "${CMUX_TUI_TREE_DISPATCH:-}" == 1 ]] || return 0
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "warning: no commit to publish tree $key; not dispatching" >&2; return 0; }
  state="$(artifacts_runs_state "$sha")"
  if [[ "$state" == active ]]; then
    echo "cmux-tui tree $key: an artifacts run for $sha is active; not dispatching" >&2
    tree_publisher_sha="$sha"; tree_publisher_action=active; return 0
  fi
  current="$(active_publisher_for_key "$key")"
  if [[ -n "$current" && "$current" != unknown ]]; then
    echo "cmux-tui tree $key: active artifacts run for $current has the same tree; not dispatching" >&2
    tree_publisher_sha="$current"; tree_publisher_action=active; return 0
  fi
  echo "warning: tree $key has no active trusted publisher; re-run after feat-cmux-next publishes it or use a local build (CMUX_NEXT_TUI_BIN=<path>)" >&2
  await_outside_publisher "$key" "$sha"
  # Not every active run could be compared (and the wait, if any, found none):
  # unknown, never a SHA and never "no publisher".
  [[ "$current" == unknown && "$tree_publisher_action" == none ]] && tree_publisher_action=unknown
  return 0
}

# await_outside_publisher <key> <sha>: waits briefly for a trusted publication
# already in flight. No PR context creates a helper ref or dispatches a
# credentialed artifacts workflow.
await_outside_publisher() {
  local key="$1" sha="$2" current
  local wait="${CMUX_TUI_TREE_PUBLISHER_WAIT_SECONDS:-90}" poll="${CMUX_TUI_TREE_PUBLISHER_POLL_SECONDS:-10}" started
  # Only a pull request has that publisher. A scheduled DEV run
  # (workflow_dispatch) looks once for its push's run or a same-tree run: that
  # run started before the dispatch, and dev-daily-tree-wait does the waiting.
  # Other callers have their own waits.
  case "${GITHUB_EVENT_NAME:-}" in
    pull_request) ;;
    workflow_dispatch) wait=0 ;;
    *) return 0 ;;
  esac
  [[ "$wait" =~ ^[0-9]+$ && "$poll" =~ ^[0-9]+$ ]] || { echo "warning: CMUX_TUI_TREE_PUBLISHER_WAIT_SECONDS and _POLL_SECONDS must be whole seconds" >&2; return 0; }
  [[ "${GITHUB_EVENT_NAME:-}" != pull_request ]] \
    || echo "cmux-tui tree $key: waiting up to ${wait}s for an active trusted publisher" >&2
  # `date +%s`, not $SECONDS: the tests run this wait on a virtual clock (tests/lib/fake-clock.sh).
  started="$(date +%s)"
  while :; do
    if [[ "$(artifacts_runs_state "$sha")" == active ]]; then
      echo "cmux-tui tree $key: an artifacts run for $sha started; deferring to it" >&2
      tree_publisher_sha="$sha"; tree_publisher_action=active; return 0
    fi
    current="$(active_publisher_for_key "$key")"
    if [[ -n "$current" && "$current" != unknown ]]; then
      echo "cmux-tui tree $key: active artifacts run for $current has the same tree; deferring to it" >&2
      tree_publisher_sha="$current"; tree_publisher_action=active; return 0
    fi
    # The last look could not compare every active run (fetch budget, API):
    # unknown, not "no publisher" (probe_checkout_tree defers on it).
    if [[ "$current" == unknown ]]; then tree_publisher_action=unknown; else tree_publisher_action=none; fi
    (( $(date +%s) - started + poll <= wait )) || break
    sleep "$poll"
  done
  echo "warning: no artifacts run for tree $key started within ${wait}s; tree $key has no publisher" >&2
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
    echo "  For a missing PR tree, land the reviewed change, then re-run after a trusted feat-cmux-next publication."
    echo "  Or bundle a local build with CMUX_NEXT_TUI_BIN=<path>."
  } >&2
  exit 1
}

# report_tree_miss <key>: one stderr line for a miss of this checkout's tree:
# the nearest published tree in the last CMUX_TUI_TREE_NEAREST_COMMITS (default
# 30) commits of HEAD, or none. Informational only: the nearest tree is built
# from different cmux-tui source and is never used as a fallback binary.
# Best effort: a lookup error only shortens the search.
report_tree_miss() {
  local key="$1" limit="${CMUX_TUI_TREE_NEAREST_COMMITS:-30}" rev candidate back=0 seen=" " head nearest=""
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || limit=30
  head="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null)" || head=unknown
  while read -r rev; do
    candidate="$(tree_key "$rev" 2>/dev/null)" || { back=$((back + 1)); continue; }
    if [[ "$candidate" != "$key" && "$seen" != *" $candidate "* ]]; then
      seen+="$candidate "
      if tree_published "$candidate"; then
        nearest="$candidate from ${rev:0:12} ($back commits back, cmux-tui source differs)"
        break
      fi
    fi
    back=$((back + 1))
  done < <(git -C "$repo_root" rev-list --date-order --max-count="$limit" HEAD 2>/dev/null || true)
  echo "no published cmux-tui tree for $key (head ${head:0:12}); nearest published tree: ${nearest:-none in the last $limit commits}" >&2
}

# Read the preferred key, then the exact historical keys of this commit.
# The compatibility list contains only git-produced hex object IDs.
read_tree_digest() {
  local key="$1" out="$2" legacy="${3:-}" candidate url
  for candidate in "$key" $legacy; do
    [[ "$candidate" =~ ^[0-9a-f]{40}$ ]] || return 1
    url="$BASE/tree/$candidate/$(tree_asset).sha256"
    if curl -fsSL --proto '=https' --connect-timeout 20 --max-time 60 -o "$out" "$url?t=$(date +%s)" 2>/dev/null; then
      published_key="$candidate"
      sha_url="$url"
      return 0
    fi
  done
  return 1
}

# Downloads the published sha256 file of tree <key> to <file>, waiting up to
# CMUX_TUI_TREE_WAIT_SECONDS while the artifacts workflow publishes it. With
# CMUX_TUI_TREE_PUBLISHER_SHA and GH_TOKEN set, it fails fast when two run
# checks in a row find no active artifacts run for that commit.
# Waits until tree <key> (v2) or <legacy> (the v2-legacy key of the same commit) is
# published, writes its sha256 file to <out>, and sets published_key to the
# key that was found and published to its sha256.
wait_for_tree() {
  local key="$1" out="$2" legacy="${3:-}" sha_url wait_seconds poll_seconds started elapsed
  local publisher="${CMUX_TUI_TREE_PUBLISHER_SHA:-}" check_seconds next_check=0 ended_checks=0 state="" active_cap extended=false
  sha_url="$BASE/tree/$key/$(tree_asset).sha256"
  published_key="$key"
  wait_seconds="${CMUX_TUI_TREE_WAIT_SECONDS:-2700}"
  poll_seconds="${CMUX_TUI_TREE_POLL_SECONDS:-30}"
  check_seconds="${CMUX_TUI_TREE_RUN_CHECK_SECONDS:-300}"
  # While the publisher's own artifacts run (or another commit's run for the same tree) is still
  # queued or running, the wait goes on past CMUX_TUI_TREE_WAIT_SECONDS up to this cap (2026-10-13: a side-branch run sat 70 min behind the
  # branch's previous run in its concurrency group and a fleet build gave up at 45 min, 36 min
  # before the tree was published).
  # Default 7200 s off CI (the fleet); 0 in GitHub Actions, whose jobs keep their own bounded
  # wait and timeout. Never for a caller that does not wait (CMUX_TUI_TREE_WAIT_SECONDS=0): until
  # 2026-10-29 the 0 of the fleet suite lanes became 7200 s whenever the commit's artifacts run was
  # active, and a suite step held its Mac for up to two hours running nothing (step 31482fc9e743
  # waited 7184 s, 036f288649bf 3065 s until it was cancelled).
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then active_cap="${CMUX_TUI_TREE_ACTIVE_WAIT_SECONDS:-0}"
  else active_cap="${CMUX_TUI_TREE_ACTIVE_WAIT_SECONDS:-7200}"; fi
  [[ "$wait_seconds" =~ ^[0-9]+$ && "$poll_seconds" =~ ^[1-9][0-9]*$ && "$check_seconds" =~ ^[1-9][0-9]*$ && "$active_cap" =~ ^[0-9]+$ ]] || {
    echo "error: CMUX_TUI_TREE_WAIT_SECONDS, CMUX_TUI_TREE_POLL_SECONDS, CMUX_TUI_TREE_RUN_CHECK_SECONDS and CMUX_TUI_TREE_ACTIVE_WAIT_SECONDS must be whole seconds" >&2; exit 2; }
  # The checkout itself is the publisher when it has this tree: its push run publishes the key, so
  # its run state decides (fail fast when it ended without publishing, wait on while it is active).
  # Not for a pull request: its merge commit has no runs of its own.
  if [[ -z "$publisher" && "${GITHUB_EVENT_NAME:-}" != pull_request* && "$(tree_key HEAD 2>/dev/null)" == "$key" ]]; then
    publisher="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
  fi
  if [[ -n "$publisher" ]]; then
    if [[ ! "$publisher" =~ ^[0-9a-f]{40}$ ]]; then
      echo "note: run check off (the publisher must be a 40-hex sha)" >&2
      publisher=""
    elif [[ "$(tree_key "$publisher" 2>/dev/null)" != "$key" ]]; then
      echo "note: run check off: $publisher does not have tree $key" >&2
      publisher=""
    fi
  fi
  if [[ -n "$publisher" ]] && (( wait_seconds > 0 )); then
    if [[ -n "${GH_TOKEN:-}" ]]; then echo "cmux-tui run check reads the GitHub API with a token" >&2
    else echo "cmux-tui run check reads the GitHub API without a token (60 requests an hour per address); a rate limit reads as no run" >&2; fi
  fi
  started="$(date +%s)"
  local dispatched=false reported=false dispatch_sha
  # The query string bypasses a cached 404 at the CDN edge.
  until read_tree_digest "$key" "$out" "$legacy"; do
    elapsed=$(( $(date +%s) - started ))
    if [[ "$reported" == false ]]; then
      reported=true
      report_tree_miss "$key"
      if (( wait_seconds == 0 )); then
        echo "next: not waiting (CMUX_TUI_TREE_WAIT_SECONDS=0 looks once)" >&2
      elif [[ "${CMUX_TUI_TREE_DISPATCH:-}" != 1 ]]; then
        echo "next: no dispatch (CMUX_TUI_TREE_DISPATCH unset); waiting up to ${wait_seconds}s for a push run, or bundle a local build with CMUX_NEXT_TUI_BIN=<path>" >&2
      fi
    fi
    if [[ "$dispatched" == false && "${CMUX_TUI_TREE_DISPATCH:-}" == 1 ]]; then
      dispatched=true
      dispatch_sha="${CMUX_TUI_TREE_PUBLISHER_SHA:-}"
      if [[ -z "$dispatch_sha" && "$(tree_key HEAD 2>/dev/null)" == "$key" ]]; then
        dispatch_sha="$(git -C "$repo_root" rev-parse HEAD)"
      fi
      ensure_tree_publisher "$key" "$dispatch_sha"
      case "$tree_publisher_action" in
        dispatched) echo "next: dispatching one cmux-tui-artifacts run for ${tree_publisher_sha:0:12} (CMUX_TUI_TREE_DISPATCH=1); waiting up to ${wait_seconds}s" >&2 ;;
        active) echo "next: an artifacts run for this tree is active; waiting up to ${wait_seconds}s" >&2 ;;
        *) echo "next: no publisher could be started (see the warning above); waiting up to ${wait_seconds}s for a push run, or bundle a local build with CMUX_NEXT_TUI_BIN=<path>" >&2 ;;
      esac
      # Fail fast on the runs of the commit that will publish the key.
      if [[ -z "$publisher" && -n "$tree_publisher_sha" && -n "${GH_TOKEN:-}" ]]; then
        publisher="$tree_publisher_sha"
      fi
    fi
    # A caller that does not wait reads no run state: nothing would wait on it.
    if [[ -n "$publisher" ]] && (( wait_seconds > 0 && elapsed >= next_check )); then
      next_check=$(( elapsed + check_seconds ))
      state="$(artifacts_runs_state "$publisher")"
      case "$state" in
        active|unknown) ended_checks=0 ;;
        *)
          # Another commit's active run for the same tree will publish it (a merge train tip, a
          # same-key build): that counts as active, not as a run that ended without publishing.
          # An unreadable runs list keeps waiting (bounded), like an unknown state above.
          case "$(active_publisher_for_key "$key")" in
            unknown) state=unknown; ended_checks=0 ;;
            "") ended_checks=$(( ended_checks + 1 )) ;;
            *) state=active; ended_checks=0 ;;
          esac ;;
      esac
      echo "cmux-tui artifacts runs for $publisher: $state" >&2
      # Two checks in a row: a failed publish requeues its run, and a new
      # push's run can appear a moment after the push.
      if (( ended_checks >= 2 )); then
        # `wait` (CMUX_TUI_TREE_ALLOW_SUPERSEDED=1) returns for a superseded
        # commit instead of failing; fetch and resolve-commit still fail.
        if [[ "${CMUX_TUI_TREE_ALLOW_SUPERSEDED:-}" == 1 ]]; then
          tree_superseded_by="$(superseded_by "$publisher" "$state")"
          [[ -n "$tree_superseded_by" ]] && return 0
        fi
        fail_unpublishable_tree "$key" "$publisher" "$state" "$elapsed"
      fi
    fi
    if (( wait_seconds == 0 )); then
      echo "error: cmux-tui for this checkout's tree $key is not published ($sha_url); CMUX_TUI_TREE_WAIT_SECONDS=0 does not wait for it." >&2
      exit 1
    elif (( elapsed >= wait_seconds )) && [[ "$state" == active ]] && (( elapsed < active_cap )); then
      if [[ "$extended" == false ]]; then
        extended=true
        echo "note: the cmux-tui artifacts run for ${publisher:0:12} is still queued or running; waiting on, up to ${active_cap}s in all" >&2
      fi
    elif (( elapsed >= wait_seconds )); then
      {
        echo "error: cmux-tui for this checkout's tree $key is not published after $((elapsed / 60)) min ($sha_url)."
        echo "  The cmux-tui artifacts workflow publishes a tree after its build and cmux_next_ daemon tests pass"
        echo "  on a trusted pushed commit of feat-cmux-next or feat-cmux-next-acpmux."
        echo "  Check its runs: https://github.com/manaflow-ai/cmux/actions/workflows/cmux-tui-artifacts.yml"
        echo "  This tree has no artifact yet; re-run after a trusted feat-cmux-next publication."
        echo "  A fleet app build can bundle its own daemon without publishing the PR tree."
        echo "  A pull request checks its merge with the base; do not publish a synthetic merge commit from the PR context."
        echo "  When the last trusted run for this tree failed, rerun it from feat-cmux-next."
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
    echo "  so no workflow will publish its cmux-tui. Land the reviewed change for trusted publication,"
    echo "  or bundle a local build with CMUX_NEXT_TUI_BIN=<path>."
  } >&2
  exit 1
}

# True when a branch head on origin now (git ls-remote, no fetch) contains
# <commit>. Only commits this clone already has count, and no head is looked up
# by id: in a partial clone each lookup of a commit the clone lacks starts a
# lazy fetch, and origin has thousands of heads (a per-head `cat-file -e` loop
# took 111 min). One local walk lists the descendants of <commit> reachable from
# the local refs and HEAD; a head counts when it is one of them (or <commit>
# itself). The publishing branches are checked first. When origin cannot be
# reached or the walk fails the answer is false: the local refs decide, as before.
on_origin_branch() {
  local commit="$1" heads descendants branch sha
  heads="$(git -C "$repo_root" ls-remote --heads origin 2>/dev/null)" || return 1
  descendants="$(git -C "$repo_root" rev-list --ancestry-path "^$commit" --all HEAD 2>/dev/null)" || return 1
  descendants+=$'\n'"$commit"
  for branch in feat-cmux-next feat-cmux-next-acpmux; do
    sha="$(awk -v ref="refs/heads/$branch" '$2 == ref { print $1 }' <<<"$heads")"
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] && grep -qxF "$sha" <<<"$descendants" && return 0
  done
  [[ -n "$heads" ]] || return 1
  # Full SHAs only on both sides: an empty line must never match.
  awk 'NR == FNR { if ($1 ~ /^[0-9a-f]{40}$/) local_desc[$1]; next }
    $1 ~ /^[0-9a-f]{40}$/ && ($1 in local_desc) { found = 1; exit } END { exit !found }' \
    <(printf '%s\n' "$descendants") <(printf '%s\n' "$heads")
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
# cmux-browser-host, host -> cmux-tui-host, holder -> cmux-holder, agent-screen-detection ->
# cmux-agent-screen-detection) that
# the commit named by
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

# Windows: the per-terminal host the daemon spawns beside itself (cx-1vlzr),
# tree object cmux-tui-host-<target>.exe, fetched as cmux-tui-host.exe next to
# cmux-tui.exe and checked against the tree's published .sha256 like the
# daemon. A tree published before the host has none: the daemon then re-execs
# itself as the host (slower terminal creation, still correct).
fetch_tree_windows_host() {
  local key="$1" dir="$2" file=cmux-tui-host.exe asset url want temp
  asset="cmux-tui-host-$TARGET.exe"
  url="$BASE/tree/$key/$asset"
  if [[ -f "$dir/$file.sha256" ]]; then
    want="$(cat "$dir/$file.sha256")"
    if [[ "$want" == none ]] || [[ -f "$dir/$file" && "$(sha256_of "$dir/$file")" == "$want" ]]; then
      return 0
    fi
  fi
  temp="$(mktemp -d "$dir/.host.XXXXXX")"
  if ! download "$url.sha256" "$temp/sha256" 2>/dev/null; then
    rm -rf "$temp"
    rm -f "$dir/$file"
    printf 'none\n' > "$dir/$file.sha256"
    echo "note: tree $key published no $file; terminals start through cmux-tui.exe (slower)"
    return 0
  fi
  want="$(awk 'NR==1 {print $1}' "$temp/sha256")"
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || { rm -rf "$temp"; echo "error: $url.sha256 is not a sha256 file" >&2; exit 1; }
  download "$url" "$temp/$file" || { rm -rf "$temp"; echo "error: could not download $url" >&2; exit 1; }
  [[ "$(sha256_of "$temp/$file")" == "$want" ]] || {
    rm -rf "$temp"; echo "error: $url does not match $url.sha256" >&2; exit 1; }
  chmod 755 "$temp/$file"
  mv -f "$temp/$file" "$dir/$file"
  rm -rf "$temp"
  printf '%s\n' "$want" > "$dir/$file.sha256"
  echo "fetched same-tree $file $key to $dir/$file"
}

fetch_tree_companions() {
  local companions="${3:-all}"
  # Windows has one companion, the terminal host; the Windows daemon has no
  # app, cloud or browser host.
  if [[ -n "$(exe_suffix)" ]]; then
    [[ "$companions" == all ]] || { echo "error: acpmux-only fetch is only supported on macOS" >&2; exit 2; }
    fetch_tree_windows_host "$1" "$2"
    return 0
  fi
  if [[ "$companions" == acpmux ]]; then
    fetch_tree_companion "$1" "$2" acpmux acpmux
    return 0
  fi
  fetch_tree_companion "$1" "$2" app-host cmux-app-host
  fetch_tree_companion "$1" "$2" cloud-server cmux-cloud
  fetch_tree_companion "$1" "$2" browser-host cmux-browser-host
  fetch_tree_companion "$1" "$2" host cmux-tui-host
  fetch_tree_companion "$1" "$2" holder cmux-holder
  fetch_tree_companion "$1" "$2" agent-screen-detection cmux-agent-screen-detection
  # The app bundles acpmux too; a tree published before its build carried
  # acpmux has none, and the app build compiles it (build-acpmux.sh).
  fetch_tree_companion "$1" "$2" acpmux acpmux
}

fetch_tree() {
  local key base_key wait_key dir binary url actual temp_dir file
  key="$(checkout_tree_key)"
  file="$(tree_binary_file)"
  if local_build_matches "${CMUX_TUI_CLIENT_LOCAL:-}"; then
    echo "same-tree cmux-tui $key: using the local build of this source, $CMUX_TUI_CLIENT_LOCAL"
    return 0
  fi
  refuse_dirty_source
  dir="$(tree_dir "$key")"
  binary="$dir/$file"
  # The cache dir carries the v2 key's name even when the binary came from the
  # compatibility publication, so fetched-key records the source; a cache without that
  # record is fetched again rather than reported as an unknown source.
  if [[ -f "$binary" && -f "$dir/$file.sha256" && -s "$dir/fetched-key" &&
        "$(sha256_of "$binary")" == "$(cat "$dir/$file.sha256")" ]]; then
    echo "same-tree cmux-tui $key already present: $binary"
    echo "cmux-tui tree $key already present, fetched from $(tree_source_label "$(awk '{print $1}' "$dir/fetched-key")" "$key")"
    fetch_tree_companions "$key" "$dir"
    return 0
  fi
  url="$BASE/tree/$key/$(tree_asset)"
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
  if [[ -n "${CMUX_TUI_TREE_KEY:-}" ]]; then
    echo "cmux-tui tree $key from CMUX_TUI_TREE_KEY: this pull request changes no cmux-tui path, so it runs on the newest published tree in its history" >&2
  fi
  require_target_in_tree "$wait_key" "$(checkout_legacy_tree_key)"
  wait_for_tree "$wait_key" "$temp_dir/sha256" "$(checkout_legacy_tree_key)"
  if [[ "$published_key" != "$key" ]]; then
    echo "same-tree cmux-tui $key: using its compatibility publication $published_key (CMUX-TUI-TREE-KEY-V2)" >&2
    url="$BASE/tree/$published_key/$(tree_asset)"
  fi
  download "$url" "$temp_dir/$file" || { echo "error: could not download $url" >&2; exit 1; }
  actual="$(sha256_of "$temp_dir/$file")"
  [[ "$actual" == "$published" ]] || { echo "error: $url has sha256 $actual, but $url.sha256 publishes $published" >&2; exit 1; }
  download "$BASE/tree/$published_key/source.json" "$temp_dir/source.json" 2>/dev/null || echo '{}' > "$temp_dir/source.json"
  chmod 755 "$temp_dir/$file"
  # Rename into place: a rewritten Mach-O keeps a stale code signature.
  mv -f "$temp_dir/source.json" "$dir/source.json"
  mv -f "$temp_dir/$file" "$binary"
  printf '%s\n' "$published" > "$dir/$file.sha256"
  if [[ "$published_key" == "$key" ]]; then echo "$published_key v2"; else echo "$published_key compatibility"; fi > "$dir/fetched-key"
  echo "fetched same-tree cmux-tui $key to $binary"
  echo "fetched cmux-tui tree $(tree_source_label "$published_key" "$key")"
  fetch_tree_companions "$key" "$dir"
}

# Fetch only the attested acpmux companion for the resolved macOS tree. The
# app build calls this before build-acpmux.sh and does not need the daemon or
# the app/cloud/browser/plugin companions, which are fetched later by the
# bundle job. Keep the tree publication and source manifest checks from the
# full fetch so a companion can never be accepted from an unverified owner.
fetch_tree_acpmux() {
  local key dir temp_dir owner manifest_sha published_sha source_file
  key="$(checkout_tree_key)"
  TARGET="$GATE_TARGET"
  refuse_dirty_source
  dir="$(tree_dir "$key")"
  mkdir -p "$dir"
  temp_dir="$(mktemp -d "$dir/.acpmux-fetch.XXXXXX")"
  # shellcheck disable=SC2064 # expand now: the trap must remove this temp dir
  trap "rm -rf '$temp_dir'" EXIT
  refuse_unpushed_source
  require_target_in_tree "$key" "$(checkout_legacy_tree_key)"
  wait_for_tree "$key" "$temp_dir/sha256" "$(checkout_legacy_tree_key)"
  published_sha="$published"
  source_file="$dir/source.json"
  download "$BASE/tree/$published_key/source.json" "$temp_dir/source.json" 2>/dev/null || {
    echo "error: could not download $BASE/tree/$published_key/source.json" >&2
    exit 1
  }
  owner="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("commit") or "")' "$temp_dir/source.json" 2>/dev/null || true)"
  [[ "$owner" =~ ^[0-9a-f]{40}$ ]] || {
    echo "error: tree $key has no valid source commit in its attested source.json" >&2
    exit 1
  }
  download "$BASE/$owner/manifest.json" "$temp_dir/manifest.json" 2>/dev/null || {
    echo "error: could not download $BASE/$owner/manifest.json" >&2
    exit 1
  }
  manifest_sha="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["binaries"].get(sys.argv[2]) or "")' "$temp_dir/manifest.json" "cmux-tui-$TARGET" 2>/dev/null || true)"
  [[ "$manifest_sha" == "$published_sha" ]] || {
    echo "error: $BASE/$owner/manifest.json does not attest cmux-tui-$TARGET for tree $key" >&2
    exit 1
  }
  mv -f "$temp_dir/source.json" "$source_file"
  fetch_tree_companions "$key" "$dir" acpmux
  [[ -x "$dir/acpmux" && -f "$dir/acpmux.sha256" && "$(cat "$dir/acpmux.sha256")" != none ]] || {
    echo "error: tree $key has no verified acpmux companion" >&2
    exit 1
  }
  echo "using attested same-tree acpmux companion: $dir/acpmux"
}

# The cmux-next gate: waits for this checkout's tree like fetch, without
# downloading the binary. A commit superseded by a newer branch head (its
# artifacts runs were cancelled or skipped) is not a failure: it prints a
# notice and writes superseded=true to GITHUB_OUTPUT, and the jobs that need
# the binary are skipped. A failed publish, or a timeout, exits 1.
wait_for_checkout_tree() {
  local key temp_dir
  key="$(tree_key HEAD)"
  refuse_dirty_source
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-tui-tree.XXXXXX")"
  # shellcheck disable=SC2064 # expand now: the trap must remove this temp dir
  trap "rm -rf '$temp_dir'" EXIT
  tree_superseded_by=""
  CMUX_TUI_TREE_ALLOW_SUPERSEDED=1 wait_for_tree "$key" "$temp_dir/sha256" "$(legacy_tree_key HEAD)"
  if [[ -n "$tree_superseded_by" ]]; then
    echo "::notice title=cmux-tui tree superseded::$(git rev-parse HEAD) was superseded by $tree_superseded_by on ${GITHUB_REF#refs/heads/}: its cmux-tui tree $key was not published, so the jobs that need it are skipped (the newer head is tested)."
    echo "cmux-tui tree $key: superseded by $tree_superseded_by"
    [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "superseded=true" >> "$GITHUB_OUTPUT"
    return 0
  fi
  echo "cmux-tui tree $key is published: $(tree_source_label "$published_key" "$key")"
  [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "superseded=false" >> "$GITHUB_OUTPUT"
  return 0
}

# Prints whether tree <key> (v2) or <legacy> (historical keys of the same commit) is
# published now: one request each, no wait.
tree_published() {
  local key="$1" legacy="${2:-}" url candidate
  for candidate in "$key" $legacy; do
    [[ "$candidate" =~ ^[0-9a-f]{40}$ ]] || return 1
    url="$BASE/tree/$candidate/$(tree_asset).sha256"
    # The query string bypasses a cached 404 at the CDN edge.
    if curl -fsSL --proto '=https' --connect-timeout 20 --max-time 60 "$url?t=$(date +%s)" 2>/dev/null \
        | awk 'NR==1 && $1 ~ /^[0-9a-f]{64}$/ { found=1 } END { exit !found }'; then
      return 0
    fi
  done
  return 1
}

# The cmux-next same-tree check (path routing): looks for this checkout's tree
# once and never waits. Writes to GITHUB_OUTPUT (and prints) tree_key and
#   tree_state=ready       published: the tree jobs run in this run
#   tree_state=deferred    an artifacts run that can publish it is active; when
#                          it ends, scripts/ci/cmux_next_tree_notify.py starts
#                          the tree jobs (cmux-next same-tree mode)
#   tree_state=superseded  a push whose artifacts runs were cancelled or skipped
#                          while the branch moved on: nothing to test
#   tree_state=failed      nothing will publish it (tree_reason says why)
#   tree_state=skipped     CMUX_TUI_TREE_BASE_FALLBACK=1 and no tree in the
#                          history is published: the tree jobs do not run
# With CMUX_TUI_TREE_BASE_FALLBACK=1 a tree that is not ready is replaced by
# the newest published one in the history (resolve-newest-published): ready,
# with tree_fetch_key= for the tree jobs' CMUX_TUI_TREE_KEY.
# The publisher is CMUX_TUI_TREE_PUBLISHER_SHA's artifacts runs (push and
# dispatch). A pull request whose merge keeps the base's tree waits for the base
# push's runs. One with its own merge tree has no publisher (GitHub runs
# pull_request_target only from the default branch). Without
# CMUX_TUI_TREE_DISPATCH (cmux-next path routing, which is read-only) the probe
# waits up to CMUX_TUI_TREE_PUBLISHER_WAIT_SECONDS for a trusted publication.
# A scheduled DEV run (workflow_dispatch with no
# publisher SHA) looks once, read-only, for its push's run or a same-tree run
# and defers to it the same way. With
# CMUX_TUI_TREE_DISPATCH=1 (same-repository PRs) only waits for a trusted
# publisher; it never creates a helper ref or dispatches a credentialed run.
# A missing or
# unreadable run list is re-checked once
# after CMUX_TUI_TREE_RECHECK_SECONDS (default 20): a push's runs can appear a
# moment after the push. A GitHub API rate limit is waited out within
# CMUX_TUI_TREE_RATE_LIMIT_WAIT_SECONDS (github_get); one that resets later
# defers (the publisher's end starts or fails the tree jobs), never fails.
# Exit 0 for every state.
probe_checkout_tree() {
  local key legacy publisher="${CMUX_TUI_TREE_PUBLISHER_SHA:-}"
  local base_key="" source="" state="" reason="" recheck="${CMUX_TUI_TREE_RECHECK_SECONDS:-20}" superseded=""
  local fetch_key="" resolved="" publisher_unknown=""
  key="$(tree_key HEAD)"
  legacy="$(legacy_tree_key HEAD)"
  [[ "$legacy" == "$key" ]] && legacy=""
  [[ "$recheck" =~ ^[0-9]+$ ]] || { echo "error: CMUX_TUI_TREE_RECHECK_SECONDS must be whole seconds" >&2; exit 2; }
  refuse_dirty_source
  # A pull request's synthetic merge tree is not published by an untrusted
  # pin branch; trusted feat-cmux-next publication is the safe path.
  pin_push_hint() {
    local sha
    sha="$(git -C "$repo_root" rev-parse HEAD)"
    printf 'This tree has no artifact yet; re-run after feat-cmux-next publishes it (or use a local build with CMUX_NEXT_TUI_BIN=<path>)'
  }
  probe_state() {
    if tree_published "$key" "$legacy"; then echo ready; return; fi
    case "$source" in
      commit:*) artifacts_runs_state_or_limited "${source#commit:}" ;;
      *) echo none ;;
    esac
  }
  if [[ -n "$publisher" ]]; then
    if [[ ! "$publisher" =~ ^[0-9a-f]{40}$ ]]; then
      reason="CMUX_TUI_TREE_PUBLISHER_SHA is not a 40-hex commit"
    elif [[ "$(tree_key "$publisher" 2>/dev/null)" != "$key" ]]; then
      reason="the publisher commit $publisher does not have tree $key"
    else
      source="commit:$publisher"
    fi
  elif base_key="$(pull_request_base_key 2>/dev/null)" && [[ "$base_key" == "$key" ]]; then
    source="commit:$(git -C "$repo_root" rev-parse HEAD^1)"
  elif [[ ("${GITHUB_EVENT_NAME:-}" == pull_request || "${GITHUB_EVENT_NAME:-}" == workflow_dispatch \
      || "${CMUX_TUI_TREE_DISPATCH:-}" == 1) ]] \
      && ! tree_published "$key" "$legacy"; then
    tree_publisher_sha=""
    if [[ "${CMUX_TUI_TREE_DISPATCH:-}" == 1 ]]; then
      ensure_tree_publisher "$key" "$(git -C "$repo_root" rev-parse HEAD)" "${CMUX_TUI_TREE_HEAD_SHA:-}"
    else
      # Read-only path routing starts nothing and waits for a trusted
      # publication. A scheduled DEV run (workflow_dispatch, no publisher SHA) defers the
      # same way to its push's artifacts run, or to the same-key run that push
      # run handed the build to (one look; dev-daily-tree-wait then waits).
      await_outside_publisher "$key" "$(git -C "$repo_root" rev-parse HEAD)"
    fi
    [[ -n "$tree_publisher_sha" ]] && source="commit:$tree_publisher_sha"
    [[ -z "$tree_publisher_sha" && "${tree_publisher_action:-}" == unknown ]] && publisher_unknown=1
  fi
  if [[ -n "$source" && -z "${GH_TOKEN:-}" ]]; then
    reason="no GH_TOKEN to read the cmux-tui artifacts runs"; source=""
  fi
  state="$(probe_state)"
  if [[ "$state" == none || "$state" == unknown ]] && [[ -n "$source" ]] && (( recheck > 0 )); then
    echo "cmux-tui artifacts runs for ${source#*:}: $state; checking once more in ${recheck}s" >&2
    sleep "$recheck"
    state="$(probe_state)"
  fi
  case "$state" in
    ready) reason="published" ;;
    active) state=deferred
      reason="an active cmux-tui artifacts run (${source#*:}) publishes tree $key; its publish starts the tree jobs" ;;
    ended\ *)
      superseded=""
      [[ "$source" == commit:* && -n "$publisher" ]] && superseded="$(superseded_by "$publisher" "$state")"
      if [[ -n "$superseded" ]]; then
        state=superseded
        reason="$(git -C "$repo_root" rev-parse HEAD) was superseded by $superseded on ${GITHUB_REF#refs/heads/}: its tree $key was not published, and the newer head is tested"
      else
        reason="the cmux-tui artifacts runs for ${source#*:} ended without publishing tree $key (${state#ended }). Re-run that run, or for an unmerged commit: $(pin_push_hint)"
        state=failed
      fi ;;
    none)
      if [[ -z "$source" && -n "$publisher_unknown" ]]; then
        # Fails open: the active runs could not all be compared in time, so a
        # same-tree publisher may exist. Deferred leaves the wait marker (and a
        # DEV run's dev-daily-tree-wait polls) instead of reporting a red.
        state=deferred
        reason="the active cmux-tui artifacts runs could not all be compared with tree $key in time (fetch budget or GitHub API), so one may be publishing it; its publish starts the tree jobs"
      elif [[ -z "$source" ]]; then
        reason="${reason:-no cmux-tui artifacts run can publish tree $key}. $(pin_push_hint)"
        state=failed
      else
        reason="no cmux-tui artifacts run exists for ${source#*:}, so nothing publishes tree $key. $(pin_push_hint)"
        state=failed
      fi ;;
    rate-limited)
      # Fails open, never red: the API refused the read for its rate limit and
      # resets after this check's wait (github_get above). The publisher's
      # artifacts run, when it ends, starts the tree jobs through the wait
      # marker (published) or reports the miss (cmux_next_tree_notify.py).
      state=deferred
      reason="the GitHub API rate limit refused reading the cmux-tui artifacts runs for ${source#*:} and resets after this check's wait, so this run does not wait for tree $key: its publisher's artifacts run starts the tree jobs when it publishes, or reports the miss when it ends without publishing" ;;
    *) state=failed
      reason="could not read the cmux-tui artifacts runs for ${source#*:} (GitHub API), so no publisher of tree $key is known; re-run this check" ;;
  esac
  # A pull request that changes no cmux-tui or ghostty-next path
  # (CMUX_TUI_TREE_BASE_FALLBACK=1 from path routing) is not held to its merge
  # tree: when that is not ready, its tree jobs run on the newest published
  # tree in its history, or are skipped when there is none. Never failed.
  if [[ "$state" != ready && "${CMUX_TUI_TREE_BASE_FALLBACK:-}" == 1 ]]; then
    if resolved="$(CMUX_TUI_TREE_DISPATCH='' GITHUB_STEP_SUMMARY='' resolve_newest_published_tree)"; then
      fetch_key="$(awk -F= '$1 == "key" { print $2 }' <<<"$resolved")"
      reason="this pull request changes no cmux-tui or ghostty-next path; its tree $key is $state, so the tree jobs use the newest published tree $fetch_key (from $(awk -F= '$1 == "source_commit" { print substr($2, 1, 12) }' <<<"$resolved"))"
      state=ready
    else
      reason="this pull request changes no cmux-tui or ghostty-next path, its tree $key is $state, and no tree in its recent history is published; the tree jobs are skipped"
      state=skipped
    fi
  fi
  if [[ "$state" != ready ]]; then
    report_tree_miss "$key"
    case "${tree_publisher_action:-none}:$state" in
      dispatched:*) echo "next: dispatching one cmux-tui-artifacts run for ${tree_publisher_sha:0:12} (CMUX_TUI_TREE_DISPATCH=1); its publish starts the tree jobs" >&2 ;;
      unknown:deferred) echo "next: tree_state=deferred; ${reason}" >&2 ;;
      *:deferred) echo "next: an artifacts run for this tree is active; its publish starts the tree jobs" >&2 ;;
      *) echo "next: tree_state=$state; ${reason}" >&2 ;;
    esac
  fi
  echo "cmux-tui tree $key: $state ($reason)"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "tree_key=$key"
      [[ -z "$fetch_key" ]] || echo "tree_fetch_key=$fetch_key"
      echo "tree_state=$state"
      echo "tree_reason=$(tr -d '\r\n' <<<"$reason")"
    } >> "$GITHUB_OUTPUT"
  fi
  return 0
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
  echo "resolved cmux-tui tree $(tree_source_label "$published_key" "$key")" >&2
  echo "$commit"
}

# Release and RC builds: the daemon of HEAD's own tree, waiting for its
# publication (bounded by CMUX_TUI_TREE_WAIT_SECONDS) like resolve-commit, in
# resolve-newest-published's output shape with source_commit=HEAD and behind=0.
# The publishing commit may be an older commit with the same tree key; its
# attested manifest carries the same cmux-tui sha256 (resolve_tree_commit checks).
resolve_exact_tree() {
  local out commit head tip_key
  head="$(git -C "$repo_root" rev-parse HEAD)"
  tip_key="$(tree_key HEAD)"
  out="$(mktemp "${TMPDIR:-/tmp}/cmux-tui-exact.XXXXXX")"
  # Same shell, not $(...): resolve_tree_commit sets published_key.
  resolve_tree_commit > "$out"
  commit="$(cat "$out")"
  rm -f "$out"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "error: resolve-commit printed no commit for ${head:0:12}" >&2; exit 1; }
  echo "resolved cmux-tui tree $published_key for ${head:0:12} itself; published by $commit" >&2
  printf 'commit=%s\nkey=%s\nsource_commit=%s\ntip_key=%s\nbehind=0\nbehind_hours=0\n' \
    "$commit" "$published_key" "$head" "$tip_key"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "### cmux-tui client"
      echo "- tree: \`$published_key\` (this commit's own tree)"
      echo "- build commit (app and daemon): \`$head\`"
      echo "- publishing commit (manifest sha256 verified): \`$commit\`"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
}

# verify_published_key <key> <temp dir>: whether tree <key> is published for
# $TARGET and verified: its sha256, the commit its source.json names, and that
# commit's attested manifest carrying the same sha256. Sets verified_commit,
# verified_sha and verified_manifest_sha. Returns 0 verified, 1 not published
# (no sha256; a failed read counts as not published), 2 published but
# unverifiable. resolve-newest-published and verify-key (the tree-commit
# marker writer, scripts/cmux-next/tree-commit-marker.sh) share it.
verify_published_key() {
  local key="$1" dir="$2"
  verified_commit="" verified_sha="" verified_manifest_sha=""
  # The query string bypasses a cached 404 at the CDN edge: the nightly's
  # second search follows a wait that saw this tree publish.
  download "$BASE/tree/$key/cmux-tui-$TARGET.sha256?t=$(date +%s)" "$dir/sha256" 2>/dev/null || return 1
  verified_sha="$(awk 'NR==1{print $1}' "$dir/sha256")"
  if [[ "$verified_sha" =~ ^[0-9a-f]{64}$ ]] \
    && download "$BASE/tree/$key/source.json" "$dir/source.json" 2>/dev/null; then
    verified_commit="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("commit") or "")' "$dir/source.json" 2>/dev/null || true)"
  fi
  if [[ "$verified_commit" =~ ^[0-9a-f]{40}$ ]] && download "$BASE/$verified_commit/manifest.json" "$dir/manifest.json" 2>/dev/null; then
    verified_manifest_sha="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["binaries"].get(sys.argv[2], ""))' "$dir/manifest.json" "cmux-tui-$TARGET" 2>/dev/null || true)"
  fi
  [[ -n "$verified_manifest_sha" && "$verified_manifest_sha" == "$verified_sha" ]] || return 2
}

# Prints commit=<publishing commit> for a verified published tree <key>
# (verify_published_key). Exit 1 only when the CDN answers 404 for its sha256
# (not published); 3 for anything else that is not a verified tree: a read
# that is neither 200 nor 404 (a read failure, never "not published") or a
# published tree whose manifest does not carry its sha256.
verify_key_command() {
  local key="${1:-}" dir rc=0
  [[ "$key" =~ ^[0-9a-f]{40}$ ]] || { echo "error: verify-key takes a 40-hex tree key" >&2; exit 2; }
  dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-tui-verify.XXXXXX")"
  verify_published_key "$key" "$dir" || rc=$?
  rm -rf "$dir"
  case "$rc" in
    0) echo "commit=$verified_commit" ;;
    1)
      # A 404 from a complete transfer only; a failed curl is a read failure.
      local code
      code="$(curl -sS --proto '=https' --connect-timeout 20 --max-time 60 -o /dev/null -w '%{http_code}' \
        "$BASE/tree/$key/cmux-tui-$TARGET.sha256?t=$(date +%s)" 2>/dev/null)" || code=000
      if [[ "$code" == 404 ]]; then echo "tree $key: not published" >&2; exit 1; fi
      echo "error: tree $key: could not read $BASE/tree/$key/cmux-tui-$TARGET.sha256 (HTTP ${code:-000}); a read failure, not \"not published\"" >&2
      exit 3 ;;
    *) echo "tree $key: published, but the manifest of ${verified_commit:-its commit} does not carry its sha256" >&2; exit 3 ;;
  esac
}

# The nightly's resolver: the newest commit within the last
# CMUX_TUI_TREE_SEARCH_COMMITS (default 50) commits of HEAD whose v2 tree is
# published and whose publishing commit's attested manifest carries the same
# cmux-tui sha256. It never waits: the tip's own tree may still be building
# (each feat-cmux-next push has its own cmux-tui-artifacts run since cx-73f2;
# before that a newer push replaced the pending run, nightly-next run 37464320457).
# Prints commit=, key=, source_commit= (the branch commit whose tree was
# used), tip_key=, behind= (commits) and behind_hours= lines, and appends them
# to GITHUB_STEP_SUMMARY. The nightly builds the app at source_commit, so app and
# daemon come from one commit. A tree more than CMUX_TUI_TREE_MAX_AGE_HOURS
# (default 24) behind the tip, or none in the window, fails: never ship stale.
# No commit needs a green "cmux-next Release compile (Xcode 26)": the nightly
# compiles the app at the resolved commit itself and publishes nothing when
# that fails, so the feed keeps its last good build (the same rule as the
# promote guard since #25786). Leo, 2026-10-26: "SKIP THE OLD FUCKING NIGHTLY
# BUILDS THEN WE'RE JSUT BUILDING FROM THE TIP" and "Just fucking compile on
# Linux." CMUX_TUI_TREE_REQUIRE_RELEASE_GREEN, which nightly.yml set to make a
# fallback commit wait for that Mac job, is ignored with a notice: nightly-next
# run 40427307041 failed here when the only published tree in the window,
# fb384d011b85's, had no such job. Every skipped commit and its reason is
# listed on a miss.
resolve_newest_published_tree() {
  local limit max_age temp_dir rev rev_time tip_time behind_hours key candidate commit vrc tip tip_key behind=0 checked=0 distinct=0
  local bad_keys=" " good_keys=" " skips=""
  local i same_path skewed skipped_skew=0 same_paths=() tip_blobs=()
  if [[ -n "${CMUX_TUI_TREE_REQUIRE_RELEASE_GREEN:-}" ]]; then
    echo "notice: CMUX_TUI_TREE_REQUIRE_RELEASE_GREEN is ignored: the nightly's own compile is the gate (#25786), so a published tree needs no Mac Release compile" >&2
  fi
  limit="${CMUX_TUI_TREE_SEARCH_COMMITS:-50}"
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || { echo "error: CMUX_TUI_TREE_SEARCH_COMMITS must be a positive whole number" >&2; exit 2; }
  limit=$((10#$limit))
  max_age="${CMUX_TUI_TREE_MAX_AGE_HOURS:-24}"
  [[ "$max_age" =~ ^[1-9][0-9]*$ ]] || { echo "error: CMUX_TUI_TREE_MAX_AGE_HOURS must be a positive whole number" >&2; exit 2; }
  max_age=$((10#$max_age))
  tip="$(git rev-parse HEAD)"
  tip_time="$(git log -1 --format=%ct HEAD)"
  tip_key="$(tree_key HEAD 2>/dev/null || true)"
  # Never waits, but starts the tip's publisher when nothing publishes it, so
  # the next nightly can build the tip (CMUX_TUI_TREE_DISPATCH=1).
  if [[ "${CMUX_TUI_TREE_DISPATCH:-}" == 1 && -n "$tip_key" ]] && ! tree_published "$tip_key"; then
    ensure_tree_publisher "$tip_key" "$tip"
  fi
  # The nightly runs the TIP's workflow but checks out the resolved commit, so
  # that commit must carry the tip's copy of these paths (the workflow file):
  # otherwise the workflow calls scripts the build commit does not have.
  read -r -a same_paths <<<"${CMUX_TUI_TREE_SAME_PATHS:-}"
  for same_path in ${same_paths[@]+"${same_paths[@]}"}; do
    tip_blobs+=("$(git rev-parse -q --verify "HEAD:$same_path" 2>/dev/null || echo missing)")
  done
  # A depth-1 CI checkout holds no window; deepen once (best effort). Only
  # this commit's history: a bare `fetch --deepen` deepens every branch of
  # origin, which outlasted path routing's 5 minutes (#18698).
  if [[ "$(git rev-parse --is-shallow-repository)" == true ]] && (( $(git rev-list --count HEAD) < limit )); then
    git fetch -q --no-tags --deepen="$limit" origin "$tip" 2>/dev/null \
      || echo "warning: could not deepen the shallow checkout; searching the history it has" >&2
  fi
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-tui-tree.XXXXXX")"
  # shellcheck disable=SC2064 # expand now: the trap must remove this temp dir
  trap "rm -rf '$temp_dir'" EXIT
  # Commit-date order covers both parents of a merge (a safe-push auto-merge
  # puts the previous branch tip on the second parent).
  while read -r rev; do
    checked=$((checked + 1))
    rev_time="$(git log -1 --format=%ct "$rev")"
    behind_hours=$(( (tip_time - rev_time) / 3600 ))
    (( behind_hours < 0 )) && behind_hours=0
    if (( tip_time - rev_time > max_age * 3600 )); then
      echo "error: no published cmux-tui tree within ${max_age} h of the tip ${tip:0:12}: the newest candidate left, ${rev:0:12}, is ${behind_hours} h behind the tip (bound ${max_age} h, ${behind} commits). The nightly does not ship a stale build; publish a newer cmux-tui tree (pin-cmux-tui.sh --help)." >&2
      [[ -z "$skips" ]] || printf 'skipped commits, newest first:\n%s' "$skips" >&2
      exit 1
    fi
    skewed=""
    for ((i = 0; i < ${#tip_blobs[@]}; i++)); do
      if [[ "$(git rev-parse -q --verify "$rev:${same_paths[$i]}" 2>/dev/null || echo missing)" != "${tip_blobs[$i]}" ]]; then
        skewed="${same_paths[$i]}"; break
      fi
    done
    if [[ -n "$skewed" ]]; then
      echo "commit ${rev:0:12}: $skewed differs from the tip ${tip:0:12}; the tip's workflow cannot build it, skipping" >&2
      skips+="  ${rev:0:12}: $skewed differs from the tip"$'\n'
      skipped_skew=$((skipped_skew + 1)); behind=$((behind + 1)); continue
    fi
    key="$(tree_key "$rev" 2>/dev/null)" || { skips+="  ${rev:0:12}: no tree key"$'\n'; behind=$((behind + 1)); continue; }
    # The v2 key first, then this commit's compatibility keys (v2-legacy, v1):
    # trees published before docs-only filtering exist only under those, and
    # they stay valid fallbacks for the nightly. key becomes the key actually
    # published, as fetch and resolve-commit report it.
    commit=""
    for candidate in "$key" $(legacy_tree_key "$rev"); do
      [[ "$candidate" =~ ^[0-9a-f]{40}$ ]] || continue
      [[ "$bad_keys" == *" $candidate "* ]] && continue
      # A verified tree is checked once.
      commit="$(tr ' ' '\n' <<<"$good_keys" | awk -F= -v k="$candidate" '$1 == k { print $2; exit }')"
      [[ -n "$commit" ]] && { key="$candidate"; break; }
      distinct=$((distinct + 1))
      vrc=0
      verify_published_key "$candidate" "$temp_dir" || vrc=$?
      if (( vrc == 1 )); then
        echo "tree $candidate (${rev:0:12}): not published" >&2
        bad_keys+="$candidate "; continue
      fi
      if (( vrc != 0 )); then
        echo "warning: tree $candidate (${rev:0:12}) is published, but the manifest of its commit ${verified_commit:0:12} does not carry its sha256 ${verified_sha:0:12} (manifest: ${verified_manifest_sha:-none}); skipping" >&2
        skips+="  ${rev:0:12}: tree ${candidate:0:12} unverifiable (manifest sha256 mismatch)"$'\n'
        bad_keys+="$candidate "; continue
      fi
      commit="$verified_commit"
      good_keys+="$candidate=$commit "
      key="$candidate"; break
    done
    if [[ -z "$commit" ]]; then
      skips+="  ${rev:0:12}: tree ${key:0:12} not published or unverifiable"$'\n'; behind=$((behind + 1)); continue
    fi
    echo "resolved cmux-tui tree $key from ${rev:0:12} ($behind commits and $behind_hours h behind the tip ${tip:0:12}, tip tree ${tip_key:-unknown}); published by $commit" >&2
    printf 'commit=%s\nkey=%s\nsource_commit=%s\ntip_key=%s\nbehind=%s\nbehind_hours=%s\n' "$commit" "$key" "$rev" "$tip_key" "$behind" "$behind_hours"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      {
        echo "### cmux-tui client"
        echo "- tree: \`$key\` (tip tree \`${tip_key:-unknown}\`)"
        echo "- build commit (app and daemon): \`$rev\` ($behind commits and $behind_hours h behind the tip \`$tip\`)"
        echo "- publishing commit (manifest sha256 verified): \`$commit\`"
      } >> "$GITHUB_STEP_SUMMARY"
    fi
    return 0
  done < <(git rev-list --date-order --max-count="$limit" HEAD)
  echo "error: no published cmux-tui tree in the last $limit commits of ${tip:0:12} ($checked checked, $distinct distinct trees, $skipped_skew skipped because ${CMUX_TUI_TREE_SAME_PATHS:-no path} differs from the tip): no commit there has a tree under $BASE/tree/<key>/ whose publishing commit's manifest sha256 matches. Publish one (pin-cmux-tui.sh --help) or raise CMUX_TUI_TREE_SEARCH_COMMITS." >&2
  [[ -z "$skips" ]] || printf 'skipped commits, newest first:\n%s' "$skips" >&2
  exit 1
}

# resolve-newest-published as the nightly runs it: the search above, and on a miss
# one bounded wait for the publisher of the TIP's own tree, then the search again.
# A promotion can move nightly-next to a commit whose tree is still being built
# by a same-key run (nightly-next run 40445128409 missed tree bf6faf9c692f of
# 5d81874b330a, which owner run 40444370171 was building, and every older commit
# carried a different nightly.yml). A hit never waits. The wait is
# CMUX_TUI_TREE_TIP_WAIT_SECONDS: by default 3000 in nightly.yml (inside the
# resolver job's 75 min) and 0 everywhere else, so request-nightly-next.sh and
# the media workflow still look once. It runs only while a cmux-tui artifacts
# run for the tip, or an active run of the same tree, exists; it fails at once
# when none does (this job holds actions: read, so it starts no publisher), when
# the publisher ends without publishing, or when the bound is hit.
resolve_newest_published_or_await_tip() {
  local wait_seconds rc=0 tip key state sha_file
  if [[ "${GITHUB_WORKFLOW_REF:-}" == */.github/workflows/nightly.yml@* ]]; then
    wait_seconds="${CMUX_TUI_TREE_TIP_WAIT_SECONDS:-3000}"
  else
    wait_seconds="${CMUX_TUI_TREE_TIP_WAIT_SECONDS:-0}"
  fi
  [[ "$wait_seconds" =~ ^[0-9]+$ ]] || { echo "error: CMUX_TUI_TREE_TIP_WAIT_SECONDS must be whole seconds" >&2; exit 2; }
  if (( wait_seconds == 0 )); then resolve_newest_published_tree; return 0; fi
  sha_file="$(mktemp "${TMPDIR:-/tmp}/cmux-tui-resolve.XXXXXX")"
  # A subshell with errexit of its own: the search exits on a miss.
  set +e
  (set -e; resolve_newest_published_tree) > "$sha_file"
  rc=$?
  set -e
  if (( rc == 0 )); then cat "$sha_file"; rm -f "$sha_file"; return 0; fi
  rm -f "$sha_file"
  (( rc == 1 )) || exit "$rc"
  tip="$(git -C "$repo_root" rev-parse HEAD)"
  key="$(tree_key HEAD)" || { echo "error: cannot compute the tree key of the tip ${tip:0:12}" >&2; exit 1; }
  if ! tree_published "$key"; then
    state="$(artifacts_runs_state "$tip")"
    # Fail fast only on a confirmed miss: the tip's runs read and none active, and
    # the recent runs list read with no same-tree run. An unreadable list waits.
    if [[ "$state" != active && "$state" != unknown && -z "$(active_publisher_for_key "$key")" ]]; then
      {
        echo "error: the tip ${tip:0:12}'s cmux-tui tree $key is not published and no cmux-tui artifacts run is publishing it, so the nightly has nothing to wait for."
        case "$state" in
          none) echo "  No cmux-tui artifacts run exists for $tip." ;;
          *) echo "  Its runs ended without publishing it: ${state#ended }." ;;
        esac
        echo "  This job holds actions: read only and starts no publisher. Start one, then re-run this nightly:"
        echo "    gh workflow run cmux-tui-artifacts.yml --repo ${GITHUB_REPOSITORY:-manaflow-ai/cmux} --ref feat-cmux-next"
        echo "  (or re-run the failed artifacts run for $tip)."
      } >&2
      exit 1
    fi
    echo "no older commit can be built; waiting up to ${wait_seconds}s for the publisher of the tip ${tip:0:12}'s tree $key (artifacts runs: $state)" >&2
    sha_file="$(mktemp "${TMPDIR:-/tmp}/cmux-tui-tip.XXXXXX")"
    CMUX_TUI_TREE_WAIT_SECONDS="$wait_seconds" CMUX_TUI_TREE_PUBLISHER_SHA="$tip" CMUX_TUI_TREE_DISPATCH="" \
      wait_for_tree "$key" "$sha_file" ""
    rm -f "$sha_file"
  fi
  echo "the tip's tree $key is published; resolving again" >&2
  resolve_newest_published_tree
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
    [[ "$mode" == tree ]] && TARGET="$(host_tree_target)"
    if [[ "$mode" == tree ]]; then fetch_tree; else fetch_pin; fi
    ;;
  fetch-acpmux)
    [[ $# -eq 0 ]] || { echo "error: fetch-acpmux does not accept pin mode" >&2; exit 2; }
    fetch_tree_acpmux
    ;;
  path)
    mode_from_args "$@"
    [[ "$mode" == tree ]] && TARGET="$(host_tree_target)"
    if [[ "$mode" == tree ]]; then
      echo "$(tree_dir "$(checkout_tree_key)")/$(tree_binary_file)"
    else
      read_pin
      echo "$repo_root/cmux-tui/target/hosted/$pin_commit/cmux-tui"
    fi
    ;;
  app-host-path)
    mode_from_args "$@"
    [[ "$mode" == tree ]] && TARGET="$(host_tree_target)"
    if [[ "$mode" == tree ]]; then
      echo "$(tree_dir "$(checkout_tree_key)")/cmux-app-host"
    else
      read_pin
      echo "$repo_root/cmux-tui/target/hosted/$pin_commit/cmux-app-host"
    fi
    ;;
  cloud-server-path)
    mode_from_args "$@"
    [[ "$mode" == tree ]] && TARGET="$(host_tree_target)"
    if [[ "$mode" == tree ]]; then
      echo "$(tree_dir "$(checkout_tree_key)")/cmux-cloud"
    else
      read_pin
      echo "$repo_root/cmux-tui/target/hosted/$pin_commit/cmux-cloud"
    fi
    ;;
  acpmux-path)
    # Tree mode only: a pin fetch brings no acpmux.
    TARGET="$(host_tree_target)"
    echo "$(tree_dir "$(checkout_tree_key)")/acpmux"
    ;;
  browser-host-path)
    mode_from_args "$@"
    [[ "$mode" == tree ]] && TARGET="$(host_tree_target)"
    if [[ "$mode" == tree ]]; then
      echo "$(tree_dir "$(checkout_tree_key)")/cmux-browser-host"
    else
      read_pin
      echo "$repo_root/cmux-tui/target/hosted/$pin_commit/cmux-browser-host"
    fi
    ;;
  resolve-commit)
    resolve_tree_commit
    ;;
  resolve-newest-published)
    resolve_newest_published_or_await_tip
    ;;
  verify-key)
    verify_key_command "${1:-}"
    ;;
  runs-state)
    [[ "${1:-}" =~ ^[0-9a-f]{40}$ ]] || { echo "error: runs-state takes a 40-hex commit" >&2; exit 2; }
    artifacts_runs_state "$1"
    ;;
  active-publisher)
    [[ "${1:-}" =~ ^[0-9a-f]{40}$ ]] || { echo "error: active-publisher takes a 40-hex tree key" >&2; exit 2; }
    active_publisher_for_key "$1"
    ;;
  resolve-exact)
    resolve_exact_tree
    ;;
  fallback-key)
    # A head that changes no tree input (its key equals its base's) tests the
    # same cmux-tui as that base, so an older published tree stands in for an
    # unpublished one. A commit on the base compares with its first parent.
    # Fleet steps check out the ref at depth 1 with no branch refs: fetch the
    # base and deepen both to CMUX_TUI_TREE_SEARCH_COMMITS so the merge base,
    # the parent and the published tree's commit are in the history.
    # The fleet worker's checkout is a git init fetched from the repository URL,
    # with no origin remote: fetch from CMUX_TUI_TREE_FALLBACK_REMOTE then.
    fallback_base="${CMUX_TUI_TREE_FALLBACK_BASE:-origin/feat-cmux-next}"
    fallback_depth="${CMUX_TUI_TREE_SEARCH_COMMITS:-50}"
    fallback_remote=origin
    git -C "$repo_root" remote get-url origin >/dev/null 2>&1 \
      || fallback_remote="${CMUX_TUI_TREE_FALLBACK_REMOTE:-https://github.com/manaflow-ai/cmux.git}"
    fallback_refs=()
    if [[ "$fallback_base" == origin/* ]] \
        && ! git -C "$repo_root" rev-parse -q --verify "$fallback_base^{commit}" >/dev/null; then
      fallback_refs+=("+refs/heads/${fallback_base#origin/}:refs/remotes/$fallback_base")
    fi
    if [[ "$(git -C "$repo_root" rev-parse --is-shallow-repository)" == true ]]; then
      fallback_refs+=("$(git -C "$repo_root" rev-parse HEAD)")
      [[ -z "$(git -C "$repo_root" rev-parse -q --verify "$fallback_base^{commit}")" ]] \
        || fallback_refs+=("+refs/heads/${fallback_base#origin/}:refs/remotes/$fallback_base")
      git -C "$repo_root" fetch -q --no-tags --depth="$fallback_depth" "$fallback_remote" "${fallback_refs[@]}" \
        || echo "fallback-key: could not deepen the shallow checkout; using the history it has" >&2
    elif (( ${#fallback_refs[@]} )); then
      git -C "$repo_root" fetch -q --no-tags "$fallback_remote" "${fallback_refs[@]}" \
        || echo "fallback-key: could not fetch $fallback_base" >&2
    fi
    if ! fallback_rev="$(git -C "$repo_root" merge-base HEAD "$fallback_base" 2>/dev/null)"; then
      echo "fallback-key: no merge base of HEAD and $fallback_base in the last $fallback_depth commits" >&2
      exit 1
    fi
    if [[ "$fallback_rev" == "$(git -C "$repo_root" rev-parse HEAD)" ]] \
        && ! fallback_rev="$(git -C "$repo_root" rev-parse -q --verify HEAD^1)"; then
      echo "fallback-key: HEAD is on $fallback_base and its parent is not in the checkout" >&2
      exit 1
    fi
    if [[ "$(tree_key HEAD)" != "$(tree_key "$fallback_rev")" ]]; then
      echo "fallback-key: HEAD changes a cmux-tui tree input since ${fallback_rev:0:12}; no fallback tree" >&2
      exit 1
    fi
    resolved="$(CMUX_TUI_TREE_DISPATCH='' GITHUB_STEP_SUMMARY='' resolve_newest_published_tree)" || exit 1
    awk -F= '$1 == "key" { print $2 }' <<<"$resolved" | grep .
    ;;
  wait)
    wait_for_checkout_tree
    ;;
  probe)
    probe_checkout_tree
    ;;
  local-build)
    local_build_matches "${1:-}"
    ;;
  key)
    rev=""
    version=v2
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --rev) rev="${2:?--rev needs a revision}"; shift 2 ;;
        --version) version="${2:?--version needs v1 or v2}"; shift 2 ;;
        *) usage >&2; exit 2 ;;
      esac
    done
    if [[ -z "$rev" && "$version" == v2 ]]; then checkout_tree_key; exit 0; fi
    python3 "$repo_root/scripts/ci/cmux_tui_tree_key.py" --version "$version" "${rev:-HEAD}"
    ;;
  show)
    read_pin
    echo "tree key=$(tree_key HEAD) url=$BASE/tree/$(tree_key HEAD)/cmux-tui-$TARGET"
    echo "pin commit=$pin_commit run=$pin_run sha256=$pin_sha256 url=$pin_url"
    ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
