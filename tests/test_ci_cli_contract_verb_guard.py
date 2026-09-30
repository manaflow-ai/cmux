#!/usr/bin/env python3
"""CI guard for ./scripts/check-cli-contract-verbs.py.

The guarded property: every top-level verb `CMUXCLI.run()` dispatches has a row
in `docs/cli-contract.md`. An agent-reachability audit read that table, found no
`layout` row, and concluded saved layouts were unreachable from the CLI; `cmux
layout` had shipped all along.

The negative cases below are what keep the guard from rotting into a no-op,
because a guard that parses source has four ways to go quiet: an anchor it can
no longer find, a case shape it cannot read, a dispatch route it does not look
at, and a brace inside a string that ends its scan early. It also has one way to
pass for the wrong reason: a row in a table that documents something other than
commands.

Cases:
  (a) The real cmux checkout passes.
  (b) A minimal fixture passes, counting both dispatch routes.
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
  (l) A switch nested inside the top-level switch does not contribute verbs,
      nor do switches elsewhere in the file.
  (m) A contract with no top-level table heading fails.
  (n) A contract with no command table rows fails.
  (o) An `if command == "…"` early return before the switch is a dispatched
      verb: `cmux diff` and `cmux version` are routed that way, and a guard
      reading only the switch shipped blind to 45 verbs.
  (p) A brace inside a multiline string literal does not end the switch scan, so
      arms below it are still read.
  (q) A verb name inside a comment or a string is not a dispatched verb.
  (r) A row in a table that is not a command table does not document a verb. The
      `sessions` field of `cmux sessions --json` must not vouch for a verb.
  (s) A switch whose brace count ends somewhere that is not the close of a
      switch fails, instead of silently dropping every arm below it.
"""

import os
import subprocess
import sys
import tempfile

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD = os.path.join(ROOT_DIR, "scripts", "check-cli-contract-verbs.py")
CLI_RELATIVE = os.path.join("CLI", "cmux.swift")
DOC_RELATIVE = os.path.join("docs", "cli-contract.md")

# Every hazard the parsers have to survive, in the shape the real file has it:
# early returns above the switch, a nested switch, a multiline literal holding a
# brace and a line that looks like a case arm, and verb names in comments.
FIXTURE_CLI = '''\
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
        if command == "version" {
            print(versionSummary())
            return
        }
        if command == "diff" { try runDiffCommand(); return }
        // Not dispatched: if command == "commented-early-return" {
        switch command {
        case "ping":
            print(try sendV1Command("ping"))
        case "layout":
            // Not dispatched: case "commented-arm":
            let usage = """
        case "arm-inside-a-multiline-string":
        }
        """
            print(usage)
        case "vm":
            switch commandArgs.first {
            case "nested-not-top-level":
                try runVMList()
            default:
                break
            }
        case "rename-workspace", "rename-window":
            try runRenameWorkspace()
        default:
            throw CLIError(message: "unknown command: } {")
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
'''

FIXTURE_DOC = """\
# CLI Contract

## Top-Level Commands

| Command | Contract |
| --- | --- |
| `version` | Print the CLI version. |
| `diff` | Open a diff viewer panel. |
| `ping` | Check socket connectivity. |
| `layout` | Saved workspace layouts. |
| `vm` | Cloud machine namespace. |
| `rename-workspace`, `rename-window` | Rename a workspace. |

## Command Families

| Command | Contract |
| --- | --- |
| `capture-pane` | tmux compatibility. |

Sessions output:

| Field | Contract |
| --- | --- |
| `sessions` | The limited result set of session records. |
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
    """Five switch arms plus the two early returns."""
    expect_pass(make_fixture_root(tmp, "case-b"), "case b", "7 dispatched verbs")


def case_c_undocumented_verb(tmp):
    cli = FIXTURE_CLI.replace(
        '        case "layout":',
        '        case "canvas":\n            try runCanvasNamespace()\n        case "layout":',
    )
    root = make_fixture_root(tmp, "case-c", cli=cli)
    expect_failure(root, "case c", "top-level verb canvas", "CLI/cmux.swift:22")


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
    expect_pass(make_fixture_root(tmp, "case-e", cli=cli), "case e", "8 dispatched verbs")


def case_f_renamed_run(tmp):
    cli = FIXTURE_CLI.replace("func run() async throws {", "func dispatch() async throws {")
    root = make_fixture_root(tmp, "case-f", cli=cli)
    expect_failure(root, "case f", "could not locate `func run() async throws`")


def case_g_renamed_switch(tmp):
    cli = FIXTURE_CLI.replace(
        '        switch command {\n        case "ping":',
        '        switch commandName {\n        case "ping":',
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
    expect_failure(root, "case i", "case pattern(s) this guard cannot read", "line 22")


def case_j_multiline_pattern(tmp):
    cli = FIXTURE_CLI.replace(
        '        case "rename-workspace", "rename-window":',
        '        case "rename-workspace",\n             "rename-window",\n             "resize-pane":',
    )
    root = make_fixture_root(tmp, "case-j", cli=cli)
    expect_failure(root, "case j", "top-level verb resize-pane", "CLI/cmux.swift:36")


def case_k_colon_inside_literal(tmp):
    """The pattern ends at the arm's `:`, not at one inside a literal."""
    cli = FIXTURE_CLI.replace(
        '        case "layout":',
        '        case "ws:layout", "layout":',
    )
    root = make_fixture_root(tmp, "case-k", cli=cli)
    expect_failure(root, "case k", "top-level verb ws:layout")


def case_l_nested_switches_ignored(tmp):
    """The nested `vm` switch and the two sibling functions add no verbs."""
    result = run_guard(make_fixture_root(tmp, "case-l"))
    for absent in ("nested-not-top-level", "not-a-top-level-verb", "also-not-top-level"):
        assert absent not in result.stdout, result.stdout
    assert "7 dispatched verbs" in result.stdout, result.stdout


def case_m_missing_heading(tmp):
    doc = FIXTURE_DOC.replace("## Top-Level Commands", "## Commands")
    root = make_fixture_root(tmp, "case-m", doc=doc)
    expect_failure(root, "case m", "could not locate `## Top-Level Commands`")


def case_n_no_command_table(tmp):
    """A contract whose command tables are gone fails instead of passing."""
    doc = FIXTURE_DOC.replace("| Command | Contract |", "| Verb | Contract |")
    root = make_fixture_root(tmp, "case-n", doc=doc)
    expect_failure(root, "case n", "no `| Command |` table rows found")


def case_o_early_return_dispatch(tmp):
    """`cmux diff` is routed above the switch and still needs a row."""
    doc = FIXTURE_DOC.replace("| `diff` | Open a diff viewer panel. |\n", "")
    root = make_fixture_root(tmp, "case-o", doc=doc)
    expect_failure(root, "case o", "top-level verb diff", "CLI/cmux.swift:17")


def case_p_brace_in_string_does_not_end_the_scan(tmp):
    """The `}` inside the multiline literal must not close the switch early.

    When it did, every arm below it was dropped and the guard still reported
    success, which is the failure mode a coverage guard cannot have.
    """
    doc = FIXTURE_DOC.replace(
        "| `rename-workspace`, `rename-window` | Rename a workspace. |\n", ""
    )
    root = make_fixture_root(tmp, "case-p", doc=doc)
    expect_failure(root, "case p", "top-level verb rename-workspace")


def case_q_comment_and_string_verbs_ignored(tmp):
    """Verb names in comments and literals are not dispatched verbs."""
    result = run_guard(make_fixture_root(tmp, "case-q"))
    for absent in ("commented-early-return", "commented-arm", "arm-inside-a-multiline-string"):
        assert absent not in result.stdout, result.stdout
    assert result.returncode == 0, result.stdout


def case_r_field_table_does_not_document(tmp):
    """A field row named like a verb does not document that verb."""
    cli = FIXTURE_CLI.replace(
        '        case "layout":',
        '        case "sessions":\n            try runSessionsCommand()\n        case "layout":',
    )
    root = make_fixture_root(tmp, "case-r", cli=cli)
    expect_failure(root, "case r", "top-level verb sessions")


def case_s_switch_end_shape(tmp):
    """Brace counting that walks past the switch fails instead of going quiet."""
    cli = FIXTURE_CLI.replace(
        '            throw CLIError(message: "unknown command: } {")',
        "            if true {\n                throw CLIError(message: \"unknown command\")",
    )
    root = make_fixture_root(tmp, "case-s", cli=cli)
    expect_failure(root, "case s", "does not close `switch command {`")


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
        case_l_nested_switches_ignored(tmp)
        case_m_missing_heading(tmp)
        case_n_no_command_table(tmp)
        case_o_early_return_dispatch(tmp)
        case_p_brace_in_string_does_not_end_the_scan(tmp)
        case_q_comment_and_string_verbs_ignored(tmp)
        case_r_field_table_does_not_document(tmp)
        case_s_switch_end_shape(tmp)
    print("test_ci_cli_contract_verb_guard: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
