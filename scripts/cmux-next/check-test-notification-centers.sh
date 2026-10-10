#!/usr/bin/env bash
# Fails when a cmux-next test posts to a process-global notification center
# (NotificationCenter.default, NSWorkspace.shared.notificationCenter or
# DistributedNotificationCenter.default()). Every observer in the test process
# gets that post on the posting thread, so one test's notice reaches another
# test's or the app's observers: a willClose posted off main on
# NotificationCenter.default trapped a @MainActor observer and killed the
# whole swift test run with signal 5 (#18771). Inject a NotificationCenter
# into the type under test and post to it instead.
#
# A hit is allowed only with a reviewed `// global-notice-allow: <reason>` on
# the same line or the comment line above. Observing a global center is fine.
#
# Usage: scripts/cmux-next/check-test-notification-centers.sh [package-root]
set -euo pipefail
root="${1:-$(git rev-parse --show-toplevel)/Packages/macOS/CmuxNext}"
exec python3 - "$root" <<'PY'
import os, re, subprocess, sys

tests = os.path.join(sys.argv[1], "Tests")
POST = re.compile(r"(\bNotificationCenter\.default|\bNSWorkspace\.shared\.notificationCenter"
                  r"|\bDistributedNotificationCenter\.default\(\))\s*\.\s*post(NotificationName)?\(")
ALLOW = re.compile(r"//\s*global-notice-allow:\s*\S")

def code_of(line):
    # Strip a trailing comment when no string literal could contain "//".
    return line.split("//", 1)[0] if '"' not in line else line

def swift_tests():
    # Only tracked files count, as in check-crash-safety.sh. Outside git, every file, loudly.
    if not os.path.isdir(tests):
        return []
    try:
        out = subprocess.run(["git", "-C", tests, "ls-files", "-z", "--", "."],
                             check=True, capture_output=True).stdout.decode("utf-8", "replace")
        return sorted(os.path.join(tests, p) for p in out.split("\0") if p.endswith(".swift"))
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"check-test-notification-centers: WARNING: {tests} is not in a git checkout ({error}); scanning every file", file=sys.stderr)
        return sorted(os.path.join(d, n) for d, _, names in os.walk(tests) for n in names if n.endswith(".swift"))

failures = []
for path in swift_tests():
    if not os.path.isfile(path):
        continue
    lines = open(path, encoding="utf-8").read().split("\n")
    for index, line in enumerate(lines):
        if line.lstrip().startswith("//") or not POST.search(code_of(line)):
            continue
        if ALLOW.search(line) or (index > 0 and ALLOW.search(lines[index - 1])):
            continue
        failures.append(f"{os.path.relpath(path, os.path.dirname(tests))}:{index + 1}: posts to a process-global notification center")

for failure in failures:
    print("test-notification-centers: " + failure)
if failures:
    print(f"check-test-notification-centers: {len(failures)} violation(s). Inject a NotificationCenter and post to it, or add a reviewed `// global-notice-allow: <reason>`.")
    sys.exit(1)
print("check-test-notification-centers: ok")
PY
