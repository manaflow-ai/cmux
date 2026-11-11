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
from unittest.mock import patch
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/defaults_guard.py"
RISK_TIER = ROOT / "scripts/ci/risk_tier.py"
AUTHOR = "teamleaderleo"
OWNERS = {"cmux-next": ["lawrencecchen", "austinywang", "teamleaderleo"]}
REVIEWER = "austinywang"  # a member account other than the author: a receipt from it keeps the rule from before Author-agent
PRIVATE_MEMBER = "hq-reviewer"  # a private org member with write access who is no call owner


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
        self.repo.write("scripts/ci/risk_tier.py", RISK_TIER.read_text(encoding="utf-8"))
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

    def check(self, head, reviews=(), author=AUTHOR, comments=(), body=""):
        pull = {"author": {"login": author}, "body": body, "headRefOid": head, "merged": False,
                "reviews": {"nodes": [{"author": {"login": who}, "state": state, "commit": {"oid": oid}}
                                      for who, state, oid in reviews]},
                "comments": {"nodes": [self.comment_node(n, item)
                                       for n, item in enumerate(comments)]}}
        path = self.repo.root.parent / f"{self.repo.root.name}-pull.json"
        path.write_text(json.dumps(pull), encoding="utf-8")
        summary = self.repo.root.parent / f"{self.repo.root.name}-summary.md"
        summary.write_text("", encoding="utf-8")
        result = self.repo.guard("check", "--base", self.base, "--head", head, "--pull-json", str(path),
                                 env={"GITHUB_STEP_SUMMARY": str(summary)})
        result.summary = summary.read_text(encoding="utf-8")
        return result

    @staticmethod
    def comment_node(number, item):
        body, at, association, kind = item[:4]
        login = item[4] if len(item) > 4 else AUTHOR
        node_id = item[5] if len(item) > 5 else None
        author = {"login": login, "__typename": kind}
        if node_id is not None:
            author["id"] = node_id
        return {"databaseId": number, "body": body, "createdAt": at,
                "authorAssociation": association, "author": author}

    # The cases that just bit us.

    def test_a_checkout_without_the_comment_writer_keeps_the_verdict(self):
        # The pull_request_target workflow runs from main, whose sparse checkout listed no
        # pr_status.py after #28451, so every pull request failed on ModuleNotFoundError.
        head = self.head(extra={"README.md": "no default changes\n"})
        path = self.repo.root.parent / f"{self.repo.root.name}-pull.json"
        path.write_text(json.dumps({"author": {"login": AUTHOR}, "headRefOid": head, "merged": False,
                                    "reviews": {"nodes": []}, "comments": {"nodes": []}}), encoding="utf-8")
        result = self.repo.guard("check", "--base", self.base, "--head", head, "--pull-json", str(path),
                                 "--repo", "o/r", "--pr", "1", "--comment")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("::warning title=Defaults comment not posted::", result.stdout)

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

    def test_tunable_default_changes_are_snapshotted_and_reported(self):
        path = "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/DevSurface.swift"
        source = '''public struct DevSurface {
    // Tunable<Bool>.toggle("commented.out", .status, "Commented", help: "no", default: true)
    /* Tunable<Bool>.toggle("also.commented", .status, "Commented", help: "no", default: true) */
    public static let enabled = Tunable<Bool>.toggle(
        "dev.surface", .status, "Developer surface", help: "opt-in",
        // Keep the default argument visible despite this comment.
        default: false)
    public static let label = Tunable<String>.choice(
        "dev.label", .status, "Developer label", help: "opt-in",
        default: "two  spaces")
}
'''
        self.repo.write(path, source)
        self.base = self.repo.commit("tunable base")
        head = self.head(extra={path: source.replace("default: false", "default: true")})
        result = self.check(head)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("DEFAULTS tunable.dev.surface: false -> true", result.stdout)
        self.assertNotIn("commented.out", result.stdout)
        self.assertNotIn("also.commented", result.stdout)
        snapshot = self.repo.guard("snapshot").stdout + self.repo.root.joinpath(
            "schemas/defaults/cmux-next.json").read_text()
        self.assertIn("tunable.dev.label", snapshot)
        self.assertIn('"two  spaces"', snapshot)

    def test_tunable_helper_and_symbol_dependencies_cannot_bypass_review(self):
        path = "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/DevTunables.swift"
        dependency = "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Material.swift"
        source = r'''enum DevTunables {
    static let devDefault = false
    static let enabled = Tunable<Bool>.toggle("dev.enabled", .status, "Dev", default: devDefault)
    static func points(_ name: String, _ value: Double) -> Tunable<Double> {
        .number("dev.\(name)", .status, name, default: value)
    }
    static let gap = points("gap", 2)
    static let opacity = Tunable<Double>.number("dev.opacity", .status, "Opacity", default: Material.opacity)
    static let values = [1, 2]
    static let dynamic = values.map { value in
        Tunable.number("dev.\(value)", .status, "Value", default: value)
    }
    static func unrelated() { print("before") }
}
'''
        material = 'enum Material { static let opacity = 0.5 }\n'
        self.repo.write(path, source)
        self.repo.write(dependency, material)
        self.base = self.repo.commit("tunable dependencies")
        for title, changed, other, expected in (
            ("symbol", source.replace("devDefault = false", "devDefault = true"), material, "DevTunables.swift:devDefault"),
            ("helper", source.replace('points("gap", 2)', 'points("gap", 3)'), material, "DevTunables.swift:gap"),
            ("helper body", source.replace("default: value)", "default: value + 1)"), material, "DevTunables.swift:points"),
            ("dynamic", source.replace("values = [1, 2]", "values = [1, 3]"), material, "DevTunables.swift:values"),
            ("external symbol", source, material.replace("0.5", "0.6"), "Material.swift:opacity"),
        ):
            with self.subTest(title=title):
                head = self.head(extra={path: changed, dependency: other})
                result = self.check(head)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("DEFAULTS tunable-source.CmuxNextDesign/" + expected, result.stdout)
        head = self.head(extra={path: source.replace('print("before")', 'print("after")')
                               .replace("static let devDefault", "/* comment */ static   let devDefault"),
                               dependency: material})
        result = self.check(head)
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_backticked_static_default_dependency_is_snapshotted(self):
        path = "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/DevTunables.swift"
        source = """enum DevTunables {
    static let enabled = Tunable<Bool>.toggle("dev.enabled", .status, "Dev", default: BrowserResize.default)
}
enum BrowserResize { static let `default` = true }
"""
        self.repo.write(path, source)
        self.base = self.repo.commit("backticked dependency")
        head = self.head(extra={path: source.replace("= true", "= false")})
        result = self.check(head)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("DEFAULTS tunable-source.CmuxNextDesign/DevTunables.swift:default", result.stdout)

    def test_cross_file_helper_and_continued_expression_are_snapshotted(self):
        helper = "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Factory.swift"
        caller = "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Surface.swift"
        helper_source = """enum Factory {
    static func number(_ value: Double) -> Tunable<Double> { .number("factory.value", .status, "Value", default: value) }
}
"""
        caller_source = """enum Surface {
    static let gap = Factory.number(2.0)
    static let defaultGap = 2.0
        * 3.0
    static let size = Tunable<Double>.number("surface.size", .status, "Size", default: defaultGap)
}
"""
        self.repo.write(helper, helper_source)
        self.repo.write(caller, caller_source)
        self.base = self.repo.commit("cross-file and continued defaults")
        for changed, expected in (
            (caller_source.replace("Factory.number(2.0)", "Factory.number(4.0)"), "gap"),
            (caller_source.replace("* 3.0", "* 4.0"), "defaultGap"),
        ):
            with self.subTest(expected=expected):
                head = self.head(extra={caller: changed})
                result = self.check(head)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("DEFAULTS tunable-source.CmuxNextDesign/Surface.swift:" + expected, result.stdout)

    def test_a_member_that_only_shares_a_helpers_name_is_not_a_tunable_source(self):
        # #32983 and #32979: `toggle` and `make` are Tunable helpers, so every declaration with a token of that name
        # (`model.toggle()`, a closure named `make`) was fingerprinted, and through them every `static func bind`:
        # 6182 tunable-source entries, and almost every app pull request "changed a default".
        tunables = "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/DropTunables.swift"
        handlers = "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Handlers.swift"
        tunables_source = """enum DropTunables {
    private static func toggle(_ name: String, _ value: Bool) -> Tunable<Bool> { .toggle(name, .status, name, default: value) }
    static let animated = toggle("animated", true)
}
enum MetricTunable {
    static func make(_ name: String, _ value: Double) -> Tunable<Double> { .number(name, .status, name, default: value) }
}
"""
        handlers_source = """enum AppActions {
    static func bindApp(_ registry: Registry) {
        registry.bind("toggleSidebar") { services.sidebar.model.toggle() }
        OnboardingHandlers.bind(registry)
    }
}
enum OnboardingHandlers {
    static func bind(_ registry: Registry) {
        for (id, make) in pages { registry.bind(id) { make(services) } }
        print("before")
    }
}
"""
        self.repo.write(tunables, tunables_source)
        self.repo.write(handlers, handlers_source)
        self.base = self.repo.commit("name collisions")
        head = self.head(extra={tunables: tunables_source, handlers: handlers_source.replace('"before"', '"after"')})
        result = self.check(head)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("tunable-source.CmuxNextApp", result.stdout)
        head = self.head(extra={tunables: tunables_source.replace('toggle("animated", true)', 'toggle("animated", false)'),
                                handlers: handlers_source})
        result = self.check(head)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("DEFAULTS tunable-source.CmuxNextDesign/DropTunables.swift:animated", result.stdout)

    def test_a_helper_called_from_an_extension_or_by_its_type_is_still_a_tunable_source(self):
        helper = "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Chrome.swift"
        extension = "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Chrome+Tabs.swift"
        caller = "Packages/macOS/CmuxNext/Sources/CmuxNextTabs/Sizes.swift"
        helper_source = """enum Chrome {
    static func points(_ name: String, _ value: Double) -> Tunable<Double> { .number(name, .status, name, default: value) }
}
"""
        extension_source = "extension Chrome {\n    static let tabGap = points(\"tabGap\", 2)\n}\n"
        caller_source = "enum Sizes {\n    static let rowGap = Chrome.points(\"rowGap\", 4)\n}\n"
        self.repo.write(helper, helper_source)
        self.repo.write(extension, extension_source)
        self.repo.write(caller, caller_source)
        self.base = self.repo.commit("helper callers")
        for path, changed, expected in (
            (extension, extension_source.replace("2)", "3)"), "CmuxNextDesign/Chrome+Tabs.swift:tabGap"),
            (caller, caller_source.replace("4)", "5)"), "CmuxNextTabs/Sizes.swift:rowGap"),
        ):
            with self.subTest(expected=expected):
                files = {helper: helper_source, extension: extension_source, caller: caller_source, path: changed}
                result = self.check(self.head(extra=files))
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("DEFAULTS tunable-source." + expected, result.stdout)

    def test_self_typealias_subclass_and_protocol_helper_calls_are_tunable_sources(self):
        # Review of #33161: these reach a Tunable (or its helper) with no Tunable token and no `Type.helper` of a
        # type declared in the helper's file. The guard caught each before #33161 and must still.
        base_files = {
            "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Chrome.swift": """enum Chrome {
    static func points(_ name: String, _ value: Double) -> Tunable<Double> { .number(name, .status, name, default: value) }
    static let viaSelf = Self.points("viaSelf", 1)
}
""",
            "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Alias.swift": """typealias TD = Tunable<Double>
enum Alias {
    static let qualified = TD.number("qualified", .status, "Q", default: 1)
    static let implicit: TD = .number("implicit", .status, "I", default: 1)
}
""",
            "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Base.swift": """class BaseTunables {
    static func gap(_ name: String, _ value: Double) -> Tunable<Double> { .number(name, .status, name, default: value) }
}
protocol TunableFactory {}
extension TunableFactory {
    static func flag(_ name: String, _ value: Bool) -> Tunable<Bool> { .toggle(name, .status, name, default: value) }
}
""",
            "Packages/macOS/CmuxNext/Sources/CmuxNextTabs/Sub.swift": """final class SubTunables: BaseTunables {
    static let inherited = gap("inherited", 1)
    static let qualified = SubTunables.gap("subQualified", 1)
}
struct Flags: TunableFactory {
    static let conformed = flag("conformed", true)
}
""",
        }
        for path, text in base_files.items():
            self.repo.write(path, text)
        self.base = self.repo.commit("reachable helper forms")
        for path, old, new, expected in (
            ("CmuxNextDesign/Chrome.swift", '"viaSelf", 1', '"viaSelf", 2', "Chrome.swift:viaSelf"),
            ("CmuxNextDesign/Alias.swift", 'default: 1)\n    static let implicit', 'default: 2)\n    static let implicit',
             "Alias.swift:qualified"),
            ("CmuxNextDesign/Alias.swift", '"I", default: 1', '"I", default: 2', "Alias.swift:implicit"),
            ("CmuxNextTabs/Sub.swift", '"inherited", 1', '"inherited", 2', "Sub.swift:inherited"),
            ("CmuxNextTabs/Sub.swift", '"subQualified", 1', '"subQualified", 2', "Sub.swift:qualified"),
            ("CmuxNextTabs/Sub.swift", '"conformed", true', '"conformed", false', "Sub.swift:conformed"),
        ):
            with self.subTest(expected=expected):
                full = "Packages/macOS/CmuxNext/Sources/" + path
                files = dict(base_files)
                files[full] = files[full].replace(old, new)
                self.assertNotEqual(files[full], base_files[full], expected)
                result = self.check(self.head(extra=files))
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("DEFAULTS tunable-source." + path.split("/")[0] + "/" + expected, result.stdout)

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

    def test_a_default_that_steps_aside_in_the_rust_catalog_fails(self):
        rust = "pub static YIELDS_TO_TERMINAL: &[&str] = &[\n    \"focusHistoryBack\",\n];\n"
        self.repo.write("cmux-tui/crates/cmux-action-catalog/src/bindings.rs", rust)
        self.base = self.repo.commit("steps aside in Rust")
        head = self.head(extra={"cmux-tui/crates/cmux-action-catalog/src/bindings.rs":
                                rust.replace("];", '    "splitRight",\n];')})
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

    def receipt(self, text, at="2026-10-21T10:00:00Z", association="MEMBER", kind="User",
                login=REVIEWER, node_id=None):
        return (text, at, association, kind, login, node_id)

    def test_a_ship_receipt_on_the_head_passes_without_a_teammate(self):
        head = self.changed_head()
        result = self.check(head, comments=[self.receipt(f"Review (subagent, correctness first): SHIP at {head}\n\nok")])
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("Signed off on this commit by `review (subagent, correctness first)`", result.summary)

    def test_a_ship_receipt_posted_as_a_review_body_passes(self):
        head = self.changed_head()
        # From the author's own account, so it names the reviewer agent and its starter (risk_tier.py).
        pull = {"author": {"login": AUTHOR}, "body": "Author-agent: claude-author", "headRefOid": head,
                "merged": False, "comments": {"nodes": []},
                "reviews": {"nodes": [{"author": {"login": AUTHOR, "__typename": "User"}, "authorAssociation": "MEMBER",
                                       "state": "COMMENTED", "submittedAt": "2026-10-21T10:00:00Z",
                                       "body": f"Review (subagent, started by lead): SHIP at {head}",
                                       "commit": {"oid": head}}]}}
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
                        self.receipt(f"Review (subagent): SHIP at {head}", association="CONTRIBUTOR",
                                     login="outsider"),
                        self.receipt(f"Review (subagent): SHIP at {head}", kind="Bot")):
            self.assertEqual(self.check(head, comments=[receipt]).returncode, 1, receipt)

    # cmux-ad m25 item 7: a SHIP from the author's own account names its reviewer agent and who started it, neither
    # of them the description's `Author-agent:` (risk_tier.py). #36311: the author agent's own subagent posted
    # `Review (claude-review-subagent): SHIP at ...` from the author's account and the guard read it as independent.

    def same_account(self, head, text, body="Author-agent: claude-author", extra=()):
        return self.check(head, body=body, comments=[self.receipt(text, login=AUTHOR), *extra])

    def test_the_author_agent_as_its_own_reviewer_is_refused(self):
        head = self.changed_head()
        for text in (f"Review (claude-author, started by lead): SHIP at {head}",
                     f"Review (claude-review-subagent): SHIP at {head}"):
            result = self.same_account(head, text)
            self.assertEqual(result.returncode, 1, text)
            self.assertIn("Needs a review", result.summary)

    def test_a_reviewer_the_author_agent_started_is_refused(self):
        head = self.changed_head()
        result = self.same_account(head, f"Review (claude-review-subagent, started by claude-author): SHIP at {head}")
        self.assertEqual(result.returncode, 1, result.stdout)

    def test_an_independent_agent_the_lead_started_counts(self):
        head = self.changed_head()
        result = self.same_account(head, f"Review (codex-reviewer-7, started by lead): SHIP at {head}")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("Signed off on this commit by `review (codex-reviewer-7, started by lead)`", result.summary)
        refused = self.same_account(head, f"Review (codex-reviewer-7, started by claude-author): SHIP at {head}")
        self.assertEqual(refused.returncode, 1, refused.stdout)

    def test_a_same_account_ship_without_an_author_agent_line_is_refused_and_a_block_still_holds(self):
        head = self.changed_head()
        result = self.same_account(head, f"Review (codex-reviewer-7, started by lead): SHIP at {head}", body="no agent")
        self.assertEqual(result.returncode, 1, result.stdout)
        ship = self.receipt(f"Review (codex): SHIP at {head}", at="2026-10-21T09:00:00Z")
        blocked = self.same_account(head, f"Review (claude-review-subagent): BLOCK at {head}", body="no agent",
                                    extra=[ship])
        self.assertEqual(blocked.returncode, 1, blocked.stdout)
        self.assertIn("BLOCK from `review (claude-review-subagent)`", blocked.summary)

    def test_a_receipt_from_another_account_keeps_the_old_rule(self):
        head = self.changed_head()
        line = f"Review (claude-review-subagent): SHIP at {head}"
        other = self.check(head, body="Author-agent: claude-author", comments=[self.receipt(line)])
        self.assertEqual(other.returncode, 0, other.stdout)
        self.assertEqual(self.same_account(head, line).returncode, 1)

    # A SHIP carried across base merges (2026-11-02: #30961, #31798, #27745 waited on a SHIP one base merge back).

    def merged_base(self, pr_head, base_settings=None, extra_merge=None):
        """The base moves on (another default of its own, a file the pull request does not touch) and is merged into
        `pr_head`, as autoland's update-branch does; `extra_merge` edits the merge commit itself. The trusted
        checkout is the new base tip. Returns (new base, merge head)."""
        self.repo.git("checkout", "-q", self.base)
        self.repo.sources(BASE_ACTIONS, base_settings or [{"key": "terminal.showJumpToBottomButton", "default": True},
                                                          BASE_SETTINGS[1]])
        self.repo.write("README.md", "base moved\n")
        tip = self.repo.commit("base moves", snapshot=False)
        self.repo.git("checkout", "-q", pr_head)
        self.repo.git("-c", "user.name=t", "-c", "user.email=t@t", "merge", "-q", "--no-commit", "-X", "theirs", tip)
        # the settings export comes from both sides: the base's new default and the pull request's own
        self.repo.sources(BASE_ACTIONS, [{"key": "terminal.showJumpToBottomButton", "default": True},
                                         {"key": "sidebar.numbering", "default": "workspacesOnly"}])
        for path, text in (extra_merge or {}).items():
            self.repo.write(path, text)
        self.repo.git("add", "-A")
        self.repo.git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--no-edit", "-m", "merge base")
        merge = self.repo.git("rev-parse", "HEAD")
        self.repo.git("checkout", "-q", tip)
        return tip, merge

    def check_at(self, base, head, comments):
        self.base = base
        return self.check(head, comments=comments)

    def test_a_ship_one_base_merge_back_is_carried(self):
        reviewed = self.changed_head()
        tip, merge = self.merged_base(reviewed)
        result = self.check_at(tip, merge, [self.receipt(f"Review (subagent): SHIP at {reviewed}")])
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn(f"carried from {reviewed[:12]} across base merges", result.summary)

    def test_a_merge_that_changes_the_pull_requests_defaults_carries_nothing(self):
        reviewed = self.changed_head()
        flags = "enum PaneSplitCommand {\n    static let optimisticSplitEnabled = true\n}\n"
        tip, merge = self.merged_base(reviewed, extra_merge={
            "Packages/macOS/CmuxNext/Sources/CmuxNextApp/PaneSplitCommand.swift": flags})
        result = self.check_at(tip, merge, [self.receipt(f"Review (subagent): SHIP at {reviewed}")])
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("not carried", result.stdout)

    def test_a_commit_of_its_own_after_the_ship_carries_nothing(self):
        reviewed = self.changed_head()
        tip, merge = self.merged_base(reviewed)
        self.repo.git("checkout", "-q", merge)
        self.repo.write("NOTES.md", "a change of its own\n")
        self.repo.git("add", "-A")
        self.repo.git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "own")
        own = self.repo.git("rev-parse", "HEAD")
        self.repo.git("checkout", "-q", tip)
        result = self.check_at(tip, own, [self.receipt(f"Review (subagent): SHIP at {reviewed}")])
        self.assertEqual(result.returncode, 1, result.stdout)

    def test_a_block_at_the_head_or_at_the_earlier_head_is_never_carried_over(self):
        reviewed = self.changed_head()
        tip, merge = self.merged_base(reviewed)
        blocked_now = self.check_at(tip, merge, [
            self.receipt(f"Review (subagent): SHIP at {reviewed}", at="2026-10-21T10:00:00Z"),
            self.receipt(f"Review (second): BLOCK at {merge}", at="2026-10-21T11:00:00Z")])
        self.assertEqual(blocked_now.returncode, 1, blocked_now.stdout)
        blocked_then = self.check_at(tip, merge, [
            self.receipt(f"Review (subagent): SHIP at {reviewed}", at="2026-10-21T10:00:00Z"),
            self.receipt(f"Review (second): BLOCK at {reviewed}", at="2026-10-21T11:00:00Z")])
        self.assertEqual(blocked_then.returncode, 1, blocked_then.stdout)

    def test_the_cmux_bot_ship_receipt_at_the_head_passes(self):
        head = self.changed_head()
        receipt = self.receipt(f"Review (codex gpt-6-astra high, next-review): SHIP at {head}",
                               kind="Bot", login="cmux-bot[bot]", node_id="BOT_kgDOFMYsLQ")
        result = self.check(head, comments=[receipt])
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_needs_a_review_ends_with_the_one_review_request_command(self):
        # #38430: the author lane's own router-review receipt (`started by` its Author-agent) was refused, and the
        # comment named no way to get one it could run. The plain form now ends with that command.
        head = self.changed_head()
        result = self.same_account(head, f"Review (codex, router-review, started by claude-author): SHIP at {head}")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Needs a review", result.summary)
        self.assertEqual(result.summary.strip().splitlines()[-1], "next: router-review OWNER/REPO N --request")
        self.assertIn("next: router-review OWNER/REPO N --request", result.stdout)
        # The service's receipt, which cmux-bot posts, passes the same head and prints no next line.
        service = self.receipt(f"Review (codex gpt-6.1-sol xhigh, next-review): SHIP at {head}",
                               kind="Bot", login="cmux-bot[bot]", node_id="BOT_kgDOFMYsLQ")
        passed = self.check(head, body="Author-agent: claude-author", comments=[service])
        self.assertEqual(passed.returncode, 0, passed.stdout)
        self.assertNotIn("next:", passed.summary)

    def test_a_cmux_bot_approval_body_never_counts_but_its_plain_review_does(self):
        head = self.changed_head()
        line = f"Review (codex gpt-6.1-sol xhigh, next-review): SHIP at {head}"
        for state, code in (("APPROVED", 1), ("COMMENTED", 0)):
            pull = {"author": {"login": AUTHOR}, "body": "Author-agent: claude-author", "headRefOid": head,
                    "merged": False, "comments": {"nodes": []},
                    "reviews": {"nodes": [{"author": {"login": "cmux-bot", "__typename": "Bot", "id": "BOT_kgDOFMYsLQ"},
                                           "authorAssociation": "NONE", "state": state,
                                           "submittedAt": "2026-10-21T10:00:00Z", "body": line,
                                           "commit": {"oid": head}}]}}
            path = self.repo.root.parent / f"{self.repo.root.name}-bot-review-{state}.json"
            path.write_text(json.dumps(pull), encoding="utf-8")
            result = self.repo.guard("check", "--base", self.base, "--head", head, "--pull-json", str(path))
            self.assertEqual(result.returncode, code, (state, result.stdout))

    def test_a_block_says_push_a_fix_before_a_new_request(self):
        head = self.changed_head()
        result = self.check(head, comments=[self.receipt(f"Review (subagent): BLOCK at {head}")])
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertTrue(result.summary.strip().splitlines()[-1].startswith("next: none (address the BLOCK and push"))

    def test_the_cmux_bot_receipt_at_an_old_head_fails(self):
        head = self.changed_head()
        receipt = self.receipt(f"Review (codex gpt-6-astra high, next-review): SHIP at {self.base}",
                               kind="Bot", login="cmux-bot[bot]", node_id="BOT_kgDOFMYsLQ")
        result = self.check(head, comments=[receipt])
        self.assertEqual(result.returncode, 1, result.stdout)

    def test_a_bot_with_the_right_login_but_wrong_node_id_fails(self):
        head = self.changed_head()
        receipt = self.receipt(f"Review (codex gpt-6-astra high, next-review): SHIP at {head}",
                               kind="Bot", login="cmux-bot[bot]", node_id="BOT_wrong")
        self.assertEqual(self.check(head, comments=[receipt]).returncode, 1)

    def test_a_later_cmux_bot_block_beats_an_earlier_ship(self):
        head = self.changed_head()
        ship = self.receipt(f"Review (codex gpt-6-astra high, next-review): SHIP at {head}",
                            at="2026-10-21T10:00:00Z", kind="Bot", login="cmux-bot[bot]",
                            node_id="BOT_kgDOFMYsLQ")
        block = self.receipt(f"Review (codex gpt-6-astra high, next-review): BLOCK at {head}",
                             at="2026-10-21T11:00:00Z", kind="Bot", login="cmux-bot[bot]",
                             node_id="BOT_kgDOFMYsLQ")
        result = self.check(head, comments=[ship, block])
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("BLOCK", result.summary)

    def test_a_user_with_the_bot_login_or_node_id_does_not_pass(self):
        head = self.changed_head()
        for login, node_id in (("cmux-bot[bot]", "BOT_kgDOFMYsLQ"), ("trusted-user", "BOT_kgDOFMYsLQ"),
                               ("cmux-bot[bot]", "BOT_wrong")):
            receipt = self.receipt(f"Review (codex gpt-6-astra high, next-review): SHIP at {head}",
                                   kind="User", login=login, node_id=node_id,
                                   association="CONTRIBUTOR")
            self.assertEqual(self.check(head, comments=[receipt]).returncode, 1,
                             (login, node_id))

    def private_member_check(self, head, roles, body=None, extra_comments=(), login=PRIVATE_MEMBER):
        """A receipt from a member whose org membership is private: the workflow's token sees
        CONTRIBUTOR (cmux#26153). `roles` is what a fake `gh` answers for the permission lookup;
        "RATE_LIMIT" answers as GitHub does when the installation's REST quota is spent."""
        bin_dir = self.repo.root.parent / f"{self.repo.root.name}-bin"
        bin_dir.mkdir(exist_ok=True)
        calls = bin_dir / "calls"
        fake = bin_dir / "gh"
        fake.write_text("#!/usr/bin/env python3\n"
                        "import json, sys\n"
                        f"roles = json.loads({json.dumps(json.dumps(roles))})\n"
                        f"open({str(calls)!r}, 'a').write(' '.join(sys.argv[1:]) + '\\n')\n"
                        "login = sys.argv[2].split('/')[-2]\n"
                        "if login not in roles:\n"
                        "    sys.stderr.write('HTTP 404: Not Found\\n'); sys.exit(1)\n"
                        "if roles[login] == 'RATE_LIMIT':\n"
                        "    sys.stderr.write('gh: API rate limit exceeded for installation. (HTTP 403)\\n'); sys.exit(1)\n"
                        "print(roles[login])\n", encoding="utf-8")
        fake.chmod(0o755)
        body = body or f"Review (Claude Opus 5.5 subagent, correctness): SHIP at {head}\n\nFollow-up review"
        nodes = [{"databaseId": 6483350726, "body": body, "createdAt": "2026-10-28T23:25:01Z",
                  "authorAssociation": "CONTRIBUTOR", "author": {"login": login, "__typename": "User"}}]
        nodes += list(extra_comments)
        pull = {"author": {"login": AUTHOR}, "headRefOid": head, "merged": False,
                "reviews": {"nodes": []}, "comments": {"nodes": nodes}}
        path = self.repo.root.parent / f"{self.repo.root.name}-private-pull.json"
        path.write_text(json.dumps(pull), encoding="utf-8")
        result = self.repo.guard("check", "--base", self.base, "--head", head, "--pull-json", str(path),
                                 "--repo", "manaflow-ai/cmux",
                                 env=git_fixture_env.fixture_env({"PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}"}))
        result.calls = calls.read_text(encoding="utf-8").splitlines() if calls.exists() else []
        return result

    def test_a_private_org_member_with_write_access_ships_the_head(self):
        head = self.changed_head()
        result = self.private_member_check(head, {PRIVATE_MEMBER: "admin"})
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.calls, [f"api repos/manaflow-ai/cmux/collaborators/{PRIVATE_MEMBER}/permission --jq .role_name"])

    def test_a_call_owners_receipt_ships_with_the_rest_quota_spent(self):
        # #32983 (2026-11-03): "Review (independent-subagent): SHIP at 8af92c61..." by lawrencecchen, a call
        # owner whose org membership is private, read as CONTRIBUTOR to the workflow's token; the write-access
        # lookup got "API rate limit exceeded for installation", so the guard trusted nobody and stayed red on
        # one tunable-source hash. The owners file is the base's, so an owner's receipt needs no lookup.
        head = self.changed_head()
        result = self.private_member_check(
            head, {"lawrencecchen": "RATE_LIMIT"}, login="lawrencecchen",
            body=f"Review (independent-subagent): SHIP at {head}\n\nIndependent review subagent, correctness first.")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.calls, [])

    def test_a_call_owners_block_still_beats_their_ship(self):
        head = self.changed_head()
        ship = {"databaseId": 1, "body": f"Review (subagent): SHIP at {head}", "createdAt": "2026-10-28T20:00:00Z",
                "authorAssociation": "CONTRIBUTOR", "author": {"login": "lawrencecchen", "__typename": "User"}}
        result = self.private_member_check(head, {}, login="lawrencecchen",
                                           body=f"Review (second): BLOCK at {head}", extra_comments=[ship])
        self.assertEqual(result.returncode, 1, result.stdout)

    def test_a_receipt_whose_lookup_failed_is_named_in_the_error(self):
        head = self.changed_head()
        result = self.private_member_check(head, {PRIVATE_MEMBER: "RATE_LIMIT"})
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(f"the receipt by {PRIVATE_MEMBER} was not checked", result.stdout)
        self.assertIn("API rate limit exceeded", result.stdout)

    def test_a_contributor_without_write_access_still_does_not_pass(self):
        head = self.changed_head()
        for roles in ({}, {PRIVATE_MEMBER: "read"}, {PRIVATE_MEMBER: "triage"}):
            result = self.private_member_check(head, roles)
            self.assertEqual(result.returncode, 1, (roles, result.stdout))

    def test_a_private_member_is_looked_up_only_for_a_receipt_on_the_head(self):
        head = self.changed_head()
        result = self.private_member_check(head, {PRIVATE_MEMBER: "admin"}, body=f"Review (subagent): SHIP at {self.base}")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertEqual(result.calls, [])

    def test_a_later_block_from_a_private_member_still_beats_a_ship(self):
        head = self.changed_head()
        ship = {"databaseId": 1, "body": f"Review (subagent): SHIP at {head}", "createdAt": "2026-10-28T20:00:00Z",
                "authorAssociation": "MEMBER", "author": {"login": AUTHOR, "__typename": "User"}}
        result = self.private_member_check(head, {PRIVATE_MEMBER: "write"},
                                           body=f"Review (subagent): BLOCK at {head}", extra_comments=[ship])
        self.assertEqual(result.returncode, 1, result.stdout)

    def test_an_unchecked_block_after_an_owners_ship_keeps_the_guard_red(self):
        # Review of #33111: a BLOCK whose author could not be looked up was dropped, so an owner's earlier SHIP passed.
        head = self.changed_head()
        ship = {"databaseId": 1, "body": f"Review (subagent): SHIP at {head}", "createdAt": "2026-10-28T20:00:00Z",
                "authorAssociation": "CONTRIBUTOR", "author": {"login": "lawrencecchen", "__typename": "User"}}
        result = self.private_member_check(head, {PRIVATE_MEMBER: "RATE_LIMIT"},
                                           body=f"Review (second): BLOCK at {head}", extra_comments=[ship])
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(f"the receipt by {PRIVATE_MEMBER} was not checked", result.stdout)

    def test_an_unchecked_ship_still_does_not_pass(self):
        head = self.changed_head()
        result = self.private_member_check(head, {PRIVATE_MEMBER: "RATE_LIMIT"})
        self.assertEqual(result.returncode, 1, result.stdout)

    def test_an_unchecked_receipt_one_base_merge_back_is_named_in_the_error(self):
        # Review of #33111: a failed lookup at the earlier head of a carried SHIP gave only a warning.
        reviewed = self.changed_head()
        tip, merge = self.merged_base(reviewed)
        self.base = tip
        result = self.private_member_check(merge, {PRIVATE_MEMBER: "RATE_LIMIT"},
                                           body=f"Review (subagent): SHIP at {reviewed}")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(f"the receipt by {PRIVATE_MEMBER} was not checked", result.stdout)

    def carried_private_check(self, body, extra_comments=()):
        """private_member_check's pull request one base merge after `reviewed`, with the receipts at `reviewed`."""
        reviewed = self.changed_head()
        tip, merge = self.merged_base(reviewed)
        self.base = tip
        return self.private_member_check(merge, {PRIVATE_MEMBER: "write"}, body=body.format(reviewed=reviewed),
                                         extra_comments=[dict(c, body=c["body"].format(reviewed=reviewed))
                                                         for c in extra_comments])

    def test_a_private_members_ship_one_base_merge_back_is_carried(self):
        result = self.carried_private_check("Review (subagent): SHIP at {reviewed}")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(len(result.calls), 1, result.calls)

    def test_a_private_members_block_one_base_merge_back_still_beats_a_ship(self):
        ship = {"databaseId": 1, "body": "Review (subagent): SHIP at {reviewed}", "createdAt": "2026-10-28T20:00:00Z",
                "authorAssociation": "MEMBER", "author": {"login": AUTHOR, "__typename": "User"}}
        result = self.carried_private_check("Review (subagent): BLOCK at {reviewed}", extra_comments=[ship])
        self.assertEqual(result.returncode, 1, result.stdout)

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
def stamp_for(root):
    """The source stamp: one `sha256  path` entry per exporter input, in UTF-8 path order, a blank
    line between entries."""
    import hashlib
    paths = [f"{EXPORTER_TESTS}/ManagedPreferencesManifestTests.swift", f"{EXPORTER_TESTS}/SettingsSchemaExportTests.swift"]
    paths += [file.relative_to(root).as_posix() for file in (root / SETTINGS_SOURCES).rglob("*")
              if file.suffix in (".swift", ".xcstrings")]
    paths.sort(key=lambda path: path.encode("utf-8"))
    return "\n\n".join(f"{hashlib.sha256((root / path).read_bytes()).hexdigest()}  {path}" for path in paths) + "\n"


class SettingsSourceStampTests(unittest.TestCase):
    """`source-stamp`: the settings exports' source stamp, derived for any commit and never
    committed (Leo 2026-10-21). A committed copy changed in every pull request that touched a
    settings source and conflicted on nearly every base move (#22674)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(pathlib.Path(self.tmp.name))
        self.repo.git("init", "-q", "-b", "main")
        self.repo.write("scripts/ci/defaults_guard.py", SCRIPT.read_text(encoding="utf-8"))
        self.repo.write(".github/defaults-call-owners.json", json.dumps(OWNERS))
        self.repo.sources(BASE_ACTIONS, BASE_SETTINGS)
        self.repo.write(f"{EXPORTER_TESTS}/ManagedPreferencesManifestTests.swift", "// manifest\n")
        self.repo.write(f"{EXPORTER_TESTS}/SettingsSchemaExportTests.swift", "// schema export\n")
        for name in ("Alpha.swift", "Beta.swift", "Gamma.swift", "Localizable.xcstrings"):
            self.repo.write(f"{SETTINGS_SOURCES}/{name}", f"// {name}\n")
        self.repo.write(f"{SETTINGS_SOURCES}/README.md", "not an input\n")
        self.repo.commit("base")

    def tearDown(self):
        self.tmp.cleanup()

    def test_source_stamp_has_one_entry_per_exporter_input(self):
        result = self.repo.guard("source-stamp")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, stamp_for(self.repo.root))
        self.assertEqual(len(result.stdout.split("\n\n")), 6)

    def test_source_stamp_prints_the_stamp_a_ref_s_sources_give(self):
        """base-autofix-push.sh lands settings exports past a settings-area move only when the tip's
        sources give the stamp of the commit the exports were made at; this is the stamp it compares."""
        head = self.repo.git("rev-parse", "HEAD")
        result = self.repo.guard("source-stamp", "--ref", head)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, stamp_for(self.repo.root))
        self.repo.write(f"{SETTINGS_SOURCES}/README.md", "still not an input\n")
        notes = self.repo.commit("a note beside the sources", snapshot=False)
        self.assertEqual(self.repo.guard("source-stamp", "--ref", notes).stdout, result.stdout)
        self.repo.write(f"{SETTINGS_SOURCES}/Beta.swift", "// beta, edited\n")
        edited = self.repo.commit("a source edit", snapshot=False)
        self.assertNotEqual(self.repo.guard("source-stamp", "--ref", edited).stdout, result.stdout)

    def test_check_fresh_reads_no_stamp(self):
        """The exports are checked against a fresh export (cmux-next.yml's generated files job), so a
        settings source edit is not check-fresh's to judge."""
        self.repo.write(f"{SETTINGS_SOURCES}/Alpha.swift", "// alpha, edited\n")
        result = self.repo.guard("check-fresh")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("stamp", result.stdout)

    def test_check_stamp_is_gone(self):
        self.assertEqual(self.repo.guard("check-stamp").returncode, 2)


class StatusCommentTests(unittest.TestCase):
    def setUp(self):
        sys.path.insert(0, str(ROOT / "scripts/ci"))
        import defaults_guard
        import pr_status
        self.guard, self.status = defaults_guard, pr_status
        self.comments, self.writes = [], []
        original = pr_status.upsert
        self.writer = patch.object(pr_status, "upsert", side_effect=lambda *a, **kw:
                                   original(*a, **kw, api=self.api, sleep=None))
        self.writer.start()
        self.addCleanup(self.writer.stop)
        self.addCleanup(sys.path.pop, 0)
        self.old = patch.object(defaults_guard, "gh", side_effect=AssertionError("standalone writer used"))
        self.old.start()
        self.addCleanup(self.old.stop)

    def api(self, method, path, payload=None):
        if method == "GET":
            return self.comments
        if getattr(self, "fail_write", False):
            raise RuntimeError("write failed")
        self.writes.append((method, path, payload))
        if method == "PATCH":
            next(c for c in self.comments if path.endswith('/' + str(c['id'])))['body'] = payload['body']
        elif method == "POST":
            self.comments.append(self.comment(100, payload['body']))
        elif method == "DELETE":
            self.comments[:] = [c for c in self.comments if not path.endswith('/' + str(c['id']))]

    def comment(self, number, body, author="github-actions[bot]"):
        return {"id": number, "body": body, "user": {"login": author}}

    def post(self, changed=True):
        # The legacy GraphQL snapshot may be truncated: the writer reads all comments.
        body = self.guard.MARKER + "\n## Default changes\n" + ("Needs review" if changed else "No default changes")
        with patch.object(self.status, "http_api", self.api):
            self.guard.post_comment("o/r", 1, {}, body, [object()] if changed else [])

    def test_changes_share_existing_status_and_unchanged_runs_write_nothing(self):
        self.comments = [self.comment(1, self.status.render({"review": "SHIP"}))]
        self.post()
        self.assertEqual([w[0] for w in self.writes], ["PATCH"])
        sections = self.status.parse(self.comments[0]['body'])
        self.assertEqual(sections['review'], 'SHIP')
        self.assertIn('Needs review', sections['defaults'])
        self.assertNotIn(self.guard.MARKER, sections['defaults'])
        self.writes.clear()
        self.post()
        self.assertEqual(self.writes, [])

    def test_no_changes_and_no_prior_defaults_are_silent(self):
        self.comments = [self.comment(1, self.status.render({"review": "SHIP"}))]
        self.post(False)
        self.assertEqual(self.writes, [])
        self.assertNotIn('defaults', self.status.parse(self.comments[0]['body']))

    def test_legacy_comment_migrates_in_place(self):
        self.comments = [self.comment(2, self.guard.MARKER + "\nold")]
        self.post()
        self.assertEqual([w[0] for w in self.writes], ['PATCH'])
        self.assertTrue(self.comments[0]['body'].startswith(self.status.MARKER))

    def test_resolved_defaults_update_the_existing_section(self):
        self.comments = [self.comment(1, self.status.render({"defaults": "Needs review", "review": "SHIP"}))]
        self.post(False)
        self.assertIn('No default changes', self.status.parse(self.comments[0]['body'])['defaults'])

    def test_failed_status_write_keeps_legacy_comment(self):
        self.comments = [self.comment(1, self.status.render({"review": "SHIP"})),
                         self.comment(2, self.guard.MARKER + "\nold")]
        self.fail_write = True
        with self.assertRaises(RuntimeError):
            self.post()
        self.assertEqual(len(self.comments), 2)

    def test_human_legacy_lookalike_is_not_changed(self):
        self.comments = [self.comment(2, self.guard.MARKER + "\nquoted", "person")]
        self.post(False)
        self.assertEqual(self.writes, [])


if __name__ == "__main__":
    unittest.main()
