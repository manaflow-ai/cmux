# Notice to PL-acpmux: a workflow a subagent starts runs as that subagent (2026-11-09)

W5-M (a) follow-up (owner W5-S). A Claude Code subagent that started a cmux workflow
(`cmux.cmux_workflow` in a `cmux_exec` script) got nothing of it: the start carried no tool
use id, so the workflow's commands and sends ran as the lead and their reports went to the lead.

- cmux-tui `cli/mcp/workflow_tools.rs`: a `start` passes the call's `_meta` tool use id (its own,
  or the `cmux_exec` script's `call_meta`) to `_acpmux/workflow`.
- `server/workflow_runs.rs`: on the chat's own proven call only, the daemon resolves the subagent
  with `subagent_call::of_call` and stores it in `RunRecord::caller_subagent` (new optional
  field, `serde(default)`, not written when absent: old records still load, and an older daemon
  reads a new record only when the field is absent).
- `hub/workflow_runs.rs`: the runner gets `ACPMUX_CALLER_SUBAGENT=TYPE:ID`; `hub/workflow_activity.rs`
  starts the workflow's machine tasks with the subagent (`bg_start_with_id`), as an MCP
  `bg_start` of the subagent does. `acpmux_mcp.rs` falls back to the process's own mark
  (`subagent_of_this_process`) when a call has no tool use id, so the runner's script sends name
  the subagent.
- `bg_hook::MCP_CALLS` adds `mcp__cmux__cmux_workflow`.
- The mark is a label within the session the caller token proves, never a proof of its own (as
  for the Bash hook's mark). A person's or the chat's own start stores none.
- SKILL.md and `lane_report_subagents.rs` drop the workflow-script limit. The send relay limit
  stays (W5-M (b), separate).
