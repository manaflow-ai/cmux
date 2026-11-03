# Claude background attachment hooks

## Goal and scope

Track acknowledged Claude daemon attachments in the client process, so background hooks can reach a live viewer after its original pane closes. Keep native Claude I/O unchanged. No shared daemon socket replacement and no notification fallback to a focused pane.

The initial integration is opt-in through `CMUX_CLAUDE_ATTACH_OBSERVER=1`. Native daemon protocol compatibility is limited to observed proto 1 attach requests and matching success replies; unknown messages remain untouched and create no subscription.

## Implementation plan

- Add a failing behavior test using real Unix streams: request/ACK chunking, failed ACK, unrelated traffic, close, simultaneous viewers, no authentication/output capture, and unchanged transport bytes.
- Add a bounded Bun preload observer. Observe socket writes/emits without adding data listeners, changing flow control, or modifying bytes. Restore BUN_OPTIONS and remove observer context before application code or children execute.
- Reuse Claude's verified background registry for short job/native session/worker identity. Persist per-attachment leases in the existing locked hook session store. Verify same-user kernel process generations and the local cmux target; exclude relays and replayed process identities.
- Route live background hooks to the most recently acknowledged, still-live viewer; retain other attachments for fallback when that viewer disconnects. Remove only the closing attachment. This preserves the current single-target notification contract.
- Storage and lookup are bounded: each session keeps at most 16 live leases (the oldest is evicted beyond that), and a hook checks at most the 4 newest live leases for app route corroboration. A viewer older than those bounds is not selected; there is no focused-pane fallback. Both bounds keep hook latency and the store size predictable.
- Wire native wrapper entrypoints, including explicit attach and the agent picker, behind the opt-in. Keep disabled integration, non-native launchers, headless runs and unsupported protocols unchanged.
- Run focused red/green tests, the agent-launch package suite, wrapper checks, an isolated native Claude mock-API run and scoped official verification. Record unrun app integration checks honestly.

## Constraints and review focus

- No production socket/configuration changes or existing session restarts.
- Authentication fields and terminal output never enter attachment records or diagnostics.
- Delayed subscribe/unsubscribe must not resurrect a closed attachment or remove another viewer.
- PID reuse, wrong config directory, wrong app socket and dead/moved viewers must fail closed.
- Existing explicit routing flags and remote hook identity rules retain precedence.
- No upstream merge; open a reviewable PR only after scoped checks pass. Full Xcode is currently unavailable.

## Current candidate and compatibility

Set `CMUX_CLAUDE_ATTACH_OBSERVER=1` only for a new managed native Claude launch under test. The default remains off. Native Claude Code 2.1.316 was exercised with a local mock API, including a real attach ACK, completion output and natural Ctrl+Z. Internal agent-picker transitions and a complete tagged cmux app have not yet been exercised.

The observer runs inside the client through Bun's preload facility, restores the previous Bun flags immediately, and observes only proto-1 Unix attach handshakes for this UID. It neither proxies nor replaces the shared daemon socket. A subscription mutation is synchronous and limited to 500 ms per attach/close, not per output frame; this prevents an asynchronous subscribe from overtaking its disconnect. Abrupt client death is rejected by kernel process-generation checks on the next hook.

The native short job ID is resolved through the existing same-config background registry. Records retain worker/viewer PID generations and the admitting cmux socket. The newest live, app-corroborated viewer is the primary notification target; other leases remain eligible after it closes. Remote relays, explicit hook targets and already-admitted replay snapshots keep their existing semantics.

Only the public preload code is cached under the user's private cmux directory. Bun's environment parser did not accept quoted preload paths in the tested native client, so a cache path containing whitespace disables this experimental observer rather than breaking the launch. No authentication fields or terminal output are written to lease records.

## Verification commands

- `node --test tests/test_claude_attach_observer.cjs`: real Unix-stream ACK/close, rejected/oversized/unrelated messages, byte preservation and child-environment restoration. Also invoked by the existing wrapper CI lane.
- `python3 tests/test_claude_attached_viewer_policy.py`: compile the actual Swift policy sources and exercise live generation, PID reuse, socket isolation, newest-viewer selection, the 16-lease and 4-candidate bounds, and independent removal, without requiring Swift Testing or the app.
- Automated checks do not load the generated Bun `--preload` when Bun is not installed in the lane; the observer test skips that case explicitly. Native Claude loads it under Bun in manual validation only.
- `python3 tests/test_claude_wrapper_hooks.py`: full affected wrapper suite; report baseline failures separately from new failures.
- `python3 scripts/verify-local.py --swift-changed`: scoped static verification only.

A full Xcode app/CLI build, queued-hook integration and actual desktop notification delivery remain required before enabling this candidate by default.
