#!/usr/bin/env python3
"""herdr-sync.py: vendoring, offline check and upstream drift for the herdr-derived plugin."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("herdr_sync", HERE.parent / "herdr-sync.py")
assert SPEC and SPEC.loader
herdr_sync = importlib.util.module_from_spec(SPEC)
sys.modules["herdr_sync"] = herdr_sync
SPEC.loader.exec_module(herdr_sync)

CODEX_V1 = 'id = "codex"\nversion = "2026.09.15.1"\n\n[[rules]]\nid = "working"\nstate = "working"\ncontains = ["esc to interrupt"]\n'
CODEX_V2 = CODEX_V1.replace("2026.09.15.1", "2026.10.01.1") + '\n[[rules]]\nid = "idle"\nstate = "idle"\ncontains = ["?"]\n'
GROK_V1 = 'id = "grok"\nversion = "2026.09.18.1"\n\n[[rules]]\nid = "spinner"\nstate = "working"\npriority = 100\n'
ENGINE_FILES = {
    "src/detect/manifest.rs": "// engine\n",
    "src/detect/mod.rs": "// identification\n",
    "src/detect/manifest_update.rs": "pub(crate) const MANIFEST_ENGINE_VERSION: u32 = 3;\n",
    "src/pane/agent_detection.rs": "// pacing\n",
    "src/pane/osc.rs": "// osc\n",
}


def run_git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(repo), *args], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    ).stdout.strip()


class FakeHerdr:
    """A throwaway git repository shaped like the parts of herdr the tool reads."""

    def __init__(self, root: Path) -> None:
        self.root = root
        root.mkdir()
        run_git(root, "init", "-q", "-b", "master")
        run_git(root, "config", "user.email", "test@example.invalid")
        run_git(root, "config", "user.name", "test")
        run_git(root, "config", "commit.gpgsign", "false")

    def commit(self, files: dict[str, str], message: str) -> str:
        for path, text in files.items():
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text, encoding="utf-8")
        run_git(self.root, "add", "-A")
        run_git(self.root, "commit", "-q", "-m", message)
        return run_git(self.root, "rev-parse", "HEAD")


class HerdrSyncTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.herdr = FakeHerdr(root / "herdr")
        self.first = self.herdr.commit(
            {
                "Cargo.toml": '[package]\nname = "herdr"\nversion = "0.9.2"\n',
                "src/detect/manifests/codex.toml": CODEX_V1,
                "src/detect/manifests/grok.toml": GROK_V1,
                **ENGINE_FILES,
            },
            "first",
        )
        self.plugin = root / "plugin"
        (self.plugin / "manifests").mkdir(parents=True)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def sync(self, rev: str) -> list[str]:
        return herdr_sync.sync(self.plugin, self.herdr.root, rev, "2026-10-08")

    def quiet_main(self, *argv: str) -> tuple[int, str]:
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = herdr_sync.main(["--plugin-dir", str(self.plugin), *argv])
        return code, out.getvalue()

    def test_sync_vendors_the_revision_and_check_accepts_it(self) -> None:
        self.sync(self.first)
        self.assertEqual((self.plugin / "manifests/codex.toml").read_text(encoding="utf-8"), CODEX_V1)
        sums = (self.plugin / "manifests/SHA256SUMS").read_text(encoding="utf-8").splitlines()
        self.assertEqual([line.split("  ")[1] for line in sums], ["codex.toml", "grok.toml"])
        pin = herdr_sync.load_pin(self.plugin)
        self.assertEqual(pin.revision, self.first)
        self.assertEqual(pin.herdr_version, "0.9.2")
        self.assertEqual(pin.engine_version, 3)
        self.assertEqual(sorted(pin.engine), sorted(ENGINE_FILES))
        self.assertEqual(herdr_sync.check(self.plugin), [])

    def test_sync_reads_an_older_revision_without_checking_it_out(self) -> None:
        self.herdr.commit({"src/detect/manifests/codex.toml": CODEX_V2}, "second")
        self.sync(self.first)
        self.assertEqual((self.plugin / "manifests/codex.toml").read_text(encoding="utf-8"), CODEX_V1)
        self.assertEqual((self.herdr.root / "src/detect/manifests/codex.toml").read_text(encoding="utf-8"), CODEX_V2)
        self.assertEqual(run_git(self.herdr.root, "status", "--porcelain"), "")

    def test_check_fails_when_a_vendored_file_or_the_pin_disagrees(self) -> None:
        self.sync(self.first)
        (self.plugin / "manifests/codex.toml").write_text(CODEX_V1 + "# local edit\n", encoding="utf-8")
        problems = herdr_sync.check(self.plugin)
        self.assertTrue(any("codex.toml" in problem and "SHA256SUMS" in problem for problem in problems), problems)
        self.assertTrue(any("without a documented local patch" in problem for problem in problems), problems)
        self.assertEqual(self.quiet_main("check")[0], 1)

        self.sync(self.first)
        pin = self.plugin / herdr_sync.PIN_NAME
        text = pin.read_text(encoding="utf-8")
        upstream = herdr_sync.sha256(CODEX_V1.encode())
        pin.write_text(text.replace(f'upstream_sha256 = "{upstream}"', f'upstream_sha256 = "{"0" * 64}"'), encoding="utf-8")
        problems = herdr_sync.check(self.plugin)
        self.assertTrue(any("differs from upstream" in problem for problem in problems), problems)

    def test_check_fails_for_an_unpinned_manifest(self) -> None:
        self.sync(self.first)
        (self.plugin / "manifests/extra.toml").write_text('id = "extra"\n', encoding="utf-8")
        problems = herdr_sync.check(self.plugin)
        self.assertTrue(any(problem.startswith("extra.toml") for problem in problems), problems)

    def test_documented_patch_is_reapplied_and_flagged_in_the_pin(self) -> None:
        (self.plugin / herdr_sync.PATCHES_NAME).write_text(
            '[[patch]]\nfile = "grok.toml"\nreason = "cmux keeps the older priority"\n'
            "[[patch.edit]]\nfind = '''priority = 100'''\nreplace = '''priority = 90'''\n",
            encoding="utf-8",
        )
        self.sync(self.first)
        vendored = (self.plugin / "manifests/grok.toml").read_text(encoding="utf-8")
        self.assertIn("priority = 90", vendored)
        pin = {entry.file: entry for entry in herdr_sync.load_pin(self.plugin).manifests}
        self.assertEqual(pin["grok.toml"].patch_reason, "cmux keeps the older priority")
        self.assertEqual(pin["grok.toml"].upstream_sha256, herdr_sync.sha256(GROK_V1.encode()))
        self.assertNotEqual(pin["grok.toml"].vendored_sha256, pin["grok.toml"].upstream_sha256)
        self.assertEqual(pin["codex.toml"].patch_reason, "")
        self.assertEqual(herdr_sync.check(self.plugin), [])

    def test_a_patch_that_no_longer_applies_fails_loudly(self) -> None:
        (self.plugin / herdr_sync.PATCHES_NAME).write_text(
            '[[patch]]\nfile = "grok.toml"\nreason = "precedence"\n'
            "[[patch.edit]]\nfind = '''priority = 100'''\nreplace = '''priority = 90'''\n",
            encoding="utf-8",
        )
        second = self.herdr.commit({"src/detect/manifests/grok.toml": GROK_V1.replace("priority = 100", "priority = 250")}, "upstream fix")
        with self.assertRaisesRegex(herdr_sync.SyncError, "no longer applies"):
            self.sync(second)

    def test_drift_reports_changed_manifests_and_engine_files(self) -> None:
        self.sync(self.first)
        pin, report = herdr_sync.drift(self.plugin, self.herdr.root, "HEAD")
        self.assertFalse(report.any)
        self.assertEqual(self.quiet_main("drift", "--herdr", str(self.herdr.root))[0], 0)

        self.herdr.commit(
            {
                "src/detect/manifests/codex.toml": CODEX_V2,
                "src/detect/manifests/letta.toml": 'id = "letta"\nversion = "2026.08.24.1"\n',
                "src/detect/mod.rs": "// identification, now with a wrapper\n",
            },
            "upstream detector change",
        )
        pin, report = herdr_sync.drift(self.plugin, self.herdr.root, "HEAD")
        self.assertEqual(report.changed, [("codex.toml", "2026.09.15.1", "2026.10.01.1")])
        self.assertEqual(report.added, ["letta.toml"])
        self.assertEqual(report.engine_changed, ["src/detect/mod.rs"])
        self.assertEqual(report.commits, [f"{report.upstream_revision[:7]} upstream detector change"])
        summary = herdr_sync.drift_markdown(pin, report)
        self.assertIn("`codex.toml` 2026.09.15.1 -> 2026.10.01.1", summary)
        self.assertIn("`src/detect/mod.rs`", summary)
        self.assertIn(f"compare/{self.first}...{report.upstream_revision}", summary)

        out = self.plugin / "summary.md"
        code, stdout = self.quiet_main("drift", "--herdr", str(self.herdr.root), "--summary-out", str(out))
        self.assertEqual(code, 1)
        self.assertIn("letta.toml", out.read_text(encoding="utf-8"))
        self.assertIn("letta.toml", stdout)

    def test_drift_ignores_unrelated_upstream_commits(self) -> None:
        self.sync(self.first)
        self.herdr.commit({"src/app/sidebar.rs": "// ui\n"}, "unrelated")
        _, report = herdr_sync.drift(self.plugin, self.herdr.root, "HEAD")
        self.assertFalse(report.any)

    def test_the_committed_plugin_matches_its_pin(self) -> None:
        # The offline gate that CI runs on every push.
        self.assertEqual(herdr_sync.check(herdr_sync.DEFAULT_PLUGIN_DIR), [])
        pin = herdr_sync.load_pin(herdr_sync.DEFAULT_PLUGIN_DIR)
        self.assertEqual(pin.repository, "https://github.com/ogulcancelik/herdr")
        self.assertEqual(sorted(pin.engine), sorted(herdr_sync.TRACKED_ENGINE_FILES))


if __name__ == "__main__":
    unittest.main()
