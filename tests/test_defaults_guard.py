"""The defaults snapshot tool (scripts/ci/defaults_guard.py): what it reads as a default, the
snapshot it writes, `check-fresh` and the settings exports' source stamp.

Each test builds a small repository with the tool copied in, commits a base and a head, and compares
the defaults the tool reads from each tree (the trees are read with git as data).
"""

import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/defaults_guard.py"


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



def load_tool(root):
    """The tool copied into `root`, imported, so a test reads a tree's defaults as `snapshot` does."""
    spec = importlib.util.spec_from_file_location("defaults_guard_under_test", root / "scripts/ci/defaults_guard.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # its dataclasses look their module up while the file runs
    spec.loader.exec_module(module)
    return module


class Changed:
    def __init__(self, found):
        self.found = found
        self.returncode = 1 if found else 0
        self.stdout = "".join(c.line + "\n" for c in found)


class DefaultsSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Repo(pathlib.Path(self.tmp.name))
        self.repo.git("init", "-q")
        self.repo.write("scripts/ci/defaults_guard.py", SCRIPT.read_text(encoding="utf-8"))
        self.repo.sources(BASE_ACTIONS, BASE_SETTINGS)
        self.base = self.repo.commit("base")
        self.tool = load_tool(self.repo.root)

    def tearDown(self):
        self.tmp.cleanup()

    def head(self, actions=None, settings=None, keybinds=KEYBINDS, flags=FLAGS, snapshot=True, extra=None):
        self.repo.git("checkout", "-q", "-b", f"pr-{len(self.repo.git('branch').splitlines())}", self.base)
        self.repo.sources(actions or BASE_ACTIONS, settings or BASE_SETTINGS, keybinds, flags)
        for path, text in (extra or {}).items():
            self.repo.write(path, text)
        head = self.repo.commit("head", snapshot=snapshot)
        self.repo.git("checkout", "-q", self.base)
        return head

    def changed(self, head, base=None):
        """Every default that differs between the base and `head`, each read from its tree's sources."""
        tool = self.tool
        before = tool.defaults(tool.Tree(base or self.base, self.repo.root))
        after = tool.defaults(tool.Tree(head, self.repo.root))
        return Changed(tool.changes(before, after))

    # What counts as a default.

    def test_a_new_default_chord_is_listed_by_name(self):
        actions = [*BASE_ACTIONS[:3], action("toggleEditor", "e", ["ctrl", "cmd"])]
        result = self.changed(self.head(actions))
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("DEFAULTS key.toggleEditor: + ctrl+cmd+e", result.stdout)

    def test_moving_ctrl_tab_to_another_action_names_both(self):
        actions = [action("nextSidebarTab", "]", ["shift", "cmd"], aliases=[("", ["ctrl"])]),
                   action("nextSurface", "\t", ["ctrl"]), *BASE_ACTIONS[2:]]
        result = self.changed(self.head(actions))
        self.assertEqual(result.returncode, 1)
        self.assertIn("DEFAULTS key.nextSidebarTab: - ctrl+tab", result.stdout)
        self.assertIn("DEFAULTS key.nextSurface: + ctrl+tab", result.stdout)

    def test_a_new_arrow_chord_reads_by_key_name(self):
        actions = [*BASE_ACTIONS[:2], action("focusUp", "", ["shift", "cmd"]), BASE_ACTIONS[3]]
        result = self.changed(self.head(actions))
        self.assertIn("DEFAULTS key.focusUp: + shift+cmd+up; - opt+cmd+up", result.stdout)

    def test_a_ui_feature_turned_on_by_default_is_listed(self):
        settings = [{"key": "terminal.showJumpToBottomButton", "default": True}, BASE_SETTINGS[1]]
        result = self.changed(self.head(settings=settings))
        self.assertEqual(result.returncode, 1)
        self.assertIn("DEFAULTS setting.terminal.showJumpToBottomButton: false -> true", result.stdout)

    def test_taking_a_chord_from_ghostty_is_listed(self):
        keybinds = KEYBINDS.replace("]\n", '    "keybind = super+d=unbind",\n]\n')
        result = self.changed(self.head(keybinds=keybinds))
        self.assertEqual(result.returncode, 1)
        self.assertIn('DEFAULTS ghostty.super+d: (none) -> "unbind"', result.stdout)

    def test_a_compiled_flag_turned_on_is_listed(self):
        result = self.changed(self.head(flags=FLAGS.replace("false", "true")))
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
        result = self.changed(head)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("DEFAULTS tunable.dev.surface: false -> true", result.stdout)
        self.assertNotIn("commented.out", result.stdout)
        self.assertNotIn("also.commented", result.stdout)
        snapshot = self.repo.guard("snapshot").stdout + self.repo.root.joinpath(
            "schemas/defaults/cmux-next.json").read_text()
        self.assertIn("tunable.dev.label", snapshot)
        self.assertIn('"two  spaces"', snapshot)

    def test_tunable_helper_and_symbol_dependencies_are_listed(self):
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
                result = self.changed(head)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("DEFAULTS tunable-source.CmuxNextDesign/" + expected, result.stdout)
        head = self.head(extra={path: source.replace('print("before")', 'print("after")')
                               .replace("static let devDefault", "/* comment */ static   let devDefault"),
                               dependency: material})
        result = self.changed(head)
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
        result = self.changed(head)
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
                result = self.changed(head)
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
        result = self.changed(head)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("tunable-source.CmuxNextApp", result.stdout)
        head = self.head(extra={tunables: tunables_source.replace('toggle("animated", true)', 'toggle("animated", false)'),
                                handlers: handlers_source})
        result = self.changed(head)
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
                result = self.changed(self.head(extra=files))
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("DEFAULTS tunable-source." + expected, result.stdout)

    def test_self_typealias_subclass_and_protocol_helper_calls_are_tunable_sources(self):
        # Review of #33161: these reach a Tunable (or its helper) with no Tunable token and no `Type.helper` of a
        # type declared in the helper's file. The reader caught each before #33161 and must still.
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
                result = self.changed(self.head(extra=files))
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("DEFAULTS tunable-source." + path.split("/")[0] + "/" + expected, result.stdout)

    def test_two_flags_with_one_name_are_judged_apart(self):
        two = "enum A {\n    static let isEnabled = false\n}\nenum B {\n    static let isEnabled = true\n}\n"
        self.repo.write("Packages/macOS/CmuxNext/Sources/CmuxNextApp/Trace.swift", two)
        self.repo.write("Packages/macOS/CmuxNext/Sources/CmuxNextTerminal/Trace.swift", "enum C {\n    static let isEnabled = false\n}\n")
        self.base = self.repo.commit("two flags")
        head = self.head(extra={"Packages/macOS/CmuxNext/Sources/CmuxNextApp/Trace.swift": two.replace("= false", "= true"),
                                "Packages/macOS/CmuxNext/Sources/CmuxNextTerminal/Trace.swift": "enum C {\n    static let isEnabled = false\n}\n"})
        result = self.changed(head)
        self.assertEqual(result.returncode, 1)
        self.assertIn("DEFAULTS flag.CmuxNextApp/Trace.isEnabled: false -> true", result.stdout)

    def test_a_default_that_steps_aside_in_a_terminal_is_listed(self):
        swift = "public static let yieldsToTerminal: Set<ActionID> = [\n    \"focusHistoryBack\",\n]\n"
        self.repo.write("Packages/macOS/CmuxNext/Sources/CmuxNextActions/KeyBindingDefaults.swift", swift)
        self.base = self.repo.commit("steps aside")
        head = self.head(extra={"Packages/macOS/CmuxNext/Sources/CmuxNextActions/KeyBindingDefaults.swift":
                                swift.replace("]", '    "splitRight",\n]')})
        result = self.changed(head)
        self.assertEqual(result.returncode, 1)
        self.assertIn("DEFAULTS steps-aside.yieldsToTerminal: + splitRight", result.stdout)

    def test_a_default_that_steps_aside_in_the_rust_catalog_is_listed(self):
        rust = "pub static YIELDS_TO_TERMINAL: &[&str] = &[\n    \"focusHistoryBack\",\n];\n"
        self.repo.write("cmux-tui/crates/cmux-action-catalog/src/bindings.rs", rust)
        self.base = self.repo.commit("steps aside in Rust")
        head = self.head(extra={"cmux-tui/crates/cmux-action-catalog/src/bindings.rs":
                                rust.replace("];", '    "splitRight",\n];')})
        result = self.changed(head)
        self.assertEqual(result.returncode, 1)
        self.assertIn("DEFAULTS steps-aside.yieldsToTerminal: + splitRight", result.stdout)

    def test_a_newline_in_a_default_stays_on_its_line(self):
        settings = [*BASE_SETTINGS, {"key": "x\n::error::forged @someone", "default": True}]
        result = self.changed(self.head(settings=settings))
        self.assertNotIn("\n::error::forged", result.stdout)
        self.assertIn("DEFAULTS setting.x\\n::error::forged @someone: (none) -> true", result.stdout)

    def test_checked_out_directories_read_as_commits_do(self):
        head = self.head(settings=[BASE_SETTINGS[0], {"key": "sidebar.numbering", "default": "workspacesOnly"}])
        checkout = self.repo.root.parent / f"{self.repo.root.name}-head"
        self.repo.git("worktree", "add", "-q", "--detach", str(checkout), head)
        tool = self.tool
        self.assertEqual(tool.defaults(tool.Tree.named(str(checkout))), tool.defaults(tool.Tree(head, self.repo.root)))
        self.assertIn("setting.sidebar.numbering", self.changed(head).stdout)

    def test_a_linked_file_in_a_checked_out_tree_is_refused(self):
        secret = self.repo.root.parent / f"{self.repo.root.name}-runner-secret.json"
        secret.write_text(json.dumps({"rows": [{"key": "leak", "default": "runner file"}]}), encoding="utf-8")
        head = self.repo.root.parent / f"{self.repo.root.name}-linked-head"
        self.repo.git("worktree", "add", "-q", "--detach", str(head), self.base)
        settings = head / "schemas/settings/settings-schema.json"
        settings.unlink()
        settings.symlink_to(secret)
        result = self.repo.guard("check-fresh", "--ref", str(head))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is a symbolic link", result.stdout + result.stderr)
        self.assertNotIn("runner file", result.stdout + result.stderr)


    # The snapshot itself.

    def test_a_branch_from_before_the_snapshot_is_judged_by_its_sources(self):
        self.repo.git("rm", "-q", "schemas/defaults/cmux-next.json")
        self.base = self.repo.commit("base before the snapshot", snapshot=False)
        head = self.head(settings=[{"key": "terminal.showJumpToBottomButton", "default": True}, BASE_SETTINGS[1]],
                         snapshot=False)
        result = self.changed(head)
        self.assertEqual(result.returncode, 1)
        self.assertIn("DEFAULTS setting.terminal.showJumpToBottomButton: false -> true", result.stdout)
        self.assertNotIn("snapshot", result.stdout.replace("defaults_guard.py snapshot", ""))

    def test_no_default_change_lists_nothing(self):
        actions = [*BASE_ACTIONS[:3], {**action("toggleEditor"), "title": "Toggle Editor"}]
        result = self.changed(self.head(actions))
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("DEFAULTS", result.stdout)

    # The snapshot is bot-only (#21946): the base autofix rewrites it after a merge, a pull request
    # never commits it, and a head's defaults are read from its sources and exports.

    def test_a_head_that_does_not_commit_the_snapshot_is_judged_by_its_sources(self):
        actions = [*BASE_ACTIONS[:3], action("toggleEditor", "e", ["ctrl", "cmd"])]
        head = self.head(actions, snapshot=False)
        result = self.changed(head)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("DEFAULTS key.toggleEditor: + ctrl+cmd+e", result.stdout)
        self.assertNotIn("does not match the sources", result.stdout)

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

    def test_check_is_gone(self):
        """The approval check was deleted (Leo 2026-11-25: "the fuck is a defaults guard for. if it's not
        useful, get rid of it"); the snapshot and the stamp stay."""
        self.assertEqual(self.repo.guard("check", "--base", "HEAD", "--head", "HEAD").returncode, 2)


if __name__ == "__main__":
    unittest.main()
