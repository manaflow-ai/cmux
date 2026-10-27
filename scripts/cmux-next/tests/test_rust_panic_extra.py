#!/usr/bin/env python3
"""rust_panic_ratchet.py --manifest: report-only rows of the shipped Rust workspaces outside cmux-tui (Q10, p10-stability-155).

A row is a package named by its repo-relative directory; a path dependency outside the run's workspace adds no row
and no hit; the workspace-relative and absolute file names of two hosts name one file; counts above
rust-panic-extra-baseline.json warn and exit 0; an unfinished run has no rows and exits 2 after the rest's report;
--update-baseline only lowers rows and adds new ones as found; rust-panic-baseline.json is never read or written.

Not a CI job (Lawrence 2026-10-23: no new CI gates): run it yourself after a change to the ratchet:
  python3 -I scripts/cmux-next/tests/test_rust_panic_extra.py
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
REPO = SCRIPTS.parents[1]


def load_ratchet():
    spec = importlib.util.spec_from_file_location("rust_panic_ratchet", SCRIPTS / "rust_panic_ratchet.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def artifact(package_dir, kind="lib", root="/w"):
    return {"reason": "compiler-artifact", "package_id": f"path+file://{root}/{package_dir}#0.1.0",
            "manifest_path": f"{root}/{package_dir}/Cargo.toml", "target": {"kind": [kind]}}


def hit(package_dir, file_name, line, lint="unwrap_used", column=5, root="/w"):
    return {"reason": "compiler-message", "package_id": f"path+file://{root}/{package_dir}#0.1.0",
            "manifest_path": f"{root}/{package_dir}/Cargo.toml", "target": {"kind": ["lib"]},
            "message": {"code": {"code": f"clippy::{lint}"},
                        "spans": [{"is_primary": True, "file_name": file_name, "line_start": line,
                                   "column_start": column}]}}


def finished(success=True):
    return {"reason": "build-finished", "success": success}


SIDECAR = "Native/DiffSidecar"
MOBILE = "cmux-next-ios/rust"
HOST = f"{MOBILE}/crates/cmux-mobile-host"
LINK = f"{MOBILE}/crates/cmux-mobile-link"


class ExtraManifestTests(unittest.TestCase):
    def setUp(self):
        self.ratchet = load_ratchet()
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        for workspace in (SIDECAR, MOBILE, HOST, LINK):
            (self.dir / workspace).mkdir(parents=True, exist_ok=True)
            (self.dir / workspace / "Cargo.toml").write_text("[package]\n")
        self.main_baseline = self.dir / "rust-panic-baseline.json"
        self.main_baseline.write_text('{"crates": {}}\n')
        self.extra_baseline = self.dir / "rust-panic-extra-baseline.json"
        self.ratchet.BASELINE = str(self.main_baseline)
        self.ratchet.EXTRA_BASELINE = str(self.extra_baseline)
        self.ratchet.EXTRA_MANIFESTS = [f"{SIDECAR}/Cargo.toml", f"{MOBILE}/Cargo.toml", "Native/OptChat/x/Cargo.toml"]

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name, items):
        path = self.dir / name
        path.write_text("".join(json.dumps(item) + "\n" for item in items))
        return str(path)

    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        old = sys.argv
        sys.argv = ["rust_panic_ratchet.py", "--repo", str(self.dir), *argv]
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                try:
                    rc = self.ratchet.main()
                except SystemExit as exit_:
                    rc = exit_.code
        finally:
            sys.argv = old
        return rc, out.getvalue(), err.getvalue()

    def sidecar_run(self, name="sidecar.jsonl", success=True, hits=2):
        items = [artifact(SIDECAR), artifact(SIDECAR, "bin")]
        items += [hit(SIDECAR, "src/server.rs", 10 + n) for n in range(hits)]
        items += [finished(success)]
        return self.write(name, items)

    def mobile_run(self, name="mobile.jsonl", root="/w", extra=()):
        return self.write(name, [
            artifact(HOST, root=root), artifact(LINK, root=root),
            # A path dependency outside the workspace: linted by its own run (or the cmux-tui one), never here.
            artifact("cmux-tui/crates/cmux-wg", root=root),
            hit("cmux-tui/crates/cmux-wg", f"{root}/cmux-tui/crates/cmux-wg/src/lib.rs", 3, root=root),
            hit(HOST, "crates/cmux-mobile-host/src/surface.rs", 7, lint="indexing_slicing", root=root),
            *extra,
            finished(),
        ])

    def manifests(self, *runs):
        argv = []
        for manifest, run in runs:
            argv += ["--manifest", manifest, run]
        return argv

    def test_rows_are_repo_relative_packages_and_skip_path_dependencies(self):
        rc, out, err = self.run_main(*self.manifests((f"{SIDECAR}/Cargo.toml", self.sidecar_run()),
                                                     (MOBILE, self.mobile_run())), "--report", "json")
        self.assertEqual(rc, 0, err)
        rows = json.loads(out)
        self.assertEqual(sorted(rows), [SIDECAR, HOST, LINK])
        self.assertEqual(rows[SIDECAR]["counts"], {"unwrap_used": 2})
        self.assertEqual(rows[HOST]["counts"], {"indexing_slicing": 1})
        self.assertEqual(rows[LINK]["counts"], {})
        self.assertTrue(rows[LINK]["deny"])
        self.assertIsNone(rows[SIDECAR]["baseline"])
        self.assertIn(f"{HOST}/src/surface.rs 1", rows[HOST]["top"])

    def test_two_hosts_merge_by_repo_path_within_one_workspace(self):
        linux = self.mobile_run("linux.jsonl")
        macos = self.mobile_run("macos.jsonl", root="/Users/fleet/w", extra=[
            hit(HOST, "/Users/fleet/w/cmux-next-ios/rust/crates/cmux-mobile-host/src/macos.rs", 4,
                root="/Users/fleet/w"),
        ])
        rc, out, err = self.run_main(*self.manifests((MOBILE, f"linux={linux}"), (MOBILE, f"macos={macos}"),
                                                     (SIDECAR, self.sidecar_run())), "--report", "md")
        self.assertEqual(rc, 0, err)
        self.assertIn(f"| {HOST} | 1 | 0 | 0 | 0 | 0 | 0 | 1 |", out)
        macos_table = out.split("### Hits only the macos run saw (1)")[1].split("###")[0]
        self.assertIn(f"| {HOST} | unwrap | {HOST}/src/macos.rs:4:5 |", macos_table)
        # The single-run sidecar workspace is not "only linux": the merge is per workspace.
        self.assertIn("### Hits only the linux run saw (0)", out)

    def test_counts_above_the_extra_baseline_warn_and_pass(self):
        self.extra_baseline.write_text(json.dumps({"crates": {
            SIDECAR: {lint: 0 for lint in self.ratchet.LINTS} | {"unwrap_used": 1}}}))
        rc, out, err = self.run_main(*self.manifests((SIDECAR, self.sidecar_run())), "--report", "md")
        self.assertEqual(rc, 0, err)
        self.assertIn("| vs baseline |", out)
        self.assertIn(f"| {SIDECAR} | 2 |", out)
        self.assertIn("| no | +1 |", out)
        self.assertIn(f"report-only)::{SIDECAR}: clippy::unwrap_used 2 > baseline 1", err)
        self.assertIn("### Separate workspaces not in this run (2)", out)
        self.assertIn("- Native/OptChat/x", out)

    def test_never_reads_or_writes_the_ci_baseline(self):
        self.main_baseline.write_text("not json: reading it would raise\n")
        rc, _, err = self.run_main(*self.manifests((SIDECAR, self.sidecar_run())), "--init-baseline")
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.main_baseline.read_text(), "not json: reading it would raise\n")
        written = json.loads(self.extra_baseline.read_text())
        self.assertEqual(written["crates"][SIDECAR]["unwrap_used"], 2)
        self.assertIn("CI never reads", written["_doc"])

    def test_update_lowers_rows_adds_new_ones_and_never_raises(self):
        base = {lint: 0 for lint in self.ratchet.LINTS}
        self.extra_baseline.write_text(json.dumps({"crates": {
            SIDECAR: base | {"unwrap_used": 1, "expect_used": 3},
            "Native/OptChat/gone": base | {"panic": 4},
        }}))
        rc, _, err = self.run_main(*self.manifests((SIDECAR, self.sidecar_run()), (MOBILE, self.mobile_run())),
                                   "--update-baseline")
        self.assertEqual(rc, 0, err)
        crates = json.loads(self.extra_baseline.read_text())["crates"]
        self.assertEqual(crates[SIDECAR]["unwrap_used"], 1)  # 2 seen, never raised
        self.assertEqual(crates[SIDECAR]["expect_used"], 0)  # lowered
        self.assertEqual(crates[HOST]["indexing_slicing"], 1)  # new row as found
        self.assertEqual(crates["Native/OptChat/gone"]["panic"], 4)  # not in this run: kept

    def test_unfinished_run_has_no_rows_and_exits_2_after_the_report(self):
        broken = self.sidecar_run("broken.jsonl", success=False)
        rc, out, err = self.run_main(*self.manifests((SIDECAR, f"linux={broken}"), (MOBILE, self.mobile_run())),
                                     "--report", "md")
        self.assertEqual(rc, 2)
        self.assertNotIn(f"| {SIDECAR} |", out)
        self.assertIn(f"| {HOST} |", out)
        self.assertIn(f"- {SIDECAR} (linux)", out)
        self.assertIn("did not finish", err)

    def test_mixing_with_the_ci_run_or_omitting_report_is_refused(self):
        run = self.sidecar_run()
        rc, _, err = self.run_main(*self.manifests((SIDECAR, run)), "--clippy-json", run, "--report", "md")
        self.assertEqual(rc, 2)
        self.assertIn("never mix with the --clippy-json run", err)
        rc, _, err = self.run_main(*self.manifests((SIDECAR, run)))
        self.assertEqual(rc, 2)
        self.assertIn("report-only", err)
        rc, _, err = self.run_main(*self.manifests(("Native/Nope/Cargo.toml", run)), "--report", "md")
        self.assertEqual(rc, 2)
        self.assertIn("no Cargo.toml there", err)
        rc, _, err = self.run_main(*self.manifests((SIDECAR, f"x={run}"), (SIDECAR, f"x={run}")), "--report", "md")
        self.assertEqual(rc, 2)
        self.assertIn("labelled 'x'", err)
        self.assertFalse(self.extra_baseline.exists())


class CommittedFilesTests(unittest.TestCase):
    """The committed list and baselines: every listed workspace exists and has rows only in the report-only file."""

    def setUp(self):
        self.ratchet = load_ratchet()

    def test_listed_manifests_exist_and_print(self):
        for manifest in self.ratchet.EXTRA_MANIFESTS:
            self.assertTrue((REPO / manifest).is_file(), manifest)
        out = io.StringIO()
        old = sys.argv
        sys.argv = ["rust_panic_ratchet.py", "--list-manifests"]
        try:
            with contextlib.redirect_stdout(out):
                self.assertEqual(self.ratchet.main(), 0)
        finally:
            sys.argv = old
        self.assertEqual(out.getvalue().split(), self.ratchet.EXTRA_MANIFESTS)

    def test_every_listed_workspace_has_extra_rows_and_none_in_the_ci_baseline(self):
        extra = json.loads((SCRIPTS / "rust-panic-extra-baseline.json").read_text())["crates"]
        ci = json.loads((SCRIPTS / "rust-panic-baseline.json").read_text())["crates"]
        for manifest in self.ratchet.EXTRA_MANIFESTS:
            workspace = manifest.rsplit("/", 1)[0]
            self.assertTrue(any(row == workspace or row.startswith(workspace + "/") for row in extra), workspace)
        self.assertFalse(set(extra) & set(ci))
        for row in extra.values():
            self.assertEqual(sorted(row), sorted(self.ratchet.LINTS))


if __name__ == "__main__":
    unittest.main()
