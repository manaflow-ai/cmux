//! Read-only agent session observation (`agent-session-observe-v1`).
//!
//! Observation uses the same trusted local routing and attachment lifecycle as
//! `agent-session-attach`, but marks the attachment so session mutations are
//! refused while history and live records remain available.

use std::sync::Arc;

use serde_json::{Map, Value};

use super::{PageParams, Refusal, attach, refuse};
use crate::mux::Mux;
use crate::server::routes::{Route, RouteLine, RouteName};
use crate::server::{FrameStage, MessageWriter};

pub const AGENT_SESSION_OBSERVE_CAPABILITY: &str = "agent-session-observe-v1";
const COMMAND: &str = "agent-session-observe";

/// The `cmd` this module answers (server/routes.rs): its exact name wins
/// over the `agent-session-` prefix of the attach route.
pub(in crate::server) const ROUTES: &[Route] = &[Route {
    names: &[RouteName::Exact(COMMAND)],
    stage: FrameStage::AgentSession,
    entry: handle,
}];

/// The route's typed handler: the observer command goes through the attach
/// family's front door ([`super::try_handle`]), which checks a teammate's link
/// (its fixed identity and pinned chat) before it calls [`observe`].
fn handle(line: &RouteLine<'_>) -> Option<bool> {
    let RouteLine { mux, client, message, writer, .. } = *line;
    super::try_handle(mux, client, message, writer)
}

/// Answers an `agent-session-observe` line, its `cmd` already taken, for the
/// teammate `author` (and the chat its share `pinned`) or the local owner.
pub(super) fn observe(
    mux: &Arc<Mux>,
    client: u64,
    mut object: Map<String, Value>,
    writer: &MessageWriter,
    author: Option<Value>,
    pinned: Option<String>,
) -> bool {
    let id = object.remove("id");
    let Ok(params) = serde_json::from_value::<PageParams>(Value::Object(object)) else {
        return refuse(writer, id, Refusal::BadRequest);
    };
    if !mux.control_clients.is_unix(client) || mux.is_remote_client(client) {
        return refuse(writer, id, Refusal::NotTrusted);
    }
    let sessions = &mux.control_clients.agent_sessions;
    let Some(socket) = sessions.socket() else {
        return refuse(writer, id, Refusal::Unavailable);
    };
    attach(mux, client, id, socket, params, true, author, pinned, writer)
}
