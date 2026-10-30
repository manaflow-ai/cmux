#!/usr/bin/env bash
# Start and inspect the cmux-next web preview surfaces.
#
# This is a small agent-friendly wrapper around web-dev.sh. It keeps one
# web-dev process per checkout, records the exact checkout SHA that process
# serves, and can open the local gallery in a cmux browser when one is
# available. It never builds or launches the native app and never runs a
# browser automation runtime.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/cmux-next/preview.sh <command> [options]

Commands:
  web       Start or reuse local Vite/HMR surfaces and print the index URL.
  gallery   Start/reuse web surfaces and print the live gallery URL.
  status    Report whether this checkout's preview is running.

Options:
  --entry <id>   Select a gallery entry (gallery command; uses the #/<entry> route).
  --open         Open the resulting URL with `cmux browser open` when available.
  --no-open      Do not open a browser (the default).
  --compare      Use scripts/gallery-compare.sh for a pushed before/after
                 gallery instead of the local HMR gallery (gallery only).
  --json         Emit one JSON object with exact SHA and URL provenance.
  -h, --help     Show this help.

State is kept outside the checkout under
$TMPDIR/cmux-next-preview (override with CMUX_PREVIEW_STATE_DIR). The web
helper can be overridden for tests or an alternate launcher with
CMUX_PREVIEW_WEB_DEV_SCRIPT. No native build is performed by this command.
USAGE
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
state_root="${CMUX_PREVIEW_STATE_DIR:-${TMPDIR:-/tmp}/cmux-next-preview}"
json=0
open_requested=0
compare=0
entry=""
command=""

# Parse options in any order so agents can use either `preview.sh --json web`
# or `preview.sh web --json`.
args=()
while (($#)); do
  case "$1" in
    --json) json=1; shift ;;
    --open) open_requested=1; shift ;;
    --no-open) open_requested=0; shift ;;
    --compare) compare=1; shift ;;
    --entry)
      (($# >= 2)) || { echo "cmux-next preview: --entry needs a value" >&2; exit 2; }
      entry="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    web|gallery|status)
      if [[ -n "$command" ]]; then
        echo "cmux-next preview: only one command may be supplied" >&2
        exit 2
      fi
      command="$1"; shift ;;
    *) args+=("$1"); shift ;;
  esac
done
if ((${#args[@]})); then
  echo "cmux-next preview: unknown argument: ${args[0]}" >&2
  exit 2
fi
[[ -n "$command" ]] || { usage >&2; exit 2; }
if [[ "$command" != gallery && -n "$entry" ]]; then
  echo "cmux-next preview: --entry is only valid with gallery" >&2
  exit 2
fi
if [[ "$command" != gallery && "$compare" == 1 ]]; then
  echo "cmux-next preview: --compare is only valid with gallery" >&2
  exit 2
fi

fail() {
  local message="$1"
  local code="${2:-1}"
  if ((json)); then
    emit_json false "$command" "$message" "" "" "" "" "" "" "" "" ""
  else
    echo "cmux-next preview: error: $message" >&2
  fi
  exit "$code"
}

# The state file is line-oriented rather than sourced as shell. Values are
# read as data, so paths or URLs cannot execute code when a state is inspected.
repo_key=""
if command -v shasum >/dev/null 2>&1; then
  repo_key="$(printf '%s' "$repo_root" | shasum -a 256 | awk '{print substr($1, 1, 16)}')"
else
  repo_key="$(printf '%s' "$repo_root" | cksum | awk '{print $1}')"
fi
state_file="$state_root/$repo_key.state"
lock_dir="$state_file.lock"
lock_acquired=0

release_lock() {
  if ((lock_acquired)); then
    rm -rf "$lock_dir"
  fi
}

acquire_lock() {
  mkdir -p "$state_root"
  if mkdir "$lock_dir" 2>/dev/null; then
    printf '%s\n' "$$" > "$lock_dir/pid"
    lock_acquired=1
    trap release_lock EXIT
    return 0
  fi
  local owner=""
  [[ -f "$lock_dir/pid" ]] && owner="$(cat "$lock_dir/pid" 2>/dev/null || true)"
  if [[ "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
    rm -rf "$lock_dir"
    if mkdir "$lock_dir" 2>/dev/null; then
      printf '%s\n' "$$" > "$lock_dir/pid"
      lock_acquired=1
      trap release_lock EXIT
      return 0
    fi
  fi
  fail "another preview command is updating this checkout; retry after it exits${owner:+ (pid $owner)}" 1
}

state_repo=""
state_sha=""
state_branch=""
state_dirty=""
state_phase=""
state_pid=""
state_helper=""
state_index_url=""
state_index_token=""
state_gallery_url=""
state_log=""
state_started=""

read_state() {
  state_repo=""; state_sha=""; state_branch=""; state_dirty=""; state_phase=""
  state_pid=""; state_helper=""; state_index_url=""; state_index_token=""; state_gallery_url=""
  state_log=""; state_started=""
  [[ -f "$state_file" ]] || return 1
  local key value
  while IFS=$'\t' read -r key value || [[ -n "$key" ]]; do
    case "$key" in
      repo_root) state_repo="$value" ;;
      sha) state_sha="$value" ;;
      branch) state_branch="$value" ;;
      dirty) state_dirty="$value" ;;
      phase) state_phase="$value" ;;
      pid) state_pid="$value" ;;
      helper) state_helper="$value" ;;
      index_url) state_index_url="$value" ;;
      index_token) state_index_token="$value" ;;
      gallery_url) state_gallery_url="$value" ;;
      log) state_log="$value" ;;
      started) state_started="$value" ;;
    esac
  done < "$state_file"
  [[ "$state_repo" == "$repo_root" ]]
}

write_state() {
  mkdir -p "$state_root"
  local tmp="$state_file.tmp.$$"
  {
    printf 'repo_root\t%s\n' "$repo_root"
    printf 'sha\t%s\n' "$state_sha"
    printf 'branch\t%s\n' "$state_branch"
    printf 'dirty\t%s\n' "$state_dirty"
    printf 'phase\t%s\n' "$state_phase"
    printf 'pid\t%s\n' "$state_pid"
    printf 'helper\t%s\n' "$state_helper"
    printf 'index_url\t%s\n' "$state_index_url"
    printf 'index_token\t%s\n' "$state_index_token"
    printf 'gallery_url\t%s\n' "$state_gallery_url"
    printf 'log\t%s\n' "$state_log"
    printf 'started\t%s\n' "$state_started"
  } > "$tmp"
  mv -f "$tmp" "$state_file"
}

# Resolve Git identity once. A dirty worktree is expected during HMR and is
# recorded so an agent can tell what the exact commit does and does not prove.
git_cmd() { git -C "$repo_root" "$@"; }
sha="$(git_cmd rev-parse --verify HEAD 2>/dev/null)" || fail "could not resolve HEAD in $repo_root" 2
branch="$(git_cmd symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'HEAD')"
if git_cmd diff --quiet --no-ext-diff && git_cmd diff --cached --quiet --no-ext-diff \
  && [[ -z "$(git_cmd status --porcelain --untracked-files=normal)" ]]; then
  dirty=false
else
  dirty=true
fi

# Python is already a repository prerequisite for verification scripts. Keep
# all JSON escaping in one place instead of interpolating shell strings.
emit_json() {
  local ok="$1" mode="$2" error="$3" index_url="$4" gallery_url="$5" selected_entry="$6"
  local pid="$7" log="$8" reused="$9" opened="${10}" open_error="${11}" phase="${12}"
  python3 - "$ok" "$mode" "$error" "$repo_root" "$sha" "$branch" "$dirty" "$index_url" "$gallery_url" \
    "$selected_entry" "$pid" "$log" "$reused" "$opened" "$open_error" "$phase" <<'PY'
import json
import sys

(
    ok,
    mode,
    error,
    repo,
    sha,
    branch,
    dirty,
    index_url,
    gallery_url,
    entry,
    pid,
    log,
    reused,
    opened,
    open_error,
    phase,
) = sys.argv[1:]

def boolean(value):
    return value == "true"

obj = {
    "ok": boolean(ok),
    "mode": mode,
    "error": error or None,
    "repo": repo,
    "sha": sha,
    "branch": branch,
    "worktree_dirty": boolean(dirty),
    "index_url": index_url or None,
    "gallery_url": gallery_url or None,
    "entry": entry or None,
    "pid": int(pid) if pid.isdigit() else None,
    "log": log or None,
    "reused": boolean(reused),
    "opened": boolean(opened),
    "open_error": open_error or None,
    "phase": phase or None,
}
print(json.dumps(obj, sort_keys=True, separators=(",", ":")))
PY
}

is_managed_pid() {
  local pid="$1" helper="$2" command_line
  [[ "$pid" =~ ^[0-9]+$ && "$pid" != 0 ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ -n "$helper" && "$command_line" == *"$helper"* ]]
}

stop_managed() {
  read_state || return 0
  if ! is_managed_pid "$state_pid" "$state_helper"; then
    rm -f "$state_file"
    return 0
  fi
  kill -TERM "$state_pid" 2>/dev/null || true
  local i
  for i in $(seq 1 50); do
    if ! kill -0 "$state_pid" 2>/dev/null; then
      rm -f "$state_file"
      return 0
    fi
    sleep 0.1
  done
  fail "the previous preview process (pid $state_pid) did not stop after SIGTERM; inspect $state_log" 1
}

http_ready() {
  local url="$1"
  [[ -n "$url" ]] || return 1
  command -v curl >/dev/null 2>&1 || return 1
  curl -fsS --max-time 2 "$url" >/dev/null 2>&1
}

http_owned() {
  local url="$1" token="$2"
  [[ -n "$token" ]] || return 1
  curl -fsS --max-time 2 "$url" | grep -F "$token" >/dev/null
}

published_gallery_url() {
  local log="$1" candidate
  candidate="$(sed -n 's/^GALLERY_URL=//p' "$log" | tail -1 || true)"
  if http_ready "$candidate"; then printf '%s' "$candidate"; fi
}

start_web() {
  local reused_value="$1"
  local helper="${CMUX_PREVIEW_WEB_DEV_SCRIPT:-$repo_root/scripts/cmux-next/web-dev.sh}"
  [[ -f "$helper" && -r "$helper" ]] || fail "web helper is missing or unreadable: $helper" 1
  helper="$(cd "$(dirname "$helper")" && pwd)/$(basename "$helper")"

  local timeout="${CMUX_PREVIEW_START_TIMEOUT:-60}"
  [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || fail "CMUX_PREVIEW_START_TIMEOUT must be a positive integer" 2
  mkdir -p "$state_root"
  local stamp="$(date +%s)"
  local log="$state_root/web-$stamp-$$.log"
  state_repo="$repo_root"; state_sha="$sha"; state_branch="$branch"; state_dirty="$dirty"
  state_phase="starting"; state_pid=""; state_helper="$helper"; state_index_url=""
  state_index_token=""; state_gallery_url=""; state_log="$log"; state_started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # Start from the repository root so web-dev's own relative paths resolve.
  (
    cd "$repo_root"
    exec bash "$helper"
  ) >"$log" 2>&1 < /dev/null &
  state_pid="$!"
  write_state

  local index_url="" index_token="" i
  for i in $(seq 1 $((timeout * 10))); do
    index_url="$(sed -n 's/^INDEX_URL=//p' "$log" | tail -1 || true)"
    index_token="$(sed -n 's/^INDEX_TOKEN=//p' "$log" | tail -1 || true)"
    if [[ -n "$index_url" && -n "$index_token" ]] && http_owned "$index_url" "$index_token"; then break; fi
    if ! kill -0 "$state_pid" 2>/dev/null; then
      local tail_log
      tail_log="$(tail -30 "$log" 2>/dev/null || true)"
      rm -f "$state_file"
      fail "web helper exited before readiness (log: $log)${tail_log:+; tail: $tail_log}" 1
    fi
    sleep 0.1
  done
  [[ -n "$index_url" && -n "$index_token" ]] && http_owned "$index_url" "$index_token" \
    || fail "web helper did not publish an owned INDEX_URL within ${timeout}s (log: $log)" 1

  # A server on the configured port may belong to another checkout. Only the
  # managed helper's readiness output can associate a gallery with this preview.
  local gallery_url
  gallery_url="$(published_gallery_url "$log")"
  state_phase="ready"; state_index_url="$index_url"; state_index_token="$index_token"; state_gallery_url="$gallery_url"
  write_state
  index_result_url="$index_url"
  gallery_result_url="$gallery_url"
  pid_result="$state_pid"
  log_result="$log"
  reused_result="$reused_value"
  phase_result="ready"
}

# Globals filled by ensure_web and used by the output path.
index_result_url=""
gallery_result_url=""
pid_result=""
log_result=""
reused_result="false"
phase_result=""

ensure_web() {
  local have_state=0
  read_state && have_state=1 || true
  if ((have_state)); then
    if [[ "$state_sha" == "$sha" && "$state_phase" == ready ]] \
      && is_managed_pid "$state_pid" "$state_helper" \
      && http_owned "$state_index_url" "$state_index_token"; then
      index_result_url="$state_index_url"; gallery_result_url="$state_gallery_url"
      pid_result="$state_pid"; log_result="$state_log"; reused_result="true"; phase_result="ready"
      # A gallery can disappear independently. Re-read the helper's published URL
      # and clear it when unavailable, including state written by older wrappers.
      gallery_result_url="$(published_gallery_url "$state_log")"
      state_gallery_url="$gallery_result_url"; write_state
      return 0
    fi
    # Never kill a process we cannot identify as our own helper. A known stale
    # helper is stopped so a new SHA cannot be mistaken for old preview proof.
    if is_managed_pid "$state_pid" "$state_helper"; then stop_managed; else rm -f "$state_file"; fi
  fi
  start_web "false"
}

open_result="false"
open_error_result=""
open_url() {
  local url="$1" name="$2"
  open_result="false"; open_error_result=""
  ((open_requested)) || return 0
  if ! command -v cmux >/dev/null 2>&1; then
    open_error_result="cmux CLI not found; open the URL manually"
    return 0
  fi
  if cmux browser open "$url" --name "$name" >/dev/null 2>&1; then
    open_result="true"
  else
    open_error_result="cmux browser open failed; open the URL manually"
  fi
}

print_result() {
  local mode="$1" error="$2" index_url="$3" gallery_url="$4" selected_entry="$5"
  local pid="$6" log="$7" reused="$8" phase="$9"
  if ((json)); then
    emit_json "$([[ -z "$error" ]] && printf true || printf false)" "$mode" "$error" "$index_url" "$gallery_url" \
      "$selected_entry" "$pid" "$log" "$reused" "$open_result" "$open_error_result" "$phase"
    return
  fi
  if [[ -n "$error" ]]; then
    echo "cmux-next preview: error: $error" >&2
    return 1
  fi
  echo "cmux-next preview $mode ready"
  echo "repo: $repo_root"
  echo "sha: $sha"
  echo "branch: $branch"
  echo "worktree dirty: $dirty"
  [[ -z "$index_url" ]] || echo "index: $index_url"
  [[ -z "$gallery_url" ]] || echo "gallery: $gallery_url"
  [[ -z "$selected_entry" ]] || echo "entry: $selected_entry"
  [[ -z "$pid" ]] || echo "pid: $pid"
  [[ -z "$log" ]] || echo "log: $log"
  echo "reused: $reused"
  if ((open_requested)); then
    if [[ "$open_result" == true ]]; then echo "opened: yes"; else echo "opened: no ($open_error_result)"; fi
  fi
}

if [[ "$command" == status ]]; then
  if ! read_state; then
    print_result status "no preview state for this checkout; run '$0 web'" "" "" "" "" "" false "stopped" || true
    exit 1
  fi
  status_error=""
  status_running=false
  if [[ "$state_sha" != "$sha" ]]; then
    status_error="preview serves SHA $state_sha, but this checkout is now $sha; restart with '$0 web'"
  elif [[ "$state_phase" != ready ]]; then
    status_error="preview is ${state_phase:-starting}; inspect $state_log"
  elif ! is_managed_pid "$state_pid" "$state_helper"; then
    status_error="preview process $state_pid is not running; inspect $state_log"
  elif ! http_owned "$state_index_url" "$state_index_token"; then
    status_error="preview index is not owned or reachable at $state_index_url; inspect $state_log"
  else
    status_running=true
  fi
  index_result_url="$state_index_url"; gallery_result_url="$state_gallery_url"; pid_result="$state_pid"
  log_result="$state_log"; phase_result="$state_phase"; reused_result="true"
  if ((json)); then
    emit_json "$status_running" status "$status_error" "$index_result_url" "$gallery_result_url" "" "$pid_result" \
      "$log_result" true false "" "$phase_result"
  else
    if [[ -n "$status_error" ]]; then
      print_result status "$status_error" "$index_result_url" "$gallery_result_url" "" "$pid_result" "$log_result" true "$phase_result" || true
      exit 1
    fi
    print_result status "" "$index_result_url" "$gallery_result_url" "" "$pid_result" "$log_result" true "$phase_result"
  fi
  [[ "$status_running" == true ]] || exit 1
  exit 0
fi

if [[ "$command" == web ]]; then
  acquire_lock
  ensure_web
  open_url "$index_result_url" "cmux-next web · $branch · ${sha:0:12}"
  print_result web "" "$index_result_url" "$gallery_result_url" "" "$pid_result" "$log_result" "$reused_result" "$phase_result"
  exit 0
fi

# gallery command
if ((compare)); then
  compare_script="$repo_root/scripts/gallery-compare.sh"
  [[ -x "$compare_script" ]] || fail "gallery compare helper is missing or not executable: $compare_script" 1
  compare_args=()
  [[ -z "$entry" ]] || compare_args+=(--entry "$entry")
  compare_output="$(bash "$compare_script" "${compare_args[@]}" 2>&1)" || fail "$compare_output" 1
  compare_url="$(printf '%s\n' "$compare_output" | grep -E '^https://' | tail -1)"
  [[ -n "$compare_url" ]] || fail "gallery compare returned no URL: $compare_output" 1
  open_url "$compare_url" "cmux-next gallery compare · ${entry:-all} · ${sha:0:12}"
  if ((json)); then
    emit_json true gallery-compare "" "" "$compare_url" "$entry" "" "" false "$open_result" "$open_error_result" "ready"
  else
    echo "$compare_url"
    echo "sha: $sha"
    echo "entry: ${entry:-all}"
  fi
  exit 0
fi

acquire_lock
ensure_web
[[ -n "$gallery_result_url" ]] || fail "the live gallery is unavailable; web-dev did not start a gallery server (check vite.config.gallery-dev.ts)" 1

gallery_result_url="${gallery_result_url%/}/"
if [[ -n "$entry" ]]; then
  encoded_entry="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$entry")"
  # The gallery shell uses hash history: /gallery/#/<entry> redirects to that
  # entry's first variant. A query parameter here would be ignored and land on
  # the default composer, which is particularly confusing for agents.
  gallery_result_url="${gallery_result_url}#/${encoded_entry}"
fi
open_url "$gallery_result_url" "cmux-next gallery · ${entry:-all} · ${sha:0:12}"
print_result gallery "" "$index_result_url" "$gallery_result_url" "$entry" "$pid_result" "$log_result" "$reused_result" "$phase_result"
