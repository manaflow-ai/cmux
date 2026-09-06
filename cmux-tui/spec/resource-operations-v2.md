# Public operation inventory

[`resource-operations-v2.json`](resource-operations-v2.json) is normative.
This page is a compact index; it does not replace the catalog's exact
selectors, fields, results, errors, constraints, or stream types.

## Transported operations

`cmux.protocol/2` transports 125 operations for exactly one local mux
session. Cross-machine aggregation and provider lifecycle require a later
broker protocol.

| Class | Count | Semantics |
| --- | ---: | --- |
| `read` | 41 | Reads state and forbids an idempotency key |
| `mutation` | 67 | Requires an idempotency key and returns a mutation result |
| `stream_open` | 5 | Opens a connection-owned typed stream |
| `connection_control` | 12 | Changes only connection-local state |

The 40 mutations with an external effect may return the non-retryable
`mutation.indeterminate` error after a crash. The same key is never repeated
automatically.

The eight `CreatedPath` operations accept `correlation_key`, defaulting to the
idempotency key. `session.creation.resolve` returns the durable creation state
and exact retry instruction. The correlation fingerprint excludes revision,
correlation, and idempotency metadata.

| Target | Count | Operations |
| --- | ---: | --- |
| `agent` | 2 | `agent.list`, `agent.report` |
| `browser` | 15 | `browser.activate`, `browser.attach`, `browser.back`, `browser.close`, `browser.forward`, `browser.get`, `browser.input.key`, `browser.input.mouse`, `browser.input.text`, `browser.input.wheel`, `browser.list`, `browser.navigate`, `browser.reload`, `browser.viewer.release`, `browser.viewer.resize` |
| `client` | 7 | `client.cell_pixels.set`, `client.detach`, `client.get`, `client.list`, `client.metadata.update`, `client.sizing.release`, `client.sizing.set` |
| `frontend_projection` | 2 | `frontend_projection.get`, `frontend_projection.put` |
| `machine` | 2 | `machine.get`, `machine.list` |
| `notification` | 2 | `notification.create`, `notification.list` |
| `pairing_request` | 2 | `pairing_request.list`, `pairing_request.resolve` |
| `pane` | 14 | `pane.close`, `pane.create`, `pane.focus`, `pane.focus_direction`, `pane.get`, `pane.list`, `pane.neighbor.get`, `pane.rename`, `pane.run`, `pane.split`, `pane.split_ratio.set`, `pane.swap`, `pane.viewport_width.set`, `pane.zoom` |
| `request` | 1 | `request.cancel` |
| `screen` | 8 | `screen.close`, `screen.create`, `screen.focus`, `screen.get`, `screen.layout.export`, `screen.layout.undo`, `screen.list`, `screen.rename` |
| `session` | 23 | `session.creation.resolve`, `session.events`, `session.get`, `session.journal.append`, `session.journal.checkpoint.create`, `session.journal.checkpoint.list`, `session.journal.hook.list`, `session.journal.hook.put`, `session.journal.producer.list`, `session.journal.producer.put`, `session.journal.restore.preview`, `session.journal.segment.list`, `session.journal.segment.seal`, `session.journal.subscribe`, `session.list`, `session.open`, `session.ping`, `session.reload_config`, `session.shutdown`, `session.snapshot`, `session.terminal_defaults.update`, `session.window.title.clear`, `session.window.title.set` |
| `sidebar_view` | 6 | `sidebar_view.attach`, `sidebar_view.ensure`, `sidebar_view.get`, `sidebar_view.input`, `sidebar_view.reload`, `sidebar_view.resize` |
| `stream` | 1 | `stream.cancel` |
| `tab` | 8 | `tab.close`, `tab.create_browser`, `tab.create_terminal`, `tab.focus`, `tab.get`, `tab.list`, `tab.move`, `tab.rename` |
| `terminal` | 22 | `terminal.attach`, `terminal.close`, `terminal.copy`, `terminal.get`, `terminal.history.clear`, `terminal.history.read`, `terminal.input.focus`, `terminal.input.keys`, `terminal.input.mouse`, `terminal.input.write`, `terminal.list`, `terminal.move`, `terminal.process.get`, `terminal.project`, `terminal.renderer_grant.create`, `terminal.screen.read`, `terminal.state.read`, `terminal.viewer.release`, `terminal.viewer.resize`, `terminal.viewport.scroll`, `terminal.wait`, `terminal.wait_exit` |
| `workspace` | 9 | `workspace.close`, `workspace.create`, `workspace.focus`, `workspace.get`, `workspace.layout.apply`, `workspace.list`, `workspace.move`, `workspace.rename`, `workspace.run` |

## Local operations

These six operations manage sidebar plugins on the caller's filesystem. They
never use a protocol envelope:

- `sidebar_plugin.install`
- `sidebar_plugin.list`
- `sidebar_plugin.remove`
- `sidebar_plugin.update`
- `sidebar_plugin.use`
- `sidebar_plugin.use_builtin`

High-level transported SDKs expose sidebar views, not plugin resource handles.
The noun-first CLI exposes the local operations under `sidebar plugin`.

Browser attachment frames carry a required nullable `pointer_frame_seq`.
Mouse and wheel mutations require the exact non-null decimal token from the
rendered frame used to choose their coordinates. A null or stale token cannot
authorize pointer input.
