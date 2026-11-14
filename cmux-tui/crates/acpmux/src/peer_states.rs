//! The last `_acpmux/peer_state_changed` sent for each peer name, and which peer instance
//! speaks for the name now (`Hub::spawn_peer` registers it). One lock orders every note, so:
//! an instance that was replaced or removed never speaks after the one that replaced it; a
//! replacement in the same state sends no repeat; a removal sends its last `offline`
//! (`error: "removed"`) only while the removed instance still speaks for the name; and a
//! watcher that fell behind the feed gets every name's last note again (`snapshot`). The
//! notes have their own feed (`subscribe`), so a burst of them never pushes a harness reload
//! out of the harness feed's buffer.
//!
//! What it holds: one entry per peer that runs, and the last note of at most
//! `REMOVED_KEPT` removed names (the oldest removal goes first), so a daemon that leases many
//! short-lived peers does not grow it without bound.

use crate::no_panic::LockExt;
use crate::protocol::peer_state::{Carrier, DownCause, MachineLink, PeerStateChanged};
use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};
use std::sync::Mutex;
use tokio::sync::broadcast;

/// The hub's feed marks a peer state note with this key (`server/harness_admin.rs`
/// `watch_note` sends its value as `_acpmux/peer_state_changed`).
pub const STATE_NOTE: &str = "peerStateChanged";

/// The feature the daemon lists for `_acpmux/peer_state_changed`.
pub const STATE_EVENTS_FEATURE: &str = "peerStateEvents";

/// The `error` of a removed peer's last note.
pub const REMOVED: &str = "removed";

/// How many removed names keep their last note for a watcher that fell behind.
pub const REMOVED_KEPT: usize = 64;

/// The notes a watcher may fall behind by before it gets a `snapshot` instead.
const FEED: usize = 256;

struct Last {
    /// The instance (`Peer::generation`) that speaks for the name; None once it was removed.
    speaker: Option<u64>,
    note: PeerStateChanged,
}

#[derive(Default)]
struct Table {
    by_name: HashMap<String, Last>,
    /// The removed names in `by_name`, oldest removal first.
    removed: VecDeque<String>,
}

impl Table {
    fn forget_removal(&mut self, name: &str) {
        self.removed.retain(|n| n != name);
    }
}

pub struct PeerStates {
    to: broadcast::Sender<Value>,
    last: Mutex<Table>,
}

impl Default for PeerStates {
    fn default() -> Self {
        Self { to: broadcast::channel(FEED).0, last: Mutex::new(Table::default()) }
    }
}

impl PeerStates {
    /// The notes from now on, each marked `STATE_NOTE` (`server/harness_admin.rs` `watch_note`).
    pub fn subscribe(&self) -> broadcast::Receiver<Value> {
        self.to.subscribe()
    }

    /// Instance `generation` speaks for `name` from now on, in `state`: sent unless it is the
    /// state last sent for the name (a replacement in the same state is no change).
    pub fn register(&self, name: &str, generation: u64, now: Observed) {
        let mut last = self.last.lock_or_recover();
        let previous = last.by_name.get(name).map(|l| key(&l.note));
        let note = now.note(name);
        last.forget_removal(name);
        last.by_name
            .insert(name.to_owned(), Last { speaker: Some(generation), note: note.clone() });
        if previous != Some(key(&note)) {
            self.send(note);
        }
    }

    /// Instance `generation`'s state changed: sent while it speaks for `name` and the link
    /// (`key`) is not the last one sent.
    pub fn changed(&self, name: &str, generation: u64, now: Observed) {
        let mut last = self.last.lock_or_recover();
        let Some(entry) = last.by_name.get_mut(name).filter(|l| l.speaker == Some(generation))
        else {
            return;
        };
        if key(&entry.note) == now.key() {
            return;
        }
        entry.note = now.note(name);
        self.send(entry.note.clone());
    }

    /// Instance `generation` left for good: its last note, `offline` with error `removed`,
    /// unless another instance speaks for the name by now.
    pub fn removed(&self, name: &str, generation: u64, last_seen: Option<u64>) {
        let mut last = self.last.lock_or_recover();
        let Some(entry) = last.by_name.get_mut(name).filter(|l| l.speaker == Some(generation))
        else {
            return;
        };
        let mut gone = Observed::new(MachineLink::Offline, last_seen, Some(REMOVED.into()));
        gone.since = crate::store::now_ms();
        entry.speaker = None;
        entry.note = gone.note(name);
        self.send(entry.note.clone());
        last.removed.push_back(name.to_owned());
        while last.removed.len() > REMOVED_KEPT {
            if let Some(oldest) = last.removed.pop_front() {
                last.by_name.remove(&oldest);
            }
        }
    }

    /// Every name's last note, marked for the feed, for a watcher that fell behind it.
    pub fn snapshot(&self) -> Vec<Value> {
        let last = self.last.lock_or_recover();
        let mut notes: Vec<&PeerStateChanged> = last.by_name.values().map(|l| &l.note).collect();
        notes.sort_by(|a, b| a.peer.cmp(&b.peer));
        notes.into_iter().map(marked).collect()
    }

    fn send(&self, note: PeerStateChanged) {
        let _ = self.to.send(marked(&note));
    }
}

/// A peer link's state as its instance sees it now (`PeerStateChanged`'s fields).
#[derive(Debug, Clone)]
pub struct Observed {
    pub link: MachineLink,
    pub carrier: Option<Carrier>,
    pub cause: Option<DownCause>,
    /// When `link` took its value.
    pub since: u64,
    pub next_retry_at: Option<u64>,
    pub last_seen: Option<u64>,
    pub error: Option<String>,
}

/// What makes a note news: a change of any of these sends one; `since`, `lastSeen` and
/// `error` ride along.
type Key = (MachineLink, Option<Carrier>, Option<DownCause>, Option<u64>);

fn key(note: &PeerStateChanged) -> Key {
    (note.link, note.carrier, note.cause, note.next_retry_at)
}

impl Observed {
    /// `link` with no carrier, cause or retry, since now.
    pub fn new(link: MachineLink, last_seen: Option<u64>, error: Option<String>) -> Self {
        Self { link, carrier: None, cause: None, since: 0, next_retry_at: None, last_seen, error }
    }

    fn key(&self) -> Key {
        (self.link, self.carrier, self.cause, self.next_retry_at)
    }

    fn note(self, name: &str) -> PeerStateChanged {
        let at = crate::store::now_ms();
        PeerStateChanged {
            peer: name.to_owned(),
            state: self.link.folded(),
            link: self.link,
            carrier: self.carrier,
            cause: self.cause,
            since: if self.since == 0 { at } else { self.since },
            next_retry_at: self.next_retry_at,
            last_seen: self.last_seen,
            error: self.error,
            at,
        }
    }
}

fn marked(note: &PeerStateChanged) -> Value {
    json!({ (STATE_NOTE): note })
}

#[cfg(test)]
mod tests;
