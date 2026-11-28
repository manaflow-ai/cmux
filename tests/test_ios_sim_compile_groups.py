#!/usr/bin/env python3
"""scripts/ci/cmux-next-ios-sim.sh: every compile runs inside a compile group of the step log.

cmux-ci run leaves the time inside a compile group (`::group::xcodebuild` with a build action, or
`::group::swift build` / `::group::Prebuild `; cmuxterm-hq build-fleet/ci-client.py STEP_COMPILE_GROUP and
CompilePhase) out of --timeout, up to CMUX_CI_STEP_COMPILE_BUDGET (5400 s). The simulator script printed no
group, so its whole compile counted: the nightly iPhone What's New clips (run 46060009038, attempt 2) were all
cancelled at --timeout 3600 s after an FFI cache miss (740 s), the Demo app and a before app, before one clip
was recorded, and ios-new-task-cloud-machine shipped with no media.
"""
from __future__ import annotations

import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/cmux-next-ios-sim.sh"

# As cmuxterm-hq build-fleet/ci-client.py STEP_COMPILE_GROUP and XCODEBUILD_TEST_ACTIONS.
STEP_COMPILE_GROUP = re.compile(r"^::group::(swift build|Prebuild |xcodebuild)")
TEST_ACTIONS = {"test", "test-without-building"}

# A compile: an xcodebuild with a build action, the FFI xcframework build, or the script's build arrays.
COMPILE = re.compile(
    r'(^|[\s;&(])(xcodebuild\s+(?!-version\b|-resolvePackageDependencies\b|-showsdks\b)'
    r'|bash cmux-next-ios/rust/scripts/build-xcframework\.sh'
    r'|"\$\{build_command\[@\]\}"'
    r'|"\$\{ffi_cache\[@\]\}" build\b)'
)


def logical_lines(text: str):
    """(first line number, joined command) with backslash continuations joined and comments dropped."""
    out, buf, start = [], "", 0
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.rstrip()
        if not buf:
            start = n
            if line.lstrip().startswith("#"):
                continue
        if line.endswith("\\"):
            buf += line[:-1] + " "
            continue
        out.append((start, buf + line))
        buf = ""
    return out


def ungrouped_compiles(text: str):
    """Compile commands that run outside a compile_open ... compile_close span (in file order)."""
    open_, misses = False, []
    for n, line in logical_lines(text):
        stripped = line.strip()
        if re.match(r"compile_open\b", stripped):
            open_ = True
            continue
        if re.match(r"compile_close\b", stripped):
            open_ = False
            continue
        if stripped.startswith(("compile_open()", "compile_close()")):
            continue
        if not COMPILE.search(line) or re.match(r"(note|echo|printf)\b", stripped):
            continue
        words = set(line.split())
        if "xcodebuild" in line and (words & TEST_ACTIONS or '"$ui_action"' in words) \
                and not words & {"build", "build-for-testing"}:
            continue  # a test run (ui_action is test or test-without-building) is not a compile
        if not open_:
            misses.append((n, stripped[:120]))
    return misses


def credited(log: str, timeline: list[float]) -> float:
    """CompilePhase's credit for LOG, line i read at timeline[i] (the client's own rule, simplified)."""
    started, spent = None, 0.0
    for line, now in zip(log.splitlines(), timeline):
        match = STEP_COMPILE_GROUP.match(line)
        opens = bool(match) and not (match.group(1) == "xcodebuild" and set(line.split()[1:]) & TEST_ACTIONS)
        if started is None and opens:
            started = now
        elif started is not None and line.startswith("::endgroup::"):
            spent, started = spent + (now - started), None
    return spent


class CompileGroupsTest(unittest.TestCase):
    def test_every_compile_is_grouped(self):
        misses = ungrouped_compiles(SCRIPT.read_text())
        self.assertEqual(misses, [], "compiles outside compile_open/compile_close (no --timeout credit)")

    def test_detector_finds_an_ungrouped_compile(self):
        text = 'note x\nxcodebuild -project a -scheme b \\\n  build >log\nxcodebuild test -scheme k\n'
        self.assertEqual([n for n, _ in ungrouped_compiles(text)], [2])
        grouped = 'compile_open "a"\n' + text + "compile_close\n"
        self.assertEqual(ungrouped_compiles(grouped), [])

    def test_helpers_print_a_group_the_client_credits(self):
        defs = re.search(r"^compile_group=\"\"\n(compile_open\(\).*\n)(compile_close\(\).*\n)", SCRIPT.read_text(), re.M)
        self.assertIsNotNone(defs, "compile_open/compile_close definitions")
        shell = 'set -euo pipefail\ncompile_group=""\n' + defs.group(1) + defs.group(2) + (
            'echo before\ncompile_open "FFI, xcodegen and the apps"\necho building\n'
            'compile_open "UI suites, build-for-testing"\necho ui\ncompile_close\ncompile_close\necho after\n')
        log = subprocess.run(["bash", "-c", shell], check=True, capture_output=True, text=True).stdout
        lines = log.splitlines()
        self.assertEqual(lines.count("::endgroup::"), 2, log)  # a second open closes the first; a spare close is a no-op
        groups = [l for l in lines if l.startswith("::group::")]
        self.assertEqual(len(groups), 2, log)
        for group in groups:  # an xcodebuild group with a word "test" is a test run to the client: no credit
            self.assertTrue(STEP_COMPILE_GROUP.match(group), group)
            self.assertFalse(set(group.split()[1:]) & TEST_ACTIONS, group)
        # 46060009038's phases: 740 s FFI + 378 s app + 1200 s before app inside the group, then the clip.
        times = [0, 0, 1118, 2318, 2318, 2318, 2318, 2400]
        self.assertEqual(credited(log, times), 2318.0)

    def test_every_label_is_a_compile_to_the_client(self):
        for label in re.findall(r'^\s*compile_open "([^"]*)"', SCRIPT.read_text(), re.M):
            self.assertFalse(set(f"build ({label})".split()) & TEST_ACTIONS, label)


if __name__ == "__main__":
    unittest.main()
