# cmux MCP Server Implementation Plan

## Overview

This document outlines the implementation plan for the cmux MCP Server, following the design in `docs/MCP-SERVER.md`.

## File Structure

```
CLI/
├── cmux.swift              # Existing CLI (no changes)
└── MCP/
    ├── MCPMain.swift       # Entry point: argument parsing, stdio loop
    ├── MCPTypes.swift      # JSON-RPC types, MCP message structures
    ├── MCPProtocol.swift   # Protocol handling: initialize, tools/list, tools/call
    ├── MCPToolRegistry.swift # Tool registration and discovery
    ├── MCPTools/
    │   ├── Tool.swift      # Base Tool protocol
    │   ├── IdentifyTool.swift    # cmux_identify
    │   ├── ListTools.swift      # cmux_list_* tools
    │   ├── ReadScreenTool.swift # cmux_read_screen
    │   ├── SendInputTool.swift  # cmux_send_input, cmux_send_key
    │   └── SplitTools.swift     # cmux_create_split, cmux_focus_pane
    └── MCPBackend.swift    # SocketClient wrapper for cmux daemon communication
```

## Implementation Order

### Phase 1: Foundation (Day 1)

1. **MCPTypes.swift**
   - JSON-RPC 2.0 types: Request, Response, Error, Notification
   - MCP-specific types: InitializeParams, InitializeResult, Tool, ToolCallParams
   - JSON serialization/deserialization

2. **MCPMain.swift**
   - CLI argument parsing (`--mcp` flag)
   - stdio input loop (read line-by-line)
   - Output writing (write JSON-RPC responses)
   - Basic error handling

### Phase 2: Protocol Layer (Day 1-2)

3. **MCPProtocol.swift**
   - `initialize` handler: validate protocol version, return capabilities
   - `initialized` notification handler
   - `tools/list` handler: return registered tools
   - `tools/call` handler: dispatch to tool implementations

4. **MCPToolRegistry.swift**
   - Tool registration API
   - Tool discovery by name
   - Tool parameter schema validation

### Phase 3: Tool Implementation (Day 2-3)

5. **MCPBackend.swift**
   - Wrapper around SocketClient from cmux.swift
   - Execute cmux commands and parse results
   - Handle connection errors

6. **Tool Implementations**

   | Order | File | Tools |
   |-------|------|-------|
   | 6.1 | IdentifyTool.swift | `cmux_identify` |
   | 6.2 | ListTools.swift | `cmux_list_workspaces`, `cmux_list_panes`, `cmux_list_pane_surfaces`, `cmux_list_windows` |
   | 6.3 | ReadScreenTool.swift | `cmux_read_screen` |
   | 6.4 | SendInputTool.swift | `cmux_send_input`, `cmux_send_key` |
   | 6.5 | SplitTools.swift | `cmux_create_split`, `cmux_focus_pane`, `cmux_new_workspace`, `cmux_trigger_flash` |

### Phase 4: Integration (Day 3)

7. **CLI Integration**
   - Add `--mcp` flag to cmux CLI argument parser
   - Conditionally launch MCP server vs normal CLI mode

## Each File's Responsibility

| File | Responsibility |
|------|----------------|
| MCPMain.swift | Entry point, stdio loop, command-line interface |
| MCPTypes.swift | Data models for JSON-RPC and MCP protocol |
| MCPProtocol.swift | Protocol state machine, method dispatch |
| MCPToolRegistry.swift | Tool registration, lookup, validation |
| MCPBackend.swift | Execute cmux commands via Unix Socket |
| Tool.swift | Base protocol all tools implement |
| *_Tool.swift | Individual tool implementations |

## Dependencies

```
MCPMain.swift
    └── MCPProtocol.swift
            ├── MCPTypes.swift
            ├── MCPToolRegistry.swift
            │       └── Tool.swift (protocol)
            └── MCPBackend.swift
                    └── cmux.swift (SocketClient)
```

## Testing Strategy

### Unit Tests
- JSON-RPC parsing/serialization
- Tool parameter validation
- Error code mapping

### Integration Tests
- Mock SocketClient for unit tests
- Use `cmux --mcp` with test surface

### E2E Tests
- Connect via Claude Code MCP
- Verify tool invocation end-to-end

## Notes

- Reuse existing `SocketClient` from `CLI/cmux.swift` for daemon communication
- All tool names must be prefixed with `cmux_`
- Follow JSON-RPC 2.0 specification strictly
- Handle stdio disconnection gracefully (exit 0)
