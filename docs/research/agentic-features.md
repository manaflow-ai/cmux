# Agentic Coding Features Research

Five high-impact features identified from ecosystem analysis. All are included in the crux implementation plan.

## 1. Cost/Token Tracking (Phase 9 — Sidebar UI)

**Source**: Agent Orchestrator (github.com/ComposioHQ/agent-orchestrator) found that tracking which prompts led to clean PRs vs. 12-cycle CI failure spirals was the most valuable signal.

**Implementation**: Parse Claude Code session JSONL from `~/.claude/projects/<hash>/<session>.jsonl`. Files contain `total_tokens` per API response (no direct `costUSD` — derive from token count x model pricing). Display per-task cumulative tokens in sidebar row.

**Lift**: ~100-150 lines.

## 2. Git Worktree Isolation (Phase 8 — Optional, default OFF)

**Source**: VS Code background agents, Agent Orchestrator, ccswarm all converged on this pattern. Without it, parallel agents editing the same repo produce merge conflicts.

**Implementation**: `git worktree add /tmp/cmux-scheduler/<task-id> -b scheduler/<task-name>` before launch. Set Ghostty surface `working_directory` to worktree. Per-task override via `ScheduledTask.useWorktree: Bool?`.

**Lift**: ~80-120 lines + ~20 lines Settings UI.

## 3. Terminal Snapshot API (Phase 10 — Socket API)

**Source**: Pilotty (github.com/msmps/pilotty) and PiloTY exist specifically for AI agents to "see" terminal state. The `scheduler.snapshot` command exposes this.

**Implementation**: Map `task_id → panelId → surface`, delegate to existing `ghostty_surface_read_text()`. Already used by cmux's `surface.read_text` v2 command.

**Lift**: ~30-50 lines (mostly lookup + delegation).

## 4. Task Chaining / Post-Run Hooks (Phase 13 — Post-MVP)

**Source**: Agent Orchestrator's "agent fixes CI failures automatically" pattern. Requires task A (tests) triggering task B (fix) on failure.

**Implementation**: `onSuccess: String?` and `onFailure: String?` fields on `ScheduledTask`. After completion, check exit code, create follow-up `TaskRun`. Chain depth max 3.

**Lift**: ~100-150 lines in SchedulerEngine. Schema fields in data model from Phase 2.

## 5. Session Memory / Context File (Phase 7 — Per Task)

**Source**: RedMonk survey — "developers are frustrated by agents that forget everything between sessions." A recurring Claude Code task needs to know what it did last time.

**Implementation**: Create `~/Library/Application Support/cmux/scheduler-context/<task-id>.md` on first run. Inject `CMUX_TASK_CONTEXT_FILE=<path>` env var. Agent reads/writes across runs.

**Lift**: ~40-60 lines.

## Sources

- Agent Orchestrator: github.com/ComposioHQ/agent-orchestrator
- Pilotty: github.com/msmps/pilotty
- ccswarm: github.com/nwiizo/ccswarm
- VS Code background agents: visualstudiomagazine.com (Nov 2025)
- RedMonk survey: redmonk.com/kholterhoff/2025/12/22/10-things-developers-want-from-their-agentic-ides-in-2025
- Agent Orchestrator blog: pkarnal.com/blog/open-sourcing-agent-orchestrator
