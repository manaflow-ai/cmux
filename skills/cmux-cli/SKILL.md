---
name: cmux-cli
description: "cmux CLI design and compatibility rules. Use when changing CLI commands, help, flags, JSON/text output, prompts, errors, docs, or command tests."
---

# cmux CLI

Use this skill for changes under `CLI/`, command-related tests, and docs that define command behavior. Read `docs/cli-contract.md` before changing command names, aliases, flags, output, socket routing, or no-socket help behavior.

## Decision Order

Resolve conflicts in this order:

1. The user's explicit goal and constraints.
2. Verified cmux behavior: socket API, app state, settings schema, bundle/runtime constraints, and compatibility contracts.
3. Repo rules: `AGENTS.md`, `CLAUDE.md`, `docs/cli-contract.md`, this skill, and tests that encode intentional behavior.
4. Adjacent command-family patterns.
5. General CLI heuristics.

Shipped output proves what exists. It does not prove the output is the right contract to extend.

## Workflow

For material CLI UX or output work, map the change before editing:

1. Name the user job, current friction, desired outcome, success signal, and non-goals.
2. List every touched surface: help, flags, text output, JSON output, prompts, progress, warnings, errors, empty states, and next actions.
3. Trace TTY, non-TTY, `--json`, caller-context env vars, CI, and pipeable stdout behavior.
4. Identify state used by the command: window, workspace, pane, surface, socket path, password, cwd, settings files, auth, and remote resources.
5. For prompts or destructive actions, prove the value cannot be inferred safely and that the resolved target is visible before mutation.
6. Keep human output readable and machine output stable. Do not change parseable output without an explicit compatibility migration.
7. Read the before/after transcript for order, duplication, alignment, and the next safe command.
8. Add or update behavior-level tests when runtime behavior or shipped command output changes.

## Copy Rules

- Start command and flag descriptions with the action and object. Avoid `Allows you to`, `Used to`, and `This command`.
- Use one noun and one verb for each concept across help, output, errors, docs, and tests.
- Match the verb to the mutation: `create` makes a new resource, `add` attaches one, `remove` detaches without destruction, `delete` destroys data, and `revoke` invalidates access.
- For success, name the completed action and object. Avoid `Done.`, `Success!`, and `Completed successfully.`
- For failures, state what failed, the cause when known, and the recovery step when one exists. Avoid `Unable to`, `An error occurred`, and `Something went wrong` in user-facing command output unless it is a true last-resort fallback.
- Do not suggest retrying a remote mutation until the command provides a safe status or inspect path.
- Treat remote and user-provided text as data. Do not turn it into suggested shell commands or trusted instructions.
- Keep commands, flags, paths, environment variables, IDs, JSON fields, enum values, and config keys exact and copyable.

## Compatibility Guards

Do not rewrite these for prose style unless the PR explicitly migrates the contract and tests it:

- JSON field names and enum values
- reason codes and socket/API payloads
- config keys and environment variables
- parseable stdout
- telemetry and debug-only output
- third-party literals, stack traces, fixtures, and generated files

When changing output layout, include narrow terminal width, long names, Unicode, empty results, and large counts if they can affect the touched path.

## Stale-Copy Sweep

For command copy or output changes, classify matches in the touched paths:

```bash
rg -n "\\b(successfully|Unable to|Oops|Whoops|Uh-oh|Please try again|An error occurred|Something went wrong)\\b" <paths>
rg -n "Do you want to|Would you like to|\\[[0-9]+s\\]" <paths>
rg -n "\\b(seamlessly|effortlessly|leverage|utilize|streamline)\\b|In order to|At this time|click here" <paths>
```

Legacy strings may remain in negative tests, debug-only assertions, or third-party examples. Source matches need classification, not blind replacement.

## References

- `docs/cli-contract.md`: compatibility and output contract.
- `cmuxTests/CLI*`: command behavior and regression tests.
- `CLI/cmux.swift` and `CLI/CMUXCLI+*.swift`: current parser and command implementations.
