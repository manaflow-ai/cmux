# Claude background attachment hooks

## Goal and scope

Track acknowledged Claude daemon attachments in the client process, so background hooks can reach a live viewer after its original pane closes. Keep native Claude I/O unchanged. No shared daemon socket replacement and no notification fallback to a focused pane.

The initial integration is opt-in through `CMUX_CLAUDE_ATTACH_OBSERVER=1`. Native daemon protocol compatibility is limited to observed proto 1 attach requests and matching success replies; unknown messages remain untouched and create no subscription.

## Implementation plan

- Add a failing behavior test using real Unix streams: request/ACK chunking, failed ACK, unrelated traffic, close, simultaneous viewers, no authentication/output capture, and unchanged transport bytes.
- Add a bounded Bun preload observer. Observe socket writes/emits without adding data listeners, changing flow control, or modifying bytes. Restore BUN_OPTIONS and remove observer context before application code or children execute.
- Reuse Claude's verified background registry for short job/native session/worker identity. Persist per-attachment leases in the existing locked hook session store. Verify same-user kernel process generations and the local cmux target; exclude relays and replayed process identities.
- Route live background hooks to the most recently acknowledged, still-live viewer; retain other attachments for fallback when that viewer disconnects. Remove only the closing attachment. This preserves the current single-target notification contract.
- Wire native wrapper entrypoints, including explicit attach and the agent picker, behind the opt-in. Keep disabled integration, non-native launchers, headless runs and unsupported protocols unchanged.
- Run focused red/green tests, the agent-launch package suite, wrapper checks, an isolated native Claude mock-API run and scoped official verification. Record unrun app integration checks honestly.

## Constraints and review focus

- No production socket/configuration changes or existing session restarts.
- Authentication fields and terminal output never enter attachment records or diagnostics.
- Delayed subscribe/unsubscribe must not resurrect a closed attachment or remove another viewer.
- PID reuse, wrong config directory, wrong app socket and dead/moved viewers must fail closed.
- Existing explicit routing flags and remote hook identity rules retain precedence.
- No upstream merge; open a reviewable PR only after scoped checks pass. Full Xcode is currently unavailable.
