//! `_acpmux/session/auth {sessionId | target, refresh?}` (`hub/session_auth.rs`) for a chat on
//! this daemon, or a `target` with no `host`. A peer's chat is answered here from its link:
//! `peerUnreachable` when the link is down, else `unknown` until this daemon asks the peer; a
//! target on a peer (`target.host`) is not answered yet.

use super::Conn;
use crate::hub::Hub;
use crate::peer::Peer;
use crate::protocol::auth::{
    SessionAuthParams, SessionAuthResult, SessionAuthSource, SessionAuthState,
};
use crate::rpc::{RpcError, method};
use serde_json::Value;
use std::sync::Arc;
use std::sync::atomic::Ordering;

pub(super) async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: Value,
) -> Result<Value, RpcError> {
    let p: SessionAuthParams = serde_json::from_value(params.clone())
        .map_err(|e| RpcError::invalid_params(format!("{}: {e}", method::MUX_SESSION_AUTH)))?;
    // A probe or a check runs on this machine: never for a browser page on the listener.
    let control = super::remote_guard::control_of(conn.origin, conn.auth, &params);
    if p.refresh && control == crate::hub::Control::Web {
        return Err(RpcError::invalid_params(
            "a remote WebSocket connection reads sign-in evidence as last seen (no refresh)",
        ));
    }
    let reply = match (&p.session_id, &p.target) {
        (Some(key), None) => match hub.resolve(key) {
            Ok(s) => hub.session_auth(Some(&s), None, p.refresh).await?,
            Err(e) => {
                let Some((peer, _, row)) = hub.resolve_remote(key) else { return Err(e) };
                let harness = row.get("harness").and_then(Value::as_str).unwrap_or_default();
                from_link(&peer, harness)
            }
        },
        (None, Some(target)) if target.host.is_none() => {
            hub.session_auth(None, Some(target), p.refresh).await?
        }
        (None, Some(_)) => {
            return Err(RpcError::invalid_params(
                "this daemon does not answer a target on a peer yet",
            ));
        }
        _ => {
            return Err(RpcError::invalid_params(
                "exactly one of sessionId and target is required",
            ));
        }
    };
    serde_json::to_value(reply).map_err(|e| RpcError::internal(e.to_string()))
}

/// A peer's chat, from the link to the peer: `peerUnreachable` when it is down, else `unknown`.
fn from_link(peer: &Arc<Peer>, harness: &str) -> SessionAuthResult {
    let down = !peer.connected.load(Ordering::SeqCst);
    let link = down.then(|| peer.link());
    SessionAuthResult {
        state: if down { SessionAuthState::PeerUnreachable } else { SessionAuthState::Unknown },
        source: if down { SessionAuthSource::PeerLink } else { SessionAuthSource::None },
        evidence_at: link.map(|l| l.down_since.unwrap_or_else(crate::store::now_ms)),
        detail: if down {
            format!("the link to {} is {}", peer.name, peer.state().as_str())
        } else {
            format!("this daemon does not ask {} about a chat's sign-in yet", peer.name)
        },
        harness: harness.to_owned(),
        host: Some(peer.name.clone()),
        route_id: None,
        login: None,
        from_session_id: None,
    }
}
