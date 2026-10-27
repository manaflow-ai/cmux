//! Read-only agent session observation (`agent-session-observe-v1`).
//!
//! Observation uses the same trusted local routing and attachment lifecycle as
//! `agent-session-attach`, but marks the attachment so session mutations are
//! refused while history and live records remain available.

use serde_json::{Map, Value};

use super::{PageParams, Refusal, attach, refuse};
use crate::server::FrameStage;
use crate::server::routes::{Route, RouteLine, RouteName};

pub const AGENT_SESSION_OBSERVE_CAPABILITY: &str = "agent-session-observe-v1";
const COMMAND: &str = "agent-session-observe";

/// The `cmd` this module answers (server/routes.rs): its exact name wins
/// over the `agent-session-` prefix of the attach route.
pub(in crate::server) const ROUTES: &[Route] = &[Route {
    names: &[RouteName::Exact(COMMAND)],
    stage: FrameStage::AgentSession,
    entry: handle,
}];

/// The route's typed handler: the line's `cmd` named the observer command, so
/// it decodes the line once and answers it. A line whose full decode fails is
/// left to the `Command` parse (`None`).
fn handle(line: &RouteLine<'_>) -> Option<bool> {
    let RouteLine { mux, client, message, writer, .. } = *line;
    let mut object = crate::line_parses::parse::<Map<String, Value>>(message).ok()?;
    object.remove("cmd");
    let id = object.remove("id");
    let Ok(params) = serde_json::from_value::<PageParams>(Value::Object(object)) else {
        return Some(refuse(writer, id, Refusal::BadRequest));
    };
    if !mux.control_clients.is_unix(client) || mux.is_remote_client(client) {
        return Some(refuse(writer, id, Refusal::NotTrusted));
    }
    let sessions = &mux.control_clients.agent_sessions;
    let Some(socket) = sessions.socket() else {
        return Some(refuse(writer, id, Refusal::Unavailable));
    };
    Some(attach(mux, client, id, socket, params, true, writer))
}
