//! The build-session kill switch for agent launches (cx-9ettq).
//!
//! GUI test jobs run tagged apps with the user's real credentials. With
//! `ACPMUX_AGENT_LAUNCH=deny` (or `CMUX_AGENTS_DISABLED=1`) in the daemon's
//! environment, acpmux starts no agent process at all: the spawn points
//! (`ChildAgent::spawn_with`, `agent::harness_command`,
//! `agent_host::link::spawn_within`) refuse, model probes and pool prewarms
//! skip, and `session/new` fails with [`rpc_error`], which says why and is not
//! retryable.
//!
//! `ACPMUX_AGENT_LAUNCH=only:<id>[,<id>...]` is the same switch with an
//! allowlist: only those harness ids start (a perf bench's replay agent),
//! every other launch is refused the same way, and what reads a real CLI's
//! credentials (sign-in checks, live model lists, CLI updates) stays off as
//! under `deny`. An empty list allows nothing.
//!
//! The variable is read at each check, never cached, so the daemon reads the
//! value it was started with (the app passes its own environment on).

use std::collections::BTreeSet;

use crate::rpc::RpcError;

/// The variable that names the policy: `deny` turns launches off,
/// `only:<id>,...` allows only those harnesses.
pub const LAUNCH_ENV: &str = "ACPMUX_AGENT_LAUNCH";
/// The app-wide switch; `1` turns launches off too.
pub const DISABLED_ENV: &str = "CMUX_AGENTS_DISABLED";
/// What a refused launch says, everywhere.
pub const DISABLED_MESSAGE: &str = "agent launch is disabled in this build session";
/// `data.reason` of the refusal, for clients that branch on it.
pub const DISABLED_REASON: &str = "agent_launch_disabled";
/// JSON-RPC code of the refusal (implementation-defined server error range).
pub const DISABLED_CODE: i64 = -32010;
/// The prefix of an allowlist value of [`LAUNCH_ENV`].
const ONLY_PREFIX: &str = "only:";

/// A spawn refused by the kill switch; callers map it with [`spawn_error`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AgentLaunchDisabled;

impl std::fmt::Display for AgentLaunchDisabled {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(DISABLED_MESSAGE)
    }
}

impl std::error::Error for AgentLaunchDisabled {}

/// Which agent launches this process may start.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LaunchPolicy {
    Allow,
    Deny,
    /// Only these harness ids.
    Only(BTreeSet<String>),
}

impl LaunchPolicy {
    /// The policy of this process's environment, read now.
    pub fn current() -> Self {
        Self::from_values(
            std::env::var(LAUNCH_ENV).ok().as_deref(),
            std::env::var(DISABLED_ENV).ok().as_deref(),
        )
    }

    /// The policy of given [`LAUNCH_ENV`] and [`DISABLED_ENV`] values.
    pub fn from_values(launch: Option<&str>, disabled: Option<&str>) -> Self {
        if disabled.is_some_and(|v| v.trim() == "1") {
            return Self::Deny;
        }
        let Some(launch) = launch.map(str::trim) else { return Self::Allow };
        if launch.eq_ignore_ascii_case("deny") {
            return Self::Deny;
        }
        match launch.split_at_checked(ONLY_PREFIX.len()) {
            Some((prefix, ids)) if prefix.eq_ignore_ascii_case(ONLY_PREFIX) => Self::Only(
                ids.split(',')
                    .map(str::trim)
                    .filter(|id| !id.is_empty())
                    .map(str::to_owned)
                    .collect(),
            ),
            _ => Self::Allow,
        }
    }

    /// Whether the harness `id` may start.
    pub fn allows(&self, id: &str) -> bool {
        match self {
            Self::Allow => true,
            Self::Deny => false,
            Self::Only(ids) => ids.contains(id),
        }
    }
}

/// Whether launches are limited (`deny` or an `only:` list): nothing that
/// reads a real CLI's credentials runs. Spawn points check
/// [`refuse_unless_allowed`] for their harness.
pub fn agent_launch_disabled() -> bool {
    LaunchPolicy::current() != LaunchPolicy::Allow
}

/// Whether every launch is off (`deny`), whatever the harness.
pub fn every_launch_denied() -> bool {
    LaunchPolicy::current() == LaunchPolicy::Deny
}

/// Whether the harness `id` may start now.
pub fn harness_launch_allowed(id: &str) -> bool {
    LaunchPolicy::current().allows(id)
}

/// `Err(AgentLaunchDisabled)` when every launch is off; called before a
/// spawn that does not know its harness id (its command line was built by
/// `agent::harness_command`, which checked the id).
pub fn refuse_if_denied() -> anyhow::Result<()> {
    if every_launch_denied() { Err(AgentLaunchDisabled.into()) } else { Ok(()) }
}

/// `Err(AgentLaunchDisabled)` unless the harness `id` may start; called
/// before its process spawns.
pub fn refuse_unless_allowed(id: &str) -> anyhow::Result<()> {
    if harness_launch_allowed(id) { Ok(()) } else { Err(AgentLaunchDisabled.into()) }
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

/// `"deny"`, `"only"` or `"allow"`, for `_acpmux/status`.
pub fn status_word() -> &'static str {
    match LaunchPolicy::current() {
        LaunchPolicy::Allow => "allow",
        LaunchPolicy::Deny => "deny",
        LaunchPolicy::Only(_) => "only",
    }
}

#[cfg(test)]
mod tests {
    use super::LaunchPolicy;

    fn only(ids: &[&str]) -> LaunchPolicy {
        LaunchPolicy::Only(ids.iter().map(|id| (*id).to_owned()).collect())
    }

    #[test]
    fn values_name_the_policy() {
        assert_eq!(LaunchPolicy::from_values(None, None), LaunchPolicy::Allow);
        assert_eq!(LaunchPolicy::from_values(Some(" Deny "), None), LaunchPolicy::Deny);
        assert_eq!(LaunchPolicy::from_values(None, Some("1")), LaunchPolicy::Deny);
        assert_eq!(LaunchPolicy::from_values(Some("only:replay"), Some("1")), LaunchPolicy::Deny);
        assert_eq!(LaunchPolicy::from_values(Some("only:replay"), None), only(&["replay"]));
        assert_eq!(LaunchPolicy::from_values(Some("ONLY: a, b ,"), None), only(&["a", "b"]));
        assert_eq!(LaunchPolicy::from_values(Some("only:"), None), only(&[]));
        assert_eq!(LaunchPolicy::from_values(Some("allow"), None), LaunchPolicy::Allow);
    }

    #[test]
    fn an_only_list_allows_its_harnesses_alone() {
        let policy = LaunchPolicy::from_values(Some("only:replay"), None);
        assert!(policy.allows("replay"));
        for other in ["claude", "codex", "unii", "replay2", ""] {
            assert!(!policy.allows(other), "{other}");
        }
        assert!(!LaunchPolicy::from_values(Some("only:"), None).allows("replay"));
        assert!(!LaunchPolicy::Deny.allows("replay"));
        assert!(LaunchPolicy::Allow.allows("claude"));
    }
}
