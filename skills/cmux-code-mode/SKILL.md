---
name: cmux-code-mode
description: "Discover cmux operations progressively instead of loading a large tool list."
---

# cmux code mode

Use cmux's catalog-backed help before guessing an operation:

```sh
cmux help <area>
cmux docs search "<what you need to do>"
```

`cmux help` shows the operations for an area. `cmux docs search` returns the
matching operation names, classes, selectors, fields, and result types. Read
only the relevant entries, then invoke the normal `cmux` CLI command.

For a multi-step task, put the calls in one TypeScript script and run it with
`cmux run script.ts`. The injected `cmux` value is the generated Node client;
`cmuxArgs` contains arguments after the script path. The runner exposes only
the cmux Unix socket, uses a locked-down Linux sandbox in this prototype, and
fails closed when that sandbox is unavailable.

Harnesses that speak MCP can configure `cmux-code-mode-mcp`. It exposes only
`cmux_docs` and `cmux_exec`; `cmux_exec` uses the same runner and catalog gates
as `cmux run`.
