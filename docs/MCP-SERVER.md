# cmux MCP Server Design Document

## 1. Overview

This document describes the design and implementation of the cmux MCP Server. The MCP Server runs as an embedded mode within the cmux daemon, exposing cmux functionality through the standardized Model Context Protocol.

## 2. Architecture

```
+-----------------+     stdio      +-----------------+
|  Claude Code    |<──────────────>|  cmux MCP Server|
|  (MCP Client)  |                |  (embedded)     |
+-----------------+                +--------+--------+
                                            |
                                    Unix Socket
                                            |
                                     +-------+-------+
                                     | cmux daemon  |
                                     +--------------+
```

### 2.1 Deployment

- **Embedded Mode**: MCP Server compiled into cmux main app
- **Startup**: `cmux --mcp` or `cmux --mcp-stdio`
- **Protocol**: stdio (standard input/output), compatible with Claude Code MCP client
- **Backend Communication**: Reuse existing Unix Socket infrastructure to communicate with cmux daemon

### 2.2 Message Flow

```
1. Client -> Server: initialize (JSON-RPC 2.0)
2. Server -> Client: initialize result (capabilities)
3. Client -> Server: initialized (notification)
4. Client -> Server: tools/list
5. Server -> Client: tools/list result (tool definitions)
6. Client -> Server: tools/call { name: "cmux_xxx", arguments: {...} }
7. Server -> Client: tools/call result (execute cmux CLI command)
```

## 3. Tool Design

### 3.1 Tool Naming Convention

All Tools prefixed with `cmux_`, following `cmux_<category>_<action>` format.

### 3.2 MVP Tools (P0 - Must Implement)

| Priority | Tool Name | Description | Parameters |
|---------|------------|-------------|------------|
| P0 | `cmux_identify` | Get current context (workspace/surface) | `workspace`, `surface`, `no_caller` |
| P0 | `cmux_list_workspaces` | List all workspaces | `workspace` (filter) |
| P0 | `cmux_list_panes` | List all panes | `workspace` |
| P0 | `cmux_list_pane_surfaces` | List surfaces | `workspace`, `pane` |
| P0 | `cmux_read_screen` | Read terminal output | `workspace`, `surface`, `scrollback`, `lines` |
| P0 | `cmux_send_input` | Send input | `workspace`, `surface`, `text` |
| P0 | `cmux_send_key` | Send key press | `workspace`, `surface`, `key` |

### 3.3 Extended Tools (P1 - Recommended)

| Priority | Tool Name | Description | Parameters |
|---------|------------|-------------|------------|
| P1 | `cmux_create_split` | Create split | `direction`, `workspace`, `surface`, `panel` |
| P1 | `cmux_focus_pane` | Focus pane | `pane`, `workspace` |
| P1 | `cmux_new_workspace` | Create workspace | `command` |
| P1 | `cmux_trigger_flash` | Trigger flash | `workspace`, `surface` |
| P1 | `cmux_list_windows` | List all windows | - |

### 3.4 Advanced Tools (P2 - Future)

| Priority | Tool Name | Description |
|---------|------------|-------------|
| P2 | `cmux_browser_open` | Open URL |
| P2 | `cmux_browser_snapshot` | Get snapshot |
| P2 | `cmux_browser_click` | Click element |
| P2 | `cmux_browser_fill` | Fill form |
| P2 | `cmux_browser_wait` | Wait for condition |
| P2 | `cmux_notify` | Send notification |
| P2 | `cmux_set_status` | Set status |
| P2 | `cmux_set_progress` | Set progress |

### 3.5 Tool Schema Example

```json
{
  "name": "cmux_read_screen",
  "description": "Read terminal screen output from a cmux surface.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "workspace": {
        "type": "string",
        "description": "Workspace ID or ref (e.g., 'workspace:1')"
      },
      "surface": {
        "type": "string",
        "description": "Surface ID or ref (e.g., 'surface:7')"
      },
      "scrollback": {
        "type": "boolean",
        "description": "Include scrollback buffer"
      },
      "lines": {
        "type": "number",
        "description": "Number of lines to read"
      }
    }
  }
}
```

## 4. Context Management Strategy

### 4.1 How AI Perceives Current Workspace

The cmux MCP Server manages context through the following mechanisms:

**1. Automatic Context Awareness**
- `cmux_identify` is the core tool, returns caller's workspace and surface
- MCP Server reuses `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID` environment variables
- AI can operate on current context without explicit specification

**2. Context Priority**
```
1. Explicit parameter: cmux_send_input --surface surface:7 "ls"
2. Environment variable: CMUX_SURFACE_ID
3. Context awareness: current surface from cmux_identify
```

**3. State Persistence**
- MCP is a stateful protocol, AI can maintain workspace/surface references across multiple calls
- Tool invocation results include new handles for subsequent use

**4. Error Recovery**
- When surface becomes invalid, return clear error messages
- AI can call `cmux_identify` to re-obtain valid context

### 4.2 Tool Result Format

All Tools return unified JSON format:

```json
{
  "content": [
    {
      "type": "text",
      "text": "{\"status\": \"ok\", \"handles\": {...}}"
    }
  ]
}
```

Internal results contain:
- `status`: Operation status
- `handles`: Related handle references (workspace:1, surface:7, etc.)
- `data`: Actual data (terminal output, list items, etc.)

---

## 5. Implementation Details

### 5.1 Technology Stack

- **Language**: Swift (shared with cmux CLI)
- **Protocol**: JSON-RPC 2.0 over stdio
- **Backend**: Reuse `SocketClient` from `CLI/cmux.swift`

### 5.2 Project Structure

```
CLI/
 ├── cmux.swift           # Existing CLI
 └── MCP/
     ├── MCPServer.swift  # MCP protocol handling
     ├── MCPTools.swift  # Tool definitions
     └── MCPMain.swift   # stdio entry point
```

### 5.3 MCP Protocol Implementation

#### Initialization Handshake

```json
// Client -> Server
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-06-18",
    "capabilities": {},
    "clientInfo": {"name": "claude-desktop", "version": "1.0"}
  }
}

// Server -> Client
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-06-18",
    "capabilities": {
      "tools": {}
    },
    "serverInfo": {"name": "cmux", "version": "0.15.0"}
  }
}
```

#### Tool Invocation

```json
// Client -> Server
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/call",
  "params": {
    "name": "cmux_identify",
    "arguments": {}
  }
}

// Server -> Client
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "{\"workspaceId\": \"...\", \"surfaceId\": \"...\"}"
      }
    ]
  }
}
```

### 5.4 Error Handling

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "error": {
    "code": -32602,
    "message": "Invalid params",
    "data": "Missing required parameter 'surface'"
  }
}
```

Error codes:
- `-32600` - Invalid Request
- `-32601` - Method not found
- `-32602` - Invalid params
- `-32603` - Internal error
- `-32000` - cmux specific error (connection failed, command failed)

## 6. Startup Parameters

```bash
# Start MCP Server mode
cmux --mcp

# Specify socket path
cmux --mcp --socket /tmp/cmux.sock

# JSON output format
cmux --mcp --json
```

## 7. Test Plan

### 7.1 Unit Tests

- JSON-RPC message parsing/serialization
- Tool parameter validation
- Error handling

### 7.2 Integration Tests

- Test using `npx @modelcontextprotocol/inspector`
- Claude Code connection test

### 7.3 E2E Tests

- Complete tool invocation flow
- Browser automation flow

## 8. Todo

- [ ] Phase 1: Preparation
  - [x] Create feature branch
  - [x] MCP protocol research
  - [x] Create design document
- [ ] Phase 2: Core Implementation
  - [ ] Implement MCP protocol layer
  - [ ] Implement Tool mapping layer
  - [ ] Integrate into cmux CLI
- [ ] Phase 3: Polish and Testing
  - [ ] Complete Tool coverage
  - [ ] Error handling
  - [ ] Testing

## 9. References

- [Model Context Protocol Specification](https://modelcontextprotocol.io/specification)
- [MCP SDKs](https://github.com/modelcontextprotocol)
- Existing cmux CLI implementation (`CLI/cmux.swift`)
