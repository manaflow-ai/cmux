#!/usr/bin/env python3
"""scripts/ci/xcode_build_timeline.py: where a build's time went, from its result bundle's build log.

check-cmux-scheme-compile.sh writes a result bundle when build metrics are on and
prints this timeline after the build: time per task kind (Swift compile split into
cache replays and real compiles) and the 15 slowest tasks. These pin the
classification and ranking on a build log shaped like `xcresulttool get log --type build`,
and that the timeline never fails a build.
"""
from __future__ import annotations

import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import xcode_build_timeline as timeline  # noqa: E402

START = 1_793_000_000.0


def task(title: str, seconds: float, start: float = 0.0, *, command: str = "", messages=()) -> dict:
    section = {"domainType": "com.apple.dt.IDE.BuildLogSection", "title": title, "duration": seconds,
               "startTime": START + start, "subsections": [], "attachments": [],
               "messages": [{"type": "notice", "title": text, "annotations": []} for text in messages]}
    if command:
        section["commandInvocationDetails"] = {"commandDetails": command, "emittedOutput": ""}
    return section


def target(name: str, *children: dict) -> dict:
    return {"domainType": "com.apple.dt.IDE.BuildLogTargetSection", "title": f"Build target {name}",
            "duration": sum(child["duration"] for child in children), "subsections": list(children),
            "messages": [], "attachments": [], "productType": "com.apple.product-type.application"}


LOG = {
    "domainType": "com.apple.dt.IDE.BuildLogSection", "title": "Build cmux", "duration": 400.0,
    "startTime": START, "messages": [], "attachments": [],
    "subsections": [
        task("Create build description", 6.0, 0.0),
        target("CmuxNextCore",
               task("Compiling Workspace.swift, Pane.swift", 196.0, 10.0, command="SwiftCompile normal arm64 Compiling Workspace.swift",
                    messages=["Cache miss"]),
               task("Compiling Tab.swift", 2.0, 10.0, command="SwiftCompile normal arm64 Compiling Tab.swift",
                    messages=["Cache hit"]),
               task("Emitting module for CmuxNextCore", 30.0, 10.0)),
        target("cmux",
               task("Compiling AppDelegate.swift", 104.0, 210.0, messages=["cache key query hit"]),
               task("Run custom shell script 'Bundle cmux-tui'", 25.0, 330.0, command="PhaseScriptExecution Bundle\\ cmux-tui"),
               task("Run custom shell script 'Embed CEF'", 12.0, 355.0),
               task("Link cmux (arm64)", 20.0, 314.0, command="Ld /x/cmux normal"),
               task("Copy Swift standard libraries into cmux.app", 3.0, 367.0, command="CopySwiftLibs /x/cmux.app"),
               task("Process Info.plist", 0.5, 370.0, command="ProcessInfoPlistFile /x/Info.plist"),
               task("Compile asset catalog", 4.0, 371.0, command="CompileAssetCatalog /x/Assets.xcassets"),
               task("Sign cmux.app", 5.0, 375.0, command="CodeSign /x/cmux.app"),
               task("Compiling glue.m", 1.0, 380.0, command="CompileC /x/glue.o glue.m normal arm64"),
               task("Write auxiliary files", 0.2, 5.0)),
    ],
}


class TimelineTests(unittest.TestCase):
    def test_tasks_are_sorted_into_the_kinds_a_warm_build_is_read_by(self):
        summary = timeline.summarize(LOG)
        kinds = summary["kinds"]
        self.assertEqual(kinds["swift-compile (real)"], {"tasks": 1, "seconds": 196.0, "longest": 196.0})
        self.assertEqual(kinds["swift-compile (cache replay)"]["tasks"], 2)
        self.assertEqual(kinds["swift-emit-module"]["seconds"], 30.0)
        self.assertEqual(kinds["script-phase"], {"tasks": 2, "seconds": 37.0, "longest": 25.0})
        for kind in ("link", "copy-swift-libs", "codesign", "assets-plists", "package-planning", "c-compile"):
            self.assertIn(kind, kinds)
        self.assertEqual(kinds["assets-plists"]["tasks"], 2)
        self.assertEqual(summary["tasks"], 14)
        self.assertEqual(summary["task_wall_seconds"], 381.0)

    def test_every_cache_remark_xcode_writes_is_read(self):
        for remark, outcome in (("Cache hit", "hit"), ("cache key query hit", "hit"),
                                ("local cache found for key: 0~abc", "hit"), ("Cache miss", "miss"),
                                ("cache key query miss", "miss"), ("compile job missed the cache", "miss"),
                                ("Compiling", "unknown")):
            with self.subTest(remark=remark):
                self.assertEqual(timeline.cache_outcome(task("Compiling a.swift", 1.0, messages=[remark])), outcome)

    def test_the_slowest_tasks_lead_with_their_target(self):
        slowest = timeline.summarize(LOG, top=3)["slowest"]
        self.assertEqual([(task["seconds"], task["target"]) for task in slowest],
                         [(196.0, "CmuxNextCore"), (104.0, "cmux"), (30.0, "CmuxNextCore")])
        self.assertEqual(slowest[0]["cache"], "miss")
        out = io.StringIO()
        timeline.report(timeline.summarize(LOG), out)
        self.assertIn("Slowest 14 tasks:", out.getvalue())
        self.assertIn("196.0s  swift-compile [miss]  CmuxNextCore: Compiling Workspace.swift", out.getvalue())

    def test_a_missing_or_broken_log_never_fails_the_build(self):
        with tempfile.TemporaryDirectory() as temp:
            broken = Path(temp) / "log.json"
            broken.write_text("{not json")
            for args in (["--log-json", str(broken)], ["--xcresult", str(Path(temp) / "none.xcresult")]):
                result = subprocess.run([sys.executable, "-I", str(ROOT / "scripts/ci/xcode_build_timeline.py"), *args],
                                        capture_output=True, text=True, env={"PATH": "/usr/bin:/bin"})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("no timeline", result.stderr)
            good = Path(temp) / "good.json"
            good.write_text(json.dumps(LOG))
            out = Path(temp) / "metrics/build-timeline.json"
            subprocess.run([sys.executable, "-I", str(ROOT / "scripts/ci/xcode_build_timeline.py"),
                            "--log-json", str(good), "--json", str(out)], check=True, capture_output=True)
            self.assertEqual(json.loads(out.read_text())["kinds"]["swift-compile (real)"]["tasks"], 1)

    def test_the_scheme_compile_writes_a_result_bundle_and_prints_the_timeline(self):
        script = (ROOT / "scripts/cmux-next/check-cmux-scheme-compile.sh").read_text()
        self.assertIn('xcode_args+=(-resultBundlePath "$result_bundle")', script)
        self.assertIn("-showBuildTimingSummary", script)
        self.assertIn('scripts/ci/xcode_build_timeline.py" --xcresult "$result_bundle"', script)
        self.assertIn('--json "$metrics_dir/build-timeline.json" || true', script)
        # After the metrics: the timeline never counts in the recorded compile seconds.
        self.assertLess(script.index('--compile-seconds "$SECONDS"'), script.index("xcode_build_timeline.py"))


if __name__ == "__main__":
    unittest.main()
