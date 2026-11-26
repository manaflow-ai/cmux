//! A client's request for a chat on a peer is that peer's use (`peer_demand.rs`): it keeps the
//! peer's link from closing unused, and dials a peer left undialed. Listing is not: a chat's
//! metadata read (`_acpmux/info`) is what a list asks of every row it shows (a phone's chat list
//! reads each row's, `cmux-tui-core` `mobile_chat.rs` `visible`; the message policy reads each
//! chat's workspace, `agent_session_link.rs`), so with 130 machines one list would dial them
//! all. For a peer left undialed it is answered from the chat's last-known row, marked so and
//! with the link `idle`, and it never counts as a use of a link that is up. The request waits for that
//! dial up to [`IDLE_DIAL_WAIT`] instead of meeting a link that is down, so the first look at a
//! machine nobody used since this daemon started reads it live, not refused and retried. A sign
//! that a person writes (`composing`) waits for nothing: it only starts the dial, and
//! `peer_forward.rs` `ask_back` wakes the machine for it as before.

use super::*;

/// How long a request for an idle peer's chat waits for its dial: about one login and the
/// handshake. Past it the request goes on as for any peer that is down (a chat's copy, or a
/// refusal that asks for the peer).
pub(super) const IDLE_DIAL_WAIT: std::time::Duration = std::time::Duration::from_secs(5);

/// The peer request `m` with `params` is for, when it is one: a chat there, or its trust.
fn target_peer(hub: &Hub, m: &str, params: &Value) -> Option<Arc<crate::peer::Peer>> {
    if let Ok(Some(name)) = super::peer_forward::trust_peer(m, params) {
        return hub.peer_by_name(name);
    }
    if !super::peer_forward::names_a_session(m) {
        return None;
    }
    super::peer_forward::demand_target(hub, m, params).map(|(peer, ..)| peer)
}

/// Whether request `m` only reads what a chat's listed row already holds: no use of its peer.
fn lists(m: &str, params: &Value) -> bool {
    m == method::MUX_INFO && params.get("row").and_then(Value::as_bool) != Some(false)
}

/// A metadata read for a chat of a peer left undialed, answered from the row this daemon keeps
/// of it (`lists`); None when it names no such chat (or one with no row), or the peer is linked.
fn from_last_known(hub: &Hub, m: &str, params: &Value) -> Option<Value> {
    let (peer, _, row, _) = super::peer_forward::demand_target(hub, m, params)?;
    if !peer.idle_parked() || row.is_null() {
        return None;
    }
    let mut reply = super::peer_forward::from_row(&row, &peer.name);
    if let Some(obj) = reply.as_object_mut() {
        obj.insert("stale".into(), json!(true));
        // Down at its last record reads `offline`; else `idle`, also before its run first reports.
        let link = match peer.state() {
            crate::peer_link::PeerState::Offline => "offline",
            _ => "idle",
        };
        obj.insert("link".into(), json!(link));
    }
    Some(reply)
}

/// Before a request is forwarded (`peer_forward::forward`): note the use, and dial an idle peer.
/// A listing read (`lists`) is neither: it is answered here, from the last-known row, while the
/// peer waits to be used (Some), and goes on to a linked peer without counting as its use.
pub(super) async fn use_peer(hub: &Hub, m: &str, params: &Value) -> Option<Value> {
    if lists(m, params) {
        return from_last_known(hub, m, params);
    }
    let peer = target_peer(hub, m, params)?;
    peer.note_use();
    if !peer.idle_parked() {
        return None;
    }
    if super::peer_forward::composing(m, params) {
        peer.want();
        return None;
    }
    super::peer_forward::await_link(&peer, IDLE_DIAL_WAIT).await;
    None
}

#[cfg(test)]
#[path = "peer_demand_wait_tests.rs"]
mod tests;
