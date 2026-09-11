# cmux home TypeScript prototype

This package is a standalone Bun/OpenTUI prototype for `cmux home`. It models the home screen around cmux agent/session primitives, then renders either an interactive terminal view or a deterministic `--once` summary for smoke checks.

Run it from this directory:

```bash
bun install
bun src/cli.ts --once
bun src/cli.ts --data ./example-state.json --once
bun src/cli.ts --data '{"sessions":[]}' --once
```

The interactive view uses `@opentui/core`. No fallback renderer is currently needed. If OpenTUI becomes a blocker later, the parsing, grouping, adapter, and summary modules are independent of the renderer.

`--data` accepts either a JSON file path or inline JSON. Without `--data`, the CLI looks for nearby shared state examples such as `../state.json`, `../example-state.json`, and `../shared/state.json`, then falls back to built-in demo state.
