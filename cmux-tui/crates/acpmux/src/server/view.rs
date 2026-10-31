//! A connection's attachments and whether it shows each chat (cx-n8ou,
//! `hub/seen.rs`): `_acpmux/attach` with `visible: false` holds a chat
//! without showing it, `_acpmux/view` changes that, and detaching or
//! disconnecting lets go with the same visibility it held.
//!
//! Presence (`hub/presence.rs`): a visible attach is the owner viewing on this connection;
//! `_acpmux/view` and `_acpmux/typing` name their person in `_meta.acpmux.author`. A view with
//! an author changes only that person's presence: whether the chat counts as shown (`unread`)
//! stays the owner's, so a link that carries other people attaches with `visible: false` and
//! names each of them in `_acpmux/view`.

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
    let mut subs = conn.subs.lock().unwrap_or_else(|e| e.into_inner());
    match subs.insert(s.id.clone(), opts) {
        // A peer's chat of the same raw id counted nothing here: this attachment is new.
        None => hub.attach_count(s, 1, !hidden),
        Some(before) if before.remote => hub.attach_count(s, 1, !hidden),
        Some(before) if before.hidden != hidden => hub.set_visible(s, !hidden),
        Some(_) => {}
    }
    // The owner always gets in (`presence::admit`).
    if open(conn) {
        let _ = hub.presence.view(&s.id, &conn.id, &Who::of(None), !hidden);
    }
}

/// Whether presence may still change for `conn`; read under its subscriptions' lock, as every
/// presence change of a connection is made. The connection's end is marked before
/// `release_all` takes that lock, so a request still running then (an attach in flight) adds no
/// entry that nothing would remove. A peer daemon's link never makes an entry ([`a_link`]).
fn open(conn: &Conn) -> bool {
    !a_link(conn) && !*conn.ended.borrow()
}

/// Whether `conn` is another daemon's link, which stands for none of its clients
/// (`hub/presence.rs`): served as Peer, or, added with the dashboard token, served as Web but
/// named `acpmux-peer` in `initialize` (`peer.rs`). Any client may take that name; it only
/// keeps that client out of presence.
pub(super) fn a_link(conn: &Conn) -> bool {
    conn.origin == Origin::Peer || *conn.name.lock_or_recover() == crate::peer::CLIENT_NAME
}

/// Subscribe `conn` to a peer's chat `id` (`peer_forward.rs`), marked remote under the same lock
/// so this daemon's presence for that raw id never reaches it (`hub/presence.rs`); it counts no
/// attachment here. `opts` replaces the options (an attach); None keeps them (a prompt, load,
/// resume or fork). One raw id holds one subscription per connection: an attachment this
/// connection held to this daemon's own chat of that id ends first, as a detach would.
pub(super) fn subscribe_remote(hub: &Hub, conn: &Conn, id: &str, opts: Option<SubOpts>) {
    let mut subs = conn.subs.lock().unwrap_or_else(|e| e.into_inner());
    let before = subs.get(id).cloned();
    if let Some(local) = before.as_ref().filter(|b| !b.remote) {
        conn.unbind_mailbox_receipt(id);
        if let Ok(s) = hub.resolve(id) {
            hub.attach_count(&s, -1, !local.hidden);
        }
        hub.presence.leave(id, &conn.id);
        conn.message_notices.lock().unwrap_or_else(|e| e.into_inner()).forget(None, id);
    }
    let mut next = opts.or(before).unwrap_or_default();
    next.remote = true;
    subs.insert(id.to_owned(), next);
}

/// Subscribe `conn` to this daemon's chat `s` with default options, counting it attached when
/// that is new (`requests::attach`: a prompt, load, resume or fork here). A subscription to a
/// peer's chat of the same raw id becomes this one.
pub(super) fn subscribe_local(hub: &Hub, conn: &Conn, s: &crate::hub::Session) {
    let mut subs = conn.subs.lock().unwrap_or_else(|e| e.into_inner());
    match subs.get_mut(&s.id) {
        None => {
            subs.insert(s.id.clone(), SubOpts::default());
            hub.attach_count(s, 1, true);
        }
        Some(opts) if opts.remote => {
            opts.remote = false;
            hub.attach_count(s, 1, !opts.hidden);
            conn.message_notices
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .forget_others(None, &s.id);
        }
        Some(_) => {}
    }
}

/// `_acpmux/detach`.
pub(super) fn detach(hub: &Hub, conn: &Conn, s: &crate::hub::Session) {
    let mut subs = conn.subs.lock().unwrap_or_else(|e| e.into_inner());
    conn.message_notices.lock().unwrap_or_else(|e| e.into_inner()).forget(None, &s.id);
    if let Some(before) = subs.remove(&s.id) {
        conn.unbind_mailbox_receipt(&s.id);
        if !before.remote {
            hub.attach_count(s, -1, !before.hidden);
        }
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
    let author = crate::author::author(params)?;
    if author.is_some() && a_link(conn) {
        return Err(crate::hub::presence::peer_unsupported());
    }
    let mut subs = conn.subs.lock().unwrap_or_else(|e| e.into_inner());
    // A peer's chat of the same raw id is not this one: its visibility is the peer's to count.
    let sub = subs
        .get_mut(&s.id)
        .filter(|sub| !sub.remote)
        .ok_or_else(|| RpcError::invalid_params("attach to the session before _acpmux/view"))?;
    if open(conn) {
        hub.presence.view(&s.id, &conn.id, &Who::of(author.as_ref()), visible)?;
    }
    if author.is_none() && sub.hidden == visible {
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
    if a_link(conn) {
        return Err(crate::hub::presence::peer_unsupported());
    }
    let subs = conn.subs.lock().unwrap_or_else(|e| e.into_inner());
    if subs.get(&s.id).is_none_or(|opts| opts.remote) || !open(conn) {
        return Err(RpcError::invalid_params("attach to the session before _acpmux/typing"));
    }
    hub.presence.typing(&s.id, &conn.id, &Who::of(author.as_ref()), on)?;
    Ok(json!({}))
}

/// `_acpmux/markUnread {sessionId}` (cx-ncc.78): the person marks a chat unread; it stays so until
/// a client shows it again after hiding it (`hub/seen.rs`).
pub(super) fn mark_unread(hub: &Hub, params: &Value) -> Result<Value, RpcError> {
    hub.mark_unread_answered(&*hub.resolve(session_key(params)?)?)?;
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
        // A peer's chat counted no attachment here, whatever local chat shares its raw id.
        if !opts.remote
            && let Ok(s) = hub.resolve(&id)
        {
            hub.attach_count(&s, -1, !opts.hidden);
        }
    }
}
