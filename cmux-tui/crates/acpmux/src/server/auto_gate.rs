//! Who may call the daemon's Auto methods (`auto_session/surface.rs`).
//!
//! The chat's own machine switches Auto and settles its kept changes, so none of the three is
//! served to a remote connection or a peer. On this machine they are the person's:
//!
//! - `set` copies the chat and its folder to the Cloud (the setting is the person's to turn on),
//!   and `leftover` with `apply` or `discard` changes the folder or deletes the kept changes. Both
//!   need the person: the app's pane, a connection that proved it is the person, or the local
//!   socket with no agent behind it. This is the line `_acpmux/set_turn_cap` draws.
//! - `wake` stops every Auto chat's processes until the store answers, so an agent's connection
//!   never sends it.
//! - `leftover` with `show` only reads, and any local connection may; so does `transcript`.

use std::sync::Arc;

use serde_json::Value;

use super::requests::person_asks;
use super::{Conn, Origin, session_key};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};

/// The person asks on `conn`, or nobody can tell: the local socket with no agent behind it (the
/// person's own terminal, a script of theirs).
fn persons(conn: &Conn) -> bool {
    person_asks(conn) || (conn.origin == Origin::Local && !conn.agent_side())
}

/// One of `_acpmux/auto_session/set`, `leftover` and `wake`, for `conn`.
pub(super) async fn request(
    hub: &Arc<Hub>,
    conn: &Conn,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    if conn.origin.web_class() {
        return Err(RpcError::method_not_found(&format!(
            "{m} (not served to a remote WebSocket connection or a peer)"
        )));
    }
    if m == method::MUX_AUTO_SESSION_WAKE {
        if conn.agent_side() {
            return Err(conn.person_only("telling the daemon that this machine woke"));
        }
        return Ok(crate::auto_session::surface::wake(hub));
    }
    if m == method::MUX_AUTO_SESSION_TRANSCRIPT {
        let s = hub.resolve(session_key(params)?)?;
        return crate::auto_session::surface::transcript(hub, &s, params);
    }
    let set = m == method::MUX_AUTO_SESSION_SET;
    let reads = !set && params.get("action").and_then(Value::as_str) == Some("show");
    if !reads && !persons(conn) {
        let what = if set { "switching Auto mode" } else { "settling a chat's kept changes" };
        return Err(conn.person_only(what));
    }
    let s = hub.resolve(session_key(params)?)?;
    crate::auto_session::surface::chat(hub, &s, params, set).await
}
