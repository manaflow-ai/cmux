//! `_acpmux/session/auth {sessionId, refresh?}` (`hub/session_auth.rs`) for a chat on this
//! daemon. A peer's chat is forwarded whole to the peer before this runs (`peer_forward.rs`).

use super::Conn;
use crate::hub::Hub;
use crate::protocol::auth::SessionAuthParams;
use crate::rpc::{RpcError, method};
use serde_json::Value;
use std::sync::Arc;

pub(super) async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: Value,
) -> Result<Value, RpcError> {
    let p: SessionAuthParams = serde_json::from_value(params.clone())
        .map_err(|e| RpcError::invalid_params(format!("{}: {e}", method::MUX_SESSION_AUTH)))?;
    // A check runs a program on this machine: never for a browser page on the listener.
    let control = super::remote_guard::control_of(conn.origin, conn.auth, &params);
    if p.refresh && control == crate::hub::Control::Web {
        return Err(RpcError::invalid_params(
            "a remote WebSocket connection reads sign-in evidence as last seen (no refresh)",
        ));
    }
    let key = match (&p.session_id, &p.target) {
        (Some(key), None) => key,
        (None, Some(_)) => {
            return Err(RpcError::invalid_params("this daemon does not answer a target yet"));
        }
        _ => {
            return Err(RpcError::invalid_params(
                "exactly one of sessionId and target is required",
            ));
        }
    };
    let s = hub.resolve(key)?;
    let reply = hub.session_auth(&s, p.refresh).await?;
    serde_json::to_value(reply).map_err(|e| RpcError::internal(e.to_string()))
}
