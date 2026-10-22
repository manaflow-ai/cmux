"""The defaults guard: a pull request that changes what everyone gets by default fails until an
independent review receipt ships its head, or a call owner other than its author approves it
(Leo 2026-10-13, 2026-10-21). A new setting that defaults to off passes on its own.

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

    def commit(self, message, snapshot=True):
        if snapshot:
            result = self.guard("snapshot")
            assert result.returncode == 0, result.stdout + result.stderr
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

    def head(self, actions=None, settings=None, keybinds=KEYBINDS, flags=FLAGS, snapshot=True, extra=None):
        self.repo.git("checkout", "-q", "-b", f"pr-{len(self.repo.git('branch').splitlines())}", self.base)
        self.repo.sources(actions or BASE_ACTIONS, settings or BASE_SETTINGS, keybinds, flags)
        for path, text in (extra or {}).items():
            self.repo.write(path, text)
        head = self.repo.commit("head", snapshot=snapshot)
        self.repo.git("checkout", "-q", self.base)  # the workflow runs the base's guard and owners
        return head

    def check(self, head, reviews=(), author=AUTHOR, comments=()):
        pull = {"author": {"login": author}, "headRefOid": head, "merged": False,
                "reviews": {"nodes": [{"author": {"login": who}, "state": state, "commit": {"oid": oid}}
                                      for who, state, oid in reviews]},
                "comments": {"nodes": [{"databaseId": n, "body": body, "createdAt": at,
                                        "authorAssociation": association,
                                        "author": {"login": AUTHOR, "__typename": kind}}
                                       for n, (body, at, association, kind) in enumerate(comments)]}}
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
        self.assertIn("Needs a review", result.summary)
        self.assertIn("@lawrencecchen or @austinywang", result.summary)
        self.assertNotIn("@teamleaderleo", result.summary.split("Needs a review")[1].split("\n")[0])

    def test_a_call_owner_approving_the_head_passes_and_the_changes_stay_listed(self):
        head = self.changed_head()
        result = self.check(head, reviews=[("lawrencecchen", "APPROVED", head)])
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("::warning title=Default changed::DEFAULTS setting.sidebar.numbering", result.stdout)
        self.assertIn("Signed off on this commit by @lawrencecchen", result.summary)

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

    # The snapshot itself.

    def test_a_branch_from_before_the_snapshot_is_judged_by_its_sources(self):
        self.repo.git("rm", "-q", "schemas/defaults/cmux-next.json")
        self.base = self.repo.commit("base before the snapshot", snapshot=False)
        head = self.head(settings=[{"key": "terminal.showJumpToBottomButton", "default": True}, BASE_SETTINGS[1]],
                         snapshot=False)
        result = self.check(head)
        self.assertEqual(result.returncode, 1)
        self.assertIn("DEFAULTS setting.terminal.showJumpToBottomButton: false -> true", result.stdout)
        self.assertNotIn("snapshot", result.stdout.replace("defaults_guard.py snapshot", ""))

    def test_no_default_change_passes_without_a_review(self):
        actions = [*BASE_ACTIONS[:3], {**action("toggleEditor"), "title": "Toggle Editor"}]
        result = self.check(self.head(actions))
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("DEFAULTS", result.stdout)

    # The snapshot is bot-only (#21946): the base autofix rewrites it after a merge, a pull request
    # never commits it, and the guard judges a head by its sources and exports.

    def test_a_head_that_does_not_commit_the_snapshot_is_judged_by_its_sources(self):
        actions = [*BASE_ACTIONS[:3], action("toggleEditor", "e", ["ctrl", "cmd"])]
        head = self.head(actions, snapshot=False)
        result = self.check(head)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("DEFAULTS key.toggleEditor: + ctrl+cmd+e", result.stdout)
        self.assertNotIn("does not match the sources", result.stdout)
        approved = self.check(head, reviews=[("lawrencecchen", "APPROVED", head)])
        self.assertEqual(approved.returncode, 0, approved.stdout)

    def test_a_hand_edited_snapshot_cannot_hide_a_default_change(self):
        actions = [*BASE_ACTIONS[:3], action("toggleEditor", "e", ["ctrl", "cmd"])]
        stale = self.repo.root.joinpath("schemas/defaults/cmux-next.json").read_text(encoding="utf-8")
        head = self.head(actions, snapshot=False, extra={"schemas/defaults/cmux-next.json": stale})
        result = self.check(head, reviews=[("lawrencecchen", "APPROVED", head)])
        # Judged as a change that needs the call, not only as a stale file.
        self.assertIn("::warning title=Default changed::DEFAULTS key.toggleEditor", result.stdout)

    # An independent review receipt on the head passes any change (Leo 2026-10-21).

    def receipt(self, text, at="2026-10-21T10:00:00Z", association="MEMBER", kind="User"):
        return (text, at, association, kind)

    def test_a_ship_receipt_on_the_head_passes_without_a_teammate(self):
        head = self.changed_head()
        result = self.check(head, comments=[self.receipt(f"Review (subagent, correctness first): SHIP at {head}\n\nok")])
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("Signed off on this commit by `review (subagent, correctness first)`", result.summary)

    def test_a_ship_receipt_posted_as_a_review_body_passes(self):
        head = self.changed_head()
        pull = {"author": {"login": AUTHOR}, "headRefOid": head, "merged": False, "comments": {"nodes": []},
                "reviews": {"nodes": [{"author": {"login": AUTHOR, "__typename": "User"}, "authorAssociation": "MEMBER",
                                       "state": "COMMENTED", "submittedAt": "2026-10-21T10:00:00Z",
                                       "body": f"Review (subagent): SHIP at {head}", "commit": {"oid": head}}]}}
        path = self.repo.root.parent / f"{self.repo.root.name}-review-pull.json"
        path.write_text(json.dumps(pull), encoding="utf-8")
        result = self.repo.guard("check", "--base", self.base, "--head", head, "--pull-json", str(path))
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_a_receipt_for_another_commit_or_a_short_sha_does_not_pass(self):
        head = self.changed_head()
        for text in (f"Review (subagent): SHIP at {self.base}", f"Review (subagent): SHIP at {head[:12]}"):
            result = self.check(head, comments=[self.receipt(text)])
            self.assertEqual(result.returncode, 1, text)
            self.assertIn("Needs a review", result.summary)

    def test_a_later_block_beats_an_earlier_ship(self):
        head = self.changed_head()
        result = self.check(head, comments=[
            self.receipt(f"Review (subagent): SHIP at {head}", at="2026-10-21T10:00:00Z"),
            self.receipt(f"Review (second subagent): BLOCK at {head}", at="2026-10-21T11:00:00Z")])
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("BLOCK from `review (second subagent)`", result.summary)
        later = self.check(head, comments=[
            self.receipt(f"Review (subagent): BLOCK at {head}", at="2026-10-21T10:00:00Z"),
            self.receipt(f"Review (subagent): SHIP at {head}", at="2026-10-21T11:00:00Z")])
        self.assertEqual(later.returncode, 0, later.stdout)

    def test_a_self_review_an_outsider_or_a_bot_does_not_pass(self):
        head = self.changed_head()
        for receipt in (self.receipt(f"Review (self): SHIP at {head}"),
                        self.receipt(f"Review (subagent): SHIP at {head}", association="CONTRIBUTOR"),
                        self.receipt(f"Review (subagent): SHIP at {head}", kind="Bot")):
            self.assertEqual(self.check(head, comments=[receipt]).returncode, 1, receipt)

    def test_a_receipt_below_the_first_line_does_not_pass(self):
        head = self.changed_head()
        result = self.check(head, comments=[self.receipt(f"Thanks!\nReview (subagent): SHIP at {head}")])
        self.assertEqual(result.returncode, 1, result.stdout)

    # A new setting whose default is off keeps what everyone had before it existed.

    def test_an_added_setting_that_defaults_off_passes_without_a_review(self):
        for default in (False, None, "off", "never", ""):
            settings = [*BASE_SETTINGS, {"key": "sidebar.newThing", "default": default}]
            result = self.check(self.head(settings=settings))
            self.assertEqual(result.returncode, 0, f"{default!r}: {result.stdout}")
            self.assertIn("DEFAULTS setting.sidebar.newThing", result.stdout)
            self.assertIn("passes on its own", result.summary)

    def test_an_added_setting_that_defaults_on_needs_a_review(self):
        for default in (True, "ask", "every-merge"):
            settings = [*BASE_SETTINGS, {"key": "sidebar.newThing", "default": default}]
            head = self.head(settings=settings)
            self.assertEqual(self.check(head).returncode, 1, default)
            shipped = self.check(head, comments=[self.receipt(f"Review (subagent): SHIP at {head}")])
            self.assertEqual(shipped.returncode, 0, shipped.stdout)

    def test_an_off_default_on_an_existing_setting_or_a_new_flag_is_not_exempt(self):
        settings = [{"key": "terminal.showJumpToBottomButton", "default": None}, BASE_SETTINGS[1]]
        self.assertEqual(self.check(self.head(settings=settings)).returncode, 1)
        flags = FLAGS + "enum Other {\n    static let newThingEnabled = false\n}\n"
        self.assertEqual(self.check(self.head(flags=flags)).returncode, 1)

    def test_a_free_new_setting_beside_a_real_change_still_needs_a_review(self):
        settings = [BASE_SETTINGS[0], {"key": "sidebar.numbering", "default": "workspacesOnly"},
                    {"key": "sidebar.newThing", "default": False}]
        result = self.check(self.head(settings=settings))
        self.assertEqual(result.returncode, 1)
        self.assertIn("1 default(s) changed", result.stdout)

    def test_check_fresh_still_finds_a_stale_snapshot(self):
        """No CI check runs check-fresh any more (the snapshot is stale between a merge and the base
        autofix's commit); it stays the command that says the snapshot needs regenerating."""
        actions = [*BASE_ACTIONS[:3], action("toggleEditor", "e", ["ctrl", "cmd"])]
        head = self.head(actions, snapshot=False)
        result = self.repo.guard("check-fresh", "--ref", head)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("does not match the sources; run `python3 scripts/ci/defaults_guard.py snapshot`", result.stdout)



SETTINGS_SOURCES = "Packages/macOS/CmuxNext/Sources/CmuxNextSettings"
EXPORTER_TESTS = "Packages/macOS/CmuxNext/Tests/CmuxNextSettingsTests"
STAMP = "schemas/settings-export/settings-schema.sources.sha256"


def stamp_for(root):
    """The stamp SettingsSchemaExportTests writes: one `sha256  path` entry per exporter input, in
    UTF-8 path order, a blank line between entries so two pull requests that edit different
    sources change lines git merges apart (#21946)."""
    import hashlib
    paths = [f"{EXPORTER_TESTS}/ManagedPreferencesManifestTests.swift", f"{EXPORTER_TESTS}/SettingsSchemaExportTests.swift"]
    paths += [file.relative_to(root).as_posix() for file in (root / SETTINGS_SOURCES).rglob("*")
              if file.suffix in (".swift", ".xcstrings")]
    paths.sort(key=lambda path: path.encode("utf-8"))
    return "\n\n".join(f"{hashlib.sha256((root / path).read_bytes()).hexdigest()}  {path}" for path in paths) + "\n"


class SettingsExportStampTests(unittest.TestCase):
    """`check-fresh` and the settings export stamp (schemas/settings-export/settings-schema.sources.sha256)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(pathlib.Path(self.tmp.name))
        self.repo.git("init", "-q", "-b", "main")
        self.repo.write("scripts/ci/defaults_guard.py", SCRIPT.read_text(encoding="utf-8"))
        self.repo.write(".github/defaults-call-owners.json", json.dumps(OWNERS))
        self.repo.sources(BASE_ACTIONS, BASE_SETTINGS)
        self.repo.write(f"{EXPORTER_TESTS}/ManagedPreferencesManifestTests.swift", "// manifest\n")
        self.repo.write(f"{EXPORTER_TESTS}/SettingsSchemaExportTests.swift", f"// writes {STAMP.rsplit('/', 1)[1]}\n")
        for name in ("Alpha.swift", "Beta.swift", "Gamma.swift", "Localizable.xcstrings"):
            self.repo.write(f"{SETTINGS_SOURCES}/{name}", f"// {name}\n")
        self.repo.write(f"{SETTINGS_SOURCES}/README.md", "not an input\n")
        self.export()
        self.repo.commit("base")

    def tearDown(self):
        self.tmp.cleanup()

    def export(self):
        self.repo.write(STAMP, stamp_for(self.repo.root))

    def fresh(self, *args):
        return self.repo.guard("check-fresh", *args)

    def test_a_stamp_of_every_input_is_fresh(self):
        result = self.fresh()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(len(self.repo.root.joinpath(STAMP).read_text().split("\n\n")), 6)

    def test_an_edited_source_is_stale_and_named(self):
        self.repo.write(f"{SETTINGS_SOURCES}/Beta.swift", "// beta, edited\n")
        result = self.fresh()
        self.assertEqual(result.returncode, 1)
        self.assertIn("settings exports are stale", result.stdout)
        self.assertIn(f"{SETTINGS_SOURCES}/Beta.swift", result.stdout)
        self.assertNotIn("Alpha.swift", result.stdout)

    def test_an_added_or_removed_source_is_stale_and_named(self):
        self.repo.write(f"{SETTINGS_SOURCES}/Delta.swift", "// delta\n")
        (self.repo.root / SETTINGS_SOURCES / "Gamma.swift").unlink()
        result = self.fresh()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Delta.swift", result.stdout)
        self.assertIn("Gamma.swift", result.stdout)

    def test_a_one_digest_stamp_from_before_the_manifest_is_stale(self):
        self.repo.write(STAMP, "a01b76447321b7bdf25b78a05bd9a7e530b92e767537d604bae476d7084a7bde\n")
        result = self.fresh()
        self.assertEqual(result.returncode, 1)
        self.assertIn("settings exports are stale", result.stdout)

    def merge_two_branches(self):
        for branch, name in (("one", "Alpha.swift"), ("two", "Gamma.swift")):
            self.repo.git("checkout", "-q", "-b", branch, "main")
            self.repo.write(f"{SETTINGS_SOURCES}/{name}", f"// {name}, edited on {branch}\n")
            self.export()
            self.repo.commit(branch, snapshot=False)
        self.repo.git("checkout", "-q", "one")
        self.repo.git("-c", "user.name=t", "-c", "user.email=t@t", "merge", "-q", "--no-edit", "two")

    def test_a_clone_with_the_merge_drivers_keeps_one_stamp_so_check_fresh_fails(self):
        """A line-merged stamp would match the merged sources while settings-schema.json and docs/mdm
        (cmux-generated-v1: one side's copy) miss the other branch's rows, so check-fresh would pass
        on stale exports. With the repository's drivers (the bots, a lane's local merge) the stamp
        keeps one side too, and check-fresh names the other side's source until the exports are
        regenerated. GitHub ignores drivers: there the stamp merges by line and the base autofix
        regenerates the exports, which it does whenever CmuxNextSettings changed."""
        self.repo.write(".gitattributes", (ROOT / ".gitattributes").read_text(encoding="utf-8"))
        self.repo.commit("attributes", snapshot=False)
        self.repo.git("config", "merge.cmux-generated-v1.driver", "true")
        self.merge_two_branches()
        result = self.fresh()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Gamma.swift", result.stdout)

    def test_two_branches_editing_different_sources_merge_by_line_without_drivers(self):
        """GitHub's view (no drivers): the two stamps merge cleanly, so neither pull request shows a
        conflict, and the merged stamp is the merged sources'."""
        self.merge_two_branches()
        self.assertEqual(self.repo.root.joinpath(STAMP).read_text(), stamp_for(self.repo.root))

    def test_check_fresh_reads_a_commit_as_it_reads_a_checkout(self):
        head = self.repo.git("rev-parse", "HEAD")
        self.assertEqual(self.fresh("--ref", head).returncode, 0)
        self.repo.write(f"{SETTINGS_SOURCES}/Alpha.swift", "// alpha, edited\n")
        stale = self.repo.commit("stale", snapshot=False)
        result = self.fresh("--ref", stale)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Alpha.swift", result.stdout)

    # The base autofix regenerates the exports after each merge, and with merges minutes apart
    # feat-cmux-next's stamp is stale most of the time (10-21: d986b175b38, #22678 and #23028 left
    # it stale for every pull request at once). A head answers only for the sources it changed.

    def stale_base(self):
        self.repo.write(f"{SETTINGS_SOURCES}/Beta.swift", "// beta, merged without its exports\n")
        return self.repo.commit("a merge before the base autofix", snapshot=False)

    def test_check_stamp_with_a_base_passes_a_head_that_inherits_the_bases_stale_exports(self):
        base = self.stale_base()
        self.repo.write("README.md", "an unrelated change\n")
        head = self.repo.commit("head", snapshot=False)
        result = self.repo.guard("check-stamp", "--ref", head, "--base", base)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("Beta.swift", result.stdout)
        self.assertIn(f"stale on the base {base[:12]} too", result.stdout)

    def test_check_stamp_with_a_base_fails_for_the_sources_the_head_changed(self):
        base = self.stale_base()
        self.repo.write(f"{SETTINGS_SOURCES}/Alpha.swift", "// alpha, edited on the head\n")
        head = self.repo.commit("head", snapshot=False)
        result = self.repo.guard("check-stamp", "--ref", head, "--base", base)
        self.assertEqual(result.returncode, 1, result.stdout)
        problems = result.stdout.split(f"stale on the base {base[:12]} too")[0]
        self.assertIn("Alpha.swift", problems)
        self.assertNotIn("Beta.swift", problems)

    def test_check_stamp_with_a_base_fails_a_head_that_changed_the_stamp_itself(self):
        """Taking the old side of the stamp in a base merge is the head's own staleness, not the base's."""
        base = self.repo.git("rev-parse", "HEAD")
        stamp = self.repo.root.joinpath(STAMP).read_text()
        digest = stamp.split("  ", 1)[0]
        self.repo.write(STAMP, stamp.replace(digest, "0" * len(digest), 1))
        head = self.repo.commit("head takes an old stamp", snapshot=False)
        result = self.repo.guard("check-stamp", "--ref", head, "--base", base)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertNotIn("stale on the base", result.stdout)

    def test_a_base_merge_that_keeps_the_branchs_stamp_is_named_as_the_pull_requests_red(self):
        """#22762 (10-21): the base changed and restamped Beta; a branch from before it changed Alpha.
        Merging the base locally with cmux-generated-v1 kept the branch's stamp, so Beta's digest went
        back to the old one. Beta is a base source and was fresh on the base, so the red read as the
        base's and the pull request merged with it, putting the old digest back on the base."""
        self.repo.write(".gitattributes", (ROOT / ".gitattributes").read_text(encoding="utf-8"))
        self.repo.commit("attributes", snapshot=False)
        self.repo.git("config", "merge.cmux-generated-v1.driver", "true")
        self.repo.git("checkout", "-q", "-b", "branch")
        self.repo.write(f"{SETTINGS_SOURCES}/Alpha.swift", "// alpha, edited on the branch\n")
        self.export()
        self.repo.commit("branch", snapshot=False)
        self.repo.git("checkout", "-q", "main")
        self.repo.write(f"{SETTINGS_SOURCES}/Beta.swift", "// beta, edited and restamped on the base\n")
        self.export()
        base = self.repo.commit("base moves on", snapshot=False)
        self.repo.git("checkout", "-q", "branch")
        self.repo.git("-c", "user.name=t", "-c", "user.email=t@t", "merge", "-q", "--no-edit", "main")
        head = self.repo.git("rev-parse", "HEAD")
        self.assertEqual(self.repo.guard("check-stamp", "--ref", base).returncode, 0, "the base is fresh")
        result = self.repo.guard("check-stamp", "--ref", head, "--base", base)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertNotIn("stale on the base", result.stdout)
        kept = result.stdout.split("this pull request's red, not the base's", 1)
        self.assertEqual(len(kept), 2, result.stdout)
        self.assertIn("Beta.swift", kept[1])
        self.assertIn("pr-autofix-patch", kept[1])

    def test_check_stamp_with_a_base_passes_however_many_sources_the_base_left_stale(self):
        for n in range(25):
            self.repo.write(f"{SETTINGS_SOURCES}/Merged{n:02}.swift", f"// merged {n} without its exports\n")
        base = self.repo.commit("many merges before the base autofix", snapshot=False)
        self.repo.write("README.md", "an unrelated change\n")
        head = self.repo.commit("head", snapshot=False)
        result = self.repo.guard("check-stamp", "--ref", head, "--base", base)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("and 5 more", result.stdout)

    def test_a_stale_stamp_says_how_to_regenerate_the_exports(self):
        """The old text pointed at a REPAIR.md row that is not in this repository."""
        self.repo.write(f"{SETTINGS_SOURCES}/Alpha.swift", "// alpha, edited\n")
        result = self.repo.guard("check-stamp")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("REPAIR.md", result.stdout)
        self.assertIn("cmux-next-pr-autofix.yml", result.stdout)
        self.assertIn("scripts/cmux-next/regenerate-settings-exports.sh", result.stdout)

    def test_source_stamp_prints_the_stamp_a_ref_s_sources_give(self):
        """base-autofix-push.sh lands settings exports past a settings-area move only when the tip's
        sources give the very stamp the exports carry; this is the stamp it compares."""
        head = self.repo.git("rev-parse", "HEAD")
        result = self.repo.guard("source-stamp", "--ref", head)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, self.repo.root.joinpath(STAMP).read_text())
        self.repo.write(f"{SETTINGS_SOURCES}/README.md", "still not an input\n")
        notes = self.repo.commit("a note beside the sources", snapshot=False)
        self.assertEqual(self.repo.guard("source-stamp", "--ref", notes).stdout, result.stdout)
        self.repo.write(f"{SETTINGS_SOURCES}/Beta.swift", "// beta, edited\n")
        edited = self.repo.commit("a source edit", snapshot=False)
        self.assertNotEqual(self.repo.guard("source-stamp", "--ref", edited).stdout, result.stdout)


if __name__ == "__main__":
    unittest.main()
