#!/usr/bin/env bash
# continue-nightly-next.sh: after a green feat-cmux-next Release compile, ask
# nightly-next for a continuation run (nightly_next_continue_only). It asks
# only when a recent completed nightly-next run still holds a pending
# notarization, and never twice within the throttle window (cx-f58x).
# No network: gh is stubbed.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SCRIPT="$ROOT/scripts/cmux-next/continue-nightly-next.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { printf '%s\n' "$@" >&2; exit 1; }

mkdir -p "$TMP/bin" "$TMP/api"
cat > "$TMP/bin/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/gh.log"
if [[ "\$1" == api ]]; then
  case "\$2" in
    repos/*/actions/workflows/nightly.yml/runs*) cat "$TMP/api/runs.json" 2>/dev/null || exit 1; exit 0 ;;
    repos/*/actions/runs/*/artifacts*) id="\${2#*/actions/runs/}"; f="$TMP/api/artifacts-\${id%%/*}.json"; [[ -f "\$f" ]] && cat "\$f" || echo '{"artifacts": []}'; exit 0 ;;
  esac
  exit 1
fi
exit 0
STUB
chmod +x "$TMP/bin/gh"

# Fixed clock: 2026-10-09T12:00:00Z.
NOW=1791547200
runs() { # <json entries>
  printf '{"workflow_runs": [%s]}\n' "$1" > "$TMP/api/runs.json"
}
run() { # <id> <event> <status> <created_at>
  printf '{"id": %s, "head_branch": "nightly-next", "event": "%s", "status": "%s", "created_at": "%s"}' "$1" "$2" "$3" "$4"
}
recovery() { # <run id>
  printf '{"artifacts": [{"name": "cmux-nightly-notarization-recovery-arm64-abc1234", "expired": false}, {"name": "cmux-nightly-unsigned-app", "expired": false}]}\n' > "$TMP/api/artifacts-$1.json"
}
invoke() {
  : > "$TMP/gh.log"
  PATH="$TMP/bin:$PATH" CMUX_NOW_EPOCH=$NOW bash "$SCRIPT" --repo manaflow-ai/cmux > "$TMP/out" 2>&1 || fail "the script must exit 0" "$(cat "$TMP/out")"
}
dispatched() { grep -q '^workflow run nightly.yml --repo manaflow-ai/cmux --ref nightly-next -f nightly_next_continue_only=true$' "$TMP/gh.log"; }

# 1. A pending notarization from 1h ago and no recent dispatch: ask once.
runs "$(run 3 push in_progress 2026-10-09T11:50:00Z), $(run 2 push completed 2026-10-09T11:00:00Z), $(run 1 push completed 2026-10-09T09:00:00Z)"
recovery 2
invoke
dispatched || fail "a pending notarization must request a continuation run" "$(cat "$TMP/out")"

# 2. A dispatch 10 minutes ago: do not ask again.
runs "$(run 4 workflow_dispatch in_progress 2026-10-09T11:50:00Z), $(run 2 push completed 2026-10-09T11:00:00Z)"
invoke
dispatched && fail "a dispatch inside the throttle window must not be repeated" "$(cat "$TMP/out")"

# 3. The dispatch is 40 minutes old: ask again.
runs "$(run 4 workflow_dispatch completed 2026-10-09T11:20:00Z), $(run 2 push completed 2026-10-09T11:00:00Z)"
invoke
dispatched || fail "a dispatch older than the throttle window must not block a continuation" "$(cat "$TMP/out")"

# 4. Only an old (7h) pending notarization: Apple's answer is final; do not ask.
rm -f "$TMP/api"/artifacts-*.json
runs "$(run 5 push completed 2026-10-09T05:00:00Z)"
recovery 5
invoke
dispatched && fail "a recovery artifact older than the age limit must not request a run" "$(cat "$TMP/out")"

# 5. No recovery artifact: do not ask.
rm -f "$TMP/api"/artifacts-*.json
runs "$(run 6 push completed 2026-10-09T11:00:00Z)"
invoke
dispatched && fail "no pending notarization must not request a run" "$(cat "$TMP/out")"

# 6. The runs query fails: warn, exit 0, do not ask.
rm -f "$TMP/api/runs.json"
invoke
dispatched && fail "a failed query must not request a run" "$(cat "$TMP/out")"

echo "PASS: continue-nightly-next requests a continuation only for a recent pending notarization, at most every 30 minutes"
