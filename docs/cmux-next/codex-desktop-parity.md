# Codex Desktop parity contract

This is the acceptance contract for cmux-next workspace parity with Codex Desktop.

- Preserve the existing **groups** model for workspace organization. Do not add a
  competing “section” vocabulary or duplicate the existing grouping behavior.
- Context menus must work from mouse, keyboard context-menu/Shift-F10, and an
  inactive window's first click. Menus must keep focus, dismiss on outside click,
  and expose Rename, Pin, unread state, Fork, Share, Copy, open in new
  window, Archive, and delete where the object supports them.
- Copy actions must provide stable deeplink, Markdown, and working-directory
  targets. A deeplink carries the host/machine identity when the source is remote;
  opening it must resolve the originating host or show a recoverable unavailable
  state rather than silently opening a local session.
- Background-process rows are live objects, not transcript decoration. They show
  command/state and provide Tail and Stop actions, update from process events,
  recover after reconnect, and navigate back to the owning session/workspace.
- A parity change is complete only after focused web tests pass and the exact
  pushed head has a managed-fleet verification receipt. Do not claim a green
  result from a local native build on the M5 laptop.

Keep implementation details in the owning area instructions. This file is the
cross-cutting behavior contract that review agents should read before editing.
