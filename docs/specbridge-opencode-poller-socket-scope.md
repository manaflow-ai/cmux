# SpecBridge: Scope OpenCode Poller By Socket

Date: 2026-05-26
Repo: `cmux-ctrixin`
Scope: focused regression fix for OpenCode completion notifications leaking across cmux app instances/tags/sockets.

## Intent

OpenCode completion polling must observe only OpenCode processes launched for the current cmux app instance and active socket. A tagged dev app such as `ctrixin-test` must not surface completion notifications from the stable/main cmux instance, and the stable/main app must not surface tagged-dev notifications.

## Non-Goals

- Do not change OpenCode DB/session completion detection semantics except adding current-socket scoping.
- Do not change Claude or Codex notification detection/creation behavior.
- Do not kill, restart, or mutate external OpenCode/cmux processes.
- Do not change global socket path configuration or launch-env policy.
- Do not add broad daemon, terminal, or notification UI refactors.

## Task Slices

1. Trace current socket source: confirm `GhosttyTerminalView.swift` launches panes with `CMUX_SOCKET_PATH` from `TerminalController.shared.activeSocketPath(preferredPath: SocketControlSettings.socketPath())`.
2. Pass the current active socket path into the OpenCode completion poller from `TerminalNotificationStore.swift` or the narrowest existing poller setup point.
3. Update `VaultAgentProcessScanner.swift` process/env scan so OpenCode candidates are accepted only when `CMUX_SOCKET_PATH` exactly matches the current active socket path after consistent path expansion/normalization.
4. Treat missing/unreadable candidate `CMUX_SOCKET_PATH` or missing current socket as non-match for OpenCode completion polling, not as a wildcard.
5. Preserve existing OpenCode DB/session logic after the socket filter and keep Claude/Codex paths untouched.
6. Add the smallest regression coverage available, or record manual validation if process-env scanning is hard to unit test.

## Acceptance Criteria

- `ctrixin-test` app does not notify for OpenCode processes whose `CMUX_SOCKET_PATH` points to `~/Library/Application Support/cmux/cmux.sock`.
- Current app still notifies for OpenCode processes whose `CMUX_SOCKET_PATH` equals the current active socket path, including `/tmp/cmux-debug-ctrixin-test.sock` for tagged dev.
- If a scanned OpenCode process lacks `CMUX_SOCKET_PATH`, the poller does not notify from it.
- Stable/main cmux only observes OpenCode processes bound to its own active socket.
- Existing OpenCode completion semantics remain unchanged once a process passes socket scope.
- Build passes.

## Changed-File Boundaries

- Primary files: `Sources/TerminalNotificationStore.swift`, `Sources/VaultAgentProcessScanner.swift`.
- Context-only file: `Sources/GhosttyTerminalView.swift` for confirming launch env; change only if socket env is not actually set where expected.
- Tests may be added/updated under existing cmux test targets if a narrow scanner/poller test pattern exists.
- Avoid unrelated notification UI changes, Claude/Codex detector changes, OpenCode DB/session rewrites, process killing, or global socket configuration edits.

## Validation Commands

```bash
./scripts/reload.sh --tag opencode-socket-scope
```

Optional compile-only fallback:

```bash
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-opencode-socket-scope build
```

Manual dogfood:

1. Run/keep an OpenCode session under main cmux with `CMUX_SOCKET_PATH=~/Library/Application Support/cmux/cmux.sock`.
2. Run tagged dev app with active socket `/tmp/cmux-debug-ctrixin-test.sock`; clear/kill its pane; confirm no periodic completion notification from the main OpenCode process.
3. Launch an OpenCode process from the tagged dev app; complete it; confirm the tagged dev app still receives the completion notification.
4. Repeat the inverse for stable/main app if practical: tagged dev OpenCode must not notify in stable/main.
5. If possible, simulate or inspect an OpenCode process without `CMUX_SOCKET_PATH`; confirm it is ignored.

## Reviewer Checklist

- OpenCode process scan compares candidate env socket against the app's current active socket, not just process name, cwd, DB rows, or cmux-scoped ancestry.
- Socket comparison handles `~` vs absolute path consistently and does not accidentally wildcard on nil/empty values.
- Missing process env or missing `CMUX_SOCKET_PATH` fails closed for OpenCode notifications.
- Claude/Codex notification behavior and OpenCode DB/session completion detection remain otherwise unchanged.
- No external processes are killed and no global socket setting is changed.
- Build/reload/manual evidence is attached; skipped tests include a short rationale.

## Blockers / Unknowns

- Exact poller constructor/call site must be confirmed before choosing whether `TerminalNotificationStore.swift` or a lower-level scanner API owns the current-socket parameter.
- macOS process env access may fail for some PIDs; this must be treated as no-match unless code has a safe, current-app-owned fallback.
- If socket paths can be symlinks or differently expanded, executor must document the chosen normalization and prove it does not merge distinct app sockets.
