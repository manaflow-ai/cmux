//! The person's Stop of a chat on a peer (`hub/cancel.rs` `person_stop`). The peer daemon's link
//! is never the person there (`hub/person.rs`), so a Stop forwarded as a bare `session/cancel`
//! was a plain cancel on the peer: the stopped turn ended and the other agents' messages queued
//! behind it started the next turn at once (Leo, 2026-10-29: "i literally can't stop you i
//! clicked the stop button and it didnt do anything so this is still busted"). Now:
//!
//! - This daemon forwards the person's Stop with `_meta.acpmux.personStop: true`, to a peer that
//!   lists `personStop` in its `initialize` (`hub/cancel.rs` `PERSON_STOP_FEATURE`, `peer.rs`). An older peer gets
//!   the plain cancel it always took: no error, and its agent messages run on as before.
//! - A peer takes `personStop` only from a peer daemon's own link (`PeerToken`, held to the
//!   peer's rules), never from one forwarding for its Web client or a paired machine, and never
//!   from any other connection. It then runs the same `person_stop` as for its own person, so the
//!   hold and the escalation behave as they do here.
//! - What a client wrote there itself is dropped before the forward ([`mark`]): only this
//!   daemon's word that its person pressed Stop goes on.
//!
//! The field only holds agent messages back (it narrows what runs); the cancel itself is what
//! the link could already send.

use crate::hub::{Control, Hub, Session};
use crate::rpc::RpcError;
use crate::server::{Conn, ConnAuth, Origin};
use serde_json::{Value, json};
use std::sync::Arc;

const FIELD: &str = "personStop";

/// Whether this Stop is the person's: the connection proved the person key here, or it is a peer
/// daemon's own link that says its person pressed Stop.
fn of(conn: &Conn, params: &Value) -> bool {
    if conn.is_person() {
        return true;
    }
    let control = crate::server::remote_guard::control_of(conn.origin, conn.auth, params);
    conn.origin == Origin::Peer
        && conn.auth == ConnAuth::PeerToken
        && control == Control::Peer
        && crate::hub::vm_boundary::owner(conn.auth, control, params)
        && params.pointer("/_meta/acpmux").and_then(|m| m.get(FIELD)) == Some(&Value::Bool(true))
}

/// `forwarded`, a cancel going to `peer`, says it is the person's when it is ([`of`]) and the
/// peer takes the field; whatever the client wrote there is dropped first.
pub(in crate::server) fn mark(
    conn: &Conn,
    params: &Value,
    peer: &crate::peer::Peer,
    forwarded: &mut Value,
) {
    if let Some(mux) = forwarded.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
        mux.remove(FIELD);
    }
    if of(conn, params) && peer.person_stop.load(std::sync::atomic::Ordering::SeqCst) {
        crate::hub::merge_mux_meta(forwarded, json!({FIELD: true}));
    }
}

/// A Stop of `session`, a chat on this daemon: the person's ([`of`]) holds the other agents'
/// messages behind its turn; any other is a plain cancel.
pub(in crate::server) async fn stop(
    hub: &Arc<Hub>,
    conn: &Conn,
    params: &Value,
    session: &Arc<Session>,
) -> Result<(), RpcError> {
    if of(conn, params) { hub.person_stop(session).await } else { hub.cancel(session).await }
}
