# SpecBridge: Workspace Read Syncs Bell Badge

Date: 2026-05-26
Repo: `cmux-ctrixin`
Scope: focused bugfix for workspace unread consumption vs. `TerminalNotificationStore` unread state.

## Intent

When a user focuses or enters the workspace/pane that produced an unread Claude Code notification, consuming the workspace unread state must also mark the matching terminal notification(s) read so the top bell badge and sidebar/card unread state agree.

## Non-Goals

- Do not remove notification history unless existing UX already removes it.
- Do not change OpenCode/Claude detection or notification creation semantics.
- Do not auto-clear notifications merely because the notification popover opens.
- Do not clear unread notifications for unrelated workspaces, panes, or surfaces.
- Preserve explicit/manual workspace-unread semantics if the user marked a workspace unread.

## Task Slices

1. Trace read-consumption flow: identify where sidebar/card unread clears when workspace/tab/pane focus happens.
2. Add a narrow bridge from that consumption point to `TerminalNotificationStore` to mark only matching unread notification records read.
3. Match by stable workspace/pane/surface/session identifiers already present in notification metadata; avoid title/text-only matching unless no stable key exists.
4. Keep notification history and existing clear buttons unchanged; update tests or add a small regression harness if project patterns exist.

## Acceptance Criteria

- Clicking/focusing the unread notification target clears both sidebar/card unread and bell badge for that consumed notification.
- If another unread notification remains in the same workspace, the bell badge still reflects the remaining unread count.
- Unread notifications in other workspaces/panes remain unread.
- Previous `x` / `全部清除` notification behavior still works.

## Changed-File Boundaries

- Primary candidates: `Sources/TerminalNotificationStore.swift`, `Sources/ContentView.swift`, `Sources/TabManager.swift`, `Sources/Update/UpdateTitlebarAccessory.swift`.
- Tests may be added/updated under existing cmux test targets only if needed for the regression.
- Avoid unrelated UI restyling, notification detection rewrites, socket/daemon changes, or broad tab/workspace refactors.

## Validation Commands

```bash
./scripts/reload.sh --tag unread-bell-sync
```

Optional compile-only fallback:

```bash
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-unread-bell-sync build
```

Manual dogfood:

1. Produce a Claude Code notification that marks a workspace/card unread.
2. Click the corresponding workspace/tab and confirm blue focus flash plus sidebar unread clear.
3. Confirm top bell badge clears only for the consumed notification and remains for unrelated unread notifications.
4. Re-check notification `x` and `全部清除` actions.

## Reviewer Checklist

- The bridge is called only from actual workspace/pane unread consumption, not popover open/render.
- Matching is scoped to the consumed target and cannot clear other workspace/pane notifications.
- Multiple unread notifications are counted correctly after partial consumption.
- Manual unread state is not silently erased unless it is the consumed focus target by existing UX rules.
- Build/dogfood evidence is recorded, including any skipped test rationale.

## Blockers / Unknowns

- Exact notification metadata keys and read-consumption entrypoint must be confirmed in code before implementation.
- If notifications lack stable workspace/pane/surface identity, executor must add the smallest metadata bridge at creation time rather than use brittle display text matching.
