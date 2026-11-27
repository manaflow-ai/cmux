#!/usr/bin/env bash
# Diagnostic wrapper (c-3683c5e238): runs update-e2e.py, then saves the updater's
# and Sparkle's unified logs for the run window, so a failed install on quit names its cause.
#   cmux-ci run --class exclusive --label measure --script scripts/measure/update-e2e-diag.sh --ref <sha> --artifact .build/update-diag
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
out=.build/update-diag; mkdir -p "$out"
start=$(date '+%Y-%m-%d %H:%M:%S')
python3 scripts/cmux-next/update-e2e.py "$@" 2>&1 | tee "$out/harness.txt"; rc=${PIPESTATUS[0]}
log show --start "$start" --style compact --info \
  --predicate 'subsystem == "com.cmuxterm.app.next" AND category == "updater"' > "$out/updater.log" 2>&1 || true
log show --start "$start" --style compact --info --debug \
  --predicate 'subsystem BEGINSWITH "org.sparkle-project" OR process CONTAINS "Autoupdate" OR process CONTAINS "Installer" OR process == "cmux NIGHTLY"' > "$out/sparkle.log" 2>&1 || true
ls -la ~/Library/Caches/com.cmuxterm.app.nightly/org.sparkle-project.Sparkle 2>&1 | head -40 > "$out/sparkle-cache.txt" || true
echo "=== updater.log (tail 120)"; tail -120 "$out/updater.log"
echo "=== sparkle.log grep"; grep -iE "install|error|fail|cancel|terminat|relaunch|quit" "$out/sparkle.log" | tail -150
exit $rc
