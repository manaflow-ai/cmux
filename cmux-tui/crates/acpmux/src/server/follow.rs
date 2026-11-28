//! A connection attached to a chat keeps the chat's stream when the chat moves to a peer, and
//! when it comes back, with nothing for the client to do: the same bare `sessionId`, every
//! record once, in seq order.
//!
//! A move leaves two logs that share seqs. The source's bundle holds the log through seq M; the
//! source then logs its own `transfer_out` (M+1) and `transferred` (M+2) on the tombstone, and
//! the target goes on from M+1 too. The chat's stream is the target's, so for a connection that
//! follows the chat:
//!
//! - the source's records from `transfer_out` on are held (`Follow::held`). A move that is
//!   aborted (`transfer_aborted`) releases them, in order, as before. One that commits
//!   (`transferred`) to a peer whose link is up drops them: the connection is subscribed to the
//!   peer's copy instead (`view::subscribe_remote`), the link attaches the chat there, and the
//!   target's records past M are read from it (`_acpmux/events`) before any live one. A live
//!   record at or below the last one sent goes no second time (`Follow::cursor`).
//! - while the chat is the peer's, this daemon's own records of it (the tombstone's) are not
//!   the chat's and do not go out.
//! - when the chat comes back (this daemon's chat is no tombstone again), the first record it
//!   logs here returns the subscription (`view::subscribe_local`), and the records past the last
//!   one sent are read from this daemon's store, which the move brought (`stream_cursor.rs`).
//!   The peer's records of it after that are stale and dropped.
//!
//! A commit to a host that is no connected peer changes nothing: the held records and
//! `transferred` go out as before. A peer daemon's link never follows (it would send this
//! daemon's records back to their owner).

use super::fanout::{deliver_once, send_event};
use super::{Conn, Hub, Message, Ordering, Origin, StdMutex, json, method, view};
use crate::hub::{HubEvent, PeerRow, RemoteRef};
use crate::store::EventRecord;
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::time::Duration;

/// How long the hand-off waits for the peer: its attach of the chat, and each page of records.
const PEER_WAIT: Duration = Duration::from_secs(10);
/// Most records in one page read from the peer (`stream_cursor.rs` `PAGE_RECORDS`).
const PAGE_RECORDS: usize = 2000;

#[derive(Default)]
struct Follow {
    /// The chat is the peer's: its stream comes over the link.
    remote: bool,
    /// The seq of the last record of the peer's stream sent; 0 when none was (a chat first
    /// reached here through its tombstone).
    cursor: u64,
    /// The owner's records since its `transfer_out`, until the move commits or is aborted.
    held: Option<Vec<HubEvent>>,
    /// The peer's copy moved on (`transferred`): nothing more of its stream is the chat's.
    ended: bool,
    /// The subscription returned here and its records past `cursor` are not read yet.
    catch_up: bool,
}

/// The chats of one connection that moved, or are being moved.
#[derive(Default)]
pub(super) struct Follows {
    map: StdMutex<HashMap<String, Follow>>,
    /// Whether `map` ever held a chat: the live path of a connection with none takes no lock.
    any: AtomicBool,
}

enum Step {
    Send,
    Drop,
    /// The held records, then this one, as they would have gone.
    Release(Vec<HubEvent>),
    Follow(Arc<crate::peer::Peer>, u64),
    /// The chat is here again; `true` when this record is its own and goes after the hand-back.
    Local(bool),
    CatchUp,
    Deliver,
}

impl Follows {
    fn map(&self) -> std::sync::MutexGuard<'_, HashMap<String, Follow>> {
        self.map.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn any(&self) -> bool {
        self.any.load(Ordering::Relaxed)
    }

    /// Whether chat `id`'s stream comes from the peer it moved to.
    pub(super) fn following(&self, id: &str) -> bool {
        self.any() && self.map().get(id).is_some_and(|f| f.remote)
    }

    /// A request for chat `id` went to the peer it moved to: its stream is the peer's from here.
    pub(super) fn forwarded(&self, id: &str) {
        let mut map = self.map();
        let f = map.entry(id.to_owned()).or_default();
        // Not while a move's records are held: its commit decides (`step`).
        if f.held.is_none() {
            f.remote = true;
        }
        drop(map);
        self.any.store(true, Ordering::Relaxed);
    }

    pub(super) fn forget(&self, id: &str) {
        if self.any() {
            self.map().remove(id);
        }
    }

    /// The subscription to chat `id` returns to this daemon (`view::subscribe_local`): the seq
    /// its stream stands at, when records were sent from the peer's.
    pub(super) fn to_local(&self, id: &str) -> Option<u64> {
        if !self.any() {
            return None;
        }
        let mut map = self.map();
        let f = map.get_mut(id).filter(|f| f.remote)?;
        f.remote = false;
        f.ended = false;
        f.held = None;
        f.catch_up = f.cursor > 0;
        f.catch_up.then_some(f.cursor)
    }

    fn take_catch_up(&self, id: &str) -> bool {
        self.map().get_mut(id).is_some_and(|f| std::mem::take(&mut f.catch_up))
    }

    /// Whether a record of the peer's stream goes on: one past the last sent. Moves the cursor.
    fn advance(&self, id: &str, seq: u64) -> bool {
        match self.map().get_mut(id) {
            Some(f) if f.remote && !f.ended && seq > f.cursor => {
                f.cursor = seq;
                true
            }
            _ => false,
        }
    }

    fn step(&self, hub: &Hub, conn: &Conn, ev: &HubEvent) -> Step {
        let (id, rec) = (&ev.session_id, &ev.record);
        let local = ev.remote.is_none();
        let kind = if rec.dir == "mux" { rec.kind.as_str() } else { "" };
        // Read before this book's lock: `view::subscribe_local` takes them the other way round.
        let begins =
            local && kind == "transfer_out" && conn.sub_opts(id).is_some_and(|opts| !opts.remote);
        if !self.any() && !begins {
            return Step::Send;
        }
        let mut map = self.map();
        let Some(f) = map.get_mut(id) else {
            if begins {
                map.insert(
                    id.clone(),
                    Follow { held: Some(vec![ev.clone()]), ..Follow::default() },
                );
                self.any.store(true, Ordering::Relaxed);
                return Step::Drop;
            }
            return Step::Send;
        };
        if local && f.remote {
            // The tombstone's own record, or the first of the chat that came back.
            return if returned(hub, id) { Step::Local(true) } else { Step::Drop };
        }
        if !local && (!f.remote || f.ended || rec.seq <= f.cursor) {
            // The peer's record of a chat that is here, or one already sent.
            return Step::Drop;
        }
        if f.held.is_some() {
            return match kind {
                "transfer_aborted" => {
                    if !local {
                        f.cursor = rec.seq;
                    }
                    Step::Release(f.held.take().unwrap_or_default())
                }
                "transferred" if local => {
                    let held = f.held.take().unwrap_or_default();
                    let after = held.first().map_or(rec.seq, |e| e.record.seq).saturating_sub(1);
                    match hub.moved_forward(id) {
                        Some((peer, there, _)) if there == *id => {
                            f.remote = true;
                            f.ended = false;
                            f.cursor = after;
                            Step::Follow(peer, after)
                        }
                        _ => {
                            map.remove(id);
                            Step::Release(held)
                        }
                    }
                }
                "transferred" => {
                    f.held = None;
                    f.ended = true;
                    if returned(hub, id) { Step::Local(false) } else { Step::Drop }
                }
                _ => {
                    if let Some(held) = f.held.as_mut() {
                        held.push(ev.clone());
                    }
                    Step::Drop
                }
            };
        }
        if kind == "transfer_out" {
            f.held = Some(vec![ev.clone()]);
            return Step::Drop;
        }
        if local {
            return if std::mem::take(&mut f.catch_up) { Step::CatchUp } else { Step::Send };
        }
        f.cursor = rec.seq;
        Step::Deliver
    }
}

/// Whether chat `id` is this daemon's own again: here, no tombstone of a move, and not a copy
/// still being received (its move's source has not let go: `transfer_out::IMPORTING`).
fn returned(hub: &Hub, id: &str) -> bool {
    hub.resolve(id).is_ok_and(|s| s.moving().is_none() && s.read_meta(|m| m.moved_to.is_none()))
}

/// One hub event for `conn`, as the fan-out sends it (`fanout::send_event`), with a chat that
/// moves followed (module doc).
pub(super) async fn event(hub: &Arc<Hub>, conn: &Arc<Conn>, ev: HubEvent) {
    // Only a chat's logged records are its stream; a peer daemon's link never follows.
    if ev.record.seq == 0 || ev.record.dir == "peer" || conn.origin == Origin::Peer {
        return send_event(hub, conn, ev);
    }
    let send = |ev: HubEvent| {
        if ev.remote.is_some() { deliver_once(hub, conn, ev) } else { send_event(hub, conn, ev) }
    };
    match conn.follows.step(hub, conn, &ev) {
        Step::Send => send_event(hub, conn, ev),
        Step::Deliver => deliver_once(hub, conn, ev),
        Step::Drop => {}
        Step::Release(held) => {
            held.into_iter().for_each(send);
            send(ev);
        }
        Step::Follow(peer, after) => {
            tell_moved(hub, conn, &ev, after);
            follow(hub, conn, &ev.session_id, &peer, after).await;
        }
        Step::Local(own) => {
            hand_back(hub, conn, &ev.session_id).await;
            if own {
                send_event(hub, conn, ev);
            }
        }
        Step::CatchUp => {
            super::stream_cursor::catch_up(hub, conn, deliver_once).await;
            send_event(hub, conn, ev);
        }
    }
}

/// A watcher that is attached hears the row change of the commit it does not hear as a record:
/// the row's `movedTo`.
fn tell_moved(hub: &Hub, conn: &Conn, ev: &HubEvent, after: u64) {
    if !conn.watch_all.load(Ordering::SeqCst) {
        return;
    }
    let Ok(s) = hub.resolve(&ev.session_id) else { return };
    conn.send(&Message::notification(
        method::MUX_SESSION_CHANGED,
        json!({"sessionId": ev.session_id, "session": hub.session_summary(&s), "kind": "transferred", "recordKind": "transferred", "seq": after, "listSeq": ev.list_seq}),
    ));
}

/// The chat moved to `peer`: `conn`'s subscription becomes one to the copy there, and the
/// records that copy holds past `after` go out before any live one.
async fn follow(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    id: &str,
    peer: &Arc<crate::peer::Peer>,
    after: u64,
) {
    if conn.sub_opts(id).is_none() {
        conn.follows.forget(id);
        return;
    }
    view::subscribe_remote(hub, conn, id, &peer.name, None);
    // The link streams a chat it attached (`peer_forward.rs`); first, so a record the page
    // below does not hold comes live.
    if peer.mark_attached(id)
        && !matches!(tokio::time::timeout(PEER_WAIT, peer.attach_hidden(id)).await, Ok(Ok(_)))
    {
        tracing::warn!(peer = %peer.name, session = %id, "a chat that moved was not attached on its peer in time: its stream resumes with its next attach");
    }
    let mut cursor = after;
    loop {
        let ask = json!({"sessionId": id, "afterSeq": cursor, "limit": PAGE_RECORDS});
        let page = match tokio::time::timeout(PEER_WAIT, peer.request(method::MUX_EVENTS, ask))
            .await
        {
            Ok(Ok(page)) => page,
            Ok(Err(e)) => {
                tracing::warn!(peer = %peer.name, session = %id, "a chat that moved: its records past {cursor} were not read from its peer: {}", e.message);
                return;
            }
            Err(_) => {
                tracing::warn!(peer = %peer.name, session = %id, "a chat that moved: its peer did not answer for its records past {cursor}");
                return;
            }
        };
        let events = page.get("events").and_then(Value::as_array).cloned().unwrap_or_default();
        let mut read = 0;
        for mut event in events {
            let seq = event.get("seq").and_then(Value::as_u64).unwrap_or(0);
            if seq <= cursor {
                continue;
            }
            (cursor, read) = (seq, read + 1);
            // A live record the link brought meanwhile was sent: not again.
            if !conn.follows.advance(id, seq) {
                continue;
            }
            let text = |event: &Value, key: &str| {
                event.get(key).and_then(Value::as_str).unwrap_or("").to_owned()
            };
            let record = EventRecord {
                seq,
                at: event.get("at").and_then(Value::as_u64).unwrap_or(0),
                dir: text(&event, "dir"),
                kind: text(&event, "kind"),
                msg: event.get_mut("msg").map(Value::take).unwrap_or(Value::Null),
                host_seq: None,
            };
            deliver_once(
                hub,
                conn,
                HubEvent {
                    session_id: id.to_owned(),
                    record: Arc::new(record),
                    remote: Some(RemoteRef {
                        peer: peer.name.clone(),
                        summary: PeerRow::new(&json!({"sessionId": id})),
                    }),
                    update_line: Default::default(),
                    event_params: Default::default(),
                    row: Default::default(),
                    list_seq: 0,
                    peer_batch: false,
                },
            );
        }
        if read == 0 || page.get("hasMore").and_then(Value::as_bool) != Some(true) {
            return;
        }
    }
}

/// The chat is this daemon's again: `conn`'s subscription returns to it, and its records past
/// the last one sent are read from the store here.
async fn hand_back(hub: &Arc<Hub>, conn: &Arc<Conn>, id: &str) {
    match (conn.sub_opts(id), hub.resolve(id)) {
        (Some(opts), Ok(s)) => {
            if opts.remote {
                view::subscribe_local(hub, conn, &s);
            }
            if conn.follows.take_catch_up(id) {
                super::stream_cursor::catch_up(hub, conn, deliver_once).await;
            }
        }
        _ => conn.follows.forget(id),
    }
}
