//! A connection's attachments and whether it shows each chat (cx-n8ou,
//! `hub/seen.rs`): `_acpmux/attach` with `visible: false` holds a chat
//! without showing it, `_acpmux/view` changes that, and detaching or
//! disconnecting lets go with the same visibility it held.
//!
//! Presence (`hub/presence.rs`): `_acpmux/typing` names its person in `_meta.acpmux.author`;
//! detaching or disconnecting ends this connection's entries.

use super::*;
use crate::hub::presence::Who;

/// Subscribes for `_acpmux/attach`, counting a new attachment and a changed
/// visibility of an existing one.
pub(super) fn attach(hub: &Hub, conn: &Conn, s: &crate::hub::Session, opts: SubOpts) {
    let hidden = opts.hidden;
    conn.bind_mailbox_receipt(crate::session_identity::SessionReceipt::new(
        crate::session_identity::LOCAL_HOST_ID,
        s.id.clone(),
        s.meta().agent_session_id,
        hub.started_at,
    ));
    match conn.subs.lock().unwrap_or_else(|e| e.into_inner()).insert(s.id.clone(), opts) {
        None => hub.attach_count(s, 1, !hidden),
        Some(before) if before.hidden != hidden => hub.set_visible(s, !hidden),
        Some(_) => {}
    }
}

/// Whether presence may still change for `conn`; read under its subscriptions' lock, as every
/// presence change of a connection is made. The connection's end is marked before
/// `release_all` takes that lock, so a request still running then (an attach in flight) adds no
/// entry that nothing would remove. A peer daemon's link stands for none of its clients
/// (`hub/presence.rs`): it never makes an entry.
fn open(conn: &Conn) -> bool {
    conn.origin != Origin::Peer && !*conn.ended.borrow()
}

/// `_acpmux/detach`.
pub(super) fn detach(hub: &Hub, conn: &Conn, s: &crate::hub::Session) {
    let mut subs = conn.subs.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(before) = subs.remove(&s.id) {
        conn.unbind_mailbox_receipt(&s.id);
        hub.attach_count(s, -1, !before.hidden);
    }
    hub.presence.leave(&s.id, &conn.id);
}

/// `_acpmux/view {sessionId, visible}`: whether this attached client shows the chat.
pub(super) fn view(hub: &Hub, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    let s = hub.resolve(session_key(params)?)?;
    let visible = params
        .get("visible")
        .and_then(Value::as_bool)
        .ok_or_else(|| RpcError::invalid_params("visible must be true or false"))?;
    let mut subs = conn.subs.lock().unwrap_or_else(|e| e.into_inner());
    let sub = subs
        .get_mut(&s.id)
        .ok_or_else(|| RpcError::invalid_params("attach to the session before _acpmux/view"))?;
    if sub.hidden == visible {
        sub.hidden = !visible;
        // Under the lock, so a detach racing this one counts the same visibility.
        hub.set_visible(&s, visible);
    }
    Ok(json!({}))
}

/// `_acpmux/typing {sessionId, on}`: the caller's author (or the owner) starts or stops typing
/// in an attached chat. Never written anywhere (`hub/presence.rs`).
pub(super) fn typing(hub: &Hub, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    let s = hub.resolve(session_key(params)?)?;
    let on = params
        .get("on")
        .and_then(Value::as_bool)
        .ok_or_else(|| RpcError::invalid_params("on must be true or false"))?;
    let author = crate::author::author(params)?;
    if conn.origin == Origin::Peer {
        return Err(crate::hub::presence::peer_unsupported());
    }
    let subs = conn.subs.lock().unwrap_or_else(|e| e.into_inner());
    if !subs.get(&s.id).is_some_and(|opts| !opts.remote) || !open(conn) {
        return Err(RpcError::invalid_params("attach to the session before _acpmux/typing"));
    }
    hub.presence.typing(&s.id, &conn.id, &Who::of(author.as_ref()), on)?;
    Ok(json!({}))
}

/// `_acpmux/markUnread {sessionId}` (cx-ncc.78): the person marks a chat unread; it stays so until
/// a client shows it again after hiding it (`hub/seen.rs`).
pub(super) fn mark_unread(hub: &Hub, params: &Value) -> Result<Value, RpcError> {
    hub.mark_unread(&*hub.resolve(session_key(params)?)?);
    Ok(json!({}))
}

/// The connection closed: every attachment it held ends with it.
pub(super) fn release_all(hub: &Hub, conn: &Conn) {
    let mut held = conn.subs.lock().unwrap_or_else(|e| e.into_inner());
    let subs: Vec<(String, SubOpts)> = held.drain().collect();
    hub.presence.close(&conn.id);
    drop(held);
    for (id, opts) in subs {
        conn.unbind_mailbox_receipt(&id);
        if let Ok(s) = hub.resolve(&id) {
            hub.attach_count(&s, -1, !opts.hidden);
        }
    }
}
