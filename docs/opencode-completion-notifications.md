# OpenCode completion notifications

Status: local cmux-ctrixin iteration, `Agent-Step: 0.2.x`.

## Intent

Detect OpenCode assistant completions without adding OpenCode hooks or parsing terminal output. The implementation uses OpenCode local state (`~/.local/share/opencode/opencode.db`) plus cmux-scoped process environment (`CMUX_WORKSPACE_ID` / `CMUX_SURFACE_ID`) to map a completion back to the correct workspace pane.

## Current behavior

- Polls active cmux-scoped OpenCode processes every 3 seconds from `TerminalNotificationStore`.
- Reads a snapshot of `opencode.db` and queries the latest assistant message for each mapped session.
- Seeds the first observed message fingerprint and does not notify for historical completions.
- Emits one `OpenCode completed` notification when the latest assistant message fingerprint changes.
- Does not infer or emit `Needs input`; that remains out of scope until OpenCode exposes a reliable actionable-waiting signal.
- Uses an in-memory overlap guard so timer ticks do not run concurrent DB/process polls.

## Known limits

- Restarting cmux resets the in-memory fingerprints, so old completions are seeded rather than replayed.
- Detection depends on OpenCode DB tables `message(session_id,time_created,data)` and assistant JSON containing `"role":"assistant"`.
- Live QA is still required for each OpenCode launcher shape (plain `opencode`, `omo`, and MMS-backed `opencode`).

## Manual QA

1. Launch the tagged dev app.
2. Open an OpenCode pane in cmux and wait a few seconds; no old notification should appear.
3. Send a new prompt and wait for the assistant response to finish.
4. Confirm one unread `OpenCode completed` notification appears.
5. Click the notification/sidebar unread card and confirm it focuses the matching pane.
6. Send another prompt and confirm exactly one additional completion notification.
7. Confirm no `Needs input` status is emitted for normal idle/completed state.
