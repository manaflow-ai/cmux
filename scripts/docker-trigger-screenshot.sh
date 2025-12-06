#!/bin/bash

set -euo pipefail

IMAGE_NAME="cmux-shell"
# Default run ID is empty (uses base ports), or can be specified for parallel runs
RUN_ID=""
PR_URL=""
EXEC_COMMAND=""
NON_INTERACTIVE=false
INITIAL_SCREENSHOT_DIR=""
INITIAL_SCREENSHOT_MTIME=""
RUN_START_TS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr)
      if [[ $# -lt 2 ]]; then
        echo "Error: --pr requires an argument" >&2
        exit 1
      fi
      PR_URL="$2"
      shift 2
      ;;
    --pr=*)
      PR_URL="${1#*=}"
      shift 1
      ;;
    --run-id)
      if [[ $# -lt 2 ]]; then
        echo "Error: --run-id requires an argument" >&2
        exit 1
      fi
      RUN_ID="$2"
      shift 2
      ;;
    --run-id=*)
      RUN_ID="${1#*=}"
      shift 1
      ;;
    --exec)
      if [[ $# -lt 2 ]]; then
        echo "Error: --exec requires a command string" >&2
        exit 1
      fi
      EXEC_COMMAND="$2"
      NON_INTERACTIVE=true
      shift 2
      ;;
    --exec=*)
      EXEC_COMMAND="${1#*=}"
      NON_INTERACTIVE=true
      shift 1
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Generate unique container name and port offset based on run ID
if [ -n "$RUN_ID" ]; then
  CONTAINER_NAME="cmux-screenshot-${RUN_ID}"
  # Use hash of run ID to generate port offset (0-99)
  PORT_OFFSET=$(($(echo "$RUN_ID" | cksum | cut -d' ' -f1) % 100))
else
  CONTAINER_NAME="cmux-screenshot"
  PORT_OFFSET=0
fi

# Base ports offset for parallel runs (each run gets 10 consecutive ports)
BASE_PORT=$((39375 + PORT_OFFSET * 10))
WORKER_PORT=$((BASE_PORT + 2))  # 39377 equivalent

# Output directories - unique per run
HOST_OUTPUT_ROOT="$(pwd)/tmp"
if [ -n "$RUN_ID" ]; then
  HOST_OUTPUT_TGZ="$HOST_OUTPUT_ROOT/cmux-screenshots-${RUN_ID}.tgz"
  HOST_OUTPUT_DIR="$HOST_OUTPUT_ROOT/cmux-screenshots-${RUN_ID}"
else
  HOST_OUTPUT_TGZ="$HOST_OUTPUT_ROOT/cmux-screenshots-latest.tgz"
  HOST_OUTPUT_DIR="$HOST_OUTPUT_ROOT/cmux-screenshots-latest"
fi

POLLING_BASE="http://localhost:${WORKER_PORT}/socket.io/?EIO=4&transport=polling"

container_started=false

cleanup() {
  if [ "$container_started" = true ]; then
    echo "Stopping container..."
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    container_started=false
  fi
}

cleanup_and_exit() {
  cleanup
  exit 0
}

trap cleanup EXIT
trap cleanup_and_exit INT TERM

# Load environment variables (including ANTHROPIC_API_KEY) if available
if [ -f ".env" ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "Error: ANTHROPIC_API_KEY not set. Add it to your environment or .env before running." >&2
  exit 1
fi

echo "Building Docker image..."
docker build -t "$IMAGE_NAME" .

echo "Starting container..."
if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

docker run -d \
  --rm \
  --privileged \
  --cgroupns=host \
  --tmpfs /run \
  --tmpfs /run/lock \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v docker-data:/var/lib/docker \
  -p "${BASE_PORT}:39375" \
  -p "$((BASE_PORT + 1)):39376" \
  -p "$((BASE_PORT + 2)):39377" \
  -p "$((BASE_PORT + 3)):39378" \
  -p "$((BASE_PORT + 4)):39379" \
  -p "$((BASE_PORT + 5)):39380" \
  -p "$((BASE_PORT + 6)):39381" \
  -p "$((BASE_PORT + 7)):39382" \
  -p "$((BASE_PORT + 8)):39383" \
  -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  --name "$CONTAINER_NAME" \
  "$IMAGE_NAME"
container_started=true

# Allow services to initialize
sleep 5

# Wait for worker health endpoint to be ready
printf "Waiting for worker health endpoint"
health_ready=false
for _ in {1..30}; do
  if curl -sSf "http://localhost:${WORKER_PORT}/health" >/dev/null 2>&1; then
    printf "\n"
    health_ready=true
    break
  fi
  printf "."
  sleep 1
done

if [ "$health_ready" = false ]; then
  echo ""
  echo "Worker health endpoint did not respond in time"
  exit 1
fi

if [ -n "$PR_URL" ]; then
  echo "Preparing PR $PR_URL in /root/workspace..."
  GH_TOKEN_VALUE=$(gh auth token 2>/dev/null || true)
  if [ -z "$GH_TOKEN_VALUE" ]; then
    echo "Error: GitHub auth token unavailable. Run 'gh auth login' on the host before using --pr." >&2
    cleanup
    exit 1
  fi

  tmp_pr_description="$(mktemp)"
  clone_status=0
  description_status=0

  docker exec \
    -e PR_URL="$PR_URL" \
    -e GH_TOKEN="$GH_TOKEN_VALUE" \
    "$CONTAINER_NAME" \
    bash -lc '
set -euo pipefail

if [[ -z "${GH_TOKEN:-}" ]]; then
  echo "GH_TOKEN not provided; cannot check out PR inside container" >&2
  exit 1
fi

if [[ -z "${PR_URL:-}" ]]; then
  echo "PR_URL environment variable is required when cloning" >&2
  exit 1
fi

if [[ "$PR_URL" != https://github.com/*/pull/* ]]; then
  echo "PR URL must match https://github.com/<owner>/<repo>/pull/<number>" >&2
  exit 1
fi

REPO_URL="${PR_URL%/pull/*}"
WORKTREE=/root/workspace

rm -rf "$WORKTREE"
echo "Cloning $REPO_URL into $WORKTREE"
git clone "$REPO_URL" "$WORKTREE"
cd "$WORKTREE"
echo "Fetching PR branch via gh pr checkout..."
export GIT_TERMINAL_PROMPT=0
gh pr checkout "$PR_URL" >/dev/null
echo "Repository ready at $WORKTREE"
' &
  clone_pid=$!

  gh pr view "$PR_URL" --json body --jq '.body // ""' >"$tmp_pr_description" &
  description_pid=$!

  set +e
  wait "$clone_pid"
  clone_status=$?
  wait "$description_pid"
  description_status=$?
  set -e

  if [ "$clone_status" -ne 0 ]; then
    echo "Error: Failed to clone PR into worker container" >&2
    rm -f "$tmp_pr_description"
    cleanup
    exit 1
  fi

  pr_description=""
  if [ "$description_status" -ne 0 ]; then
    echo "Warning: Unable to retrieve PR description; continuing without it" >&2
  else
    pr_description=$(cat "$tmp_pr_description")
  fi
  rm -f "$tmp_pr_description"

  if [ -n "$pr_description" ]; then
    docker exec "$CONTAINER_NAME" bash -lc 'mkdir -p /root/workspace/.cmux'
    printf "%s" "$pr_description" | docker exec -i "$CONTAINER_NAME" bash -lc 'cat > /root/workspace/.cmux/pr-description.md'
    docker exec "$CONTAINER_NAME" bash -lc 'chmod 600 /root/workspace/.cmux/pr-description.md'
    echo "PR description copied into container for screenshot context."
  fi
fi

echo "Performing Socket.IO polling handshake..."
HANDSHAKE_RESPONSE=$(curl -s "${POLLING_BASE}&t=$(date +%s%3N)")

if [ -z "$HANDSHAKE_RESPONSE" ]; then
  echo "Handshake with worker failed; empty response"
  exit 1
fi

SID=$(node -e "const raw = process.argv[1]; const start = raw.indexOf('{'); const end = raw.lastIndexOf('}') + 1; if (start === -1 || end === 0) { process.stderr.write('Unable to parse handshake response\n'); process.exit(1); } const payload = JSON.parse(raw.slice(start, end)); process.stdout.write(payload.sid);" "$HANDSHAKE_RESPONSE")

if [ -z "$SID" ]; then
  echo "Failed to parse session id from handshake response"
  exit 1
fi

echo "Connecting to /management namespace..."
curl -s \
  -X POST \
  -H 'Content-Type: text/plain;charset=UTF-8' \
  --data-binary '40/management' \
  "${POLLING_BASE}&sid=${SID}&t=$(date +%s%3N)" >/dev/null

# Prepare screenshot collection payload
SOCKET_PAYLOAD=$(node -e '
const anthropicKey = process.argv[1] ?? "";
const payload = ["worker:start-screenshot-collection"];
const config = {};
if (anthropicKey.length > 0) {
  config.anthropicApiKey = anthropicKey;
}
if (Object.keys(config).length > 0) {
  payload.push(config);
}
process.stdout.write(JSON.stringify(payload));
' "$ANTHROPIC_API_KEY")

RUN_START_TS=$(date +%s)
INITIAL_SCREENSHOT_DIR=$(docker exec "$CONTAINER_NAME" bash -lc 'ls -1t /root/screenshots 2>/dev/null | head -1 || true')
if [ -n "$INITIAL_SCREENSHOT_DIR" ]; then
  INITIAL_SCREENSHOT_MTIME=$(docker exec "$CONTAINER_NAME" bash -lc 'stat -c %Y "/root/screenshots/'"$INITIAL_SCREENSHOT_DIR"'" 2>/dev/null || true')
else
  INITIAL_SCREENSHOT_MTIME=""
fi

echo "Triggering worker:start-screenshot-collection..."
curl -s \
  -X POST \
  -H 'Content-Type: text/plain;charset=UTF-8' \
  --data-binary "42/management,${SOCKET_PAYLOAD}" \
  "${POLLING_BASE}&sid=${SID}&t=$(date +%s%3N)" >/dev/null

VSCODE_PORT=$((BASE_PORT + 3))  # 39378 equivalent
NOVNC_PORT=$((BASE_PORT + 5))   # 39380 equivalent

echo "Screenshot collection trigger sent. View logs via http://localhost:${VSCODE_PORT}/?folder=/var/log/cmux"

echo ""
echo "================================ URLs ================================="
printf "| %-18s | %s |\n" "Worker Logs" "http://localhost:${VSCODE_PORT}/?folder=/var/log/cmux"
printf "| %-18s | %s |\n" "Workspace" "http://localhost:${VSCODE_PORT}/?folder=/root/workspace"
printf "| %-18s | %s |\n" "VS Code" "http://localhost:${VSCODE_PORT}/?folder=/root/workspace"
printf "| %-18s | %s |\n" "noVNC" "http://localhost:${NOVNC_PORT}/vnc.html"
echo "========================================================================"

if [ -n "$EXEC_COMMAND" ]; then
  echo "Executing command inside container: $EXEC_COMMAND"
  docker exec "$CONTAINER_NAME" bash -lc "$EXEC_COMMAND"
fi

if [ "$NON_INTERACTIVE" = false ] && [ -t 0 ]; then
  echo ""
  echo "Leave this script running while you inspect the worker."
  echo "Press Enter (or Ctrl+C) when you're ready to stop the container."
  read -r _
elif [ "$NON_INTERACTIVE" = false ]; then
  echo ""
  echo "Non-interactive shell detected; keeping the container alive for 5 minutes before cleanup."
  sleep 300
fi

fetch_screenshots() {
  if ! docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
    echo "Container is not running; skipping automatic screenshot download."
    return
  fi

  echo "Waiting for screenshots to appear in the container..."
  local latest=""
  local latest_mtime=""
  local has_files=""
  local target_dir=""
  local starting_latest="$INITIAL_SCREENSHOT_DIR"
  local starting_mtime="$INITIAL_SCREENSHOT_MTIME"
  local run_started_at="$RUN_START_TS"

  if [ -z "$run_started_at" ]; then
    run_started_at=$(date +%s)
  fi

  for _ in {1..36}; do
    latest=$(docker exec "$CONTAINER_NAME" bash -lc 'ls -1t /root/screenshots 2>/dev/null | head -1 || true')
    if [ -n "$latest" ]; then
      latest_mtime=$(docker exec "$CONTAINER_NAME" bash -lc 'stat -c %Y "/root/screenshots/'"$latest"'" 2>/dev/null || true')
      has_files=$(docker exec "$CONTAINER_NAME" bash -lc 'ls -A "/root/screenshots/'"$latest"'" 2>/dev/null | head -1 || true')
      is_new_dir=false
      if [ "$latest" != "$starting_latest" ]; then
        is_new_dir=true
      elif [ -n "$latest_mtime" ] && [ "$latest_mtime" -ge "$run_started_at" ]; then
        is_new_dir=true
      elif [ -n "$starting_mtime" ] && [ -n "$latest_mtime" ] && [ "$latest_mtime" -gt "$starting_mtime" ]; then
        is_new_dir=true
      fi

      if [ "$is_new_dir" = true ] && [ -n "$has_files" ]; then
        target_dir="$latest"
        break
      fi
    fi
    sleep 10
  done

  if [ -z "$target_dir" ]; then
    echo "No new screenshots were found in the container after waiting."
    return
  fi

  echo "Found screenshots in /root/screenshots/$target_dir. Copying to host..."
  docker exec "$CONTAINER_NAME" bash -lc 'tar -czf /tmp/cmux-screenshots.tgz -C /root/screenshots '"$target_dir"'' || {
    echo "Failed to create screenshots archive inside container."
    return
  }

  mkdir -p "$HOST_OUTPUT_ROOT"
  rm -rf "$HOST_OUTPUT_DIR" "$HOST_OUTPUT_TGZ"
  docker cp "$CONTAINER_NAME:/tmp/cmux-screenshots.tgz" "$HOST_OUTPUT_TGZ" || {
    echo "Failed to copy screenshots archive from container."
    return
  }

  mkdir -p "$HOST_OUTPUT_DIR"
  tar -xzf "$HOST_OUTPUT_TGZ" -C "$HOST_OUTPUT_DIR"
  local extracted_dir="$HOST_OUTPUT_DIR/$target_dir"

  # Write a simple structured output JSON alongside the images using host paths
  # If the container wrote a manifest.json, use its hasUiChanges value and image descriptions
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<PY
import json, os, glob
latest = "${target_dir}"
base_dir = os.path.join("${HOST_OUTPUT_DIR}", latest)
images = sorted(glob.glob(os.path.join(base_dir, "*.*")))
# Filter out manifest.json from images list
images = [img for img in images if not img.endswith("manifest.json")]

# Try to read the container's manifest.json for hasUiChanges and descriptions
container_manifest_path = os.path.join(base_dir, "manifest.json")
has_ui_changes = bool(images)  # default: true if there are images
description_map = {}

if os.path.exists(container_manifest_path):
    try:
        with open(container_manifest_path, "r") as f:
            container_manifest = json.load(f)
        if "hasUiChanges" in container_manifest:
            has_ui_changes = container_manifest["hasUiChanges"]
            print(f"Read hasUiChanges={has_ui_changes} from container manifest")
        # Build a map of filename -> description for matching
        for img_info in container_manifest.get("images", []):
            img_path = img_info.get("path", "")
            img_desc = img_info.get("description")
            if img_path and img_desc:
                filename = os.path.basename(img_path)
                description_map[filename] = img_desc
    except Exception as e:
        print(f"Warning: Could not read container manifest: {e}")

# Build payload with descriptions from container manifest
image_entries = []
for path in images:
    entry = {"path": os.path.abspath(path)}
    filename = os.path.basename(path)
    if filename in description_map:
        entry["description"] = description_map[filename]
    image_entries.append(entry)

payload = {
    "hasUiChanges": has_ui_changes,
    "images": image_entries,
}
out_path = os.path.join("${HOST_OUTPUT_ROOT}", "cmux-screenshots-latest.json")
with open(out_path, "w") as f:
    json.dump(payload, f, indent=2)
print(f"Wrote JSON manifest: {out_path}")
PY
  else
    echo "python3 not available; skipping JSON manifest generation."
  fi

  echo "Screenshots extracted to: $extracted_dir"
}

fetch_screenshots

# Drain any pending poll so server can close cleanly once we're done
curl -s "${POLLING_BASE}&sid=${SID}&t=$(date +%s%3N)" >/dev/null || true

cleanup
