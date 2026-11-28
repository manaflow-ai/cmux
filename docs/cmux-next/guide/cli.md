# CLI and MCP reference

Every cmux CLI command and which are also MCP tools.

Every action in the app can run from the CLI. This page is generated from the action catalog. It cannot drift: a test fails when the catalog changes and this page does not.

```bash
cmux <noun> <verb>
cmux action list
cmux action run <id>
```

A verb marked no under MCP tool is CLI only, because it needs credentials, ends the app, changes the system, or only moves focus.

The full table is generated from the app's own catalog. In a cmux terminal, `cmux --help`, `cmux <scope> --help` and `cmux action list` print it.

- [MCP server](mcp.md)
