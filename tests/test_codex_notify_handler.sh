#!/usr/bin/env bash
# Regression tests for Resources/bin/codex-cmux-notify.sh
#
# Verifies that the notify handler extracts the last-assistant-message from
# Codex's AfterAgent JSON payload and emits the correct cmux commands.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NOTIFY_SCRIPT="$SCRIPT_DIR/../Resources/bin/codex-cmux-notify.sh"

FAILURES=0

expect() {
    local description="$1"
    local condition="$2"
    if ! eval "$condition"; then
        echo "FAIL: $description"
        FAILURES=$((FAILURES + 1))
    fi
}

run_notify() {
    local payload="$1"
    local tmpdir
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-codex-notify-test.XXXXXX")"
    trap "rm -rf '$tmpdir'" RETURN
    local cmux_log="$tmpdir/cmux.log"
    local fake_cmux="$tmpdir/cmux"

    cat > "$fake_cmux" << 'FAKECMUX'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_CMUX_LOG"
FAKECMUX
    chmod +x "$fake_cmux"

    FAKE_CMUX_LOG="$cmux_log" PATH="$tmpdir:$PATH" \
        bash "$NOTIFY_SCRIPT" "$payload" 2>/dev/null

    if [[ -f "$cmux_log" ]]; then
        cat "$cmux_log"
    fi
}

# Test 1: Valid JSON with last-assistant-message
OUTPUT="$(run_notify '{"type":"agent-turn-complete","last-assistant-message":"I fixed the bug in auth.ts"}')"
expect "extracts last-assistant-message" \
    '[[ "$OUTPUT" == *"notify --title Codex --body I fixed the bug in auth.ts"* ]]'
expect "sets idle status after turn" \
    '[[ "$OUTPUT" == *"set-status codex Idle --icon pause.circle.fill --color"* ]]'

# Test 2: JSON without last-assistant-message falls back to default
OUTPUT="$(run_notify '{"type":"agent-turn-complete"}')"
expect "falls back to Turn complete" \
    '[[ "$OUTPUT" == *"notify --title Codex --body Turn complete"* ]]'

# Test 3: Empty payload falls back to default
OUTPUT="$(run_notify '')"
expect "empty payload uses default message" \
    '[[ "$OUTPUT" == *"notify --title Codex --body Turn complete"* ]]'

# Test 4: Invalid JSON falls back to default
# shellcheck disable=SC2034
OUTPUT="$(run_notify 'not-json')"
expect "invalid JSON uses default message" \
    '[[ "$OUTPUT" == *"notify --title Codex --body Turn complete"* ]]'

if [[ "$FAILURES" -gt 0 ]]; then
    echo "FAIL: $FAILURES codex notify handler checks failed"
    exit 1
fi

echo "PASS: codex notify handler extracts messages and emits correct cmux commands"
