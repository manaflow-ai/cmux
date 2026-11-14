# Screen sharing viewer controls

Leo, 2026-11-13: "in addition there was stuff like... adding proper paths to screen share thru gui/command palette/wherever reasonable"

Leo, 2026-11-14: "ok but in screen sharing we also want the interaction pathways better"

References: the private [screen-sharing study](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/docs/remote-transport/screen-sharing-references.md) and [path audit](https://github.com/manaflow-ai/cmuxterm-hq/blob/lane/screen-share-path-audit/docs/remote-transport/screen-sharing-path-audit.md). The reference pattern is a named remote computer, explicit view/control scope, visible quality and measured latency, and persistent disconnect. The Machines entry/host permission/host indicator foundation remains #42277's owner's work.

The viewer exposes its current access as a menu. Choosing another scope requests a new session through the existing hub; it never upgrades a ticket locally. The selected choice does nothing. Full Screen uses the owning AppKit window. Disconnect retains its existing session action. Quality, display choice, Send Keys and refresh retain their existing actions and approval behavior.

The layouts use the same native controls and semantic theme tokens:

- Inline: name and live latency beside all controls when they fit.
- Stacked: the name and live latency above the controls, preserving their labels.
- Compact: name and latency above access, quality, full screen, More and connect/disconnect. More contains display choice, Send Keys and refresh. Very narrow panes wrap whole controls, including long translations; no control extends beyond the pane.

The selected quality stays on its menu button (its tooltip and accessible name at compact widths). The detailed stats preference still controls the extended metrics; measured round-trip latency is visible independently. Missing latency reads as unavailable, never zero. The keyboard release hint remains visible when it fits and in the access control's tooltip otherwise.

All affected geometry uses the toolbar's measured height: video, pointer input and the state card move together. Layout costs are bounded by the fixed control count, independent of workspace and session counts. There are no new timers, observers or motion.

`MacScreenViewerControlsTests` captures the production renderer's three arrangements in light and dark, checks narrow/wide geometry, and exercises scope requests through the existing refusal boundary. Its gallery fixtures are layout evidence only, not authenticated first-frame evidence. Exact-head fleet session captures must separately prove live view and stop.

Phone audit: Screen Sharing already opens a full-screen viewer, provides quality in its options menu, and closes through `dismissViewer`. The chooser exposes View Only and Full Control. An in-session scope switch is not yet wired on the phone; that remains part of the interaction-path follow-up, with no transport changes in this slice.
