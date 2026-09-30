#!/usr/bin/env python3
"""CI guard for ./scripts/check-cli-contract-verbs.py.

The guarded property: every verb the top-level command switch dispatches has a
row in `docs/cli-contract.md`. An agent-reachability audit read that table,
found no `layout` row, and concluded saved layouts were unreachable from the
CLI; `cmux layout` had shipped all along. The negative cases below are what keep
the guard from rotting into a no-op, because a guard that parses source has two
ways to go quiet: an anchor it can no longer find, and a case shape it cannot
read.

Cases:
  (a) The real cmux checkout passes.
  (b) A minimal fixture passes.
  (c) A dispatched verb with no row fails, named with its line number.
  (d) An alias sharing a case arm with a documented verb is checked on its own.
  (e) A verb documented in a family table below the top-level table passes. This
      is the tmux compatibility set, which lives in its own table; reading only
      the top-level section reported 23 verbs as undocumented.
  (f) Renaming `func run()` fails loudly instead of finding no verbs.
  (g) Removing `switch command {` fails the same way.
  (h) An unclosed switch fails instead of running off the end of the file.
  (i) A case pattern that is not a list of string literals fails by name, so a
      new pattern shape cannot silently drop its verbs.
  (j) A comma-separated pattern split over several lines is read as one arm.
  (k) A `:` inside a string literal does not truncate the pattern.
  (l) Subcommand switches elsewhere in the file are not read as top-level verbs.
  (m) A contract with no top-level table heading fails.
  (n) A contract with no table rows at all fails.
"""

import os
import subprocess
import sys
import tempfile

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD = os.path.join(ROOT_DIR, "scripts", "check-cli-contract-verbs.py")
CLI_RELATIVE = os.path.join("CLI", "cmux.swift")
DOC_RELATIVE = os.path.join("docs", "cli-contract.md")

FIXTURE_CLI = """\
struct CMUXCLI {
    func helper() throws {
        switch subcommand {
        case "not-a-top-level-verb":
            try runHelper()
        default:
            break
        }
    }

    func run() async throws {
        let command = commandName
        switch command {
        case "ping":
            print(try sendV1Command("ping"))
        case "layout":
            try runLayoutNamespace()
        case "rename-workspace", "rename-window":
            try runRenameWorkspace()
        default:
            throw CLIError(message: "unknown command")
        }
    }

    func trailing() throws {
        switch other {
        case "also-not-top-level":
            break
        default:
            break
        }
    }
}
"""

FIXTURE_DOC = """\
# CLI Contract

## Top-Level Commands

| Command | Contract |
| --- | --- |
| `ping` | Check socket connectivity. |
| `layout` | Saved workspace layouts. |
| `rename-workspace`, `rename-window` | Rename a workspace. |

## Command Families

| Command | Contract |
| --- | --- |
| `capture-pane` | tmux compatibility. |
"""


def write_text(path, contents):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(contents)


def make_fixture_root(directory, case, cli=FIXTURE_CLI, doc=FIXTURE_DOC):
    """Writes one case's fixture checkout and returns its root."""
    root = os.path.join(directory, case)
    write_text(os.path.join(root, CLI_RELATIVE), cli)
    write_text(os.path.join(root, DOC_RELATIVE), doc)
    return root


def run_guard(root):
    return subprocess.run(
        [sys.executable, GUARD, "--root", root],
        cwd=ROOT_DIR,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )


def expect_pass(root, case, *needles):
    result = run_guard(root)
    assert result.returncode == 0, "{0}: expected pass, got:\n{1}".format(
        case, result.stdout
    )
    for needle in needles:
        assert needle in result.stdout, "{0}: missing {1!r} in:\n{2}".format(
            case, needle, result.stdout
        )


def expect_failure(root, case, *needles):
    result = run_guard(root)
    assert result.returncode == 1, "{0}: expected failure, got:\n{1}".format(
        case, result.stdout
    )
    for needle in needles:
        assert needle in result.stdout, "{0}: missing {1!r} in:\n{2}".format(
            case, needle, result.stdout
        )


def case_a_real_repo():
    expect_pass(ROOT_DIR, "case a", "check-cli-contract-verbs: ok")


def case_b_fixture_baseline(tmp):
    expect_pass(make_fixture_root(tmp, "case-b"), "case b", "4 dispatched verbs")


def case_c_undocumented_verb(tmp):
    cli = FIXTURE_CLI.replace(
        '        case "layout":',
        '        case "canvas":\n            try runCanvasNamespace()\n        case "layout":',
    )
    root = make_fixture_root(tmp, "case-c", cli=cli)
    expect_failure(root, "case c", "top-level verb canvas", "CLI/cmux.swift:16")


def case_d_alias_checked_separately(tmp):
    doc = FIXTURE_DOC.replace(
        "| `rename-workspace`, `rename-window` | Rename a workspace. |",
        "| `rename-workspace` | Rename a workspace. |",
    )
    root = make_fixture_root(tmp, "case-d", doc=doc)
    expect_failure(root, "case d", "top-level verb rename-window")


def case_e_family_table_counts(tmp):
    """A verb documented only in the family table is documented."""
    cli = FIXTURE_CLI.replace(
        '        case "layout":',
        '        case "capture-pane":\n            try runTmuxCompat()\n        case "layout":',
    )
    expect_pass(make_fixture_root(tmp, "case-e", cli=cli), "case e")


def case_f_renamed_run(tmp):
    cli = FIXTURE_CLI.replace("func run() async throws {", "func dispatch() async throws {")
    root = make_fixture_root(tmp, "case-f", cli=cli)
    expect_failure(root, "case f", "could not locate `func run() async throws`")


def case_g_renamed_switch(tmp):
    cli = FIXTURE_CLI.replace(
        "        switch command {\n        case \"ping\":",
        "        switch commandName {\n        case \"ping\":",
    )
    root = make_fixture_root(tmp, "case-g", cli=cli)
    expect_failure(root, "case g", "could not locate `switch command {`")


def case_h_unclosed_switch(tmp):
    """A truncated file stops the guard instead of reading to the end."""
    cli = FIXTURE_CLI.split('        case "rename-workspace"')[0]
    root = make_fixture_root(tmp, "case-h", cli=cli)
    expect_failure(root, "case h", "is never closed")


def case_i_unreadable_pattern(tmp):
    cli = FIXTURE_CLI.replace(
        '        case "layout":',
        '        case let other where other.hasPrefix("x"):\n            try runOther()\n        case "layout":',
    )
    root = make_fixture_root(tmp, "case-i", cli=cli)
    expect_failure(root, "case i", "case pattern(s) this guard cannot read", "line 16")


def case_j_multiline_pattern(tmp):
    cli = FIXTURE_CLI.replace(
        '        case "rename-workspace", "rename-window":',
        '        case "rename-workspace",\n             "rename-window",\n             "resize-pane":',
    )
    root = make_fixture_root(tmp, "case-j", cli=cli)
    expect_failure(root, "case j", "top-level verb resize-pane", "CLI/cmux.swift:18")


def case_k_colon_inside_literal(tmp):
    """The pattern ends at the arm's `:`, not at one inside a literal."""
    cli = FIXTURE_CLI.replace(
        '        case "layout":',
        '        case "ws:layout", "layout":',
    )
    root = make_fixture_root(tmp, "case-k", cli=cli)
    expect_failure(root, "case k", "top-level verb ws:layout")


def case_l_subcommand_switches_ignored(tmp):
    """Case l is the baseline's other switches: neither reaches the count."""
    result = run_guard(make_fixture_root(tmp, "case-l"))
    assert "not-a-top-level-verb" not in result.stdout, result.stdout
    assert "also-not-top-level" not in result.stdout, result.stdout
    assert "4 dispatched verbs" in result.stdout, result.stdout


def case_m_missing_heading(tmp):
    doc = FIXTURE_DOC.replace("## Top-Level Commands", "## Commands")
    root = make_fixture_root(tmp, "case-m", doc=doc)
    expect_failure(root, "case m", "could not locate `## Top-Level Commands`")


def case_n_no_table_rows(tmp):
    doc = "# CLI Contract\n\n## Top-Level Commands\n\nSee the app's help output.\n"
    root = make_fixture_root(tmp, "case-n", doc=doc)
    expect_failure(root, "case n", "parsed as having no table rows")


def main():
    with tempfile.TemporaryDirectory(prefix="cli-contract-verb-guard-") as tmp:
        case_a_real_repo()
        case_b_fixture_baseline(tmp)
        case_c_undocumented_verb(tmp)
        case_d_alias_checked_separately(tmp)
        case_e_family_table_counts(tmp)
        case_f_renamed_run(tmp)
        case_g_renamed_switch(tmp)
        case_h_unclosed_switch(tmp)
        case_i_unreadable_pattern(tmp)
        case_j_multiline_pattern(tmp)
        case_k_colon_inside_literal(tmp)
        case_l_subcommand_switches_ignored(tmp)
        case_m_missing_heading(tmp)
        case_n_no_table_rows(tmp)
    print("test_ci_cli_contract_verb_guard: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
