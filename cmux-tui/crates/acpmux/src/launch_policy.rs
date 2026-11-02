//! The build-session kill switch for agent launches (cx-9ettq).
//!
//! GUI test jobs run tagged apps with the user's real credentials. With
//! `ACPMUX_AGENT_LAUNCH=deny` (or `CMUX_AGENTS_DISABLED=1`) in the daemon's
//! environment, acpmux starts no agent process at all: the spawn points
//! (`ChildAgent::spawn_with`, `agent_host::link::spawn`) refuse, model
//! probes and pool prewarms skip, and `session/new` fails with
//! [`rpc_error`], which says why and is not retryable.
//!
//! The variable is read at each check, never cached, so the daemon reads the
//! value it was started with (the app passes its own environment on).

use crate::rpc::RpcError;

/// The variable that names the policy; `deny` turns launches off.
pub const LAUNCH_ENV: &str = "ACPMUX_AGENT_LAUNCH";
/// The app-wide switch; `1` turns launches off too.
pub const DISABLED_ENV: &str = "CMUX_AGENTS_DISABLED";
/// What a refused launch says, everywhere.
pub const DISABLED_MESSAGE: &str = "agent launch is disabled in this build session";
/// `data.reason` of the refusal, for clients that branch on it.
pub const DISABLED_REASON: &str = "agent_launch_disabled";
/// JSON-RPC code of the refusal (implementation-defined server error range).
pub const DISABLED_CODE: i64 = -32010;

/// A spawn refused by the kill switch; callers map it with [`spawn_error`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AgentLaunchDisabled;

impl std::fmt::Display for AgentLaunchDisabled {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(DISABLED_MESSAGE)
    }
}

impl std::error::Error for AgentLaunchDisabled {}

/// Whether this process must not start agents.
pub fn agent_launch_disabled() -> bool {
    disabled_by(
        std::env::var(LAUNCH_ENV).ok().as_deref(),
        std::env::var(DISABLED_ENV).ok().as_deref(),
    )
}

fn disabled_by(launch: Option<&str>, disabled: Option<&str>) -> bool {
    launch.is_some_and(|v| v.trim().eq_ignore_ascii_case("deny"))
        || disabled.is_some_and(|v| v.trim() == "1")
}

/// `Err(AgentLaunchDisabled)` when launches are off; called before any spawn.
pub fn refuse_if_disabled() -> anyhow::Result<()> {
    if agent_launch_disabled() { Err(AgentLaunchDisabled.into()) } else { Ok(()) }
}

/// The ACP error a refused launch returns to the client.
pub fn rpc_error() -> RpcError {
    RpcError::new(DISABLED_CODE, DISABLED_MESSAGE)
        .with_data(serde_json::json!({"reason": DISABLED_REASON, "retryable": false}))
}

/// Maps a spawn failure: the kill switch keeps its own error, any other
/// failure goes through `other`.
pub fn spawn_error(e: anyhow::Error, other: impl FnOnce(anyhow::Error) -> RpcError) -> RpcError {
    if e.chain().any(|c| c.downcast_ref::<AgentLaunchDisabled>().is_some()) {
        rpc_error()
    } else {
        other(e)
    }
}

/// `"deny"` or `"allow"`, for `_acpmux/status`.
pub fn status_word() -> &'static str {
    if agent_launch_disabled() { "deny" } else { "allow" }
}
