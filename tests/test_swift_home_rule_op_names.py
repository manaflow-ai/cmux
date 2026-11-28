#!/usr/bin/env python3
"""Every home-rules op name the Mac app's Swift passes as a literal is one the Rust side answers.

cmux_home_call (cmux-tui/crates/cmux-home-rules/src/ops.rs) takes `AREA.NAME`; a bare name or one
the area's `OPS` list lacks answers `unknownOp`. The Swift wrappers that assert on a failed call
(ChiefRules.rule, welcomeRule) then trap a DEBUG build at launch: pair-e2e run 46134149895, the
tagged app ended with SIGTRAP at "HostedChiefRules.swift:15: Fatal error: home rules op chiefs_tab:
unknownOp" because ChiefRules sent "chiefs_tab", not "cloud.chiefs_tab".

This reads the Swift sources and the Rust OPS lists only, so it runs on Linux.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SWIFT = ROOT / "Packages/macOS/CmuxNext/Sources"
RULES = ROOT / "cmux-tui/crates/cmux-home-rules/src"

# A Swift call whose first argument is an op-name literal, and the area its wrapper puts in front
# (None: the literal goes through as is, so it must be AREA.NAME). Read from the wrappers, not assumed.
def callers() -> list[tuple[re.Pattern[str], str | None]]:
    chief = (SWIFT / "CmuxNextHostedChief/HostedChiefRules.swift").read_text()
    area = re.search(r'static let area = "(\w+)"', chief)
    # Both ChiefRules entry points must qualify; one that sends `op` bare gets no area.
    qualifies = chief.count("HomeEngineRules.call(qualified(op), input)") == 2 and 'qualified(_ op: String)' in chief
    chief_area = area.group(1) if area and qualifies else None
    home = (SWIFT / "CmuxNextHomeEngine/ChiefHome.swift").read_text()
    home_area = re.search(r'HomeRules\.call\("(\w+)\." \+ name', home)
    return [
        (re.compile(r'\bHomeRules\.call\(\s*"([^"\\]+)"(?!\s*\+)'), None),
        (re.compile(r'\bHomeEngineRules\.call\(\s*"([^"\\]+)"(?!\s*\+)'), None),
        (re.compile(r'\bwelcomeRule\(\s*"([^"\\]+)"'), None),
        (re.compile(r'\bChiefRules\.(?:rule|call)\(\s*"([^"\\]+)"'), chief_area),
        (re.compile(r'\bChiefHomeRules\(\)\.call\(\s*"([^"\\]+)"'), home_area.group(1) if home_area else None),
    ]


def rust_ops() -> dict[str, set[str]]:
    """{area: op names}, from each area's `pub const OPS` and ops.rs's area match."""
    dispatch = (RULES / "ops.rs").read_text()
    areas = dict(re.findall(r'"(\w+)" => crate::(\w+)::call\(name, request\)', dispatch))
    ops: dict[str, set[str]] = {"ops": set()}
    for area, module in areas.items():
        path = RULES / module / "mod.rs"
        if not path.exists():
            path = RULES / f"{module}.rs"
        text = path.read_text()
        block = re.search(r"pub const OPS: &\[&str\] = &\[(.*?)\];", text, re.S)
        assert block, f"{path}: no `pub const OPS`"
        ops[area] = set(re.findall(r'"([^"]+)"', block.group(1)))
    return ops


def swift_calls() -> list[tuple[Path, int, str]]:
    """(file, line, AREA.NAME) for every literal op name a wrapper sends."""
    found = []
    patterns = callers()
    for path in sorted(SWIFT.rglob("*.swift")):
        text = path.read_text()
        for pattern, area in patterns:
            for match in pattern.finditer(text):
                name = match.group(1)
                op = f"{area}.{name}" if area else name
                found.append((path, text.count("\n", 0, match.start()) + 1, op))
    return found


def unanswered(ops: dict[str, set[str]], calls: list[tuple[Path, int, str]]) -> list[str]:
    bad = []
    for path, line, op in calls:
        area, dot, name = op.partition(".")
        if not dot or area not in ops or (area != "ops" and name not in ops[area]):
            bad.append(f"{path.relative_to(ROOT)}:{line}: {op!r} is not an op cmux_home_call answers")
    return bad


def main() -> int:
    ops = rust_ops()
    calls = swift_calls()
    assert len(ops) >= 9, f"read only {sorted(ops)} from ops.rs"
    assert sum(1 for _, _, op in calls if "chiefs_" in op) >= 8, "the ChiefRules calls were not found"

    # The detector catches the shape that broke: a bare name, and a name the area lacks.
    probe = [(SWIFT / "x.swift", 1, "chiefs_tab"), (SWIFT / "x.swift", 2, "cloud.chiefs_nope")]
    assert len(unanswered(ops, probe)) == 2

    bad = unanswered(ops, calls)
    if bad:
        print("\n".join(bad))
        return 1
    print(f"ok: {len(calls)} literal op names, all answered")
    return 0


if __name__ == "__main__":
    sys.exit(main())
