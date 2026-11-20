#!/usr/bin/env bash
# check-motion.sh: an animation that names no motion category (Motion.<category>,
# 2026-10-20: ui.animations.enabled and ui.animations.<category>), a SwiftUI or
# AppKit animation outside a gate, a constraint animator outside Motion.animator(_:in:) and a
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

fail "a raw constraint animator" '        Motion.sidebar.animateTimed(.appear, in: self, { width.animator().constant = 0 })'
fail "a Motion.animate call without in:" '        Motion.overlays.animate(.fadeIn) { view.animator().alphaValue = 1 }'
fail "a Motion.animateTimed call without in:" '        Motion.panes.animateTimed(hidden ? .disappear : .appear, { apply() })'
fail "a Motion.animateExit call without in:" '        Motion.sidebar.animateExit(.disappear, apply)'
pass "a call with in: and the constraint helper" '        Motion.sidebar.animateTimed(.appear, in: self, { Motion.animator(width, in: self).constant = 0 })'
pass "a call with in: for a view" '        Motion.overlays.animate(appearing ? .fadeIn : .fadeOut, in: view, { view.animator().alphaValue = 1 }, completion: nil)'
pass "a reviewed exception on the line above" '        // motion-allow: the overlay has no view to ask
        Motion.overlays.animate(.fadeIn) { overlay.animator().alphaValue = 1 }'
pass "a comment that mentions the call" '        // Motion.animate(.fadeIn) { x.animator().constant = 1 }'

# Every animation names its motion category (ui.animations.<category>, motion-DESIGN.md).
fail "an animation with no category" '        Motion.animate(.move, in: self) { view.animator().frame = target }'
fail "a layer animation with no category" '        Motion.set(layer, "opacity", to: 1, fade: .fadeIn)'
fail "a timing read with no category" '        let seconds = Motion.duration(.fadeIn)'
fail "a spinner with no category" '        layer.add(Motion.spinAnimation()!, forKey: "spin")'
pass "a categorized layer animation" '        Motion.tabs.set(layer, "opacity", to: 1, fade: .fadeIn)'
pass "a categorized timing read" '        let seconds = Motion.home.duration(.fadeIn)'
pass "category-free helpers" '        Motion.withoutAnimation { view.frame = target }; _ = Motion.canAnimate(in: view)'
fail "a raw SwiftUI animation" '        .animation(.easeOut, value: isHovered)'
fail "a raw SwiftUI default animation" '        .animation(.default, value: model)'
pass "a SwiftUI animation from a gate" '        .animation(reduceMotion ? nil : Motion.feedback.animation(.hover), value: isHovered)'
pass "reading a layer animation" '        let running = layer.animation(forKey: "opacity") != nil'
fail "a SwiftUI transition" '        .transition(.opacity)'
fail "a symbol effect" '        content.symbolEffect(.pulse, isActive: true)'
fail "a continuous TimelineView" '        TimelineView(.animation) { context in sky(context.date) }'
fail "a window that animates by itself" '        animationBehavior = .utilityWindow'
pass "a window whose animation a gate decides" '        animationBehavior = Motion.overlays.animatesMovement ? .utilityWindow : .none'
pass "a window that never animates" '        animationBehavior = .none'
fail "a popover that animates by itself" '        popover.animates = true'
fail "a popover controlled by an ungated variable" '        popover.animates = flag'
fail "a popover controlled by an ungated expression" '        popover.animates = false || flag'
fail "a popover controlled by a false-prefixed variable" '        popover.animates = falseFlag'
fail "a popover controlled by a comparison" '        popover.animates = false == flag'
fail "a multiline ungated popover expression" '        popover.animates = false
            || flag'
fail "a commented multiline ungated popover expression" '        popover.animates = false // not a complete assignment
            // the expression continues
            || flag'
fail "a multiline popover type check" '        popover.animates = false
            is Bool'
fail "a multiline popover property access" '        popover.animates = false
            .enabled'
fail "a multiline popover custom operator" '        popover.animates = false
            ⋁ flag'
fail "a second ungated assignment after disabling a popover" '        popover.animates = false; another.animates = flag'
pass "a disabled popover followed by another statement" '        popover.animates = false
        configure()'
pass "a popover explicitly disables animation" '        popover.animates = false'
pass "a popover disables animation before another statement" '        popover.animates = false; configure()'
pass "a popover disables animation at the end of a block" '        if enabled { popover.animates = false }'
pass "a popover whose animation a gate decides" '        popover.animates = Motion.overlays.animatesMovement'
pass "a popover explicitly disables AppKit animation" '        popover.animates = false'
fail "a popup entrance animation" '        popup.show(entrance: true)'
fail "an animator change outside any gate group" '        view.animator().alphaValue = 1'
pass "an animator change inside a gate group" '        Motion.home.animate(.fadeIn, in: view) {
            view.animator().alphaValue = 1
        }'
pass "the new escape with a reason" '        // motion: allow runs only inside the caller'"'"'s Motion.sidebar.animate group
        view.animator().alphaValue = 1'
fail "the new escape without a reason" '        view.animator().alphaValue = 1 // motion: allow'
echo "check-motion.test: ok"
