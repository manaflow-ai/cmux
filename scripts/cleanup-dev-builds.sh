#!/usr/bin/env bash
# Clean up tagged dev-build artifacts created by scripts/reload.sh.
#
# Each `./scripts/reload.sh --tag <tag>` produces:
#   ~/Library/Developer/Xcode/DerivedData/cmux-<tag>/      (multi-GB)
#   /tmp/cmux-<tag>/                                       (build scratch)
#   /tmp/cmux-debug-<tag>.sock                             (control socket)
#   /tmp/cmux-debug-<tag>.log                              (debug log)
#   /tmp/cmux-reload-<tag>.log                             (build log)
#   ~/Library/Application Support/cmux/cmuxd-dev-<tag>.sock (cmuxd socket)
#
# This script removes those artifacts for tags that are safe to clean.
# Safety rules (always on):
#   - Skip any tag whose `cmux DEV <tag>` app is currently running.
#   - Skip the tag pointed at by /tmp/cmux-last-cli-path (most recent reload).
# A worktree merely existing on the same name is not treated as a
# protection. Use --keep TAG when you want to preserve a build whose
# worktree you still have around, or --older-than DAYS to skip anything
# you have touched recently.
#
# Defaults to dry-run. Pass --apply to actually delete.
#
# Filters:
#   --older-than <DAYS>   Only touch tags whose DerivedData mtime is at
#                         least DAYS days old.
#   --keep <TAG>          Protect a tag (repeatable).
#   --terminate-terminal-backends
#                         Permit unregistering persistent terminal backends.
#                         This terminates every PTY owned by those backends.
#   --apply               Delete instead of preview.
#
# Examples:
#   ./scripts/cleanup-dev-builds.sh
#   ./scripts/cleanup-dev-builds.sh --older-than 7
#   ./scripts/cleanup-dev-builds.sh --keep sidebar-lazy --keep txtbox --apply

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/mobile-attach.sh
source "$SCRIPT_DIR/lib/mobile-attach.sh"
TERMINAL_BACKEND_IDENTITY_TOOL="$SCRIPT_DIR/terminal-backend-identity.py"
DERIVED_DATA_ROOT="$HOME/Library/Developer/Xcode/DerivedData"
APP_SUPPORT_DIR="$HOME/Library/Application Support/cmux"
LAST_CLI_PATH_FILE="/tmp/cmux-last-cli-path"

apply=0
terminate_terminal_backends=0
older_than_days=0
keep_tags=()

usage() {
    awk '/^# / && !/^#!/ {sub(/^# ?/, ""); print; next} /^set -euo/ {exit}' "$0"
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply) apply=1; shift ;;
        --terminate-terminal-backends) terminate_terminal_backends=1; shift ;;
        --older-than)
            older_than_days="${2:?--older-than requires DAYS}"
            shift 2
            ;;
        --keep)
            keep_tags+=("${2:?--keep requires TAG}")
            shift 2
            ;;
        -h|--help) usage 0 ;;
        *) echo "unknown arg: $1" >&2; usage 2 ;;
    esac
done

# ---- discovery --------------------------------------------------------------

# Tags come from DerivedData dirs named cmux-<tag>. Authoritative because
# reload.sh always creates one there.
discover_tags() {
    [[ -d "$DERIVED_DATA_ROOT" ]] || return 0
    local d name
    for d in "$DERIVED_DATA_ROOT"/cmux-*/; do
        # The glob leaves the literal pattern if no matches exist on macOS.
        [[ -d "$d" ]] || continue
        name="${d%/}"
        name="${name##*/}"
        printf '%s\n' "${name#cmux-}"
    done
}

artifact_paths_for_tag() {
    local tag="$1"
    printf '%s\n' \
        "$DERIVED_DATA_ROOT/cmux-${tag}" \
        "/tmp/cmux-${tag}" \
        "/tmp/cmux-${tag}.tar" \
        "/tmp/cmux-debug-${tag}.sock" \
        "/tmp/cmux-debug-${tag}.log" \
        "/tmp/cmux-reload-${tag}.log" \
        "$APP_SUPPORT_DIR/cmuxd-dev-${tag}.sock"
}

bytes_in_path() {
    local p="$1"
    [[ -e "$p" || -L "$p" ]] || { echo 0; return; }
    # du -sk reports KB, portable across macOS and Linux. Convert to bytes.
    local kb
    kb="$(du -sk "$p" 2>/dev/null | awk '{print $1}')"
    [[ -n "$kb" ]] || kb=0
    echo "$((kb * 1024))"
}

human_bytes() {
    local b="$1"
    awk -v b="$b" 'BEGIN {
        split("B KB MB GB TB", u);
        for (i = 1; b >= 1024 && i < 5; i++) b /= 1024;
        printf "%.1f %s", b, u[i];
    }'
}

derived_data_mtime_days() {
    local p="$1"
    [[ -e "$p" ]] || { echo -1; return; }
    local mtime
    mtime="$(stat -f %m "$p" 2>/dev/null || stat -c %Y "$p" 2>/dev/null)"
    local now
    now="$(date +%s)"
    echo $(( (now - mtime) / 86400 ))
}

# Populated by probe_maintenance_bundle_for_tag. A return status of 0 means one
# exact, fully validated tagged bundle owns both maintenance entrypoints. Status
# 1 means no maintenance-capable bundle exists. Status 2 means an ambiguous or
# malformed bundle exists and the tag must be preserved.
MAINTENANCE_APP=""
MAINTENANCE_EXECUTABLE=""
MAINTENANCE_BUNDLE_ID=""
MAINTENANCE_SERVICE_LABEL=""
MAINTENANCE_FINGERPRINT=""
MAINTENANCE_PROBE_REASON=""

maintenance_files_fingerprint() {
    /usr/bin/python3 - "$@" <<'PY'
import os
import sys

parts = []
for path in sys.argv[1:]:
    stat = os.stat(path, follow_symlinks=False)
    parts.append(f"{path}:{stat.st_dev}:{stat.st_ino}:{stat.st_size}:{stat.st_mtime_ns}")
print(";".join(parts))
PY
}

products_have_maintenance_bundle() {
    local products="$1"
    local candidate=""
    local plist=""
    for candidate in "$products"/*.app; do
        [[ -d "$candidate" ]] || continue
        plist="$candidate/Contents/Info.plist"
        [[ -r "$plist" ]] || continue
        if /usr/libexec/PlistBuddy \
            -c 'Print :CMUXTerminalBackendServiceStatusCommand' \
            "$plist" >/dev/null 2>&1 || \
           /usr/libexec/PlistBuddy \
            -c 'Print :CMUXTerminalBackendServiceUnregisterCommand' \
            "$plist" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

probe_maintenance_bundle_for_tag() {
    local tag="$1"
    local products="$DERIVED_DATA_ROOT/cmux-${tag}/Build/Products/Debug"
    local app="$products/cmux DEV ${tag}.app"
    local plist="$app/Contents/Info.plist"
    local executable_name=""
    local status_command=""
    local unregister_command=""
    local expected_bundle_id=""
    local actual_bundle_id=""
    local expected_service_label=""
    local launch_plist=""
    local actual_service_label=""

    MAINTENANCE_APP=""
    MAINTENANCE_EXECUTABLE=""
    MAINTENANCE_BUNDLE_ID=""
    MAINTENANCE_SERVICE_LABEL=""
    MAINTENANCE_FINGERPRINT=""
    MAINTENANCE_PROBE_REASON=""

    if [[ ! -d "$app" || ! -r "$plist" ]]; then
        if products_have_maintenance_bundle "$products"; then
            MAINTENANCE_PROBE_REASON="canonical tagged app missing while another maintenance-capable app exists"
            return 2
        fi
        return 1
    fi

    status_command="$(/usr/libexec/PlistBuddy -c 'Print :CMUXTerminalBackendServiceStatusCommand' "$plist" 2>/dev/null || true)"
    unregister_command="$(/usr/libexec/PlistBuddy -c 'Print :CMUXTerminalBackendServiceUnregisterCommand' "$plist" 2>/dev/null || true)"
    if [[ -z "$status_command" && -z "$unregister_command" ]]; then
        if products_have_maintenance_bundle "$products"; then
            MAINTENANCE_PROBE_REASON="canonical tagged app has no maintenance contract while another app does"
            return 2
        fi
        return 1
    fi
    if [[ "$status_command" != "--terminal-backend-service-status" || \
          "$unregister_command" != "--unregister-terminal-backend-service" ]]; then
        MAINTENANCE_PROBE_REASON="canonical tagged app has an incomplete maintenance contract"
        return 2
    fi

    expected_bundle_id="$(cmux_attach_mac_bundle_id "$tag")"
    actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"
    if [[ "$actual_bundle_id" != "$expected_bundle_id" ]]; then
        MAINTENANCE_PROBE_REASON="canonical tagged app bundle identifier mismatch"
        return 2
    fi

    executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || true)"
    MAINTENANCE_EXECUTABLE="$app/Contents/MacOS/$executable_name"
    if [[ -z "$executable_name" || ! -x "$MAINTENANCE_EXECUTABLE" ]]; then
        MAINTENANCE_PROBE_REASON="canonical tagged app maintenance executable missing"
        return 2
    fi

    expected_service_label="$("$TERMINAL_BACKEND_IDENTITY_TOOL" \
        --bundle-id "$actual_bundle_id" \
        --field serviceLabel 2>/dev/null || true)"
    launch_plist="$app/Contents/Library/LaunchAgents/$expected_service_label.plist"
    actual_service_label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$launch_plist" 2>/dev/null || true)"
    if [[ -z "$expected_service_label" || "$actual_service_label" != "$expected_service_label" ]]; then
        MAINTENANCE_PROBE_REASON="canonical tagged app terminal backend service identity mismatch"
        return 2
    fi

    MAINTENANCE_FINGERPRINT="$(maintenance_files_fingerprint \
        "$plist" \
        "$MAINTENANCE_EXECUTABLE" \
        "$launch_plist")" || {
        MAINTENANCE_PROBE_REASON="canonical tagged app changed during validation"
        return 2
    }
    MAINTENANCE_APP="$app"
    MAINTENANCE_BUNDLE_ID="$actual_bundle_id"
    MAINTENANCE_SERVICE_LABEL="$expected_service_label"
    return 0
}

maintenance_record() {
    printf '%s|%s|%s|%s|%s' \
        "$MAINTENANCE_APP" \
        "$MAINTENANCE_EXECUTABLE" \
        "$MAINTENANCE_BUNDLE_ID" \
        "$MAINTENANCE_SERVICE_LABEL" \
        "$MAINTENANCE_FINGERPRINT"
}

run_backend_status() {
    local executable="$1"
    python3 - "$executable" <<'PY'
import subprocess
import sys

try:
    result = subprocess.run(
        [sys.argv[1], "--terminal-backend-service-status"],
        timeout=5,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
except subprocess.TimeoutExpired:
    raise SystemExit(124)
if result.returncode != 0:
    raise SystemExit(result.returncode)
value = result.stdout.strip()
if value not in {"not-registered", "enabled", "requires-approval", "not-found"}:
    raise SystemExit(65)
print(value)
PY
}

run_backend_unregistration() {
    local executable="$1"
    python3 - "$executable" <<'PY'
import subprocess
import sys

try:
    result = subprocess.run(
        [sys.argv[1], "--unregister-terminal-backend-service"],
        timeout=30,
        check=False,
    )
except subprocess.TimeoutExpired:
    print("error: terminal backend unregistration timed out after 30 seconds", file=sys.stderr)
    raise SystemExit(124)
raise SystemExit(result.returncode)
PY
}

# ---- safety probes ----------------------------------------------------------

# Active tag (most recent reload) per the CLI symlink target. Match
# `/cmux-<tag>/` anywhere in the path so we cover paths under DerivedData,
# /tmp, or other locations reload.sh may emit.
active_tag=""
if [[ -r "$LAST_CLI_PATH_FILE" ]]; then
    last_path="$(cat "$LAST_CLI_PATH_FILE" 2>/dev/null || true)"
    if [[ "$last_path" =~ /cmux-([A-Za-z0-9._-]+)/ ]]; then
        active_tag="${BASH_REMATCH[1]}"
    fi
fi

# Running cmux DEV processes by tag (the app name embeds the tag).
running_tags=()
while IFS= read -r line; do
    # Match "cmux DEV <tag>" (with or without .app suffix).
    if [[ "$line" =~ cmux\ DEV\ ([A-Za-z0-9._-]+) ]]; then
        running_tags+=("${BASH_REMATCH[1]}")
    fi
done < <(pgrep -fl "cmux DEV " 2>/dev/null || true)

# ---- planning ---------------------------------------------------------------

contains() {
    local needle="$1"; shift
    for x in "$@"; do
        [[ "$x" == "$needle" ]] && return 0
    done
    return 1
}

declare -a plan_delete=()
declare -a plan_skip=()
total_bytes=0

while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    reasons=()

    if [[ "$tag" == "$active_tag" ]]; then
        reasons+=("active (most recent reload)")
    fi
    if contains "$tag" ${running_tags[@]+"${running_tags[@]}"}; then
        reasons+=("app running")
    fi
    if contains "$tag" ${keep_tags[@]+"${keep_tags[@]}"}; then
        reasons+=("--keep")
    fi
    maintenance_probe_status=0
    probe_maintenance_bundle_for_tag "$tag" || maintenance_probe_status=$?
    planned_maintenance_record=""
    if (( maintenance_probe_status == 0 )); then
        planned_maintenance_record="$(maintenance_record)"
        if backend_status="$(run_backend_status "$MAINTENANCE_EXECUTABLE")"; then
            case "$backend_status" in
                enabled|requires-approval)
                    if (( terminate_terminal_backends == 0 )); then
                        reasons+=("persistent terminal backend; use --terminate-terminal-backends to terminate its PTYs")
                    fi
                    ;;
                not-registered) ;;
                not-found)
                    reasons+=("terminal backend service status not found; preserving app")
                    ;;
            esac
        else
            reasons+=("terminal backend service status query failed; preserving app")
        fi
    elif (( maintenance_probe_status == 2 )); then
        reasons+=("terminal backend maintenance identity is unsafe: $MAINTENANCE_PROBE_REASON; preserving app")
    fi
    if (( older_than_days > 0 )); then
        age="$(derived_data_mtime_days "$DERIVED_DATA_ROOT/cmux-${tag}")"
        # age == -1 means the DerivedData dir is gone (e.g., manually
        # deleted while orphan sockets/logs remain). Treat as "no age
        # signal, age filter does not apply" so the residue still gets
        # cleaned. Otherwise apply the threshold normally.
        if (( age >= 0 && age < older_than_days )); then
            reasons+=("age ${age}d < ${older_than_days}d")
        fi
    fi

    tag_bytes=0
    while IFS= read -r p; do
        tag_bytes=$(( tag_bytes + $(bytes_in_path "$p") ))
    done < <(artifact_paths_for_tag "$tag")

    if (( ${#reasons[@]} == 0 )); then
        plan_delete+=("$tag|$tag_bytes|$planned_maintenance_record")
        total_bytes=$(( total_bytes + tag_bytes ))
    else
        IFS=, ; reason_str="${reasons[*]}" ; IFS=$' \t\n'
        plan_skip+=("$tag|$tag_bytes|$reason_str")
    fi
done < <(discover_tags | sort)

# ---- output -----------------------------------------------------------------

printf 'cleanup-dev-builds  (mode: %s)\n\n' "$([[ $apply -eq 1 ]] && echo APPLY || echo DRY-RUN)"

if (( ${#plan_skip[@]} > 0 )); then
    printf 'skipping:\n'
    for entry in "${plan_skip[@]}"; do
        IFS='|' read -r tag bytes reason <<< "$entry"
        printf '  %-40s %10s  (%s)\n' "$tag" "$(human_bytes "$bytes")" "$reason"
    done
    echo
fi

if (( ${#plan_delete[@]} == 0 )); then
    printf 'nothing to clean.\n'
    exit 0
fi

printf 'would delete:\n'
for entry in "${plan_delete[@]}"; do
    IFS='|' read -r tag bytes _ <<< "$entry"
    printf '  %-40s %10s\n' "$tag" "$(human_bytes "$bytes")"
done
printf '\ntotal reclaimable: %s across %d tag(s)\n' "$(human_bytes "$total_bytes")" "${#plan_delete[@]}"

if (( apply == 0 )); then
    printf '\nDry run. Re-run with --apply to delete.\n'
    exit 0
fi

echo
echo 'applying...'
freed_bytes=0
for entry in "${plan_delete[@]}"; do
    IFS='|' read -r \
        tag \
        tag_bytes \
        planned_app \
        planned_executable \
        planned_bundle_id \
        planned_service_label \
        planned_fingerprint \
        <<< "$entry"
    planned_maintenance_record=""
    if [[ -n "${planned_app:-}" ]]; then
        planned_maintenance_record="$planned_app|$planned_executable|$planned_bundle_id|$planned_service_label|$planned_fingerprint"
    fi

    maintenance_probe_status=0
    probe_maintenance_bundle_for_tag "$tag" || maintenance_probe_status=$?
    if (( maintenance_probe_status == 2 )); then
        printf '  skipped: %s (backend maintenance identity unsafe: %s; artifacts preserved)\n' \
            "$tag" "$MAINTENANCE_PROBE_REASON" >&2
        continue
    fi
    if (( maintenance_probe_status == 0 )); then
        current_maintenance_record="$(maintenance_record)"
        if [[ -z "$planned_maintenance_record" || \
              "$current_maintenance_record" != "$planned_maintenance_record" ]]; then
            printf '  skipped: %s (backend maintenance bundle changed after planning; artifacts preserved)\n' "$tag" >&2
            continue
        fi
        if ! backend_status="$(run_backend_status "$MAINTENANCE_EXECUTABLE")"; then
            printf '  skipped: %s (backend status query failed; artifacts preserved)\n' "$tag" >&2
            continue
        fi

        # The status executable is app code and may race a rebuild. Pin the
        # exact bundle, service identity, and file identities across the call.
        maintenance_probe_status=0
        probe_maintenance_bundle_for_tag "$tag" || maintenance_probe_status=$?
        if (( maintenance_probe_status != 0 )) || \
           [[ "$(maintenance_record)" != "$planned_maintenance_record" ]]; then
            printf '  skipped: %s (backend maintenance bundle changed during status; artifacts preserved)\n' "$tag" >&2
            continue
        fi
        case "$backend_status" in
            enabled|requires-approval)
                if (( terminate_terminal_backends == 0 )); then
                    printf '  skipped: %s (persistent terminal backend preserved)\n' "$tag" >&2
                    continue
                fi
                printf '  WARNING: unregistering %s terminates every PTY owned by its terminal backend.\n' "$tag" >&2
                if ! run_backend_unregistration "$MAINTENANCE_EXECUTABLE"; then
                    printf '  skipped: %s (backend unregistration failed; artifacts preserved)\n' "$tag" >&2
                    continue
                fi
                maintenance_probe_status=0
                probe_maintenance_bundle_for_tag "$tag" || maintenance_probe_status=$?
                if (( maintenance_probe_status != 0 )) || \
                   [[ "$(maintenance_record)" != "$planned_maintenance_record" ]]; then
                    printf '  skipped: %s (backend maintenance bundle changed during unregister; artifacts preserved)\n' "$tag" >&2
                    continue
                fi
                if ! backend_status="$(run_backend_status "$MAINTENANCE_EXECUTABLE")" || \
                   [[ "$backend_status" != "not-registered" ]]; then
                    printf '  skipped: %s (backend did not confirm unregistration; artifacts preserved)\n' "$tag" >&2
                    continue
                fi
                ;;
            not-registered) ;;
            not-found)
                printf '  skipped: %s (backend service not found; artifacts preserved)\n' "$tag" >&2
                continue
                ;;
        esac
    elif [[ -n "$planned_maintenance_record" ]]; then
        printf '  skipped: %s (backend maintenance bundle disappeared after planning; artifacts preserved)\n' "$tag" >&2
        continue
    fi
    while IFS= read -r p; do
        if [[ -e "$p" || -L "$p" ]]; then
            rm -rf -- "$p"
        fi
    done < <(artifact_paths_for_tag "$tag")
    freed_bytes=$((freed_bytes + tag_bytes))
    printf '  removed: %s\n' "$tag"
done
# Estimated because freed_bytes was measured during planning. If a
# concurrent process (e.g., Xcode's "Delete Derived Data") removed a
# planned path between then and now, rm -rf skips it but the byte
# count still includes those bytes.
printf '\nfreed (estimated): %s\n' "$(human_bytes "$freed_bytes")"
