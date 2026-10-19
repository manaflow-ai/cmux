"""The defaults guard: a pull request that changes what everyone gets by default fails until a
call owner other than its author approves its head (Leo 2026-10-13).

Each test builds a small repository with the guard copied in (the trusted base checkout the
workflow runs from), commits a base and a head, and runs `defaults_guard.py check` as the
workflow does, with the pull request's reviews as data.
"""

import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/defaults_guard.py"
AUTHOR = "teamleaderleo"
OWNERS = {"cmux-next": ["lawrencecchen", "austinywang", "teamleaderleo"]}


def action(id, key=None, modifiers=(), aliases=()):
    shortcut = {"key": key, "modifiers": list(modifiers)} if key else None
    return {"id": id, "default_shortcut": shortcut, "default_chord": None,
            "default_aliases": [{"keys": [{"key": k, "modifiers": list(m)}], "when": None} for k, m in aliases]}


BASE_ACTIONS = [
    action("nextSidebarTab", "]", ["shift", "cmd"], aliases=[("\t", ["ctrl"]), ("", ["ctrl"])]),
    action("nextSurface"),
    action("focusUp", "", ["opt", "cmd"]),
    action("toggleEditor"),
]
BASE_SETTINGS = [{"key": "terminal.showJumpToBottomButton", "default": False},
                 {"key": "sidebar.numbering", "default": "allItems"}]
KEYBINDS = '''nonisolated static let cmuxDefaultKeybindLines = [
    "keybind = super+j=unbind",
]
'''
FLAGS = "enum PaneSplitCommand {\n    static let optimisticSplitEnabled = false\n}\n"


class Repo:
    def __init__(self, root):
        self.root = root

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True, text=True).stdout.strip()

    def write(self, path, text):
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text, encoding="utf-8")

    def sources(self, actions, settings, keybinds=KEYBINDS, flags=FLAGS):
        self.write("plans/cmux-next/action-surfaces.json", json.dumps({"actions": actions}))
        self.write("schemas/settings/settings-schema.json", json.dumps({"rows": settings}))
        self.write("Packages/macOS/CmuxNext/Sources/CmuxNextTerminal/GhosttyRuntime+Keybinds.swift", keybinds)
        self.write("Packages/macOS/CmuxNext/Sources/CmuxNextApp/PaneSplitCommand.swift", flags)

    def guard(self, *args, env=None):
        return subprocess.run([sys.executable, str(self.root / "scripts/ci/defaults_guard.py"), *args],
                              cwd=self.root, capture_output=True, text=True, env={**os.environ, **(env or {})})

    def commit(self, message):
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")


class DefaultsGuardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(pathlib.Path(self.tmp.name))
        self.repo.git("init", "-q")
        self.repo.write("scripts/ci/defaults_guard.py", SCRIPT.read_text(encoding="utf-8"))
        self.repo.write(".github/defaults-call-owners.json", json.dumps(OWNERS))
        self.repo.sources(BASE_ACTIONS, BASE_SETTINGS)
        self.base = self.repo.commit("base")

    def tearDown(self):
        self.tmp.cleanup()

    def head(self, actions=None, settings=None, keybinds=KEYBINDS, flags=FLAGS, extra=None):
        self.repo.git("checkout", "-q", "-b", f"pr-{len(self.repo.git('branch').splitlines())}", self.base)
        self.repo.sources(actions or BASE_ACTIONS, settings or BASE_SETTINGS, keybinds, flags)
        for path, text in (extra or {}).items():
            self.repo.write(path, text)
        head = self.repo.commit("head")
        self.repo.git("checkout", "-q", self.base)  # the workflow runs the base's guard and owners
        return head

    def check(self, head, reviews=(), author=AUTHOR):
        pull = {"author": {"login": author}, "headRefOid": head, "merged": False,
                "reviews": {"nodes": [{"author": {"login": who}, "state": state, "commit": {"oid": oid}}
                                      for who, state, oid in reviews]},
                "comments": {"nodes": []}}
        path = self.repo.root.parent / f"{self.repo.root.name}-pull.json"
        path.write_text(json.dumps(pull), encoding="utf-8")
        summary = self.repo.root.parent / f"{self.repo.root.name}-summary.md"
        summary.write_text("", encoding="utf-8")
        result = self.repo.guard("check", "--base", self.base, "--head", head, "--pull-json", str(path),
                                 env={"GITHUB_STEP_SUMMARY": str(summary)})
        result.summary = summary.read_text(encoding="utf-8")
        return result

    # The cases that just bit us.

    def test_a_new_default_chord_fails_and_names_it(self):
        actions = [*BASE_ACTIONS[:3], action("toggleEditor", "e", ["ctrl", "cmd"])]
        result = self.check(self.head(actions))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("DEFAULTS key.toggleEditor: + ctrl+cmd+e", result.stdout)
        self.assertIn("::warning title=Default changed::DEFAULTS key.toggleEditor", result.stdout)

    def test_moving_ctrl_tab_to_another_action_names_both(self):
        actions = [action("nextSidebarTab", "]", ["shift", "cmd"], aliases=[("", ["ctrl"])]),
                   action("nextSurface", "\t", ["ctrl"]), *BASE_ACTIONS[2:]]
        result = self.check(self.head(actions))
        self.assertEqual(result.returncode, 1)
        self.assertIn("DEFAULTS key.nextSidebarTab: - ctrl+tab", result.stdout)
        self.assertIn("DEFAULTS key.nextSurface: + ctrl+tab", result.stdout)

    def test_a_new_arrow_chord_reads_by_key_name(self):
        actions = [*BASE_ACTIONS[:2], action("focusUp", "", ["shift", "cmd"]), BASE_ACTIONS[3]]
        result = self.check(self.head(actions))
        self.assertIn("DEFAULTS key.focusUp: + shift+cmd+up; - opt+cmd+up", result.stdout)

    def test_a_ui_feature_turned_on_by_default_fails(self):
        settings = [{"key": "terminal.showJumpToBottomButton", "default": True}, BASE_SETTINGS[1]]
        result = self.check(self.head(settings=settings))
        self.assertEqual(result.returncode, 1)
        self.assertIn("DEFAULTS setting.terminal.showJumpToBottomButton: false -> true", result.stdout)

    def test_taking_a_chord_from_ghostty_fails(self):
        keybinds = KEYBINDS.replace("]\n", '    "keybind = super+d=unbind",\n]\n')
        result = self.check(self.head(keybinds=keybinds))
        self.assertEqual(result.returncode, 1)
        self.assertIn('DEFAULTS ghostty.super+d: (none) -> "unbind"', result.stdout)

    def test_a_compiled_flag_turned_on_fails(self):
        result = self.check(self.head(flags=FLAGS.replace("false", "true")))
        self.assertEqual(result.returncode, 1)
        self.assertIn("DEFAULTS flag.CmuxNextApp/PaneSplitCommand.optimisticSplitEnabled: false -> true", result.stdout)

    def test_two_flags_with_one_name_are_judged_apart(self):
        two = "enum A {\n    static let isEnabled = false\n}\nenum B {\n    static let isEnabled = true\n}\n"
        self.repo.write("Packages/macOS/CmuxNext/Sources/CmuxNextApp/Trace.swift", two)
        self.repo.write("Packages/macOS/CmuxNext/Sources/CmuxNextTerminal/Trace.swift", "enum C {\n    static let isEnabled = false\n}\n")
        self.base = self.repo.commit("two flags")
        head = self.head(extra={"Packages/macOS/CmuxNext/Sources/CmuxNextApp/Trace.swift": two.replace("= false", "= true"),
                                "Packages/macOS/CmuxNext/Sources/CmuxNextTerminal/Trace.swift": "enum C {\n    static let isEnabled = false\n}\n"})
        result = self.check(head)
        self.assertEqual(result.returncode, 1)
        self.assertIn("DEFAULTS flag.CmuxNextApp/Trace.isEnabled: false -> true", result.stdout)

    def test_a_default_that_steps_aside_in_a_terminal_fails(self):
        swift = "public static let yieldsToTerminal: Set<ActionID> = [\n    \"focusHistoryBack\",\n]\n"
        self.repo.write("Packages/macOS/CmuxNext/Sources/CmuxNextActions/KeyBindingDefaults.swift", swift)
        self.base = self.repo.commit("steps aside")
        head = self.head(extra={"Packages/macOS/CmuxNext/Sources/CmuxNextActions/KeyBindingDefaults.swift":
                                swift.replace("]", '    "splitRight",\n]')})
        result = self.check(head)
        self.assertEqual(result.returncode, 1)
        self.assertIn("DEFAULTS steps-aside.yieldsToTerminal: + splitRight", result.stdout)

    def test_a_newline_in_a_default_cannot_start_a_workflow_command(self):
        settings = [*BASE_SETTINGS, {"key": "x\n::error::forged @someone", "default": True}]
        result = self.check(self.head(settings=settings))
        self.assertNotIn("\n::error::forged", result.stdout)
        self.assertNotIn("\n::error::forged", result.summary)
        self.assertIn("`setting.x\\n::error::forged @someone`", result.summary)

    # Who may pass it.

    def changed_head(self):
        return self.head(settings=[BASE_SETTINGS[0], {"key": "sidebar.numbering", "default": "workspacesOnly"}])

    def test_no_review_fails_and_the_summary_says_who_must_approve(self):
        result = self.check(self.changed_head())
        self.assertEqual(result.returncode, 1)
        self.assertIn("Needs a call", result.summary)
        self.assertIn("@lawrencecchen or @austinywang", result.summary)
        self.assertNotIn("@teamleaderleo", result.summary.split("Needs a call")[1].split("\n")[0])

    def test_a_call_owner_approving_the_head_passes_and_the_changes_stay_listed(self):
        head = self.changed_head()
        result = self.check(head, reviews=[("lawrencecchen", "APPROVED", head)])
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("::warning title=Default changed::DEFAULTS setting.sidebar.numbering", result.stdout)
        self.assertIn("Approved on this commit by @lawrencecchen", result.summary)

    def test_the_author_approving_never_passes_even_as_a_call_owner(self):
        head = self.changed_head()
        self.assertEqual(self.check(head, reviews=[(AUTHOR, "APPROVED", head)]).returncode, 1)

    def test_an_approval_of_an_earlier_commit_does_not_pass(self):
        head = self.changed_head()
        result = self.check(head, reviews=[("austinywang", "APPROVED", self.base)])
        self.assertEqual(result.returncode, 1)
        self.assertIn("Earlier approvals on an older commit: @austinywang", result.summary)

    def test_someone_outside_the_owners_file_approving_does_not_pass(self):
        head = self.changed_head()
        self.assertEqual(self.check(head, reviews=[("someone-else", "APPROVED", head)]).returncode, 1)

    def test_a_later_change_request_replaces_an_approval(self):
        head = self.changed_head()
        reviews = [("lawrencecchen", "APPROVED", head), ("lawrencecchen", "CHANGES_REQUESTED", head)]
        self.assertEqual(self.check(head, reviews=reviews).returncode, 1)

    def test_a_head_that_adds_its_author_to_the_owners_file_still_fails(self):
        owners = json.dumps({"cmux-next": ["lawrencecchen", "someone-else"]})
        head = self.head(settings=[BASE_SETTINGS[0], {"key": "sidebar.numbering", "default": "workspacesOnly"}],
                         extra={".github/defaults-call-owners.json": owners})
        result = self.check(head, reviews=[("someone-else", "APPROVED", head)], author="someone")
        self.assertEqual(result.returncode, 1)
        self.assertIn("DEFAULTS guard..github/defaults-call-owners.json: (none) -> \"edited\"", result.stdout)

    def test_checked_out_directories_judge_as_commits_do(self):
        # The workflow checks out only the guard's files of the merge base and the head.
        head = self.changed_head()
        dirs = {}
        for name, sha in (("base", self.base), ("head", head)):
            dirs[name] = self.repo.root.parent / f"{self.repo.root.name}-{name}"
            self.repo.git("worktree", "add", "-q", "--detach", str(dirs[name]), sha)
        pull = {"author": {"login": AUTHOR}, "headRefOid": head, "merged": False,
                "reviews": {"nodes": [{"author": {"login": "austinywang"}, "state": "APPROVED", "commit": {"oid": head}}]},
                "comments": {"nodes": []}}
        path = self.repo.root.parent / f"{self.repo.root.name}-dir-pull.json"
        path.write_text(json.dumps(pull), encoding="utf-8")
        result = self.repo.guard("check", "--base", str(dirs["base"]), "--head", str(dirs["head"]),
                                 "--head-sha", head, "--pull-json", str(path))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('DEFAULTS setting.sidebar.numbering: "allItems" -> "workspacesOnly"', result.stdout)

    def test_a_linked_file_in_a_checked_out_head_is_refused(self):
        secret = self.repo.root.parent / f"{self.repo.root.name}-runner-secret.json"
        secret.write_text(json.dumps({"rows": [{"key": "leak", "default": "runner file"}]}), encoding="utf-8")
        head = self.repo.root.parent / f"{self.repo.root.name}-linked-head"
        self.repo.git("worktree", "add", "-q", "--detach", str(head), self.base)
        settings = head / "schemas/settings/settings-schema.json"
        settings.unlink()
        settings.symlink_to(secret)
        result = self.repo.guard("check", "--base", str(self.repo.root), "--head", str(head), "--head-sha", self.base)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is a symbolic link", result.stdout + result.stderr)
        self.assertNotIn("runner file", result.stdout + result.stderr)

    def test_backticks_in_head_text_cannot_end_its_code_span(self):
        key = "x``@someone [a](http://e)``y"
        result = self.check(self.head(settings=[*BASE_SETTINGS, {"key": key, "default": True}]))
        line = next(l for l in result.summary.splitlines() if "@someone" in l)
        span = line[2:line.index(": ")]
        fence = span[:len(span) - len(span.lstrip("`"))]
        self.assertGreater(len(fence), 2, line)
        self.assertEqual(span.count(fence), 2, line)  # opened once, closed once, never inside

    # No committed snapshot (hq#2572 step 1): every default comes from the sources at check time.

    STALE = json.dumps({"app": "cmux-next", "version": 1, "defaults": {"setting.terminal.showJumpToBottomButton": True}})

    def test_a_committed_snapshot_is_never_read(self):
        # A branch from before hq#2572 still carries the old file; a stale copy must not hide a change.
        self.repo.write("schemas/defaults/cmux-next.json", self.STALE)
        self.base = self.repo.commit("base with a stale snapshot")
        head = self.head(settings=[{"key": "terminal.showJumpToBottomButton", "default": True}, BASE_SETTINGS[1]])
        result = self.check(head)
        self.assertEqual(result.returncode, 1)
        self.assertIn("DEFAULTS setting.terminal.showJumpToBottomButton: false -> true", result.stdout)

    def test_no_default_change_passes_without_a_review(self):
        actions = [*BASE_ACTIONS[:3], {**action("toggleEditor"), "title": "Toggle Editor"}]
        result = self.check(self.head(actions))
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("DEFAULTS", result.stdout)

    def test_check_fresh_refuses_a_committed_snapshot(self):
        self.repo.write("schemas/defaults/cmux-next.json", self.STALE)
        sha = self.repo.commit("someone committed the snapshot again")
        for args in (("check-fresh", "--ref", sha), ("check-fresh",)):
            with self.subTest(args=args):
                result = self.repo.guard(*args)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("schemas/defaults/cmux-next.json is committed, but it is build output now", result.stdout)

    def test_check_fresh_passes_with_an_untracked_snapshot(self):
        # `snapshot` writes the ignored build output; check-fresh only refuses a tracked copy.
        self.assertEqual(self.repo.guard("snapshot").returncode, 0)
        self.assertTrue((self.repo.root / "schemas/defaults/cmux-next.json").is_file())
        result = self.repo.guard("check-fresh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_snapshot_prints_every_default_from_the_sources(self):
        result = self.repo.guard("snapshot", "--out", "-")
        self.assertEqual(result.returncode, 0, result.stderr)
        values = json.loads(result.stdout)["defaults"]
        self.assertEqual(values["setting.sidebar.numbering"], "allItems")
        self.assertEqual(values["key.nextSidebarTab"], ["ctrl+pagedown", "ctrl+tab", "shift+cmd+]"])
        self.assertEqual(values["ghostty.super+j"], "unbind")
        self.assertIs(values["flag.CmuxNextApp/PaneSplitCommand.optimisticSplitEnabled"], False)
        self.assertFalse((self.repo.root / "schemas/defaults/cmux-next.json").exists())

if __name__ == "__main__":
    unittest.main()
