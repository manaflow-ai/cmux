//! The app's person proof may authorize a race on its owner's paired daemon. This is a
//! race-only assertion, bound to one exact parent and method, never a general person proof.
//! A peer cannot forward it onward, and Web/device/agent requests cannot mint one.

use super::*;
use crate::hub::{Control, Session};
use crate::server::{ConnAuth, Origin};

const FIELD: &str = "raceOwner";

fn allowed_method(m: &str) -> bool {
    matches!(
        m,
        method::MUX_RACE_START
            | method::MUX_RACE_LIST
            | method::MUX_RACE_GET
            | method::MUX_RACE_CANCEL
            | method::MUX_RACE_STATS
    )
}

fn owner_link(origin: Origin, auth: ConnAuth, params: &Value) -> bool {
    let control = crate::server::remote_guard::control_of(origin, auth, params);
    origin == Origin::Peer
        && auth.peer_daemon()
        && control == Control::Peer
        && crate::hub::vm_boundary::owner(auth, control, params)
        && !crate::server::remote_guard::cloud_mobile(params)
}

fn asserted(origin: Origin, auth: ConnAuth, m: &str, params: &Value) -> bool {
    let Some(parent) = str_param(params, "parent").filter(|p| !p.is_empty()) else { return false };
    owner_link(origin, auth, params)
        && allowed_method(m)
        && params.pointer("/_meta/acpmux/raceOwner/parent").and_then(Value::as_str) == Some(parent)
        && params.pointer("/_meta/acpmux/raceOwner/method").and_then(Value::as_str) == Some(m)
}

/// Only the owning person's connection or the exact validated one-hop assertion can
/// authorize worktrees for a peer-created parent. Request body flags confer no authority.
pub(super) fn owner_authorized(conn: &Conn, m: &str, params: &Value) -> bool {
    (conn.is_person()
        && matches!(conn.origin, Origin::Local | Origin::LocalApp)
        && crate::server::remote_guard::control_of(conn.origin, conn.auth, params)
            == Control::Local)
        || asserted(conn.origin, conn.auth, m, params)
}

pub(super) fn parent(
    hub: &Hub,
    conn: &Conn,
    m: &str,
    params: &Value,
) -> Result<Arc<Session>, RpcError> {
    if asserted(conn.origin, conn.auth, m, params) {
        let key = str_param(params, "parent").unwrap_or_default();
        let session = hub.resolve(key)?;
        // Never accept a mutable name/prefix: the assertion identifies a session, not a lookup.
        if session.id != key {
            return Err(refused());
        }
        return Ok(session);
    }
    crate::server::subsessions::start_parent(hub, conn, params)
}

fn refused() -> RpcError {
    RpcError::invalid_params("a peer race requires the owning app's person proof for this parent")
        .with_data(json!({"reason": "race.owner_required"}))
}

fn forwarded(params: &Value, parent: &str, m: &str) -> Value {
    // No caller-supplied metadata or assertion is forwarded. Only these race inputs cross.
    let mut p = json!({"parent": parent, "_meta": {"acpmux": {
        FIELD: {"parent": parent, "method": m}, "via": "app"
    }}});
    for field in ["prompt", "candidates", "reviewer", "raceId"] {
        if let (Some(value), Some(map)) = (params.get(field), p.as_object_mut()) {
            map.insert(field.to_owned(), value.clone());
        }
    }
    p
}

pub(super) async fn forward(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    // Peer and other remote connections never discover or forward to a second machine.
    if !matches!(conn.origin, Origin::Local | Origin::LocalApp) || !allowed_method(m) {
        return None;
    }
    let key = str_param(params, "parent")?;
    if hub.resolve(key).is_ok() {
        return None;
    }
    // Do not let an agent borrow the peer daemon's authority by naming a remote parent.
    if !conn.is_person()
        || crate::server::remote_guard::control_of(conn.origin, conn.auth, params) != Control::Local
    {
        return Some(Err(refused()));
    }
    let Some((peer, id, _)) = hub.resolve_remote(key) else {
        return hub.peer_down_for(key).map(Err);
    };
    if !peer.ready() {
        peer.want();
        return Some(Err(peer.unreachable_error()));
    }
    if peer.served_as().as_deref() != Some("peer") {
        return Some(Err(refused()));
    }
    crate::server::view::subscribe_remote(hub, conn, &id, None);
    if peer.mark_attached(&id) {
        // The subscription belongs to the shared peer link, not the duration of this request.
        let attaching = tokio::spawn({
            let (peer, id) = (peer.clone(), id.clone());
            async move { peer.attach_hidden(&id).await }
        });
        if let Err(error) =
            attaching.await.unwrap_or_else(|e| Err(RpcError::internal(e.to_string())))
        {
            return Some(Err(error));
        }
    }
    let result = peer.request(m, forwarded(params, &id, m)).await.map(|mut answer| {
        qualify_reply(&peer.name, &mut answer);
        answer
    });
    Some(result)
}

fn qualify_id(peer: &str, value: &mut Value) {
    if let Some(id) = value.as_str().filter(|s| !s.is_empty()) {
        *value = json!(format!("{peer}/{id}"));
    }
}

/// Race data is stored with daemon-local ids; the viewer uses that daemon's qualified routes.
pub(in crate::server) fn qualify_reply(peer: &str, answer: &mut Value) {
    if let Some(races) = answer.get_mut("races").and_then(Value::as_array_mut) {
        for race in races {
            qualify_reply(peer, race);
        }
        return;
    }
    if answer.get("parent").and_then(Value::as_str).is_none() {
        return;
    }
    qualify_id(peer, &mut answer["parent"]);
    if let Some(id) = answer.get_mut("reviewerSessionId") {
        qualify_id(peer, id);
    }
    if let Some(candidates) = answer.get_mut("candidates").and_then(Value::as_array_mut) {
        for candidate in candidates {
            if let Some(id) = candidate.get_mut("sessionId") {
                qualify_id(peer, id);
            }
        }
    }
}

/// Applied only at the local client boundary, never persisted or forwarded to another peer.
pub(in crate::server) fn qualify_event(peer: &str, event: &mut Value) {
    if event.get("kind").and_then(Value::as_str) == Some("race")
        && let Some(race) = event.get_mut("msg")
    {
        qualify_reply(peer, race);
    }
}

#[cfg(test)]
mod tests;
