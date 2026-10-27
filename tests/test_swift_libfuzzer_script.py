#!/usr/bin/env python3
"""Regression checks of scripts/cmux-next/swift-libfuzzer.sh's run and classification (p10-stability-182).

The script needs a Swift toolchain with the libFuzzer runtime to build its targets. This test puts a
fake `swift` and `swiftc` first on PATH: they build one C libFuzzer target (clang -fsanitize=fuzzer)
under every target name of the package, so the script's own option parsing, artifact choice,
random baseline and exit status run unchanged. Skips when clang cannot link libFuzzer.

Run: python3 tests/test_swift_libfuzzer_script.py
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SCRIPT = Path(os.environ.get("SWIFT_LIBFUZZER_SCRIPT", REPO / "scripts/cmux-next/swift-libfuzzer.sh"))
PACKAGE = REPO / "Packages/Shared/CmuxFuzzSupport/LinuxFuzz"

# FAKE_FUZZ_MODE picks the finding: "seed-crash" traps on a nonempty input (the seed is "c"),
# "random-crash" traps only on an input of 2 or more bytes (the seed is 1 byte, and random inputs
# of up to 256 bytes reach 2 bytes), anything else is clean.
TARGET_C = textwrap.dedent(
    r"""
    #include <stdint.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>

    int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
      const char *mode = getenv("FAKE_FUZZ_MODE");
      if (mode && strcmp(mode, "seed-crash") == 0 && size > 0) __builtin_trap();
      if (mode && strcmp(mode, "random-crash") == 0 && size >= 2) __builtin_trap();
      return 0;
    }

    int LLVMFuzzerInitialize(int *argc, char ***argv) {
      if (*argc == 2 && strcmp((*argv)[1], "--cmux-corpus-name") == 0) {
        puts("Fake.oneInput");
        exit(0);
      }
      if (*argc == 3 && strcmp((*argv)[1], "--cmux-write-seeds") == 0) {
        char path[4096];
        snprintf(path, sizeof path, "%s/seed-0", (*argv)[2]);
        FILE *file = fopen(path, "wb");
        if (!file) exit(1);
        fputc('c', file);
        exit(fclose(file) == 0 ? 0 : 1);
      }
      return 0;
    }
    """
)

FAKE_SWIFT = textwrap.dedent(
    """\
    #!/usr/bin/env bash
    # A fake swift for test_swift_libfuzzer_script.py: build compiles the C target under every name.
    set -euo pipefail
    if [[ "${1:-}" == --version ]]; then echo "fake swift"; exit 0; fi
    [[ "${1:-}" == build ]] || { echo "fake swift: $*" >&2; exit 1; }
    for arg in "$@"; do
      if [[ "$arg" == --show-bin-path ]]; then echo "$FAKE_ROOT/bin"; exit 0; fi
    done
    mkdir -p "$FAKE_ROOT/bin"
    clang -fsanitize=fuzzer -O1 "$FAKE_ROOT/target.c" -o "$FAKE_ROOT/bin/fuzzer"
    for name in $FAKE_TARGETS; do cp "$FAKE_ROOT/bin/fuzzer" "$FAKE_ROOT/bin/$name"; done
    """
)

FAKE_SWIFTC = textwrap.dedent(
    """\
    #!/usr/bin/env bash
    printf '{"paths": {"runtimeResourcePath": "%s/usr/lib/swift"}}\\n' "$FAKE_ROOT"
    """
)


def clang_links_libfuzzer(scratch: Path) -> bool:
    if shutil.which("clang") is None:
        return False
    source = scratch / "probe.c"
    source.write_text("#include <stdint.h>\n#include <stddef.h>\nint LLVMFuzzerTestOneInput(const uint8_t *d, size_t n) { return 0; }\n")
    result = subprocess.run(
        ["clang", "-fsanitize=fuzzer", str(source), "-o", str(scratch / "probe")],
        capture_output=True,
        check=False,
    )
    return result.returncode == 0


class SwiftLibFuzzerScriptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.scratch = Path(tempfile.mkdtemp(prefix="swift-libfuzzer-test-"))
        self.addCleanup(shutil.rmtree, self.scratch, True)
        if not clang_links_libfuzzer(self.scratch):
            self.skipTest("clang cannot link -fsanitize=fuzzer here")
        self.root = self.scratch / "toolchain"
        (self.root / "usr/lib/swift").mkdir(parents=True)
        (self.root / "usr/lib/libclang_rt.fuzzer-x86_64.a").touch()
        (self.root / "target.c").write_text(TARGET_C)
        tools = self.root / "path"
        tools.mkdir()
        for name, body in (("swift", FAKE_SWIFT), ("swiftc", FAKE_SWIFTC)):
            tool = tools / name
            tool.write_text(body)
            tool.chmod(0o755)
        self.targets = sorted(
            path.name for path in (PACKAGE / "Sources").glob("*Fuzzer") if (path / "main.swift").is_file()
        )
        self.assertIn("SelfTestFuzzer", self.targets)
        self.env = {
            **os.environ,
            "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}",
            "FAKE_ROOT": str(self.root),
            "FAKE_TARGETS": " ".join(self.targets),
        }
        self.env.pop("ASAN_OPTIONS", None)
        self.env.pop("LSAN_OPTIONS", None)
        # The caller's directory: a run must leave nothing here.
        self.cwd = self.scratch / "cwd"
        self.cwd.mkdir()

    def run_script(self, mode: str, *args: str) -> tuple[int, list[dict], Path]:
        out = self.scratch / f"out-{mode}"
        result = subprocess.run(
            [str(SCRIPT), "--out", str(out), "--scratch", str(self.scratch / "build"), "--seconds", "30", *args],
            cwd=self.cwd,
            env={**self.env, "FAKE_FUZZ_MODE": mode},
            capture_output=True,
            text=True,
            check=False,
            timeout=600,
        )
        summary = out / "summary.jsonl"
        rows = [json.loads(line) for line in summary.read_text().splitlines() if line.strip()] if summary.exists() else []
        self.assertEqual(sorted(os.listdir(self.cwd)), [], "a run wrote into the caller's directory")
        self.assertNotIn("unbound variable", result.stderr)
        return result.returncode, rows, out

    def test_clean_run_of_every_target_in_parallel(self) -> None:
        status, rows, _ = self.run_script("clean", "--all", "--parallel", "3", "--", "-runs=0")
        self.assertEqual(status, 0)
        self.assertEqual(sorted(row["target"] for row in rows), [t for t in self.targets if t != "SelfTestFuzzer"])
        for row in rows:
            self.assertEqual(row["verdict"], "clean")
            self.assertIsNone(row["artifact"])
            self.assertIsNone(row["random_verdict"])
            self.assertIsNone(row["random_edges"])

    def test_no_extra_flags(self) -> None:
        # An empty `--` tail: the libFuzzer flags array is empty, which bash 3.2 rejects under set -u
        # unless the script guards it. -max_total_time ends the run.
        status, rows, _ = self.run_script("clean", "--target", "SelfTestFuzzer", "--seconds", "1")
        self.assertEqual(status, 0)
        self.assertEqual([row["verdict"] for row in rows], ["clean"])

    def test_fuzzing_crash_is_the_first_artifact(self) -> None:
        status, rows, out = self.run_script("seed-crash", "--target", "SelfTestFuzzer", "--", "-runs=0")
        self.assertEqual(status, 1)
        [row] = rows
        self.assertEqual(row["verdict"], "crash")
        artifact = Path(row["artifact"])
        self.assertTrue(artifact.name.startswith("crash-"))
        self.assertTrue(artifact.is_file())
        self.assertTrue(artifact.is_relative_to(out / "artifacts" / "SelfTestFuzzer"))

    def test_random_baseline_clean_records_edges(self) -> None:
        status, rows, out = self.run_script(
            "clean", "--target", "SelfTestFuzzer", "--random-baseline", "32", "--", "-runs=0"
        )
        self.assertEqual(status, 0)
        [row] = rows
        self.assertEqual(row["random_verdict"], "clean")
        self.assertIsNone(row["random_artifact"])
        self.assertIsInstance(row["random_edges"], int)
        self.assertIsInstance(row["random_features"], int)
        # Empty artifact directories go.
        self.assertEqual(os.listdir(out / "artifacts" / "SelfTestFuzzer"), [])

    def test_random_baseline_crash_is_a_finding(self) -> None:
        status, rows, out = self.run_script(
            "random-crash", "--target", "SelfTestFuzzer", "--random-baseline", "64", "--", "-runs=0"
        )
        self.assertEqual(status, 1)
        [row] = rows
        self.assertEqual(row["verdict"], "clean")
        self.assertEqual(row["random_verdict"], "crash")
        artifact = Path(row["random_artifact"])
        self.assertTrue(artifact.name.startswith("crash-"))
        self.assertTrue(artifact.parent.name.startswith("random-"))
        self.assertTrue(artifact.is_relative_to(out / "artifacts" / "SelfTestFuzzer"))
        # The pass stopped at the crash, so its coverage is not a full baseline.
        self.assertIsNone(row["random_edges"])
        self.assertIsNone(row["random_features"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
