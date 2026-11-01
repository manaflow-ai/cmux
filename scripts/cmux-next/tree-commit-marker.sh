#!/usr/bin/env bash
# The tree-commit marker: one public, write-once object per feat-cmux-next
# commit saying its cmux-tui tree is published and verified, so main's promote
# guard (scripts/ci/promote-nightly-next.mjs) and request-nightly-next.sh can
# check a commit without the tree key algorithm, which main does not have, and
# without a GitHub API call.
#
# Since 2026-10-28 the marker does not wait for the tree's daemon tests. They
# still run after the publish and report their result, and the feat-cmux-next
# channel (scripts/ci/cmux-tui-point-channel.sh) still follows only
# daemon-tested trees, but no nightly waits on them. A Zig package download
# failure in those tests (run 40651931144) left 60 commits unmarked and held a
# launch-crash fix off the nightly feed. Leo, 2026-10-23: "we want no smoke
# tests".
#
# Contract (readers must keep to it):
#   GET https://files.cmux.com/cmux-tui/tree-commits/<sha40>.json?t=<now>
#     (the query string bypasses a cached 404 at the CDN edge)
#   200 with JSON {"commit": "<sha40>", "key": "<v2 tree key>",
#     "publishedBy": "<sha40>", "markedBy": "<run url>"}, every field present
#     and well formed, and commit == <sha40>: ready. 404: not ready (not marked yet). Anything else (another status, a
#     network error, a body that does not parse or names another commit): a
#     read failure, never "not ready"; callers fail closed and say so.
#   Written write-once by cmux-tui-artifacts.yml (mark-tree-commits) on every
#   feat-cmux-next push or dispatch run whose tree is published, for each
#   first-parent commit in the last 40 of the run's commit (the run's own
#   included) whose tree is ready, and for the same window
#   from the branch tip: a run that publishes a tree late (a takeover after the
#   owner's publish failed) marks the newer commits that share it, whose own
#   runs found it unpublished and ended (the 2026-10-28 promote waited on them).
#   Backfill: gh workflow run cmux-tui-artifacts.yml -R manaflow-ai/cmux --ref feat-cmux-next
#
# Usage:
#   tree-commit-marker.sh check <sha>       exit 0 marked (prints key=), 1 not marked, 3 read failure
#   tree-commit-marker.sh daemon-tested <key>
#                                            exit 0 when the tree's daemon tests passed (or it
#                                            predates separate daemon tests), 1 not yet, 3 read
#                                            failure; not part of tree-ready
#   tree-commit-marker.sh tree-ready <key>   exit 0 published and verified (prints publishedBy=),
#                                            1 not (a 404), 3 a read failure or an unverifiable
#                                            tree
#   tree-commit-marker.sh write [--window N] [--tip-branch B]
#                                            marks HEAD and its first-parent ancestors (default
#                                            40) whose tree is ready, and with --tip-branch the
#                                            same window from origin's B too (later commits that
#                                            share a tree this run just published); needs
#                                            R2_ENDPOINT and the R2 AWS_* credentials
# Env: CMUX_TUI_PIN_BASE (default https://files.cmux.com/cmux-tui).
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
base="${CMUX_TUI_PIN_BASE:-https://files.cmux.com/cmux-tui}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tree-commit-marker.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# http_get <url> <out>: prints the HTTP status of a complete transfer, 000
# when no response came or curl failed (a truncated or timed-out transfer can
# carry a 200 or a 404 status: it is a read failure, never ready or missing).
http_get() {
  local code rc=0
  code="$(curl -sS --proto '=https' --connect-timeout 20 --max-time 60 --retry 2 --retry-delay 2 \
    -o "$2" -w '%{http_code}' "$1" 2>/dev/null)" || rc=$?
  if (( rc != 0 )); then echo 000; else echo "${code:-000}"; fi
}

check() { # <sha>
  local sha="$1" code url
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "error: check takes a 40-hex commit" >&2; exit 2; }
  url="$base/tree-commits/$sha.json"
  code="$(http_get "$url?t=$(date +%s)" "$tmp/marker.json")"
  case "$code" in
    200) ;;
    404) echo "no tree-commit marker for $sha ($url)" >&2; return 1 ;;
    *) echo "error: could not read the tree-commit marker $url (HTTP ${code:-000})" >&2; return 3 ;;
  esac
  python3 - "$sha" "$tmp/marker.json" <<'PY' || { echo "error: the tree-commit marker $url is not a marker of $sha (commit, key, publishedBy, markedBy)" >&2; return 3; }
import json, re, sys
data = json.load(open(sys.argv[2]))
assert data.get("commit") == sys.argv[1]
assert re.fullmatch(r"[0-9a-f]{40}", data.get("key") or "")
assert re.fullmatch(r"[0-9a-f]{40}", data.get("publishedBy") or "")
assert isinstance(data.get("markedBy"), str) and data["markedBy"].strip()
print("key=" + data["key"])
PY
}

# The cmux_next_ daemon tests passed for tree <key> (chief 2026-10-13):
# cmux-tui-artifacts publishes a tree before its daemon tests end; such a
# tree's source.json says daemonTests "separate", and publish-tree-tested
# writes daemon-tests.json when they pass. A tree published before that change
# (no field) was published only after its tests. Only the marker's presence
# counts. A read that is neither 200 nor 404 is a read failure (exit 3), never
# a pass: a missed source.json read used to skip the daemon-tests check.
daemon_tested() { # <key>
  local key="$1" code
  [[ "$key" =~ ^[0-9a-f]{40}$ ]] || { echo "error: daemon-tested takes a 40-hex tree key" >&2; exit 2; }
  code="$(http_get "$base/tree/$key/source.json?t=$(date +%s)" "$tmp/source.json")"
  case "$code" in
    200) ;;
    404) echo "tree $key is not published (no $base/tree/$key/source.json)" >&2; return 1 ;;
    *) echo "error: could not read $base/tree/$key/source.json (HTTP ${code:-000}); nothing is promoted or marked until it reads" >&2; return 3 ;;
  esac
  local separate
  separate="$(python3 -c 'import json,sys; print("yes" if json.load(open(sys.argv[1])).get("daemonTests") == "separate" else "no")' "$tmp/source.json" 2>/dev/null)" \
    || { echo "error: $base/tree/$key/source.json does not parse" >&2; return 3; }
  [[ "$separate" == yes ]] || return 0
  code="$(http_get "$base/tree/$key/daemon-tests.json?t=$(date +%s)" "$tmp/daemon-tests.json")"
  case "$code" in
    200) return 0 ;;
    404) echo "the daemon tests have not passed for tree $key yet (no daemon-tests.json)" >&2; return 1 ;;
    *) echo "error: could not read $base/tree/$key/daemon-tests.json (HTTP ${code:-000})" >&2; return 3 ;;
  esac
}

# Tree <key> is published and verified (pin-cmux-tui.sh verify-key: its sha256,
# source.json and the publishing commit's attested manifest agree). Its daemon
# tests are not asked for (see the header).
tree_ready() { # <key>
  local key="$1" out rc=0
  out="$(bash "$script_dir/pin-cmux-tui.sh" verify-key "$key")" || rc=$?
  case "$rc" in
    0) ;;
    1) return 1 ;;
    *) return 3 ;;
  esac
  echo "publishedBy=${out#commit=}"
}

# key_definition <rev>: the blobs that define the tree key at <rev> (the key
# script and its input list), one line; fails when either is missing.
key_definition() {
  local script inputs
  script="$(git -C "$repo_root" rev-parse --verify -q "$1:scripts/ci/cmux_tui_tree_key.py")" || return 1
  inputs="$(git -C "$repo_root" rev-parse --verify -q "$1:scripts/cmux-next/cmux-tui-tree-inputs.txt")" || return 1
  echo "$script $inputs"
}

write_markers() {
  local window=40 tip_branch="" tip="" rev key ready published code rrc marked=0 skipped=0
  # One readiness check per distinct key: $tmp/keys/<key> holds "ready <publisher>" or "no".
  mkdir -p "$tmp/keys"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --window) window="${2:-}"; shift 2 ;;
      --tip-branch) tip_branch="${2:-}"; shift 2 ;;
      *) echo "error: unknown argument $1" >&2; exit 2 ;;
    esac
  done
  [[ "$window" =~ ^[1-9][0-9]?$ ]] || { echo "error: --window must be 1 to 99" >&2; exit 2; }
  [[ -z "$tip_branch" || "$tip_branch" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "error: --tip-branch takes a branch name" >&2; exit 2; }
  [[ -n "${R2_ENDPOINT:-}" ]] || { echo "error: R2_ENDPOINT is required to write markers" >&2; exit 2; }
  local run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-manaflow-ai/cmux}/actions/runs/${GITHUB_RUN_ID:-local}"
  # The commits to walk: HEAD's window, then the tip's, each once. Listed up
  # front so a failed rev-list fails the run instead of ending the walk early.
  git -C "$repo_root" rev-list --first-parent -n "$window" HEAD > "$tmp/head-revs" \
    || { echo "error: could not list HEAD's first-parent history" >&2; exit 1; }
  cp "$tmp/head-revs" "$tmp/revs"
  # Fetched only after HEAD's window is listed: in a shallow checkout a
  # --depth fetch of a tip less than a window ahead moves the shallow boundary
  # into HEAD's window (the objects stay, so the listed commits still key). In
  # a full clone no --depth, which would make it shallow. A failed fetch marks
  # from HEAD alone, as before --tip-branch.
  if [[ -n "$tip_branch" ]]; then
    local depth=()
    [[ "$(git -C "$repo_root" rev-parse --is-shallow-repository)" == true ]] && depth=(--depth="$((window + 1))")
    if git -C "$repo_root" fetch -q --no-tags ${depth[@]+"${depth[@]}"} origin "refs/heads/$tip_branch" 2>/dev/null; then
      tip="$(git -C "$repo_root" rev-parse FETCH_HEAD)"
    else
      echo "warning: could not fetch $tip_branch; marking from this run's commit only" >&2
    fi
  fi
  if [[ -n "$tip" ]]; then
    git -C "$repo_root" rev-list --first-parent -n "$window" "$tip" > "$tmp/tip-revs" \
      || { echo "error: could not list the tip's first-parent history" >&2; exit 1; }
    grep -vxF -f "$tmp/head-revs" "$tmp/tip-revs" >> "$tmp/revs" || true
  fi
  # Every commit is keyed with this checkout's key script and input list, so it
  # is marked only when its own copies are the same: an older commit from before
  # a key definition change, or a tip commit after one, is left to a run whose
  # definition matches it (its own run, or the backfill).
  local key_def
  key_def="$(key_definition HEAD)" || { echo "error: could not read this checkout's tree key definition" >&2; exit 1; }
  while read -r rev; do
    if [[ "$(key_definition "$rev" 2>/dev/null)" != "$key_def" ]]; then
      echo "commit ${rev:0:12}: its tree key definition differs from this run's; not marked here"
      skipped=$((skipped + 1)); continue
    fi
    key="$(python3 "$repo_root/scripts/ci/cmux_tui_tree_key.py" --version v2 "$rev" 2>/dev/null)" || {
      echo "commit ${rev:0:12}: no tree key; not marked"; skipped=$((skipped + 1)); continue; }
    if [[ ! -f "$tmp/keys/$key" ]]; then
      # Not ready and unreadable both leave the commits unmarked (fail closed);
      # the log tells them apart, and the next run or the backfill reads again.
      rrc=0
      ready="$(tree_ready "$key" 2>"$tmp/ready.err")" || rrc=$?
      if (( rrc == 0 )); then
        echo "ready ${ready#publishedBy=}" > "$tmp/keys/$key"
      elif (( rrc == 1 )); then
        echo no > "$tmp/keys/$key"
        echo "tree $key: not ready ($(tail -n 1 "$tmp/ready.err" 2>/dev/null))"
      else
        echo no > "$tmp/keys/$key"
        echo "warning: tree $key: read failure, not marking its commits this run ($(tail -n 1 "$tmp/ready.err" 2>/dev/null))" >&2
      fi
    fi
    read -r ready published < "$tmp/keys/$key" || true
    [[ "$ready" == ready ]] || { skipped=$((skipped + 1)); continue; }
    code=0
    check "$rev" >/dev/null 2>&1 || code=$?
    if (( code == 0 )); then continue; fi
    if (( code == 3 )); then
      echo "warning: could not read the marker of ${rev:0:12}; not writing it this run" >&2
      skipped=$((skipped + 1)); continue
    fi
    python3 - "$rev" "$key" "$published" "$run_url" > "$tmp/$rev.json" <<'PY'
import json, sys
print(json.dumps({"commit": sys.argv[1], "key": sys.argv[2], "publishedBy": sys.argv[3], "markedBy": sys.argv[4]}, indent=2))
PY
    if python3 "$repo_root/scripts/ci/upload-r2-object.py" --file "$tmp/$rev.json" --endpoint-url "$R2_ENDPOINT" \
        --bucket cmux-binaries --key "cmux-tui/tree-commits/$rev.json" \
        --cache-control "public, max-age=31536000, immutable" --content-type application/json --write-once; then
      echo "marked ${rev:0:12} (tree $key, published by ${published:0:12})"
      marked=$((marked + 1))
    elif check "$rev" >/dev/null 2>&1; then
      # Another run marked it between the check and this write-once upload.
      echo "${rev:0:12} was marked by another run"
    else
      echo "error: could not write the tree-commit marker of $rev" >&2
      exit 1
    fi
  done < "$tmp/revs"
  echo "tree-commit markers: $marked written, $skipped commits not ready or unreadable, window $window"
}

cmd="${1:-}"
shift || true
case "$cmd" in
  check) check "${1:-}" ;;
  daemon-tested) daemon_tested "${1:-}" ;;
  tree-ready) tree_ready "${1:-}" ;;
  write) write_markers "$@" ;;
  -h|--help|"") sed -n '2,48p' "$0" ;;
  *) echo "error: unknown command $cmd" >&2; exit 2 ;;
esac
