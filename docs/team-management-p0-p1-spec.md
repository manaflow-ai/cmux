# Team Management P0/P1 Spec

Last updated: March 14, 2026

## Implementation Status (P0)

✅ **Completed:**
- `tm-agent` unified CLI (Rust, ~2ms latency) replacing `team.py` and `tm-rpc`
- Task creation with title, assignee, priority, acceptance criteria, dependencies
- Task lifecycle: queued, assigned, in_progress, blocked, review_ready, completed, failed
- Task commands: create, start, done, block, review, get, list, update, reassign, unblock, split, clear
- Message operations: send, list, clear with optional --to and --from-agent filtering
- Dashboard with task board, agent list, and message panel
- Leader and worker agent initialization prompts with task lifecycle guidance
- Model picker with CLI-dependent model selection (claude, codex, gemini)

🟡 **In Progress:**
- Dashboard "Needs Attention" prioritization card
- Stale task detection (heartbeat-based)
- Per-agent active task and heartbeat tracking

❌ **Not Yet Started (P1 scope):**
- Task dependencies blocking/unblocking automation
- Workflow presets (Bug Triage, Feature Build, Refactor + Verify, Release Prep)
- Task reassignment without creating replacement
- Brief agent command with active task + heartbeat + recent messages + terminal tail

This document defines the first productization pass for term-mesh multi-agent team management.

The current system already supports:
1. team creation and teardown
2. direct agent messaging
3. terminal output reads
4. file-backed result reporting
5. basic message queue
6. basic task board
7. dashboard views for agents, messages, and tasks

The gap is not raw capability. The gap is operational clarity.

Today, the leader can send work to agents, but the system does not model the core management questions well enough:
1. What is each agent currently responsible for?
2. Which agents are blocked, and why?
3. Which items are waiting on leader review?
4. Which teams or agents are stale and need intervention?
5. Which next action should the leader take first?

This spec introduces those concepts without changing the basic team workflow.

## Goals

P0 goals:
1. Make `task` the canonical unit of delegation.
2. Introduce explicit operational states: `blocked`, `review_ready`, and `stale`.
3. Make the dashboard answer "who needs attention right now?" at a glance.
4. Add enough API and CLI structure that leader agents can manage teams deterministically.

P1 goals:
1. Add dependency-aware task routing and reassignment.
2. Add richer event waiting and leader inbox workflows.
3. Add progress and heartbeat signals so "silent failure" is visible.
4. Improve team creation from role presets toward workflow presets.

Non-goals for P0/P1:
1. Full autonomous planning or agent self-healing.
2. Historical analytics across many teams.
3. Complex scheduling or optimization algorithms.
4. Replacing free-form `send` messaging.

## Current Constraints

Current relevant files:
1. [daemon/term-mesh-cli/src/tm_agent.rs](/Users/jinwoo/work/project/cmux/daemon/term-mesh-cli/src/tm_agent.rs) (unified CLI — replaces scripts/team.py)
2. [Sources/TeamOrchestrator.swift](/Users/jinwoo/work/project/cmux/Sources/TeamOrchestrator.swift)
3. [Sources/TerminalController.swift](/Users/jinwoo/work/project/cmux/Sources/TerminalController.swift)
4. [Resources/dashboard/index.html](/Users/jinwoo/work/project/cmux/Resources/dashboard/index.html)
5. [Sources/DashboardController.swift](/Users/jinwoo/work/project/cmux/Sources/DashboardController.swift)
6. [Sources/TeamCreationView.swift](/Users/jinwoo/work/project/cmux/Sources/TeamCreationView.swift)
7. [Sources/AgentRolePreset.swift](/Users/jinwoo/work/project/cmux/Sources/AgentRolePreset.swift)

Current limitations:
1. `TeamTask` only stores `title`, `assignee`, `status`, and `result`.
2. Message types exist, but there is no first-class operational inbox.
3. `wait` only understands `report`, `msg`, and `any`.
4. Dashboard task rendering is a simple board, not an intervention console.
5. Task-to-message, task-to-report, and task-to-agent relationships are implicit.
6. There is no heartbeat or staleness model.

## Canonical Management Model

### Core Principles

1. `task` is the source of truth for work assignment.
2. `message` is conversational transport, not authoritative task state.
3. `report` is a structured work output signal, not a chat substitute.
4. The leader should manage by exceptions, not poll every pane manually.

### Task Lifecycle

Canonical states:
1. `queued`
2. `assigned`
3. `in_progress`
4. `blocked`
5. `review_ready`
6. `completed`
7. `failed`
8. `abandoned`

State intent:
1. `queued`: task exists, no owner yet
2. `assigned`: owner chosen, work has not started
3. `in_progress`: agent has begun execution
4. `blocked`: agent cannot proceed without an external action
5. `review_ready`: implementation or analysis is ready for leader validation
6. `completed`: accepted as done
7. `failed`: task ended unsuccessfully
8. `abandoned`: task intentionally dropped or superseded

### Attention Model

The leader inbox should prioritize:
1. `blocked`
2. `review_ready`
3. `failed`
4. `stale`
5. `completed`

The system should derive `stale` rather than store it directly on tasks:
1. task is not terminal
2. no heartbeat or update for longer than threshold
3. optional threshold override per task or team

## P0 Scope

### P0 Data Model

Extend `TeamTask` in [Sources/TeamOrchestrator.swift](/Users/jinwoo/work/project/cmux/Sources/TeamOrchestrator.swift):
1. `description: String?`
2. `acceptanceCriteria: [String]`
3. `assignee: String?`
4. `status: String`
5. `priority: Int`
6. `dependsOn: [String]`
7. `blockedReason: String?`
8. `reviewSummary: String?`
9. `createdBy: String`
10. `createdAt: Date`
11. `updatedAt: Date`
12. `startedAt: Date?`
13. `completedAt: Date?`
14. `lastProgressAt: Date?`

Add a derived dashboard-only view model:
1. `needsAttention: Bool`
2. `attentionReason: String?`
3. `isStale: Bool`
4. `staleSeconds: Int`

P0 message type normalization in `TeamMessage.type`:
1. `note`
2. `progress`
3. `blocked`
4. `review_ready`
5. `error`
6. `report`

### P0 API Surface

Keep existing methods, but expand payloads:
1. `team.task.create`
2. `team.task.update`
3. `team.task.list`
4. `team.message.post`
5. `team.message.list`
6. `team.status`

P0 additions:
1. `team.inbox`
2. `team.task.get`

Proposed `team.task.create` params:
1. `team_name`
2. `title`
3. `description` optional
4. `assignee` optional
5. `acceptance_criteria` optional string array
6. `priority` optional int, default `2`
7. `depends_on` optional string array
8. `created_by` optional, default `leader`

Proposed `team.task.update` params:
1. `team_name`
2. `task_id`
3. `status` optional
4. `result` optional
5. `assignee` optional
6. `blocked_reason` optional
7. `review_summary` optional
8. `progress_note` optional

`team.inbox` response should return a priority-sorted list of attention items:
1. `kind`: `task` or `message`
2. `priority`
3. `team_name`
4. `task_id` optional
5. `agent_name` optional
6. `reason`
7. `age_seconds`
8. `summary`

### P0 CLI Surface

Update `tm-agent` CLI ([daemon/term-mesh-cli/src/tm_agent.rs](/Users/jinwoo/work/project/cmux/daemon/term-mesh-cli/src/tm_agent.rs)).

New commands:
1. `tm-agent inbox`
2. `tm-agent task get <id>`
3. `tm-agent task block <id> <reason>`
4. `tm-agent task review <id> <summary>`
5. `tm-agent task start <id>`
6. `tm-agent task done <id> [result]`

CLI behavior changes:
1. `task create` should support `--desc`, `--accept`, `--priority`, and `--deps`.
2. `task list` should include attention-relevant fields in non-JSON output.
3. `wait` should support `--mode review_ready` and `--mode blocked`.
4. `msg send` should support `--type note|progress|blocked|review_ready|error|report`.

### P0 Dashboard

Update [Resources/dashboard/index.html](/Users/jinwoo/work/project/cmux/Resources/dashboard/index.html) and [Sources/DashboardController.swift](/Users/jinwoo/work/project/cmux/Sources/DashboardController.swift).

Add a top-level "Needs Attention" card:
1. blocked tasks
2. review-ready tasks
3. failed tasks
4. stale tasks

Task board changes:
1. add columns for `Blocked` and `Review Ready`
2. show `priority`
3. show `blockedReason` when present
4. show `lastProgressAt` or relative stale time
5. show acceptance criteria count

Agent list changes:
1. show active task title if assigned
2. show agent attention state
3. show staleness indicator when agent has an active task with no recent progress

Message panel changes:
1. allow filtering by type
2. visually distinguish `blocked` and `review_ready`

### P0 Leader Prompting

Update leader instructions in [Sources/TeamOrchestrator.swift](/Users/jinwoo/work/project/cmux/Sources/TeamOrchestrator.swift).

The leader prompt should explicitly instruct:
1. create tasks before delegating meaningful work
2. use `task start`, `task block`, `task review`, and `task done`
3. check `inbox` before answering the user
4. treat `blocked` and `review_ready` as first-class control points

Worker init prompts should explicitly instruct:
1. when beginning a task, mark it `in_progress`
2. when blocked, call `task block`
3. when ready for validation, call `task review`
4. only call `report` for substantive result output

### P0 Acceptance Criteria

1. A leader can create a task with assignee, priority, acceptance criteria, and dependencies.
2. An agent or leader can move a task into `blocked` with a reason.
3. An agent or leader can move a task into `review_ready` with a summary.
4. The dashboard exposes a single attention queue without manually inspecting each pane.
5. `wait --mode blocked` returns when any task enters blocked state.
6. `wait --mode review_ready` returns when any task enters review-ready state.
7. Existing `send/read/collect/report` workflows still function.

## P1 Scope

### P1 Data Model

Extend `TeamTask` further:
1. `labels: [String]`
2. `estimatedSize: Int?`
3. `parentTaskId: String?`
4. `childTaskIds: [String]`
5. `reassignmentCount: Int`
6. `supersededBy: String?`

Add per-agent runtime state:
1. `activeTaskId: String?`
2. `lastHeartbeatAt: Date?`
3. `lastHeartbeatSummary: String?`
4. `agentState: String` with `idle|running|blocked|review_ready|error`

### P1 API Surface

New methods:
1. `team.task.reassign`
2. `team.task.split`
3. `team.task.unblock`
4. `team.task.dependents`
5. `team.agent.heartbeat`
6. `team.agent.status`

API behavior:
1. `team.task.list` should support filtering by `needs_attention`, `priority`, `stale`, and `depends_on`.
2. `team.inbox` should optionally return only the top item.
3. `team.status` should include per-agent `active_task_id`, `agent_state`, and heartbeat age.

### P1 CLI Surface

New commands:
1. `tm-agent task reassign <id> <agent>`
2. `tm-agent task split <id> '<title>' --assign <agent>`
3. `tm-agent task unblock <id>`
4. `tm-agent heartbeat '<summary>'`
5. `tm-agent brief <agent>`

CLI behavior changes:
1. `wait` should support `--task <id>`.
2. `wait` should support `--mode idle`.
3. `brief <agent>` should summarize the agent's active task, last heartbeat, last message, and recent terminal tail.

### P1 Dashboard

Add workflow-oriented team views:
1. dependency badges on tasks
2. reassignment actions
3. per-agent active task chip
4. heartbeat age and stale warnings
5. one-click filters: `attention`, `blocked`, `review_ready`, `stale`

Consider a compact leader console block:
1. next recommended action
2. tasks waiting on review
3. tasks blocked on external input
4. stale agents

### P1 Team Creation UX

Update [Sources/TeamCreationView.swift](/Users/jinwoo/work/project/cmux/Sources/TeamCreationView.swift) and [Sources/AgentRolePreset.swift](/Users/jinwoo/work/project/cmux/Sources/AgentRolePreset.swift).

Add workflow presets alongside role presets:
1. `Bug Triage`
2. `Feature Build`
3. `Refactor + Verify`
4. `Release Prep`

Each workflow preset should define:
1. recommended agent roles
2. recommended default task template set
3. suggested leader mode
4. suggested review checkpoints

### P1 Acceptance Criteria

1. A leader can reassign a task without creating a replacement task.
2. The system can identify stale active tasks based on heartbeat or progress age.
3. The dashboard shows each agent's active task and heartbeat age.
4. The leader can wait on a specific task to enter terminal or attention states.
5. Workflow presets reduce the setup time for common multi-agent patterns.

## Implementation Plan

### P0 Order

1. Expand `TeamTask` and task serialization in [Sources/TeamOrchestrator.swift](/Users/jinwoo/work/project/cmux/Sources/TeamOrchestrator.swift).
2. Extend JSON-RPC handling in [Sources/TerminalController.swift](/Users/jinwoo/work/project/cmux/Sources/TerminalController.swift) for `team.inbox` and richer task updates.
3. Update `tm-agent` CLI to expose the new task and inbox commands.
4. Update dashboard fetch wiring in [Sources/DashboardController.swift](/Users/jinwoo/work/project/cmux/Sources/DashboardController.swift).
5. Update dashboard rendering in [Resources/dashboard/index.html](/Users/jinwoo/work/project/cmux/Resources/dashboard/index.html).
6. Update leader and worker prompts in [Sources/TeamOrchestrator.swift](/Users/jinwoo/work/project/cmux/Sources/TeamOrchestrator.swift).

### P1 Order

1. Add agent heartbeat tracking to orchestrator state.
2. Extend CLI/API for reassignment, split, unblock, and briefing.
3. Add workflow presets and task templates to team creation.
4. Add dependency and heartbeat UI to dashboard.

## Compatibility Rules

1. Existing commands must remain valid: `send`, `broadcast`, `read`, `collect`, `report`, `msg`, `task create`, `task update`, `task list`.
2. Existing simple task statuses should be mapped:
   `pending -> queued`
   `assigned -> assigned`
   `in_progress -> in_progress`
   `completed -> completed`
   `failed -> failed`
3. Older dashboards should degrade gracefully when new fields are absent.
4. Free-form messaging remains supported for ad hoc coordination.

## Open Questions

1. Should `review_ready` be a task status only, or also an agent session state?
2. Should `stale` thresholds be global, team-level, or task-level?
3. Should `team.inbox` include free-form messages, or only task-derived attention items by default?
4. Should task acceptance criteria be plain strings only, or later support checkbox completion?
5. Should `brief <agent>` use only local state, or also summarize recent terminal screen text heuristically?

## Recommended Default Decisions

1. `review_ready` should exist as both task status and derived agent state.
2. Stale threshold should start global in P0 and become team-level in P1 only if needed.
3. `team.inbox` should include both task and message items, but default-sort tasks higher.
4. Acceptance criteria should remain plain strings in P0/P1.
5. `brief <agent>` should combine task state, heartbeat, latest messages, and terminal tail in P1.
