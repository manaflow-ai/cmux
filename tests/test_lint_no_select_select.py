#!/usr/bin/env python3
"""No select.select() in cmux's Python: it refuses a descriptor at or above FD_SETSIZE (1024) with ValueError.

A process that holds many files (a long-lived tool, a test runner, a client library) is handed such a descriptor
sooner or later, and a wait on it with select.select() then raises instead of waiting (a pidfd wait in the shared
process helpers was the first). This walks every tracked Python file, and each program a file carries as a string,
with the rule leo-workspace#4486 added to the shared process_gone cases (tools/process_gone_cases.py's
select_select_uses, copied below unchanged): select.select and selectors.SelectSelector in every alias form. A site
waits with select.poll() or selectors.DefaultSelector, or ALLOWED names its file, how many uses it keeps, and why its
descriptor cannot be high.
"""
from __future__ import annotations

import ast
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

NONE = "a timed wait on no descriptor at all: select([], [], [], t)"
TTY = ("a terminal (a pty or stdin) in a short-lived tool or test: macOS poll() does not serve a terminal device, "
       "and the fd is a fresh, low one")
# path: (uses it keeps, why). A new use in one of these files fails too.
ALLOWED = {
    "cmux-next-ios/verify/scripts/sizing_probe.py": (1, NONE),
    "cmux-tui/crates/acpmux/tests/tui_terminal.py": (1, TTY),
    "cmux-tui/crates/cmux-cellgrid-bench/scripts/record.py": (1, TTY),
    "cmux-tui/scripts/repro-10431-dash-only.py": (1, TTY),
    "cmux-tui/scripts/repro-10431-paste.py": (1, TTY),
    "cmux-tui/scripts/repro-10431-pure-pty.py": (2, TTY),
    "cmux-tui/scripts/smoke-attach.py": (2, TTY),
    "cmux-tui/scripts/smoke-tui.py": (2, TTY),
    "experiments/live-migrate/newpty.py": (1, TTY),
    "experiments/live-migrate/owner.py": (1, TTY),
    "experiments/live-migrate/probe.py": (1, TTY),
    "experiments/live-migrate/receiver.py": (3, TTY),
    "scripts/ci/hung_test_watchdog.py": (1, TTY),
    "scripts/ci/xcodebuild_noninteractive.py": (1, TTY),
    "scripts/cmux-next/clipboard-read-live-check.py": (1, TTY),
    "scripts/cmux-next/quit-launch-bound.py": (2, NONE),
    "scripts/cmux-next/shell-integration-bench.py": (1, TTY),
    "scripts/journeys/pixel/tui_border.py": (2, TTY),
    "scripts/journeys/test_ext_marker.py": (1, TTY),
    "scripts/journeys/tui-kit/test_tuikit.py": (1, TTY),
    "scripts/journeys/tui-kit/tuikit.py": (2, TTY),
    "scripts/pty-run.py": (1, TTY),
    "tests/process_gone.py": (1, "vendored from leo-workspace tools/process_gone.py, whose source polls; #41409 "
                                 "re-vendors it"),
    "tests/test_bash_integration_no_done_notifications.py": (2, TTY),
    "tests/test_cmux_next_fast_gates.py": (2, NONE),
    "tests/test_ghostty_zsh_job_table_saturation_guard.py": (1, TTY),
    "tests/test_ghostty_zsh_prompt_redraw_uses_prompt_start.py": (1, TTY),
    "tests/test_ghostty_zsh_pure_hidden_cr_omits_continuation_marker.py": (1, TTY),
    "tests/test_ghostty_zsh_pure_preprompt_redraw.py": (1, TTY),
    "tests/test_issue_13766_terminal_history.py": (2, TTY),
    "tests/test_issue_15066_zsh_watcher_sleep.py": (1, TTY),
    "tests/test_issue_8953_zsh_prompt_wrap_guard.py": (2, TTY),
    "tests_v2/test_mobile_terminal_paste_submit.py": (1, TTY),
    "tests_v2/test_restore_launch_lease_contention.py": (1, TTY),
    "tests_v2/test_signals_auto.py": (4, TTY),
}
SKIP = {"tests/test_lint_no_select_select.py"}  # this file's own cases

SELECT_LIMITED = {"select.select", "selectors.SelectSelector"}


# leo-workspace tools/process_gone_cases.py at e6faf08b (#4486), unchanged.
def select_select_uses(source, name="<source>"):
    """(line, what) for every use in SOURCE of select.select or selectors.SelectSelector: called or not, through
    `import select as s`, `from select import select as w`, getattr(select, "select"), or an alias of either. A
    getattr on the select or selectors module with a name the source does not show may be either, so it counts."""
    import ast
    tree = ast.parse(source, name)
    names = {}  # name -> "select", "selectors", "select.select", ...
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for a in node.names:
                if a.name in ("select", "selectors"):
                    names[a.asname or a.name] = a.name
        elif isinstance(node, ast.ImportFrom) and node.module in ("select", "selectors") and not node.level:
            for a in node.names:
                names[a.asname or a.name] = "*" if a.name == "*" else "%s.%s" % (node.module, a.name)
    if "*" in names.values():
        names.update({"select": "select.select", "SelectSelector": "selectors.SelectSelector"})

    def dotted(node):
        if isinstance(node, ast.Name):
            return names.get(node.id)
        if isinstance(node, ast.Attribute):
            base = dotted(node.value)
            return "%s.%s" % (base, node.attr) if base else None
        if isinstance(node, ast.Call) and getattr(node.func, "id", "") == "getattr" and len(node.args) >= 2:
            base = dotted(node.args[0])
            if base in ("select", "selectors"):
                key = node.args[1]
                if isinstance(key, ast.Constant) and isinstance(key.value, str):
                    return "%s.%s" % (base, key.value)
                return "%s.<run time>" % base
        return None
    for _ in range(3):  # w = select.select; v = w
        for node in ast.walk(tree):
            if isinstance(node, (ast.Assign, ast.NamedExpr)):
                got = dotted(node.value)
                if got:
                    for t in (node.targets if isinstance(node, ast.Assign) else [node.target]):
                        if isinstance(t, ast.Name):
                            names[t.id] = got
    hits = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Name, ast.Attribute, ast.Call)):
            got = dotted(node)
            if got in SELECT_LIMITED or (got or "").endswith(".<run time>"):
                hits.add((node.lineno, got))
        if isinstance(node, ast.ImportFrom) and node.module in ("select", "selectors"):
            for a in node.names:
                if "%s.%s" % (node.module, a.name) in SELECT_LIMITED:
                    hits.add((node.lineno, "%s.%s" % (node.module, a.name)))
    return sorted(hits)


def uses(source: str, rel: str) -> list[tuple[int, str]]:
    """(line, what) for each select.select in SOURCE or in a program SOURCE holds as a string."""
    tree = ast.parse(source, rel)
    hits = list(select_select_uses(source, rel))
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and "select" in node.value \
                and "\n" in node.value:
            try:
                inner = select_select_uses(node.value, rel)
            except (SyntaxError, ValueError):
                continue  # prose, not a program
            hits += [(node.lineno + line - 1, what + " (in a string program)") for line, what in inner]
    return sorted(hits)


def python_files() -> list[str]:
    """Every tracked .py file, and every tracked file whose first line runs python."""
    out = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z"], capture_output=True, text=True, check=True,
                         timeout=60).stdout
    found = []
    for rel in filter(None, out.split("\0")):
        path = ROOT / rel
        if path.is_symlink() or not path.is_file():
            continue
        if not rel.endswith(".py"):
            with open(path, "rb") as f:
                head = f.readline(200)
            if not (head.startswith(b"#!") and b"python" in head):
                continue
        found.append(rel)
    return found


class NoSelectSelect(unittest.TestCase):
    def test_no_python_here_waits_with_select_select(self):
        found, kept = [], {}
        for rel in python_files():
            if rel in SKIP:
                continue
            try:
                source = (ROOT / rel).read_text()
            except (OSError, UnicodeDecodeError):
                continue
            if "select" not in source:
                continue
            try:
                import warnings
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore", SyntaxWarning)
                    hits = uses(source, rel)
            except (SyntaxError, ValueError):
                continue  # not this lint's to parse
            if rel in ALLOWED:
                kept[rel] = len(hits)
                if len(hits) <= ALLOWED[rel][0]:
                    continue
            found += [f"{rel}:{line}: {what}" for line, what in hits]
        self.assertEqual(found, [], "select.select() refuses an fd at or above 1024: wait with select.poll() or "
                                   "selectors.DefaultSelector")
        stale = sorted(rel for rel, (n, _) in ALLOWED.items() if kept.get(rel, 0) < n)
        self.assertEqual(stale, [], "ALLOWED keeps more uses than these files have: lower its count")

    def test_the_rule_finds_every_form(self):
        rows = [
            ("import select\nselect.select(fds, [], [], 1)\n", [(2, "select.select")]),
            ("import select as s\ns.select([fd], [], [])\n", [(2, "select.select")]),
            ("from select import select as wait\nwait([fd], [], [], 1)\n",
             [(1, "select.select"), (2, "select.select")]),
            ("import selectors\nselectors.SelectSelector()\n", [(2, "selectors.SelectSelector")]),
            ("import select, selectors\nselect.poll().poll(1)\nselectors.DefaultSelector()\n", []),
            ('X = r"""\nimport select\nselect.select([0], [], [], 1)\n"""\n',
             [(3, "select.select (in a string program)")]),
        ]
        for source, want in rows:
            with self.subTest(source):
                self.assertEqual(uses(source, "x.py"), want)


if __name__ == "__main__":
    unittest.main()
