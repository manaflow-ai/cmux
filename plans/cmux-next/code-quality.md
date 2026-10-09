# Code quality rules (binding checklist)

Every review subagent uses this file as its checklist. A finding cites the rule id (for example `SW3`). Rules that a script enforces name the script; the script wins when it is stricter. State ownership rules are in OWNERSHIP-PRINCIPLES.md; god file limits are in godfiles.md. This file does not repeat them.

Lawrence (2026-10-09): no blocking size limits beyond the existing ratchets. Many agents refactor often, in small move-only steps.

## All languages

- G1. One owner per piece of state. Name the owner before you write code (OWNERSHIP-PRINCIPLES.md). No second copy that is written back.
- G2. One responsibility per file and per type: one screen, one resource, one op family, or one concern. A file name says what it owns.
- G3. Narrow surface. Private or module-internal by default. Make an item public only when a caller outside the module needs it.
- G4. No crash paths in runtime code. `crash_ratchet.py` (run by `check-crash-safety.sh` and safe-push) fails a module that gains one. Return a typed error.
- G5. No sleep or timer as synchronization. No polling (idle-wakeups.md, `check-concurrency.sh`). Use events, callbacks, or an injected clock.
- G6. User-facing strings are localized (English and Japanese). No bare literal in UI code.
- G7. Tests check behavior or built artifacts. No source-shape tests (tests that read a source file to find a snippet).
- G8. Comments say why, not what. Each new module or file starts with one doc comment that says what it owns.
- G9. Generated files are never edited by hand. Change the source and rerun the generator in the same commit.

## Swift

- SW1. Strict concurrency. Swift 6 language mode, no `@unchecked Sendable`, no `nonisolated(unsafe)`, no `assumeIsolated` without `// crash-allow:` and a reason.
- SW2. Isolation is explicit. UI state is `@MainActor`. Shared mutable state off the main thread is an `actor`. No locks, semaphores or `DispatchQueue.sync` (`check-concurrency.sh`). The main thread never waits.
- SW3. Store every `Task` handle and cancel it with its owner, or mark the owner with `// task-owner: <reason>`. No `DispatchQueue.asyncAfter`.
- SW4. Value types first. Model data as `struct` and `enum`; use a `class` or `actor` only for identity or shared lifetime. Use `enum` with associated values instead of flag sets and optional groups.
- SW5. No force unwrap, `as!`, `try!`, implicitly unwrapped optional (`!` type), `fatalError` or `precondition` in runtime code. Use `guard let` with a typed error or a logged early return.
- SW6. Thin views. An `NSView`, `NSViewController` or SwiftUI `View` renders state and forwards user intents. Decisions, I/O, parsing and state machines go into a separate model or controller type that tests can drive without a window.
- SW7. Small types. Absolute limits for CmuxNext: 400 lines per file (tests 600), 3 top-level types per file, 1,000 lines per type including extensions (`check-no-godfiles.sh`). For other packages use the same numbers as targets. A type that grows a second responsibility splits into owner types (each owns its state); moving methods into `Type+Concern.swift` extensions is only a first step, because the type keeps every responsibility.
- SW8. Typed errors. `enum ...Error: Error` with cases that callers can act on. Do not throw `NSError` or strings across module boundaries.
- SW9. Swift Testing (`import Testing`, `@Test`, `#expect`) for new tests. Keep XCTest only where the file already uses it. A test uses fakes through a protocol, not real sockets or timers.
- SW10. Dependencies come in through the initializer (protocols, clocks, file roots). No new singletons, no global mutable state.
- SW11. Swift paper cuts go to Rust: when state ownership, races or logic duplicated with the daemon cause bugs, move that logic into the daemon and keep Swift as a thin client (lane rule 2026-10-09).
- SW12. Logs use `Logger` with a subsystem and category. No `print` in runtime code. Never log secrets or message bodies.
- SW13. No caseless namespace enums or all-static public/package types in package source; scope helpers onto the owning type (`scripts/lint-ios-package-conventions.sh`). App-linked code stays Swift 6.0 compatible.

## Rust

- RS1. Typed errors. Libraries define error enums with `thiserror`. `anyhow` only in binaries and tests. No `Box<dyn Error>` in a public API.
- RS2. No panics in runtime code: no `unwrap`, `expect`, `panic!`, `unreachable!` on input-dependent paths, slice indexing that can go out of range, or `process::exit` outside `main` (crash ratchet). Tests may unwrap.
- RS3. Narrow public API. `pub(crate)` by default; `pub` only for items the crate exports by design. Re-export from `lib.rs` deliberately; no `pub use module::*`.
- RS4. One module per responsibility. The ratchet limit is 1,000 lines and 60 functions per file (tests 1,500 and 120). A large `impl` splits into child modules that add `impl` blocks, with tests next to the code in `<module>/tests.rs`.
- RS5. Clippy is clean with `-D warnings` on every touched crate, with the workspace lint set in `cmux-tui/Cargo.toml` (`uninlined_format_args`, `semicolon_if_nothing_returned`, `redundant_clone`, `unsafe_op_in_unsafe_fn = deny`). `cargo fmt` is clean. An `#[allow(...)]` names its reason in a comment.
- RS6. `unsafe` only at FFI boundaries, each block with a `// SAFETY:` comment.
- RS7. Every cmux-tui-core or cmux-tui change compiles for Windows (`cargo check --target x86_64-pc-windows-gnu`). A `#[cfg(unix)]` covers one item; wrap whole blocks in a cfg module.
- RS8. Locks are held for short, synchronous sections. No lock across an `.await`. Document the lock order where two locks meet.
- RS9. Pure reducers for state: `(state, op) -> Result<(state, events), Reject>` with no I/O, covered by property tests (OWNERSHIP-PRINCIPLES.md).

## TypeScript and React

- TS1. No new `useEffect`. Use, in this order: derived values computed during render; event handlers; callback refs for DOM setup and teardown; `useSyncExternalStore` for external stores. If an effect stays, hide it in a small named hook with a narrow contract and a test. Each removal of an existing effect ships with a behavior test that proves the same result.
- TS2. Small components. One component per file for anything with its own state or more than about 100 lines. A screen file composes; it does not hold helpers, hooks and subcomponents for other screens. Pure helpers go into `.ts` files with their own tests.
- TS3. Types come from the generated sources: `src/protocol/generated` (pane protocol), the generated page clients and strings, and `agentBrands.generated.ts`. Do not hand-write a copy of a generated type; derive with `Pick`, `Omit` or indexed types.
- TS4. No `any`. Use `unknown` and narrow with a validator or type guard at the boundary (messages from Swift, JSON, `postMessage`). No `as` casts that skip validation; no non-null `!` on values that can be absent.
- TS5. State lives in one place. Do not copy props into state. Lift shared state to the nearest owner or an external store; keep view-only state local.
- TS6. Accessibility rules (a11y-foundation.md, `test/ui-rules.test.ts`): page code outside `src/ui` has no raw widget roles, tab indexes, key handlers or portals. A file on `ui-rules.pending.json` may only go down; a move updates the counts of both files in the same commit.
- TS7. Strings come from the page's generated strings files (react-pages.md). No user-facing literal in a component.
- TS8. Tests use the per-file runner (`scripts/ci/run-webviews-tests.sh`), never a plain single-process `bun test`. Typecheck (`bun run typecheck`) is clean.
- TS9. Exports are named. No default exports in new files, except where a tool requires one.

## How agents refactor

- R1. Move-only steps. A landing moves code to a better place (G2) with no behavior change. Tests pass unchanged; only their imports or paths may change. A bug found during a move becomes a bead; it is not fixed in the move.
- R1a. Prefer owner splits: move a concern and its state into its own type that the old type owns. A file-only split (extension files, child modules) is phase 1; record the phase 2 owner design in refactor-log.md and agree it with the file's feature owner.
- R2. One responsibility per landing, under 2,000 moved lines. Land on the newest tip, gate, push. No long-lived branch; rebase at least hourly.
- R3. Check before you touch a file: `git log --since=3.days -- <file>` and the beads. If another lane edits the file, ask the chief first. Never edit another refactor lane's files.
- R4. Keep the diff reviewable: move the code byte for byte, then (in the same commit) only change visibility, imports and the names needed to compile. Formatting changes go in a separate commit or not at all.
- R5. Visibility only narrows or stays the same, except the minimum needed to compile across the new file boundary (for example `private` to `fileprivate` or internal, Rust private to `pub(super)`). Never `public` or `pub` for a move.
- R6. Moves can break visibility, codegen and per-file counters. Run the full test set of the touched package or crate, the godfile check, the crash ratchet and (for webviews) the ui-rules test and typecheck.
- R7. Quality improvements that change behavior (removing a `useEffect`, replacing a force unwrap, a new typed error) are separate commits with their own behavior test, never mixed into a move commit.
- R8. Lower the ratchets when a file shrinks: `check-no-godfiles.sh --update-baseline`, `ui-rules.pending.json`. Lowering needs no window.
- R9. Record each landing in plans/cmux-next/refactor-log.md (append-only, one line: date, SHA, what moved where, old and new line counts, gate minutes) and report it to the chief.
- R10. FREEZE paths (pbxproj, CmuxNext Package.swift, the action catalog, settings schemas and the Settings page) need the chief's token even for a move.

## Review checklist (for review subagents)

For each changed file, answer in order and cite the rule id for each finding:

1. Does a move commit change behavior (R1, R4, R7)? Compare the removed and added code.
2. Did visibility widen beyond what the move needs (G3, R5, RS3)?
3. New crash path, force unwrap, panic, IUO or unchecked concurrency (G4, SW1, SW5, RS2)?
4. New state owner, copied state, or new optimistic copy (G1, TS5)?
5. New `useEffect`, `any`, unvalidated cast, or hand-written copy of a generated type (TS1, TS3, TS4)?
6. Does each new file own one thing and start with an ownership comment (G2, G8)?
7. Did the right gates run on the exact head, and were the ratchets lowered (R6, R8)?
