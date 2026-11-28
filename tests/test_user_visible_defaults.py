#!/usr/bin/env python3
"""scripts/ci/user_visible_defaults.py flags a watched default's change, warns only, and fails open.

Leo, ask-5ad71ec59c: "Flag changes to user-visible defaults (like the banner, the Live button or Cmd+N)."
Each case is a two-commit fixture repo: base, then a head that changes defaults.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
_here = pathlib.Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("git_fixture_env", _here / "git_fixture_env.py")
git_fixture_env = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(git_fixture_env)

ROOT = _here.parent
_spec = importlib.util.spec_from_file_location("user_visible_defaults", ROOT / "scripts/ci/user_visible_defaults.py")
uvd = importlib.util.module_from_spec(_spec)
sys.modules["user_visible_defaults"] = uvd  # dataclasses look their module up by name
_spec.loader.exec_module(uvd)

WATCH = (ROOT / "scripts/ci/user-visible-defaults.json").read_text()


def action(id, key=None, modifiers=()):
    shortcut = {"key": key, "modifiers": list(modifiers)} if key else None
    return {"id": id, "default_shortcut": shortcut, "default_chord": None, "default_aliases": []}


def settings_source(live: bool, unread: str, other: bool) -> str:
    rows = [
        {"key": "sidebar.showLiveToggle", "kind": "toggle", "default": live},
        {"key": "agentPane.display.unreadBanner", "kind": "choice", "default": unread},
        {"key": "sidebar.compact", "kind": "toggle", "default": other},
    ]
    return json.dumps({"sections": [{"rows": rows}]}, indent=2) + "\n"


def surfaces(new_tab_key: str, other_key: str) -> str:
    actions = [action("newTab", new_tab_key, ["cmd"]), action("openThing", other_key, ["cmd"])]
    return json.dumps({"actions": actions}, indent=2, separators=(",", " : ")) + "\n"


def tunable_swift(banner: bool) -> str:
    return ('enum HostPressureTunables {\n'
            f'    static let banner = Tunable<Bool>.toggle("hostPressure.banner", "Banner", default: {str(banner).lower()})\n'
            '}\n')


class UserVisibleDefaultsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = pathlib.Path(self.tmp.name)
        env = git_fixture_env.write_env(dict(os.environ))
        self.env = mock.patch.dict(os.environ, env, clear=True)
        self.env.start()
        self.root = mock.patch.object(uvd, "ROOT", self.repo)
        self.root.start()
        self.git("init", "-q", "-b", "main")
        self.write(live=True, unread="off", other=False, new_tab="n", other_key="o", banner=False)
        self.base = self.commit("base")

    def tearDown(self) -> None:
        self.root.stop()
        self.env.stop()
        self.tmp.cleanup()

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True, capture_output=True, text=True).stdout

    def put(self, path: str, text: str) -> None:
        file = self.repo / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)

    def write(self, *, live, unread, other, new_tab, other_key, banner) -> None:
        self.put("scripts/ci/user-visible-defaults.json", WATCH)
        self.put("schemas/settings/source/sidebar.json", settings_source(live, unread, other))
        self.put("plans/cmux-next/action-surfaces.json", surfaces(new_tab, other_key))
        self.put("Packages/macOS/CmuxNext/Sources/CmuxNextApp/HostPressure/HostPressureTunables.swift", tunable_swift(banner))

    def commit(self, message: str) -> str:
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD").strip()

    def head(self, **changes) -> list:
        values = dict(live=True, unread="off", other=False, new_tab="n", other_key="o", banner=False)
        values.update(changes)
        self.write(**values)
        return uvd.run(self.base, self.commit("head"))

    def test_the_live_button_flip_is_flagged_at_its_line(self) -> None:
        [flag] = self.head(live=False)
        self.assertEqual(flag.rule, "the Live button")
        self.assertEqual(flag.change.id, "setting.sidebar.showLiveToggle")
        self.assertEqual(flag.change.detail, "true -> false")
        self.assertEqual(flag.path, "schemas/settings/source/sidebar.json")
        text = (self.repo / flag.path).read_text().splitlines()
        self.assertIn('"sidebar.showLiveToggle"', text[flag.line - 1])
        self.assertTrue(flag.annotation.startswith(f"::warning file={flag.path},line={flag.line},"))

    def test_a_banner_setting_and_a_banner_tunable_are_flagged(self) -> None:
        found = {f.change.id: f for f in self.head(unread="always", banner=True)}
        self.assertEqual(set(found), {"setting.agentPane.display.unreadBanner", "tunable.hostPressure.banner"})
        self.assertTrue(all(f.rule == "the banner" for f in found.values()))
        self.assertTrue(found["tunable.hostPressure.banner"].path.endswith("HostPressureTunables.swift"))

    def test_cmd_n_moving_to_another_action_is_flagged_on_both(self) -> None:
        found = {f.change.id: f.change.detail for f in self.head(new_tab="t", other_key="n")}
        self.assertEqual(found, {"key.newTab": "+ cmd+t; - cmd+n", "key.openThing": "+ cmd+n; - cmd+o"})

    def test_an_unwatched_default_is_not_flagged(self) -> None:
        self.assertEqual(self.head(other=True, other_key="p"), [])

    def test_a_broken_read_warns_and_exits_zero(self) -> None:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = uvd.main(["--base", "0" * 40])
        self.assertEqual(code, 0)
        self.assertIn("::warning title=user-visible defaults check skipped::", out.getvalue())

    def test_main_writes_the_step_summary_and_exits_zero(self) -> None:
        self.write(live=False, unread="off", other=False, new_tab="n", other_key="o", banner=False)
        self.commit("head")
        summary = self.repo / "summary.md"
        out = io.StringIO()
        with mock.patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(summary)}), contextlib.redirect_stdout(out):
            code = uvd.main(["--base", self.base])
        self.assertEqual(code, 0)
        self.assertIn("::warning file=schemas/settings/source/sidebar.json", out.getvalue())
        self.assertIn("| the Live button | `setting.sidebar.showLiveToggle` | true -> false |", summary.read_text())


if __name__ == "__main__":
    unittest.main()
