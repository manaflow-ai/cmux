#!/usr/bin/env python3
"""Every `${{ }}` a guard reads is found by one tokenizer (scripts/ci/gh_expressions.py), never by a regex.

A string literal in an expression may hold `}}`: `format('{{{0}}}', x)` writes JSON braces. A regex such as
`\\$\\{\\{(.*?)\\}\\}` or `\\$\\{\\{[^}]*\\}\\}` ends the expression at the first `}}` (or `}`), so what follows
the cut reads as plain text: a matrix read, a secret or `github.token` after it is missed and the guard passes
(Codex review of #41768, F1: `${{ format('{{{0}}}', matrix[inputs.axis]) }}` got a signing job past the keychain
guard's fail-closed matrix check). gh_expressions skips single-quoted literals (`''` is an escaped quote) and
ends an expression at the first `}}` outside one; an expression that never ends raises Unterminated, so a guard
fails closed.

Rows: the tokenizer itself (the four shapes and a plain literal), each guard script that scanned with a regex
(github_token_polling, runs_on_values, runner_routing_table, run_ci_guards), and a detector: no Python file under
scripts/ or tests/ holds a regex that scans `${{ ... }}` with a generic body (`.*`, `.+`, `[^}]`). ALLOWED names
the few that only pin an exact shape, each with why a cut cannot pass it; an entry that no longer matches fails.
"""

from __future__ import annotations

import ast
import importlib
import re
import sys
import unittest
from pathlib import Path

TESTS = Path(__file__).resolve().parent
ROOT = TESTS.parent
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
sys.path.insert(0, str(TESTS))

BRACES = "${{ format('{{{0}}}', matrix[inputs.axis]) }}"
LITERAL_FIRST = "${{ '}}' && matrix[inputs.axis] }}"
ESCAPED_QUOTE = "${{ format('it''s }} {0}', matrix[inputs.axis]) }}"
UNTERMINATED = ("${{ matrix[inputs.axis]", "${{ format('}}', matrix[inputs.axis])", "a ${{ 'b' }} ${{ c")

# A regex source that scans `${{ ... }}`: the escaped opener, a body, the escaped closer.
SCAN = re.compile(r"\\\$\\\{\\\{(.*?)\\\}\\\}", re.DOTALL)
OPEN, CLOSE = r"\$\{\{", r"\}\}"
# A body that can stop at a `}}` inside a string literal (or at any `}`): any-char runs and `[^}]` classes.
GENERIC = re.compile(r"\.\*|\.\+|\[\^\\?\}")

# (file relative to the repository, the start of the regex source): why it is safe. Each pins one exact shape, so
# text a cut would misread does not match it and the check goes red instead of passing. This file's own sources (the
# entries here) are not scanned.
ALLOWED: dict[tuple[str, str], str] = {
    ("tests/test_ci_change_areas.py", r'^\s+bun-version:\s*"?(\$\{\{[^}]*\}\}|[^"\s#]*)"?'):
        "reads one setup-bun pin to compare with devEngines: a cut leaves `${{`, which is neither "
        "`${{ steps.X.outputs.version }}` nor the pin, so the test goes red",
    ("tests/test_nightly_delivery_concurrency.py",
     r"nightly-build-\$\{\{[^}]*\}\}-\$\{\{ github\.ref == 'refs/heads/nightly-next' && "):
        "asserts the concurrency group is this exact text: a `}` inside the first expression makes it not match, "
        "so the assertion fails rather than passes",
}


def _allowed(path: str, source: str) -> str | None:
    return next((key for key in ALLOWED if key[0] == path and source.startswith(key[1])), None)


def _scanning_regexes() -> list[tuple[str, int, str]]:
    found = []
    for base in ("scripts", "tests"):
        for path in sorted((ROOT / base).rglob("*.py")):
            if path.resolve() == Path(__file__).resolve():
                continue
            try:
                tree = ast.parse(path.read_text(encoding="utf-8"))
            except (SyntaxError, UnicodeDecodeError):
                continue
            docstrings = set()
            for node in ast.walk(tree):
                if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
                    body = getattr(node, "body", [])
                    if body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant):
                        docstrings.add(id(body[0].value))
            for node in ast.walk(tree):
                if (isinstance(node, ast.Constant) and isinstance(node.value, str) and id(node) not in docstrings
                        and any(GENERIC.search(body) for body in SCAN.findall(node.value))):
                    found.append((str(path.relative_to(ROOT)), node.lineno, node.value))
    return found


class Tokenizer(unittest.TestCase):
    def setUp(self) -> None:
        self.gh = importlib.import_module("gh_expressions")

    def test_a_brace_string_does_not_end_the_expression(self) -> None:
        self.assertEqual(self.gh.EXPRESSION.findall(BRACES), [BRACES[3:-2]])

    def test_a_closing_brace_literal_before_a_read(self) -> None:
        self.assertEqual(self.gh.EXPRESSION.findall(LITERAL_FIRST), [LITERAL_FIRST[3:-2]])

    def test_an_escaped_quote_stays_inside_the_literal(self) -> None:
        self.assertEqual(self.gh.EXPRESSION.findall(ESCAPED_QUOTE), [ESCAPED_QUOTE[3:-2]])

    def test_an_unterminated_expression_fails_closed(self) -> None:
        for text in UNTERMINATED:
            with self.subTest(text=text):
                with self.assertRaises(self.gh.Unterminated):
                    self.gh.EXPRESSION.findall(text)
                with self.assertRaises(self.gh.Unterminated):
                    self.gh.EXPRESSION.sub("x", text)

    def test_plain_text_and_several_expressions(self) -> None:
        self.assertEqual(self.gh.EXPRESSION.findall("macos-26"), [])
        self.assertEqual(self.gh.EXPRESSION.sub(lambda m: m.group(1).strip().upper(), "a-${{ b }}-${{ '}}' }}"),
                         "a-B-'}}'")
        self.assertEqual(self.gh.EXPRESSION.split("a${{ b }}c"), ["a", " b ", "c"])
        self.assertEqual(self.gh.STRIPPED.fullmatch(" ${{ x }} "), None)
        self.assertEqual(self.gh.STRIPPED.fullmatch("${{ x || '}}' }}").group(1), "x || '}}'")
        self.assertIsNone(self.gh.EXPRESSION.fullmatch("${{ a }}-${{ b }}"))


class GuardScripts(unittest.TestCase):
    """Each guard script that scanned `${{ }}` with a regex reads the whole expression now."""

    def test_token_polling_sees_github_token_after_a_brace_literal(self) -> None:
        polling = importlib.import_module("github_token_polling")
        for token in ("${{ format('{0}}}', github.token) }}", "${{ '}' && github.token }}",
                      "${{ format('{{{0}}}', secrets.GITHUB_TOKEN) }}"):
            with self.subTest(token=token):
                self.assertTrue(polling.calls_with_own_token({"env": {"GH_TOKEN": token}}, {}, {}))
        self.assertFalse(polling.calls_with_own_token({"env": {"GH_TOKEN": "${{ secrets.OTHER }}"}}, {}, {}))

    def test_runs_on_values_reads_the_whole_expression(self) -> None:
        values = importlib.import_module("runs_on_values")
        text = "${{ format('{{{0}}}', vars.ONE_HOST) }}"
        self.assertEqual(values.runs_on_expressions(text), [text[3:-2]])

    def test_runner_routing_table_reads_the_whole_expression(self) -> None:
        table = importlib.import_module("runner_routing_table")
        self.assertEqual(table.EXPRESSION.findall(BRACES), [BRACES[3:-2]])

    def test_run_ci_guards_reads_the_whole_expression(self) -> None:
        guards = importlib.import_module("run_ci_guards")
        self.assertEqual(guards.EXPRESSION.findall("${{ github.sha || '}}' }}"), ["github.sha || '}}'"])


    def test_fork_routing_names_a_line_whose_expression_does_not_end(self) -> None:
        routing = importlib.import_module("test_ci_fork_runner_routing")
        line = "    runs-on: ${{ format('{0}}}', matrix.pr_runner) }}"
        self.assertIsNotNone(routing.fork_pull_request_gate_error(line))
        self.assertIsNotNone(routing.fork_pull_request_gate_error("    runs-on: ${{ matrix.pr_runner ||"))


class NoRegexScans(unittest.TestCase):
    def test_no_regex_scans_an_expression(self) -> None:
        named = [f"{path}:{line}: {source}" for path, line, source in _scanning_regexes()
                 if _allowed(path, source) is None]
        self.assertEqual(named, [], "scan `${{ }}` with gh_expressions (EXPRESSION, STRIPPED), not a regex")

    def test_every_allowed_entry_still_matches(self) -> None:
        found = {_allowed(path, source) for path, _, source in _scanning_regexes()}
        self.assertEqual(sorted(set(ALLOWED) - found), [])

    def test_the_detector_names_the_old_scans(self) -> None:
        # Built from parts so this file holds no scanning regex itself.
        for body in ("(.*?)", r"\s*(.*?)\s*", "[^}]*", r"\s*([^}]+?)\s*", ".*?"):
            source = OPEN + body + CLOSE
            with self.subTest(source=source):
                self.assertTrue(any(GENERIC.search(body) for body in SCAN.findall(source)))
        for source in (r"\$\{\{ vars\.[^\n]*$", r"\$\{\{ inputs\.([A-Za-z0-9_]+) == 'true' \}\}"):
            with self.subTest(source=source):
                self.assertFalse(any(GENERIC.search(body) for body in SCAN.findall(source)))


_SUB_CALLS = {"sub", "subn"}


def _holds_open(node: ast.AST) -> bool:
    return any(isinstance(n, ast.Constant) and isinstance(n.value, str) and OPEN in n.value for n in ast.walk(node))


def _substitutions_in(source: str, guards: bool) -> list[int]:
    """Lines that rewrite `${{ ... }}` text by regex (`re.sub` with a `${{` pattern, or `.sub` on a name compiled
    from one), or, in a guard script (`guards`), by `str.replace` of a `${{` string. Either one rewrites text inside
    another expression's string literal too (cmux#41768 follow-up F1)."""
    tree = ast.parse(source)
    compiled = set()
    for node in ast.walk(tree):
        if (isinstance(node, ast.Assign) and isinstance(node.value, ast.Call)
                and isinstance(node.value.func, ast.Attribute) and node.value.func.attr == "compile"
                and node.value.args and _holds_open(node.value.args[0])):
            compiled.update(target.id for target in node.targets if isinstance(target, ast.Name))
    lines = []
    for node in ast.walk(tree):
        if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)):
            continue
        owner, name = node.func.value, node.func.attr
        if name in _SUB_CALLS and isinstance(owner, ast.Name) and owner.id == "re" and node.args and _holds_open(node.args[0]):
            lines.append(node.lineno)
        elif name in _SUB_CALLS and isinstance(owner, ast.Name) and owner.id in compiled:
            lines.append(node.lineno)
        elif guards and name == "replace" and node.args and isinstance(node.args[0], ast.Constant) \
                and isinstance(node.args[0].value, str) and "${{" in node.args[0].value:
            lines.append(node.lineno)
    return lines


def _regex_substitutions() -> list[str]:
    found = []
    for base in ("scripts", "tests"):
        for path in sorted((ROOT / base).rglob("*.py")):
            if path.resolve() == Path(__file__).resolve():
                continue
            try:
                source = path.read_text(encoding="utf-8")
                lines = _substitutions_in(source, guards=base == "scripts" or path.name == "workflow_jobs.py")
            except (SyntaxError, UnicodeDecodeError):
                continue
            found += [f"{path.relative_to(ROOT)}:{line}" for line in lines]
    return found


class NoTextSubstitutions(unittest.TestCase):
    """cmux#41768 follow-up F1: expand_matrix replaced `${{ matrix.KEY }}` with re.sub, so a copy of it inside
    another expression's string literal was rewritten too; a value with `' }}` then ended that expression early and
    hid a computed matrix read. Replace whole expressions through gh_expressions (EXPRESSION.sub), never by text."""

    def test_no_regex_rewrites_an_expression(self) -> None:
        self.assertEqual(_regex_substitutions(), [],
                         "rewrite `${{ }}` with gh_expressions.EXPRESSION.sub on whole spans, not re.sub or str.replace")

    def test_the_detector_names_the_old_rewrite(self) -> None:
        # Built from parts so this file holds no rewrite itself.
        old = ("import re\nexpanded = re.sub(r'" + OPEN + r"\s*matrix\s*\.\s*' + re.escape(key) + r'\s*"
               + CLOSE + "', value, expanded)\n")
        self.assertEqual(_substitutions_in(old, guards=False), [2])
        compiled = "import re\nWHOLE = re.compile(r'" + OPEN + r"\s*inputs\.x\s*" + CLOSE + "')\nWHOLE.sub('v', text)\n"
        self.assertEqual(_substitutions_in(compiled, guards=False), [3])
        replaced = "text.replace('$" + "{{ runner.temp }}', 'tmp')\n"
        self.assertEqual(_substitutions_in(replaced, guards=True), [1])
        self.assertEqual(_substitutions_in(replaced, guards=False), [])
        self.assertEqual(_substitutions_in("import re\nre.sub(r'x', 'y', text)\n", guards=True), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
