//! Who created a session (`SessionMeta::created_by`, the summary's `createdBy`): the person, an
//! agent session or a script, in the shape cmux-tui's `workspace.create {created_by}` takes, so
//! the app places a chat an agent or a script made below its creator as it places a workspace.
//!
//! Decided once by the daemon, at creation, from what the connection proved, never from a
//! request value:
//! - `agent`: a connection that proved with its caller token that it runs in session S
//!   (`acpmux new` in S's shell, `hub/person.rs` (a)) and is not the person, or S's
//!   `start_session` tool (`subsessions.rs`). `session` is S, `workspace` S's workspace.
//! - `person`: this host's app or a connection that proved it is the person (`person_asks`),
//!   and a Web client (the person's phone or browser), told by its connection
//!   (`remote_guard::proven_control`), never by a request marker such as `via`.
//! - `script`: any other client: the CLI outside a chat, a script, a Cloud trigger
//!   (`server/trigger_chat.rs`, from the trigger's workspace).
//!
//! A workflow's agent activity (`workflow_activity.rs`) is its owning agent's.
//!
//! A peer daemon forwarding a start stamps its own answer as `_meta.acpmux.createdBy`
//! ([`FIELD`]); the host takes it only from a proven peer (`Control::Peer`), else ignores it.
//! `workspace` for a person or a script is the workspace the create named.

use super::*;
use crate::store::{CreatedBy, CreatorKind};

/// `_meta.acpmux` field of a `session/new` a peer daemon forwards: its own [`CreatedBy`].
pub const FIELD: &str = "createdBy";
/// The longest workspace or session id a peer's stamp may carry.
const MAX_ID: usize = 256;

/// What a `session/new`'s connection proved, for [`Hub::creator_of`].
pub struct Creator<'a> {
    /// The connection proved it is the person, or is this host's app.
    pub person: bool,
    /// The session the connection proved it runs in (`Conn::caller`).
    pub caller: Option<&'a str>,
    /// The connection's own proof (`remote_guard::proven_control`), not a request's marker.
    pub control: Control,
    /// The request's `_meta.acpmux`, read for [`FIELD`] from a proven peer only.
    pub meta: Option<&'a Value>,
    /// The workspace the create named (`_meta.acpmux.workspaceId`).
    pub workspace: Option<String>,
}

/// An agent session `id` with meta `m` created it.
pub(crate) fn agent(id: &str, m: &SessionMeta) -> CreatedBy {
    CreatedBy {
        kind: CreatorKind::Agent,
        workspace: m.workspace_id.clone(),
        session: Some(id.to_owned()),
    }
}

/// Agent session `id` created it, from its workspace when it is here.
pub(crate) fn owner(hub: &Hub, id: &str) -> CreatedBy {
    match hub.session_meta_by_id(id) {
        Some(m) => agent(id, &m),
        None => {
            CreatedBy { kind: CreatorKind::Agent, workspace: None, session: Some(id.to_owned()) }
        }
    }
}

/// A peer's [`FIELD`] stamp, when it is well formed.
fn stamped(meta: Option<&Value>) -> Option<CreatedBy> {
    let by: CreatedBy = serde_json::from_value(meta?.get(FIELD)?.clone()).ok()?;
    let fits =
        |id: &Option<String>| id.as_ref().is_none_or(|id| !id.is_empty() && id.len() <= MAX_ID);
    (fits(&by.workspace) && fits(&by.session)).then_some(by)
}

impl Hub {
    /// Who creates a session from a connection that proved `c` (module docs).
    pub fn creator_of(&self, c: Creator<'_>) -> CreatedBy {
        let named = |kind| CreatedBy { kind, workspace: c.workspace.clone(), session: None };
        match c.control {
            Control::Peer => return stamped(c.meta).unwrap_or_else(|| named(CreatorKind::Script)),
            Control::Web => return named(CreatorKind::Person),
            Control::Local => {}
        }
        if c.person {
            return named(CreatorKind::Person);
        }
        match c.caller.and_then(|id| Some((id, self.session_meta_by_id(id)?))) {
            Some((id, m)) => agent(id, &m),
            None => named(CreatorKind::Script),
        }
    }
}
