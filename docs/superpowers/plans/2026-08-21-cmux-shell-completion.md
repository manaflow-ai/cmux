# cmux Shell Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship zsh, bash, and fish autocompletion for the `cmux` CLI, covering commands, subcommands, flags, and live cmux entities (workspace/surface/window/pane/tab refs, theme names, VM ids).

**Architecture:** Introduce a parse-only swift-argument-parser facade in a new `CLI/Commands/` directory. A root `CmuxCommand` declares the full command tree; every leaf's `run()` delegates to the existing `CMUXCLI` runner method, so no command implementation is rewritten. Completion then falls out of the declared tree: static scripts from the framework generator, live values from `CompletionKind.custom` handlers that query the control socket. The hand-rolled parser stays reachable behind `CMUX_CLI_LEGACY_PARSER=1` for one release.

**Tech Stack:** Swift 6, swift-argument-parser 1.8.2, Xcode project (`cmux.xcodeproj`, target `cmux-cli`), XCTest/Swift Testing in `cmuxTests/`, Python contract harness in `tests/`.

**Spec:** `docs/superpowers/specs/2026-08-21-cmux-shell-completion-design.md`

---

## Global Constraints

These apply to every task. Do not restate them per task; do not violate them.

- **Build with a tag, always.** `./scripts/reload.sh --tag shell-completion`. Never run bare `xcodebuild` or `open` an untagged `cmux DEV.app`.
- **Built CLI binary path:** `/tmp/cmux-shell-completion/Build/Products/Debug/cmux`. Export it as `CMUX_CLI_BIN` for the Python contract harness.
- **Contract harness command:** `CMUX_CLI_BIN=/tmp/cmux-shell-completion/Build/Products/Debug/cmux python3 tests/test_cli_contract_help.py`. It exits 0 on pass and prints `PASS: N CLI help contract probes...`.
- **Swift unit tests:** `./scripts/test-unit.sh test -only-testing:cmuxTests/<ClassName>/<methodName>` (scheme `cmux-unit`).
- **Every new Swift file needs four pbxproj entries** or it is silently not compiled: a `PBXBuildFile`, a `PBXFileReference`, a group membership entry, and a `Sources` build-phase entry. For CLI files the target Sources phase is `B9000006A1B2C3D4E5F60719` (target `cmux-cli`, id `B9000005A1B2C3D4E5F60719`) and the CLI group entry list is around `cmux.xcodeproj/project.pbxproj:7798`. Copy the shape of `CMUXCLI+CommandSuggestions.swift`, which appears at pbxproj lines 662, 3531, 7798, and 10880.
- **Test files need the same wiring** in the test target or `xcodebuild test` reports success on zero tests. Verify with `./scripts/lint-pbxproj-test-wiring.sh`.
- **Normalize pbxproj** after editing: the pre-commit hook runs `scripts/normalize-pbxproj.py`; verify with `./scripts/check-pbxproj.sh`.
- **Never gitignore `Package.resolved`.** Commit resolution changes; verify with `python3 scripts/check-package-resolved-policy.py`.
- **Localize every user-facing string:** `String(localized: "key.name", defaultValue: "English text")` with keys in `Resources/Localizable.xcstrings`. That file currently holds 5,078 keys across 20 locales: ar, bs, da, de, en, es, fr, it, ja, km, ko, nb, pl, pt-BR, ru, th, tr, uk, zh-Hans, zh-Hant.
- **`CLI/Commands/` contains declaration and delegation only.** No business logic. Any real work belongs in a `CMUXCLI` runner method that already exists.
- **Never regress a contract probe.** `docs/cli-contract.md` is the authority. Probes may be added; existing probe lines may not be edited or deleted.
- **Commit after every task.** Use `git add <exact paths>`, never `git add -A`.
- **Never use bare `git stash` / `git stash pop`** — the stash stack is shared across worktrees.

### Family Declaration Recipe

Tasks 6 through 16 each declare one command family. Every one of them follows this recipe exactly. It is stated once here rather than repeated in each task.

For each command in the family's inventory:

1. Find its dispatch arm in `CLI/cmux.swift` (search `case "<command-name>"`) and note the runner method it calls and the exact parameters it passes.
2. Find its line in the `usage()` string literal (`CLI/cmux.swift:36550`–`36767`). That line is the authoritative flag list. Every flag shown there gets declared.
3. Write a struct in the family's file:

```swift
struct ListWorkspaces: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-workspaces",
        abstract: String(
            localized: "cli.command.listWorkspaces.abstract",
            defaultValue: "List workspaces in a window."
        )
    )

    @OptionGroup var globals: GlobalOptions

    @Option(
        name: .customLong("window"),
        help: String(
            localized: "cli.option.window.help",
            defaultValue: "Target window as id, ref, or index."
        ),
        completion: .custom(CompletionCandidates.windows)
    )
    var window: String?

    func run() throws {
        let cli = try globals.makeCLI()
        try cli.runListWorkspaces(
            windowOverride: window,
            jsonOutput: globals.json,
            idFormat: globals.idFormat
        )
    }
}
```

4. Register it in the family's `subcommands:` array, and register the family in `CmuxCommand`.
5. Apply completion kinds by argument name, per this table. No exceptions, no judgment calls:

| Argument name | Completion kind |
| --- | --- |
| `--workspace` | `.custom(CompletionCandidates.workspaces)` |
| `--surface` | `.custom(CompletionCandidates.surfaces)` |
| `--window` | `.custom(CompletionCandidates.windows)` |
| `--pane`, `--target-pane` | `.custom(CompletionCandidates.panes)` |
| `--panel` | `.custom(CompletionCandidates.panels)` |
| `--tab` | `.custom(CompletionCandidates.tabs)` |
| `--cwd`, `--path`, `--out`, `--identity` | `.directory()` for `--cwd`, else `.file()` |
| Closed enum (`--direction`, `--id-format`, `--source`, `--layout`, `--type`, `--transport`, `--sort`, `--format`) | `.list([...])` with the exact values from the `usage()` line |
| Free text (`--title`, `--body`, `--name`, `--command`) | no completion kind |

6. Regenerate the tree snapshot and review its diff (see Task 2).

Aliases are declared with `CommandConfiguration(aliases:)`, not as duplicate structs.

---

### Task 1: ArgumentParser dependency and the routing bridge

Adds the dependency and a router that sends declared commands to ArgumentParser and everything else to today's parser. At the end of this task the tree is empty, so 100% of traffic still goes to the legacy parser and behavior is unchanged. That is the point: it proves the bridge is transparent before any command moves.

**Files:**
- Modify: `cmux.xcodeproj/project.pbxproj` (package reference + product dependency for target `cmux-cli`)
- Modify: `cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- Create: `CLI/Commands/CmuxCommand.swift`
- Create: `CLI/Commands/GlobalOptions.swift`
- Modify: `CLI/cmux.swift:36777-36795` (`CMUXTermMain.main()`)

**Interfaces:**
- Consumes: nothing.
- Produces: `CmuxCommand` (root `ParsableCommand`, `static var declaredCommandNames: Set<String>`), `GlobalOptions` (an `@OptionGroup` struct exposing `socket: String?`, `password: String?`, `window: String?`, `json: Bool`, `idFormat: String`, and `func makeCLI() throws -> CMUXCLI`), and the env escape hatch `CMUX_CLI_LEGACY_PARSER`.

- [ ] **Step 1: Add the package dependency**

Add an `XCRemoteSwiftPackageReference` for `https://github.com/apple/swift-argument-parser` pinned to the revision already resolved for `Packages/Shared/CmuxAPIClient`: revision `6a52f3251125d74daf04fcbd5e6f08a75d074382`, version `1.8.2`. Add a matching `XCSwiftPackageProductDependency` for product `ArgumentParser` and list it in the `packageProductDependencies` array of target `cmux-cli` (`cmux.xcodeproj/project.pbxproj:8651`).

- [ ] **Step 2: Verify it resolves and the policy check passes**

Run: `./scripts/reload.sh --tag shell-completion`
Expected: build succeeds.

Run: `python3 scripts/check-package-resolved-policy.py`
Expected: exit 0.

- [ ] **Step 3: Write `GlobalOptions`**

Create `CLI/Commands/GlobalOptions.swift`:

```swift
import ArgumentParser
import Foundation

struct GlobalOptions: ParsableArguments {
    @Option(name: .customLong("socket"), help: .hidden)
    var socket: String?

    @Option(name: .customLong("password"), help: .hidden)
    var password: String?

    @Option(name: .customLong("window"), help: .hidden)
    var window: String?

    @Flag(name: .customLong("json"))
    var json: Bool = false

    @Option(name: .customLong("id-format"), completion: .list(["refs", "uuids", "both"]))
    var idFormat: String = "refs"

    /// Builds the CLI with the same precedence the hand-rolled parser uses:
    /// --password, then CMUX_SOCKET_PASSWORD, then the password saved in Settings.
    func makeCLI() throws -> CMUXCLI {
        CMUXCLI(
            args: CommandLine.arguments,
            initialSIGPIPEInspectionPayload: CMUXCLI.currentSIGPIPEInspectionPayload()
        )
    }
}
```

- [ ] **Step 4: Write the empty root command**

Create `CLI/Commands/CmuxCommand.swift`:

```swift
import ArgumentParser
import Foundation

struct CmuxCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cmux",
        abstract: String(
            localized: "cli.root.abstract",
            defaultValue: "Control cmux via Unix socket."
        ),
        subcommands: []
    )

    /// Every command name and alias the facade owns. The router sends only these
    /// to ArgumentParser; everything else falls through to the legacy parser.
    static var declaredCommandNames: Set<String> {
        var names: Set<String> = []
        for subcommand in configuration.subcommands {
            let config = subcommand.configuration
            if let name = config.commandName { names.insert(name) }
            names.formUnion(config.aliases)
        }
        return names
    }
}
```

- [ ] **Step 5: Wire the router into `main()`**

Replace the body of `CMUXTermMain.main()` at `CLI/cmux.swift:36779`. Keep SIGPIPE setup and error mapping exactly as they are; only add the routing decision:

```swift
static func main() {
    let initialSIGPIPEInspectionPayload = CMUXCLI.currentSIGPIPEInspectionPayload()
    _ = signal(SIGPIPE, SIG_DFL)
    configureCLIStdioNoSIGPIPE()

    if shouldUseFacade() {
        CmuxCommand.runFacade()
        return
    }

    let cli = CMUXCLI(
        args: CommandLine.arguments,
        initialSIGPIPEInspectionPayload: initialSIGPIPEInspectionPayload
    )
    do {
        try cli.run()
    } catch {
        CMUXCLIOutput.writeStandardError("Error: \(error)\n")
        let exitCode = (error as? CLIError)?.exitCode ?? 1
        exit(exitCode)
    }
}

/// The facade owns an invocation only when the first non-global argument names a
/// declared command. Bare paths, undeclared commands, and the legacy escape hatch
/// all stay on the hand-rolled parser.
private static func shouldUseFacade() -> Bool {
    if ProcessInfo.processInfo.environment["CMUX_CLI_LEGACY_PARSER"] == "1" {
        return false
    }
    guard let command = firstNonGlobalArgument(CommandLine.arguments.dropFirst()) else {
        return false
    }
    return CmuxCommand.declaredCommandNames.contains(command)
}
```

Implement `firstNonGlobalArgument(_:)` in the same file. It skips `--socket`, `--password`, `--window`, and `--id-format` together with their values, skips the valueless `--json`, and returns the first remaining token. It returns nil when the arguments run out.

- [ ] **Step 6: Wire the two new files into the pbxproj**

Add `PBXBuildFile`, `PBXFileReference`, CLI group, and `Sources` phase entries for both files, following the `CMUXCLI+CommandSuggestions.swift` shape. Then run `./scripts/check-pbxproj.sh` and expect exit 0.

- [ ] **Step 7: Prove the bridge is transparent**

Run: `./scripts/reload.sh --tag shell-completion`
Expected: build succeeds.

Run: `CMUX_CLI_BIN=/tmp/cmux-shell-completion/Build/Products/Debug/cmux python3 tests/test_cli_contract_help.py`
Expected: `PASS`, with the same probe count as before this task. Nothing routes to the facade yet, so any failure here is a bug in the router, not in a command.

- [ ] **Step 8: Commit**

```bash
git add cmux.xcodeproj/project.pbxproj \
        cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved \
        CLI/Commands/CmuxCommand.swift \
        CLI/Commands/GlobalOptions.swift \
        CLI/cmux.swift
git commit -m "feat(cli): add ArgumentParser facade routing bridge"
```

---

### Task 2: Command tree snapshot

A reviewer cannot read ~180 command structs against a 723-line contract. This produces the artifact they read instead, and it is the durable answer to catalog drift.

**Files:**
- Create: `CLI/Commands/CommandTreeDump.swift`
- Create: `docs/cli-command-tree.txt`
- Create: `tests/test_cli_command_tree_snapshot.py`

**Interfaces:**
- Consumes: `CmuxCommand` from Task 1.
- Produces: hidden command `cmux __dump-command-tree`, and `docs/cli-command-tree.txt` as the committed snapshot every later task regenerates.

- [ ] **Step 1: Write the failing snapshot test**

Create `tests/test_cli_command_tree_snapshot.py`:

```python
#!/usr/bin/env python3
"""Asserts docs/cli-command-tree.txt matches `cmux __dump-command-tree`.

The snapshot is how CLI surface changes stay reviewable: any command, flag, or
completion-kind change shows up as a diff hunk in this file.
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def main() -> int:
    cli = os.environ.get("CMUX_CLI_BIN")
    if not cli or not os.access(cli, os.X_OK):
        print("FAIL: set CMUX_CLI_BIN to the built cmux binary")
        return 1

    proc = subprocess.run(
        [cli, "__dump-command-tree"],
        text=True, capture_output=True, check=False, timeout=30.0,
    )
    if proc.returncode != 0:
        print(f"FAIL: __dump-command-tree exited {proc.returncode}\n{proc.stderr}")
        return 1

    snapshot = repo_root() / "docs" / "cli-command-tree.txt"
    expected = snapshot.read_text(encoding="utf-8")
    if proc.stdout != expected:
        print(
            "FAIL: CLI command tree drifted from docs/cli-command-tree.txt\n"
            f"Regenerate with: {cli} __dump-command-tree > {snapshot}"
        )
        return 1

    print(f"PASS: CLI command tree matches snapshot ({len(expected.splitlines())} lines)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Run it to verify it fails**

Run: `CMUX_CLI_BIN=/tmp/cmux-shell-completion/Build/Products/Debug/cmux python3 tests/test_cli_command_tree_snapshot.py`
Expected: FAIL, because `__dump-command-tree` does not exist yet.

- [ ] **Step 3: Implement the dump command**

Create `CLI/Commands/CommandTreeDump.swift` declaring `struct DumpCommandTree: ParsableCommand` with `commandName: "__dump-command-tree"` and `shouldDisplay: false`. It walks `CmuxCommand.configuration.subcommands` recursively and prints one line per command and one per argument, sorted, in this stable format:

```
command  <full path>  aliases=<comma-separated or ->
  arg  <name>  kind=<option|flag|argument>  completion=<kind or ->
```

Sort command paths lexicographically and arguments by name within a command, so the output is deterministic across builds. Register it in `CmuxCommand.configuration.subcommands`.

- [ ] **Step 4: Generate the snapshot and verify the test passes**

Run:
```bash
./scripts/reload.sh --tag shell-completion
/tmp/cmux-shell-completion/Build/Products/Debug/cmux __dump-command-tree > docs/cli-command-tree.txt
CMUX_CLI_BIN=/tmp/cmux-shell-completion/Build/Products/Debug/cmux python3 tests/test_cli_command_tree_snapshot.py
```
Expected: PASS. The snapshot holds only `__dump-command-tree` itself at this point.

- [ ] **Step 5: Add the check to CI**

Modify `.github/workflows/ci.yml` next to the existing contract invocation at line 1195, adding:

```yaml
          CMUX_CLI_BIN="$CLI_BIN" python3 tests/test_cli_command_tree_snapshot.py
```

- [ ] **Step 6: Commit**

```bash
git add CLI/Commands/CommandTreeDump.swift docs/cli-command-tree.txt \
        tests/test_cli_command_tree_snapshot.py cmux.xcodeproj/project.pbxproj \
        .github/workflows/ci.yml
git commit -m "feat(cli): add command tree snapshot check"
```

---

### Task 3: `cmux completion <shell>`

Ships the user-visible command early so every later family task improves something already reachable.

**Files:**
- Create: `CLI/Commands/CompletionCommand.swift`
- Create: `tests/test_cli_completion_scripts.py`
- Modify: `docs/cli-contract.md`

**Interfaces:**
- Consumes: `CmuxCommand` from Task 1.
- Produces: `cmux completion <bash|zsh|fish>` writing a completion script to stdout.

- [ ] **Step 1: Write the failing script-syntax test**

Create `tests/test_cli_completion_scripts.py`. For each of `bash`, `zsh`, `fish`, run `cmux completion <shell>` with `CMUX_SOCKET_PATH` forced to a nonexistent socket, then assert all of:

- exit code is 0,
- stdout is non-empty,
- stderr is empty,
- the forced socket path does not appear in the output (proving no socket was consulted),
- the script parses: pipe it to `bash -n`, `zsh -n`, or `fish --no-execute` respectively, and require exit 0,
- the script's generated content includes representative tokens (`list-workspaces`, the nested `browser` family, `--json`), so a script that parses but silently dropped commands still fails.

Skip a shell with a printed notice, not a failure, when that shell is not installed. Print `PASS: N completion scripts generated and parsed` at the end.

- [ ] **Step 2: Run it to verify it fails**

Run: `CMUX_CLI_BIN=/tmp/cmux-shell-completion/Build/Products/Debug/cmux python3 tests/test_cli_completion_scripts.py`
Expected: FAIL, `completion` is not a known command.

- [ ] **Step 3: Implement the command**

Create `CLI/Commands/CompletionCommand.swift`:

```swift
import ArgumentParser
import Foundation

struct Completion: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "completion",
        abstract: String(
            localized: "cli.command.completion.abstract",
            defaultValue: "Print a shell completion script for cmux."
        ),
        discussion: String(
            localized: "cli.command.completion.discussion",
            defaultValue: """
            Add the matching line to your shell startup file:
              zsh:  eval "$(cmux completion zsh)"
              bash: eval "$(cmux completion bash)"
              fish: cmux completion fish | source
            """
        )
    )

    @Argument(
        help: String(
            localized: "cli.command.completion.shell.help",
            defaultValue: "Shell to generate a script for."
        ),
        completion: .list(["bash", "zsh", "fish"])
    )
    var shell: String

    func run() throws {
        guard let kind = CompletionShell(rawValue: shell) else {
            throw CLIError(
                message: "Unsupported shell '\(shell)'. Supported: bash, zsh, fish.",
                exitCode: 2
            )
        }
        print(CmuxCommand.completionScript(for: kind))
    }
}
```

Register `Completion.self` in `CmuxCommand.configuration.subcommands`.

- [ ] **Step 4: Run the test to verify it passes**

Run:
```bash
./scripts/reload.sh --tag shell-completion
CMUX_CLI_BIN=/tmp/cmux-shell-completion/Build/Products/Debug/cmux python3 tests/test_cli_completion_scripts.py
```
Expected: PASS for every installed shell.

- [ ] **Step 5: Add contract probes**

Inside the `<!-- cli-contract-help-probes:start -->` block in `docs/cli-contract.md`, append:

```
- `cmux completion --help` -> `Print a shell completion script for cmux.`
```

Add `completion` to the top-level command table in the same file.

- [ ] **Step 6: Regenerate the snapshot and run both harnesses**

Run:
```bash
/tmp/cmux-shell-completion/Build/Products/Debug/cmux __dump-command-tree > docs/cli-command-tree.txt
CMUX_CLI_BIN=/tmp/cmux-shell-completion/Build/Products/Debug/cmux python3 tests/test_cli_contract_help.py
CMUX_CLI_BIN=/tmp/cmux-shell-completion/Build/Products/Debug/cmux python3 tests/test_cli_command_tree_snapshot.py
```
Expected: both PASS.

- [ ] **Step 7: Add the script test to CI**

Modify `.github/workflows/ci.yml` alongside the other two, adding `CMUX_CLI_BIN="$CLI_BIN" python3 tests/test_cli_completion_scripts.py`.

- [ ] **Step 8: Commit**

```bash
git add CLI/Commands/CompletionCommand.swift tests/test_cli_completion_scripts.py \
        docs/cli-contract.md docs/cli-command-tree.txt \
        cmux.xcodeproj/project.pbxproj .github/workflows/ci.yml
git commit -m "feat(cli): add cmux completion command"
```

---

### Task 4: Completion candidate safety contract

The four safety requirements come before any live data, because they are what protect the user's Tab key. Build the failure path first, then the success path in Task 5.

**Files:**
- Create: `CLI/Commands/CompletionCandidates.swift`
- Create: `cmuxTests/CLICompletionCandidateSafetyTests.swift`
- Create: `cmuxTests/CLIProcessRunSupport.swift`
- Modify: `cmux.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `GlobalOptions` from Task 1.
- Produces: `enum CompletionCandidates` with static handlers `workspaces`, `surfaces`, `windows`, `panes`, `panels`, `tabs`, `themes`, `vms`, each `([String]) -> [String]`, plus the shared private `fetch(method:mapping:)`; and the test helper `runCLI(_:arguments:environment:) throws -> CLIRunResult` in `cmuxTests/CLIProcessRunSupport.swift`, used by Tasks 4, 5, and 17.

- [ ] **Step 1: Write the failing safety test**

Create `cmuxTests/CLICompletionCandidateSafetyTests.swift`. It invokes the built CLI binary directly, so it needs no mock server. Use `BundledCLITestSupport.bundledCLIPath(for:)` to locate the binary, as `cmuxTests/CLIAuthAliasTests.swift` does.

The test runs `cmux __complete-candidates workspaces` with `CMUX_SOCKET_PATH` pointed at a path that does not exist, and asserts all four safety requirements as separate assertions with distinct failure messages:

```swift
func testCompletionCandidatesDegradeSilentlyWithoutSocket() throws {
    let cliPath = try BundledCLITestSupport.bundledCLIPath(for: Self.self)
    let missingSocket = "/tmp/cmux-completion-absent-\(UUID().uuidString).sock"

    let result = try runCLI(
        cliPath,
        arguments: ["__complete-candidates", "workspaces"],
        environment: ["CMUX_SOCKET_PATH": missingSocket]
    )

    XCTAssertEqual(result.exitCode, 0, "completion must never exit nonzero; a nonzero exit makes the shell beep")
    XCTAssertEqual(result.stdout, "", "completion must offer no candidates when cmux is not running")
    XCTAssertEqual(result.stderr, "", "completion must never write to stderr; it would corrupt the user's prompt")
    // `runCLI` itself enforces a hard deadline (see below), so a hang fails via
    // that timeout rather than a wall-clock elapsed-time assertion here.
}
```

Create the shared helper in its own file, `cmuxTests/CLIProcessRunSupport.swift`, since Task 17 uses it too:

```swift
import Foundation

struct CLIRunResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// Runs the CLI binary to completion with a hard timeout, so a hung invocation
/// fails the test instead of stalling the suite.
func runCLI(
    _ cliPath: String,
    arguments: [String],
    environment: [String: String]
) throws -> CLIRunResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: cliPath)
    process.arguments = arguments

    var env = ProcessInfo.processInfo.environment
    for key in ["CMUX_SOCKET", "CMUX_SOCKET_PASSWORD", "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_TAB_ID"] {
        env.removeValue(forKey: key)
    }
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env.merge(environment) { _, new in new }
    process.environment = env

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    // Await the real completion signal (the termination handler), not a
    // Date()-based elapsed check or a busy-wait poll of `process.isRunning`.
    // Draining the pipes only after that signal, rather than before it,
    // means a child that keeps a pipe open cannot block the deadline from
    // firing.
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    try process.run()

    let deadline = DispatchTime.now() + .seconds(5)
    guard finished.wait(timeout: deadline) == .success else {
        process.terminate()
        if finished.wait(timeout: .now() + .seconds(1)) == .timedOut {
            Darwin.kill(process.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + .seconds(1))
        }
        throw NSError(
            domain: "CLIProcessRunSupport", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "cmux \(arguments.joined(separator: " ")) timed out"]
        )
    }

    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

    return CLIRunResult(
        exitCode: process.terminationStatus,
        stdout: String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
        stderr: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    )
}
```

Wire this file into the test target with the same four pbxproj entries.

- [ ] **Step 2: Wire the test file into the test target**

Add the four pbxproj entries for the test target, then run `./scripts/lint-pbxproj-test-wiring.sh` and expect exit 0.

- [ ] **Step 3: Run the test to verify it fails**

Run: `./scripts/test-unit.sh test -only-testing:cmuxTests/CLICompletionCandidateSafetyTests`
Expected: FAIL, `__complete-candidates` is not a known command.

- [ ] **Step 4: Implement the candidates enum and its debug entry point**

Create `CLI/Commands/CompletionCandidates.swift`:

```swift
import ArgumentParser
import Foundation

/// Candidate providers for dynamic shell completion.
///
/// Every handler runs on the user's Tab key, so all four of these hold without
/// exception: bounded time, empty on any failure, never stderr, never nonzero.
/// A cmux that is broken or not running must degrade to "no suggestions", never
/// to a hung or noisy shell.
enum CompletionCandidates {
    /// Upper bound on a completion round trip. Past this the shell gets nothing.
    private static let timeout: TimeInterval = 0.5

    static func workspaces(_ arguments: [String]) -> [String] {
        fetch(method: "workspace.list") { $0["ref"] as? String }
    }

    // surfaces, windows, panes, panels, tabs, themes, vms follow the same shape
    // with their own method and key; see Task 5 for the method table.

    /// Returns candidates, or an empty array for every failure mode: no socket,
    /// app not running, auth failure, malformed response, or timeout.
    private static func fetch(
        method: String,
        mapping: ([String: Any]) -> String?
    ) -> [String] {
        // Deliberately no error propagation and no logging. See the doc comment.
        return []
    }
}

/// Hidden entry point that lets tests and shell scripts exercise handlers directly.
struct CompleteCandidates: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__complete-candidates",
        shouldDisplay: false
    )

    @Argument var kind: String

    func run() throws {
        let candidates: [String]
        switch kind {
        case "workspaces": candidates = CompletionCandidates.workspaces([])
        case "surfaces": candidates = CompletionCandidates.surfaces([])
        case "windows": candidates = CompletionCandidates.windows([])
        case "panes": candidates = CompletionCandidates.panes([])
        case "panels": candidates = CompletionCandidates.panels([])
        case "tabs": candidates = CompletionCandidates.tabs([])
        case "themes": candidates = CompletionCandidates.themes([])
        case "vms": candidates = CompletionCandidates.vms([])
        default: candidates = []
        }
        for candidate in candidates { print(candidate) }
    }
}
```

Register `CompleteCandidates.self` in `CmuxCommand.configuration.subcommands`. The stub `fetch` returning `[]` is enough to pass this task's test; Task 5 fills it in.

- [ ] **Step 5: Run the test to verify it passes**

Run:
```bash
./scripts/reload.sh --tag shell-completion
./scripts/test-unit.sh test -only-testing:cmuxTests/CLICompletionCandidateSafetyTests
```
Expected: PASS, all four assertions.

- [ ] **Step 6: Regenerate the snapshot and commit**

```bash
/tmp/cmux-shell-completion/Build/Products/Debug/cmux __dump-command-tree > docs/cli-command-tree.txt
git add CLI/Commands/CompletionCandidates.swift \
        cmuxTests/CLICompletionCandidateSafetyTests.swift \
        cmuxTests/CLIProcessRunSupport.swift \
        docs/cli-command-tree.txt cmux.xcodeproj/project.pbxproj
git commit -m "feat(cli): add completion candidate safety contract"
```

---

### Task 5: Live completion candidates over the socket

**Files:**
- Modify: `CLI/Commands/CompletionCandidates.swift`
- Create: `cmuxTests/CLICompletionCandidateLiveTests.swift`

**Interfaces:**
- Consumes: `CompletionCandidates.fetch(method:mapping:)` from Task 4.
- Produces: working handlers returning live refs.

- [ ] **Step 1: Write the failing live test**

Create `cmuxTests/CLICompletionCandidateLiveTests.swift`, modeled on `cmuxTests/CLIAuthAliasTests.swift`. Bind a Unix socket, start a mock server answering `workspace.list` with two workspaces, then run `cmux __complete-candidates workspaces` against it.

Assert the exact candidate values, not merely that output is non-empty:

```swift
XCTAssertEqual(
    result.stdout.split(separator: "\n").map(String.init),
    ["workspace:1", "workspace:2"],
    "completion must offer the refs the app reported, in order"
)
```

Add a second test asserting that a well-formed connection returning an error envelope still yields empty stdout and exit 0, so an authenticated-but-failing app degrades the same way an absent one does.

- [ ] **Step 2: Wire the test file into the test target and run it**

Run: `./scripts/lint-pbxproj-test-wiring.sh` (expect exit 0), then
`./scripts/test-unit.sh test -only-testing:cmuxTests/CLICompletionCandidateLiveTests`
Expected: FAIL, `fetch` still returns `[]`.

- [ ] **Step 3: Implement `fetch` and the handler table**

Replace the stub `fetch` with a real implementation that connects to the resolved socket path, sends the v2 method, waits at most `timeout`, decodes the result array, and maps each element. Every failure path returns `[]`. Wrap the whole body so no error escapes and nothing is written to stderr.

Implement each handler with this method and key table:

| Handler | v2 method | Key |
| --- | --- | --- |
| `workspaces` | `workspace.list` | `ref` |
| `surfaces` | `surface.list` | `ref` |
| `windows` | `window.list` | `ref` |
| `panes` | `pane.list` | `ref` |
| `panels` | `panel.list` | `ref` |
| `tabs` | `tab.list` | `ref` |
| `themes` | `theme.list` | `name` |
| `vms` | `vm.list` | `id` |

Confirm each method name against its existing dispatch arm in `CLI/cmux.swift` before using it; where a command already sends a different method for the same listing, use the one the command already sends.

- [ ] **Step 4: Run both completion test classes to verify they pass**

Run:
```bash
./scripts/reload.sh --tag shell-completion
./scripts/test-unit.sh test -only-testing:cmuxTests/CLICompletionCandidateLiveTests
./scripts/test-unit.sh test -only-testing:cmuxTests/CLICompletionCandidateSafetyTests
```
Expected: PASS for both. The safety class must still pass; live data must not have weakened the degradation path.

- [ ] **Step 5: Commit**

```bash
git add CLI/Commands/CompletionCandidates.swift \
        cmuxTests/CLICompletionCandidateLiveTests.swift \
        cmux.xcodeproj/project.pbxproj
git commit -m "feat(cli): complete live cmux refs, themes, and VM ids"
```

---

### Tasks 6-16: Declare the command tree

Each task declares one family using the **Family Declaration Recipe** in Global Constraints, then ends with the identical five-step verification cycle below. Do not skip the cycle: it is what keeps a one-pass tree honest.

**Per-family verification cycle (every one of Tasks 6-16):**

```bash
./scripts/reload.sh --tag shell-completion
CMUX_CLI_BIN=/tmp/cmux-shell-completion/Build/Products/Debug/cmux python3 tests/test_cli_contract_help.py
/tmp/cmux-shell-completion/Build/Products/Debug/cmux __dump-command-tree > docs/cli-command-tree.txt
git diff docs/cli-command-tree.txt   # review: every command in the inventory present, no others
CMUX_CLI_BIN=/tmp/cmux-shell-completion/Build/Products/Debug/cmux python3 tests/test_cli_command_tree_snapshot.py
```

Expected: contract PASS, snapshot PASS, and a tree diff that adds exactly the family's inventory. Commit with `git commit -m "feat(cli): declare <family> command family"`.

- [ ] **Task 6: Meta and no-socket commands** — `CLI/Commands/MetaCommands.swift`
  Inventory: `welcome`, `docs`, `settings`, `config`, `shortcuts`, `version`, `capabilities`, `ping`, `iroh-diag`, `help`, `reload-config`, `feedback`, `themes`, `__internal_flags`, `__sidebar_footer_icon_balance`.
  Quirks that must be preserved verbatim: `cmux version --help` prints the version summary rather than help, and `cmux settings --help` must print `Usage: cmux settings [open [target]|path|docs|<target>]` and must not print the stale `[open|path|docs|target]` form. Both are asserted by `tests/test_cli_contract_help.py`. `themes set` takes `.custom(CompletionCandidates.themes)`.

- [ ] **Task 7: Auth and accounts** — `CLI/Commands/AuthCommands.swift`
  Inventory: `auth` (subcommands `status`, `login`, `logout`), `login`, `logout`, `ai-accounts` (`list`, `upload`, `remove`).
  `login` and `logout` are top-level aliases that map to `auth login` / `auth logout`; declare them via `aliases:` on the subcommands, and keep `cmux auth` with no subcommand defaulting to `status`.

- [ ] **Task 8: VM and remotes** — `CLI/Commands/VMCommands.swift`
  Inventory: `vm` (`base`, `new`, `ls`, `status`, `snapshot`, `fork`, `restore`, `rm`, `exec`, `shell`, `ssh`, `ssh-info`, `tools`, `ports`, `handoff`, `promote-template`), `cloud` (alias of `vm`), `remotes` with alias `remote` (`list`, `add`, `remove`), `remote-daemon-status`.
  `vm exec <id> -- <command...>` must use `@Argument(parsing: .captureForPassthrough)`; the negative probe `cmux vm exec demo -- --help` must keep exiting nonzero without printing `Usage: cmux vm`. `cmux remote-daemon-status --help` prints status rather than help, per the contract's help caveats. VM id arguments take `.custom(CompletionCandidates.vms)`.

- [ ] **Task 9: Windows** — `CLI/Commands/WindowCommands.swift`
  Inventory: `list-windows`, `current-window`, `new-window`, `focus-window`, `close-window`, `find-window`, `next-window`, `previous-window`, `last-window`, `rename-window`.

- [ ] **Task 10: Workspaces** — `CLI/Commands/WorkspaceCommands.swift`
  Inventory: `list-workspaces`, `new-workspace`, `close-workspace`, `select-workspace`, `current-workspace`, `rename-workspace`, `reorder-workspace`, `reorder-workspaces`, `move-workspace-to-window`, `workspace`, `workspace-action`, `workspace-group`, `move-tab-to-new-workspace`.

- [ ] **Task 11: Panes and surfaces** — `CLI/Commands/SurfaceCommands.swift`
  Inventory: `new-pane`, `new-split`, `new-surface`, `close-surface`, `move-surface`, `split-off`, `reorder-surface`, `focus-pane`, `focus-panel`, `list-panes`, `list-pane-surfaces`, `list-panels`, `drag-surface-to-split`, `surface`, `surface-health`, `surface-resume`, `detach-tab`, `tab-action`, `rename-tab`, `last-pane`, `refresh-surfaces`, `debug-terminals`, `sidebar-state`.
  `tab-action` accepts `tab:<n>` in addition to `surface:<n>`; its `--tab` argument takes `.custom(CompletionCandidates.tabs)`.

- [ ] **Task 12: Browser** — `CLI/Commands/BrowserCommands.swift`
  Inventory: the full `browser` subcommand tree at `CLI/cmux.swift:36718`–`36765` (roughly 60 subcommands from `browser disable` through `browser identify`), plus the legacy top-level aliases `open-browser`, `navigate`, `browser-back`, `browser-forward`, `browser-reload`, `browser-status`, `get-url`, `focus-webview`, `is-webview-focused`, `disable-browser`, `enable-browser`.
  This is the largest family; consider splitting the file by subcommand group if it grows past comfortable reading, keeping all groups registered under the one `browser` command. Each legacy alias must keep printing its documented `Legacy alias for 'cmux browser <x>'` help text, which the contract probes assert. `browser open` and `browser open-split` keep the localized `cli.browser.profile.option` string; `browser design-mode` keeps `cli.browser.designMode.help`.

- [ ] **Task 13: tmux compatibility** — `CLI/Commands/TmuxCompatCommands.swift`
  Inventory: `capture-pane`, `resize-pane`, `pipe-pane`, `wait-for`, `swap-pane`, `break-pane`, `join-pane`, `clear-history`, `set-hook`, `popup`, `bind-key`, `unbind-key`, `copy-mode`, `set-buffer`, `list-buffers`, `paste-buffer`, `respawn-pane`, `display-message`, `read-screen`, `send`, `send-key`, `send-panel`, `send-key-panel`, `__tmux-compat`.
  These dispatch through `runTmuxCompatCommand(command:commandArgs:client:jsonOutput:idFormat:windowOverride:)` at `CLI/cmux.swift:6050`, which takes the command name as a string; each struct passes its own name through. `resize-pane` uses the short flags `-L`, `-R`, `-U`, `-D`; `wait-for` uses `-S`/`--signal`; `display-message` uses `-p`/`--print`.

- [ ] **Task 14: Hooks and agent launchers** — `CLI/Commands/HookCommands.swift`
  Inventory: `hooks`, `setup-hooks`, `uninstall-hooks`, `claude-hook`, `codex-hook`, `feed-hook`, `claude-teams`, `codex-teams`, `codex`, `omo`, `omx`, `omc`, `agent-hibernation`, `coderouter` with alias `cr`, `__codex-teams-watch`, `__codex-teams-app-server-supervisor`.
  Every launcher forwards unparsed arguments to its agent, so all of them need `@Argument(parsing: .captureForPassthrough)`. `cmux claude-teams --help` and `cmux codex-teams --help` are handled by the launcher rather than the help dispatcher, per the contract's help caveats, and must keep behaving that way. `coderouter`/`cr` keeps its localized alias text from `localizedCoderouterAliases()`. `__codex-teams-app-server-supervisor` is handled before normal dispatch at `CLI/cmux.swift:3755` and exits with the supervisor's status; preserve that.

- [ ] **Task 15: Notifications, status, feed, and logging** — `CLI/Commands/NotificationCommands.swift`
  Inventory: `notify`, `list-notifications`, `dismiss-notification`, `mark-notification-read`, `open-notification`, `jump-to-unread`, `clear-notifications`, `feed`, `events`, `log`, `list-log`, `clear-log`, `set-status`, `list-status`, `clear-status`, `set-progress`, `clear-progress`.
  `dismiss-notification` and `mark-notification-read` take mutually exclusive argument groups, shown in `usage()` with `(... | ...)`; model each group and reject invalid combinations with exit code 2, matching today's behavior.

- [ ] **Task 16: Remaining system commands** — `CLI/Commands/SystemCommands.swift`
  Inventory: `open`, `diff`, `markdown`, `memory`, `top`, `tree`, `identify`, `trigger-flash`, `restore`, `restore-session`, `rpc`, `simulator`, `ios`, `mobile`, `ssh`, `ssh-pty-attach`, `ssh-session-attach`, `ssh-session-cleanup`, `ssh-session-end`, `ssh-session-list`, `ssh-tmux`, `mosh`, `mosh-tmux`, `vm-pty-attach`, `vm-pty-connect`, `vm-ssh-attach`, `todo`, `comments`, `sidebar`, `right-sidebar`, `set-app-focus`, `simulate-app-active`, `simulate-sidebar-drag`, `project`.
  `restore`, `simulator`, and `ios` build their usage lines from `restoreCommandUsageLine`, `simulatorCommandUsageLine`, and `iosCommandUsageLine`; reuse those same values as the command abstracts rather than retyping them. `ssh` and `mosh` forward everything after `--` to the remote command, so both need `.captureForPassthrough`. For `cmux restore`, `--surface [id|ref]` defaults to the caller when omitted.

---

### Task 17: Derive `topLevelCommandNames` from the tree

Removes one of the three hand-maintained lists. Only safe once every family is declared.

**Files:**
- Modify: `CLI/CMUXCLI+CommandSuggestions.swift:53-221`
- Create: `cmuxTests/CLICommandSuggestionDerivationTests.swift`

**Interfaces:**
- Consumes: `CmuxCommand.declaredCommandNames` from Task 1.
- Produces: `CMUXCLI.topLevelCommandNames` as a computed property.

- [ ] **Step 1: Write the failing test**

Create `cmuxTests/CLICommandSuggestionDerivationTests.swift` asserting behavior, not just wiring:

```swift
func testUnknownCommandSuggestsNearestDeclaredCommand() throws {
    let cliPath = try BundledCLITestSupport.bundledCLIPath(for: Self.self)
    let result = try runCLI(cliPath, arguments: ["list-workspace"], environment: [:])

    XCTAssertTrue(
        result.stderr.contains("Did you mean 'list-workspaces'?"),
        "typo suggestions must come from the declared tree, not a stale literal list"
    )
    XCTAssertEqual(result.exitCode, 2)
}

func testHiddenCommandsAreNeverSuggested() throws {
    let cliPath = try BundledCLITestSupport.bundledCLIPath(for: Self.self)
    let result = try runCLI(cliPath, arguments: ["_internal_flags"], environment: [:])

    XCTAssertFalse(
        result.stderr.contains("__internal_flags"),
        "hidden __-prefixed commands must stay out of user-facing suggestions"
    )
}
```

- [ ] **Step 2: Run it to verify the second test fails**

Run: `./scripts/test-unit.sh test -only-testing:cmuxTests/CLICommandSuggestionDerivationTests`
Expected: the first test passes against the literal list; the second is the guard for the derivation.

- [ ] **Step 3: Replace the literal with a derivation**

Delete the `static let topLevelCommandNames: Set<String> = [...]` literal at `CLI/CMUXCLI+CommandSuggestions.swift:53-221` and replace it with:

```swift
    static var topLevelCommandNames: Set<String> {
        CmuxCommand.declaredCommandNames
    }
```

Leave `suggestedCommandName(for:)` unchanged: it already filters `__`-prefixed names, which is what keeps hidden commands out of suggestions while the completion tree still sees them.

- [ ] **Step 4: Verify**

Run:
```bash
./scripts/reload.sh --tag shell-completion
./scripts/test-unit.sh test -only-testing:cmuxTests/CLICommandSuggestionDerivationTests
CMUX_CLI_BIN=/tmp/cmux-shell-completion/Build/Products/Debug/cmux python3 tests/test_cli_contract_help.py
```
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add CLI/CMUXCLI+CommandSuggestions.swift \
        cmuxTests/CLICommandSuggestionDerivationTests.swift \
        cmux.xcodeproj/project.pbxproj
git commit -m "refactor(cli): derive command name list from declared tree"
```

---

### Task 18: Alias and dispatch parity

Aliases are the likeliest silent casualty of a one-pass rewrite, so they get their own gate.

**Files:**
- Create: `tests/test_cli_dispatch_parity.py`

**Interfaces:**
- Consumes: `cmux __dump-command-tree` from Task 2.
- Produces: a CI gate proving no command or alias was dropped.

- [ ] **Step 1: Write the failing parity test**

Create `tests/test_cli_dispatch_parity.py`. It extracts every `case "<name>"` string from the top-level dispatch `switch` in `CLI/cmux.swift`, extracts every command name and alias from `cmux __dump-command-tree`, and asserts the first set is a subset of the second. Report missing names explicitly, one per line.

Additionally hard-code this alias table and assert each alias resolves to the same help output as its target, or (for aliases with a dedicated legacy alias banner) that the banner names the exact target structurally rather than loosely containing `cmux <target>` anywhere in the body, so an alias that exists but points at the wrong command is still caught:

```python
ALIASES = {
    "cloud": "vm",
    "remote": "remotes",
    "login": "auth login",
    "logout": "auth logout",
    "cr": "coderouter",
    "open-browser": "browser open",
    "navigate": "browser navigate",
    "browser-back": "browser back",
    "browser-forward": "browser forward",
    "browser-reload": "browser reload",
    "browser-status": "browser status",
    "disable-browser": "browser disable",
    "enable-browser": "browser enable",
    "get-url": "browser get-url",
    "focus-webview": "browser focus-webview",
    "is-webview-focused": "browser is-webview-focused",
}
```

- [ ] **Step 2: Run it**

Run: `CMUX_CLI_BIN=/tmp/cmux-shell-completion/Build/Products/Debug/cmux python3 tests/test_cli_dispatch_parity.py`
Expected: FAIL initially if any family task missed a command, listing exactly which. Fix the responsible family file, rebuild, regenerate the snapshot, and rerun until PASS.

- [ ] **Step 3: Add to CI**

Modify `.github/workflows/ci.yml` alongside the other CLI checks, adding `CMUX_CLI_BIN="$CLI_BIN" python3 tests/test_cli_dispatch_parity.py`.

- [ ] **Step 4: Commit**

```bash
git add tests/test_cli_dispatch_parity.py .github/workflows/ci.yml \
        docs/cli-command-tree.txt CLI/Commands/
git commit -m "test(cli): gate dispatch and alias parity"
```

---

### Task 19: Global option placement and passthrough hardening

**Files:**
- Modify: `CLI/cmux.swift` (`firstNonGlobalArgument`, from Task 1)
- Modify: `docs/cli-contract.md`

**Interfaces:**
- Consumes: the router from Task 1 and the declared tree from Tasks 6-16.
- Produces: contract probes covering both option placements and the passthrough boundary.

- [ ] **Step 1: Add contract probes for both placements**

Inside the `<!-- cli-contract-help-probes:start -->` block in `docs/cli-contract.md`, append:

```
- `cmux --json list-workspaces --help` -> `List workspaces`
- `cmux list-workspaces --json --help` -> `List workspaces`
- `cmux --id-format uuids list-workspaces --help` -> `List workspaces`
```

- [ ] **Step 2: Run the harness to see which placements fail**

Run: `CMUX_CLI_BIN=/tmp/cmux-shell-completion/Build/Products/Debug/cmux python3 tests/test_cli_contract_help.py`
Expected: the leading-option probes fail if `firstNonGlobalArgument` mishandles them.

- [ ] **Step 3: Fix the pre-parse**

Correct `firstNonGlobalArgument(_:)` so it skips `--socket`, `--password`, `--window`, and `--id-format` with their values, skips the valueless `--json`, handles the `--option=value` form, and stops skipping at a bare `--`. A `--` terminator means everything after it is payload, so the token before it decides routing.

- [ ] **Step 4: Verify both placements and the negative probe**

Run: `CMUX_CLI_BIN=/tmp/cmux-shell-completion/Build/Products/Debug/cmux python3 tests/test_cli_contract_help.py`
Expected: PASS, including the pre-existing negative probe `cmux vm exec demo -- --help`, which must still exit nonzero and reach the socket.

- [ ] **Step 5: Commit**

```bash
git add CLI/cmux.swift docs/cli-contract.md
git commit -m "fix(cli): handle global options on both sides of the command"
```

---

### Task 20: Localization audit

**Files:**
- Modify: `Resources/Localizable.xcstrings`
- Modify: `CLI/Commands/*.swift` (any remaining bare English)

**Interfaces:**
- Consumes: every abstract and help string declared in Tasks 3-16.
- Produces: a complete localization audit for the handoff.

- [ ] **Step 1: Find bare English in the new files**

Run:
```bash
rg -n 'abstract: "|help: "|discussion: "' CLI/Commands/
```
Expected: no matches. Every one is a `String(localized:defaultValue:)` call. Fix any hit.

- [ ] **Step 2: Verify every new key exists for every locale**

Run:
```bash
python3 - <<'PY'
import json, re, subprocess
d = json.load(open('Resources/Localizable.xcstrings'))
expected = {'ar','bs','da','de','en','es','fr','it','ja','km','ko','nb','pl',
            'pt-BR','ru','th','tr','uk','zh-Hans','zh-Hant'}
diff = subprocess.run(
    ['git','diff','--unified=0','origin/main','--','Resources/Localizable.xcstrings'],
    capture_output=True, text=True).stdout
# Only added/changed keys, not every pre-existing catalog entry: a full-catalog
# scan would fail on unrelated, already-known gaps and couldn't prove the new
# keys specifically are complete.
changed_keys = sorted(set(re.findall(r'^\+\s*"(cli\.[^"]+)":\s*\{', diff, re.MULTILINE)))
missing = []
for key in changed_keys:
    value = d['strings'].get(key)
    have = set((value.get('localizations') or {}).keys()) if value else set()
    if expected - have:
        missing.append((key, sorted(expected - have)))
for key, locales in missing:
    print(key, 'missing:', ','.join(locales))
print(f'checked {len(changed_keys)} changed keys, total incomplete:', len(missing))
PY
```
Expected: `total incomplete: 0`. Add translations for any key reported.

- [ ] **Step 3: Confirm preserved localized fragments**

Run:
```bash
rg -n 'cli.browser.profile.option|cli.browser.designMode.help|localizedCoderouterAliases' CLI/
```
Expected: each still referenced from its declared command, not replaced with English.

- [ ] **Step 4: Commit**

```bash
git add Resources/Localizable.xcstrings CLI/Commands/
git commit -m "i18n(cli): localize command abstracts and option help"
```

---

### Task 21: Documentation and handoff

**Files:**
- Modify: `README.md`
- Modify: `docs/cli-contract.md`
- Modify: `CLI/cmux.swift` (the `docs` command topic list)

- [ ] **Step 1: Document the install lines in the README**

Add a "Shell completion" section after the Homebrew section (`README.md:106`):

````markdown
### Shell completion

Add the line for your shell, then start a new shell:

```bash
# zsh
eval "$(cmux completion zsh)"
# bash
eval "$(cmux completion bash)"
# fish
cmux completion fish | source
```
````

- [ ] **Step 2: Update the CLI contract**

In `docs/cli-contract.md`, mark the "ArgumentParser Migration Sequence" steps 1 through 3 as done, and add a note that step 6 (removing the manual parser) is deferred one release behind `CMUX_CLI_LEGACY_PARSER=1`.

- [ ] **Step 3: Add a `cmux docs completion` topic**

Extend the `docs` command's topic list to include `completion`, printing the same three install lines. Add a contract probe for it inside the help-probes block:

```
- `cmux docs completion` -> `cmux completion zsh`
```

- [ ] **Step 4: Full verification sweep**

Run:
```bash
./scripts/reload.sh --tag shell-completion
export CMUX_CLI_BIN=/tmp/cmux-shell-completion/Build/Products/Debug/cmux
python3 tests/test_cli_contract_help.py
python3 tests/test_cli_command_tree_snapshot.py
python3 tests/test_cli_completion_scripts.py
python3 tests/test_cli_dispatch_parity.py
./scripts/test-unit.sh test -only-testing:cmuxTests/CLICompletionCandidateSafetyTests
./scripts/test-unit.sh test -only-testing:cmuxTests/CLICompletionCandidateLiveTests
./scripts/test-unit.sh test -only-testing:cmuxTests/CLICommandSuggestionDerivationTests
./scripts/lint-pbxproj-test-wiring.sh
./scripts/check-pbxproj.sh
python3 scripts/check-package-resolved-policy.py
```
Expected: every one exits 0. Report any failure rather than working around it.

- [ ] **Step 5: Manual dogfood in all three shells**

In a real terminal, for each of zsh, bash, and fish:

1. `eval "$(cmux completion <shell>)"` (or the fish form).
2. Type `cmux list-work<TAB>` and confirm it completes to `list-workspaces`.
3. Type `cmux list-panes --workspace <TAB>` with cmux running and confirm live refs appear.
4. Quit cmux, repeat step 3, and confirm the shell offers nothing, returns immediately, and prints no error.
5. Type `cmux browser <TAB>` and confirm browser subcommands appear.

Record the result for each shell in the handoff. Step 4 is the one that matters most; a regression there degrades every shell the user opens.

- [ ] **Step 6: Commit**

```bash
git add README.md docs/cli-contract.md CLI/cmux.swift
git commit -m "docs(cli): document shell completion install"
```

---

## Handoff Requirements

Per `CLAUDE.md`, a first pass ends when the change is implemented, the tagged build succeeded on the pushed HEAD, focused tests ran, and the PR is open. The handoff must state:

- The three-shell dogfood result, including the cmux-not-running case.
- The localization audit: what was enumerated, which locales were verified, and anything that could not be verified.
- That `CMUX_CLI_LEGACY_PARSER=1` exists as a one-release escape hatch and needs a follow-up PR to remove.
- That `skills/cmux-localization/SKILL.md` says "English and Japanese" while `Resources/Localizable.xcstrings` carries 20 locales, as a separate follow-up.

Notify with:

```bash
cmux notify --title "Dogfood ready: cmux shell completion" \
  --subtitle "feature/cmux-shell-autocomplete · shell-completion" \
  --body "Was: no shell completion for cmux. Now: cmux completion zsh|bash|fish, with live workspace/surface/window refs. Check: eval \"\$(cmux completion zsh)\" then cmux list-panes --workspace <TAB>. PR: <pr-url>"
```
