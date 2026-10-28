#!/usr/bin/env python3
"""The perf-lab docs match the code: every number in perf-lab-DESIGN.md section 7.1, the sheriff states, and links.

Run: python3 -m unittest scripts/perf-lab/tests/test_design_docs.py

- Section 7.1 of plans/cmux-next/perf-lab-DESIGN.md is a table of (constant, value, code). A code cell
  `path::NAME` is a module-level constant, read from the file's syntax tree without running it. A code cell
  `path::expression` is evaluated in that perf-lab module (scripts/perf-lab/ only). A value equals the code's value
  exactly, with the same type. Only a value cell marked `≈` (a computed p-value or threshold lookup) matches when the
  code's value rounds to it at the doc's number of decimals.
- The state line of plans/cmux-next/perf-sheriff.md lists store.py ALERT_GROUP_STATES in order.
- Every relative Markdown link of the perf-lab docs points to a file that exists, and an anchor to a heading in it.
"""

import ast
import importlib.util
import os
import re
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
LAB = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(LAB))
DESIGN = "plans/cmux-next/perf-lab-DESIGN.md"
SHERIFF = "plans/cmux-next/perf-sheriff.md"
DOCS = (DESIGN, SHERIFF, "plans/cmux-next/perf-lead.md", "plans/cmux-next/PATTERNS.md", "plans/cmux-next/OWNERS.md")
CODE_CELL = re.compile(r"^`([^`:]+)::(.+)`$")
VALUE_CELL = re.compile(r"^(≈ )?`(.+)`$")
LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]+)\)")


def _read(rel):
    with open(os.path.join(REPO, rel), encoding="utf-8") as f:
        return f.read()


def _section(text, heading):
    """The lines under the Markdown heading `heading` up to the next heading of the same or a higher level."""
    lines = text.splitlines()
    start = lines.index(heading)
    level = len(heading) - len(heading.lstrip("#"))
    out = []
    for line in lines[start + 1:]:
        match = re.match(r"^(#+) ", line)
        if match and len(match.group(1)) <= level:
            break
        out.append(line)
    return out


def _table_rows(lines):
    """Cells of each body row of the first Markdown table in `lines`."""
    rows = [line for line in lines if line.startswith("|")]
    return [[cell.strip() for cell in row.strip().strip("|").split("|")] for row in rows[2:]]


def constant_rows():
    """[(label, doc value cell, code path, code expression)] of perf-lab-DESIGN.md section 7.1."""
    out = []
    for cells in _table_rows(_section(_read(DESIGN), "### 7.1 Values in code")):
        label, value, code = cells[0], cells[1], cells[2]
        match = CODE_CELL.match(code)
        if not match:
            raise AssertionError("7.1 row %r: code cell %r is not `path::NAME`" % (label, code))
        out.append((label, value, match.group(1), match.group(2)))
    return out


def module_constant(rel, name):
    """The literal value of the module-level assignment `name = ...` in the Python file `rel`, without running it."""
    tree = ast.parse(_read(rel), rel)
    for node in tree.body:
        targets = node.targets if isinstance(node, ast.Assign) else [node.target] if isinstance(node, ast.AnnAssign) else []
        if any(isinstance(target, ast.Name) and target.id == name for target in targets):
            return ast.literal_eval(node.value)
    raise AssertionError("%s has no module-level %s" % (rel, name))


_MODULES = {}


def lab_module(rel):
    """The perf-lab module `rel`, loaded by file path once."""
    if not rel.startswith("scripts/perf-lab/"):
        raise AssertionError("%s: only scripts/perf-lab/ modules are run; name a constant instead" % rel)
    if rel not in _MODULES:
        name = "perf_lab_doc_" + re.sub(r"\W", "_", os.path.basename(rel)[:-3])
        spec = importlib.util.spec_from_file_location(name, os.path.join(REPO, rel))
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module  # before exec: a dataclass resolves its module through sys.modules (as lab.py)
        spec.loader.exec_module(module)
        _MODULES[rel] = module
    return _MODULES[rel]


def code_value(rel, expression):
    if re.fullmatch(r"[A-Za-z_]\w*", expression):
        return module_constant(rel, expression)
    return eval(expression, vars(lab_module(rel)))  # noqa: S307 - the expression is a reviewed doc cell


def matches(doc_value, value, approximate=False):
    """The doc value equals the code value with the same type; an approximate doc float is the code value rounded
    to the doc's decimals."""
    if approximate:
        return (isinstance(doc_value, float) and type(value) is float
                and round(value, len(repr(doc_value).split(".")[1])) == doc_value)
    return type(doc_value) is type(value) and doc_value == value


def github_slug(heading):
    slug = re.sub(r"[^\w\- ]", "", heading.strip().lower())
    return slug.replace(" ", "-")


class ConstantsMatchCode(unittest.TestCase):
    def test_the_table_has_the_spec_constants(self):
        labels = [row[0] for row in constant_rows()]
        self.assertGreaterEqual(len(labels), 20, labels)
        self.assertEqual(len(labels), len(set(labels)), "a constant is listed twice")

    def test_every_value_matches_its_code(self):
        for label, cell, rel, expression in constant_rows():
            with self.subTest(constant=label):
                match = VALUE_CELL.match(cell)
                self.assertIsNotNone(match, cell)
                doc_value = ast.literal_eval(match.group(2))
                value = code_value(rel, expression)
                self.assertTrue(matches(doc_value, value, approximate=bool(match.group(1))),
                                "%s: the doc says %r, %s::%s is %r" % (label, doc_value, rel, expression, value))

    def test_a_changed_value_fails(self):
        # The comparison itself: a code value past the doc's last digit, a wrong type or a reordered tuple never passes.
        for doc_value, value in ((0.1, 0.14), (0.5, 0.54), (2.5, 2.54), (0.95, 0.954), (1.05, 1.054), (0.01, 0.012),
                                 (1.0, 62 / 60), (10.0, 10.04), (2.0, 2.033)):
            self.assertFalse(matches(doc_value, value), (doc_value, value))
        self.assertTrue(matches(0.1, 0.1))
        # Only a cell marked approximate rounds, and only a float.
        self.assertTrue(matches(0.0195, 0.01945044401695495, approximate=True))
        self.assertFalse(matches(0.0195, 0.01945044401695495))
        self.assertFalse(matches(0.0196, 0.01945044401695495, approximate=True))
        self.assertFalse(matches(2.0, 2, approximate=True))
        self.assertFalse(matches(60, 60.0))
        self.assertFalse(matches(("a", "b"), ("b", "a")))
        self.assertFalse(matches(3, True))

    def test_constant_cells_are_read_without_running_the_file(self):
        # perf-cron.py is a 3000-line script: a NAME cell reads its syntax tree, it never imports it.
        self.assertEqual(module_constant("scripts/cmux-next/perf-cron.py", "BENCH_WORKER"), "cmux20-bench")
        with self.assertRaises(AssertionError):
            code_value("scripts/cmux-next/perf-cron.py", "len(BENCH_WORKER)")


class SheriffStatesMatchStore(unittest.TestCase):
    def test_the_state_line_lists_the_store_states_in_order(self):
        states = module_constant("scripts/perf-lab/store.py", "ALERT_GROUP_STATES")
        lines = [line for line in _read(SHERIFF).splitlines() if line.startswith("`new -> ")]
        self.assertEqual(len(lines), 1, lines)
        self.assertEqual(tuple(re.split(r" -> | \| ", lines[0].split("`")[1])), states)

    def test_the_state_table_names_every_state(self):
        states = module_constant("scripts/perf-lab/store.py", "ALERT_GROUP_STATES")
        rows = _table_rows(_section(_read(SHERIFF), "## 2. States"))
        self.assertEqual(tuple(cells[0].strip("`") for cells in rows), states)


class LinksResolve(unittest.TestCase):
    def test_relative_links_point_to_files_and_headings(self):
        for doc in DOCS:
            base = os.path.dirname(doc)
            for target in LINK.findall(_read(doc)):
                if re.match(r"^[a-z]+:", target):
                    continue
                with self.subTest(doc=doc, link=target):
                    path, _, anchor = target.partition("#")
                    rel = os.path.normpath(os.path.join(base, path)) if path else doc
                    self.assertTrue(os.path.exists(os.path.join(REPO, rel)), "%s links to missing %s" % (doc, rel))
                    if anchor and rel.endswith(".md"):
                        headings = [github_slug(line.lstrip("#")) for line in _read(rel).splitlines()
                                    if re.match(r"^#+ ", line)]
                        self.assertIn(anchor, headings, "%s links to a missing heading in %s" % (doc, rel))


if __name__ == "__main__":
    unittest.main()
