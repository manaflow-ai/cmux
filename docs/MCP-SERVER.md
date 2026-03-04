# cmux MCP Server

The cmux MCP Server exposes cmux functionality through the [Model Context Protocol](https://modelcontextprotocol.io/) (MCP), allowing AI tools like Claude Desktop and Claude Code to control terminal workspaces, panes, surfaces, browser, and notifications.

## Architecture

```
+-----------------+     stdio      +-----------------+     Unix Socket     +--------------+
|  AI Tool        |<──────────────>|  cmux --mcp     |<───────────────────>| cmux daemon  |
|  (MCP Client)   |                |  (MCP Server)   |                     |              |
+-----------------+                +-----------------+                     +--------------+
```

- **Transport**: stdio (JSON-RPC 2.0 over stdin/stdout)
- **Backend**: Direct Unix socket RPC to the cmux daemon (no subprocess spawning)
- **Authentication**: Inherits socket password from explicit flag, `CMUX_SOCKET_PASSWORD` env var, or stored credential file

## Setup

### Claude Code

Claude Code auto-discovers cmux when running inside a cmux terminal. No manual configuration needed.

### Claude Desktop

Add to your Claude Desktop config (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "cmux": {
      "command": "/Applications/cmux.app/Contents/Resources/bin/cmux",
      "args": ["--mcp"]
    }
  }
}
```

### Custom socket path or password

```bash
cmux --mcp --socket /path/to/cmux.sock --password <password>
```

## Tools

The MCP server exposes 8 grouped tools. Each tool accepts an `action` parameter that maps to a socket RPC method, plus action-specific parameters.

| Tool | Namespace | Description |
|------|-----------|-------------|
| `cmux_system` | `system.*` | Ping, identify context, list capabilities |
| `cmux_workspace` | `workspace.*` | List, create, select, close, rename workspaces |
| `cmux_window` | `window.*` | List, create, close, focus windows |
| `cmux_pane` | `pane.*` | List, focus, create, resize, swap panes |
| `cmux_surface` | `surface.*` | Read terminal output, send input/keys, split, manage surfaces |
| `cmux_notification` | `notification.*` | Create, list, clear notifications |
| `cmux_tab` | `tab.*` | Run tab actions |
| `cmux_browser` | `browser.*` | Navigate, click, fill, screenshot, evaluate JS, and 50+ browser automation actions |

### Example: Read terminal output

```json
{
  "name": "cmux_surface",
  "arguments": {
    "action": "read_text",
    "surface_id": "surface:3"
  }
}
```

### Example: Send text to a terminal

```json
{
  "name": "cmux_surface",
  "arguments": {
    "action": "send_text",
    "text": "ls -la\n"
  }
}
```

## Settings

The MCP server can be enabled or disabled in **Settings > Automation > MCP Server**. When disabled, `cmux --mcp` exits immediately with a JSON-RPC error.

## File Structure

```
CLI/
├── MCPMain.swift         # stdio entry point, CLI integration
├── MCPProtocol.swift     # JSON-RPC 2.0 protocol handler
├── MCPToolRegistry.swift # Grouped tool definitions with action validation
├── MCPBackend.swift      # Direct Unix socket RPC to cmux daemon
└── MCPTypes.swift        # JSON-RPC types and MCP message structures
```
