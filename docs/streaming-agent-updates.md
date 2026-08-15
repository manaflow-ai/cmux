# iOS streaming agent updates: incremental responses in the chat GUI

Goal: the iOS chat GUI should show the agent's response building incrementally (partial text / blocks appearing as they generate), not just the final message after the turn completes.

## Root cause (investigation in this worktree)

The wire and the iOS renderer already support incremental updates. The pipeline is starved of partial data, not broken.

1. **Agent JSONL is the source, and it is written per content block, never per token.** Confirmed empirically against the installed versions (Claude Code 2.1.187, Codex 0.142.0) by watching the on-disk file grow during a live turn: a 647-character answer went from absent to fully present in a single 100ms poll interval, not in growing increments. Each Claude `assistant` line is one already-complete content block carrying its `stop_reason`; Codex rollout JSONL contains `agent_message`/`message` items but no `agent_message_delta` (the deltas exist only on Codex's in-process event stream, never persisted). So a single long final-answer block lands all at once when generation finishes. Block-level streaming already works (thinking → tool → text each appear as their line is written); the only gap is intra-block token streaming. (`Packages/Shared/CmuxAgentChat/.../Parsing/ClaudeTranscriptParser.swift:174-189`, `CodexTranscriptParser.swift:135-163` parse complete lines only.)
2. **Host tailer reads complete lines only.** `Sources/Mobile/AgentChat/AgentChatTranscriptTailer.swift:184-254` seeks to the last byte offset, reads only newline-terminated lines (`:224`), and re-reads on file growth (FileWatcher, 200ms throttle). A single final line appears once and is parsed once.
3. **Wire is correct.** `Sources/Mobile/AgentChat/AgentChatTranscriptService.swift:313-329` emits `.appended` for new messages and `.updated` for in-place changes (today only tool results / permission answers), with no coalescing.
4. **iOS render is correct.** `Packages/Shared/CmuxAgentChat/.../Store/ChatConversationStore.swift:457-528` mutates messages on `.updated` and reprojects; `Packages/iOS/CmuxAgentChatUI/.../Transcript/ChatTranscriptListView.swift` renders the final state. It would render streaming updates if they arrived.

Ranked: (a) agent JSONL has no partials to parse [PRIMARY], (b) parsers can't emit partial prose [follows from a], (c) wire forwards everything correctly [not a cause], (d) iOS renders updates correctly [not a cause].

## The real lever: Ghostty's emulated screen grid

The three candidate sources, now resolved against the installed versions:

- **B (parser change) is dead.** Confirmed above: neither agent persists token deltas to JSONL. There is no format flag or version that writes partial lines for an interactive session. Nothing to tail.
- **C (stream-json output mode) is incompatible with the interactive UX.** `claude --print --output-format stream-json --include-partial-messages` and `codex exec --json` do emit token deltas, but only in non-interactive print mode, which is mutually exclusive with the interactive TUI the user actually runs. There is no way to get deltas out of an already-running interactive agent except its own stdout (the TUI bytes). Using C would mean cmux owning the agent process in headless mode and rendering it itself, a different product, not a streaming improvement.
- **A (pty tee), but not by parsing raw bytes.** Confirmed empirically by capturing Claude Code 2.1's interactive pty output: it paints the streaming answer as a synchronized-output frame (`ESC[?2026h`/`l`) over a bottom "live" region, placing each word with absolute-column moves (`ESC[<col>G`) and relative cursor moves, repainting the whole region (answer + spinner + input box + footer) every frame. No alt-screen, no `ESC[2J`, but also no linear append: finalized text only commits to scrollback once the turn ends. Recovering the visible prose from these raw bytes means running a terminal emulator (cell grid, cursor, scroll region, synchronized frames). Ghostty already is that emulator.

So the one viable source is **Ghostty's emulated screen text** (`ghostty_surface_read_text`), polled during an active turn off the typing hot path, with the assistant-prose region isolated from per-agent TUI chrome (Claude's `●`/`✶` bullets and `✢ …ing… (Ns · ↓N tokens)` spinner, the `────` rules, the `❯` input box, the `⏵⏵ auto mode` footer; Codex differs), emitted as a provisional `.prose` message via the existing wire (`.appended` once, then `.updated` repeatedly), and reconciled against the authoritative JSONL line at turn end (replace provisional with parsed-final by message id) so the committed state always matches JSONL and streaming imperfections are transient only.

This is a large, inherently heuristic subsystem: per-agent chrome stripping that drifts with CLI versions and locale, anchoring "this turn's prose" against the prompt echo / turn-start scrollback position, scrollback inclusion for answers taller than the viewport, JSONL reconciliation, and care on the latency-sensitive terminal path (`MobileTerminalByteTee`, the Ghostty read path) so polling never touches the keystroke hot path. It is also hard to unit-test deterministically (needs recorded TUI byte fixtures replayed through the emulator, or recorded screen snapshots).

### Active-turn gating

Poll only while a turn is in flight. The hook lifecycle already marks this: `UserPromptSubmit` starts a turn, `Stop` ends it. Gate the scraper to active turns per surface so idle terminals are never polled (cost + latency), and stop on `Stop` / the authoritative JSONL append.

## Parity note

This is consistent with the agent-GUI component map: the streaming source belongs in Layer 1 (host) and the shared model (Layer 2), feeding the existing wire. The iOS view layer (Layer 3) needs no new capability for streaming text beyond what `.updated` already drives.
