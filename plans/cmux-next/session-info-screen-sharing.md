# Session Info screen sharing

Leo, 2026-11-13: "in addition there was stuff like... adding proper paths to screen share thru gui/command palette/wherever reasonable"

Leo, 2026-11-14: "ok but in screen sharing we also want the interaction pathways better"

## Shared routing contract

`cmux-window-rules::screen_share` selects an existing action from one explicitly resolved machine. The app reads native facts and calls `window_remote_screen_share` over the existing JSON FFI. Local sharing uses `macScreen.shareThisMac`; a Cloud host uses its existing Open Desktop action; a registered macOS host uses `macScreen.open` with its authenticated device UUID. This decision grants no access: the existing permission and host-approval flows remain authoritative.

Device identity must match the hub record by UUID, including normalization. A missing, removed, nil, mismatched, offline or unsupported device does not become the local machine or the generic picker. No display-name matching or focused-machine fallback occurs.

A chat entry supplies the daemon's exact session summary as well as its expected session ID. A stale summary refuses. A peer's chat is not necessarily on its containing daemon: until a peer has an authenticated machine mapping, it refuses rather than sharing that daemon's screen. Chief is outside this slice. Machine entry points have an explicit native target and omit chat facts.

The route examines one machine and one device; its cost is independent of workspace, session and fleet counts. It creates no timer, observer, task or connection.

## Surface design and follow-on

Session Info retains its machine row, followed by one text action. Compare three arrangements using the existing native row renderer: a text action below the machine (preferred for discoverability at narrow widths), an inline trailing action, and a compact icon action. Keep the existing typography, semantic colors and spacing; add no container or motion. Live state and Stop require authoritative session state, not a successful dispatch.

References: the private screen-sharing study at `cmuxterm-hq/docs/remote-transport/screen-sharing-references.md`, the surface specification at `leo-workspace/design/session-info.md`, and `cmux-design-references@1bbc3657dc8d:apps/cmux/live/sidebar-session-rail-environment-and-tasks.png`.

This routing prerequisite does not mount a button or claim a live path. The native adapter, mounted Session Info/palette/chevron actions, gallery and authenticated readback follow the app FFI publication. They must preserve `(machine, tab)` scope, revalidate the session after any asynchronous read, and show an unavailable reason if the FFI or identity mapping is missing.

## Evidence

Unit tests cover explicit identity, removal and rotation, offline/unsupported hosts, local and Cloud routes, stale chat summaries and peer/Chief refusal. The JSON FFI test covers the wire shape. Tests run through `cmux-ci`; adding a test is not a passing receipt.

Live acceptance requires an authenticated decoded frame from the targeted host, then viewer Stop and host Stop readback. Count the selected action separately from opening its menu, first-use permission, and host approval. Mac and Linux hosts are the executable matrix; Windows awaits the host port tracked in the remote-desktop plan. Clicks-to-live remain unmeasured until that capture succeeds.
