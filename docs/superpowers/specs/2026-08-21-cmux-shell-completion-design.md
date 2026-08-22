# cmux Shell Completion Design

Date: 2026-08-21
Status: Approved for implementation planning
Branch: `feature/cmux-shell-autocomplete`

## Goal

Ship shell autocompletion for the `cmux` CLI in zsh, bash, and fish. Completion
covers commands, subcommands, and flag names, and also completes live cmux
entities: workspace, surface, window, pane, and tab refs, theme names, and VM
ids.

## Background

`CLI/cmux.swift` is a hand-rolled parser: 36,795 lines in one file, 71,756 lines
across 126 files in `CLI/`, dispatching 484 `case` arms. The CLI surface is
described in three places that are maintained by hand and can disagree:

- the dispatch `switch` in `CLI/cmux.swift`,
- `CMUXCLI.topLevelCommandNames` in `CLI/CMUXCLI+CommandSuggestions.swift`, a
  flat `Set<String>` used only for typo suggestions,
- the `usage()` string literal at `CLI/cmux.swift:36550`.

`docs/cli-contract.md` is the behavior contract for this CLI and already
prescribes a migration to Swift ArgumentParser, with a six-step sequence and a
guard test at `tests/test_cli_contract_help.py`.

Two facts make that migration the right foundation for completion rather than a
detour:

- swift-argument-parser 1.8.2 is already a resolved dependency of
  `Packages/Shared/CmuxAPIClient`, so adding it costs no new third-party review.
- ArgumentParser provides `--generate-completion-script bash|zsh|fish` and
  `CompletionKind.custom` natively. Completion quality depends only on the
  declared command tree, not on whether a command's implementation was
  rewritten.

That second point is the load-bearing one. A command struct whose `run()` simply
calls the existing `CMUXCLI` runner completes exactly as well as a fully migrated
one. So the parse-only facade, step 3 of the documented sequence, is the part
that buys completion. Steps 4 and 5, moving implementations family by family,
buy code health and are explicitly out of scope here.

## Decisions

Settled during brainstorming, recorded so the plan does not relitigate them:

| Decision | Choice |
| --- | --- |
| Completion scope | Commands, subcommands, flags, and live refs |
| Shells | zsh, bash, fish |
| Foundation | Migrate to ArgumentParser first, parse-only facade |
| Phasing | Declare the whole command tree in one pass |
| Install | Print script to stdout; user adds an `eval` line |
| Localization | Localize all abstracts and option help in this PR |

## Scope

In scope:

- A parse-only ArgumentParser facade declaring the full command tree.
- `cmux completion <shell>` and dynamic completion handlers.
- A generated, committed snapshot of the CLI surface.
- Contract, parity, script-syntax, and handler tests.
- README and `docs/cli-contract.md` updates, and a `cmux docs` topic.
- Localization of command abstracts and option help.

Out of scope, deferred to a separate spec:

- Migrating command *implementations* out of `CMUXCLI` (documented sequence
  steps 4 and 5).
- Deleting the hand-rolled parser (step 6), deferred one release; see Rollout.
- Any change to `CmuxCLIPathInstaller` or the command palette.

## Architecture

### Entry point

`CMUXTermMain.main()` (`CLI/cmux.swift:36777`) keeps ownership of SIGPIPE setup,
stdio configuration, and error-to-exit-code mapping. It delegates parsing to a
new root `CmuxCommand: ParsableCommand`. Command declarations and their `run()`
methods stay synchronous, matching `parseAsRoot()` and `runFacade()`'s
synchronous flow; adopt `AsyncParsableCommand` only if the whole facade and
`CMUXTermMain.main()` are explicitly converted to async.

Each leaf command struct's `run()` constructs the same `CMUXCLI` and calls the
runner method that handles it today. `CMUXCLI` keeps all of its behavior. Only
argument parsing moves. This is what makes a one-pass declaration reviewable: the
diff is additive declarations plus deletions from the manual parser, not
rewritten logic.

### File layout

New directory `CLI/Commands/`, one file per command family, mirroring the
existing `CMUXCLI+Family.swift` split:

```
CLI/Commands/CmuxCommand.swift           root tree and global options
CLI/Commands/VMCommands.swift
CLI/Commands/BrowserCommands.swift
CLI/Commands/TmuxCompatCommands.swift
CLI/Commands/HookCommands.swift
...
CLI/Commands/CompletionCandidates.swift  dynamic completion handlers
```

Standing rule for `CLI/Commands/`: declaration and delegation only, no business
logic. The directory then reads as a specification of the CLI surface, which is
what makes it reviewable and what keeps future changes visible.

### Contract behaviors ArgumentParser does not provide

Three behaviors in `docs/cli-contract.md` have no native equivalent. Each needs
an explicit mechanism and a named test, because these are where a one-pass
migration silently breaks things.

**1. Bare path invocation.** `cmux <path>` opens a directory or file parent
through the app's file-open path, without control-socket access, resolving
relative paths from the working directory. It is not a subcommand. A pre-parse
check in `main()` routes to the existing open path when the first non-global
argument is not a declared subcommand name.

**2. Presentation options before or after the command.** `--json` and
`--id-format` are accepted on either side of the command name; `--socket`,
`--password`, and `--window` are global options before the command.
ArgumentParser handles the trailing form per-subcommand. For the leading form, a
small pre-parse pass lifts recognized global options out of `argv` before
ArgumentParser sees the remainder, preserving today's precedence: `--password`,
then `CMUX_SOCKET_PASSWORD`, then the password saved in Settings.

**3. Passthrough after `--`.** `cmux vm exec demo -- --help` must not print help;
the forwarded `--help` belongs to the command payload.
`@Argument(parsing: .captureForPassthrough)` on forwarding commands, guarded by
the negative-help probe already recorded in `docs/cli-contract.md`.

### Removing a duplicate list

`CMUXCLI.topLevelCommandNames` stops being a literal `Set<String>` and is derived
from the declared subcommand tree. The typo suggester, the help output, and
completion then cannot disagree, which removes one of the three hand-maintained
lists outright.

Behavior to preserve: `suggestedCommandName(for:)` filters out `__`-prefixed
commands, so the derivation must expose hidden commands to the completion tree
while keeping them out of typo suggestions.

## Completion

### Static completion

`cmux completion <shell>` is a thin declared subcommand wrapping the framework
generator, so the documented UX matches the `eval` line users paste. The
framework's own `--generate-completion-script` flag keeps working.

Hard requirement: `cmux completion <shell>` must succeed with no socket and no
running app. Users run it from `.zshrc` at shell startup, so any dependency on a
live app would break every new shell when cmux is not running.

### Dynamic completion

Value-bearing options get `completion: .custom(handler)`. The shell re-invokes
`cmux` to ask for candidates, and the handler queries the control socket for live
entities.

All handlers live in `CLI/Commands/CompletionCandidates.swift`. Four hard
requirements on every handler, because this code runs on the user's Tab key:

- a short timeout, so completion never hangs a shell,
- an empty array on any failure: no socket, app not running, auth failure,
  malformed response,
- never write to stderr,
- never exit nonzero.

A broken or absent cmux must degrade to no suggestions, never to a hung or noisy
shell. These four are the safety-critical assertions of the whole feature.

### Value kinds

| Argument | Completion |
| --- | --- |
| `--workspace`, `--surface`, `--window`, `--pane`, `--tab` | live refs |
| `themes set <name>` | live theme list |
| `vm <id>`, `cloud <id>` | live VM ids |
| `--cwd`, path arguments | `.directory()` / `.file()` |
| `--direction`, `--id-format`, `--source`, `--layout`, `--type`, and other closed enums | static `.list` |

Refs follow the documented handle format: a UUID, a short ref such as
`workspace:2`, or an index. `tab-action` also accepts `tab:<n>`. Completion
offers refs, matching the documented default output format.

## Verification

### Reviewability of a one-pass tree

A reviewer cannot meaningfully read ~180 command structs against a 723-line
contract. So the PR carries a generated, committed snapshot of the CLI surface:

- a hidden `cmux __dump-command-tree` prints every command, subcommand, option,
  and completion kind in a stable sorted format,
- `docs/cli-command-tree.txt` holds the committed output,
- a test asserts the two match.

Reviewers read the tree rather than the structs, and any future PR that changes
the CLI surface shows it as a diff hunk. This is also the durable answer to
catalog drift: the snapshot cannot rot silently.

### Tests

In the order they catch things:

1. **Contract help probes.** `tests/test_cli_contract_help.py` is the primary
   gate and already encodes the help probes and the negative passthrough probe.
   Extend it to assert every declared subcommand's `--help` works with no
   socket, plus the four "Current Help Caveats" in `docs/cli-contract.md`
   (`version`, `claude-teams`, `codex-teams`, `remote-daemon-status`), which must
   survive verbatim.
2. **Parity.** Assert the declared subcommand set exactly equals today's dispatch
   set, including `__`-prefixed hidden commands and every alias: `cloud`→`vm`,
   `remote`→`remotes`, `login`/`logout`→`auth`, `coderouter`/`cr`, and the legacy
   browser aliases (`open-browser`, `navigate`, `browser-back`, `get-url`,
   `focus-webview`, `is-webview-focused`). Aliases are the likeliest thing to be
   silently dropped in a one-pass rewrite.
3. **Script syntax.** Generate for each shell and check it parses: `bash -n`,
   `zsh -n`, `fish --no-execute`. Cheap, and it catches a class of breakage that
   otherwise only appears in a user's shell.
4. **Dynamic handlers.** Candidates come back against a fake socket. With no
   socket, the handler returns empty, fast, silent, exit 0. That last assertion
   is what protects the Tab key.
5. **Manual dogfood** in zsh, bash, and fish against a tagged build before
   handoff.

Swift test files require a `PBXFileReference` plus a `PBXSourcesBuildPhase` entry
or they are silently skipped while `xcodebuild test` still reports success on
zero tests. `./scripts/lint-pbxproj-test-wiring.sh` covers this.

Tests must assert specific candidate values and specific help text, not merely
non-empty output. A completion test that only checks "some candidates returned"
cannot fail when the tree regresses.

## Rollout

Agent hooks, `claude-teams`, `codex-teams`, and the omo/omx/omc launchers drive
this CLI constantly, so a parsing regression breaks agent workflows quietly
rather than loudly.

The hand-rolled parser stays reachable behind `CMUX_CLI_LEGACY_PARSER=1` for one
release, then is deleted in a follow-up PR. This is step 6 of the documented
migration sequence, deferred by one release in exchange for a rollback that does
not require a new build. The escape hatch is not documented as a public feature;
it is a support lever.

## Install and docs

`cmux completion <shell>` prints to stdout. It writes nothing to user config and
requires no socket.

- README gains the three `eval` lines, one per shell.
- `docs/cli-contract.md` gains `completion` in its top-level command table, help
  probes for the new command, and its migration sequence marked off through step
  3.
- `cmux docs` gains a completion topic.

`CmuxCLIPathInstaller` is untouched and no command palette entry is added, so no
new multi-entrypoint behavior needs keeping in sync.

## Localization

Command abstracts and option help text become user-facing strings surfaced in
completion menus, so they are localized in this PR:
`String(localized: "key", defaultValue: "English")` with keys in
`Resources/Localizable.xcstrings`.

Two facts about the current state:

- `Resources/Localizable.xcstrings` carries 5,078 keys across 20 locales: ar, bs,
  da, de, en, es, fr, it, ja, km, ko, nb, pl, pt-BR, ru, th, tr, uk, zh-Hans,
  zh-Hant.
- `skills/cmux-localization/SKILL.md` says "currently English and Japanese." That
  is stale relative to the file. This spec follows the file, since it is the
  tested artifact. Correcting the skill text is a separate follow-up.

The existing `usage()` output is mostly plain English with a few localized
interpolations (`localizedCoderouterAliases()`,
`cli.browser.profile.option`). Those localized fragments must be preserved as
localized when their commands are declared.

A localization audit is required before handoff: enumerate changed user-facing
surfaces, verify entries exist for every supported locale, compare changed keys
across locales, `rg` the changed Swift files for newly introduced bare English,
and state in the handoff what was audited.

## Risks

| Risk | Mitigation |
| --- | --- |
| One-pass tree hides a behavior regression | Contract probes, parity test including aliases, committed tree snapshot, legacy parser escape hatch |
| Dynamic completion hangs or spams a user's shell | Four hard handler requirements, each with a direct test |
| Global option pre-parse changes precedence | Contract probes cover `--password` precedence and the before/after forms |
| Passthrough after `--` regresses, breaking agent launchers | Negative help probe, plus dogfood of `claude-teams` and `codex-teams` |
| Localization diff swamps the parsing diff | Separate commits within the PR: facade, completion, localization |

## Success criteria

- Tab completion works in zsh, bash, and fish for commands, subcommands, and
  flags.
- Tab completion offers live workspace, surface, window, pane, and tab refs,
  theme names, and VM ids when cmux is running.
- With cmux not running, completion returns nothing, immediately, with no stderr
  output and exit 0.
- `tests/test_cli_contract_help.py` passes unmodified except for additive probes.
- The parity test shows no command or alias lost.
- `docs/cli-command-tree.txt` matches generated output.
- Localization audit reported in the handoff.
