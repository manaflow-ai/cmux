#!/usr/bin/env bash
# Close system dialogs left over the console session before UI tests run.
#
# Owned minis keep one GUI session across jobs and reboots. On cmux13s
# (2026-09-27) two modals sat over every UI test for hours: a crash report
# ("Reopen / Ignore / Report...") from an earlier app crash, and Spotlight
# asking for the cmux-ci test keychain's password, which it read while the
# keychain was still locked after a reboot. With them up, XCUITest could not
# activate the app under test or give its fields keyboard focus. Both run as
# the runner user, so no sudo is needed. Crash reports are still written to
# ~/Library/Logs/DiagnosticReports; only the modal goes away.
set -u

defaults write com.apple.CrashReporter DialogType none 2>/dev/null || true

uid="$(id -u)"
for process in UserNotificationCenter SecurityAgent; do
  if pgrep -x -u "$uid" "$process" >/dev/null 2>&1; then
    if pkill -x -u "$uid" "$process"; then
      echo "Closed $process (its dialogs are cancelled; launchd restarts it on demand)"
    fi
  fi
done
exit 0
