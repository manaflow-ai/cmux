# MCP server

Give Claude Code, Codex, or any MCP client control of cmux.

cmux mcp serve gives an MCP client the same control of cmux that the CLI has. It talks JSON-RPC on stdin and stdout; nothing listens on the network.

## Turn it on

Agents you start in cmux get it by default: Claude Code and Codex in cmux's terminals and its agent chats. cmux gives it to them when it starts them and never changes their own settings. To turn it off, set cmux Tools for Agents in cmux to Off in Settings > Agents. To turn it back on, choose On there, or run:

```bash
cmux settings set agents.cmuxMcp on --confirm
cmux setup mcp
```

A chat cmux starts on another machine (a linked Mac, a Cloud VM, a headless cmux) follows the answer of the Mac that started it. That machine's own setting applies only to chats started there. A chat started from your phone or the web gets none of cmux's tools, and a cmux server in that agent's own settings answers as if the setting were off.

When cmux cannot be sure which cmux server a Codex launch will load, it gives that launch none and leaves Codex's settings as they are, so Codex starts as it would outside cmux, without cmux's tools. That happens when your own cmux entry is an HTTP server, when a project folder's Codex settings define cmux and Codex has not trusted that folder yet (you may trust it at Codex's prompt), when you resume or fork a session, and when you start Codex with --trust, --worktree, --ignore-user-config or --remote.

This setting chooses what the agents cmux starts get. It is not a security boundary: a program that runs as you can still run the cmux CLI itself.

## Outside cmux (manual)

To use it in an agent you start somewhere else, add it to that agent's own settings yourself. cmux never does this for you; cmux setup mcp prints these lines with the path of your cmux.

```bash
claude mcp add --scope user cmux -- cmux mcp serve
codex mcp add cmux -- cmux mcp serve
```

When cmux is not on the client's PATH, use the one in the app: /Applications/cmux.app/Contents/Resources/bin/cmux. Each agent's own mcp remove cmux takes it out again. Settings > Agents lists any other cmux entry in an agent's own settings, with a Remove button that runs that line. An entry with settings cmux could not put back, such as a token, stays, and Settings says why.

Only two cmux commands write an agent's own settings, and only when you run them: cmux acp desktop link (gives Claude desktop, Claude Code and Codex this Mac's sessions) and cmux acp bridge connect (connects Claude desktop and Codex desktop to cmux). Turning cmux Tools on writes nothing.

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
