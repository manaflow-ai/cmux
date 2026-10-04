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

/// Decides whether `grant`'s agent may call `op`.
pub fn agent_view(_op: &OpExposure, _grant: &AgentGrant) -> Exposure {
    Exposure::Offered
}

#[cfg(test)]
mod tests;
