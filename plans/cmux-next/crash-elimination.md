# Crash elimination

Owner: the crash lead. Started after cmux NIGHTLY aborted three times on
2026-10-04 (05:56, 05:58, 06:00 PDT). Goal: no input, page, extension, peer
or daemon state can end the app, and every crash that still happens is
collected, symbolicated and filed without a person copying files.

## 0. Model: why a Swift app dies

A process ends only in five ways:

| Way | Mechanism | 2026-10 cmux examples |
| --- | --- | --- |
| a. A runtime-checked invariant fails | Swift traps: `x!`, IUO, `as!`, `try!`, `unowned` to a freed object, an index out of range, overflow, `precondition`/`fatalError`, `MainActor.assumeIsolated` off main, exclusivity, continuation misuse | KeyViewProxy `unowned` |
| b. An Objective-C exception escapes Cocoa | NSRangeException, unrecognized selector, unknown KVC key; Swift cannot catch them | TextLayout NSRangeException (stale UTF-16 offsets on a background render), PointerHover `mouseEnteredWith:` |
| c. Memory unsafety | C/C++/Zig/Rust FFI, unsafe pointers, a C callback into a freed object | none filed this month |
| d. An embedded engine asserts | CEF CHECK/DCHECK, a Rust panic across FFI with abort | CEF WebAuthn DCHECK (section 1) |
| e. Something outside kills it | jetsam/OOM, hang watchdog, launch constraints, our own scripts | Launch Constraint kills, terminal hosts ended by a reaper LaunchAgent |

The common root of a and b: an invariant that the type system does not hold
is checked at run time, at a boundary with an untyped or dynamic system
(Objective-C selectors and KVC, NSString UTF-16 offsets, C callbacks), or on
state shared across threads and time (a range computed for one string and
used on another, an owner freed before its callback). "Zero crashes" is not
reachable (e, d and hardware stay), so the program has two halves:

1. Make each class impossible to write: the type carries the invariant (a
   text range that is valid only for the string it came from, a callback
   delivered on main at its source, a weak owner), and a lint bans the
   trapping construct. Ratchet first, then BAN.
2. Report the crashes that remain honestly (Lawrence, 2026-10-08: no
   auto-restart, so crashes stay visible and get fixed at their class). A
   crash handler writes a report; the next launch shows a crash dialog with
   Reopen (restore windows, workspaces and panes from daemon state;
   terminals already live in their hosts) and Report. The weight of the
   program is on half 1 and on Phase 3 (fuzz, sanitizers).

### Program status

| Phase | Item | State |
| --- | --- | --- |
| 1 | Ratchet v2: scope = CmuxNext + every package in its `.package(path:)` closure except vendor/ (the TextLayout crash was in CmuxHomeRender, outside v1's scope); BAN mode with `scripts/cmux-next/crash-allowlist.json` (path, class, count, reason, reviewer; inline crash-allow does not waive a banned class); `// main-proof:` exempts assumeIsolated; new classes `objc_selector` (BAN) and `dynamic_dispatch` (ratchet); `fatal_error` BAN | landing (P1a) |
| 1 | Swift classes to 0 per module, then BAN: force_unwrap 338, iuo 61, unowned 110, as! 12, precondition 40, assumeIsolated 123 (counts in the widened scope at 406a70f2f39e) | next (P1b, helpers per module, at most 3 at a time) |
| 1 | NSRange/UTF-16 ban outside one TextRange module | after the TextLayout fix (cx-qpqs) lands |
| 1 | Rust: poison-tolerant lock helper with worker restart, clippy `unwrap_used`/`expect_used`/`panic`/`indexing_slicing` warn then deny per crate | planned (CORE window) |
| 2 | Crash handler (uncaught NSException handler + signal report the crash watcher reads), crash dialog on next launch (Reopen restores from daemon state, Report sends the report), crash e2e (debug.crash.app, then Reopen: no lost terminals). No auto-restart (Lawrence 2026-10-08) | design |
| 3 | Fuzz/property tests (text layout, markdown, protocol decoding), nightly ASan/TSan | planned |
| 4 | CEF out of process go/no-go | planned |

P1b rules (chief, 2026-10-08): no behavior change except "no trap". An
`assumeIsolated` site first tries delivery on main at its source (the
registration's queue or run loop); a hop (`DispatchQueue.main.async`) only
where the call returns nothing and order does not matter; otherwise keep it
with a `// main-proof:` that names the guarantee. A guard that returns must
not drop a user action silently: show the existing error toast where the
user acted, or log a fault for non-user paths. Each commit names its choice
per site.

## 1. The 2026-10-04 crash

Stack (main thread, symbolicated with the unstripped cmux.15 framework,
UUID 4C4C4466-5555-3144-A1FF-66F41D63F6DC):

```
CFRunLoop timer -> CEFMessagePump (Swift) -> cmux_cef_shim -> CefDoMessageLoopWork
-> mojo Connector -> blink.mojom.Authenticator dispatch
-> AuthenticatorImpl::IsUserVerifyingPlatformAuthenticatorAvailable
-> AuthenticatorCommonImpl::GetWebAuthnRequestProxyIfActive
-> DCHECK(!caller_origin.opaque()) -> LogMessage::HandleFatal -> abort
```

cef.log: `FATAL:content/browser/webauth/authenticator_common_impl.cc:3500] DCHECK failed: !caller_origin.opaque().`

- The cmux call was legal: main thread, after CefInitialize, before
  shutdown, not re-entrant. No cmux lifecycle invariant was broken.
- A frame with an opaque origin (sandboxed iframe, data: frame or an
  about:blank child of one) called
  `PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()`.
- Root cause: CEF cmux.15 and cmux.16 are non-official Chromium builds
  without a `dcheck_always_on` override. `build/config/dcheck_always_on.gni`
  turns DCHECKs on for every non-official build, and a failed DCHECK aborts
  the browser process. In CEF the browser process is the app. Any DCHECK
  that web content can reach was an app crash.
- Two cmux binaries with one version: crash 1 ran a binary from an older
  nightly (launched 04:02); Sparkle replaced the bundle at 05:02 while it
  ran, and ReportCrash reads the version from the bundle on disk at crash
  time. Not a release identity bug. Rule for triage: identify a build by
  the binary UUID in `usedImages`, never by `app_version`.

Fix:

| Step | State |
| --- | --- |
| Red test: embedder case `opaque-webauthn` (manaflow-ai/cef, sandboxed srcdoc iframe calls isUVPAA) | red on cmux.15 and cmux.16 (exit 134, same FATAL line) |
| CEF cmux.17 = cmux.16 + `dcheck_always_on=false` + GN args in archive.json (`gn_args`), [cef PR 8](https://github.com/manaflow-ai/cef/pull/8) | published: [cef-154.0.28-cmux.17](https://github.com/manaflow-ai/cef/releases/tag/cef-154.0.28-cmux.17), R2 write-once with read-back, pinned; arm64 embedder cases 10/10; x86_64 built and packaged, cases not run (no Rosetta host); about_credits is still Chromium's placeholder (cmux.18) |
| Linux and Windows build scripts get the same flag, [cef PR 9](https://github.com/manaflow-ai/cef/pull/9) | merged |
| One shared args.gn check for the macOS, Linux and Windows scripts: record `gn_args`, refuse a build without `dcheck_always_on=false` (macOS has it since PR 8) | before any Linux or Windows build ships |
| Interim renderer guard (a stand-in PublicKeyCredential in secure opaque-origin contexts, defined in OnContextCreated before Blink installs the real one) | landed in cc284fc6ea1, removed with the cmux.17 pin; `scripts/cmux-next/webauthn-opaque-e2e.py` stays (it accepts native methods) |
| ensure-cef.sh refuses a framework whose `archive.json` lacks `gn_args.dcheck_always_on == false` | on: the manifest sets `"require_dcheck_off": true` (warning before the pin) |

All CEF builds after cmux.17 (cmux.18, any rebuild) run on the fleet CEF
workers (`cmux-ci build cef --arch ...`), not on cmux-lawrence-2
(coordinator decision, 2026-10-04): the x86_64 half of cmux.17 took 3.7 h at
nice 19 there and held the GUI host at load 60-90.

Next CEF releases (coordinator plan, 2026-10-04):

- cmux.18: the passkeys fork branch (`cmux/8037-api18-pw`), real credits
  (`generate_about_credits=true`, `CREDITS.html` in the framework's
  Resources, the build refuses the placeholder), one shared args.gn check for
  the macOS, Linux and Windows build scripts, one API bump (17 to 18), the
  remote-tab patches and the password-core API if they are ready by the cut.
- cmux.19: `symbol_level=1` + dsymutil; the dSYM archived per release in R2,
  so the crash pipeline gives file:line for CEF frames.

## 2. Inventory of crash classes

Counts on feat-cmux-next 3c57fb6bb03 (2026-10-04), production code only.
Swift: `Packages/macOS/CmuxNext/Sources`. Rust: `cmux-tui/crates/*/src`
without inline test modules or `tests/` folders. The ratchet numbers come
from `scripts/cmux-next/crash_ratchet.py --update-baseline`.

Ranked by risk (likelihood that a user or a peer reaches it, times blast
radius):

| # | Class | Hits | Reach | Blast radius |
| --- | --- | --- | --- | --- |
| 1 | Chromium browser-process CHECK/DCHECK reachable from web content (in-process CEF) | DCHECKs: all of Chromium until cmux.17; CHECKs: always | any page | whole app |
| 2 | Rust panic in daemon paths (`unwrap` 2388, `expect` 782, `panic!`/`unreachable!`/`todo!` 105, `process::exit`/`abort` 27, indexing about 2600 sites, 537 of the unwraps are `lock().unwrap()` poisoning) | as listed | socket, journal, peer, PTY input | the cmux-tui daemon (every terminal, the CLI) |
| 3 | `MainActor.assumeIsolated` (123) | C callbacks, notifications, CEF/Ghostty events | a callback on the wrong thread | app (trap) |
| 4 | C callbacks into freed objects (`@convention(c)` 114, `Unmanaged`/unsafe pointers 269) | CEF shim, Ghostty, IOSurface | lifecycle races (close during callback) | app (EXC_BAD_ACCESS) |
| 5 | Force unwrap `x!` (225), implicitly unwrapped declarations (54), `.first!` and `[0]` (about 80) | UI and app code | state that is empty "only in theory" | app |
| 6 | `unowned` (96) | AppKit controllers, browser | an owner gone before the callback | app |
| 7 | Unchecked concurrency: `nonisolated(unsafe)` and `@unchecked Sendable` (58) | data races | timing | app (heap corruption, late crash) |
| 8 | `as!` (8), `precondition` (6), `fatalError` outside unreachable inits (1, `debug.crash.app`) | rare | specific inputs | app |
| 9 | Swift exclusivity violations (runtime check is on in Release) | re-entrant mutation from callbacks | rare | app (trap) |
| 10 | Objective-C exceptions from AppKit (NSRangeException, layout loops) | AppKit APIs with bad indexes | rare | app |
| 11 | Recursion and OOM (deep view trees, unbounded buffers, journal replay) | large sessions | rare | app or daemon |
| 12 | Signals (SIGPIPE handled: check-crash-safety; SIGBUS on truncated mmap) | sockets, files | rare | app or daemon |
| 13 | WebKit (WKWebView) page crashes | pages | contained: WebContent process |
| 14 | Chromium renderer, GPU, utility crashes | pages | contained: child process; tab shows "This page crashed" |
| 15 | Debug-only asserts (`assert`, `assertionFailure`: 5; Rust `debug_assert!`) | none in Release | DEV builds only |

Ratchet v2 (2026-10-08) widened the scope to the app package closure, so the counts above (CmuxNext only, 2026-10-04) are lower than the v2 baseline; see the program status in section 0.

Already in place: `try!` is banned (0), force unwrap and `as!` are banned in
CmuxNextDaemon, CmuxNextControl and CmuxNextMobile (external input), and
every socket says how it avoids SIGPIPE (check-crash-safety.sh).

## 3. Rules, gates and containment per class

Every gate starts in ratchet mode: the tree stays green, a module or crate
may never gain a hit, and a fix lowers the baseline in the same commit
(`scripts/cmux-next/crash_ratchet.py --update-baseline`). A reviewed
`// crash-allow: <reason>` on the line or the line above exempts one hit.

| Class | Rule | Gate (now) | Gate (next) | Containment |
| --- | --- | --- | --- | --- |
| 1 Chromium CHECK/DCHECK | Ship CEF with `dcheck_always_on=false`; never call CEF outside the owner type's legal states | `opaque-webauthn` embedder case; build-cmux-cef.sh refuses args without the flag | ensure-cef.sh refuses DCHECK-on frameworks (with the cmux.17 pin) | Lane CEF-OOP (design study): host the CEF browser process in a helper app, so a browser-process CHECK ends that helper and cmux reloads pages |
| 2 Rust panics | Daemon paths return errors; `lock()` uses a poison-tolerant helper; no indexing on peer input | ratchet: unwrap, expect, panic macros, exit per crate | clippy `unwrap_used`, `expect_used`, `panic`, `indexing_slicing` as `warn` with a per-crate allow list, then `deny` crate by crate (needs a cmux-tui window); `panic = "unwind"` stays, every thread and task boundary catches panics and restarts the worker | supervisor restarts a dead daemon; the app reattaches |
| 3 assumeIsolated | Hop with `Task { @MainActor in }` or `DispatchQueue.main.async` from callbacks; assume only where the caller is proven main | ratchet | a lint that requires a `// main-proof:` comment | none (trap) |
| 4 C callbacks | Every C callback takes a token (an id into a registry), not a pointer to a Swift object; the registry refuses unknown ids | ratchet on `Unmanaged` (next) | gate: `Unmanaged.passUnretained` only in the CEF owner type | none (segfault) |
| 5 Force unwrap, IUO, `.first!` | `guard let ... else { log; return }` | ratchet | per-module ban (as for the external-data modules) once a module reaches 0 | none |
| 6 unowned | `weak` + guard | ratchet | ban in new code | none |
| 7 unchecked concurrency | A lock or an actor; `@unchecked Sendable` only with a named lock | ratchet | TSan run of the package tests on the fleet (nightly) | none |
| 8 as!, precondition, fatalError | Typed errors | ratchet | ban | none |
| 9 exclusivity | No mutation from callbacks during a mutation | none | exclusivity-violation e2e under the debug socket | none |
| 10 ObjC exceptions | Bounds checks before AppKit index APIs | none | `NSSetUncaughtExceptionHandler` report with the stack | none |
| 11 recursion, OOM | Bounded buffers (check-concurrency already bans unbounded AsyncStream) | check-concurrency | memory budget e2e on large sessions | memory pressure handler hibernates pages |
| 12 signals | SIGPIPE policy | check-crash-safety | SIGBUS-safe file reads (no mmap of files other processes truncate) | none |
| 13, 14 page crashes | Pages are never trusted | none | crash e2e: kill a renderer, a GPU and a WebContent process, the app stays | already contained; the tab offers Reload |
| 15 debug asserts | Allowed; they must not have side effects | none | none | not in Release |

The CEF owner type (requested in the crash brief) is a hardening item, not
the fix for this crash: `CEFMessagePump` already refuses re-entry and runs no
work after shutdown. Proposed lane CEF-OWNER: one `CEFHost` type is the only
caller of `cmux_cef_shim` (state machine: unloaded, initializing, ready,
shuttingDown, shutDown; an illegal call logs and returns an error, never
aborts), plus a gate that forbids `shim.` calls outside it.

## 4. Crash-report pipeline

| Step | State |
| --- | --- |
| At launch, `CrashRecoveryService` finds the previous run's `.ips` and writes cmux's own report | done |
| Help > Show Crash Logs (palette, `cmux settings show-crash-logs`, restart notice): the newest log in TextEdit | done (94319dabd02, d20af6c17df) |
| CEF `cef.log` is overwritten at each launch: keep the previous one (`cef.previous.log`) so the FATAL line survives a relaunch | next |
| Consent: the restart notice asks once to send crash reports (off by default, setting `crashReports.send`) | proposed |
| Upload: the report, the `.ips` (paths under the home folder replaced by `~`), the previous `cef.log` tail (FATAL lines only) to a crash endpoint (R2 write-only key, per-install id) | proposed |
| CI symbolication: a workflow matches `usedImages` UUIDs to the cmux dSYM (Sentry debug files, uploaded by nightly.yml) and the CEF `-debug` archive (unstripped binary, function names only while symbol_level=0), then dedupes by the top 5 symbolicated frames and files or updates one GitHub issue per signature | proposed |
| Release check: a nightly fails when the Sentry dSYM upload is skipped or when the arm64 cmux UUID is not in its upload list | proposed |
| CEF symbols: the `-debug` release asset holds the unstripped framework (function names only, symbol_level=0, no file:line). cmux.19 builds with `symbol_level=1`, runs dsymutil and archives the dSYM per release in R2, so the pipeline gives file:line | cmux.19 |

## 5. Proposed lanes (larger fixes)

1. CEF-OOP: design study for an out-of-process CEF browser process
   (plans/cmux-next/cef-out-of-process.md).
2. CEF-OWNER: the owner type and gate in section 3.
3. RUST-PANIC: daemon crates to clippy deny lints, crate by crate, with a
   panic-catching boundary per worker thread (needs cmux-tui windows).
4. SWIFT-UNWRAP: drive force unwraps, IUO, unowned and assumeIsolated to 0
   module by module, then ban per module.
5. CRASH-PIPE: consent, upload, CI symbolication, dedupe, issues (section 4).
