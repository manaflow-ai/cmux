#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <derived-data-path> <source-packages-dir>" >&2
  exit 2
fi

derived_data_path="$1"
source_packages_dir="$2"
token="$(uuidgen | tr '[:upper:]' '[:lower:]')"
socket_path="/tmp/cmux-ui-test-project-worktree-description-${token}.sock"
diagnostics_path="/tmp/cmux-ui-test-project-worktree-description-${token}.json"
app_log_path="/tmp/cmux-ui-test-project-worktree-description-${token}.log"
snapshot_path="/tmp/cmux-ui-test-project-worktree-description-${token}-snapshot.json"
launch_tag="ui-tests-project-worktree-description-${token%%-*}"
repository_path="/tmp/cmux-ui-test-project-worktree-${token}"
branch="issue-4889-branch"
custom_description="Custom workspace description"
workspace_name="Issue 4889 ${token%%-*}"
app_pid=""

cleanup() {
  local exit_code=$?
  if [ -n "$app_pid" ] && kill -0 "$app_pid" 2>/dev/null; then
    kill -TERM "$app_pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      kill -0 "$app_pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$app_pid" 2>/dev/null; then
      kill -KILL "$app_pid" 2>/dev/null || true
    fi
    wait "$app_pid" 2>/dev/null || true
  fi
  if [ "$exit_code" -ne 0 ]; then
    echo "--- Project Worktrees prelaunched app diagnostics ---" >&2
    tail -80 "$app_log_path" >&2 2>/dev/null || true
    cat "$diagnostics_path" >&2 2>/dev/null || true
  fi
  rm -f "$socket_path" "$diagnostics_path" "$app_log_path" "$snapshot_path"
  rm -rf -- "$repository_path"
}
trap cleanup EXIT

xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug \
  -derivedDataPath "$derived_data_path" \
  -clonedSourcePackagesDirPath "$source_packages_dir" \
  -disableAutomaticPackageResolution \
  -destination "platform=macOS" \
  CMUX_SKIP_ZIG_BUILD=1 \
  build

products_path="$derived_data_path/Build/Products/Debug"
app_bundle="$products_path/cmux DEV.app"
app_binary="$app_bundle/Contents/MacOS/cmux DEV"
cli_binary="$app_bundle/Contents/Resources/bin/cmux"
if [ ! -x "$app_binary" ] || [ ! -x "$cli_binary" ]; then
  echo "Built app or bundled CLI is missing under $app_bundle" >&2
  exit 1
fi

run_cli() {
  env -u CMUX_SOCKET -u CMUX_SOCKET_PATH -u CMUX_SOCKET_PASSWORD \
    -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID -u CMUX_TAB_ID -u CMUX_PANEL_ID \
    -u CMUX_WINDOW_ID -u CMUX_TAG -u CMUX_BUNDLE_ID -u CMUX_BUNDLED_CLI_PATH \
    "$cli_binary" --socket "$socket_path" "$@"
}

rm -f "$socket_path" "$diagnostics_path" "$app_log_path" "$snapshot_path"
(
  unset CMUX_SOCKET CMUX_SOCKET_PASSWORD CMUX_WORKSPACE_ID CMUX_SURFACE_ID
  unset CMUX_TAB_ID CMUX_PANEL_ID CMUX_WINDOW_ID CMUX_BUNDLE_ID CMUX_BUNDLED_CLI_PATH
  export CMUX_UI_TEST_MODE=1
  export CMUX_SOCKET_ENABLE=1
  export CMUX_SOCKET_MODE=allowAll
  export CMUX_SOCKET_PATH="$socket_path"
  export CMUX_ALLOW_SOCKET_OVERRIDE=1
  export CMUX_UI_TEST_SOCKET_SANITY=1
  export CMUX_UI_TEST_DIAGNOSTICS_PATH="$diagnostics_path"
  export CMUX_TAG="$launch_tag"
  exec "$app_binary" \
    -socketControlMode allowAll \
    -AppleLanguages "(en)" \
    -AppleLocale en_US \
    -NSAppSleepDisabled YES \
    -cmuxExtensionSidebar.providerId com.example.cmux.sidebar.project-worktrees
) >"$app_log_path" 2>&1 &
app_pid=$!
echo "Prelaunched app PID: $app_pid"
echo "Prelaunched app socket: $socket_path"

app_ready=false
for _ in $(seq 1 120); do
  if ! kill -0 "$app_pid" 2>/dev/null; then
    echo "Prelaunched app exited before its socket became ready" >&2
    break
  fi
  if [ -S "$socket_path" ]; then
    ping_output="$(run_cli ping 2>/dev/null || true)"
    if [ "$ping_output" = "PONG" ]; then
      app_ready=true
      break
    fi
  fi
  sleep 0.25
done

if [ "$app_ready" != "true" ]; then
  echo "Prelaunched app did not expose a responsive socket within 30 seconds" >&2
  exit 1
fi

mkdir -p "$repository_path"
git init "$repository_path" >/dev/null
git -C "$repository_path" checkout -b "$branch" >/dev/null
git -C "$repository_path" config user.email "cmux-ui-test@example.test"
git -C "$repository_path" config user.name "cmux UI Test"
printf 'issue 4889 fixture\n' > "$repository_path/README.md"
git -C "$repository_path" add README.md
git -c commit.gpgsign=false -C "$repository_path" commit -m "Initial fixture" >/dev/null

creation_output="$(
  run_cli new-workspace \
    --name "$workspace_name" \
    --description "$custom_description" \
    --cwd "$repository_path" \
    --focus true
)"
if [[ "$creation_output" != OK\ * ]]; then
  echo "cmux new-workspace failed: $creation_output" >&2
  exit 1
fi
echo "Created described workspace: $creation_output"

sidebar_snapshot=""
snapshot_ready=false
for _ in $(seq 1 80); do
  sidebar_snapshot="$(run_cli rpc extension.sidebar.snapshot '{}' 2>/dev/null || true)"
  if [[ "$sidebar_snapshot" == *"$custom_description"* && "$sidebar_snapshot" == *"$branch"* ]]; then
    snapshot_ready=true
    break
  fi
  sleep 0.25
done
if [ "$snapshot_ready" != "true" ]; then
  echo "Extension sidebar snapshot never contained the described Git workspace: $sidebar_snapshot" >&2
  exit 1
fi
printf '%s\n' "$sidebar_snapshot" > "$snapshot_path"
echo "Extension sidebar snapshot contains description and branch"

env \
  CMUX_PROJECT_WORKTREE_SNAPSHOT_PATH="$snapshot_path" \
  CMUX_PROJECT_WORKTREE_EXPECTED_DESCRIPTION="$custom_description" \
  CMUX_PROJECT_WORKTREE_EXPECTED_BRANCH="$branch" \
  swift test \
    --package-path Examples/CmuxExtensionSidebarExamples \
    --scratch-path "$derived_data_path/ProjectWorktreeSidebarPackageTests" \
    --filter ProjectWorktreeSidebarTests/testLiveSnapshotUsesCustomDescriptionAsSubtitle
