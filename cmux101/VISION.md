# cmux101

An agentic coding CLI that picks the best ideas from Codex CLI, Claude Code, and OpenCode, then
adds first-class integration with [cmux](https://github.com/manaflow-ai/cmux) (a Ghostty-based
macOS terminal built for AI coding agents).

## Goals

- Support every major model provider (Anthropic, OpenAI, Google, OpenRouter, Bedrock, Vertex, local
  via Ollama / LM Studio). The model layer is provider-agnostic.
- First-class tool use: file edits, shell, web fetch/search, subagents, MCP servers.
- Deep cmux integration: native tools that drive `cmux send`, `cmux new-pane`, `cmux tree`, etc.
  Treat cmux as the canonical surface for IDE-like workflows.
- Headless and interactive modes; scriptable like Codex CLI's `-p`/`--print`.
- Subagent system (parallel work, scoped tools, isolation).
- Hooks, skills/slash-commands, auto-memory.
- Sane defaults, single-binary distribution where the language permits.

## Non-goals

- Not a fork of any existing CLI. Original implementation.
- Not macOS-only (cmux integration is opt-in; the core CLI must work without cmux installed).
