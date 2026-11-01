#!/usr/bin/env bash
# Fails when CmuxNext code animates without the Motion tokens
# (plans/cmux-next/motion.md). Every duration, curve and spring constant
# lives in Sources/CmuxNextDesign/Motion and Sources/CmuxNextDesignTokens/Motion; everything else asks `Motion` for a
# token, so `ui.animationSpeed`, Reduce Motion and retuning apply everywhere.
#
# Flags, outside those two Motion folders (tests are exempt):
#   - numeric durations: `duration = 0.2`, `duration: 0.14`, `setAnimationDuration(`
#   - spring constants: `response: 0.3`, `dampingFraction:`, `dampingRatio:`,
#     `stiffness =`, `damping =`, `perceptualDuration:`, `bounce:`
#   - SwiftUI curves with literal times: `.spring(duration:`, `.easeOut(duration:` ...
#   - raw animation construction: CABasicAnimation, CASpringAnimation,
#     CAKeyframeAnimation, CATransition, CAAnimationGroup, CAMediaTimingFunction,
#     NSAnimationContext.runAnimationGroup / .animate, withAnimation
#   - a constraint animator outside `Motion.animator(_:in:)`: `.animator().constant`
#     (it never applies in a window with no screen, even in a zero-length group)
#   - `Motion.animate(`, `Motion.animateTimed(` or `Motion.animateExit(` without
#     `in:` on the call's line: Motion snaps when the animated view's window has
#     no screen, so it must know that view
#   - an animation that names no motion category: `Motion.animate(`,
#     `Motion.set(`, `Motion.duration(` ... must be `Motion.<category>.animate(`
#     (`Motion.sidebar`, `Motion.tabs`, ...; MotionGate), so the master switch
#     `ui.animations.enabled`, the category switch `ui.animations.<category>`,
#     `ui.animationSpeed` and Reduce Motion all apply (motion-DESIGN.md)
#   - SwiftUI animation outside a gate: `.animation(` whose value is not a
#     `Motion.<category>.animation(...)`, `.transition(`, `.contentTransition(`,
#     `.symbolEffect(`, `.matchedGeometryEffect(`, `phaseAnimator`,
#     `keyframeAnimator`, `TimelineView(.animation`
#   - AppKit animation outside a gate: a window `animationBehavior` other than
#     `.none` and a popover `animates` that no gate decides, an `.animator()`
#     change with no Motion call on its line or the 3 lines above
# A reviewed exception carries `// motion: allow <reason>` (or the older
# `// motion-allow: <reason>`) on the line or the line above. The reason is
# required, and it must say how the animation still obeys the switches.
#
# Usage: scripts/cmux-next/check-motion.sh [package-root]
set -euo pipefail
root="${1:-$(git rev-parse --show-toplevel)/Packages/macOS/CmuxNext}"
exec python3 - "$root" <<'PY'
import os
import re
import sys

root = sys.argv[1]
sources = os.path.join(root, "Sources")
# The motion tokens and the gate: Design's Motion folder and its view-free half in DesignTokens.
exempt = (os.path.join(sources, "CmuxNextDesign", "Motion") + os.sep,
          os.path.join(sources, "CmuxNextDesignTokens", "Motion") + os.sep)

# The MotionGate members (Sources/CmuxNextDesign/Motion): every one decides with a category.
GATE_MEMBERS = "|".join([
    "animates", "animatesMovement", "animatesPaneLayout", "animatesFades", "animatesLoops", "spring", "duration",
    "period", "dividerReleaseProjection", "animate", "animateTimed", "animateExit", "transaction", "set",
    "springAnimation", "scheduledFade", "spinAnimation", "stepAnimation", "framesAnimation", "pulseAnimation",
    "flashAnimation", "passOverAnimation", "crossfadeInPlace", "animation", "attentionAnimation",
    "revealLaunchMark", "concealLaunchMark", "marqueeAnimation", "policy", "sweepAnimation", "agentCursorGlideDuration",
])

RULES = [
    ("literal animation duration", r"(\bduration|\.duration)\s*[:=]\s*[^,)\n]*\b\d*\.\d+"),
    ("setAnimationDuration (use Motion.transaction)", r"\bsetAnimationDuration\("),
    ("literal spring constant", r"\bresponse:\s*\d|\bdamping(Fraction|Ratio)?\s*[:=]\s*\d|\bstiffness\s*[:=]\s*\d|\bperceptualDuration:|\bbounce:\s*\d"),
    ("SwiftUI curve with literal time", r"\.(spring|easeIn|easeOut|easeInOut|linear|smooth|snappy|bouncy)\((duration|response):"),
    ("raw Core Animation object (use Motion.set / Motion.transaction)", r"\b(CABasicAnimation|CASpringAnimation|CAKeyframeAnimation|CATransition|CAAnimationGroup|CAMediaTimingFunction)\("),
    ("raw NSAnimationContext (use Motion.animate)", r"\bNSAnimationContext\.(runAnimationGroup|animate)\b"),
    ("SwiftUI withAnimation (use a Motion token)", r"\bwithAnimation\s*[({]"),
    ("constraint animator (use Motion.animator(_:in:))", r"\.animator\(\)\.constant\b"),
    ("animation without a motion category (use Motion.<category>.<call>, e.g. Motion.sidebar.animate)",
     r"\bMotion\.(" + GATE_MEMBERS + r")\b"),
    ("SwiftUI .animation( outside a motion gate (use .animation(Motion.<category>.animation(token), value:))",
     r"(?<![A-Za-z0-9_\)])\.animation\((?!forKey:)(?![^\n]*\bMotion\.[a-z][A-Za-z]*\.animation\()"),
    ("SwiftUI transition or effect outside a motion gate",
     r"\.(transition|contentTransition|symbolEffect|matchedGeometryEffect)\(|\b(phaseAnimator|keyframeAnimator)\b|TimelineView\(\.animation"),
    ("window animationBehavior outside a motion gate (use gate.animatesMovement ? .x : .none)",
     r"\banimationBehavior\s*=\s*\.(?!none\b)(?![^\n]*\bMotion\.)"),
    ("popover animates outside a motion gate", r"\.animates\s*=(?!\s*false\s*(?:;|}))(?![^\n]*\bMotion\.)"),
    ("popup entrance animation (open popups in one frame)", r"\bentrance\s*:\s*true\b"),
]
# An .animator() change must run inside a Motion gate's animation group: outside one, AppKit
# animates it on its own 0.25 s default, which no switch reaches. Heuristic: a gate call that
# opens a group (`Motion.<category>.animate...`, `Motion.withoutAnimation`, `gate.animate...`)
# within 40 lines of it, in the same file; a block that a caller elsewhere runs inside its group
# says so with `// motion: allow <reason>`.
animator_use = re.compile(r"\.animator\(\)")
in_gate = re.compile(r"\bMotion\.(?:[a-z][A-Za-z]*\.)?(animate|animateTimed|animateExit|withoutAnimation)\b|\bgate\.(animate|animateTimed|animateExit|withoutAnimation)\b|\bMotion\.animator\(")
# A Motion AppKit call whose arguments before its first closure name no view.
motion_call = re.compile(r"\bMotion\.(?:[a-z][A-Za-z]*\.)?(animate|animateTimed|animateExit)\(")
compiled = [(name, re.compile(pattern)) for name, pattern in RULES]
# `// motion: allow <reason>` or `// motion-allow: <reason>`, with a reason.
ALLOW = re.compile(r"//\s*motion(:\s*allow|-allow:)\s*\S")

def code_part(line):
    # Drop trailing // comments (not inside strings; good enough for Swift sources here).
    in_string = False
    for i, ch in enumerate(line):
        if ch == '"':
            in_string = not in_string
        elif not in_string and line.startswith("//", i):
            return line[:i]
    return line

def popover_assignment_code(index, code, lines):
    # A newline after `false` need not end a Swift expression. Only treat it as a
    # literal assignment when the next significant line starts a new statement or
    # closes the scope. Operators, member access, casts and type checks continue it.
    if not re.search(r"\.animates\s*=\s*false\s*$", code):
        return code
    for following in lines[index + 1:]:
        following = code_part(following).strip()
        if not following:
            continue
        if re.match(r"(?:as|is)\b", following) or not re.match(r"[A-Za-z_@};]", following):
            return code
        break
    return code + ";"

failures = []
for directory, _, files in os.walk(sources):
    for name in files:
        if not name.endswith(".swift"):
            continue
        path = os.path.join(directory, name)
        if path.startswith(exempt):
            continue
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
        for index, line in enumerate(lines):
            stripped = line.strip()
            if stripped.startswith("//") or stripped.startswith("///") or stripped.startswith("*"):
                continue
            allowed = bool(ALLOW.search(line) or (index > 0 and ALLOW.search(lines[index - 1])))
            code = code_part(line)
            for rule, pattern in compiled:
                rule_code = popover_assignment_code(index, code, lines) if rule == "popover animates outside a motion gate" else code
                if pattern.search(rule_code) and not allowed:
                    failures.append(f"{os.path.relpath(path, root)}:{index + 1}: {rule}: {stripped}")
            if animator_use.search(code) and not allowed:
                window = [code_part(l) for l in lines[max(0, index - 40):index + 41]]
                if not any(in_gate.search(l) for l in window):
                    failures.append(f"{os.path.relpath(path, root)}:{index + 1}: .animator() outside a Motion gate call: {stripped}")
            for match in motion_call.finditer(code):
                head = code[match.end():].split("{", 1)[0]
                if "in:" not in head and not allowed:
                    failures.append(f"{os.path.relpath(path, root)}:{index + 1}: Motion call without the animated view (pass in:): {stripped}")

if failures:
    print("check-motion: every animation goes through a Motion gate with a category (plans/cmux-next/motion-DESIGN.md):")
    for failure in failures:
        print("  " + failure)
    sys.exit(1)
print("check-motion: ok")
PY
