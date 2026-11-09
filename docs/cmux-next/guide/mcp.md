# MCP server

Give Claude Code, Codex, or any MCP client control of cmux.

cmux mcp serve gives an MCP client the same control of cmux that the CLI has. It talks JSON-RPC on stdin and stdout; nothing listens on the network. Agent chats inside cmux have it already.

## Turn it on

For clients outside cmux, the server is off until you turn it on:

```bash
cmux settings set mcp.enabled true
cmux mcp tools
```

## Claude Code

```bash
claude mcp add cmux -- cmux mcp serve
```

## Codex

```toml
# ~/.codex/config.toml
[mcp_servers.cmux]
command = "cmux"
args = ["mcp", "serve"]
```

When cmux is not on the client's PATH, use the one in the app: /Applications/cmux.app/Contents/Resources/bin/cmux.

## Tools

By default the server offers two tools: cmux_docs searches every cmux tool, and cmux_exec runs a short script that calls them. This keeps the client's tool list small. With --all-tools it offers every tool directly:

- one tool per app action, named app_ and the CLI words (cmux workspace rename is app_workspace_rename). The CLI and MCP reference lists each name;
- tools for workspaces, panes, tabs, terminals, and git (workspace_list, terminal_input_write, git_status);
- browser tools (browser_navigate, browser_repl_eval) and agent tools (agents_snapshot, agents_wait).

```bash
cmux mcp serve --all-tools
cmux mcp tools --json
```

cmux mcp tools --json lists every tool with its input schema, and every action it leaves out with the reason. A tool never steals focus unless its purpose is focus.

- [CLI and MCP reference](cli.md)
