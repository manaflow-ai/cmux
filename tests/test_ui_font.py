#!/usr/bin/env python3
"""The UI font of cmux NEXT is the macOS system font, everywhere (Lawrence 2026-11-07: "default fonts on cmux for
everything should be macos default, not inter, this applies to everything, including markdown viewer, chat
trajectory etc").

scripts/cmux-next/check-ui-font.py fails when the type scale's stack, the generated `--font-ui` or its
letter-spacing tokens leave the pinned system stack (schemas/type-scale/ui-font-pin.json), when the app bundles an
Inter file again, when a default font stack in the webviews names Inter, and when the pin changes without a
`Font-order:` trailer. Each test builds a small git repository with those files.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

SOURCE = Path(__file__).resolve().parents[1]
CHECK = SOURCE / "scripts/cmux-next/check-ui-font.py"
STACK = ["-apple-system", "BlinkMacSystemFont", "system-ui", "sans-serif"]
STEPS = ("caption", "detail", "body", "field", "title", "heading")
FONTS = "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Resources/Fonts/"


def type_scale(stack=None):
    return {"font": {"stack": stack or STACK},
            "steps": [{"name": n, "size": 11 + i, "lineHeight": 16 + i, "for": "x"} for i, n in enumerate(STEPS)]}


def pin(note=None):
    data = {"orders": [{"date": "2026-11-07", "words": "macos default, not inter"}], "stack": STACK}
    if note:
        data["note"] = note
    return data


def desktop_css(stack=", ".join(STACK), spacing=None):
    spacing = spacing or {}
    lines = "\n".join(f"  --text-{n}--letter-spacing: {spacing.get(n, '0em')};" for n in STEPS)
    return ("/* shared */\n/* type-scale:begin. GENERATED; do not edit. */\n:root {\n"
            f"  --font-ui: {stack};\n{lines}\n}}\n/* type-scale:end */\n")


class UIFontTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ui-font-")
        self.repo = Path(self.tmp.name)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "user.name", "Test")
        self.write("schemas/type-scale/type-scale.json", json.dumps(type_scale()))
        self.write("schemas/type-scale/ui-font-pin.json", json.dumps(pin()))
        self.write("webviews/src/pages/shared/desktop.css", desktop_css())
        self.write("webviews/src/page.css", ".page { font: 13px var(--font-ui); }\n"
                   "code { font-family: ui-monospace, \"SF Mono\", Menlo, monospace; }\n"
                   "/* was \"Inter\", system-ui before 2026-11-07 */\n")
        self.write("webviews/src/measure.ts", 'const stack = "-apple-system, system-ui, sans-serif";\n'
                   '// Inter, the old default, is a chat font choice now.\n')
        # The chat's font menu offers Inter as an opt-in choice: naming it there is not a default.
        self.write("webviews/src/agent-session/acpmux/chatUiFont.ts", "inter: '\"Inter\", system-ui, sans-serif',\n")
        self.commit("base\n\nFont-order: macos default, not inter")
        self.base = self.git("rev-parse", "HEAD").strip()

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True, capture_output=True, text=True).stdout

    def write(self, path: str, content):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, bytes):
            target.write_bytes(content)
        else:
            target.write_text(content, encoding="utf-8")

    def commit(self, message: str):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)

    def check(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, "-I", str(CHECK), "--repo", str(self.repo), *args],
                              capture_output=True, text=True, timeout=60)

    def assert_fails(self, needle: str, *args: str):
        result = self.check(*args)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(needle, result.stdout)

    def test_the_system_font_passes(self):
        for args in ((), ("--rev", "HEAD"), ("--rev", "HEAD", "--base", self.base)):
            with self.subTest(args=args):
                result = self.check(*args)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_type_scale_stack_naming_inter_fails(self):
        self.write("schemas/type-scale/type-scale.json", json.dumps(type_scale(stack=['"Inter"'] + STACK)))
        self.assert_fails("type-scale.json: the UI font stack is")

    def test_font_ui_naming_inter_fails(self):
        self.write("webviews/src/pages/shared/desktop.css", desktop_css(stack='"Inter", ' + ", ".join(STACK)))
        self.assert_fails("--font-ui is")

    def test_letter_spacing_on_the_system_font_fails(self):
        # SF Pro carries its own size-specific tracking; an Inter curve on top of it draws it too tight.
        self.write("webviews/src/pages/shared/desktop.css", desktop_css(spacing={"heading": "-0.0167em"}))
        self.assert_fails("--text-heading--letter-spacing is -0.0167em")

    def test_a_bundled_inter_file_fails(self):
        self.write(FONTS + "InterVariable.woff2", b"wOF2fake")
        self.assert_fails("bundles Inter")

    def test_a_default_stack_naming_inter_fails(self):
        for path, line in (("webviews/src/agent/row.css", '.row { font-family: "Inter", system-ui; }'),
                           ("webviews/src/agent/row.css", ".row { font: 13px var(--font-ui, Inter, sans-serif); }"),
                           ("webviews/src/agent/measure.ts", "const stack = '\"Inter\", system-ui, sans-serif';"),
                           ("Native/OptChat/optchat-chief/inspector/index.html", 'body { font: 13px "Inter", system-ui; }')):
            with self.subTest(path=path, line=line):
                self.write(path, line + "\n")
                self.assert_fails(f"{path}:1: names Inter")
                (self.repo / path).unlink()

    def test_a_pin_change_needs_a_font_order(self):
        self.write("schemas/type-scale/ui-font-pin.json", json.dumps(pin(note="moved")))
        self.commit("tweak the pin")
        self.assert_fails("no `Font-order: <the user's words>` trailer", "--rev", "HEAD", "--base", self.base)
        self.write("schemas/type-scale/ui-font-pin.json", json.dumps(pin(note="moved again")))
        self.commit("move the pin\n\nFont-order: use this stack")
        result = self.check("--rev", "HEAD", "--base", self.base)
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_every_file_whose_change_moves_a_finding_is_in_its_inputs(self):
        # prepush-gate.py skips this check on a push that changes none of the paths `--inputs` prints (2026-11-09,
        # #39765). A file that moves a finding but is not in them would let such a push through unchecked.
        result = self.check("--inputs")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        inputs = tuple(line for line in result.stdout.splitlines() if line)
        self.assertTrue(inputs, "--inputs printed nothing")
        mutations = {
            "schemas/type-scale/type-scale.json": json.dumps(type_scale(stack=['"Inter"'] + STACK)),
            "schemas/type-scale/ui-font-pin.json": json.dumps(pin(note="moved")),
            "webviews/src/pages/shared/desktop.css": desktop_css(stack='"Inter", ' + ", ".join(STACK)),
            FONTS + "InterVariable.woff2": b"wOF2fake",
            "webviews/src/agent/row.css": '.row { font-family: "Inter", system-ui; }\n',
            "Native/OptChat/optchat-chief/inspector/index.html": 'body { font: 13px "Inter", system-ui; }\n',
        }
        for path, content in mutations.items():
            with self.subTest(path=path):
                self.write(path, content)
                self.commit(f"change {path}")
                moved = self.check("--rev", "HEAD", "--base", self.base)
                self.git("reset", "-q", "--hard", self.base)
                self.assertEqual(moved.returncode, 1, f"{path}: the change must move a finding\n{moved.stdout}")
                self.assertTrue(path.startswith(inputs), f"{path} moves a finding but --inputs is {inputs}")

    def test_a_read_outside_its_inputs_stops_the_check(self):
        # A new read must join INPUTS, or the gate would skip a push that changes only that file.
        copy = self.repo / "copy" / "check-ui-font.py"
        copy.parent.mkdir()
        entry = "def check_tree(tree: Tree) -> list[str]:\n"
        text = CHECK.read_text(encoding="utf-8")
        self.assertIn(entry, text)
        copy.write_text(text.replace(entry, entry + "    tree.read(\"README.md\")\n", 1), encoding="utf-8")
        for args in ((), ("--rev", "HEAD")):
            with self.subTest(args=args):
                result = subprocess.run([sys.executable, "-I", str(copy), "--repo", str(self.repo), *args],
                                        capture_output=True, text=True, timeout=60)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("README.md", result.stdout + result.stderr)
                self.assertIn("INPUTS", result.stdout + result.stderr)

    def test_the_repository_keeps_the_system_font(self):
        result = subprocess.run([sys.executable, "-I", str(CHECK), "--repo", str(SOURCE)], capture_output=True,
                                text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    os.environ.pop("GIT_DIR", None)
    unittest.main()
