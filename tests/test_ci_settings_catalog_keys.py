#!/usr/bin/env python3
"""scripts/ci/settings_catalog_keys.py: a schema text key missing from the catalog fails; a row's setting key does not;
with --base-rev, a key the base already misses is a note and a key newly missing at the head still fails."""
from __future__ import annotations

import contextlib
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import settings_catalog_keys as gate  # noqa: E402

TEXTS = ["settings.experiments.thing", "settings.experiments.thing.help"]


def tree(root: Path, catalog: list[str], texts: list[str] = TEXTS) -> None:
    """A schema source naming TEXTS, and a one-file-per-key catalog holding CATALOG (string_catalogs.py's shape)."""
    source = root / gate.SOURCES
    source.mkdir(parents=True, exist_ok=True)
    (source / "x.json").write_text(json.dumps({"lists": [{"rows": [
        {"key": "experiments.thing", "title": {"key": text, "text": text}} for text in texts]}]}))
    path = root / gate.CATALOG
    if path.exists():
        for old in path.glob("*.xcstrings"):
            old.unlink()
    path.mkdir(parents=True, exist_ok=True)
    for key in catalog:
        (path / f"{key}.xcstrings").write_text(json.dumps({"sourceLanguage": "en", "strings": {key: {}}}))


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()


def commit(repo: Path, message: str) -> str:
    git(repo, "add", "-A")
    git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", message)
    return git(repo, "rev-parse", "HEAD")


def run(argv: list[str]) -> tuple[int, str]:
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        code = gate.main(argv)
    return code, out.getvalue()


class SettingsCatalogKeysTests(unittest.TestCase):
    def test_missing_text_key_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tree(Path(tmp), ["settings.experiments.thing"])
            self.assertEqual(len(gate.missing(Path(tmp))), 1)
            self.assertEqual(run(["--root", tmp])[0], 1)

    def test_every_text_key_passes_and_row_key_is_not_a_text(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tree(Path(tmp), TEXTS)
            self.assertEqual(gate.missing(Path(tmp)), [])
            self.assertEqual(run(["--root", tmp])[0], 0)

    def test_repo_catalog_is_complete(self) -> None:
        self.assertEqual(gate.missing(ROOT), [])


class BaseCompareTests(unittest.TestCase):
    """The fast gates pass --base-rev BASE: only keys the change itself leaves missing fail."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self._tmp.name)
        git(self.repo, "init", "-q")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_key_already_missing_at_base_does_not_fail(self) -> None:
        tree(self.repo, ["settings.experiments.thing"])  # base misses .help (as feat-cmux-next did before #56824)
        base = commit(self.repo, "base")
        (self.repo / "unrelated.txt").write_text("a settings PR that does not touch .help\n")
        commit(self.repo, "head")
        self.assertEqual(run(["--root", str(self.repo)])[0], 1)  # without the base: today's red
        code, out = run(["--root", str(self.repo), "--base-rev", base])
        self.assertEqual(code, 0, out)
        self.assertIn("::notice::", out)
        self.assertIn("already missing on base", out)
        self.assertIn("settings.experiments.thing.help", out)
        self.assertNotIn("::error::", out)

    def test_key_newly_missing_at_head_fails(self) -> None:
        tree(self.repo, TEXTS)
        base = commit(self.repo, "base")
        tree(self.repo, ["settings.experiments.thing"])  # the change drops the .help catalog file
        commit(self.repo, "head")
        code, out = run(["--root", str(self.repo), "--base-rev", base])
        self.assertEqual(code, 1, out)
        self.assertIn("::error::", out)
        self.assertIn("settings.experiments.thing.help", out)

    def test_new_key_fails_even_on_a_red_base(self) -> None:
        tree(self.repo, ["settings.experiments.thing"])  # base already red on .help
        base = commit(self.repo, "base")
        tree(self.repo, ["settings.experiments.thing"], [*TEXTS, "settings.experiments.thing.footer"])
        commit(self.repo, "head")
        code, out = run(["--root", str(self.repo), "--base-rev", base])
        self.assertEqual(code, 1, out)
        errors = [line for line in out.splitlines() if line.startswith("::error::")]
        self.assertEqual(len(errors), 1, out)
        self.assertIn("settings.experiments.thing.footer", errors[0])
        self.assertIn("already missing on base", out)  # .help still noted as the base's

    def test_unreadable_base_excuses_nothing(self) -> None:
        tree(self.repo, ["settings.experiments.thing"])
        commit(self.repo, "only")
        code, out = run(["--root", str(self.repo), "--base-rev", "0" * 40])
        self.assertEqual(code, 1, out)
        self.assertIn("could not be read", out)


if __name__ == "__main__":
    unittest.main()
