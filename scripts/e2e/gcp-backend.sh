#!/usr/bin/env bash
# Provision the tagged web backend used by the iOS E2E workflow.
#
# The VM is already installed by the cmuxterm-hq backend administration flow.
# This CI-side client uploads only web/ over Tailscale SSH, asks devbackendd to
# start a direct Tailscale Serve endpoint, and records the remote port for
# cleanup. It deliberately has no static VM SSH key or cross-repository
# checkout dependency.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARCHIVE_HELPER="$SCRIPT_DIR/gcp-backend-archive.py"

VM_HOST="${CMUX_E2E_BACKEND_HOST:-cmux-dev-backend-1}"
VM_USER="${CMUX_DEV_BACKEND_VM_USER:-ubuntu}"
REMOTE_BASE="${CMUX_DEV_BACKEND_REMOTE_BASE:-/srv/cmux-dev}"
CONTROL_PORT="${CMUX_DEV_BACKEND_CONTROL_PORT:-8477}"
PROVISION_WAIT="${CMUX_DEV_BACKEND_PROVISION_WAIT_SECS:-30}"
REMOTE_API_TIMEOUT="${CMUX_DEV_BACKEND_API_TIMEOUT_SECS:-120}"
PROVISION_API_TIMEOUT="${CMUX_DEV_BACKEND_PROVISION_TIMEOUT_SECS:-600}"
STATE_ROOT="${CMUX_E2E_BACKEND_STATE_DIR:-${RUNNER_TEMP:-/tmp}/cmux-gcp-backend}"
TARGET="$VM_USER@$VM_HOST"
SSH_OPTS=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o ConnectTimeout=10
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=2
)

CLEANUP_PATHS=()
cleanup_paths() {
  local path
  for path in "${CLEANUP_PATHS[@]}"; do
    [[ -n "$path" ]] && rm -rf -- "$path"
  done
}
trap cleanup_paths EXIT

err() { printf 'gcp-backend: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  scripts/e2e/gcp-backend.sh start --tag TAG [--checkout PATH]
  scripts/e2e/gcp-backend.sh url --tag TAG
  scripts/e2e/gcp-backend.sh remove --tag TAG

Environment:
  CMUX_E2E_BACKEND_HOST       Tailscale DNS name of the backend VM
  CMUX_DEV_BACKEND_VM_USER    VM SSH user (default ubuntu)
  CMUX_DEV_BACKEND_REMOTE_BASE (default /srv/cmux-dev)
  CMUX_DEV_BACKEND_CONTROL_PORT (default 8477)
  CMUX_E2E_BACKEND_STATE_DIR  per-run state directory
EOF
}

is_valid_tag() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]
}

is_valid_port() {
  [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] || return 1
  local port=$((10#$1))
  (( port >= 3800 && port <= 4799 ))
}

is_safe_remote_base() {
  [[ "$REMOTE_BASE" =~ ^/[A-Za-z0-9._/-]+$ ]] || return 1
  [[ "$REMOTE_BASE" != *..* && "$REMOTE_BASE" != */ ]]
}

require_tools() {
  local tool
  for tool in git jq python3 ssh scp shasum tar; do
    command -v "$tool" >/dev/null 2>&1 || die "required command is missing: $tool"
  done
  is_safe_remote_base || die "CMUX_DEV_BACKEND_REMOTE_BASE must be a simple absolute path"
  [[ "$CONTROL_PORT" =~ ^[0-9]+$ ]] || die "invalid control port: $CONTROL_PORT"
  [[ "$PROVISION_WAIT" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "invalid provision wait: $PROVISION_WAIT"
  [[ "$REMOTE_API_TIMEOUT" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "invalid API timeout: $REMOTE_API_TIMEOUT"
  [[ "$PROVISION_API_TIMEOUT" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "invalid provision timeout: $PROVISION_API_TIMEOUT"
}

state_path() {
  local tag="$1"
  printf '%s/%s.json\n' "$STATE_ROOT" "$tag"
}

read_state() {
  local tag="$1" path
  is_valid_tag "$tag" || die "invalid tag '$tag'"
  path="$(state_path "$tag")"
  [[ -f "$path" ]] || die "no backend state for tag '$tag'; run start first"
  jq -e . "$path" >/dev/null || die "invalid backend state: $path"
  printf '%s\n' "$path"
}

state_value() {
  local path="$1" key="$2"
  jq -er --arg key "$key" '.[$key]' "$path"
}

remote_api() {
  local method="$1" path="$2" body="${3:-}" max_time="${4:-$REMOTE_API_TIMEOUT}"
  local output status response rc marker url="http://127.0.0.1:${CONTROL_PORT}${path}"
  marker="__CMUX_DEV_BACKEND_HTTP_STATUS__"
  set +e
  if [[ -n "$body" ]]; then
    output="$(printf '%s' "$body" | ssh "${SSH_OPTS[@]}" "$TARGET" \
      curl --silent --show-error --connect-timeout 5 --max-time "$max_time" \
        -X "$method" -H Content-Type:application/json --data-binary @- \
        -w "${marker}%{http_code}" "$url")"
    rc=$?
  else
    output="$(ssh "${SSH_OPTS[@]}" "$TARGET" \
      curl --silent --show-error --connect-timeout 5 --max-time "$max_time" \
        -X "$method" -w "${marker}%{http_code}" "$url")"
    rc=$?
  fi
  set -e
  if (( rc != 0 )); then
    err "could not reach $TARGET (ssh/curl status $rc)"
    return "$rc"
  fi
  status="${output##*"$marker"}"
  response="${output%"$marker$status"}"
  if [[ ! "$status" =~ ^2[0-9][0-9]$ ]]; then
    [[ -n "$response" ]] && printf '%s\n' "$response" >&2
    err "remote backend request failed with HTTP $status"
    return 1
  fi
  printf '%s\n' "$response"
}

remove_remote_upload() {
  local filename="$1"
  ssh "${SSH_OPTS[@]}" "$TARGET" rm -f -- "$REMOTE_BASE/incoming/$filename" >/dev/null 2>&1 || true
}

make_source_archive() {
  local checkout="$1" output="$2"
  [[ -d "$checkout/web" ]] || die "checkout has no web/ directory: $checkout"
  python3 "$ARCHIVE_HELPER" "$checkout" "$output"
  tar -tzf "$output" | awk '/^web\// { found=1 } END { exit found ? 0 : 1 }' \
    || die "source archive did not contain web/"
}

instance_id_for() {
  local tag="$1" run_id="${GITHUB_RUN_ID:-local}" attempt="${GITHUB_RUN_ATTEMPT:-1}"
  local identity digest
  identity="${GITHUB_REPOSITORY:-local}/$run_id/$attempt/$tag"
  digest="$(printf '%s' "$identity" | shasum -a 256 | awk '{print $1}' | cut -c1-16)"
  printf 'ci-%s-%s\n' "$digest" "$tag"
}

write_state() {
  local tag="$1" instance_id="$2" remote_port="$3" checkout="$4" commit="$5"
  local source_sha="$6" branch="$7" url="$8" path tmp
  path="$(state_path "$tag")"
  mkdir -p "$STATE_ROOT"
  chmod 700 "$STATE_ROOT"
  tmp="$path.tmp.$$"
  umask 077
  jq -n \
    --arg tag "$tag" \
    --arg instance_id "$instance_id" \
    --argjson remote_port "$remote_port" \
    --arg host "$VM_HOST" \
    --arg user "$VM_USER" \
    --arg checkout "$checkout" \
    --arg commit "$commit" \
    --arg source_sha256 "$source_sha" \
    --arg branch "$branch" \
    --arg url "$url" \
    --arg control_port "$CONTROL_PORT" \
    --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema: 1, tag: $tag, instance_id: $instance_id, remote_port: $remote_port,
      host: $host, user: $user, checkout: $checkout, commit: $commit,
      branch: $branch, source_sha256: $source_sha256, url: $url,
      control_port: ($control_port|tonumber), updated_at: $updated_at}' >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$path"
}

cmd_start() {
  local tag="" checkout="$REPO_ROOT"
  local branch commit instance_id archive_dir archive archive_name source_sha
  local body response remote_port url existing_state
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tag) tag="${2:?missing --tag value}"; shift 2 ;;
      --tag=*) tag="${1#*=}"; shift ;;
      --checkout) checkout="${2:?missing --checkout value}"; shift 2 ;;
      --checkout=*) checkout="${1#*=}"; shift ;;
      *) die "unknown start option: $1" ;;
    esac
  done
  is_valid_tag "$tag" || die "invalid tag '$tag'"
  checkout="$(cd "$checkout" && pwd)"
  [[ -x "$checkout/scripts/reload.sh" ]] || die "checkout is not a cmux checkout: $checkout"
  instance_id="$(instance_id_for "$tag")"
  existing_state="$(state_path "$tag")"
  if [[ -f "$existing_state" ]]; then
    die "backend state already exists for tag '$tag'; remove it before restarting"
  fi
  branch="$(git -C "$checkout" branch --show-current 2>/dev/null || true)"
  [[ -n "$branch" ]] || branch=detached
  commit="$(git -C "$checkout" rev-parse HEAD 2>/dev/null || true)"
  [[ -n "$commit" ]] || commit=unknown
  archive_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-gcp-backend-upload.XXXXXX")"
  CLEANUP_PATHS+=("$archive_dir")
  archive="$archive_dir/source.tar.gz"
  make_source_archive "$checkout" "$archive"
  source_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
  archive_name="${instance_id}-${source_sha:0:16}-$(date +%s).tar.gz"
  ssh "${SSH_OPTS[@]}" "$TARGET" mkdir -m 700 -p "$REMOTE_BASE/incoming"
  scp "${SSH_OPTS[@]}" "$archive" "$TARGET:$REMOTE_BASE/incoming/$archive_name" >/dev/null
  body="$(jq -cn \
    --arg instance_id "$instance_id" --arg tag "$tag" --arg branch "$branch" \
    --arg commit "$commit" --arg archive "$archive_name" --arg source_sha256 "$source_sha" \
    --arg transport direct --argjson wait "$PROVISION_WAIT" \
    '{instance_id:$instance_id, tag:$tag, branch:$branch, commit:$commit,
      archive:$archive, source_sha256:$source_sha256, wait:$wait, transport:$transport}')"
  if response="$(remote_api POST /provision "$body" "$PROVISION_API_TIMEOUT")"; then
    :
  else
    local request_rc=$?
    response="$(remote_api GET /status "" "$REMOTE_API_TIMEOUT" 2>/dev/null || true)"
    if [[ -n "$response" ]]; then
      remote_port="$(jq -r --arg id "$instance_id" '.entries[]? | select(.instance_id == $id) | .port' <<<"$response" | head -n 1)"
      if is_valid_port "${remote_port:-}"; then
        response="$(remote_api POST "/ensure/$remote_port?wait=$PROVISION_WAIT" "" "$REMOTE_API_TIMEOUT" 2>/dev/null || true)"
      else
        remote_port=""
      fi
    fi
    if [[ -z "${remote_port:-}" || -z "${response:-}" ]]; then
      remove_remote_upload "$archive_name"
      die "remote provisioning failed (status $request_rc)"
    fi
    err "provision response was interrupted; recovered the remote instance"
  fi
  remote_port="$(jq -er '.port' <<<"$response")" || die "remote response has no port"
  is_valid_port "$remote_port" || die "remote response returned an invalid port"
  url="$(jq -r '.url // empty' <<<"$response")"
  [[ "$url" == https://* ]] || die "remote response has no HTTPS backend URL"
  write_state "$tag" "$instance_id" "$remote_port" "$checkout" "$commit" "$source_sha" "$branch" "$url"
  printf 'tag=%s url=%s remote_port=%s state=%s healthy=%s\n' \
    "$tag" "$url" "$remote_port" "$(jq -r '.state // unknown' <<<"$response")" \
    "$(jq -r '(.healthy // false)|tostring' <<<"$response")"
}

cmd_url() {
  local tag="" path remote_port response url
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tag) tag="${2:?missing --tag value}"; shift 2 ;;
      --tag=*) tag="${1#*=}"; shift ;;
      *) die "unknown url option: $1" ;;
    esac
  done
  path="$(read_state "$tag")"
  remote_port="$(state_value "$path" remote_port)"
  is_valid_port "$remote_port" || die "state has an invalid remote port"
  response="$(remote_api POST "/ensure/$remote_port?wait=30")" || die "remote ensure failed"
  url="$(jq -r '.url // empty' <<<"$response")"
  [[ "$url" == https://* ]] || die "remote ensure returned no HTTPS backend URL"
  jq --arg url "$url" --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.url = $url | .updated_at = $updated_at' "$path" >"$path.tmp.$$"
  chmod 600 "$path.tmp.$$"
  mv -f "$path.tmp.$$" "$path"
  printf '%s\n' "$url"
}

cmd_remove() {
  local tag="" path remote_port
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tag) tag="${2:?missing --tag value}"; shift 2 ;;
      --tag=*) tag="${1#*=}"; shift ;;
      *) die "unknown remove option: $1" ;;
    esac
  done
  path="$(read_state "$tag")"
  remote_port="$(state_value "$path" remote_port)"
  is_valid_port "$remote_port" || die "state has an invalid remote port"
  remote_api POST "/rm/$remote_port?purge=1" >/dev/null || die "remote remove failed"
  rm -f "$path"
  printf 'removed tag=%s remote_port=%s\n' "$tag" "$remote_port"
}

main() {
  require_tools
  case "${1:-}" in
    start) shift; cmd_start "$@" ;;
    url) shift; cmd_url "$@" ;;
    remove) shift; cmd_remove "$@" ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
}

main "$@"
