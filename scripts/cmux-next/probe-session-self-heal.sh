#!/usr/bin/env bash
# Self-heal probe: the app recovers on its own from a slow or wedged session
# server and from a chat stream that stops (Leo, 2026-11-08: "it fixes itself").
#
#   scripts/cmux-next/probe-session-self-heal.sh [web|app|all]
#
# web: the chat page (webviews selfHeal.test.tsx, fake clock). Its socket stops
#      delivering while acpmux keeps writing turns, the first reconnect is
#      refused and the next handshake takes 12 s. It checks that the page shows
#      "Reconnecting…", then every turn exactly once.
# app: the app (Swift, macOS only). A stand-in `server ensure --restore-progress`
#      reports a restore for 3 s. It checks that the launch window and the
#      sidebar say "Restoring sessions…" with a growing time, and that the status
#      clears when the ensure answers. A chat clicked meanwhile waits and opens
#      once the sessions are ready (PendingOpenSlotTests).
#
# Each part prints one line:
#   SELF_HEAL_PROBE web time_to_recover_ms=<n> missed_turns=<n> duplicate_turns=<n>
#   SELF_HEAL_PROBE app restore_status_shown_after_ms=<n> connected_after_ms=<n>
# and the script exits non-zero when a part fails or a line is missing or
# reports a missed or duplicated turn.
#
# Run it on a fleet machine, never on a laptop:
#   cmux-ci test --setup webviews -- 'scripts/cmux-next/probe-session-self-heal.sh web'
#   cmux-ci run --os macos ... (or a Mac lane via `reach`) for `app`
set -euo pipefail
part="${1:-all}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
log="$(mktemp -t self-heal-probe.XXXXXX)"
trap 'rm -f "$log"' EXIT
status=0

run_web() {
  (cd "$root/webviews" && bun test src/agent-session/acpmux/selfHeal.test.tsx) 2>&1 | tee -a "$log" || status=1
  local line
  line="$(grep -m1 '^SELF_HEAL_PROBE web ' "$log" || true)"
  if [[ -z "$line" ]]; then
    echo "probe: the web part printed no SELF_HEAL_PROBE line" >&2
    status=1
  elif ! grep -q 'missed_turns=0 duplicate_turns=0' <<<"$line"; then
    echo "probe: the web part lost or repeated turns: $line" >&2
    status=1
  fi
}

run_app() {
  if [[ "$(uname -s)" != Darwin ]]; then
    echo "probe: the app part needs macOS; skipped here" >&2
    return
  fi
  (cd "$root/Packages/macOS/CmuxNext" &&
    swift test --filter 'DaemonRestoreProgressTests|RestoreProgressLinesTests|PendingOpenSlotTests') 2>&1 | tee -a "$log" || status=1
  grep -q '^SELF_HEAL_PROBE app ' "$log" || { echo "probe: the app part printed no SELF_HEAL_PROBE line" >&2; status=1; }
}

case "$part" in
  web) run_web ;;
  app) run_app ;;
  all) run_web; run_app ;;
  *) sed -n '2,26p' "$0"; exit 2 ;;
esac
echo "--- summary"
grep '^SELF_HEAL_PROBE ' "$log" || true
exit "$status"
