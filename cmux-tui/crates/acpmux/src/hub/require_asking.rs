//! Part of `Hub`; see `hub/mod.rs`. `session/new` with `_meta.acpmux.requireAsking`: a start
//! that must ask before each change or not start at all. The acpmux MCP server's guest mode
//! (`acpmux_mcp_guest.rs`, through `acpmux new --require-asking`) sends it: a guest is not the
//! person, so a session it starts never acts without asking.
//!
//! A session's policy is held only in a harness mode that asks (`policy_mode.rs`); a harness
//! with none (the legacy codex-acp adapter, opencode, pi) logs `policy_unenforced` and runs.
//! This start is refused instead, before anything exists, by the table the Web and paired
//! machines start from (`web_modes::remote_start`, the reviewed asking modes): fail closed,
//! so a harness that does not resolve, or resolves to one that table does not list, is refused.
//! Also refused: no policy or approve-all, a start mode (`_meta.acpmux.mode`) and an adopt.
//!
//! The request check (`check_require_asking`) answers early; the start itself carries it
//! (`NewRequest::require_asking`) and checks again on the profile it actually resolves, under the
//! same config read (`lifecycle.rs`), so a config reload between the two (bare `codex` moved from
//! the bridge to the legacy adapter) is refused, and its `ask` policy fails the start if the
//! harness does not keep it (`policy_mode::require_enforced`), never only logged.

use super::*;

/// The `_meta.acpmux` field that asks for it.
pub const FIELD: &str = "requireAsking";
/// The `initialize` feature that says this daemon refuses on [`FIELD`]: a client that needs
/// it refuses to start against a daemon that would ignore it.
pub const FEATURE: &str = "requireAsking";

/// Whether `session/new`'s `_meta.acpmux` asks for it.
pub(crate) fn asked(meta: Option<&Value>) -> bool {
    meta.and_then(|m| m.get(FIELD)).and_then(Value::as_bool) == Some(true)
}

fn refused(why: String) -> RpcError {
    RpcError::invalid_params(why).with_data(json!({"reason": "start.not_asking"}))
}

/// Whether a start of `agent` (resolved to `profile`) under `policy`, with `meta`, is held to
/// asking before each change.
pub(crate) fn admits(
    cfg: &Config,
    agent: &str,
    profile: &HarnessProfile,
    policy: Option<PermissionPolicy>,
    meta: Option<&Value>,
) -> Result<(), RpcError> {
    if !policy.is_some_and(|p| p != PermissionPolicy::ApproveAll) {
        return Err(refused(
            "a start held to asking needs a policy narrower than approve-all".to_owned(),
        ));
    }
    let mode = meta.and_then(|m| m.get(crate::hub::person::START_MODE_FIELD));
    if mode.is_some_and(|m| !m.is_null()) {
        return Err(refused("a start held to asking takes no start mode".to_owned()));
    }
    crate::web_modes::remote_start_for_config(cfg, agent, profile).map(|_| ()).map_err(|why| {
        refused(format!("{agent} cannot be held to asking before each change: {why}"))
    })
}

/// The start's own check (`lifecycle.rs`), on the profile it resolved and under the config read
/// it resolved it with: a narrow policy, no adopt, and a harness the asking table lists.
pub(super) fn holds_at_start(
    cfg: &Config,
    agent: &str,
    profile: &HarnessProfile,
    policy: Option<PermissionPolicy>,
    adopting: bool,
) -> Result<(), RpcError> {
    if adopting {
        return Err(refused("a start held to asking adopts no conversation".to_owned()));
    }
    admits(cfg, agent, profile, policy, None)
}

impl Hub {
    /// [`admits`] for what `session/new` would resolve (`resolve_new`), before it exists.
    #[allow(clippy::too_many_arguments)]
    pub(crate) async fn check_require_asking(
        &self,
        harness: Option<String>,
        preset: Option<String>,
        model: Option<String>,
        cwd: Option<&Path>,
        policy: Option<PermissionPolicy>,
        meta: Option<&Value>,
        adopting: bool,
    ) -> Result<(), RpcError> {
        if adopting {
            return Err(refused("a start held to asking adopts no conversation".to_owned()));
        }
        // As `session/new`: the catalog and launcher checks, not every chat's adoption.
        self.wait_spawn_ready().await;
        let cfg = self.config.read().await;
        let r = self.resolve_new(&cfg, harness, &preset, model.as_deref(), false, cwd)?;
        admits(&cfg, &r.agent, &r.profile, policy, meta)
    }
}

#[cfg(test)]
mod tests;
