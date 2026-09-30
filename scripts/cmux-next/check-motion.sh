#!/usr/bin/env bash
# Fails when CmuxNext code animates without the Motion tokens
# (plans/cmux-next/motion.md). Every duration, curve and spring constant
# lives in Sources/CmuxNextDesign/Motion; everything else asks `Motion` for a
# token, so `ui.animationSpeed`, Reduce Motion and retuning apply everywhere.
#
# Flags, outside CmuxNextDesign/Motion (tests are exempt):
#   - numeric durations: `duration = 0.2`, `duration: 0.14`, `setAnimationDuration(`
#   - spring constants: `response: 0.3`, `dampingFraction:`, `dampingRatio:`,
#     `stiffness =`, `damping =`, `perceptualDuration:`, `bounce:`
#   - SwiftUI curves with literal times: `.spring(duration:`, `.easeOut(duration:` ...
#   - raw animation construction: CABasicAnimation, CASpringAnimation,
#     CAKeyframeAnimation, CATransition, CAAnimationGroup, CAMediaTimingFunction,
#     NSAnimationContext.runAnimationGroup / .animate, withAnimation
# A reviewed exception carries `// motion-allow: <reason>` on the line or the
# line above.
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
exempt = os.path.join(sources, "CmuxNextDesign", "Motion") + os.sep

RULES = [
    ("literal animation duration", r"(\bduration|\.duration)\s*[:=]\s*[^,)\n]*\b\d*\.\d+"),
    ("setAnimationDuration (use Motion.transaction)", r"\bsetAnimationDuration\("),
    ("literal spring constant", r"\bresponse:\s*\d|\bdamping(Fraction|Ratio)?\s*[:=]\s*\d|\bstiffness\s*[:=]\s*\d|\bperceptualDuration:|\bbounce:\s*\d"),
    ("SwiftUI curve with literal time", r"\.(spring|easeIn|easeOut|easeInOut|linear|smooth|snappy|bouncy)\((duration|response):"),
    ("raw Core Animation object (use Motion.set / Motion.transaction)", r"\b(CABasicAnimation|CASpringAnimation|CAKeyframeAnimation|CATransition|CAAnimationGroup|CAMediaTimingFunction)\("),
    ("raw NSAnimationContext (use Motion.animate)", r"\bNSAnimationContext\.(runAnimationGroup|animate)\b"),
    ("SwiftUI withAnimation (use a Motion token)", r"\bwithAnimation\s*[({]"),
]
compiled = [(name, re.compile(pattern)) for name, pattern in RULES]

def code_part(line):
    # Drop trailing // comments (not inside strings; good enough for Swift sources here).
    in_string = False
    for i, ch in enumerate(line):
        if ch == '"':
            in_string = not in_string
        elif not in_string and line.startswith("//", i):
            return line[:i]
    return line

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
            allowed = "motion-allow:" in line or (index > 0 and "motion-allow:" in lines[index - 1])
            code = code_part(line)
            for rule, pattern in compiled:
                if pattern.search(code) and not allowed:
                    failures.append(f"{os.path.relpath(path, root)}:{index + 1}: {rule}: {stripped}")

if failures:
    print("check-motion: animation timing must come from CmuxNextDesign Motion tokens:")
    for failure in failures:
        print("  " + failure)
    sys.exit(1)
print("check-motion: ok")
PY
