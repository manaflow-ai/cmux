#!/usr/bin/env bash
# check-motion.sh: a constraint animator outside Motion.animator(_:in:) and a
# Motion.animate / animateTimed / animateExit call without `in:` fail the
# gate (an animation in a window with no screen never advances, so Motion
# must know the animated view; 2026-10-05). A reviewed `// motion-allow:`
# exception passes, and so do the compliant forms.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
CHECK="$ROOT_DIR/scripts/cmux-next/check-motion.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cmux-check-motion.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Runs the gate on a package root whose only source is $1.
check() {
  rm -rf "$tmp/pkg"
  mkdir -p "$tmp/pkg/Sources/Fixture"
  printf '%s\n' "$1" > "$tmp/pkg/Sources/Fixture/Fixture.swift"
  bash "$CHECK" "$tmp/pkg" >/dev/null 2>&1
}
pass() { check "$2" || { echo "FAIL: must pass: $1" >&2; exit 1; }; }
fail() { if check "$2"; then echo "FAIL: must fail: $1" >&2; exit 1; fi; }

fail "a raw constraint animator" '        Motion.animateTimed(.appear, in: self, { width.animator().constant = 0 })'
fail "a Motion.animate call without in:" '        Motion.animate(.fadeIn) { view.animator().alphaValue = 1 }'
fail "a Motion.animateTimed call without in:" '        Motion.animateTimed(hidden ? .disappear : .appear, { apply() })'
fail "a Motion.animateExit call without in:" '        Motion.animateExit(.disappear, apply)'
pass "a call with in: and the constraint helper" '        Motion.animateTimed(.appear, in: self, { Motion.animator(width, in: self).constant = 0 })'
pass "a call with in: for a view" '        Motion.animate(appearing ? .fadeIn : .fadeOut, in: view, { view.animator().alphaValue = 1 }, completion: nil)'
pass "a reviewed exception on the line above" '        // motion-allow: the overlay has no view to ask
        Motion.animate(.fadeIn) { overlay.animator().alphaValue = 1 }'
pass "a comment that mentions the call" '        // Motion.animate(.fadeIn) { x.animator().constant = 1 }'
echo "check-motion.test: ok"
