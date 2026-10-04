//! What an agent may call (plans/cmux-next/app-commands-codemode.md section 4).
//!
//! One function, [`agent_view`], decides for every agent surface (app CLI
//! commands run by an agent principal, `cmux mcp serve` tools, code mode)
//! whether an op is offered, needs the user's approval per call, or is
//! excluded, and why. Its inputs are the op's catalog fields and the agent
//! principal's grant; the daemon router applies the same answer on every call
//! so a surface that forgot to filter cannot widen it.

use std::collections::BTreeSet;

/// How an op declares itself to agents (catalog `mcp.expose`). An op with
/// no declaration is [`McpExpose::Never`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum McpExpose {
    Default,
    OptIn,
    Never,
}

/// The op's risk (catalog `risk`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Risk {
    Read,
    MutateOwn,
    MutateShared,
    Execute,
    SendExternal,
    Money,
    Destructive,
}

/// The class of the op's scope (`scope-classes.json`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScopeClass {
    Standard,
    Sensitive,
    Restricted,
}

/// The catalog fields [`agent_view`] reads for one op.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OpExposure {
    /// Full op name, for example `cmux.workspace.list` or `notes.capture`.
    pub name: String,
    /// The scope the op needs, for example `workspace:read`.
    pub scope: String,
    pub scope_class: ScopeClass,
    pub risk: Risk,
    pub mcp: McpExpose,
    /// The op runs only with a live user gesture (catalog `gesture: required`).
    pub gesture_required: bool,
    /// The op's result holds a secret (IR `x-cmux-secret` on an output field).
    pub secret_output: bool,
    /// The op belongs to an app (`app:<id>` owner) that is not installed and
    /// enabled on this machine.
    pub app_disabled: bool,
}

impl OpExposure {
    /// Reads one op of the IR (`cmux-pane-protocol/spec/pane-protocol.json`,
    /// `ops[]`). `scope_class` classifies a scope with `scope-classes.json`;
    /// `app_enabled` says whether an `app:<id>` owner is installed and
    /// enabled. Returns `None` for an op without a name or scope.
    pub fn from_ir(
        _op: &serde_json::Value,
        _scope_class: impl Fn(&str) -> ScopeClass,
        _app_enabled: impl Fn(&str) -> bool,
    ) -> Option<Self> {
        None
    }
}

/// An agent principal's grant, as the owner of the grant reports it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AgentGrant {
    /// Scopes the agent holds. `*` holds every scope (the user's mux).
    pub scopes: BTreeSet<String>,
    /// `opt_in` ops the user turned on for this agent.
    pub opted_in: BTreeSet<String>,
    /// Ops the user allowed without asking again ("Allow for this session").
    pub standing_approvals: BTreeSet<String>,
}

/// Why an op is not offered to an agent.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Exclusion {
    /// `mcp.expose` is `never` (or absent).
    NotOffered,
    /// `mcp.expose` is `opt_in` and the user has not turned it on.
    OptInOff,
    /// The op reads or makes secrets: passwords, keys, credentials, accounts.
    Secret,
    /// Only the user may run it: installs, grants, policy.
    UserOnly,
    /// The op needs a live user gesture.
    GestureRequired,
    /// The op's app is not installed and enabled.
    AppDisabled,
    /// The agent's grant does not hold the op's scope.
    NotGranted,
}

/// The answer for one op and one agent.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Exposure {
    Offered,
    /// Offered, but every call waits for the user's native approval.
    NeedsApproval,
    Excluded(Exclusion),
}

/// Scope families whose ops read or make secrets (PASSWORDS P2, identity
/// "no secret ever handed to an agent").
const SECRET_FAMILIES: &[&str] = &["passwords", "credentials", "accounts"];

/// Scope families only the user may change.
const USER_ONLY_FAMILIES: &[&str] = &["grants", "policy"];

/// Ops only the user may run: app installs, updates and grants
/// (app-platform.md section 15; agents may still hide and unhide apps).
const USER_ONLY_OPS: &[&str] = &[
    "cmux.apps.install",
    "cmux.apps.uninstall",
    "cmux.apps.update",
    "cmux.apps.grant.set",
    "cmux.apps.local.add",
    "cmux.apps.local.remove",
];

/// Decides whether `grant`'s agent may call `op`. Exclusions are checked in
/// a fixed order and always win over approvals; a standing approval never
/// adds a scope or lifts an exclusion.
pub fn agent_view(op: &OpExposure, grant: &AgentGrant) -> Exposure {
    if let Some(reason) = exclusion(op, grant) {
        return Exposure::Excluded(reason);
    }
    let risky = matches!(op.risk, Risk::Destructive | Risk::SendExternal | Risk::Money)
        || op.scope_class == ScopeClass::Restricted;
    if risky && !grant.standing_approvals.contains(&op.name) {
        Exposure::NeedsApproval
    } else {
        Exposure::Offered
    }
}

fn exclusion(op: &OpExposure, grant: &AgentGrant) -> Option<Exclusion> {
    let (family, verb) = op.scope.split_once(':').unwrap_or((op.scope.as_str(), ""));
    if op.secret_output || verb == "keys" || SECRET_FAMILIES.contains(&family) {
        return Some(Exclusion::Secret);
    }
    if USER_ONLY_FAMILIES.contains(&family) || USER_ONLY_OPS.contains(&op.name.as_str()) {
        return Some(Exclusion::UserOnly);
    }
    match op.mcp {
        McpExpose::Never => return Some(Exclusion::NotOffered),
        McpExpose::OptIn if !grant.opted_in.contains(&op.name) => {
            return Some(Exclusion::OptInOff);
        }
        McpExpose::Default | McpExpose::OptIn => {}
    }
    if op.gesture_required {
        return Some(Exclusion::GestureRequired);
    }
    if op.app_disabled {
        return Some(Exclusion::AppDisabled);
    }
    if !grant.scopes.contains("*") && !grant.scopes.contains(&op.scope) {
        return Some(Exclusion::NotGranted);
    }
    None
}

#[cfg(test)]
mod tests;
