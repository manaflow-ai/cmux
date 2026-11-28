//! What an agent may call (plans/cmux-next/app-commands-codemode.md section 4).
//!
//! One function, [`agent_view`], decides for every agent surface (app CLI
//! commands run by an agent principal, `cmux mcp serve` tools, code mode)
//! whether an op is offered, needs the user's approval per call, or is
//! excluded, and why. Its inputs are the op's catalog fields and the agent
//! principal's grant; the daemon router applies the same answer on every call
//! so a surface that forgot to filter cannot widen it.

use std::collections::BTreeSet;

/// The class of the op's scope: the one table in `scope-classes.json`,
/// shared with the app platform (no second copy of the classes here).
pub use cmux_app_manifest::ScopeClass;
use cmux_app_manifest::scope_info;

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
    /// The op's scope is server-only (`process:spawn:*`, `op:*`): only an
    /// app server may hold it.
    pub server_only: bool,
    /// The op belongs to an app (`app:<id>` owner) that is not installed and
    /// enabled on this machine.
    pub app_disabled: bool,
}

impl OpExposure {
    /// Reads one op of the IR (`cmux-pane-protocol/spec/pane-protocol.json`,
    /// `ops[]`, with hq-48 decision 27's `risk`, `gesture`, `scope_class` and
    /// `server_only`). `app_enabled` says whether an `app:<id>` owner is
    /// installed and enabled. Returns `None` for an op without a name or scope.
    ///
    /// Missing or unknown fields fail closed: `mcp.expose` is
    /// [`McpExpose::Never`], `risk` is [`Risk::Destructive`], `gesture` is
    /// required, `scope_class` is [`ScopeClass::Restricted`] and a missing
    /// `secret_output` is true (emit-ir always writes it). A missing
    /// `server_only` is false here because emit-ir omits it when false;
    /// [`agent_view`] still reads the scope's class and server-only flag from
    /// `scope-classes.json`, so a missing flag never offers a server-only op.
    /// The input must be merged IR, not an app catalog (catalogs spell
    /// `gesture` and outputs differently).
    pub fn from_ir(op: &serde_json::Value, app_enabled: impl Fn(&str) -> bool) -> Option<Self> {
        let name = op["name"].as_str()?;
        let scope = op["scope"].as_str()?;
        let mcp = match op.pointer("/mcp/expose").and_then(serde_json::Value::as_str) {
            Some("default") => McpExpose::Default,
            Some("opt_in") => McpExpose::OptIn,
            _ => McpExpose::Never,
        };
        let risk = match op["risk"].as_str() {
            Some("read") => Risk::Read,
            Some("mutate-own") => Risk::MutateOwn,
            Some("mutate-shared") => Risk::MutateShared,
            Some("execute") => Risk::Execute,
            Some("send-external") => Risk::SendExternal,
            Some("money") => Risk::Money,
            _ => Risk::Destructive,
        };
        let scope_class = match op["scope_class"].as_str() {
            Some("standard") => ScopeClass::Standard,
            Some("sensitive") => ScopeClass::Sensitive,
            Some("elevated") => ScopeClass::Elevated,
            _ => ScopeClass::Restricted,
        };
        let app_disabled = op["owner"]
            .as_str()
            .and_then(|owner| owner.strip_prefix("app:"))
            .is_some_and(|app| !app_enabled(app));
        Some(Self {
            name: name.to_owned(),
            scope: scope.to_owned(),
            scope_class,
            risk,
            mcp,
            gesture_required: op["gesture"].as_bool() != Some(false),
            secret_output: op["secret_output"].as_bool() != Some(false),
            server_only: op["server_only"] == true,
            app_disabled,
        })
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
    /// The op's scope is server-only; only app servers may hold it.
    ServerOnly,
    /// The op needs a live user gesture.
    GestureRequired,
    /// The op's app is not installed and enabled.
    AppDisabled,
    /// The agent's grant does not hold the op's scope. An elevated scope
    /// counts only when the grant names it; `*` does not hold it.
    NotGranted,
    /// No rule of `scope-classes.json` knows the op's scope.
    UnknownScope,
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

/// Ops only the user may run, beyond the daemon's origin gate A2
/// (`request_origin::USER_ONLY_OPERATIONS`, which [`agent_view`] also reads):
/// app updates, grants, local apps and `cmux.apps.set` (app-platform.md
/// section 15 and D55 as amended: origin user for every field).
const USER_ONLY_OPS: &[&str] = &[
    "cmux.apps.update",
    "cmux.apps.set",
    "cmux.apps.grant.set",
    "cmux.apps.local.add",
    "cmux.apps.local.remove",
];

fn user_only(name: &str) -> bool {
    let daemon_name = name.strip_prefix("cmux.").unwrap_or(name);
    USER_ONLY_OPS.contains(&name)
        || crate::request_origin::USER_ONLY_OPERATIONS.contains(&daemon_name)
}

/// Decides whether `grant`'s agent may call `op`. Exclusions are checked in
/// a fixed order and always win over approvals; a standing approval never
/// adds a scope or lifts an exclusion.
pub fn agent_view(op: &OpExposure, grant: &AgentGrant) -> Exposure {
    if let Some(reason) = exclusion(op, grant) {
        return Exposure::Excluded(reason);
    }
    let class = scope_info(&op.scope).map_or(ScopeClass::Restricted, |info| info.class);
    let risky = matches!(op.risk, Risk::Destructive | Risk::SendExternal | Risk::Money)
        || [op.scope_class, class].contains(&ScopeClass::Restricted);
    if risky && !grant.standing_approvals.contains(&op.name) {
        Exposure::NeedsApproval
    } else {
        Exposure::Offered
    }
}

fn exclusion(op: &OpExposure, grant: &AgentGrant) -> Option<Exclusion> {
    let family = op.scope.split_once(':').map_or(op.scope.as_str(), |(family, _)| family);
    if op.secret_output || op.scope.ends_with(":keys") || SECRET_FAMILIES.contains(&family) {
        return Some(Exclusion::Secret);
    }
    if USER_ONLY_FAMILIES.contains(&family) || user_only(&op.name) {
        return Some(Exclusion::UserOnly);
    }
    let Some(info) = scope_info(&op.scope) else {
        return Some(Exclusion::UnknownScope);
    };
    if op.server_only || info.server_only {
        return Some(Exclusion::ServerOnly);
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
    let elevated = [op.scope_class, info.class].contains(&ScopeClass::Elevated);
    let wildcard = grant.scopes.contains("*") && !elevated;
    if !wildcard && !grant.scopes.contains(&op.scope) {
        return Some(Exclusion::NotGranted);
    }
    None
}
