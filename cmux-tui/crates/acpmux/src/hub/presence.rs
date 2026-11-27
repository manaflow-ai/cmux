//! Who has a chat open and who types in it (chat multiplayer, hq#4389 §5), in memory only.
//!
//! One unix link may carry several people (the host daemon admits each teammate by tailnet
//! login and names them in `_meta.acpmux.author`), so an entry is keyed by (connection, author
//! id) in each chat; a request with no author is the owner (`{id: "owner", name: <the host's
//! user>}`). An entry is made by a visible `_acpmux/attach` (the owner's), `_acpmux/view`
//! visible and `_acpmux/typing` on, and it goes when it neither views nor types, when its
//! connection detaches the chat, or when the connection closes.
//!
//! `_acpmux/presence {sessionId, participants: [{id, name, devices, viewing, typing}]}` goes to
//! every connection attached to the chat (`server/fanout.rs`) on every change, one participant
//! per person (`devices`: how many connections carry them), and `_acpmux/attach` answers it as
//! `presence`. The hub never sets `self`: the client knows which id is its own. None of it is a
//! log record, so it is never in `_acpmux/events`, an export or a restart.
//!
//! Only this daemon's own chats have presence. A peer daemon's link is one connection that
//! carries all of that daemon's clients, so it can stand for none of them: it makes no entry
//! (its attach and view still count for `unread`), its `_acpmux/typing` and authored
//! `_acpmux/view` are refused `presence.peer_unsupported`, it hears no `_acpmux/presence`, and a
//! chat that lives on a peer answers its attach with no participants (`server/peer_forward.rs`).
//!
//! Bounds: [`MAX_PEOPLE`] people besides the owner in one chat (a new one past it is refused
//! `presence.full`); `_acpmux/typing` at most [`TYPING_PER_SECOND`] calls a second per connection
//! (`typing.rate_limited`). Timers: an `on` expires after [`TYPING_EXPIRY`]. Each (connection,
//! author, chat) holds at most one expiry task; it is aborted by an `off`, by a newer `on` (which
//! starts the next one), and by the entry's removal (detach, connection close), and otherwise
//! ends when it fires.
//!
//! Rooms (RFD 0141 phase 2, "Transport"): `_acpmux/rooms {chats, workspaces}` names every room a
//! client shows now (the open chat, the visible workspace rows, the Live menu's) and replaces the
//! set it named before; an empty set unsubscribes. A newly watched room answers one
//! `_acpmux/room {room, snapshot: true, presence}` with its `cmux-presence` records, then one
//! `_acpmux/room {room, presence, deltas, left}` per change: `presence` the records that joined,
//! `deltas` a [`Delta`] for each record that stayed (an empty one renews its lease at the new
//! epoch, so a subscriber's watermark never skips one), `left` the ids that went. A change is
//! one write and one fan-out to that room's subscribers ([`Sink`]s), whatever the number of
//! rooms or presences elsewhere. A chat room needs the connection attached to the chat (its
//! `_acpmux/presence` goes to the same connections) and goes when it detaches; a peer link
//! watches none (`presence.peer_unsupported`). At most [`MAX_ROOMS`] rooms a connection
//! (`presence.rooms_full`).
//!
//! Follow (RFD 0141 phase 3): `_acpmux/follow {target}` sets who the caller (its author on its
//! connection) follows, `null` to stop. It is kept per (connection, author), so it holds while
//! that person moves between chats, and it rides the record's `following`: every chat the caller
//! shows hears it as one `Following` delta in `_acpmux/room` (never in `_acpmux/presence`, whose
//! participants stay as they were). The target must be live in some chat on this daemon
//! (`presence.follow_not_live`) and is never the caller (`presence.follow_self`). The connection
//! closing ends it; moving your own view ends it in the client, which sends `null`.

use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use cmux_presence::{Delta, Doing, Kind, Presence as Record, PresenceId};
use serde::Serialize;
use serde_json::{Value, json};
use tokio::sync::broadcast;
use tokio::task::AbortHandle;
use tokio::time::Instant;

use crate::no_panic::LockExt;
use crate::rpc::RpcError;

use crate::author::Author;

/// How long a typing `on` holds without another.
pub const TYPING_EXPIRY: Duration = Duration::from_millis(cmux_presence::TYPING_LEASE_MS as u64);
/// `_acpmux/typing` calls one connection may make in any one second.
pub const TYPING_PER_SECOND: usize = 2;
/// People besides the owner in one chat's presence.
/// Measured: every change sends the whole list (about 100 bytes a person, in one 4 KiB
/// replacement) to every attached connection: 32 people is about 100 KB per change.
pub const MAX_PEOPLE: usize = 32;
/// The id of a caller that names no author.
pub const OWNER_ID: &str = "owner";
/// `data.reason` of a typing call past the rate.
pub const RATE_LIMITED: &str = "typing.rate_limited";
/// `data.reason` of a new person past [`MAX_PEOPLE`].
pub const FULL: &str = "presence.full";
/// `data.reason` of a presence change over a peer daemon's link.
pub const PEER_UNSUPPORTED: &str = "presence.peer_unsupported";

/// Rooms one connection watches at once: an open chat, a sidebar's visible workspace rows and
/// the Live menu's fit well under it.
pub const MAX_ROOMS: usize = 512;
/// `data.reason` of an `_acpmux/rooms` past [`MAX_ROOMS`].
pub const ROOMS_FULL: &str = "presence.rooms_full";

/// `data.reason` of an `_acpmux/follow` whose target shows no chat on this daemon.
pub const FOLLOW_NOT_LIVE: &str = "presence.follow_not_live";
/// `data.reason` of an `_acpmux/follow` that names the caller.
pub const FOLLOW_SELF: &str = "presence.follow_self";

/// A room a client shows (RFD 0141 "Transport"): a chat, or a workspace row.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Room {
    Chat(String),
    Workspace(String),
}

impl Room {
    /// `{chat: id}` or `{workspace: id}`, as `_acpmux/room` names it.
    pub fn wire(&self) -> Value {
        match self {
            Room::Chat(id) => json!({"chat": id}),
            Room::Workspace(id) => json!({"workspace": id}),
        }
    }
}

/// Where one subscriber's `_acpmux/room` params go: its connection's outbound queue
/// (`server/view.rs`). Called under the presence lock, so subscribers hear the changes in the
/// order they happened; it only enqueues.
pub type Sink = Arc<dyn Fn(Value) + Send + Sync>;

/// The refusal for a presence change over a peer daemon's link.
pub fn peer_unsupported() -> RpcError {
    RpcError::new(
        -32000,
        "presence is kept for this daemon's own clients; a peer daemon's link carries none",
    )
    .with_data(json!({"reason": PEER_UNSUPPORTED}))
}

/// No participants: a chat on a peer daemon, whose presence this daemon does not carry.
pub fn none(chat: &str) -> Value {
    json!({"sessionId": chat, "participants": []})
}

/// Changes a slow connection may fall behind by before it catches up from snapshots.
const CHANGES_BUFFER: usize = 256;

/// Whom an entry is for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Who {
    pub id: String,
    pub name: String,
}

impl Who {
    /// The author a request named, or the owner.
    pub fn of(author: Option<&Author>) -> Who {
        match author {
            Some(a) => Who { id: a.id.clone(), name: a.name.clone() },
            None => Who { id: OWNER_ID.to_owned(), name: owner_name().to_owned() },
        }
    }
}

/// The host's user, as the owner's name.
pub(crate) fn owner_name() -> &'static str {
    static NAME: OnceLock<String> = OnceLock::new();
    NAME.get_or_init(|| {
        ["USER", "LOGNAME"]
            .iter()
            .filter_map(|key| std::env::var(key).ok())
            .map(|name| name.trim().chars().take(64).collect::<String>())
            .find(|name| !name.is_empty() && !name.chars().any(char::is_control))
            .unwrap_or_else(|| OWNER_ID.to_owned())
    })
}

/// (connection id, author id).
type Key = (String, String);

struct Entry {
    name: String,
    viewing: bool,
    typing: bool,
    /// A live pane's cutover for recap reads. This is memory-only and never appears in presence.
    cutover: Option<(u64, u64)>,
    /// The running typing expiry, and which `on` started it.
    expiry: Option<(AbortHandle, u64)>,
}

impl Entry {
    fn stop_expiry(&mut self) {
        if let Some((task, _)) = self.expiry.take() {
            task.abort();
        }
    }
}

impl Drop for Entry {
    fn drop(&mut self) {
        self.stop_expiry();
    }
}

#[derive(Default)]
struct State {
    chats: HashMap<String, BTreeMap<Key, Entry>>,
    /// Each connection's typing calls in the last second.
    typing_calls: HashMap<String, VecDeque<Instant>>,
    next_on: u64,
    next_cutover: u64,
    // A room snapshot uses one owner revision. Removing the final participant releases the room.
    next_revision: u64,
    revisions: HashMap<String, u64>,
    /// Each room's subscribers, by connection: what one change fans out to.
    rooms: HashMap<Room, HashMap<String, Sink>>,
    /// The rooms each connection watches, so a new set or a close drops only its own.
    watching: HashMap<String, HashSet<Room>>,
    /// Whom each (connection, author) follows (`_acpmux/follow`).
    follows: HashMap<Key, String>,
    /// Subscribers one change visited, all rooms together (the cost test reads it).
    #[cfg(test)]
    fanned: u64,
}

impl State {
    /// `conn` stops watching `room`; a room with no subscriber left goes.
    fn unwatch(&mut self, room: &Room, conn: &str) {
        if let Some(subs) = self.rooms.get_mut(room) {
            subs.remove(conn);
            if subs.is_empty() {
                self.rooms.remove(room);
            }
        }
    }

    /// The room as it is now, as `_acpmux/room` params.
    fn room_snapshot(&self, room: &Room) -> Value {
        let presence = match room {
            Room::Chat(chat) => self.chat_records(chat),
            // No source places presence in a workspace on this daemon yet: the room is empty
            // until one does (RFD 0141 phase 2's next step).
            Room::Workspace(_) => Vec::new(),
        };
        json!({"room": room.wire(), "snapshot": true, "presence": presence})
    }

    fn chat_records(&self, chat: &str) -> Vec<Record> {
        let Some(&epoch) = self.revisions.get(chat) else { return Vec::new() };
        self.participants(chat).iter().map(|p| p.record(chat, epoch)).collect()
    }

    /// One participant per person in `chat`, with whom each follows.
    fn participants(&self, chat: &str) -> Vec<Participant> {
        participants(self.chats.get(chat), &self.follows)
    }

    /// Whether `id` shows any chat on this daemon now.
    fn live(&self, id: &str) -> bool {
        self.chats.values().any(|entries| entries.keys().any(|(_, other)| other == id))
    }

    /// Sends `note()` to `room`'s subscribers only: one lookup when nobody watches it, then one
    /// send each. Nothing here reads another room.
    fn fan_out(&mut self, room: &Room, note: impl FnOnce() -> Value) {
        let Some(subs) = self.rooms.get(room) else { return };
        let note = note();
        for sink in subs.values() {
            sink(note.clone());
        }
        #[cfg(test)]
        {
            self.fanned += subs.len() as u64;
        }
    }
}

struct Inner {
    state: Mutex<State>,
    /// The owner's Live opt-in (`_acpmux/live`); off until set, and never kept past a restart.
    live: AtomicBool,
    changes: broadcast::Sender<Arc<Value>>,
}

/// The hub's presence (`Hub::presence`).
pub struct Presence {
    inner: Arc<Inner>,
}

impl Default for Presence {
    fn default() -> Self {
        Presence {
            inner: Arc::new(Inner {
                state: Mutex::new(State::default()),
                live: AtomicBool::new(false),
                changes: broadcast::channel(CHANGES_BUFFER).0,
            }),
        }
    }
}

impl Presence {
    /// Every change, as `_acpmux/presence` params.
    pub fn subscribe(&self) -> broadcast::Receiver<Arc<Value>> {
        self.inner.changes.subscribe()
    }

    /// The chat's presence now, as `_acpmux/presence` params.
    pub fn snapshot(&self, chat: &str) -> Value {
        let state = self.inner.state.lock_or_recover();
        note(chat, &state.participants(chat))
    }

    /// Local projection for a subscriber to this chat. The owner id is daemon-local.
    /// Multiple connections for one author produce one record, as in the attach response.
    pub fn records(&self, chat: &str) -> Vec<Record> {
        self.inner.state.lock_or_recover().chat_records(chat)
    }

    /// `_acpmux/rooms`: `conn` shows exactly `rooms` now (none: it unsubscribes). Each room it
    /// did not watch before hears its snapshot through `sink` at once, under the same lock as
    /// every later change, so no delta reaches it ahead of its base. Answers how many rooms it
    /// watches. The caller checks a chat room's attachment (`server/view.rs`).
    pub fn rooms(&self, conn: &str, sink: Sink, rooms: Vec<Room>) -> Result<usize, RpcError> {
        let wanted: HashSet<Room> = rooms.into_iter().collect();
        if wanted.len() > MAX_ROOMS {
            return Err(RpcError::new(-32000, "a connection watches at most 512 rooms")
                .with_data(json!({"reason": ROOMS_FULL, "max": MAX_ROOMS})));
        }
        let mut state = self.inner.state.lock_or_recover();
        let before = state.watching.remove(conn).unwrap_or_default();
        for room in before.difference(&wanted) {
            state.unwatch(room, conn);
        }
        for room in &wanted {
            let subs = state.rooms.entry(room.clone()).or_default();
            // A new sink replaces the old one; only a room new to this connection snapshots.
            if subs.insert(conn.to_owned(), sink.clone()).is_none() {
                sink(state.room_snapshot(room));
            }
        }
        let watched = wanted.len();
        if watched > 0 {
            state.watching.insert(conn.to_owned(), wanted);
        }
        Ok(watched)
    }

    /// `_acpmux/follow`: person `who` (an author id) on `conn` follows `target`, or stops
    /// (`None`). Every chat it shows hears the change as one delta, under one lock.
    pub fn follow(&self, conn: &str, who: &str, target: Option<&str>) -> Result<(), RpcError> {
        let mut state = self.inner.state.lock_or_recover();
        if let Some(target) = target {
            if target == who {
                return Err(RpcError::new(-32000, "you cannot follow yourself")
                    .with_data(json!({"reason": FOLLOW_SELF})));
            }
            if !state.live(target) {
                return Err(RpcError::new(-32000, format!("{target} shows no chat here now"))
                    .with_data(json!({"reason": FOLLOW_NOT_LIVE, "target": target})));
            }
        }
        let key = (conn.to_owned(), who.to_owned());
        let shown: Vec<String> = state
            .chats
            .iter()
            .filter(|(_, entries)| entries.contains_key(&key))
            .map(|(chat, _)| chat.clone())
            .collect();
        let before: Vec<Vec<Participant>> = shown.iter().map(|c| state.participants(c)).collect();
        match target {
            Some(target) => state.follows.insert(key, target.to_owned()),
            None => state.follows.remove(&key),
        };
        for (chat, before) in shown.iter().zip(before) {
            let after = state.participants(chat);
            self.inner.publish(&mut state, chat, before, after);
        }
        Ok(())
    }

    /// Whom `who` on `conn` follows (tests and the server's answer).
    pub fn following(&self, conn: &str, who: &str) -> Option<String> {
        let state = self.inner.state.lock_or_recover();
        state.follows.get(&(conn.to_owned(), who.to_owned())).cloned()
    }

    /// Whether `conn` watches `room` (tests and the server's checks).
    pub fn watches(&self, conn: &str, room: &Room) -> bool {
        let state = self.inner.state.lock_or_recover();
        state.watching.get(conn).is_some_and(|rooms| rooms.contains(room))
    }

    /// Whether the owner is Live (`_acpmux/live`).
    pub fn is_live(&self) -> bool {
        self.inner.live.load(Ordering::Acquire)
    }

    /// Turns the owner's Live on or off; the previous value.
    pub fn set_live(&self, live: bool) -> bool {
        self.inner.live.swap(live, Ordering::AcqRel)
    }

    /// `_acpmux/live_list`: one shared record per person across this daemon's chats, ordered by
    /// id. Empty while the owner is not Live. A person in several chats shows the chat where
    /// they type, else the one with the newest owner epoch.
    pub fn live_list(&self) -> Vec<Record> {
        if !self.is_live() {
            return Vec::new();
        }
        let scope =
            cmux_presence::Sharing { live: true, private_chat: false, share_agent_files: false };
        let state = self.inner.state.lock_or_recover();
        let mut people: BTreeMap<String, Record> = BTreeMap::new();
        for (chat, entries) in &state.chats {
            let Some(&epoch) = state.revisions.get(chat) else { continue };
            for person in participants(Some(entries), &state.follows) {
                let record = person.record(chat, epoch);
                let better = |old: &Record| {
                    (record.doing == Doing::Typing, record.epoch)
                        > (old.doing == Doing::Typing, old.epoch)
                };
                match people.get(&*record.id.0) {
                    Some(old) if !better(old) => {}
                    _ => {
                        people.insert(record.id.0.to_string(), record);
                    }
                }
            }
        }
        people.into_values().filter_map(|r| r.shared(scope)).collect()
    }

    /// `_acpmux/view` (and a visible attach): `who` on `conn` shows the chat or stops.
    pub fn view(&self, chat: &str, conn: &str, who: &Who, visible: bool) -> Result<(), RpcError> {
        self.view_with_cutover(chat, conn, who, visible, true, None)
    }

    /// Updates a view and its transient recap cutover atomically. The cutover is retained only
    /// while this entry is visible and attending, and never changes presence participants.
    pub fn view_with_cutover(
        &self,
        chat: &str,
        conn: &str,
        who: &Who,
        visible: bool,
        attending: bool,
        cutover: Option<u64>,
    ) -> Result<(), RpcError> {
        self.inner.change(chat, |state| {
            let key = (conn.to_owned(), who.id.clone());
            let entries = state.chats.entry(chat.to_owned()).or_default();
            if visible {
                admit(entries, &key)?;
                let entry = entries.entry(key).or_insert_with(|| fresh(who));
                entry.name.clone_from(&who.name);
                entry.viewing = true;
                entry.cutover = cutover.filter(|_| attending).map(|seq| {
                    state.next_cutover = state.next_cutover.wrapping_add(1);
                    (state.next_cutover, seq)
                });
            } else if let Some(entry) = entries.get_mut(&key) {
                entry.viewing = false;
                entry.cutover = None;
                if !entry.typing {
                    entries.remove(&key);
                }
            }
            Ok(())
        })
    }

    /// The newest active cutover for a reader across its visible connections.
    pub fn active_cutover(&self, chat: &str, reader: &str) -> Option<u64> {
        let state = self.inner.state.lock_or_recover();
        state
            .chats
            .get(chat)?
            .iter()
            .filter(|((_, id), entry)| id.as_str() == reader && entry.viewing)
            .filter_map(|(_, entry)| entry.cutover)
            .max_by_key(|(order, _)| *order)
            .map(|(_, seq)| seq)
    }

    /// `_acpmux/typing`: `who` on `conn` starts or stops typing.
    pub fn typing(&self, chat: &str, conn: &str, who: &Who, on: bool) -> Result<(), RpcError> {
        let weak = Arc::downgrade(&self.inner);
        self.inner.change(chat, |state| {
            let now = Instant::now();
            let calls = state.typing_calls.entry(conn.to_owned()).or_default();
            while calls.front().is_some_and(|at| now.duration_since(*at) >= Duration::from_secs(1))
            {
                calls.pop_front();
            }
            if calls.len() >= TYPING_PER_SECOND {
                return Err(RpcError::new(
                    -32000,
                    "typing is limited to 2 calls a second per connection",
                )
                .with_data(json!({"reason": RATE_LIMITED, "retryable": true})));
            }
            calls.push_back(now);
            let key = (conn.to_owned(), who.id.clone());
            let entries = state.chats.entry(chat.to_owned()).or_default();
            if on {
                admit(entries, &key)?;
                state.next_on += 1;
                let generation = state.next_on;
                let entry = entries.entry(key.clone()).or_insert_with(|| fresh(who));
                entry.name.clone_from(&who.name);
                entry.typing = true;
                entry.stop_expiry();
                let chat = chat.to_owned();
                let task = tokio::spawn(async move {
                    tokio::time::sleep(TYPING_EXPIRY).await;
                    if let Some(inner) = weak.upgrade() {
                        inner.expire(&chat, &key, generation);
                    }
                });
                entry.expiry = Some((task.abort_handle(), generation));
            } else if let Some(entry) = entries.get_mut(&key) {
                entry.typing = false;
                entry.stop_expiry();
                if !entry.viewing {
                    entries.remove(&key);
                }
            }
            Ok(())
        })
    }

    /// `conn` detached `chat`: its entries there go.
    pub fn leave(&self, chat: &str, conn: &str) {
        let _ = self.inner.change(chat, |state| {
            if let Some(entries) = state.chats.get_mut(chat) {
                entries.retain(|(c, _), _| c != conn);
            }
            // Its chat room goes with the attachment: before this change fans out.
            let room = Room::Chat(chat.to_owned());
            if state.watching.get_mut(conn).is_some_and(|rooms| rooms.remove(&room)) {
                state.unwatch(&room, conn);
                if state.watching.get(conn).is_some_and(HashSet::is_empty) {
                    state.watching.remove(conn);
                }
            }
            Ok(())
        });
    }

    /// `conn` closed: its entries in every chat go, and its typing allowance.
    pub fn close(&self, conn: &str) {
        // Its follows end first, as deltas, so a person still on another connection drops it.
        let followers: Vec<String> = {
            let state = self.inner.state.lock_or_recover();
            state.follows.keys().filter(|(c, _)| c == conn).map(|(_, id)| id.clone()).collect()
        };
        for who in followers {
            let _ = self.follow(conn, &who, None);
        }
        let chats: Vec<String> = {
            let mut state = self.inner.state.lock_or_recover();
            state.typing_calls.remove(conn);
            for room in state.watching.remove(conn).unwrap_or_default() {
                state.unwatch(&room, conn);
            }
            state
                .chats
                .iter()
                .filter(|(_, entries)| entries.keys().any(|(c, _)| c == conn))
                .map(|(chat, _)| chat.clone())
                .collect()
        };
        for chat in chats {
            self.leave(&chat, conn);
        }
    }
}

impl Inner {
    /// Apply `f` to the state; broadcast the chat's presence when its participants changed.
    fn change(
        &self,
        chat: &str,
        f: impl FnOnce(&mut State) -> Result<(), RpcError>,
    ) -> Result<(), RpcError> {
        let mut state = self.state.lock_or_recover();
        let before = state.participants(chat);
        let result = f(&mut state);
        if state.chats.get(chat).is_some_and(BTreeMap::is_empty) {
            state.chats.remove(chat);
        }
        let after = state.participants(chat);
        self.publish(&mut state, chat, before, after);
        result
    }

    /// Fans out one change of `chat` from `before` to `after`, if any: its room's delta and, when
    /// the `_acpmux/presence` view changed, its participants.
    fn publish(
        &self,
        state: &mut State,
        chat: &str,
        before: Vec<Participant>,
        after: Vec<Participant>,
    ) {
        if before != after {
            let base = state.revisions.get(chat).copied();
            state.next_revision += 1;
            let revision = state.next_revision;
            state.fan_out(&Room::Chat(chat.to_owned()), || {
                room_change(chat, base, revision, &before, &after)
            });
            if after.is_empty() {
                state.revisions.remove(chat);
            } else {
                state.revisions.insert(chat.to_owned(), revision);
            }
            // Under the lock, so every connection hears the changes in the order they happened.
            // A follow alone leaves `_acpmux/presence` as it was: it is a room delta only.
            if !before.iter().map(Participant::shown).eq(after.iter().map(Participant::shown)) {
                let _ =
                    self.changes.send(Arc::new(json!({"sessionId": chat, "participants": after})));
            }
        }
    }

    /// The typing expiry fired: the `on` that started it ends, unless a newer one replaced it.
    fn expire(&self, chat: &str, key: &Key, generation: u64) {
        let _ = self.change(chat, |state| {
            let Some(entries) = state.chats.get_mut(chat) else { return Ok(()) };
            let Some(entry) = entries.get_mut(key) else { return Ok(()) };
            if entry.expiry.as_ref().map(|(_, g)| *g) != Some(generation) {
                return Ok(());
            }
            // This task is the one ending: nothing to abort.
            entry.expiry = None;
            entry.typing = false;
            if !entry.viewing {
                entries.remove(key);
            }
            Ok(())
        });
    }
}

fn fresh(who: &Who) -> Entry {
    Entry { name: who.name.clone(), viewing: false, typing: false, cutover: None, expiry: None }
}

/// Refuses a new person past [`MAX_PEOPLE`]; one already in, and the owner, always pass.
fn admit(entries: &BTreeMap<Key, Entry>, key: &Key) -> Result<(), RpcError> {
    let id = key.1.as_str();
    if id == OWNER_ID || entries.keys().any(|(_, other)| other == id) {
        return Ok(());
    }
    let mut people: Vec<&str> =
        entries.keys().map(|(_, other)| other.as_str()).filter(|o| *o != OWNER_ID).collect();
    people.sort_unstable();
    people.dedup();
    if people.len() >= MAX_PEOPLE {
        return Err(RpcError::new(-32000, "this chat already shows 32 people")
            .with_data(json!({"reason": FULL, "max": MAX_PEOPLE})));
    }
    Ok(())
}

#[derive(Serialize, PartialEq, Eq)]
struct Participant {
    id: String,
    name: String,
    devices: u64,
    viewing: bool,
    typing: bool,
    /// Whom this person follows (RFD 0141 phase 3): on the room record, not `_acpmux/presence`.
    #[serde(skip)]
    following: Option<String>,
}

impl Participant {
    /// What `_acpmux/presence` shows of it.
    fn shown(&self) -> (&str, &str, u64, bool, bool) {
        (&self.id, &self.name, self.devices, self.viewing, self.typing)
    }

    fn record(&self, chat: &str, epoch: u64) -> Record {
        let mut record = Record::new(
            PresenceId(self.id.as_str().into()),
            Kind::Person,
            self.name.as_str(),
            epoch,
        );
        record.location.chat = Some(chat.into());
        if self.typing {
            record.doing = Doing::Typing;
            record.lease_ms = cmux_presence::TYPING_LEASE_MS;
        }
        record.following = self.following.as_deref().map(|id| PresenceId(id.into()));
        record
    }
}

/// One participant per person, by id. A person on several connections follows whom the first
/// of them (by connection id) that follows anyone does.
fn participants(
    entries: Option<&BTreeMap<Key, Entry>>,
    follows: &HashMap<Key, String>,
) -> Vec<Participant> {
    let mut people: BTreeMap<&str, (&str, u64, bool, bool, Option<&str>)> = BTreeMap::new();
    for (key, entry) in entries.into_iter().flatten() {
        let person = people.entry(&key.1).or_insert((&entry.name, 0, false, false, None));
        person.1 += 1;
        person.2 |= entry.viewing;
        person.3 |= entry.typing;
        if person.4.is_none() {
            person.4 = follows.get(key).map(String::as_str);
        }
    }
    people
        .into_iter()
        .map(|(id, (name, devices, viewing, typing, following))| Participant {
            id: id.to_owned(),
            name: name.to_owned(),
            devices,
            viewing,
            typing,
            following: following.map(str::to_owned),
        })
        .collect()
}

/// One change of a chat room, as `_acpmux/room` params: the records that joined at `epoch`, a
/// delta from `base` for each that stayed, and the ids that left. `base` None: the room was
/// empty, so everyone joined.
fn room_change(
    chat: &str,
    base: Option<u64>,
    epoch: u64,
    before: &[Participant],
    after: &[Participant],
) -> Value {
    let old: HashMap<&str, &Participant> = before.iter().map(|p| (p.id.as_str(), p)).collect();
    let mut joined = Vec::new();
    let mut deltas = Vec::new();
    for person in after {
        let record = person.record(chat, epoch);
        match (old.get(person.id.as_str()), base) {
            (Some(was), Some(base)) => {
                deltas.extend(Delta::between(&was.record(chat, base), &record));
            }
            _ => joined.push(record),
        }
    }
    let now: HashSet<&str> = after.iter().map(|p| p.id.as_str()).collect();
    let left: Vec<&str> =
        before.iter().map(|p| p.id.as_str()).filter(|id| !now.contains(id)).collect();
    json!({
        "room": Room::Chat(chat.to_owned()).wire(),
        "presence": joined,
        "deltas": deltas,
        "left": left,
    })
}

fn note(chat: &str, participants: &[Participant]) -> Value {
    json!({"sessionId": chat, "participants": participants})
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ana() -> Who {
        Who { id: "tailnet:ana".to_owned(), name: "Ana".to_owned() }
    }

    fn typing(presence: &Presence) -> Option<bool> {
        let note = presence.snapshot("c");
        note["participants"].as_array()?.first().map(|p| p["typing"] == true)
    }

    /// A newer `on` restarts the 8 s and the older timer ends without effect; an `off` and a close
    /// end it at once. (The 8 s expiry itself: `tests/hub_integration/presence.rs`.)
    #[tokio::test(start_paused = true)]
    async fn a_newer_on_restarts_the_expiry_and_off_or_close_ends_it() {
        let presence = Presence::default();
        presence.typing("c", "conn", &ana(), true).unwrap();
        tokio::time::sleep(Duration::from_secs(5)).await;
        presence.typing("c", "conn", &ana(), true).unwrap();
        tokio::time::sleep(Duration::from_secs(5)).await;
        assert_eq!(typing(&presence), Some(true), "the first timer ended the newer on");
        tokio::time::sleep(Duration::from_millis(3001)).await;
        assert_eq!(typing(&presence), None);

        presence.typing("c", "conn", &ana(), true).unwrap();
        presence.typing("c", "conn", &ana(), false).unwrap();
        assert_eq!(typing(&presence), None);
        presence.typing("c", "other", &ana(), true).unwrap();
        presence.close("other");
        assert_eq!(presence.snapshot("c")["participants"], json!([]));
    }

    #[tokio::test(start_paused = true)]
    async fn records_follow_the_aggregated_chat_and_its_owner_revision() {
        let hub = Presence::default();
        let who = ana();
        hub.view("chat", "a", &who, true).unwrap();
        let first = hub.records("chat").pop().unwrap();
        assert_eq!(first.id.0.as_ref(), who.id);
        assert_eq!(first.location.chat.as_deref(), Some("chat"));
        hub.typing("chat", "b", &who, true).unwrap();
        let typing = hub.records("chat");
        assert_eq!(typing.len(), 1);
        assert!(typing[0].epoch > first.epoch);
        assert_eq!(typing[0].doing, Doing::Typing);
        assert_eq!(typing[0].lease_ms, cmux_presence::TYPING_LEASE_MS);
        assert_eq!(
            hub.snapshot("chat")["participants"],
            json!([
                {"id":who.id, "name":who.name, "devices":2, "viewing":true, "typing":true}
            ])
        );
        hub.close("b");
        let idle = hub.records("chat").pop().unwrap();
        assert_eq!(idle.doing, Doing::Idle);
        assert!(idle.epoch > typing[0].epoch);
        hub.close("a");
        assert!(hub.records("chat").is_empty());
        hub.view("chat", "a", &who, true).unwrap();
        assert!(hub.records("chat")[0].epoch > idle.epoch);
    }

    #[test]
    fn a_cutover_is_transient_per_reader_and_connection() {
        let presence = Presence::default();
        let alice = ana();
        let bob = Who { id: "tailnet:bob".into(), name: "Bob".into() };
        presence.view_with_cutover("c", "conn-a", &alice, true, true, Some(2)).unwrap();
        presence.view_with_cutover("c", "conn-b", &bob, true, true, Some(3)).unwrap();
        assert_eq!(presence.active_cutover("c", "tailnet:ana"), Some(2));
        assert_eq!(presence.active_cutover("c", "tailnet:bob"), Some(3));
        presence.view_with_cutover("c", "conn-a", &alice, true, false, Some(4)).unwrap();
        assert_eq!(presence.active_cutover("c", "tailnet:ana"), None);
        assert_eq!(presence.active_cutover("c", "tailnet:bob"), Some(3));
        presence.leave("c", "conn-b");
        assert_eq!(presence.active_cutover("c", "tailnet:bob"), None);
    }

    #[tokio::test]
    async fn live_list_is_empty_until_live_and_merges_a_person_across_chats() {
        let presence = Presence::default();
        presence.view("a", "c1", &ana(), true).unwrap();
        presence.view("b", "c1", &ana(), true).unwrap();
        presence
            .view("b", "c2", &Who { id: "tailnet:bo".to_owned(), name: "Bo".to_owned() }, true)
            .unwrap();
        assert!(presence.live_list().is_empty(), "off by default");
        assert!(!presence.set_live(true));
        assert!(presence.is_live());
        let list = presence.live_list();
        let ids: Vec<&str> = list.iter().map(|r| &*r.id.0).collect();
        assert_eq!(ids, ["tailnet:ana", "tailnet:bo"]);
        presence.typing("a", "c1", &ana(), true).unwrap();
        let list = presence.live_list();
        assert_eq!(list[0].location.chat.as_deref(), Some("a"), "the chat where they type");
        assert_eq!(list[0].doing, Doing::Typing);
        assert!(presence.set_live(false));
        assert!(presence.live_list().is_empty(), "off again clears the list");
    }

    #[tokio::test]
    async fn live_list_drops_people_who_left() {
        let presence = Presence::default();
        presence.set_live(true);
        presence.view("a", "c1", &ana(), true).unwrap();
        assert_eq!(presence.live_list().len(), 1);
        presence.close("c1");
        assert!(presence.live_list().is_empty());
    }

    /// A sink that keeps what it heard.
    fn heard() -> (Sink, Arc<Mutex<Vec<Value>>>) {
        let notes = Arc::new(Mutex::new(Vec::new()));
        let keep = notes.clone();
        (Arc::new(move |note| keep.lock_or_recover().push(note)), notes)
    }

    fn chat(id: &str) -> Room {
        Room::Chat(id.to_owned())
    }

    /// A change reaches the room's subscribers only, as one delta from the snapshot's epoch; a
    /// subscriber to another room, or to none, hears nothing of it.
    #[test]
    fn a_change_fans_out_to_that_rooms_subscribers_only() {
        let presence = Presence::default();
        let bob = Who { id: "tailnet:bob".into(), name: "Bob".into() };
        presence.view("c", "conn-a", &ana(), true).unwrap();
        let (watcher, watched) = heard();
        let (other, elsewhere) = heard();
        assert_eq!(presence.rooms("w", watcher, vec![chat("c")]).unwrap(), 1);
        assert_eq!(
            presence.rooms("o", other, vec![chat("d"), Room::Workspace("ws".into())]).unwrap(),
            2
        );

        let snapshot = watched.lock_or_recover()[0].clone();
        assert_eq!(snapshot["room"], json!({"chat": "c"}));
        assert_eq!(snapshot["snapshot"], true);
        let base = snapshot["presence"][0]["epoch"].as_u64().unwrap();
        assert_eq!(snapshot["presence"][0]["id"], "tailnet:ana");

        presence.view("c", "conn-b", &bob, true).unwrap();
        presence.view("c", "conn-a", &ana(), false).unwrap();
        let notes = watched.lock_or_recover().clone();
        assert_eq!(notes.len(), 3, "one note a change: {notes:?}");
        assert_eq!(notes[1]["presence"][0]["id"], "tailnet:bob", "bob joined: {}", notes[1]);
        assert_eq!(notes[1]["deltas"][0]["id"], "tailnet:ana");
        assert_eq!(notes[1]["deltas"][0]["base"], base, "the delta builds on the snapshot");
        assert_eq!(notes[2]["left"], json!(["tailnet:ana"]));
        assert_eq!(notes[2]["deltas"][0]["base"], notes[1]["deltas"][0]["epoch"]);

        let others = elsewhere.lock_or_recover().clone();
        assert_eq!(others.len(), 2, "only its own rooms' snapshots: {others:?}");
        assert!(others.iter().all(|n| n["snapshot"] == true));
    }

    /// An empty set unsubscribes, a smaller one drops only the rooms it left out, a detach drops
    /// that chat's room, and a close drops the rest.
    #[test]
    fn unsubscribe_stops_the_deltas() {
        let presence = Presence::default();
        let (sink, notes) = heard();
        presence.rooms("w", sink.clone(), vec![chat("c"), chat("d")]).unwrap();
        assert_eq!(notes.lock_or_recover().len(), 2);
        presence.rooms("w", sink.clone(), vec![chat("d")]).unwrap();
        assert_eq!(notes.lock_or_recover().len(), 2, "a room it already watched snapshots once");
        assert!(!presence.watches("w", &chat("c")));
        presence.view("c", "conn", &ana(), true).unwrap();
        assert_eq!(notes.lock_or_recover().len(), 2, "c is no longer watched");
        presence.view("d", "conn", &ana(), true).unwrap();
        assert_eq!(notes.lock_or_recover().len(), 3);

        assert_eq!(presence.rooms("w", sink.clone(), Vec::new()).unwrap(), 0);
        presence.view("d", "conn", &ana(), false).unwrap();
        assert_eq!(notes.lock_or_recover().len(), 3, "an empty set unsubscribes");
        assert!(presence.inner.state.lock_or_recover().rooms.is_empty(), "no empty room is kept");

        presence.rooms("w", sink.clone(), vec![chat("c"), chat("d")]).unwrap();
        presence.leave("c", "w");
        assert!(!presence.watches("w", &chat("c")), "a detach drops its chat room");
        assert!(presence.watches("w", &chat("d")));
        presence.close("w");
        assert!(!presence.watches("w", &chat("d")));
        let state = presence.inner.state.lock_or_recover();
        assert!(state.rooms.is_empty() && state.watching.is_empty());
    }

    #[test]
    fn a_set_past_the_bound_is_refused_and_keeps_the_old_one() {
        let presence = Presence::default();
        let (sink, _) = heard();
        presence.rooms("w", sink.clone(), vec![chat("c")]).unwrap();
        let many = (0..=MAX_ROOMS).map(|i| Room::Workspace(format!("ws{i}"))).collect();
        let refused = presence.rooms("w", sink, many).unwrap_err();
        assert_eq!(refused.data.as_ref().unwrap()["reason"], ROOMS_FULL);
        assert!(presence.watches("w", &chat("c")));
    }

    /// A follow reaches the follower's rooms as one `Following` delta, `_acpmux/presence` does
    /// not change, and `null` clears it the same way.
    #[test]
    fn a_follow_rides_the_room_deltas_and_null_clears_it() {
        let presence = Presence::default();
        let bob = Who { id: "tailnet:bob".into(), name: "Bob".into() };
        presence.view("c", "conn-a", &ana(), true).unwrap();
        presence.view("d", "conn-b", &bob, true).unwrap();
        let (sink, notes) = heard();
        presence.rooms("w", sink, vec![chat("c")]).unwrap();
        let mut changes = presence.subscribe();
        let before = presence.snapshot("c");

        presence.follow("conn-a", "tailnet:ana", Some("tailnet:bob")).unwrap();
        assert_eq!(presence.following("conn-a", "tailnet:ana").as_deref(), Some("tailnet:bob"));
        let follow = notes.lock_or_recover()[1].clone();
        assert_eq!(follow["deltas"][0]["id"], "tailnet:ana", "{follow}");
        assert_eq!(
            follow["deltas"][0]["changes"],
            json!([{"following": "tailnet:bob"}]),
            "{follow}"
        );
        assert_eq!(
            presence.records("c")[0].following.as_ref().map(|id| id.0.as_ref()),
            Some("tailnet:bob")
        );
        assert_eq!(presence.snapshot("c"), before, "_acpmux/presence is unchanged");
        assert!(changes.try_recv().is_err(), "a follow alone broadcasts no _acpmux/presence");

        // A chat the follower moves to carries it on its record.
        presence.view("e", "conn-a", &ana(), true).unwrap();
        assert!(presence.records("e")[0].following.is_some());

        presence.follow("conn-a", "tailnet:ana", None).unwrap();
        let cleared = notes.lock_or_recover()[2].clone();
        assert_eq!(cleared["deltas"][0]["changes"], json!([{"following": null}]), "{cleared}");
        assert!(presence.records("c")[0].following.is_none());
        assert_eq!(notes.lock_or_recover().len(), 3, "one note a follow change");
    }

    /// Following yourself and following someone who shows no chat here are refused, and
    /// change nothing.
    #[test]
    fn a_follow_of_yourself_or_of_nobody_live_is_refused() {
        let presence = Presence::default();
        presence.view("c", "conn-a", &ana(), true).unwrap();
        let own = presence.follow("conn-a", "tailnet:ana", Some("tailnet:ana")).unwrap_err();
        assert_eq!(own.data.as_ref().unwrap()["reason"], FOLLOW_SELF);
        let gone = presence.follow("conn-a", "tailnet:ana", Some("tailnet:zed")).unwrap_err();
        assert_eq!(gone.data.as_ref().unwrap()["reason"], FOLLOW_NOT_LIVE);
        assert_eq!(presence.following("conn-a", "tailnet:ana"), None);
        assert!(presence.records("c")[0].following.is_none());
    }

    /// Closing the follower's connection ends its follow as a delta, so the same person on
    /// another connection no longer shows it.
    #[test]
    fn closing_the_followers_connection_ends_the_follow() {
        let presence = Presence::default();
        let bob = Who { id: "tailnet:bob".into(), name: "Bob".into() };
        presence.view("c", "conn-a", &ana(), true).unwrap();
        presence.view("c", "conn-a2", &ana(), true).unwrap();
        presence.view("d", "conn-b", &bob, true).unwrap();
        presence.follow("conn-a", "tailnet:ana", Some("tailnet:bob")).unwrap();
        let (sink, notes) = heard();
        presence.rooms("w", sink, vec![chat("c")]).unwrap();
        presence.close("conn-a");
        assert_eq!(presence.following("conn-a", "tailnet:ana"), None);
        assert!(presence.records("c")[0].following.is_none());
        let heard = notes.lock_or_recover().clone();
        assert!(
            heard.iter().any(|n| n["deltas"][0]["changes"] == json!([{"following": null}])),
            "{heard:?}"
        );
        assert!(presence.inner.state.lock_or_recover().follows.is_empty());
    }

    /// The cost of one update is the room's subscribers, never the number of other rooms: the
    /// same change visits one subscriber beside 10 unrelated rooms and beside 10,000.
    #[test]
    fn cost_per_update_does_not_grow_with_unrelated_rooms() {
        let mut visited = Vec::new();
        for unrelated in [10, 10_000] {
            let presence = Presence::default();
            for i in 0..unrelated {
                let (sink, _) = heard();
                let conn = format!("u{i}");
                presence.view(&format!("other{i}"), &conn, &ana(), true).unwrap();
                presence
                    .rooms(
                        &conn,
                        sink,
                        vec![chat(&format!("other{i}")), Room::Workspace(format!("ws{i}"))],
                    )
                    .unwrap();
            }
            let (sink, notes) = heard();
            presence.rooms("w", sink, vec![chat("c")]).unwrap();
            let before = presence.inner.state.lock_or_recover().fanned;
            presence.view("c", "conn", &ana(), true).unwrap();
            presence.view("c", "conn", &ana(), false).unwrap();
            visited.push(presence.inner.state.lock_or_recover().fanned - before);
            assert_eq!(notes.lock_or_recover().len(), 3, "snapshot and two changes");
        }
        assert_eq!(visited, vec![2, 2], "subscribers visited for two changes");
    }
}
