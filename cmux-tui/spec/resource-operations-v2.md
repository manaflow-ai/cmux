# Public operation inventory

[`resource-operations-v2.json`](resource-operations-v2.json) is normative.
This page is a compact index; it does not replace the catalog's exact
selectors, fields, results, errors, constraints, or stream types.

## Transported operations

`cmux.protocol/2` transports the operations in `resource-operations-v2.json` for one local mux
session. `machine.list/get` can explicitly opt in to admitted remote metadata
with `catalog:true`; this supplies no remote execution route. Cross-machine
session aggregation and provider lifecycle require a later broker protocol.

| Class | Count | Semantics |
| --- | ---: | --- |
| `read` | 91 | Reads state and forbids an idempotency key |
| `mutation` | 202 | Requires an idempotency key and returns a mutation result |
| `stream_open` | 6 | Opens a connection-owned typed stream |
| `connection_control` | 13 | Changes only connection-local state |

The 41 mutations with an external effect may return the non-retryable
`mutation.indeterminate` error after a crash. The same key is never repeated
automatically.

The eight `CreatedPath` operations accept `correlation_key`, defaulting to the
idempotency key. `session.creation.resolve` returns the durable creation state
and exact retry instruction. The correlation fingerprint excludes revision,
correlation, and idempotency metadata.

| Target | Count | Operations |
| --- | ---: | --- |
| `agent` | 7 | `agent.list`, `agent.message.list`, `agent.message.mark`, `agent.message.release`, `agent.message.send`, `agent.message.unsend`, `agent.report` |
| `browser` | 15 | `browser.activate`, `browser.attach`, `browser.back`, `browser.close`, `browser.forward`, `browser.get`, `browser.input.key`, `browser.input.mouse`, `browser.input.text`, `browser.input.wheel`, `browser.list`, `browser.navigate`, `browser.reload`, `browser.viewer.release`, `browser.viewer.resize` |
| `browser_device` | 3 | `browser.devices.add_custom`, `browser.devices.list`, `browser.devices.remove_custom` |
| `browser_profile` | 2 | `browser.profile.create`, `browser.profile.list` |
| `chief` | 15 | `chief.automation.list`, `chief.automation.update`, `chief.engine.get`, `chief.engine.set`, `chief.profile.adopt`, `chief.profile.avatar.get`, `chief.profile.avatar.set`, `chief.profile.create`, `chief.profile.delete`, `chief.profile.get`, `chief.profile.history`, `chief.profile.list`, `chief.profile.undo`, `chief.profile.update`, `chief.stop` |
| `client` | 8 | `client.cell_pixels.set`, `client.detach`, `client.get`, `client.list`, `client.metadata.update`, `client.sizing.release`, `client.sizing.set`, `origin.confirmation.issue` |
| `closed` | 3 | `closed.delete`, `closed.list`, `closed.reopen` |
| `conversation` | 8 | `conversation.draft`, `conversation.events`, `conversation.get`, `conversation.history`, `conversation.list`, `conversation.search`, `conversation.send`, `conversation.typing` |
| `credential` | 3 | `credential.mint`, `credential.rotate`, `credential.verify` |
| `frontend_projection` | 2 | `frontend_projection.get`, `frontend_projection.put` |
| `git` | 16 | `git.branches`, `git.checkpoint.create`, `git.checkpoint.diff`, `git.checkpoint.get`, `git.checkpoint.list`, `git.checkpoint.pin`, `git.checkpoint.unpin`, `git.commit`, `git.diff`, `git.files.list`, `git.files.search`, `git.push`, `git.status`, `git.worktree.apply`, `git.worktree.create`, `git.worktree.remove` |
| `keybinding` | 4 | `keybindings.get`, `keybindings.remove`, `keybindings.reset`, `keybindings.set` |
| `machine` | 2 | `machine.get`, `machine.list` |
| `notification` | 4 | `notification.ack`, `notification.clear`, `notification.create`, `notification.list` |
| `pairing_request` | 2 | `pairing_request.list`, `pairing_request.resolve` |
| `palette_usage` | 5 | `palette_usage.forget`, `palette_usage.get`, `palette_usage.hide`, `palette_usage.import`, `palette_usage.record` |
| `pane` | 14 | `pane.close`, `pane.create`, `pane.focus`, `pane.focus_direction`, `pane.get`, `pane.list`, `pane.neighbor.get`, `pane.rename`, `pane.run`, `pane.split`, `pane.split_ratio.set`, `pane.swap`, `pane.viewport_width.set`, `pane.zoom` |
| `participant` | 2 | `participant.avatar.get`, `participant.avatar.set` |
| `request` | 1 | `request.cancel` |
| `room` | 8 | `room.create`, `room.delete`, `room.follow`, `room.list`, `room.move`, `room.pin`, `room.unpin`, `room.update` |
| `saved_tab_group` | 4 | `saved_tab_group.delete`, `saved_tab_group.list`, `saved_tab_group.reopen`, `saved_tab_group.save` |
| `screen` | 11 | `column.update`, `screen.close`, `screen.create`, `screen.focus`, `screen.get`, `screen.layout.export`, `screen.layout.undo`, `screen.list`, `screen.move`, `screen.rename`, `screen.update` |
| `screen_group` | 7 | `screen_group.add_screens`, `screen_group.create`, `screen_group.get`, `screen_group.list`, `screen_group.remove_screens`, `screen_group.ungroup`, `screen_group.update` |
| `session` | 26 | `layout.bulk`, `session.creation.resolve`, `session.events`, `session.get`, `session.journal.append`, `session.journal.checkpoint.create`, `session.journal.checkpoint.list`, `session.journal.hook.list`, `session.journal.hook.put`, `session.journal.producer.list`, `session.journal.producer.put`, `session.journal.restore.preview`, `session.journal.segment.list`, `session.journal.segment.seal`, `session.journal.subscribe`, `session.list`, `session.open`, `session.ping`, `session.reload_config`, `session.shutdown`, `session.snapshot`, `session.terminal_defaults.update`, `session.window.title.clear`, `session.window.title.set`, `workspace_checklist.list`, `workspace_status.list` |
| `sidebar_layout` | 20 | `sidebar.adopt`, `sidebar.apply`, `sidebar.get`, `sidebar.group.create`, `sidebar.group.ungroup`, `sidebar.group.update`, `sidebar.item.add`, `sidebar.item.remove`, `sidebar.item.remove_ref`, `sidebar.item.update`, `sidebar.move`, `sidebar.pin`, `sidebar.reset`, `sidebar.section.add`, `sidebar.section.move`, `sidebar.section.remove`, `sidebar.section.update`, `sidebar.unpin`, `sidebar_layout.get`, `sidebar_layout.update` |
| `project` | 6 | `project.add`, `project.list`, `project.observe`, `project.remove`, `project.sync`, `project.update` |
| `setting` | 7 | `settings.get`, `settings.list`, `settings.reset`, `settings.reset_all`, `settings.schema`, `settings.set`, `settings.snapshot` |
| `sidebar_view` | 6 | `sidebar_view.attach`, `sidebar_view.ensure`, `sidebar_view.get`, `sidebar_view.input`, `sidebar_view.reload`, `sidebar_view.resize` |
| `stash` | 5 | `stash.create`, `stash.delete`, `stash.import`, `stash.list`, `stash.restore` |
| `stream` | 1 | `stream.cancel` |
| `tab` | 15 | `browser.profile.open`, `browser.tab.emulate`, `browser.tab.emulate.clear`, `browser.tab.set_profile`, `tab.close`, `tab.create_browser`, `tab.create_terminal`, `tab.focus`, `tab.get`, `tab.list`, `tab.move`, `tab.pin`, `tab.rename`, `tab.unpin`, `tab.update` |
| `tab_group` | 9 | `tab_group.add_tabs`, `tab_group.close`, `tab_group.create`, `tab_group.get`, `tab_group.list`, `tab_group.move`, `tab_group.remove_tabs`, `tab_group.ungroup`, `tab_group.update` |
| `terminal` | 23 | `terminal.attach`, `terminal.close`, `terminal.copy`, `terminal.get`, `terminal.history.clear`, `terminal.history.read`, `terminal.input.focus`, `terminal.input.keys`, `terminal.input.mouse`, `terminal.input.write`, `terminal.list`, `terminal.move`, `terminal.output_read`, `terminal.process.get`, `terminal.project`, `terminal.renderer_grant.create`, `terminal.screen.read`, `terminal.state.read`, `terminal.viewer.release`, `terminal.viewer.resize`, `terminal.viewport.scroll`, `terminal.wait`, `terminal.wait_exit` |
| `window_record` | 3 | `window_record.delete`, `window_record.list`, `window_record.put` |
| `workspace` | 27 | `workspace.agent_folder.set`, `workspace.agent_start.get`, `workspace.close`, `workspace.create`, `workspace.ensure_app`, `workspace.ensure_home`, `workspace.focus`, `workspace.get`, `workspace.layout.apply`, `workspace.list`, `workspace.move`, `workspace.open_url`, `workspace.place`, `workspace.placement.list`, `workspace.rename`, `workspace.run`, `workspace.update`, `workspace_checklist.add`, `workspace_checklist.remove`, `workspace_checklist.update`, `workspace_log.append`, `workspace_log.clear`, `workspace_log.list`, `workspace_progress.clear`, `workspace_progress.set`, `workspace_status.clear`, `workspace_status.set` |
| `workspace_group` | 5 | `workspace_group.create`, `workspace_group.delete`, `workspace_group.list`, `workspace_group.move`, `workspace_group.update` |

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

The noun-first CLI also exposes `agent plugin install|list|use|update|remove`.
Those commands clone, build, replace, and configure an executable on the
caller filesystem, so they stay outside this transport catalog by design.
The agent-plugin lifecycle and its generic journal contract are specified in
[`plugins.md`](plugins.md).

Browser attachment frames carry a required nullable `pointer_frame_seq`.
Mouse and wheel mutations require the exact non-null decimal token from the
rendered frame used to choose their coordinates. A null or stale token cannot
authorize pointer input.
