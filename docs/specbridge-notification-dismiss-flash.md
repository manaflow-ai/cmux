# SpecBridge: Suppress Idle Pane Notification Flash

Date: 2026-05-26
Repo: `cmux-ctrixin`
Scope: focused regression fix for notification dismiss/focus flash when clicking terminal panes.

## Intent

Keep workspace-level unread notification and bell/sidebar sync behavior, but prevent ordinary terminal pane clicks from triggering the blue notification dismiss/focus flash when no pane-level notification target is being consumed.

## Non-Goals

- Do not revert OpenCode/MMS notification work or unread sync behavior.
- Do not change completion detection or notification creation semantics.
- Do not remove valid flash/focus behavior when user jumps to or consumes an actual unread notification target.
- Do not clear unrelated pane-specific notifications.
- Do not restyle terminal borders or notification UI.

## Task Slices

1. Inspect `TabManager.dismissNotification(tabId:surfaceId:context:)` and callers that pass `surfaceId: nil` vs. pane/surface identifiers.
2. Separate workspace-level focused/unread consumption from pane-level targeted notification consumption so `hasFocusedIndicator` does not imply pane flash during direct pane interaction.
3. Gate `workspace.triggerNotificationDismissFlash(...)` behind evidence of a pane-targeted/focused notification or explicit notification jump/consume context.
4. Preserve workspace-level unread clearing and bell badge sync for `surfaceId: nil` workspace entry/focus flows.
5. Add the smallest regression coverage available in existing Swift test patterns, or record manual validation if no practical harness exists.

## Acceptance Criteria

- Clicking an idle terminal pane with no unread/focused pane notification does not flash the blue border.
- Clicking or entering a workspace with workspace-level unread notification clears the bell/sidebar badge as intended.
- Jumping to an actual pane-targeted unread notification still focuses/flashes as before.
- Pane-specific notifications unrelated to the interaction remain unread/uncleared.
- Build passes.

## Changed-File Boundaries

- Primary file: `Sources/TabManager.swift`, especially `dismissNotification(tabId:surfaceId:context:)`.
- Tests may be added/updated only under existing cmux test targets if a narrow regression test is practical.
- Avoid broad notification-store rewrites, completion detection changes, OpenCode/MMS behavior changes, UI restyling, or daemon/socket refactors.

## Validation Commands

```bash
./scripts/reload.sh --tag notification-dismiss-flash
```

Optional compile-only fallback:

```bash
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-notification-dismiss-flash build
```

Manual dogfood:

1. Open a terminal pane with no unread/focused pane notification; click inside it; confirm no blue border flash.
2. Produce a workspace-level unread notification; enter/click that workspace; confirm unread/bell/sidebar clears.
3. Produce or select a pane-targeted notification; jump to/consume it; confirm the intended flash/focus still occurs.
4. Confirm another pane/workspace unread notification remains unread until explicitly consumed.

## Reviewer Checklist

- `surfaceId: nil` workspace indicator is not treated as a pane-level focused indicator for ordinary pane clicks.
- Flash is emitted only for explicit notification jump/consume or real pane-targeted notification evidence.
- Workspace-level unread and `TerminalNotificationStore` read sync from the previous fix still works.
- Matching/clearing remains scoped to the active workspace/pane and cannot clear unrelated pane notifications.
- Build or reload evidence is attached; skipped tests include a short rationale.

## Blockers / Unknowns

- Exact `context` values and caller intent must be confirmed before deciding the flash gate.
- If current context does not distinguish ordinary pane click from notification jump, add the smallest local discriminator at the call site instead of weakening notification matching globally.
