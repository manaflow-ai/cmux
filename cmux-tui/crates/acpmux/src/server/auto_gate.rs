//! Who may call the daemon's Auto methods (`auto_session/surface.rs`).
//!
//! The chat's own machine switches Auto, moves the chat and settles its kept changes, so none of
//! the four is served to a remote connection or a peer. On this machine they are the person's:
//!
//! - `set` copies the chat and its folder to the Cloud (the setting is the person's to turn on),
//!   `move` stops the chat's turn and changes the machine it runs on, and `leftover` with `apply`
//!   or `discard` changes the folder or deletes the kept changes. All three need the person: the
//!   app's pane, a connection that proved it is the person, or the local socket with no agent
//!   behind it. This is the line `_acpmux/set_turn_cap` draws.
//! - `wake` stops every Auto chat's processes until the store answers, so an agent's connection
//!   never sends it.
//! - `leftover` with `show` only reads, and any local connection may; so does `transcript`.
//! - `_acpmux/chat_move` is `set` by `mode` for the person, and for a chat's own agent the moves
//!   `chat_place::consent` allows it.

use std::sync::Arc;

use serde_json::Value;

use super::requests::person_asks;
use super::{Conn, Origin, session_key};
use crate::auto_session::surface::Ask;
use crate::hub::Hub;
use crate::rpc::{RpcError, method};

/// The person asks on `conn`, or nobody can tell: the local socket with no agent behind it (the
/// person's own terminal, a script of theirs).
fn persons(conn: &Conn) -> bool {
    person_asks(conn) || (conn.origin == Origin::Local && !conn.agent_side())
}

/// One of `_acpmux/auto_session/set`, `move`, `leftover` and `wake`, for `conn`.
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
    let (ask, what) = match m {
        method::MUX_AUTO_SESSION_SET => (Ask::Set, "switching Auto mode"),
        method::MUX_AUTO_SESSION_MOVE => (Ask::Move, "moving a chat"),
        _ => (Ask::Leftover, "settling a chat's kept changes"),
    };
    let reads =
        ask == Ask::Leftover && params.get("action").and_then(Value::as_str) == Some("show");
    if !reads && !persons(conn) {
        return Err(conn.person_only(what));
    }
    let s = hub.resolve(session_key(params)?)?;
    crate::auto_session::surface::chat(hub, &s, params, ask).await
}

/// `_acpmux/chat_move`: Local, Cloud or AutoCloud for one chat, by the person or by the chat's
/// own agent within `chat_place::consent`. A move is one Auto `set` by `mode`, the store's
/// fenced handoff.
async fn chat_move(hub: &Arc<Hub>, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    use crate::chat_place::{Asker, Consent, Place, agent_moves_enabled, consent, not_moved};
    let word = params.get("on").and_then(Value::as_str).unwrap_or_default();
    let to = Place::parse(word).ok_or_else(|| {
        RpcError::invalid_params(format!("on must be local, cloud or auto (got {word:?})"))
    })?;
    let s = hub.resolve(session_key(params)?)?;
    let row = crate::auto_session::record::AutoRecord::row_of(hub.auto_record(&s).as_ref());
    let from = Place::of_row(&row);
    // A chat kept in the Cloud that runs on this Mac with no move under way (it has not gone
    // yet, or the Cloud did not take it) is not there: asked again, it is moved, by the rules
    // for a chat set to auto.
    let laptop = hub.auto_holder.get().is_some_and(|holder| !holder.on_machine());
    let waits_here = (from, to) == (Place::Cloud, Place::Cloud)
        && laptop
        && row["here"] == true
        && row.get("moving").is_none();
    let asker = if persons(conn) {
        Asker::Person
    } else {
        Asker::Agent {
            own_chat: conn.caller() == Some(s.id.as_str()),
            auto_cloud: crate::placement::auto_cloud_on(),
            enabled: agent_moves_enabled(),
        }
    };
    let verdict = consent(if waits_here { Place::Auto } else { from }, to, asker);
    let id = s.id.to_string();
    match verdict {
        Consent::Go => {
            let reason = params.get("reason").and_then(Value::as_str).unwrap_or_default();
            let agent = matches!(asker, Asker::Agent { .. });
            tracing::info!(session = %id, from = from.as_str(), to = to.as_str(), agent, reason,
                "chat move");
            // By `mode` (`surface.rs`): `cloud` moves the chat there now, and `local` brings a
            // chat the Cloud has home before Auto goes off.
            let set = to.set_params(&id);
            let mut answer = crate::auto_session::surface::chat(hub, &s, &set, Ask::Set).await?;
            // The answer says what the chat's row says: `moving` while it is on its way, and
            // never `moved` for a chat whose setting did not change.
            let row = answer.get("autoSession").unwrap_or(&Value::Null);
            let reads = Place::of_row(row);
            if reads != to {
                let (reads, to) = (reads.as_str(), to.as_str());
                let why = format!("this chat was not moved to {to}: it is still set to {reads}");
                return Err(RpcError::internal(why));
            }
            let status = if row.get("moving").is_some() { "moving" } else { "moved" };
            if let Some(o) = answer.as_object_mut() {
                o.insert("status".into(), status.into());
                o.insert("from".into(), from.as_str().into());
                o.insert("to".into(), to.as_str().into());
            }
            Ok(answer)
        }
        Consent::Refused(why) => Err(conn.person_only(why)),
        other => Ok(not_moved(&id, from, to, &other)),
    }
}
