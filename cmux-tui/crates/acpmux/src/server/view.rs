//! A connection's attachments and whether it shows each chat (cx-n8ou,
//! `hub/seen.rs`): `_acpmux/attach` with `visible: false` holds a chat
//! without showing it, `_acpmux/view` changes that, and detaching or
//! disconnecting lets go with the same visibility it held. `_acpmux/view`'s
//! `attending` says whether the person in front of a shown chat attends
//! (`hub/seen.rs` `Look`): an idle client lets go as a hidden one, after
//! its idle look is taken back.
//!
//! Presence (`hub/presence.rs`): a visible attach is the owner viewing on this connection;
//! `_acpmux/view` and `_acpmux/typing` name their person in `_meta.acpmux.author`. A view with
//! an author changes only that person's presence: whether the chat counts as shown (`unread`)
//! stays the owner's, so a link that carries other people attaches with `visible: false` and
//! names each of them in `_acpmux/view`.

use super::*;
use crate::hub::Look;
use crate::hub::presence::Who;

/// How `opts` holds its chat (`hub/seen.rs`).
fn look(opts: &SubOpts) -> Look {
    Look::of(opts.hidden, opts.idle)
}

/// An idle attachment about to end or change hands is turned hidden first, so the hidden count it
/// lets go with is the one it holds, and the idle count drops with it.
fn settle_idle(hub: &Hub, s: &crate::hub::Session, opts: &mut SubOpts) {
    if look(opts) == Look::Idle {
        hub.look_changed(s, Look::Idle, Look::Hidden, None);
        opts.hidden = true;
        opts.idle = false;
    }
}

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
    // A person's client shows it, here or through a peer's link (whose own subscriptions are
    // hidden, `peer_forward.rs`): it may get a session recap (`hub/away_recap.rs`).
    if !hidden {
        hub.recap_person_shows(s);
    }
    let after = look(&opts);
    // A new attachment counts as hidden first when its person is away, so it sees nothing.
    let count_new = |hub: &Hub| {
        hub.attach_count_from(s, 1, after == Look::Attending, a_person(conn));
        if after == Look::Idle {
            hub.look_changed(s, Look::Hidden, Look::Idle, None);
        }
    };
    let mut subs = conn.subs.lock().unwrap_or_else(|e| e.into_inner());
    // The client starts this chat over: its next chunk goes whole (`chunk_deltas.rs`).
    conn.chunk_deltas.forget(&s.id);
    conn.interest.attach(&s.id);
    // Its live stream starts after the chat's last record now; read under the subscriptions'
    // lock, so a lap's catch-up never reads from before it (`stream_cursor.rs`).
    conn.stream_cursors.start(&s.id, s.meta().last_seq);
    match subs.insert(s.id.clone(), opts) {
        // A peer's chat of the same raw id counted nothing here: this attachment is new.
        None => count_new(hub),
        Some(before) if before.remote => count_new(hub),
        // Attaching again starts the look over: an idle one that shows attends again.
        Some(before) => {
            hub.look_changed(s, look(&before), after, None);
        }
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

/// Whether `conn` is a person's client, whose showing a chat or letting go of it starts its idle
/// period again (`hub/seen.rs` `attach_count_from`): not another daemon's link ([`a_link`]) and
/// not an agent's CLI or tool, one that runs in an acpmux session (proven, named or declared,
/// `cli_caller.rs`). An agent reading a chat (`acpmux last`, `wait`, `tail`) is no use of it.
pub(super) fn a_person(conn: &Conn) -> bool {
    !a_link(conn)
        && conn.caller().is_none()
        && conn.unproven_caller.get().is_none()
        && !matches!(conn.declared(), Some(crate::cli_caller::Declared::Agent))
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
            let mut local = local.clone();
            settle_idle(hub, &s, &mut local);
            hub.attach_count_from(&s, -1, !local.hidden, a_person(conn));
        }
        hub.presence.leave(id, &conn.id);
        conn.message_notices.lock().unwrap_or_else(|e| e.into_inner()).forget(None, id);
        conn.stream_cursors.forget(id);
    }
    if opts.is_some() {
        conn.chunk_deltas.forget(id);
    }
    let mut next = opts.or(before).unwrap_or_default();
    next.remote = true;
    next.idle = false;
    conn.interest.attach(id);
    subs.insert(id.to_owned(), next);
}

/// Subscribe `conn` to this daemon's chat `s` with default options, counting it attached when
/// that is new (`requests::attach`: a prompt, load, resume or fork here). A subscription to a
/// peer's chat of the same raw id becomes this one.
pub(super) fn subscribe_local(hub: &Hub, conn: &Conn, s: &crate::hub::Session) {
    let mut subs = conn.subs.lock().unwrap_or_else(|e| e.into_inner());
    conn.interest.attach(&s.id);
    match subs.get_mut(&s.id) {
        None => {
            // A lap catches this ACP subscription up from here too (`stream_cursor.rs`); a
            // later prompt keeps the cursor where its stream stands.
            conn.stream_cursors.start(&s.id, s.meta().last_seq);
            subs.insert(s.id.clone(), SubOpts::default());
            hub.attach_count_from(s, 1, true, a_person(conn));
        }
        Some(opts) if opts.remote => {
            // A chat that came back from the peer it moved to goes on from the last record of
            // it sent (`follow.rs`), not from the log's end.
            let at = conn.follows.to_local(&s.id).unwrap_or_else(|| s.meta().last_seq);
            conn.stream_cursors.start(&s.id, at);
            opts.remote = false;
            hub.attach_count_from(s, 1, !opts.hidden, a_person(conn));
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
    conn.chunk_deltas.forget(&s.id);
    conn.stream_cursors.forget(&s.id);
    conn.follows.forget(&s.id);
    if let Some(mut before) = subs.remove(&s.id) {
        conn.interest.detach(&s.id);
        conn.unbind_mailbox_receipt(&s.id);
        if !before.remote {
            settle_idle(hub, s, &mut before);
            hub.attach_count_from(s, -1, !before.hidden, a_person(conn));
        }
    }
    hub.presence.leave(&s.id, &conn.id);
}

/// `_acpmux/view {sessionId, visible, attending?, seenSeq?, cutoverSeq?}`: whether this attached client shows
/// the chat, and whether its person attends it (default true: a client that never says counts as
/// watched, as before). `seenSeq` is the log seq the client had at its person's last input, where
/// a chat they stopped attending was left off (`hub/seen.rs`). `cutoverSeq` is a transient recap
/// pin for the visible, attending pane. Answers `{lastReturn}` when the person's return put
/// "New since you looked" on the chat.
pub(super) fn view(hub: &Hub, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    let s = hub.resolve(session_key(params)?)?;
    let visible = params
        .get("visible")
        .and_then(Value::as_bool)
        .ok_or_else(|| RpcError::invalid_params("visible must be true or false"))?;
    let attending = match params.get("attending") {
        None | Some(Value::Null) => true,
        Some(v) => v
            .as_bool()
            .ok_or_else(|| RpcError::invalid_params("attending must be true or false"))?,
    };
    let seen_through = match params.get("seenSeq") {
        None | Some(Value::Null) => None,
        Some(v) => {
            Some(v.as_u64().ok_or_else(|| RpcError::invalid_params("seenSeq must be a log seq"))?)
        }
    };
    let cutover = match params.get("cutoverSeq") {
        None | Some(Value::Null) => None,
        Some(v) => Some(
            v.as_u64().ok_or_else(|| RpcError::invalid_params("cutoverSeq must be a log seq"))?,
        ),
    };
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
        hub.presence.view_with_cutover(
            &s.id,
            &conn.id,
            &Who::of(author.as_ref()),
            visible,
            attending,
            cutover,
        )?;
    }
    if author.is_none() && visible {
        hub.recap_person_shows(&s);
    }
    let mut back = None;
    if author.is_none() {
        let before = look(sub);
        sub.hidden = !visible;
        sub.idle = visible && !attending;
        // Shown again after its stream was left out (`SubOpts::quiet_hidden`): one lag notice,
        // queued under this lock so it goes before any record the show lets through. It names the
        // cursor before the first record left out (`afterSeq`): the turn ends and status that
        // still went out moved the client's own cursor past it, and a read from there would skip
        // every chunk left out (direct.ts `lagCursor` reads from the older of the two).
        // Other chats' rows left out while every chat here was hidden (`Conn::leaves_out_row`) are
        // in the same notice, as `watch: true`: the page reads the list and its asks again.
        let rows = if visible { conn.rows_left_out.swap(0, Ordering::SeqCst) } else { 0 };
        if visible && (sub.left_out > 0 || rows > 0) {
            let stream = std::mem::take(&mut sub.left_out);
            let after_seq = std::mem::take(&mut sub.left_from);
            let mut notice = json!({"dropped": stream + rows, "reason": "hidden",
                "sessionIds": if stream > 0 { json!([s.id]) } else { json!([]) }});
            if stream > 0 {
                notice.set("afterSeq", json!(after_seq));
            }
            if rows > 0 {
                notice.set("watch", Value::Bool(true));
            }
            conn.send(&Message::notification("_acpmux/lagged", notice));
        }
        // Under the lock, so a detach racing this one counts the same look.
        back = hub.look_changed(&s, before, look(sub), seen_through);
    }
    Ok(match back {
        Some(back) => json!({"lastReturn": back}),
        None => json!({}),
    })
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

/// `_acpmux/follow {target}` (RFD 0141 phase 3): the caller's author (or the owner) follows the
/// person `target` live in a chat here, or stops (`null`). Its rooms hear it as the record's
/// `following` (`hub/presence.rs`). A peer daemon's link follows nobody.
pub(super) fn follow(hub: &Hub, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    let target = match params.get("target") {
        None | Some(Value::Null) => None,
        Some(Value::String(id)) if !id.is_empty() => Some(id.as_str()),
        Some(_) => return Err(RpcError::invalid_params("target must be a presence id or null")),
    };
    let author = crate::author::author(params)?;
    if a_link(conn) {
        return Err(crate::hub::presence::peer_unsupported());
    }
    let who = Who::of(author.as_ref());
    hub.presence.follow(&conn.id, &who.id, target)?;
    Ok(json!({"following": target}))
}

/// `_acpmux/rooms {chats?, workspaces?}` (RFD 0141 phase 2): the rooms this connection shows
/// now, replacing the set it named before (`hub/presence.rs`). Each chat must be attached here,
/// as for `_acpmux/typing`: a room shows who has the chat open, which only its attached
/// connections hear. A peer daemon's link watches none.
pub(super) fn rooms(hub: &Hub, conn: &Arc<Conn>, params: &Value) -> Result<Value, RpcError> {
    use crate::hub::presence::{Room, Sink};
    if a_link(conn) {
        return Err(crate::hub::presence::peer_unsupported());
    }
    let ids = |key: &str| -> Result<Vec<String>, RpcError> {
        match params.get(key) {
            None | Some(Value::Null) => Ok(Vec::new()),
            Some(Value::Array(ids)) => ids
                .iter()
                .map(|id| {
                    id.as_str()
                        .map(str::to_owned)
                        .ok_or_else(|| RpcError::invalid_params(format!("{key} must be strings")))
                })
                .collect(),
            Some(_) => Err(RpcError::invalid_params(format!("{key} must be a list of ids"))),
        }
    };
    let mut rooms = Vec::new();
    {
        let subs = conn.subs.lock().unwrap_or_else(|e| e.into_inner());
        for key in ids("chats")? {
            let id = hub.resolve(&key)?.id.clone();
            if subs.get(&id).is_none_or(|opts| opts.remote) || !open(conn) {
                return Err(RpcError::invalid_params(format!(
                    "attach to {key} before watching its room"
                )));
            }
            rooms.push(Room::Chat(id));
        }
    }
    rooms.extend(ids("workspaces")?.into_iter().map(Room::Workspace));
    let weak = Arc::downgrade(conn);
    let sink: Sink = Arc::new(move |note| {
        if let Some(conn) = weak.upgrade() {
            conn.send(&Message::notification(crate::rpc::method::MUX_ROOM, note));
        }
    });
    let watched = hub.presence.rooms(&conn.id, sink, rooms)?;
    Ok(json!({"rooms": watched}))
}

/// `_acpmux/markUnread {sessionId, readThrough?}` (cx-ncc.78): the person marks a chat unread; it
/// stays so until a client shows it again after hiding it (`hub/seen.rs`). With `readThrough`, the
/// person's seen cursor also moves back to it (never forward), so the rows after it are unseen.
pub(super) fn mark_unread(hub: &Hub, params: &Value) -> Result<Value, RpcError> {
    let s = hub.resolve(session_key(params)?)?;
    let back = match params.get("readThrough") {
        None | Some(Value::Null) => None,
        Some(v) => Some(
            v.as_u64().ok_or_else(|| RpcError::invalid_params("readThrough must be a log seq"))?,
        ),
    };
    if let Some(seq) = back {
        let author = crate::author::author(params)?;
        hub.mark_read_back(&s, crate::hub::reader_of(author.as_ref()), seq);
    }
    hub.mark_unread_answered(&s)?;
    Ok(json!({}))
}

/// `_acpmux/markRead {sessionId}`: the person marks a chat read without showing it (cmux's
/// `chat.mark_read`, an App Store app's Mark Read); answered once the mark is on disk.
pub(super) fn mark_read(hub: &Hub, params: &Value) -> Result<Value, RpcError> {
    hub.mark_read_answered(&*hub.resolve(session_key(params)?)?)?;
    Ok(json!({}))
}

/// `_acpmux/seen {sessionId, seq}`: the person (`_meta.acpmux.author`, the owner when none) had
/// the chat's rows through `seq` on screen while attending it. Moves their seen cursor forward
/// only, clamped to the chat's newest record (`hub/seen.rs` `mark_read_through`). Answers
/// `{readThrough}`, the cursor after. The only request that moves it forward.
pub(super) fn seen(hub: &Hub, params: &Value) -> Result<Value, RpcError> {
    let s = hub.resolve(session_key(params)?)?;
    let seq = params
        .get("seq")
        .and_then(Value::as_u64)
        .ok_or_else(|| RpcError::invalid_params("seq must be a log seq"))?;
    let author = crate::author::author(params)?;
    let through = hub.mark_read_through(&s, crate::hub::reader_of(author.as_ref()), seq);
    Ok(json!({"readThrough": through}))
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
            let mut opts = opts;
            settle_idle(hub, &s, &mut opts);
            hub.attach_count_from(&s, -1, !opts.hidden, a_person(conn));
        }
    }
}

#[cfg(test)]
#[path = "view_seen_tests.rs"]
mod seen_tests;
