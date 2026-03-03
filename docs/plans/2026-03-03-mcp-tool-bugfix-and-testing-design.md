# MCP Tool Bugfix and Testing Design

## Date: 2026-03-03

## Problem

Two MCP tools fail at runtime due to incorrect CLI command construction:

1. **`cmux_read_screen`** — generates `read-screen --json ...`, but `--json` is a global flag consumed before command routing. The `read-screen` parser treats it as an unexpected argument and errors.
2. **`cmux_send_key`** — generates `send-key --json <key>`, causing `--json` to be parsed as the key name instead of the actual key.

Root cause: `MCPBackend.executeCommand()` builds commands as a space-separated string which is then split back into args. Each tool hardcodes `--json` into the command string, but `--json` is a global flag parsed at the top level of `cmux.swift` (line 634-637), not within individual command handlers.

## Bug Fix

Remove `--json` from all tool command strings in `MCPToolRegistry.swift`. The MCP server doesn't need structured JSON from the CLI — it wraps raw text output into MCP content blocks.

Affected tools (all 12):
- `IdentifyTool`: `identify --json` → `identify`
- `ListWorkspacesTool`: `list-workspaces --json` → `list-workspaces`
- `ListPanesTool`: `list-panes --json` → `list-panes`
- `ListPaneSurfacesTool`: `list-pane-surfaces --json` → `list-pane-surfaces`
- `ReadScreenTool`: `read-screen --json` → `read-screen`
- `SendInputTool`: `send --json` → `send`
- `SendKeyTool`: `send-key --json` → `send-key`
- `CreateSplitTool`: `new-split <dir> --json` → `new-split <dir>`
- `FocusPaneTool`: `focus-pane --pane <p> --json` → `focus-pane --pane <p>`
- `NewWorkspaceTool`: `new-workspace --json` → `new-workspace`
- `TriggerFlashTool`: `trigger-flash --json` → `trigger-flash`
- `ListWindowsTool`: `list-windows --json` → `list-windows`

## Testing Strategy

### 1. Swift Unit Tests (command construction)

Add `MCPToolCommandTests.swift` to the `cmuxTests` target.

- Create a `MockMCPBackend` subclass that captures the command string instead of executing it.
- For each tool, call `execute(arguments:)` and assert the captured command matches expected format.
- Covers: correct flag ordering, required params, optional params, special character escaping.

### 2. Python Smoke Test (end-to-end MCP protocol)

Add `tests/test_mcp_server.py`.

- Launches `cmux-mcp --mcp` as a subprocess.
- Sends JSON-RPC messages via stdin, reads responses from stdout.
- Validates:
  - `initialize` returns correct capabilities and protocol version.
  - `tools/list` returns all 12 tools with correct schemas.
  - `tools/call` for each tool returns expected error format (socket not available) confirming the command was constructed and dispatched.
  - Invalid method returns proper JSON-RPC error.
  - Notifications (e.g., `initialized`) don't produce responses.

### 3. Test Commands

```bash
# Swift unit tests (on VM)
ssh cmux-vm 'cd /Users/cmux/GhosttyTabs && xcodebuild ... -only-testing:cmuxTests/MCPToolCommandTests test'

# Python smoke test (local, no daemon needed)
python3 tests/test_mcp_server.py
```
