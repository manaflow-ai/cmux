#!/usr/bin/env python3
"""messageslab_queue.py: concurrency-only counting, folder buckets, the complete-checking build, and the
swift_diagnostics.py (p10-stability-036) hand-off.

ROWS_6_3 are swift_diagnostics.py rows of a real Swift 6.3.3 build (Linux VM) of a `.v5` probe target built with
`-Xswiftc -strict-concurrency=complete -Xswiftc -print-diagnostic-groups`, read in its --no-build mode.
"""

from __future__ import annotations

import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import textwrap
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parent
spec = importlib.util.spec_from_file_location("messageslab_queue", SCRIPTS / "messageslab_queue.py")
mq = importlib.util.module_from_spec(spec)
sys.modules["messageslab_queue"] = mq
spec.loader.exec_module(mq)

SUFFIX = "; this is an error in the Swift 6 language mode"
ROWS_6_3 = [
    ("MutableGlobalVariable", "var 'counter' is not concurrency-safe because it is nonisolated global shared "
                              "mutable state" + SUFFIX),
    ("SendingClosureRisksDataRace", "passing closure as a 'sending' parameter risks causing data races between "
                                    "main actor-isolated code and concurrent execution of the closure" + SUFFIX),
    ("", "stored property 'box' of 'Sendable'-conforming struct 'S' has non-Sendable type 'Box'" + SUFFIX),
    ("ConformanceIsolation", "conformance of 'C' to protocol 'P' crosses into main actor-isolated code and can "
                             "cause data races" + SUFFIX),
    ("DeprecatedDeclaration", "'old()' is deprecated"),
    ("no-usage", "initialization of immutable value 'unused' was never used; consider replacing with assignment "
                 "to '_' or removing it"),
]


def row(file: str, group: str, message: str, severity: str = "warning") -> dict:
    return {"file": file, "line": 1, "column": 1, "severity": severity, "group": group, "message": message,
            "target": "", "mode": "clean", "fixits": [], "notes": []}


class Classification(unittest.TestCase):
    def test_real_rows_count_concurrency_only(self):
        counted = [group for group, message in ROWS_6_3 if mq.is_concurrency(row("A.swift", group, message))]
        self.assertEqual(counted, ["MutableGlobalVariable", "SendingClosureRisksDataRace", "",
                                   "ConformanceIsolation"])

    def test_error_always_counts(self):
        self.assertTrue(mq.is_concurrency(row("A.swift", "", "cannot find 'x' in scope", severity="error")))


class Folders(unittest.TestCase):
    package = Path("/repo") / mq.PACKAGE

    def test_buckets(self):
        cases = {
            "Sources/MessagesLabHome/Vendor/catalyst/Bubble.swift": "Sources/MessagesLabHome/Vendor/catalyst/[A-L]*",
            "Sources/MessagesLabHome/Vendor/catalyst/Transcript.swift":
                "Sources/MessagesLabHome/Vendor/catalyst/[M-Z]*",
            "Sources/MessagesLabHome/Vendor/appkit-port/X.swift": "Sources/MessagesLabHome/Vendor/appkit-port/*",
            "Sources/MessagesLabHome/Cmux/Home.swift": "Sources/MessagesLabHome/Cmux/[A-L]*",
            "Sources/MessagesLabSidebar/CmuxSidebarView.swift": "Sources/MessagesLabSidebar/*",
            "Tests/MessagesLabHomeTests/A.swift": "Tests/MessagesLabHomeTests/*",
            "Harness/HomeCoverageCheck.swift": mq.OTHER,
        }
        for relative, glob in cases.items():
            with self.subTest(relative):
                self.assertEqual(mq.folder_of(str(self.package / relative), self.package), glob)
                self.assertEqual(mq.folder_of(relative, self.package), glob)

    def test_dependency_file_is_outside(self):
        self.assertIsNone(mq.folder_of("/repo/Packages/Shared/CmuxHomeCore/Sources/A.swift", self.package))

    def test_count_and_split(self):
        home = str(self.package / "Sources/MessagesLabHome/Cmux/Home.swift")
        rows = [row(home, "MutableGlobalVariable", "x" + SUFFIX)] * (mq.SPLIT_ABOVE + 1)
        rows += [row(home, "DeprecatedDeclaration", "'old()' is deprecated")]
        rows += [row("/repo/Packages/Shared/CmuxHomeCore/Sources/A.swift", "SendingRisksDataRace", "y")]
        per_folder, outside = mq.count(rows, self.package)
        self.assertEqual(per_folder, {"Sources/MessagesLabHome/Cmux/[A-L]*": mq.SPLIT_ABOVE + 1})
        self.assertEqual(outside, 1)
        lines = mq.table(per_folder)
        self.assertIn(f"| Sources/MessagesLabHome/Cmux/[A-L]* | 043 | {mq.SPLIT_ABOVE + 1:,} (split) |", lines)
        self.assertIn("| Sources/MessagesLabSidebar | 039 | 0 |", lines)
        self.assertEqual(len(lines), 2 + len(mq.FOLDERS))


FAKE_DIAGNOSTICS = textwrap.dedent('''
    import json
    from pathlib import Path
    calls = []
    def main(argv, build, root, **seams):
        calls.append({"argv": argv, "build": build, "root": root, "seams": seams})
        out = Path(argv[argv.index("--out") + 1])
        out.parent.mkdir(parents=True, exist_ok=True)
        package = root / "Packages/Shared/CmuxMessagesLab"
        rows = [{"file": str(package / "Sources/MessagesLabSidebar/A.swift"), "severity": "warning",
                 "group": "SendingRisksDataRace", "message": "m"}]
        out.write_text("".join(json.dumps(r) + "\\n" for r in rows))
        return STATUS
''')


class Main(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.scripts = self.root / "scripts"
        self.scripts.mkdir()

    def tearDown(self):
        self.temp.cleanup()
        sys.modules.pop("swift_diagnostics", None)

    def run_main(self, argv: list[str], **seams) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            status = mq.main(argv, root=self.root, scripts=self.scripts, **seams)
        return status, out.getvalue(), err.getvalue()

    def test_without_swift_diagnostics_is_no_verdict(self):
        status, _, err = self.run_main([])
        self.assertEqual(status, 3)
        self.assertIn("p10-stability-036", err)

    def test_fleet_run_uses_complete_checking_build(self):
        (self.scripts / "swift_diagnostics.py").write_text(FAKE_DIAGNOSTICS.replace("STATUS", "1"))
        status, out, _ = self.run_main(["--ref", "abc1234"], environ={"CMUX_CI_STEP_KEY": "k"})
        self.assertEqual(status, 1)
        call = sys.modules["swift_diagnostics"].calls[0]
        self.assertIs(call["build"], mq.complete_checking_build)
        self.assertEqual(call["argv"][:2], ["--package", mq.PACKAGE])
        self.assertEqual(call["argv"][-2:], ["--ref", "abc1234"])
        self.assertEqual(call["seams"], {"environ": {"CMUX_CI_STEP_KEY": "k"}})
        self.assertIn("| Sources/MessagesLabSidebar | 039 | 1 |", out)
        self.assertIn("DOES NOT COMPILE", out)

    def test_refusal_passes_through(self):
        (self.scripts / "swift_diagnostics.py").write_text(FAKE_DIAGNOSTICS.replace("STATUS", "2"))
        status, out, _ = self.run_main([])
        self.assertEqual(status, 2)
        self.assertEqual(out, "")

    def test_from_jsonl(self):
        package = self.root / mq.PACKAGE
        saved = self.root / "diagnostics.jsonl"
        rows = [row(str(package / "Tests/MessagesLabHomeTests/A.swift"), group, message) for group, message in ROWS_6_3]
        saved.write_text("".join(json.dumps(r) + "\n" for r in rows))
        status, out, _ = self.run_main(["--from-jsonl", str(saved)])
        self.assertEqual(status, 0)
        self.assertIn("| Tests/MessagesLabHomeTests | 045 | 4 |", out)
        self.assertIn("4 concurrency diagnostic(s)", out)

    def test_build_command(self):
        log = self.root / "build.log"
        with mock.patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run, \
                redirect_stdout(io.StringIO()):
            status = mq.complete_checking_build(Path("/p"), Path("/s"), "debug", {"A": "1"}, log)
        self.assertEqual(status, 0)
        command = run.call_args.args[0]
        self.assertEqual(command[:5], ["xcrun", "--sdk", "macosx", "swift", "build"])
        self.assertIn("-print-diagnostic-groups", command)
        self.assertEqual(command[-3:], ["-Xswiftc", "-strict-concurrency=complete", "--build-tests"])


if __name__ == "__main__":
    unittest.main()
