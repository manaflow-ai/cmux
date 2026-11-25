//! A client's request for a chat on a peer is that peer's use (`peer_demand.rs`): it keeps the
//! peer's link from closing unused, and dials a peer left undialed. The request waits for that
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
    let key = session_key(params).ok()?;
    super::peer_forward::target(hub, m, key).map(|(peer, ..)| peer)
}

/// Before a request is forwarded (`peer_forward::forward`): note the use, and dial an idle peer.
pub(super) async fn use_peer(hub: &Hub, m: &str, params: &Value) {
    let Some(peer) = target_peer(hub, m, params) else { return };
    peer.note_use();
    if !peer.idle_parked() {
        return;
    }
    if super::peer_forward::composing(m, params) {
        peer.want();
        return;
    }
    super::peer_forward::await_link(&peer, IDLE_DIAL_WAIT).await;
}
