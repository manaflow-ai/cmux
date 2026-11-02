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
use crate::protocol::peer_state::{PeerLinkState, PeerStateChanged};
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
        let previous = last.by_name.get(name).map(|l| l.note.state);
        let note = now.note(name);
        last.forget_removal(name);
        last.by_name
            .insert(name.to_owned(), Last { speaker: Some(generation), note: note.clone() });
        if previous != Some(note.state) {
            self.send(note);
        }
    }

    /// Instance `generation`'s state changed: sent while it speaks for `name` and the state is
    /// not the last one sent.
    pub fn changed(&self, name: &str, generation: u64, now: Observed) {
        let mut last = self.last.lock_or_recover();
        let Some(entry) = last.by_name.get_mut(name).filter(|l| l.speaker == Some(generation))
        else {
            return;
        };
        if entry.note.state == now.state {
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
        let gone =
            Observed { state: PeerLinkState::Offline, last_seen, error: Some(REMOVED.into()) };
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

/// A peer link's state as its instance sees it now.
#[derive(Debug, Clone)]
pub struct Observed {
    pub state: PeerLinkState,
    pub last_seen: Option<u64>,
    pub error: Option<String>,
}

impl Observed {
    fn note(self, name: &str) -> PeerStateChanged {
        PeerStateChanged {
            peer: name.to_owned(),
            state: self.state,
            last_seen: self.last_seen,
            error: self.error,
            at: crate::store::now_ms(),
        }
    }
}

fn marked(note: &PeerStateChanged) -> Value {
    json!({ (STATE_NOTE): note })
}

#[cfg(test)]
mod tests {
    use super::*;
    use PeerLinkState::*;

    fn seen(state: PeerLinkState) -> Observed {
        Observed { state, last_seen: Some(1), error: None }
    }

    fn drain(rx: &mut broadcast::Receiver<Value>) -> Vec<(String, PeerLinkState, Option<String>)> {
        let mut out = Vec::new();
        while let Ok(v) = rx.try_recv() {
            let n: PeerStateChanged = serde_json::from_value(v[STATE_NOTE].clone()).unwrap();
            out.push((n.peer, n.state, n.error));
        }
        out
    }

    /// A replaced instance never speaks after its replacement, a replacement in the same state
    /// sends no repeat, and a change of the replacement goes out.
    #[test]
    fn a_replacement_speaks_alone_and_repeats_nothing() {
        let states = PeerStates::default();
        let mut rx = states.subscribe();
        states.register("b", 1, seen(Connecting));
        states.changed("b", 1, seen(Reconnecting));
        // Reconnect: a new instance, still reconnecting.
        states.register("b", 2, seen(Reconnecting));
        // The old one's late change is dropped.
        states.changed("b", 1, seen(Connected));
        states.changed("b", 2, seen(Reconnecting));
        states.changed("b", 2, seen(Connected));
        let b = |s| ("b".to_owned(), s, None);
        assert_eq!(drain(&mut rx), [b(Connecting), b(Reconnecting), b(Connected)]);
    }

    /// A removal sends its last note only while the removed instance still speaks: a lease that
    /// ended after a new one took its name says nothing, and the removed one stays silent.
    #[test]
    fn a_removal_is_the_last_word_only_for_the_instance_that_speaks() {
        let states = PeerStates::default();
        let mut rx = states.subscribe();
        states.register("b", 1, seen(Connected));
        states.register("b", 2, seen(Connecting));
        states.removed("b", 1, None);
        states.removed("b", 2, Some(5));
        states.changed("b", 2, seen(Connected));
        let got = drain(&mut rx);
        assert_eq!(got.len(), 3, "{got:?}");
        assert_eq!(got[2], ("b".to_owned(), Offline, Some(REMOVED.to_owned())));
        // Added again: its first state goes out.
        states.register("b", 3, seen(Connecting));
        assert_eq!(drain(&mut rx), [("b".to_owned(), Connecting, None)]);
    }

    /// A watcher that fell behind gets each name's last note, a removed one's included.
    #[test]
    fn the_snapshot_has_every_names_last_note() {
        let states = PeerStates::default();
        states.register("a", 1, seen(Connected));
        states.register("b", 2, seen(Connected));
        states.removed("b", 2, None);
        let notes: Vec<PeerStateChanged> = states
            .snapshot()
            .into_iter()
            .map(|v| serde_json::from_value(v[STATE_NOTE].clone()).unwrap())
            .collect();
        assert_eq!(
            notes.iter().map(|n| (n.peer.as_str(), n.state)).collect::<Vec<_>>(),
            [("a", Connected), ("b", Offline)]
        );
        assert_eq!(notes[1].error.as_deref(), Some(REMOVED));
    }

    /// Removed names keep their last note up to `REMOVED_KEPT`, the oldest removal going first;
    /// a name added again is no longer a removal.
    #[test]
    fn removed_names_are_kept_up_to_a_bound() {
        let states = PeerStates::default();
        for g in 0..(REMOVED_KEPT as u64 + 10) {
            let name = format!("lease-{g}");
            states.register(&name, g, seen(Connected));
            states.removed(&name, g, None);
        }
        states.register("lease-20", 1000, seen(Connecting));
        let names: Vec<String> = states
            .snapshot()
            .into_iter()
            .map(|v| v[STATE_NOTE]["peer"].as_str().unwrap().to_owned())
            .collect();
        assert_eq!(names.len(), REMOVED_KEPT, "{names:?}");
        assert!(!names.contains(&"lease-0".to_owned()), "the oldest removal went first");
        assert!(names.contains(&"lease-20".to_owned()), "added again: it runs");
        assert!(names.contains(&format!("lease-{}", REMOVED_KEPT + 9)), "the newest is kept");
    }
}
