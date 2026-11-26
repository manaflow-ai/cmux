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
    if m == method::MUX_CHAT_MOVE {
        return chat_move(hub, conn, params).await;
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

/// `_acpmux/chat_move`: Local, Cloud or AutoCloud for one chat, by the person or by the chat's
/// own agent within `chat_place::consent`. A move is one Auto `set`, the store's fenced handoff.
async fn chat_move(hub: &Arc<Hub>, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    use crate::chat_place::{Asker, Consent, Place, agent_moves_enabled, consent, not_moved};
    let word = params.get("on").and_then(Value::as_str).unwrap_or_default();
    let to = Place::parse(word).ok_or_else(|| {
        RpcError::invalid_params(&format!("on must be local, cloud or auto (got {word:?})"))
    })?;
    let s = hub.resolve(session_key(params)?)?;
    let from = Place::of_row(&crate::auto_session::record::AutoRecord::row_of(
        hub.auto_record(&s).as_ref(),
    ));
    let asker = if persons(conn) {
        Asker::Person
    } else {
        Asker::Agent {
            own_chat: conn.caller() == Some(s.id.as_str()),
            auto_cloud: crate::placement::auto_cloud_on(),
            enabled: agent_moves_enabled(),
        }
    };
    let verdict = consent(from, to, asker);
    let id = s.id.to_string();
    match verdict {
        Consent::Go => {
            let reason = params.get("reason").and_then(Value::as_str).unwrap_or_default();
            let agent = matches!(asker, Asker::Agent { .. });
            tracing::info!(session = %id, from = from.as_str(), to = to.as_str(), agent, reason,
                "chat move");
            let set = to.set_params(&id);
            let mut answer = crate::auto_session::surface::chat(hub, &s, &set, true).await?;
            if let Some(o) = answer.as_object_mut() {
                o.insert("status".into(), "moved".into());
                o.insert("from".into(), from.as_str().into());
                o.insert("to".into(), to.as_str().into());
            }
            Ok(answer)
        }
        Consent::Refused(why) => Err(conn.person_only(why)),
        other => Ok(not_moved(&id, from, to, &other)),
    }
}
