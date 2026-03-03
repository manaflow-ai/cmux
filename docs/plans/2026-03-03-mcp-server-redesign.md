# MCP Server Redesign: Direct Socket + Grouped Tools

**Date:** 2026-03-03
**Status:** Approved

## Problem

The MCP server spawns `cmux` CLI subprocesses to execute commands. This causes:
1. **Bug:** `read-screen` and `new-workspace` reject `--socket`/`--id-format` CLI flags that `MCPBackend` appends to all commands
2. **Overhead:** ~50ms per call from process spawn
3. **Fragility:** Text output parsing, CLI flag compatibility across subcommands

## Solution

Replace CLI subprocess execution with direct Unix socket communication using cmux's socket v2 RPC protocol.

## Architecture

```
Before: MCP Client → stdio → MCPBackend → spawn cmux CLI → CLI → socket → response
After:  MCP Client → stdio → MCPBackend → Unix socket directly → response
```

## Socket v2 RPC Adapter

cmux socket uses a custom RPC protocol, NOT JSON-RPC 2.0:

| Field        | JSON-RPC 2.0              | cmux socket v2                    |
|-------------|---------------------------|-----------------------------------|
| Success     | `{jsonrpc:"2.0", result}` | `{ok:true, result}`               |
| Error       | `{jsonrpc:"2.0", error}`  | `{ok:false, error:{code,message}}`|
| No `jsonrpc`| Required                  | Absent                            |

MCPBackend must translate between these formats.

## Grouped Tools with Action Validation

~10 MCP tools, each grouping a namespace of socket methods. Every tool accepts an `action` parameter plus action-specific params.

Each tool has an internal action registry for strict validation:

```swift
struct ActionDef {
    let required: [String]    // required param names
    let optional: [String]    // optional param names
}
```

### Tool Groups

| MCP Tool             | Socket namespace  | Actions                                                                    |
|---------------------|-------------------|----------------------------------------------------------------------------|
| `cmux_system`       | `system.*`        | ping, identify, capabilities                                              |
| `cmux_workspace`    | `workspace.*`     | list, create, select, close, rename, current, last, next, previous, reorder, action, move_to_window |
| `cmux_window`       | `window.*`        | list, create, close, focus, current                                        |
| `cmux_pane`         | `pane.*`          | list, focus, create, surfaces, resize, swap, break, join, last             |
| `cmux_surface`      | `surface.*`       | list, focus, read_text, send_text, send_key, split, close, create, current, move, reorder, trigger_flash, clear_history, health, action, refresh |
| `cmux_notification` | `notification.*`  | create, create_for_surface, create_for_target, list, clear                 |
| `cmux_tab`          | `tab.*`           | action                                                                     |
| `cmux_browser`      | `browser.*`       | navigate, click, fill, screenshot, eval, type, press, hover, check, uncheck, select, focus, scroll, wait, snapshot, and 50+ more |

### Tool Description Format

Each tool's MCP description lists available actions and their params, e.g.:

```
Actions:
- list: List all workspaces. Params: (none)
- select: Switch to workspace. Params: workspace_id (required)
- create: Create workspace. Params: command (optional)
- close: Close workspace. Params: workspace_id (required)
- rename: Rename workspace. Params: workspace_id (required), name (required)
```

## MCPBackend Rewrite

### Connection Management

- Persistent Unix socket connection (not per-request)
- Auto-reconnect on failure (one retry)
- NSLock for thread safety

### Core RPC Method

```swift
func rpc(method: String, params: [String: Any] = [:]) throws -> [String: Any] {
    // 1. Ensure connected (reconnect if needed)
    // 2. Send: {"id": N, "method": method, "params": params}\n
    // 3. Read response line
    // 4. Parse: {ok: bool, result/error: ...}
    // 5. If ok=false, throw MCPError with error details
    // 6. Return result dict
}
```

### Ref ID Support

Socket API natively accepts ref IDs (`workspace:3`, `surface:9`). No UUID normalization needed.

### Authentication

If password is configured, send `auth.login` after connecting. Priority: explicit param > env var > stored credential.

## Files to Change

| File | Change |
|------|--------|
| `CLI/MCPBackend.swift` | Complete rewrite: socket connection instead of Process spawn |
| `CLI/MCPToolRegistry.swift` | Replace 13 individual tool classes with ~10 grouped tool classes |
| `CLI/MCPProtocol.swift` | No changes needed |
| `CLI/MCPTypes.swift` | No changes needed |
| `CLI/MCPMain.swift` | No changes needed |

## Implementation Order

1. **MCPBackend** — Socket connection + rpc() method
2. **Grouped tools** — New tool classes with action validation
3. **MCPToolRegistry** — Register new tools
4. **Test** — Verify all tools via live MCP connection
