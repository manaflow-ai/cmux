# Sandboxing Options for Scheduled Agent Tasks

## Status: Future enhancement — not in current implementation plan

## Context

Scheduled tasks (especially headless Claude Code sessions) run with full user privileges. Sandboxing limits blast radius from prompt injection or agent errors.

## Evaluated Options

### 1. agent-sandbox (Rust crate) — Most Promising

**Repo**: github.com/Parassharmaa/agent-sandbox (MIT license)
**Language**: Rust, with Node.js bindings (NAPI)

- 80+ built-in CLI tools (grep, find, sed, awk, jq, git, etc.)
- Full shell interpreter running inside WASM
- Filesystem sandboxing with path traversal prevention
- Safe HTTP with SSRF protection, domain allowlists
- <13ms cold start, AOT precompiled WASM
- Change tracking via filesystem snapshots + diff

**Integration path**: Standalone Rust binary called by SchedulerEngine before task launch. Mount project directory as read-only overlay, run command inside sandbox, capture diff on completion, present changes for review.

**Challenge**: Claude Code is a Node.js CLI that spawns subprocesses. Running it fully inside the WASM sandbox may not work — the sandbox provides a virtual shell but Claude Code depends on native Node.js capabilities. Would need a PoC.

**Fallback**: Run Claude Code natively but mount working directory through sandbox overlay for file mutation tracking.

### 2. amla-sandbox (Python) — Capability-Based

**Repo**: github.com/amlalabs/amla-sandbox (311 stars)
**Language**: Python

- WASM sandbox with capability enforcement via wasmtime
- Virtual filesystem (copy-on-write, agent never touches real fs)
- No network, no shell escape — only host-mediated tool calls
- Capability constraints: method patterns, parameter limits, max calls
- 13MB single binary, no Docker/VM

**Good for**: Constraining LLM-generated code execution (LangChain, AutoGen patterns). Less applicable to wrapping a full CLI tool like Claude Code.

### 3. Cosmonic/wasmCloud — MCP Server Sandboxing

**Blog**: blog.cosmonic.com/engineering/2025-03-25-sandboxing-agentic-developers-with-webassembly

- WASI component model — code can only reach outside sandbox through capability contracts
- "Sandbox MCP" generates MCP servers as secure WASM components
- Deny-by-default for filesystem, network, syscalls

**Good for**: Running MCP servers safely. Not designed to sandbox a whole CLI tool.

### 4. OS-Level (macOS native)

| Mechanism | Effort | Notes |
|-----------|--------|-------|
| `sandbox-exec` profiles | Low | Deprecated but functional. Limit filesystem + network per-process |
| Dedicated macOS user | Low | `sudo -u scheduler-agent claude ...` — Unix DAC isolation |
| macOS App Sandbox entitlements | Medium | Per-process entitlements via code signing |

### 5. Zellij WASM Plugins — Wrong Layer

Zellij's WASM sandbox contains the *plugin code*, not the processes the plugin spawns. A scheduled command runs as a native OS process outside the sandbox. Not useful for agent containment.

## Recommendation

**For v1**: No sandboxing. Rely on vibeshield container isolation during development.

**For v2**: Investigate `agent-sandbox` Rust crate as a standalone helper binary. The `cargo add agent-sandbox` integration is native Rust, but since crux is Swift, the integration would be:
1. Build `agent-sandbox` as a standalone CLI binary
2. SchedulerEngine calls it as a subprocess: `agent-sandbox exec --work-dir /path --command "claude code --headless ..."`
3. Capture sandbox diff output for review in the sidebar

**PoC needed**: Verify Claude Code can actually run inside agent-sandbox's virtual shell.
