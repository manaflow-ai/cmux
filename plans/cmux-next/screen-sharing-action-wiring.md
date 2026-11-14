# Screen-sharing action wiring

Leo, 2026-11-13: “in addition there was stuff like... adding proper paths to screen share thru gui/command palette/wherever reasonable”.
Leo, 2026-11-14: “ok but in screen sharing we also want the interaction pathways better”.

The Rust catalog slice #42789 owns the direct pane/tab entries, optional device argument and Stop Viewing action. This native slice binds that contract after its FFI release is pinned. A selected device opens in the explicitly targeted pane; a malformed device or missing explicit pane refuses rather than opening the focused pane or home by accident. With no device, Screen Sharing opens its existing device picker.

A native person action requests View through the existing hub approval path. CLI, MCP, script, remote and page actions keep Connect confirmation, including a control-socket caller that claims user origin. Stop Viewing resolves the existing target tab independently of focus, ends that viewer through the toolbar's own disconnect action and leaves other viewers alone. Non-viewer tabs do not show the stop menu row. Host Stop Sharing remains a distinct action.

The small `MacScreenPages.record(forDevice:requesting:)` helper is reused unchanged from #42277 at `16726f7000ddf7f6713fc02076749d99db70cb4e`; its live owner retains the Machines mapping, native entry points, host permission guide and sharing indicator. No transport is changed.

References and measurement contract: [private interaction reference](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/docs/remote-transport/screen-sharing-references.md) and [path audit](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/docs/remote-transport/screen-sharing-path-audit.md). Tests of targeting and approval boundaries are not live first-frame evidence. Authenticated fleet clicks-to-live and stop readback remain required; no measured before/after count is claimed by this source change.
