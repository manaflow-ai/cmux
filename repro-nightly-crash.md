# Reproduce nightly crash investigation

## Chosen crash

Chosen signature: `feed.push` dispatch reentrancy in `FeedCoordinator.ingestBlocking`.

I excluded the local `NSImageView _NSAsynchronousPreparation preparedResult` crash because issue #3590 was explicitly out of scope. The selected signature is tracked in GitHub issue #3316 and its attached crash report. It is a nightly crash from `0.63.2-nightly.2511485682701` where the main thread traps in libdispatch because `feed.push` enters `FeedCoordinator.ingestBlocking`, then synchronously dispatches back to the main queue while already running on it.

Source survey:

| Source | Result |
| --- | --- |
| Local DiagnosticReports | Recent stable and nightly reports are dominated by the excluded #3590 `NSImageView` stack. One non-#3590 local stable crash exists in AppKit constraint update, but it is not nightly. |
| Sentry | Blocked by local Sentry authentication. `sentry auth status`, `sentry project list manaflow --json`, and the installed `sentry-cli` all required an auth token. No Sentry event id, fingerprint, or count is claimed here. |
| GitHub issues | The requested `label:crash` search returned no open issues because the repository currently has no `crash` label. A broader open crash-text search found #3316, #3369, and #743. I chose #3316 because it is nightly-specific and not #3590. |

Local crash logs inspected:

| File | Channel | Version | Hardware | Exception | Crashing thread | Top frames |
| --- | --- | --- | --- | --- | --- | --- |
| `cmux-2026-05-05-170425.ips` | nightly, `/Applications/cmux NIGHTLY.app` | `0.64.2-nightly.2540862386901` build `2540862386901` | `Mac15,10` | `EXC_BREAKPOINT / SIGTRAP` | Thread 51 | `__abort`; `abort`; `__assert_rtn`; `-[_NSAsynchronousPreparation preparedResult]`; `-[NSImageView _shownImage]`; `-[_NSSimpleImageView _isSymbolAndRBLayerImageView]` |
| `cmux-2026-05-05-165828.ips` | stable, `/Applications/cmux.app` | `0.64.2` build `82` | `Mac15,10` | `EXC_BREAKPOINT / SIGTRAP` | Thread 6 | `__abort`; `abort`; `__assert_rtn`; `-[_NSAsynchronousPreparation preparedResult]`; `-[NSImageView _shownImage]`; `-[_NSSimpleImageView _isSymbolAndRBLayerImageView]` |
| `cmux-2026-05-05-165828.000.ips` | stable, `/Applications/cmux.app` | `0.64.2` build `82` | `Mac15,10` | `EXC_BREAKPOINT / SIGTRAP` | Thread 8 | `__abort`; `abort`; `__assert_rtn`; `-[_NSAsynchronousPreparation preparedResult]`; `-[NSImageView _shownImage]`; `-[_NSSimpleImageView _isSymbolAndRBLayerImageView]` |
| `cmux-2026-05-05-170014.ips` | stable, `/Applications/cmux.app` | `0.64.2` build `82` | `Mac15,10` | `EXC_CRASH / SIGKILL`, termination `Application Triggered Fault` | Thread 0 | `__terminate_with_payload`; `abort_with_payload_wrapper_internal`; `abort_with_payload`; `_os_crash_msg`; `-[NSView _updateConstraintsForSubtreeIfNeededCollectingViewsWithInvalidBaselines:]`; `-[NSView _updateConstraintsForSubtreeIfNeededCollectingViewsWithInvalidBaselines:]` |

## Signature (stack/threads/version)

Crash report from issue #3316:

- Process: `/Applications/cmux NIGHTLY.app/Contents/MacOS/cmux`
- Identifier: `com.cmuxterm.app.nightly`
- Version: `0.63.2-nightly.2511485682701`
- Hardware: `Mac15,6`
- macOS: `26.3.1 (25D2128)`
- Date: `2026-04-29 15:35:01.7638 -0700`
- Incident: `A796843C-49F4-4800-81E0-2F0C8618F300`
- Exception: `EXC_BREAKPOINT (SIGTRAP)`
- Application specific information: `BUG IN CLIENT OF LIBDISPATCH: dispatch_sync called on queue already owned by current thread`
- Crashing thread: Thread 0, Dispatch queue `com.apple.main-thread`

Top frames:

```text
0  libdispatch.dylib  __DISPATCH_WAIT_FOR_QUEUE__ + 484
1  libdispatch.dylib  _dispatch_sync_f_slow + 148
2  cmux               FeedCoordinator.ingestBlocking(event:waitTimeout:) + 960
3  cmux               TerminalController.v2FeedPush(params:) + 1900
4  cmux               closure #2 in TerminalController.processV2Command(_:) + 7124
5  cmux               TerminalController.processV2Command(_:) + 2168
```

Relevant current code map:

- `docs/feed.md:46`: agents send hook events through `cmux hooks feed`, which forwards a `feed.push` V2 frame to the app socket and may block on a semaphore until the user replies.
- `Sources/TerminalController.swift:8023`: `v2FeedPush(params:)` decodes the event and calls `FeedCoordinator.shared.ingestBlocking`.
- `Sources/Feed/FeedCoordinator.swift:84`: `ingestBlocking(event:waitTimeout:)` blocks the caller when `waitTimeout > 0`.
- `Sources/Feed/FeedCoordinator.swift:114`: the blocking path uses `DispatchQueue.main.sync` to insert into the `@MainActor` store before waiting on the semaphore.
- `Sources/TerminalController.swift:1477`: current `socketWorkerV2Methods` includes `feed.push`, `feed.permission.reply`, `feed.question.reply`, and `feed.exit_plan.reply`.
- `Sources/TerminalController.swift:1516`: current dispatcher routes socket-worker V2 methods before they enter the main-actor path.

Affected versions:

- Confirmed historical nightly: `0.63.2-nightly.2511485682701`.
- Current nightly tested: `0.64.2-nightly.2540862386901 (2540862386901) [7acb1fb]`.
- Stable local logs did not show this exact signature.
- Sentry event count: unknown because Sentry CLI was not authenticated.

Hypothesis:

The older nightly routed `feed.push` through `processV2Command` on the main actor. `v2FeedPush` then called `FeedCoordinator.ingestBlocking`; the blocking branch tried to `DispatchQueue.main.sync` from the main queue and libdispatch trapped. The current code appears to address the class by routing blocking V2 socket methods through the socket worker first, so the main sync happens from a non-main caller. The invariant should be: any V2 command that can block or wait for `@MainActor` work must be impossible to execute from `processV2Command` on the main thread.

## Reproducible? (Yes / Sometimes / No)

No on the current local nightly, `/Applications/cmux NIGHTLY.app`, version `0.64.2-nightly.2540862386901`.

The issue was reproducible in the attached historical crash report for `0.63.2-nightly.2511485682701`, but the direct trigger did not reproduce after the current worker-routing change.

## Repro steps

Nightly build located locally:

```bash
/Applications/cmux NIGHTLY.app
"/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux" --version
# cmux 0.64.2-nightly.2540862386901 (2540862386901) [7acb1fb]
```

Launch with an isolated socket:

```bash
pkill -f "/Applications/cmux NIGHTLY.app/Contents/MacOS/cmux" 2>/dev/null || true
rm -f /tmp/cmux-nightly.sock /tmp/cmux-nightly-crash-repro.sock
env -u CMUX_SOCKET -u CMUX_SOCKET_PATH -u CMUX_SOCKET_MODE \
  CMUX_ALLOW_SOCKET_OVERRIDE=1 \
  CMUX_SOCKET_PATH=/tmp/cmux-nightly-crash-repro.sock \
  CMUX_SOCKET_MODE=allowAll \
  CMUX_SOCKET_ENABLE=1 \
  open -n -g "/Applications/cmux NIGHTLY.app"
```

Verify the socket:

```bash
"/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux" \
  --socket /tmp/cmux-nightly-crash-repro.sock ping
# PONG
```

Attempt the suspected trigger:

```bash
"/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux" \
  --socket /tmp/cmux-nightly-crash-repro.sock \
  rpc feed.push '{"wait_timeout_seconds":0.5,"event":{"session_id":"nightly-repro-session","hook_event_name":"PermissionRequest","_source":"codex","cwd":"/Users/austinwang/manaflow/term/cmux4","tool_name":"Bash","tool_input":{"command":"true"},"_opencode_request_id":"nightly-repro-1","_ppid":1}}'
```

Observed result:

```json
{
  "item_id": "2DEC245E-5076-484F-9952-E06DF240E135",
  "status": "timed_out"
}
```

Stress attempt:

- Sent 15 concurrent blocking `feed.push` calls with `wait_timeout_seconds: 1.0` and unique request ids.
- All calls returned `status: timed_out`.
- The app still answered `ping` with `PONG`.
- No new cmux crash log appeared in `~/Library/Logs/DiagnosticReports/`.

## Negative attempts

- Single blocking `feed.push` socket call against current nightly: no crash, timed out normally.
- Fifteen concurrent blocking `feed.push` socket calls against current nightly: no crash, all timed out normally.
- Local DiagnosticReports check after the attempts: no new report for the `feed.push` signature. The newest nightly report remained the excluded `NSImageView _NSAsynchronousPreparation` crash.
- Initial socket isolation did not work until setting `CMUX_ALLOW_SOCKET_OVERRIDE=1`; that was a launch environment issue, not a product crash.

## Suggested next steps and likely owner of the affected subsystem

Likely owner: socket/feed subsystem, specifically `TerminalController` V2 socket dispatch and `FeedCoordinator`.

Architectural recommendation:

Keep the current worker-dispatch boundary as the source of truth for blocking socket methods. The durable fix is not another `DispatchQueue.main.async` patch inside `FeedCoordinator`; it is to make blocking V2 commands structurally unable to execute on the main queue. `FeedCoordinator.ingestBlocking` can keep its narrow job of moving store mutation onto the `@MainActor`, while `TerminalController` owns the invariant that any command that waits on a semaphore is routed off-main before handler execution.

Concrete follow-ups:

- Once Sentry is authenticated, query the cmux project for unresolved nightly issues and confirm whether this fingerprint still has events after `0.64.2-nightly.2540862386901`.
- If Sentry is clean, close #3316 as fixed by the socket-worker routing work.
- Keep regression coverage around `feed.push` entering through the socket worker rather than `processV2Command` on main. Current history shows related commits `4623196f` (`Reproduce feed push main-queue socket crash`) and `2597d88b` (`Route blocking v2 socket methods off main`).
- Consider a debug-only assertion at the handler boundary for blocking V2 socket methods so future regressions fail at dispatch policy rather than inside libdispatch.
