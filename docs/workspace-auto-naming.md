# Workspace auto-naming

Opt-in AI naming of sidebar workspaces and tabs from agent conversation content. With several concurrent agent sessions, the sidebar otherwise shows identical rows ("Claude Code", "codex"); auto-naming turns them into short, topic-bearing names that refresh as each conversation moves.

Off by default. Enable it in **Settings > Automation > Workspace Auto-Naming** or via `automation.workspaceAutoNaming` in `cmux.json` (see [configuration.md](configuration.md#automationworkspaceautonaming)).

## What it does

- At the end of an agent turn, cmux summarizes the session's recent conversation into a 2-5 word title (in the conversation's language) and applies it to the workspace. When a workspace has multiple tabs, the agent's own tab is named too.
- Names refresh when the topic shifts, throttled by transcript growth and a minimum interval, so quiet or single-topic sessions converge to a stable name without repeated summarization calls.
- Summarization runs through your own agent binary: `claude -p` for Claude Code sessions (model from `ANTHROPIC_SMALL_FAST_MODEL` when set, the fast default otherwise; Vertex/Bedrock backend selection is preserved), `codex exec` for Codex sessions, and each supported hook agent's own non-interactive CLI for its sessions. Each agent names itself, so the calls use the account you already authenticated, and a machine without another agent installed simply skips that adapter.

## Precedence: manual names always win

Custom titles carry a provenance marker (user vs auto):

- A name you set yourself - sidebar rename, command palette, `cmux rename-workspace`/`rename-tab`, or Claude's `/rename` - is never overwritten by auto-naming, and auto-naming for that workspace or tab stops.
- Custom titles that predate this feature (snapshots persisted before provenance existed) restore as user-set: existing named workspaces are never auto-renamed. Workspaces without a custom title (the common "Claude Code"-row case) auto-name normally.
- Clearing your custom name re-opens the workspace or tab to auto-naming (sidebar, command palette, or `cmux workspace-action --action clear-name`).
- Auto names lose to the user everywhere else too: OSC terminal titles never override any custom title (unchanged behavior), and provenance survives session restore and moving tabs between workspaces.

## Guarantees

- No summarization call ever runs unless the setting is on; the hooks gate themselves on the live setting, so toggling takes effect on the next turn without restarting agents.
- Only the workspace's current agent session names it: stale, background, and nested (subagent) sessions are filtered by the same active-session gates the notification hooks use.
- Failures degrade silently to current behavior - no binary on PATH, a timed-out call, or an unsupported backend just means the name does not change.
- Naming never blocks the agent: the Claude pass runs as an async hook and the generic hook adapters run detached from the hook process.

## Supported adapters

Auto-naming currently has source adapters and summarizer runners for:

- Claude Code: reads the Claude transcript JSONL and summarizes with `claude -p`.
- Codex: reads the Codex rollout JSONL and summarizes with `codex exec --output-last-message`.
- Grok: reads Grok's `chat_history.jsonl` for the active session and summarizes with `grok --prompt-file` with tools and web search disabled.
- OpenCode: caches recent prompt/assistant text from the cmux OpenCode session plugin and summarizes with `opencode run --pure` from an isolated temporary directory.
- Pi and OMP: cache prompt/assistant text from their cmux hooks and summarize with their own non-interactive CLIs (`pi --print --no-tools` and `omp --print --no-tools`).

The other hook integrations are intentionally skipped for now:

- Amp's current cmux plugin reports lifecycle/status but does not expose a usable prompt or assistant transcript.
- Gemini has hook payload text, but the available non-interactive CLI invocation has not been verified to disable tools/project access, so it is skipped rather than running untrusted transcript text through a tool-capable summarizer.
- Cursor, Antigravity, Kiro, Rovo Dev, Hermes Agent, Copilot, CodeBuddy, Factory, and Qoder have cmux Stop/notification hooks, but this branch does not yet have both a verified transcript source and a safe cheap non-interactive summarizer invocation that disables tools/project access.

## Mechanics

The Claude Code wrapper registers an async `Stop` hook (`cmux hooks claude auto-name`); other supported agents spawn an equivalent detached pass from their turn-end hook. Each pass reads the adapter's transcript source, evaluates the throttle against per-session state in `~/.cmuxterm/<agent>-hook-sessions.json`, and applies the title through the `workspace.set_auto_title` socket method, which enforces the setting and the user-provenance rule app-side.
