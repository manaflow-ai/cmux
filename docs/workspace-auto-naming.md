# Workspace auto-naming

Opt-in AI naming of sidebar workspaces and tabs from agent conversation content. With several concurrent agent sessions, the sidebar otherwise shows identical rows ("Claude Code", "codex"); auto-naming turns them into short, topic-bearing names that refresh as each conversation moves.

Off by default. Enable it in **Settings > Automation > Workspace Auto-Naming** or via `automation.workspaceAutoNaming` in `cmux.json` (see [configuration.md](configuration.md#automationworkspaceautonaming)).

## What it does

- At the end of an agent turn, cmux summarizes the session's recent conversation into a 2-5 word title (in the conversation's language) and applies it to the workspace. When a workspace has multiple tabs, the agent's own tab is named too.
- Names refresh when the topic shifts, throttled by transcript growth and a minimum interval, so quiet or single-topic sessions converge to a stable name without repeated summarization calls.
- Summarization runs through your own agent binary: `claude -p` for Claude Code sessions (model from `ANTHROPIC_SMALL_FAST_MODEL` when set, the fast default otherwise; Vertex/Bedrock backend selection is preserved) and `codex exec` for Codex sessions. Each agent names itself, so the calls use the account you already authenticated, and a codex-only machine needs no claude install.

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
- Naming never blocks the agent: the Claude pass runs as an async hook and the Codex pass runs detached from the hook process.

## Mechanics

The Claude Code wrapper registers an async `Stop` hook (`cmux hooks claude auto-name`); the Codex Stop hook spawns the equivalent detached pass. Each pass reads the session transcript (Claude JSONL or the Codex rollout), evaluates the throttle against per-session state in `~/.cmuxterm/<agent>-hook-sessions.json`, and applies the title through the `workspace.set_auto_title` socket method, which enforces the setting and the user-provenance rule app-side.
