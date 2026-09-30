#!/usr/bin/env python3
"""CI guard for ./scripts/check-cli-contract-verbs.py.

The guarded property: every top-level verb `CMUXCLI.run()` dispatches has a row
in `docs/cli-contract.md`. An agent-reachability audit read that table, found no
`layout` row, and concluded saved layouts were unreachable from the CLI; `cmux
layout` had shipped all along.

The negative cases below are what keep the guard from rotting into a no-op,
because a guard that parses source has five ways to go quiet: an anchor it can
no longer find, a case shape it cannot read, a dispatch route it does not look
at, a comparison whose right side is not a literal, and a brace inside a string
that ends its scan early. It also has two ways to pass for the wrong reason: a
row in a table that documents something other than commands, and a table whose
rows it cannot parse at all.

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
  (t) `command == SomeType.someConstant` is a dispatched verb, resolved by
      reading the `static let` in the file declaring that type. Four hidden
      verbs reached main this way while the guard read only literals.
  (u) The same shape with no row fails, named at the constant's own line, which
      is where someone has to look to learn the verb's spelling.
  (v) A `command ==` whose right side is neither a literal nor a resolvable
      constant fails by line instead of being skipped.
  (w) `SomeType(command: command, …)` is a dispatch route: an initializer that
      returns nil for a verb it does not own. Its verbs are read from the file
      declaring the type, by comparison and by its own `switch command`.
  (x) An initializer route whose type declaration cannot be found fails.
  (y) An initializer route whose type names no readable verb fails, rather than
      contributing nothing and passing.
  (z) A lowercase helper taking the same `command:` argument label is a
      predicate, not a route, and demands nothing.
 (aa) A compactly written table (`|Command|Contract|`) counts, and an escaped
      pipe inside a first cell does not cut the row's verb off mid-backtick.
 (ab) A constant route whose named constant is not a readable string in the
      type's file fails, because a renamed constant is a lost verb.
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


def make_fixture_root(directory, case, cli=FIXTURE_CLI, doc=FIXTURE_DOC, extra=None):
    """Writes one case's fixture checkout and returns its root.

    `extra` maps a repository-relative path to its contents, for the cases where
    a verb is named in the file declaring a type rather than at the dispatch.
    """
    root = os.path.join(directory, case)
    write_text(os.path.join(root, CLI_RELATIVE), cli)
    write_text(os.path.join(root, DOC_RELATIVE), doc)
    for relative, contents in (extra or {}).items():
        write_text(os.path.join(root, relative), contents)
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


# The two indirect early routes, in the shape `run()` has them: a comparison
# against a constant declared next to its implementation, and an initializer
# that returns nil for a verb it does not own.
CONSTANT_ROUTE = """\
        if command == HiddenBroker.hiddenCommand {
            Darwin.exit(runHiddenBroker(commandArgs: rawCommandArgs))
        }
"""

CONSTANT_DECLARATION = """\
public struct HiddenBroker {
    public static let hiddenCommand = "__hidden-broker"
}
"""

INITIALIZER_ROUTE = """\
        if let supervisor = try OwnedSupervisor(command: command, arguments: rawCommandArgs) {
            exit(try supervisor.run())
        }
"""

INITIALIZER_DECLARATION = """\
struct OwnedSupervisor {
    init?(command: String, arguments: [String]) throws {
        guard command == "__supervise" || command == "__supervise-app-server" else {
            return nil
        }
        switch command {
        case "__supervise-legacy":
            return nil
        default:
            break
        }
    }
}
"""


def with_early_route(route):
    """Returns the fixture CLI with `route` spliced in above the switch."""
    anchor = "        let command = commandName\n"
    assert anchor in FIXTURE_CLI
    return FIXTURE_CLI.replace(anchor, anchor + route, 1)


def with_rows(doc, *rows):
    """Returns `doc` with extra rows appended to the top-level table."""
    anchor = "| `rename-workspace`, `rename-window` | Rename a workspace. |\n"
    assert anchor in doc
    return doc.replace(anchor, anchor + "".join(rows), 1)


def case_t_constant_route(tmp):
    """A verb named by a constant is dispatched, and resolvable."""
    root = make_fixture_root(
        tmp,
        "case-t",
        cli=with_early_route(CONSTANT_ROUTE),
        doc=with_rows(FIXTURE_DOC, "| `__hidden-broker` | Internal broker. |\n"),
        extra={os.path.join("CLI", "HiddenBroker.swift"): CONSTANT_DECLARATION},
    )
    expect_pass(root, "case t", "8 dispatched verbs")


def case_u_constant_route_undocumented(tmp):
    """The constant's verb with no row fails, named at its declaration."""
    root = make_fixture_root(
        tmp,
        "case-u",
        cli=with_early_route(CONSTANT_ROUTE),
        extra={os.path.join("CLI", "HiddenBroker.swift"): CONSTANT_DECLARATION},
    )
    expect_failure(
        root, "case u", "top-level verb __hidden-broker", "CLI/HiddenBroker.swift:2"
    )


def case_v_unreadable_comparison(tmp):
    """A comparison this guard cannot resolve fails instead of being skipped."""
    root = make_fixture_root(
        tmp,
        "case-v",
        cli=with_early_route(
            "        if command == fallbackCommandName {\n"
            "            try runFallback()\n"
            "            return\n"
            "        }\n"
        ),
    )
    expect_failure(
        root, "case v", "cannot read", "command == fallbackCommandName"
    )


def case_w_initializer_route(tmp):
    """An initializer route's verbs are read from the type's own file."""
    root = make_fixture_root(
        tmp,
        "case-w",
        cli=with_early_route(INITIALIZER_ROUTE),
        doc=with_rows(
            FIXTURE_DOC,
            "| `__supervise` | Internal supervisor. |\n",
            "| `__supervise-app-server` | Internal app server supervisor. |\n",
            "| `__supervise-legacy` | Internal legacy supervisor. |\n",
        ),
        extra={os.path.join("CLI", "OwnedSupervisor.swift"): INITIALIZER_DECLARATION},
    )
    expect_pass(root, "case w", "10 dispatched verbs")


def case_x_initializer_type_missing(tmp):
    """A route whose type cannot be found is an unreadable route."""
    root = make_fixture_root(tmp, "case-x", cli=with_early_route(INITIALIZER_ROUTE))
    expect_failure(root, "case x", "could not find the file declaring", "OwnedSupervisor")


def case_y_initializer_names_no_verb(tmp):
    """A route whose type names no verb fails instead of contributing none."""
    root = make_fixture_root(
        tmp,
        "case-y",
        cli=with_early_route(INITIALIZER_ROUTE),
        extra={
            os.path.join("CLI", "OwnedSupervisor.swift"): (
                "struct OwnedSupervisor {\n"
                "    init?(command: String, arguments: [String]) throws {\n"
                "        guard isSupervisorCommand(command) else { return nil }\n"
                "    }\n"
                "}\n"
            )
        },
    )
    expect_failure(root, "case y", "names no verb this guard can read")


def case_z_lowercase_helper_is_not_a_route(tmp):
    """`runGuideCommand(command:)` is a predicate; it demands no rows."""
    root = make_fixture_root(
        tmp,
        "case-z",
        cli=with_early_route(
            "        if try runGuideCommand(command: command, commandArgs: commandArgs) {\n"
            "            return\n"
            "        }\n"
        ),
    )
    expect_pass(root, "case z", "7 dispatched verbs")


def case_aa_compact_table_and_escaped_pipe(tmp):
    """A compact table counts, and an escaped pipe does not truncate a verb."""
    doc = """\
# CLI Contract

## Top-Level Commands

|Command|Contract|
|---|---|
|`version`|Print the CLI version.|
|`diff`|Open a diff viewer panel.|
|`ping`|Check socket connectivity.|
|`layout`|Saved workspace layouts.|
|`vm restore --from <channel\\|path>`|Cloud machine namespace.|
|`rename-workspace`, `rename-window`|Rename a workspace.|

## Command Families

|Command|Contract|
|---|---|
|`capture-pane`|tmux compatibility.|
"""
    expect_pass(make_fixture_root(tmp, "case-aa", doc=doc), "case aa", "7 dispatched verbs")


def case_ab_constant_not_resolvable(tmp):
    """A route naming a constant the type does not declare fails by name."""
    root = make_fixture_root(
        tmp,
        "case-ab",
        cli=with_early_route(CONSTANT_ROUTE),
        extra={
            os.path.join("CLI", "HiddenBroker.swift"): (
                "public struct HiddenBroker {\n"
                "    public static let hiddenVerb = \"__hidden-broker\"\n"
                "}\n"
            )
        },
    )
    expect_failure(
        root,
        "case ab",
        "HiddenBroker.hiddenCommand",
        "resolved to 0 string constant(s)",
    )


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
        case_t_constant_route(tmp)
        case_u_constant_route_undocumented(tmp)
        case_v_unreadable_comparison(tmp)
        case_w_initializer_route(tmp)
        case_x_initializer_type_missing(tmp)
        case_y_initializer_names_no_verb(tmp)
        case_z_lowercase_helper_is_not_a_route(tmp)
        case_aa_compact_table_and_escaped_pipe(tmp)
        case_ab_constant_not_resolvable(tmp)
    print("test_ci_cli_contract_verb_guard: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
