# MCP Server Build Guide

This document describes how to build the cmux MCP Server.

## Overview

The cmux MCP Server is embedded in the cmux CLI and provides Model Context Protocol tools for AI agents to interact with cmux.

## Prerequisites

1. **Xcode** - Full Xcode installation (not just Command Line Tools)
2. **zig** - Version 0.14.x (required for building GhosttyKit)
   ```bash
   brew install zig@0.14
   ```
3. **xcodeproj gem** - For adding files to Xcode project
   ```bash
   sudo gem install xcodeproj
   ```

## Build Steps

### 1. Initialize Submodules

```bash
# With proxy if needed
export https_proxy=http://127.0.0.1:7897 http_proxy=http://127.0.0.1:7897
git submodule update --init --recursive
```

### 2. Build GhosttyKit.xcframework (Required for Full App)

```bash
cd ghostty
zig build -Demit-xcframework=true -Doptimize=ReleaseFast
```

The xcframework will be output to the ghostty directory.

### 3. Build cmux-cli (MCP Server Only)

For building just the CLI (without full app):

```bash
xcodebuild -project GhosttyTabs.xcodeproj \
  -scheme cmux-cli \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

The binary is located at:
```
~/Library/Developer/Xcode/DerivedData/GhosttyTabs-*/Build/Products/Debug/cmux
```

### 4. Build Full App (Optional)

```bash
xcodebuild -project GhosttyTabs.xcodeproj \
  -scheme cmux \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

## Adding MCP Files to Xcode Project

When adding new Swift files to the MCP module, you need to add them to the Xcode project:

```bash
# Using Ruby xcodeproj
ruby -e '
require "xcodeproj"

project = Xcodeproj::Project.open("GhosttyTabs.xcodeproj")
target = project.targets.find { |t| t.name == "cmux-cli" }
cli_group = project.main_group.find_subpath("CLI", true)

files = ["MCPTypes.swift", "MCPProtocol.swift"]
files.each do |file|
  file_ref = cli_group.new_file(file)
  target.add_file_references([file_ref])
end

project.save
'
```

## Usage

### Running MCP Server

```bash
# From built binary
./cmux --mcp

# With custom socket
./cmux --mcp --socket /tmp/cmux.sock
```

### Configuration in Claude Code

Add to your Claude Code settings:

```json
{
  "mcpServers": {
    "cmux": {
      "command": "/path/to/cmux",
      "args": ["--mcp"]
    }
  }
}
```

## Troubleshooting

### "xcodebuild requires Xcode"

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

### "No such file or directory" errors

Clean DerivedData:
```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/GhosttyTabs-*
```

### Zig build failures

- Ensure zig 0.14.x is installed (not 0.15.x)
- Use proxy for network issues

## MCP Tools Available

| Tool | Description |
|------|-------------|
| `cmux_identify` | Get current workspace/surface context |
| `cmux_list_workspaces` | List all workspaces |
| `cmux_list_panes` | List all panes |
| `cmux_list_pane_surfaces` | List surfaces in a pane |
| `cmux_read_screen` | Read terminal output |
| `cmux_send_input` | Send text input |
| `cmux_send_key` | Send key press |
| `cmux_create_split` | Create a split |
| `cmux_focus_pane` | Focus a pane |
| `cmux_new_workspace` | Create a new workspace |
| `cmux_trigger_flash` | Trigger attention flash |
| `cmux_list_windows` | List all windows |

## File Structure

```
CLI/
├── cmux.swift           # Main CLI entry
├── MCPTypes.swift      # JSON-RPC and MCP types
├── MCPProtocol.swift   # MCP protocol handler
├── MCPToolRegistry.swift # Tool registration and execution
├── MCPBackend.swift    # cmux daemon communication
└── MCPMain.swift      # stdio entry point
```
