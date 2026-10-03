#!/usr/bin/env bash
# Fetch the hosted macOS arm64 cmux-tui that the cmux-next app bundles.
#
# Two modes. Dogfood, tagged, fleet and nightly builds use tree mode; only
# release and RC builds use the pin.
#
# tree (default): the daemon built from this checkout's own cmux-tui source.
#   The key is a git tree hash of the binary's source inputs, the cmux-tui
#   tree and the ghostty gitlink (`pin-cmux-tui.sh key`):
#     printf '040000 tree %s\tcmux-tui\n160000 commit %s\tghostty\n' \
#       "$(git rev-parse HEAD:cmux-tui)" "$(git rev-parse HEAD:ghostty)" | git mktree --missing
#   The `cmux-tui artifacts` workflow runs on every push to feat-cmux-next,
#   feat-cmux-next-acpmux and cmux-tui-pin-* that touches cmux-tui or ghostty.
#   After the hosted build and the cmux_next_ daemon tests pass on that commit,
#   it publishes https://files.cmux.com/cmux-tui/tree/<key>/ with
#   cmux-tui-aarch64-apple-darwin, cmux-tui-aarch64-apple-darwin.sha256 and
#   source.json (the commit and run that built it). `fetch` downloads it to
#   cmux-tui/target/hosted/tree/<key>/cmux-tui and checks the published
#   sha256. When the key is not published yet it waits, printing progress, up
#   to CMUX_TUI_TREE_WAIT_SECONDS (default 2700), then fails. It never falls
#   back to another binary. To publish the tree of an unmerged branch:
#     git push origin HEAD:refs/heads/cmux-tui-pin-<short-sha>
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
#        (the push runs the artifacts workflow).
#     3. ./scripts/cmux-next/pin-cmux-tui.sh pin --commit <sha> --verified-run <run-id>
#     4. Commit scripts/cmux-next/cmux-tui.pin; delete the helper branch.
#
# No mode needs GitHub credentials: downloads are public and sha256-checked.
#
# Usage: pin-cmux-tui.sh fetch [--tree|--pin] | path [--tree|--pin] | key [--rev <rev>]
#        | resolve-commit (the commit that published this tree, for nightly)
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
}

# Downloads $1 to $2 with retries; never follows to a non-HTTPS URL.
download() {
  curl -fsSL --proto '=https' --retry 4 --retry-delay 2 --connect-timeout 20 --max-time 600 -o "$2" "$1"
}

# The tree key of <rev> (default HEAD): the git tree hash of {cmux-tui tree,
# ghostty gitlink}, the binary's source inputs.
tree_key() {
  local rev="${1:-HEAD}" tui ghostty
  tui="$(git -C "$repo_root" rev-parse --verify -q "$rev:cmux-tui")" || {
    echo "error: $rev has no cmux-tui tree" >&2; return 1; }
  ghostty="$(git -C "$repo_root" rev-parse --verify -q "$rev:ghostty")" || {
    echo "error: $rev has no ghostty gitlink" >&2; return 1; }
  printf '040000 tree %s\tcmux-tui\n160000 commit %s\tghostty\n' "$tui" "$ghostty" \
    | git -C "$repo_root" mktree --missing
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
  dirty="$(git -C "$repo_root" status --porcelain --ignore-submodules=dirty -- cmux-tui ghostty 2>/dev/null || true)"
  [[ -z "$dirty" ]] && return 0
  {
    echo "error: uncommitted cmux-tui source changes are not in any published cmux-tui binary:"
    printf '%s\n' "$dirty" | head -n 20 | sed 's/^/  /'
    echo "  Commit and push them (see --help to publish the tree), bundle a local build with"
    echo "  CMUX_NEXT_TUI_BIN=<path>, or set CMUX_NEXT_TUI_ALLOW_DIRTY=1 to bundle the committed tree."
  } >&2
  exit 1
}

# Downloads the published sha256 file of tree <key> to <file>, waiting up to
# CMUX_TUI_TREE_WAIT_SECONDS while the artifacts workflow publishes it.
wait_for_tree() {
  local key="$1" out="$2" sha_url wait_seconds poll_seconds started elapsed
  sha_url="$BASE/tree/$key/cmux-tui-$TARGET.sha256"
  wait_seconds="${CMUX_TUI_TREE_WAIT_SECONDS:-2700}"
  poll_seconds="${CMUX_TUI_TREE_POLL_SECONDS:-30}"
  [[ "$wait_seconds" =~ ^[0-9]+$ && "$poll_seconds" =~ ^[1-9][0-9]*$ ]] || {
    echo "error: CMUX_TUI_TREE_WAIT_SECONDS and CMUX_TUI_TREE_POLL_SECONDS must be whole seconds" >&2; exit 2; }
  started="$(date +%s)"
  # The query string bypasses a cached 404 at the CDN edge.
  until curl -fsSL --proto '=https' --connect-timeout 20 --max-time 60 -o "$out" "$sha_url?t=$(date +%s)" 2>/dev/null; do
    elapsed=$(( $(date +%s) - started ))
    if (( elapsed >= wait_seconds )); then
      {
        echo "error: cmux-tui for this checkout's tree $key is not published after $((elapsed / 60)) min ($sha_url)."
        echo "  The cmux-tui artifacts workflow publishes a tree after its build and cmux_next_ daemon tests pass"
        echo "  on a pushed commit of feat-cmux-next, feat-cmux-next-acpmux or cmux-tui-pin-*."
        echo "  Check its runs: https://github.com/manaflow-ai/cmux/actions/workflows/cmux-tui-artifacts.yml"
        echo "  For an unmerged branch: git push origin HEAD:refs/heads/cmux-tui-pin-$(git -C "$repo_root" rev-parse --short=12 HEAD)"
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

# On a developer checkout, waiting is pointless when the last commit that
# changed the binary's inputs is on no remote branch: nothing will publish
# it. CI and fleet checkouts may lack remote-tracking refs, so they wait.
refuse_unpushed_source() {
  [[ -n "${GITHUB_ACTIONS:-}" || -n "${CI_JOB_DIR:-}" ]] && return 0
  [[ "$(git -C "$repo_root" rev-parse --is-shallow-repository 2>/dev/null)" == false ]] || return 0
  [[ -n "$(git -C "$repo_root" for-each-ref --count=1 refs/remotes 2>/dev/null)" ]] || return 0
  local last
  last="$(git -C "$repo_root" rev-list -1 HEAD -- cmux-tui ghostty 2>/dev/null)" || return 0
  [[ -n "$last" ]] || return 0
  [[ -n "$(git -C "$repo_root" branch -r --contains "$last" 2>/dev/null | head -n 1)" ]] && return 0
  {
    echo "error: commit $last, the last change to cmux-tui or ghostty here, is on no remote branch,"
    echo "  so no workflow will publish its cmux-tui. Push it (to feat-cmux-next, feat-cmux-next-acpmux or"
    echo "  cmux-tui-pin-<short-sha>), or bundle a local build with CMUX_NEXT_TUI_BIN=<path>."
  } >&2
  exit 1
}

fetch_tree() {
  local key dir binary url actual temp_dir
  key="$(tree_key HEAD)"
  refuse_dirty_source
  dir="$(tree_dir "$key")"
  binary="$dir/cmux-tui"
  if [[ -f "$binary" && -f "$dir/cmux-tui.sha256" && "$(sha256_of "$binary")" == "$(cat "$dir/cmux-tui.sha256")" ]]; then
    echo "same-tree cmux-tui $key already present: $binary"
    return 0
  fi
  url="$BASE/tree/$key/cmux-tui-$TARGET"
  mkdir -p "$dir"
  temp_dir="$(mktemp -d "$dir/.fetch.XXXXXX")"
  # shellcheck disable=SC2064 # expand now: the trap must remove this temp dir
  trap "rm -rf '$temp_dir'" EXIT
  refuse_unpushed_source
  wait_for_tree "$key" "$temp_dir/sha256"
  download "$url" "$temp_dir/cmux-tui" || { echo "error: could not download $url" >&2; exit 1; }
  actual="$(sha256_of "$temp_dir/cmux-tui")"
  [[ "$actual" == "$published" ]] || { echo "error: $url has sha256 $actual, but $url.sha256 publishes $published" >&2; exit 1; }
  download "$BASE/tree/$key/source.json" "$temp_dir/source.json" 2>/dev/null || echo '{}' > "$temp_dir/source.json"
  chmod 755 "$temp_dir/cmux-tui"
  # Rename into place: a rewritten Mach-O keeps a stale code signature.
  mv -f "$temp_dir/source.json" "$dir/source.json"
  mv -f "$temp_dir/cmux-tui" "$binary"
  printf '%s\n' "$published" > "$dir/cmux-tui.sha256"
  echo "fetched same-tree cmux-tui $key to $binary"
}

# Prints the commit whose attested commit-addressed artifacts carry this
# checkout's tree binary (nightly installs that commit's universal client).
resolve_tree_commit() {
  local key temp_dir commit manifest_sha
  key="$(tree_key HEAD)"
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-tui-tree.XXXXXX")"
  # shellcheck disable=SC2064 # expand now: the trap must remove this temp dir
  trap "rm -rf '$temp_dir'" EXIT
  wait_for_tree "$key" "$temp_dir/sha256"
  download "$BASE/tree/$key/source.json" "$temp_dir/source.json" || {
    echo "error: $BASE/tree/$key/source.json is missing" >&2; exit 1; }
  commit="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("commit") or "")' "$temp_dir/source.json")"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "error: tree $key names no source commit" >&2; exit 1; }
  download "$BASE/$commit/manifest.json" "$temp_dir/manifest.json" || {
    echo "error: $BASE/$commit/manifest.json is missing" >&2; exit 1; }
  manifest_sha="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["binaries"].get(sys.argv[2], ""))' "$temp_dir/manifest.json" "cmux-tui-$TARGET")"
  [[ "$manifest_sha" == "$published" ]] || {
    echo "error: commit $commit published cmux-tui-$TARGET $manifest_sha, not tree $key's $published" >&2; exit 1; }
  echo "$commit"
}

fetch_pin() {
  read_pin
  local dir binary temp actual
  dir="$repo_root/cmux-tui/target/hosted/$pin_commit"
  binary="$dir/cmux-tui"
  if [[ -f "$binary" && "$(sha256_of "$binary")" == "$pin_sha256" ]]; then
    echo "pinned cmux-tui ${pin_commit:0:12} already present: $binary"
    return 0
  fi
  mkdir -p "$dir"
  temp="$(mktemp "$dir/.cmux-tui.XXXXXX")"
  # shellcheck disable=SC2064 # expand now: the trap must remove this temp file
  trap "rm -f '$temp'" EXIT
  if ! download "$pin_url" "$temp"; then
    echo "error: could not download the pinned cmux-tui from $pin_url" >&2
    exit 1
  fi
  actual="$(sha256_of "$temp")"
  if [[ "$actual" != "$pin_sha256" ]]; then
    echo "error: $pin_url has sha256 $actual, but $pin_file pins $pin_sha256" >&2
    exit 1
  fi
  chmod 755 "$temp"
  # Rename into place: a rewritten Mach-O keeps a stale code signature.
  mv -f "$temp" "$binary"
  echo "fetched pinned cmux-tui ${pin_commit:0:12} to $binary"
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
    read -r manifest_commit sha256 run < <(python3 - "$temp_dir/manifest.json" "cmux-tui-$TARGET" <<'PY'
import json, re, sys
m = json.load(open(sys.argv[1]))
run = re.search(r"/actions/runs/(\d+)", m.get("attestationUrl") or "")
print(m.get("sourceCommit", ""), m.get("binaries", {}).get(sys.argv[2], ""), run.group(1) if run else "")
PY
)
    [[ "$manifest_commit" == "$commit" && "$sha256" =~ ^[0-9a-f]{64}$ ]] || {
      echo "error: $manifest_url does not describe cmux-tui-$TARGET for $commit" >&2; exit 1; }
    url="$BASE/$commit/cmux-tui-$TARGET"
    download "$url" "$temp_dir/cmux-tui"
    [[ "$(sha256_of "$temp_dir/cmux-tui")" == "$sha256" ]] || { echo "error: $url does not match its manifest" >&2; exit 1; }
    chmod 755 "$temp_dir/cmux-tui"
    version="$("$temp_dir/cmux-tui" --version 2>/dev/null | head -n 1 || true)"
    [[ "$version" == *"${commit:0:7}"* ]] || { echo "error: $url reports '$version', not commit $commit" >&2; exit 1; }
    {
      echo "# Hosted cmux-tui that release and RC builds bundle (dogfood builds use the same-tree binary). Refresh: scripts/cmux-next/pin-cmux-tui.sh --help"
      echo "commit=$commit"
      echo "url=$url"
      echo "run=$run"
      [[ -n "$verified_run" ]] && echo "verified_run=$verified_run"
      echo "sha256=$sha256"
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
  resolve-commit)
    resolve_tree_commit
    ;;
  key)
    rev=HEAD
    if [[ "${1:-}" == --rev ]]; then rev="${2:?--rev needs a revision}"; fi
    tree_key "$rev"
    ;;
  show)
    read_pin
    echo "tree key=$(tree_key HEAD) url=$BASE/tree/$(tree_key HEAD)/cmux-tui-$TARGET"
    echo "pin commit=$pin_commit run=$pin_run sha256=$pin_sha256 url=$pin_url"
    ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
