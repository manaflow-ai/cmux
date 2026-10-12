#!/usr/bin/env python3
"""scripts/cmux-next/compile-string-catalogs.sh compiles every String Catalog that
`swift build` copied into the resource bundles."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "cmux-next" / "compile-string-catalogs.sh"

FAKE_XCRUN = r"""#!/usr/bin/env python3
import os, sys, time
args = sys.argv[1:]
assert args[:2] == ["xcstringstool", "compile"], args
catalog = args[2]
out = args[args.index("--output-directory") + 1]
with open(os.environ["FAKE_CALLS"], "a") as calls:
    calls.write(f"start {time.monotonic()} {catalog}\n")
time.sleep(0.3)
if "Broken" in catalog:
    raise SystemExit(3)
open(os.path.join(out, "compiled-" + os.path.basename(catalog)), "w").close()
with open(os.environ["FAKE_CALLS"], "a") as calls:
    calls.write(f"end {time.monotonic()} {catalog}\n")
"""


class CompileStringCatalogsTests(unittest.TestCase):
    def _setup(self, temp: pathlib.Path, names: list[str]) -> tuple[pathlib.Path, dict[str, str]]:
        bin_dir = temp / "bin"
        bin_dir.mkdir()
        (bin_dir / "xcrun").write_text(FAKE_XCRUN, encoding="utf-8")
        (bin_dir / "xcrun").chmod(0o755)
        # SwiftPM must not be asked when the caller passes the bin path.
        (bin_dir / "swift").write_text("#!/bin/sh\necho swift was called >&2\nexit 9\n", encoding="utf-8")
        (bin_dir / "swift").chmod(0o755)
        products = temp / "Package" / ".build" / "arm64-apple-macosx" / "debug"
        for index, name in enumerate(names):
            bundle = products / f"Target{index}_Target{index}.bundle"
            bundle.mkdir(parents=True)
            (bundle / f"{name}.xcstrings").write_text("{}", encoding="utf-8")
        env = os.environ.copy()
        env["PATH"] = f"{bin_dir}:{env['PATH']}"
        env["FAKE_CALLS"] = str(temp / "calls.txt")
        env["CMUX_SWIFT_BIN_PATH"] = str(products)
        return products, env

    def test_catalogs_compile_in_parallel_from_the_given_bin_path(self) -> None:
        """hq11 fixed-cost profile (2026-10-09): 100 catalogs compiled one at a
        time took 5-12 s of every CmuxNext suite step."""
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = pathlib.Path(temp_dir).resolve()
            names = [f"Localizable{i}" for i in range(6)]
            products, env = self._setup(temp, names)
            completed = subprocess.run(
                [str(SCRIPT)], cwd=temp / "Package", env=env, text=True,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60,
            )
            self.assertEqual(completed.returncode, 0, completed.stdout)
            self.assertIn("compiled 6 string catalogs", completed.stdout)
            self.assertEqual(len(list(products.glob("*.bundle/compiled-*.xcstrings"))), 6)
            starts, ends = [], []
            for line in (temp / "calls.txt").read_text(encoding="utf-8").splitlines():
                kind, at, _ = line.split(" ", 2)
                (starts if kind == "start" else ends).append(float(at))
            # Some compile started before another ended: they ran at once.
            self.assertLess(sorted(starts)[1], min(ends), (starts, ends))

    def test_a_failed_catalog_fails_the_compile(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = pathlib.Path(temp_dir).resolve()
            _, env = self._setup(temp, ["Good", "Broken", "AlsoGood"])
            completed = subprocess.run(
                [str(SCRIPT)], cwd=temp / "Package", env=env, text=True,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60,
            )
            self.assertNotEqual(completed.returncode, 0, completed.stdout)
            self.assertNotIn("compiled 3 string catalogs", completed.stdout)


if __name__ == "__main__":
    unittest.main()
