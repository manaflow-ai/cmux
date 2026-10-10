#!/usr/bin/env bash
# check-test-notification-centers.sh: a cmux-next test that posts to a
# process-global notification center fails the gate. Every observer in the test
# process receives that post on the posting thread, so a test that posted
# NSWindow.willCloseNotification off main on NotificationCenter.default trapped
# an unrelated @MainActor observer and killed the whole swift test run with
# signal 5 (#18771). Tests inject their own NotificationCenter instead.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-test-notification-centers.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-check-notices.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Runs the gate on a package root whose only test source is $1 (at $2, default a test file).
check() {
  rm -rf "$tmp/pkg"
  local path="${2:-Tests/FixtureTests/FixtureTests.swift}"
  mkdir -p "$tmp/pkg/$(dirname "$path")"
  printf '%s\n' "$1" > "$tmp/pkg/$path"
  bash "$CHECK" "$tmp/pkg" >"$tmp/out" 2>&1
}
pass() { check "$2" "${3:-}" || { echo "FAIL: must pass: $1" >&2; cat "$tmp/out" >&2; exit 1; }; }
fail() { if check "$2" "${3:-}"; then echo "FAIL: must fail: $1" >&2; cat "$tmp/out" >&2; exit 1; fi; }

fail "a default-center post" '        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)'
fail "a default-center post by name" '        NotificationCenter.default.post(name: .x, object: nil, userInfo: [:])'
fail "a default-center postNotificationName" '        NotificationCenter.default.postNotificationName(.x, object: nil)'
fail "a workspace-center post" '        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)'
fail "a distributed-center post" '        DistributedNotificationCenter.default().post(name: .x, object: nil)'
fail "a distributed-center postNotificationName" '        DistributedNotificationCenter.default().postNotificationName(.x, object: nil, userInfo: nil, deliverImmediately: true)'
pass "an injected center" '        center.post(name: NSWindow.willCloseNotification, object: window)'
pass "a private center" '        NotificationCenter().post(name: .x, object: nil)'
pass "observing the default center" '        let token = NotificationCenter.default.addObserver(forName: .x, object: window, queue: nil) { _ in }'
pass "a comment" '        // never NotificationCenter.default.post(name: .x, object: nil) here'
pass "a reviewed exception" '        NotificationCenter.default.post(name: .x, object: window) // global-notice-allow: AppKit observer takes no center'
pass "a reviewed exception above" '        // global-notice-allow: AppKit observer takes no center
        NotificationCenter.default.post(name: .x, object: window)'
fail "an exception without a reason" '        NotificationCenter.default.post(name: .x, object: window) // global-notice-allow:'
pass "a production source" '        NotificationCenter.default.post(name: .x, object: nil)' Sources/Fixture/Fixture.swift
grep -q 'Tests/FixtureTests/FixtureTests.swift:1' <(check '        NotificationCenter.default.post(name: .x, object: nil)'; cat "$tmp/out") \
  || { echo "FAIL: the hit does not name its file and line" >&2; cat "$tmp/out" >&2; exit 1; }
echo "check-test-notification-centers tests: ok"
