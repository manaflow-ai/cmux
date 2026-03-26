#!/usr/bin/env bash
set -euo pipefail

RELEASE_TAG="${CMUX_RELEASE_TAG:-v0.62.2}"
SHORTCUT="${CMUX_REPRO_SHORTCUT:-cmd-d}"
REPRO_DIR="${CMUX_REPRO_DIR:-${RUNNER_TEMP:-/tmp}/cmux-intel-release-repro}"
ARTIFACT_DIR="${REPRO_DIR}/artifacts"
DMG_PATH="${REPRO_DIR}/cmux-macos.dmg"
MOUNT_DIR="${REPRO_DIR}/mount"
APP_PATH="${REPRO_DIR}/cmux.app"
APP_BINARY="${APP_PATH}/Contents/MacOS/cmux"
APP_CLI="${APP_PATH}/Contents/Resources/bin/cmux"
APP_LOG="${ARTIFACT_DIR}/app.log"
CLI_LOG="${ARTIFACT_DIR}/cli.log"
RESULT_LOG="${ARTIFACT_DIR}/result.txt"
SHORTCUT_LOG="${ARTIFACT_DIR}/shortcut.log"
SYSTEM_INFO_LOG="${ARTIFACT_DIR}/system-info.txt"
BEFORE_JSON="${ARTIFACT_DIR}/before-list-panes.json"
AFTER_JSON="${ARTIFACT_DIR}/after-list-panes.json"
CRASH_DIR="${ARTIFACT_DIR}/crash-reports"
SWIFT_HELPER_SRC="${REPRO_DIR}/send-shortcut.swift"
SWIFT_HELPER_BIN="${REPRO_DIR}/send-shortcut"
APP_PID=""
BEFORE_CRASH_LIST="${REPRO_DIR}/before-crash-list.txt"

mkdir -p "${ARTIFACT_DIR}" "${CRASH_DIR}" "${MOUNT_DIR}"
: > "${APP_LOG}"
: > "${CLI_LOG}"
: > "${SHORTCUT_LOG}"
: > "${RESULT_LOG}"

cleanup() {
  if [[ -n "${APP_PID}" ]] && kill -0 "${APP_PID}" 2>/dev/null; then
    kill "${APP_PID}" 2>/dev/null || true
    wait "${APP_PID}" 2>/dev/null || true
  fi
  if mount | grep -F "on ${MOUNT_DIR} " >/dev/null 2>&1; then
    hdiutil detach "${MOUNT_DIR}" -quiet || true
  fi
}
trap cleanup EXIT

log() {
  printf '%s\n' "$*" | tee -a "${RESULT_LOG}"
}

record_system_info() {
  {
    echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "release_tag=${RELEASE_TAG}"
    echo "shortcut=${SHORTCUT}"
    echo "uname=$(uname -a)"
    echo "arch=$(uname -m)"
    echo "sw_vers:"
    sw_vers
    echo "sysctl machdep.cpu.brand_string:"
    sysctl machdep.cpu.brand_string 2>/dev/null || true
  } > "${SYSTEM_INFO_LOG}"
}

new_crash_report_paths() {
  python3 - <<'PY' "${BEFORE_CRASH_LIST}"
from pathlib import Path
import sys

before = set()
before_path = Path(sys.argv[1])
if before_path.exists():
    before = {line.strip() for line in before_path.read_text().splitlines() if line.strip()}

diag = Path.home() / "Library/Logs/DiagnosticReports"
if diag.exists():
    candidates = sorted(
        [p for p in diag.glob("*cmux*") if p.is_file()],
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    for path in candidates:
        if str(path) not in before:
            print(path)
PY
}

copy_recent_crash_reports() {
  local dest="${CRASH_DIR}/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "${dest}"
  local found=0
  local report_paths=""

  if [[ -n "${APP_PID}" ]] && ! kill -0 "${APP_PID}" 2>/dev/null; then
    for _ in $(seq 1 10); do
      report_paths="$(new_crash_report_paths)"
      if [[ -n "${report_paths}" ]]; then
        break
      fi
      sleep 1
    done
  else
    report_paths="$(new_crash_report_paths)"
  fi

  while IFS= read -r report_path; do
    [[ -z "${report_path}" ]] && continue
    cp "${report_path}" "${dest}/" 2>/dev/null || true
    found=1
  done <<< "${report_paths}"
  if [[ "${found}" -eq 0 ]]; then
    echo "(none)" > "${dest}/none.txt"
  fi
}

fail() {
  log "FAIL: $*"
  copy_recent_crash_reports
  {
    echo
    echo "--- app.log ---"
    tail -n 200 "${APP_LOG}" 2>/dev/null || true
    echo
    echo "--- cli.log ---"
    tail -n 200 "${CLI_LOG}" 2>/dev/null || true
    echo
    echo "--- shortcut.log ---"
    tail -n 200 "${SHORTCUT_LOG}" 2>/dev/null || true
  } >> "${RESULT_LOG}"
  exit 1
}

capture_existing_crash_list() {
  : > "${BEFORE_CRASH_LIST}"
  if [[ -d "${HOME}/Library/Logs/DiagnosticReports" ]]; then
    find "${HOME}/Library/Logs/DiagnosticReports" -maxdepth 1 -type f -name '*cmux*' -print | sort > "${BEFORE_CRASH_LIST}" || true
  fi
}

download_release_dmg() {
  local url="https://github.com/manaflow-ai/cmux/releases/download/${RELEASE_TAG}/cmux-macos.dmg"
  log "Downloading ${url}"
  curl -fL --retry 5 --retry-delay 2 --retry-all-errors "${url}" -o "${DMG_PATH}"
}

install_release_app() {
  hdiutil attach "${DMG_PATH}" -mountpoint "${MOUNT_DIR}" -nobrowse -quiet
  local mounted_app="${MOUNT_DIR}/cmux.app"
  [[ -d "${mounted_app}" ]] || fail "Mounted DMG did not contain cmux.app"
  rm -rf "${APP_PATH}"
  ditto "${mounted_app}" "${APP_PATH}"
  xattr -dr com.apple.quarantine "${APP_PATH}" 2>/dev/null || true
  [[ -x "${APP_BINARY}" ]] || fail "Installed app binary not found at ${APP_BINARY}"
  [[ -x "${APP_CLI}" ]] || fail "Bundled CLI not found at ${APP_CLI}"
  {
    echo "app_binary=${APP_BINARY}"
    echo "app_cli=${APP_CLI}"
    echo "app_archs=$(lipo -archs "${APP_BINARY}" 2>/dev/null || file "${APP_BINARY}")"
    echo "bundle_id=$(defaults read "${APP_PATH}/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo unknown)"
    echo "bundle_version=$(defaults read "${APP_PATH}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo unknown)"
    echo "bundle_build=$(defaults read "${APP_PATH}/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo unknown)"
  } >> "${SYSTEM_INFO_LOG}"
}

launch_release_app() {
  pkill -f "/cmux.app/Contents/MacOS/cmux$" 2>/dev/null || true
  sleep 1
  CMUX_SOCKET_MODE=allowAll "${APP_BINARY}" > "${APP_LOG}" 2>&1 &
  APP_PID=$!
  log "Launched ${APP_BINARY} pid=${APP_PID}"
}

wait_for_process_launch() {
  for _ in $(seq 1 20); do
    if kill -0 "${APP_PID}" 2>/dev/null; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

run_cli_json() {
  local output_path="$1"
  CMUX_CLI_SENTRY_DISABLED=1 "${APP_CLI}" --json list-panes > "${output_path}" 2>> "${CLI_LOG}"
}

wait_for_cli_ready() {
  local output_path="$1"
  for _ in $(seq 1 60); do
    if ! kill -0 "${APP_PID}" 2>/dev/null; then
      return 2
    fi
    if run_cli_json "${output_path}"; then
      local current_count
      current_count="$(pane_count "${output_path}")" || return 1
      if (( current_count >= 1 )); then
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

pane_count() {
  local json_path="$1"
  python3 - <<'PY' "${json_path}"
from pathlib import Path
import json
import sys

payload = json.loads(Path(sys.argv[1]).read_text() or "{}")
print(len(payload.get("panes", [])))
PY
}

write_swift_shortcut_helper() {
  cat > "${SWIFT_HELPER_SRC}" <<'EOF'
import AppKit
import CoreGraphics
import Foundation

let shortcut = CommandLine.arguments.dropFirst().first ?? "cmd-d"

func shortcutSpec(_ raw: String) -> (CGKeyCode, CGEventFlags)? {
    switch raw {
    case "cmd-d":
        return (2, .maskCommand)
    case "cmd-shift-d":
        return (2, [.maskCommand, .maskShift])
    default:
        return nil
    }
}

guard let runningApp = NSWorkspace.shared.runningApplications.first(where: { ($0.localizedName ?? "") == "cmux" }) else {
    fputs("No running cmux app found\n", stderr)
    exit(1)
}

guard let (keyCode, flags) = shortcutSpec(shortcut) else {
    fputs("Unsupported shortcut: \(shortcut)\n", stderr)
    exit(1)
}

guard runningApp.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]) else {
    fputs("Failed to activate cmux\n", stderr)
    exit(1)
}

RunLoop.current.run(until: Date().addingTimeInterval(1.0))

guard let source = CGEventSource(stateID: .combinedSessionState) else {
    fputs("Could not create event source\n", stderr)
    exit(1)
}

for keyDown in [true, false] {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
        fputs("Could not create keyboard event\n", stderr)
        exit(1)
    }
    event.flags = flags
    event.post(tap: .cghidEventTap)
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}

print("Sent \(shortcut) to cmux pid=\(runningApp.processIdentifier)")
EOF
  swiftc "${SWIFT_HELPER_SRC}" -o "${SWIFT_HELPER_BIN}"
}

send_shortcut_via_osascript() {
  local keystroke_expr
  case "${SHORTCUT}" in
    cmd-d)
      keystroke_expr='keystroke "d" using command down'
      ;;
    cmd-shift-d)
      keystroke_expr='keystroke "d" using {command down, shift down}'
      ;;
    *)
      fail "Unsupported shortcut ${SHORTCUT}"
      ;;
  esac

  osascript > "${SHORTCUT_LOG}" 2>&1 <<EOF
tell application "cmux" to activate
delay 1
tell application "System Events"
  ${keystroke_expr}
end tell
EOF
}

send_shortcut_via_swift() {
  write_swift_shortcut_helper
  "${SWIFT_HELPER_BIN}" "${SHORTCUT}" > "${SHORTCUT_LOG}" 2>&1
}

wait_for_expected_result() {
  local expected_count="$1"
  local output_path="$2"
  for _ in $(seq 1 12); do
    if ! kill -0 "${APP_PID}" 2>/dev/null; then
      return 2
    fi
    if run_cli_json "${output_path}"; then
      local current_count
      current_count="$(pane_count "${output_path}")"
      if [[ "${current_count}" == "${expected_count}" ]]; then
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

attempt_shortcut() {
  local method="$1"
  local expected_count="$2"
  : > "${SHORTCUT_LOG}"
  log "Triggering ${SHORTCUT} via ${method}"
  case "${method}" in
    osascript)
      if ! send_shortcut_via_osascript; then
        log "Shortcut via osascript failed"
        return 1
      fi
      ;;
    swift)
      if ! send_shortcut_via_swift; then
        log "Shortcut via swift helper failed"
        return 1
      fi
      ;;
    *)
      fail "Unknown shortcut method ${method}"
      ;;
  esac
  wait_for_expected_result "${expected_count}" "${AFTER_JSON}"
}

main() {
  record_system_info || fail "Failed to capture system info"
  capture_existing_crash_list || fail "Failed to capture existing crash list"
  download_release_dmg || fail "Failed to download release DMG"
  install_release_app || fail "Failed to install release app"
  launch_release_app || fail "Failed to launch release app"

  if ! wait_for_process_launch; then
    fail "cmux app process never stayed alive after launch"
  fi

  local cli_status=0
  if wait_for_cli_ready "${BEFORE_JSON}"; then
    :
  else
    cli_status=$?
    if [[ "${cli_status}" -eq 2 ]]; then
      fail "cmux crashed before the CLI became ready"
    fi
    fail "cmux CLI never became ready"
  fi

  local before_count
  before_count="$(pane_count "${BEFORE_JSON}")" || fail "Failed to parse initial pane list"
  log "Pane count before shortcut: ${before_count}"
  local expected_count=$((before_count + 1))

  local shortcut_status=0
  if attempt_shortcut osascript "${expected_count}"; then
    :
  else
    shortcut_status=$?
    if [[ "${shortcut_status}" -eq 2 ]]; then
      fail "${SHORTCUT} crashed the app via osascript path"
    fi
    log "No split observed after osascript attempt"
    if attempt_shortcut swift "${expected_count}"; then
      :
    else
      shortcut_status=$?
      if [[ "${shortcut_status}" -eq 2 ]]; then
        fail "${SHORTCUT} crashed the app via swift event path"
      fi
      fail "${SHORTCUT} did not create a second pane on the release app"
    fi
  fi

  local after_count
  after_count="$(pane_count "${AFTER_JSON}")" || fail "Failed to parse post-shortcut pane list"
  log "Pane count after shortcut: ${after_count}"

  if ! kill -0 "${APP_PID}" 2>/dev/null; then
    fail "cmux exited after reporting a successful pane split"
  fi

  log "PASS: ${SHORTCUT} created a split without crashing"
}

main "$@"
