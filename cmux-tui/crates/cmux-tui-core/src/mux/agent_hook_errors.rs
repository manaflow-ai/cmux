//! Typed errors of the agent hook projection: a terminal that is gone ends
//! the hook, an unavailable terminal or a busy registry retries it.

use std::fmt;

pub(super) const AGENT_HOOK_RETRY_ERROR: &str = "agent hook projection retry deferred";

#[derive(Debug)]
pub(super) struct AgentHookTerminalUnavailable;

impl fmt::Display for AgentHookTerminalUnavailable {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("terminal is not available for agent hook projection")
    }
}

impl std::error::Error for AgentHookTerminalUnavailable {}

#[derive(Debug)]
pub(super) struct AgentHookTerminalGone;

impl fmt::Display for AgentHookTerminalGone {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("terminal no longer exists for agent hook projection")
    }
}

impl std::error::Error for AgentHookTerminalGone {}

pub(super) fn agent_hook_terminal_gone(error: &anyhow::Error) -> bool {
    error.downcast_ref::<AgentHookTerminalGone>().is_some()
}

pub(super) fn agent_hook_retry_class(
    error: &anyhow::Error,
) -> crate::workspace_registry::AgentHookRetryClass {
    if error.downcast_ref::<AgentHookTerminalUnavailable>().is_some()
        || error.chain().any(|cause| {
            matches!(
                cause.downcast_ref::<rusqlite::Error>(),
                Some(rusqlite::Error::SqliteFailure(
                    rusqlite::ffi::Error {
                        code: rusqlite::ErrorCode::DatabaseBusy
                            | rusqlite::ErrorCode::DatabaseLocked,
                        ..
                    },
                    _
                ))
            )
        })
    {
        crate::workspace_registry::AgentHookRetryClass::Transient
    } else {
        crate::workspace_registry::AgentHookRetryClass::Permanent
    }
}
