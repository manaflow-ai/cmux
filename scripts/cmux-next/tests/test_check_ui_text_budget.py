#!/usr/bin/env python3
"""check-ui-text-budget.py: visible strings stay within their kind's word budget, and the allowlist of strings
over budget only shrinks (Leo, 2026-11-16: "this needs to shut up / most of our s*** probably needs to shut up /
and stop writing so much s***")."""

import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# tests/git_fixture_env.py turns off git's background maintenance in temp repos.
_git_fixture_env = importlib.util.spec_from_file_location(
    "git_fixture_env",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "tests", "git_fixture_env.py"),
)
git_fixture_env = importlib.util.module_from_spec(_git_fixture_env)
_git_fixture_env.loader.exec_module(git_fixture_env)

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "check-ui-text-budget.py"
SPEC = importlib.util.spec_from_file_location("check_ui_text_budget", SCRIPT)
assert SPEC and SPEC.loader
lint = importlib.util.module_from_spec(SPEC)
sys.modules["check_ui_text_budget"] = lint
SPEC.loader.exec_module(lint)

TABLE = "webviews/src/pages/demo/Localizable.xcstrings"
SCHEMA = "schemas/settings/source/demo.json"
LONG = "one two three four five six seven eight nine ten eleven twelve thirteen"  # 13 words


def table(strings: dict[str, str | None]) -> str:
    body = {}
    for key, value in strings.items():
        body[key] = {} if value is None else {"localizations": {"en": {"stringUnit": {"state": "translated",
                                                                                      "value": value}}}}
    return json.dumps({"sourceLanguage": "en", "strings": body, "version": "1.0"}, indent=2)


class Fixture:
    def __init__(self, root: Path):
        self.root = root

    def write(self, rel: str, text: str) -> None:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def strings(self, strings: dict[str, str | None], rel: str = TABLE) -> None:
        self.write(rel, table(strings))

    def run(self, *args: str) -> tuple[int, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = lint.main([*args, str(self.root)])
        return code, out.getvalue() + err.getvalue()

    def allowlist(self) -> str:
        return (self.root / lint.ALLOWLIST).read_text(encoding="utf-8")

    def git(self, *args: str) -> None:
        subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True,
                       env=git_fixture_env.fixture_env())

    def commit(self, message: str) -> None:
        self.git("add", "-A")
        self.git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", message)


class KindTests(unittest.TestCase):
    def test_kind_from_the_keys_last_words(self):
        cases = {
            "settings.title": "label",
            "composer.sendButton": "label",
            "home.emptyTitle": "label",
            "palette.placeholder.search": "label",
            "sidebar.status.running": "status",
            "remote.offline": "status",
            "agent.timedOut": "error",
            "turn.failure.contextFull": "error",
            "chats.empty": "empty",
            "feed.none": "empty",
            "onboarding.cloud.subtitle": "hint",
            "page.intro": "hint",
            "button.help": "hint",
            "deleteChat.alert.message": "dialog",
            "confirm.body": "dialog",
            "Open Settings": "text",
            "lane.needsName": "status",
            "handlers.refusal.noTab": "cli",
            "cloud.cli.machineGone": "cli",
            "foo.bar": "text",
        }
        for key, kind in cases.items():
            with self.subTest(key=key):
                self.assertEqual(lint.kind_of(key), kind)

    def test_words_count_a_placeholder_as_one_word(self):
        self.assertEqual(lint.count_words("Open %@ in %1$@ now"), 5)
        self.assertEqual(lint.count_words("{count} chats, %lld left"), 4)
        self.assertEqual(lint.count_words("Can’t reach the Mac."), 4)

    def test_every_kind_has_a_budget(self):
        self.assertTrue(set(lint.KIND_WORDS.values()) <= set(lint.BUDGETS))


class CheckTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.fx = Fixture(Path(self.tmp.name))

    def test_within_budget_passes(self):
        self.fx.strings({"demo.title": "Chats", "demo.status.running": "Running"})
        code, out = self.fx.run()
        self.assertEqual(code, 0, out)

    def test_over_budget_fails_with_the_fix_line(self):
        self.fx.strings({"demo.status.running": LONG})
        code, out = self.fx.run()
        self.assertEqual(code, 1)
        self.assertIn(f"{TABLE}: demo.status.running: 13 words, budget 12 for status "
                      "(Leo: say only what the person can act on)", out)

    def test_english_value_else_the_key(self):
        self.fx.strings({LONG: None})  # 13 words, the key is the English; text budget 25
        self.assertEqual(self.fx.run()[0], 0)
        self.fx.strings({"demo.title": None})
        self.assertEqual(self.fx.run()[0], 0)

    def test_plural_variation_is_read(self):
        entry = {"localizations": {"en": {"variations": {"plural": {
            "one": {"stringUnit": {"state": "translated", "value": "One"}},
            "other": {"stringUnit": {"state": "translated", "value": LONG}}}}}}}
        self.fx.write(TABLE, json.dumps({"sourceLanguage": "en", "strings": {"demo.badge": entry}}))
        code, out = self.fx.run()
        self.assertEqual(code, 1)
        self.assertIn("13 words, budget 12 for status", out)

    def test_tables_under_node_modules_are_skipped(self):
        self.fx.strings({"demo.title": LONG}, "webviews/src/node_modules/x/Localizable.xcstrings")
        self.assertEqual(self.fx.run()[0], 0)

    def test_settings_schema_summary_and_search_help(self):
        schema = {"lists": [{"rows": [{
            "title": {"key": "settings.demo.title", "text": "Demo"},
            "summary": {"key": "settings.demo.summary", "text": "one two three four five six seven eight nine ten"},
            "help": {"key": "settings.demo.help", "text": " ".join(["word"] * 60)},
        }]}]}
        self.fx.write(SCHEMA, json.dumps(schema))
        # The schema's generated table copies its keys; they are judged once, as the schema's.
        self.fx.strings({"settings.demo.help": " ".join(["word"] * 60)},
                        "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Localizable.xcstrings")
        self.assertEqual(self.fx.run()[0], 0)
        schema["lists"][0]["rows"][0]["summary"]["text"] += " eleven"
        schema["lists"][0]["rows"][0]["help"]["text"] += " more"
        self.fx.write(SCHEMA, json.dumps(schema))
        code, out = self.fx.run()
        self.assertEqual(code, 1)
        self.assertIn(f"{SCHEMA}: settings.demo.summary: 11 words, budget 10 for summary", out)
        self.assertIn(f"{SCHEMA}: settings.demo.help: 61 words, budget 60 for search-help", out)
        self.assertNotIn("Localizable.xcstrings", out.split("UI text budget failure")[0])

    def test_listed_string_passes_and_growth_fails(self):
        self.fx.strings({"demo.status.running": LONG})
        self.fx.run("--seed-allowlist")
        self.assertIn(f"{TABLE}\tdemo.status.running\t13\t12", self.fx.allowlist())
        self.assertEqual(self.fx.run()[0], 0)
        self.fx.strings({"demo.status.running": LONG + " fourteen"})
        code, out = self.fx.run()
        self.assertEqual(code, 1)
        self.assertIn("grew past its allowlist row (13)", out)

    def test_stale_rows_fail_and_write_allowlist_only_shrinks(self):
        self.fx.strings({"demo.status.running": LONG + " fourteen", "demo.status.done": LONG})
        self.fx.run("--seed-allowlist")
        # One string shortened but still over, one cut within budget, and a new long string.
        self.fx.strings({"demo.status.running": LONG, "demo.status.done": "Done", "demo.status.busy": LONG})
        code, out = self.fx.run()
        self.assertEqual(code, 1)
        self.assertIn("stale row " + TABLE + ": demo.status.running: it is 13 words", out)
        self.assertIn("stale row " + TABLE + ": demo.status.done: it is 1 words, within budget 12", out)
        self.assertIn("--write-allowlist", out)
        self.fx.run("--write-allowlist")
        listed = self.fx.allowlist()
        self.assertIn("demo.status.running\t13\t12", listed)
        self.assertNotIn("demo.status.done", listed)
        self.assertNotIn("demo.status.busy", listed)  # never adds a row
        code, out = self.fx.run()
        self.assertEqual(code, 1)
        self.assertIn(f"{TABLE}: demo.status.busy: 13 words, budget 12 for status", out)

    def test_gone_string_is_a_stale_row(self):
        self.fx.strings({"demo.status.running": LONG})
        self.fx.run("--seed-allowlist")
        self.fx.strings({})
        code, out = self.fx.run()
        self.assertEqual(code, 1)
        self.assertIn("the string is gone", out)

    def test_keys_with_tabs_and_newlines_round_trip(self):
        key = "line one\nline two\t" + LONG + " " + LONG
        self.fx.strings({key: None})
        self.fx.run("--seed-allowlist")
        self.assertEqual(len([l for l in self.fx.allowlist().splitlines() if not l.startswith("#")]), 1)
        self.assertEqual(self.fx.run()[0], 0)

    def test_malformed_and_duplicate_rows_fail(self):
        self.fx.strings({})
        self.fx.write(lint.ALLOWLIST, "a\tb\tc\n")
        self.assertIn("a row is path, key, words, budget", self.fx.run()[1])
        self.fx.write(lint.ALLOWLIST, "a\tb\t13\t12\na\tb\t13\t12\n")
        self.assertIn("duplicate row", self.fx.run()[1])


class BaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.fx = Fixture(Path(self.tmp.name))
        git_fixture_env.init_repo(self.fx.root, "-q")

    def test_first_change_may_add_the_list(self):
        self.fx.write("README", "x")
        self.fx.commit("base")
        self.fx.strings({"demo.status.running": LONG})
        self.fx.run("--seed-allowlist")
        self.assertEqual(self.fx.run("--base", "HEAD")[0], 0)

    def test_new_row_and_grown_row_fail_against_base(self):
        self.fx.strings({"demo.status.running": LONG})
        self.fx.run("--seed-allowlist")
        self.fx.commit("base")
        self.fx.strings({"demo.status.running": LONG + " fourteen", "demo.status.busy": LONG})
        self.fx.run("--seed-allowlist")  # what a change that hand-adds rows would carry
        code, out = self.fx.run("--base", "HEAD")
        self.assertEqual(code, 1)
        self.assertIn(f"new row {TABLE}: demo.status.busy: the list only shrinks", out)
        self.assertIn(f"row {TABLE}: demo.status.running grew from 13 to 14 words", out)

    def test_shrunk_row_passes_against_base(self):
        self.fx.strings({"demo.status.running": LONG + " fourteen"})
        self.fx.run("--seed-allowlist")
        self.fx.commit("base")
        self.fx.strings({"demo.status.running": LONG})
        self.fx.run("--write-allowlist")
        code, out = self.fx.run("--base", "HEAD")
        self.assertEqual(code, 0, out)

    def test_unresolvable_base_exits_2(self):
        self.fx.strings({})
        self.fx.commit("base")
        code, out = self.fx.run("--base", "no-such-ref")
        self.assertEqual(code, 2)
        self.assertIn("does not resolve", out)


if __name__ == "__main__":
    unittest.main()
