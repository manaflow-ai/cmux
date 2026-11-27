#!/usr/bin/env python3
"""scripts/ci/check-cmux-cua-helper-run.py, the check cmux-next-cua-helper-publish.yml runs.

Runs the check against this checkout's real scripts/build-cmux-cua.sh and the
files the helper key hashes, and against the feat-cmux-next shape of the patch
series (CMUX_CUA_PATCH_RELATIVE_PATHS=( ... )). A script in another shape fails
with a named error, never an AttributeError traceback.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / "scripts/ci/check-cmux-cua-helper-run.py"
WORKFLOW = ROOT / ".github/workflows/cmux-next-cua-helper-publish.yml"
INPUTS = [
    "scripts/build-cmux-cua.sh",
    "scripts/apply-cmux-cua-patch.sh",
    "scripts/strip-cmux-cua-rpaths.sh",
    "Resources/ComputerUseHelperIcon.icns",
    "cmux-tui/rust-toolchain.toml",
]
# scripts/cmux-cua-helper-key.sh (feat-cmux-next) reads the series with this sed rule.
KEY_SCRIPT_SED = (
    "sed -n '/^CMUX_CUA_PATCH_RELATIVE_PATHS=(/,/^)/p' \"$1\""
    " | sed -n 's/^[[:space:]]*\"\\([^\"]*\\)\"[[:space:]]*$/\\1/p'"
)

spec = importlib.util.spec_from_file_location("check_cmux_cua_helper_run", CHECK)
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def make_run(tmp: Path, src: Path, *, tamper: str | None = None) -> Path:
    """A cmux-cua-helper-unsigned artifact whose key.txt matches src, as the nightly writes it."""
    helper = tmp / "helper"
    helper.mkdir()
    build = (src / "scripts/build-cmux-cua.sh").read_text()
    fields = [
        f"recipe={check.RECIPE}",
        "cmux_cua_pinned_sha=" + re.search(r'^CMUX_CUA_PINNED_SHA="([0-9a-f]{40})"$', build, re.M).group(1),
        "build_script=" + sha(src / "scripts/build-cmux-cua.sh"),
        "apply_patch=" + sha(src / "scripts/apply-cmux-cua-patch.sh"),
        "strip_rpaths=" + sha(src / "scripts/strip-cmux-cua-rpaths.sh"),
        "icon=" + sha(src / "Resources/ComputerUseHelperIcon.icns"),
        "rust_toolchain=" + re.search(r'^channel = "(.*)"$', (src / "cmux-tui/rust-toolchain.toml").read_text(), re.M).group(1),
        "archs=arm64",
        "display_name=cmux Computer Use",
        "xcode=Xcode 26.1 Build version 17B55",
        "macos_sdk=26.1 25B74",
    ]
    for rel in check.patch_series(build):
        fields.append(f"patch:{rel}=" + ("0" * 64 if rel == tamper else sha(src / rel)))
    asset = "cmux-computer-use-unsigned-macos-arm64.zip"
    with zipfile.ZipFile(helper / asset, "w") as z:
        z.writestr("cmux Computer Use.app/Contents/Info.plist", plistlib.dumps({"CFBundleIdentifier": "com.cmuxterm.cua"}))
        z.writestr("cmux Computer Use.app/Contents/MacOS/cmux-cua", b"\0")
    key = hashlib.sha256("".join(f + "\n" for f in fields).encode()).hexdigest()
    head = [f"input_key={key}", f"asset={asset}", f"sha256={sha(helper / asset)}"]
    (helper / "key.txt").write_text("\n".join(head + fields) + "\n")
    return helper


def copy_inputs(dest: Path, build_text: str | None = None) -> Path:
    for rel in INPUTS:
        (dest / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / rel, dest / rel)
    for patch in (ROOT / "scripts").glob("cmux-cua-*.patch"):
        shutil.copy2(patch, dest / "scripts" / patch.name)
    if build_text is not None:
        (dest / "scripts/build-cmux-cua.sh").write_text(build_text)
    return dest


def run_check(helper: Path, src: Path, out: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, "-I", str(CHECK), str(helper), str(src), str(out), "https://example.invalid/run", "0" * 40],
        capture_output=True, text=True,
    )


def array_form(build_text: str) -> str:
    """This checkout's build script with its patch declared the way feat-cmux-next declares the series."""
    patches = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "scripts").glob("cmux-cua-*.patch"))
    block = "CMUX_CUA_PATCH_RELATIVE_PATHS=(\n" + "".join(f'  "{p}"\n' for p in patches) + ")"
    replaced, count = re.subn(r'^CMUX_CUA_PATCH_RELATIVE_PATH="[^"]+"$', lambda _: block, build_text, flags=re.M)
    if count == 0:
        replaced, count = re.subn(r"^CMUX_CUA_PATCH_RELATIVE_PATHS=\(\n.*?^\)$", lambda _: block, build_text, flags=re.M | re.S)
    assert count == 1, "no patch declaration to rewrite"
    return replaced


class PatchSeries(unittest.TestCase):
    def test_reads_this_checkouts_real_build_script(self) -> None:
        series = check.patch_series((ROOT / "scripts/build-cmux-cua.sh").read_text())
        self.assertTrue(series)
        for rel in series:
            self.assertTrue((ROOT / rel).is_file(), rel)

    def test_array_form_matches_the_key_scripts_rule(self) -> None:
        text = array_form((ROOT / "scripts/build-cmux-cua.sh").read_text())
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "build-cmux-cua.sh"
            path.write_text(text)
            sed = subprocess.run(["bash", "-c", KEY_SCRIPT_SED, "sed", str(path)], capture_output=True, text=True, check=True)
        self.assertEqual(check.patch_series(text), sed.stdout.split())
        self.assertGreaterEqual(len(check.patch_series(text)), 1)

    def test_another_shape_is_a_named_error(self) -> None:
        with self.assertRaises(check.CheckError) as raised:
            check.patch_series('CMUX_CUA_PATCHES="a.patch"\n')
        self.assertIn("patch series", str(raised.exception))


class RunCheck(unittest.TestCase):
    def check_source(self, build_text: str | None) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            src = copy_inputs(tmp / "run-source", build_text)
            helper = make_run(tmp, src)
            result = run_check(helper, src, tmp / "pins")
            self.assertEqual(result.returncode, 0, result.stderr)
            pin = json.loads((tmp / "pins/cmux-cua-helper.pin.json").read_text())
            self.assertEqual(pin["bundle_id"], "com.cmuxterm.cua")
            self.assertEqual(pin["r2_key"], f"cmux-cua-helper/{pin['sha256']}/{pin['asset']}")
            self.assertRegex((tmp / "pins/pinned_sha").read_text(), r"^[0-9a-f]{40}$")

    def test_passes_on_the_real_build_script(self) -> None:
        self.check_source(None)

    def test_passes_on_the_feat_cmux_next_series(self) -> None:
        self.check_source(array_form((ROOT / "scripts/build-cmux-cua.sh").read_text()))

    def test_refusals_name_the_problem(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            src = copy_inputs(tmp / "run-source")
            rel = check.patch_series((src / "scripts/build-cmux-cua.sh").read_text())[0]
            helper = make_run(tmp, src, tamper=rel)
            result = run_check(helper, src, tmp / "pins")
            self.assertEqual(result.returncode, 1)
            self.assertIn(f"patch:{rel}", result.stderr)
            self.assertNotIn("Traceback", result.stderr)
            self.assertFalse((tmp / "pins/cmux-cua-helper.pin.json").exists())

            (src / "scripts/build-cmux-cua.sh").write_text("#!/bin/bash\n")
            result = run_check(helper, src, tmp / "pins")
            self.assertEqual(result.returncode, 1)
            self.assertIn("cannot read CMUX_CUA_PINNED_SHA", result.stderr)
            self.assertNotIn("Traceback", result.stderr)


class Workflow(unittest.TestCase):
    def test_workflow_runs_mains_check_and_parses_nothing_inline(self) -> None:
        text = WORKFLOW.read_text()
        self.assertIn("python3 -I scripts/ci/check-cmux-cua-helper-run.py", text)
        self.assertIn("scripts/ci/check-cmux-cua-helper-run.py\n", text.split("- name: Checkout the run's helper inputs")[0])
        self.assertNotIn(".group(", text)
        self.assertNotIn("re.search", text)
        self.assertNotIn("sed -n 's/^asset=", text)


if __name__ == "__main__":
    unittest.main()
