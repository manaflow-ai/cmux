#!/usr/bin/env python3
"""Counts the animations in cmux NEXT that may still move with Reduce Motion on, one number per platform.

    scripts/cmux-next/reduce-motion-audit.py [--root DIR] [--json]

The count behind goal a11y-baseline's motion leg (cmuxterm-hq goals/a11y-baseline.md: "every animation honors Reduce
Motion"). It reports and never fails; a gate can be added once the count is 0.

- macOS: check-motion.sh's findings. Every NEXT animation there goes through a `Motion.<category>` gate, which
  follows Reduce Motion, so a finding is an animation no gate decides.
- webviews: CSS durations already follow Reduce Motion everywhere desktop.css reaches (its
  `prefers-reduced-motion: reduce` rule), so only script-driven motion is counted: a Web Animations call
  (`.animate([...]` or `.animate({...}`) and a smooth scroll (`behavior: "smooth"`), in a file that never reads the
  reduce or motion-off state (WEB_GATE).
- iOS: a UIKit or SwiftUI animation call (IOS_SITE) in a file that never reads Reduce Motion (IOS_GATE), in the
  NEXT iPhone app, the shared iOS packages and the classic iOS app (IOS_DIRS), each reported by its own path.

A file counts as gated as soon as it reads the state anywhere. That is coarse: a file with one gated animation and
one that is not reads as gated. A reviewed exception carries `motion: allow <reason>` on the line or the line above,
as check-motion.sh's do. Tests, galleries and fixtures are not counted.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

WEB_DIRS = ("webviews/src",)
WEB_SUFFIXES = (".ts", ".tsx", ".js", ".jsx", ".mjs")
WEB_SITE = re.compile(r"""\.animate\(\s*[\[{]|behavior:\s*["']smooth["']""")
WEB_GATE = re.compile(r"prefers-reduced-motion|isAgentMotionOff|cmuxMotion|agentMotion|data-cmux-motion|"
                      r"data-agent-motion|reducedMotion|motionOff|"
                      # The shared helpers that read it: ui/motion/motionMode.ts, conversation/fold.ts,
                      # session-info/foldMotion.ts, composer/SendSlotGlyph.tsx.
                      r"\bmotionMode\(|\bfoldMs\(|\bfoldMoves\(|\bmotionAllowed\(", re.I)
# The NEXT iPhone app (cmux-next-ios, its home is CmuxMobileHome) and the shared packages it builds on; ios/ is the
# classic iOS app, counted beside them while its home shares those packages.
IOS_DIRS = ("cmux-next-ios", "Packages/iOS", "ios")
IOS_SITE = re.compile(r"UIView\.animate|UIView\.transition|UIViewPropertyAnimator|withAnimation|CABasicAnimation|"
                      r"CASpringAnimation|CAKeyframeAnimation|\.animation\((?!forKey)")
# HomeMotion (ios CmuxiOSDesign) is the iOS home's gate.
IOS_GATE = re.compile(r"isReduceMotionEnabled|accessibilityReduceMotion|reduceMotion|reducesMotion|MotionPolicy|"
                      r"HomeMotion\.", re.I)
SKIP = re.compile(r"(^|/)(tests?|Tests|UITests|__tests__|fixtures?)(/|$)|\.test\.|\.gallery\.|\.spec\.|Tests?\.swift$")
ALLOW = re.compile(r"motion:? ?-?allow\b")
FINDING = re.compile(r"^\s+(\S+?):(\d+): (.+)$")


def ungated(root: Path, dirs: tuple[str, ...], suffixes: tuple[str, ...], site: re.Pattern, gate: re.Pattern) -> dict:
    """{"sites": N, "files": N, "where": [{"file", "line", "text"}]}: the animation calls in files that never read
    the reduce state, a reviewed `motion: allow` excepted."""
    where = []
    for top in dirs:
        base = root / top
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*")):
            rel = path.relative_to(root).as_posix()
            if path.suffix not in suffixes or not path.is_file() or SKIP.search(rel) or "node_modules" in rel:
                continue
            text = path.read_text(errors="replace")
            if not site.search(text) or gate.search(text):
                continue
            lines = text.splitlines()
            for i, line in enumerate(lines):
                if site.search(line) and not ALLOW.search(line) and not (i and ALLOW.search(lines[i - 1])):
                    where.append({"file": rel, "line": i + 1, "text": line.strip()[:160]})
    return {"sites": len(where), "files": len({w["file"] for w in where}), "where": where}


def macos(root: Path) -> dict:
    """check-motion.sh's findings as {"sites", "files", "where"}, or {"error"} when it did not run."""
    script = root / "scripts" / "cmux-next" / "check-motion.sh"
    package = root / "Packages" / "macOS" / "CmuxNext"
    if not script.is_file() or not package.is_dir():
        return {"error": "check-motion.sh or Packages/macOS/CmuxNext is not in this tree"}
    done = subprocess.run(["bash", str(script), str(package)], capture_output=True, text=True, timeout=600)
    where = [{"file": f"Packages/macOS/CmuxNext/{m[1]}", "line": int(m[2]), "text": m[3][:160]}
             for m in map(FINDING.match, (done.stdout + done.stderr).splitlines()) if m]
    if done.returncode != 0 and not where:
        return {"error": f"check-motion.sh exited {done.returncode} with no finding it could read"}
    return {"sites": len(where), "files": len({w["file"] for w in where}), "where": where}


def audit(root: Path) -> dict:
    out = {
        "macos": macos(root),
        "webviews": ungated(root, WEB_DIRS, WEB_SUFFIXES, WEB_SITE, WEB_GATE),
        "ios": ungated(root, IOS_DIRS, (".swift",), IOS_SITE, IOS_GATE),
    }
    out["total"] = None if any("error" in v for v in out.values()) else sum(v["sites"] for v in out.values())
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    ap.add_argument("--json", action="store_true", help="the whole report as JSON on stdout")
    a = ap.parse_args(argv)
    report = audit(a.root)
    if a.json:
        print(json.dumps(report, indent=1))
        return 0
    for name in ("macos", "webviews", "ios"):
        part = report[name]
        if "error" in part:
            print(f"{name}: {part['error']}")
            continue
        print(f"{name}: {part['sites']} animation(s) in {part['files']} file(s) may move with Reduce Motion on")
        for w in part["where"]:
            print(f"  {w['file']}:{w['line']}: {w['text']}")
    print(f"total: {report['total']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
