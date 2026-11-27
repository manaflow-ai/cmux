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

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::sync::broadcast;
use tokio::task::AbortHandle;
use tokio::time::Instant;

use crate::no_panic::LockExt;
use crate::rpc::RpcError;

use crate::author::Author;

/// How long a typing `on` holds without another.
pub const TYPING_EXPIRY: Duration = Duration::from_secs(8);
/// `_acpmux/typing` calls one connection may make in any one second.
pub const TYPING_PER_SECOND: usize = 2;
/// People besides the owner in one chat's presence.
pub const MAX_PEOPLE: usize = 32;
/// The id of a caller that names no author.
pub const OWNER_ID: &str = "owner";
/// `data.reason` of a typing call past the rate.
pub const RATE_LIMITED: &str = "typing.rate_limited";
/// `data.reason` of a new person past [`MAX_PEOPLE`].
pub const FULL: &str = "presence.full";
/// `data.reason` of a presence change over a peer daemon's link.
pub const PEER_UNSUPPORTED: &str = "presence.peer_unsupported";

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
fn owner_name() -> &'static str {
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
}

struct Inner {
    state: Mutex<State>,
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
        note(chat, state.chats.get(chat))
    }

    /// `_acpmux/view` (and a visible attach): `who` on `conn` shows the chat or stops.
    pub fn view(&self, chat: &str, conn: &str, who: &Who, visible: bool) -> Result<(), RpcError> {
        self.inner.change(chat, |state| {
            let key = (conn.to_owned(), who.id.clone());
            let entries = state.chats.entry(chat.to_owned()).or_default();
            if visible {
                admit(entries, &key)?;
                let entry = entries.entry(key).or_insert_with(|| fresh(who));
                entry.name.clone_from(&who.name);
                entry.viewing = true;
            } else if let Some(entry) = entries.get_mut(&key) {
                entry.viewing = false;
                if !entry.typing {
                    entries.remove(&key);
                }
            }
            Ok(())
        })
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
            Ok(())
        });
    }

    /// `conn` closed: its entries in every chat go, and its typing allowance.
    pub fn close(&self, conn: &str) {
        let chats: Vec<String> = {
            let mut state = self.inner.state.lock_or_recover();
            state.typing_calls.remove(conn);
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
        let before = participants(state.chats.get(chat));
        let result = f(&mut state);
        if state.chats.get(chat).is_some_and(BTreeMap::is_empty) {
            state.chats.remove(chat);
        }
        let after = participants(state.chats.get(chat));
        if before != after {
            // Under the lock, so every connection hears the changes in the order they happened.
            let _ = self.changes.send(Arc::new(json!({"sessionId": chat, "participants": after})));
        }
        result
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
    Entry { name: who.name.clone(), viewing: false, typing: false, expiry: None }
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

/// One participant per person, by id.
fn participants(entries: Option<&BTreeMap<Key, Entry>>) -> Vec<Value> {
    let mut people: BTreeMap<&str, (&str, u64, bool, bool)> = BTreeMap::new();
    for ((_, id), entry) in entries.into_iter().flatten() {
        let person = people.entry(id).or_insert((&entry.name, 0, false, false));
        person.1 += 1;
        person.2 |= entry.viewing;
        person.3 |= entry.typing;
    }
    people
        .into_iter()
        .map(|(id, (name, devices, viewing, typing))| {
            json!({"id": id, "name": name, "devices": devices, "viewing": viewing, "typing": typing})
        })
        .collect()
}

fn note(chat: &str, entries: Option<&BTreeMap<Key, Entry>>) -> Value {
    json!({"sessionId": chat, "participants": participants(entries)})
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
}
