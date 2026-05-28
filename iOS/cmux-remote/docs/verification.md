# Verification

## Build

```bash
cd iOS/cmux-remote
brew install xcodegen          # one-time
./scripts/generate.sh          # writes cmux-remote.xcodeproj from project.yml
xcodebuild \
  -scheme CmuxRemote \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4),OS=26.0' \
  build
```

For headless test runs in CI:

```bash
xcodebuild \
  -scheme CmuxKit \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0' \
  test
```

## Unit tests

`Tests/CmuxKitTests/` covers:

| File | What it pins |
| --- | --- |
| `CmuxEventDecoderTests.swift` | NDJSON event-stream frames lifted verbatim from `docs/events.md`; cursor advance + reset semantics across boot-id changes |
| `ShellEscapeTests.swift` | POSIX single-quote escaping for command injection resistance |
| `CMUXClientCommandTests.swift` | Exact shell-command shapes for v2 snapshot/feed RPCs, `send`, error propagation; event stream consumption |

There is no live-cmux integration test in CI here; that needs a Mac
runner with cmux running and is left as a project-level follow-up.

## Manual verification on device

1. Generate + open the project; sign with your team.
2. On the Mac running cmux: `cmux capabilities | jq`; confirm
   `events.stream` is present.
3. Add an SSH key to the Mac's `~/.ssh/authorized_keys` (ed25519).
4. In cmux-remote → Add Mac, enter the host, paste the base64-encoded
   raw ed25519 private key (the 32-byte seed).
5. Confirm the connection pill turns green; the workspace sidebar
   populates.
6. Trigger a notification on the Mac: `cmux notify --workspace … --body
   "agent waiting"`. Confirm:
   * Bell badge increments in the iOS toolbar.
   * Local notification fires (time-sensitive).
   * Live Activity (Dynamic Island) shows the pending count.
   * Notification action buttons (Open / Reply / Mark read / Dismiss) work
     and the change reflects on the Mac.
7. Send a key from the iOS terminal view; confirm the Mac's surface
   receives it.
8. Go offline → background the app → bring it back online. Confirm the
   event reactor reconnects without re-rendering the entire workspace.

## Pre-merge checklist

- [ ] `xcodebuild test -scheme CmuxKit` passes locally on an iOS 26
      simulator
- [ ] `xcodebuild build -scheme CmuxRemote` passes for both an iPhone and
      iPad simulator
- [ ] No new strict-concurrency warnings (the project sets
      `SWIFT_STRICT_CONCURRENCY = complete` and treats warnings as errors)
- [ ] `docs/known-limitations.md` updated if you discover a new limit
- [ ] `docs/architecture.md` updated if you move a layer boundary
