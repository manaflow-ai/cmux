//! Typed shapes for the background-process methods
//! (`server/processes.rs`, docs/background-processes.md).

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// `_acpmux/process/background` (Ctrl-B): the chat whose running work goes
/// to the background, and the one tool call to move (none: every
/// foreground task, as Claude Code's own Ctrl-B does).
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
#[schemars(deny_unknown_fields)]
pub struct ProcessBackgroundParams {
    /// The chat's id, name or unique prefix.
    pub session_id: String,
    /// Only the task this tool call started.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ProcessBackgroundResult {
    /// Claude Code moved something: the tasks arrive as `process_update`s
    /// with origin `user_backgrounded`. False when nothing ran in the
    /// foreground (or no turn ran).
    pub backgrounded: bool,
}
