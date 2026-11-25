"""scripts/cmux-next/settings-export-key-drift.py and its pre-push gate check: a settings export keeps every key the
base's export had and the sources still declare, and gains no key that no source declares.

2026-11-15: #43022 and #43027 each carried exports regenerated at an older tree. They dropped tabs.newTabApp from
schemas/settings/settings-schema.json, the docs settings reference and docs/mdm/*, while
schemas/settings/source/tabs.json still declared it. The Mac comparison (cmux-next generated files) was red on the
base for other reasons all day, so its signal was ignored; review caught both.
"""
from __future__ import annotations

import importlib.util
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1]
SCRIPT = SOURCE / "scripts/cmux-next/settings-export-key-drift.py"
CHECK = "Settings exports keep their keys (scripts/cmux-next/settings-export-key-drift.py)"


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


git_fixture_env = load("git_fixture_env", Path(__file__).resolve().parent / "git_fixture_env.py")


def source(*keys: str) -> str:
    return json.dumps({"lists": [{"name": "rows", "rows": [{"key": key} for key in keys]}]})


def exports(*keys: str) -> dict[str, bytes]:
    """The five keyed exports, each listing KEYS (the MDM files also carry a policy key, which is not a setting)."""
    rows = [{"key": key, "title": key} for key in keys]
    return {
        "schemas/settings/settings-schema.json": json.dumps({"version": 1, "rows": rows}).encode(),
        "web/data/next-docs/settings-reference.generated.json":
            json.dumps({"version": 1, "sections": [{"id": "general", "rows": rows}]}).encode(),
        "docs/mdm/com.manaflow.cmux.json":
            json.dumps({"properties": {"PolicyLock": {}, **{key: {"type": "string"} for key in keys}}}).encode(),
        "docs/mdm/com.manaflow.cmux.plist": plistlib.dumps({"pfm_subkeys": [
            {"pfm_name": "PayloadType"},
            *({"pfm_name": key, "pfm_subkeys": [{"pfm_name": "nested"}]} for key in keys)]}),
        "docs/mdm/managed-preferences.md":
            ("| Key | Type |\n| --- | --- |\n| `PolicyLock` | bool |\n"
             + "".join("| `%s` | string |\n" % key for key in keys)).encode(),
    }


class GitRange(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="cmux-settings-key-drift-test-")
        self.addCleanup(temporary.cleanup)
        self.repo = Path(temporary.name)
        self.env = git_fixture_env.fixture_env({
            **os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "F", "GIT_AUTHOR_EMAIL": "f@e",
            "GIT_COMMITTER_NAME": "F", "GIT_COMMITTER_EMAIL": "f@e"})
        git_fixture_env.init_repo(self.repo, env=self.env)
        self.write("schemas/settings/source/tabs.json", source("tabs.newTabApp", "tabs.position"))
        self.write("schemas/settings/source/page-layout.json", json.dumps({"cards": []}))
        self.write("schemas/settings/retired-keys.json",
                   json.dumps({"retired": [{"key": "ui.animations.bounce", "reason": "removed"}]}))
        self.write_exports("tabs.newTabApp", "tabs.position")
        # The gate runs the check only at a commit that has it (check_script).
        if SCRIPT.exists():
            self.write("scripts/cmux-next/settings-export-key-drift.py", SCRIPT.read_text())
        self.base = self.commit("base")

    def write(self, relative, text):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(text if isinstance(text, bytes) else text.encode())

    def write_exports(self, *keys):
        for path, data in exports(*keys).items():
            self.write(path, data)

    def commit(self, message):
        subprocess.run(["git", "-C", str(self.repo), "add", "-A"], env=self.env, check=True)
        subprocess.run(["git", "-C", str(self.repo), "commit", "-qm", message, "--allow-empty"], env=self.env,
                       check=True)
        return subprocess.run(["git", "-C", str(self.repo), "rev-parse", "HEAD"], env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def run_check(self, head, base=None):
        return subprocess.run([sys.executable, "-I", str(SCRIPT), "--repo", str(self.repo),
                               "--base", base or self.base, "--head", head],
                              env=self.env, capture_output=True, text=True)

    def gate(self, head):
        gate = load("cmux_next_prepush_gate_settings_keys", SOURCE / "scripts/cmux-next/prepush-gate.py")
        return dict(gate.gate(self.repo, self.base, head, {"settings-export-keys"}, False))

    def test_exports_from_an_older_tree_that_drop_a_declared_key_are_refused(self):
        # #43027: every export lost tabs.newTabApp; source/tabs.json still declares it.
        self.write_exports("tabs.position")
        head = self.commit("exports regenerated at an older tree")
        result = self.run_check(head)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            "drift: docs/mdm/com.manaflow.cmux.json: drops tabs.newTabApp, which the sources still declare",
            "drift: docs/mdm/com.manaflow.cmux.plist: drops tabs.newTabApp, which the sources still declare",
            "drift: docs/mdm/managed-preferences.md: drops tabs.newTabApp, which the sources still declare",
            "drift: schemas/settings/settings-schema.json: drops tabs.newTabApp, which the sources still declare",
            "drift: web/data/next-docs/settings-reference.generated.json: drops tabs.newTabApp, which the sources "
            "still declare",
        ])

    def test_one_export_dropping_a_key_is_refused(self):
        self.write("web/data/next-docs/settings-reference.generated.json",
                   exports("tabs.position")["web/data/next-docs/settings-reference.generated.json"])
        result = self.run_check(self.commit("stale reference"))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            "drift: web/data/next-docs/settings-reference.generated.json: drops tabs.newTabApp, which the sources "
            "still declare"])

    def test_a_key_no_source_declares_is_refused(self):
        # An older tree's export brings back a retired key, or one a later base removed from its source.
        self.write_exports("tabs.newTabApp", "tabs.position", "ui.animations.bounce", "nowhere.made.up")
        result = self.run_check(self.commit("old export"))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("drift: schemas/settings/settings-schema.json: adds nowhere.made.up, ui.animations.bounce, which "
                      "no source declares", result.stdout.splitlines())
        self.assertEqual(len(result.stdout.splitlines()), 5, result.stdout)

    def test_a_new_setting_not_yet_exported_passes(self):
        # The PR autofix exports it later: the source is ahead of the export, which is not drift.
        self.write("schemas/settings/source/tabs.json", source("tabs.newTabApp", "tabs.position", "tabs.fresh"))
        self.assertEqual(self.run_check(self.commit("add a setting")).returncode, 0)

    def test_a_new_setting_exported_passes(self):
        self.write("schemas/settings/source/tabs.json", source("tabs.newTabApp", "tabs.position", "tabs.fresh"))
        self.write_exports("tabs.newTabApp", "tabs.position", "tabs.fresh")
        self.assertEqual(self.run_check(self.commit("add and export a setting")).returncode, 0)

    def test_a_changed_row_that_leaves_an_export_passes(self):
        # A row whose source changes (consumers: browser only, hidden from the docs) may leave an export on purpose;
        # only a key whose source row is the same at both ends must stay (review of #43507, F1).
        self.write("schemas/settings/source/tabs.json", json.dumps({"lists": [{"name": "rows", "rows": [
            {"key": "tabs.newTabApp", "consumers": ["cmux-browser"]}, {"key": "tabs.position"}]}]}))
        for path in ("docs/mdm/com.manaflow.cmux.json", "docs/mdm/com.manaflow.cmux.plist",
                     "docs/mdm/managed-preferences.md"):
            self.write(path, exports("tabs.position")[path])
        result = self.run_check(self.commit("browser-only row leaves the MDM exports"))
        self.assertEqual((result.returncode, result.stdout), (0, ""), result.stderr)

    def test_a_hidden_row_leaving_a_stale_reference_passes(self):
        # cmux#51125: the base (a branch tip) already hid tabs.newTabApp from the Settings page, but its docs
        # reference was stale and still listed it. The reference regenerated at the head leaves the hidden row out
        # (export-next-docs.ts), which is right, not drift; the other exports must still keep it.
        self.write("schemas/settings/source/tabs.json", json.dumps({"lists": [{"name": "rows", "rows": [
            {"key": "tabs.newTabApp", "page_hidden": "cmux.json only"}, {"key": "tabs.position"}]}]}))
        base = self.commit("hide a row; reference not yet regenerated")
        reference = "web/data/next-docs/settings-reference.generated.json"
        self.write(reference, exports("tabs.position")[reference])
        result = self.run_check(self.commit("regenerated reference"), base=base)
        self.assertEqual((result.returncode, result.stdout), (0, ""), result.stderr)
        self.write_exports("tabs.position")
        result = self.run_check(self.commit("every export drops the hidden row"), base=base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertNotIn(reference, result.stdout)
        self.assertEqual(len(result.stdout.splitlines()), 4, result.stdout)

    def test_a_source_with_an_unexpected_shape_is_an_error_not_a_crash(self):
        self.write("schemas/settings/source/odd.json", json.dumps({"lists": ["not a list entry"]}))
        result = self.run_check(self.commit("odd source"))
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("cannot read the exports or sources", result.stderr)

    def test_a_removed_setting_not_yet_exported_passes(self):
        self.write("schemas/settings/source/tabs.json", source("tabs.position"))
        self.assertEqual(self.run_check(self.commit("remove a setting")).returncode, 0)

    def test_the_base_itself_is_never_red(self):
        result = self.run_check(self.base)
        self.assertEqual((result.returncode, result.stdout), (0, ""), result.stderr)

    def test_the_gate_refuses_the_drift_and_passes_a_clean_range(self):
        self.write_exports("tabs.position")
        stale = self.commit("exports regenerated at an older tree")
        self.assertIn(CHECK, self.gate(stale))
        self.assertIn("schemas/settings/settings-schema.json: drops tabs.newTabApp, which the sources still declare",
                      self.gate(stale)[CHECK])
        self.write_exports("tabs.newTabApp", "tabs.position")
        self.assertEqual(self.gate(self.commit("regenerated at the head")), {})


if __name__ == "__main__":
    unittest.main()
