//! Public ids and principals.
//!
//! Ids are public prefixed strings (`task_…`, `st_…`, `lbl_…`, `prj_…`,
//! `rel_…`, `cmt_…`, `asess_…`). Creates take a client-chosen id so a retried
//! create converges and a client can reference an entity before its echo.

use serde::{Deserialize, Serialize};

/// Id prefixes per entity kind.
pub mod prefix {
    pub const TASK: &str = "task_";
    pub const STATUS: &str = "st_";
    pub const LABEL: &str = "lbl_";
    pub const PROJECT: &str = "prj_";
    pub const RELATION: &str = "rel_";
    pub const COMMENT: &str = "cmt_";
    pub const SESSION: &str = "asess_";
    pub const USER: &str = "usr_";
    pub const AGENT: &str = "agt_";
}

/// Whether `id` has `prefix` followed by 1..=64 characters of `[0-9a-z_-]`.
pub fn is_valid_id(id: &str, prefix: &str) -> bool {
    let Some(rest) = id.strip_prefix(prefix) else {
        return false;
    };
    !rest.is_empty()
        && rest.len() <= 64
        && rest
            .bytes()
            .all(|b| b.is_ascii_digit() || b.is_ascii_lowercase() || b == b'_' || b == b'-')
}

/// Agent classes (D20): muxes operate on everything, ordinary agents are scoped.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentClass {
    Mux,
    Ordinary,
}

/// An agent principal. `on_behalf_of` is the person the agent works for.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct AgentRef {
    pub principal: String,
    pub class: AgentClass,
    /// claude, codex, opencode, … (free text; the dispatcher interprets it).
    pub harness: String,
    pub on_behalf_of: String,
}

/// Who acts or who is assigned. The actor of an op always comes from the
/// connection (token or socket peer), never from op params.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Principal {
    User { id: String },
    Agent(AgentRef),
}

impl Principal {
    pub fn user(id: impl Into<String>) -> Self {
        Self::User { id: id.into() }
    }

    /// Stable id of this principal (`usr_…` or `agt_…`).
    pub fn id(&self) -> &str {
        match self {
            Self::User { id } => id,
            Self::Agent(agent) => &agent.principal,
        }
    }

    /// The person accountable for this principal's actions.
    pub fn human(&self) -> &str {
        match self {
            Self::User { id } => id,
            Self::Agent(agent) => &agent.on_behalf_of,
        }
    }

    pub fn is_user(&self) -> bool {
        matches!(self, Self::User { .. })
    }

    pub fn is_mux(&self) -> bool {
        matches!(self, Self::Agent(AgentRef { class: AgentClass::Mux, .. }))
    }

    pub fn is_ordinary_agent(&self) -> bool {
        matches!(self, Self::Agent(AgentRef { class: AgentClass::Ordinary, .. }))
    }
}
