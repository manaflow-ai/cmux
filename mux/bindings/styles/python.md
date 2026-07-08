# Python Binding Style

Generate a zero-dependency synchronous Python package under `mux/bindings/python/cmux_mux_client/`.

Requirements:

- Use only the Python standard library.
- Provide `MuxClient` as the main entry point.
- Export `EventStream` and `AttachStream`.
- Use dataclasses for typed results, tree objects, and stream events.
- Method names are snake_case and map 1:1 to implemented command names.
- Preserve server error strings in `CommandError`.
- Distinguish command errors, connection errors, protocol errors, and timeouts.
- Resolve the default socket as `$TMPDIR/cmux-mux-<uid>/<session>.sock`, with explicit socket path override.
- Use separate sockets for command requests, subscribe streams, and attach streams.
- Provide `MuxClient.request(cmd, **params) -> dict` as the raw JSON response entry point.
- Implement `subscribe()` as an iterator over event objects.
- Implement `attach_surface(surface)` as an iterator over attach event objects.
- Support protocol v5 attach streams and reject protocol v6 attach streams unless `resized` replay handling is implemented.
- Include consumer-side methods for `move_tab(surface, pane, index)` and `move_workspace(workspace, index)`.
- Do not implement proposed commands such as `wait-for`, `run`, `send-key`, `copy`, `ids`, `notify`, `list-agents`, or `report-agent` as active protocol methods.

Public API shape:

- `MuxClient.identify() -> IdentifyResult`
- `MuxClient.list_workspaces() -> Tree`
- Mutating commands returning `{}` should return `EmptyResult`.
- Create commands returning `{surface}` should return `SurfaceResult`.
- `read_screen()` and `vt_state()` return typed dataclasses.
- `send()` accepts `text`, `bytes_data`, or both, matching v5 write order.

The package must be importable with:

```python
from cmux_mux_client import MuxClient
```
