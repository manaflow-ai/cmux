//! The last `_acpmux/peer_state_changed` sent for each peer name, and which peer instance
//! speaks for the name now (`Hub::spawn_peer` registers it). One lock orders every note, so:
//! an instance that was replaced or removed never speaks after the one that replaced it; a
//! replacement in the same state sends no repeat; a removal sends its last `offline`
//! (`error: "removed"`) only while the removed instance still speaks for the name; and a
//! watcher that fell behind the feed gets every name's last note again (`snapshot`).

use crate::no_panic::LockExt;
use crate::protocol::peer_state::{PeerLinkState, PeerStateChanged};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::Mutex;
use tokio::sync::broadcast;

/// The hub's feed marks a peer state note with this key (`server/harness_admin.rs`
/// `watch_note` sends its value as `_acpmux/peer_state_changed`).
pub const STATE_NOTE: &str = "peerStateChanged";

/// The feature the daemon lists for `_acpmux/peer_state_changed`.
pub const STATE_EVENTS_FEATURE: &str = "peerStateEvents";

/// The `error` of a removed peer's last note.
pub const REMOVED: &str = "removed";

struct Last {
    /// The instance (`Peer::generation`) that speaks for the name; None once it was removed.
    speaker: Option<u64>,
    note: PeerStateChanged,
}

pub struct PeerStates {
    to: broadcast::Sender<Value>,
    /// One entry per name a peer ran under in this daemon's life, a removed one's included:
    /// a handful, never pruned.
    last: Mutex<HashMap<String, Last>>,
}

impl PeerStates {
    pub fn new(to: broadcast::Sender<Value>) -> Self {
        Self { to, last: Mutex::new(HashMap::new()) }
    }

    /// Instance `generation` speaks for `name` from now on, in `state`: sent unless it is the
    /// state last sent for the name (a replacement in the same state is no change).
    pub fn register(&self, name: &str, generation: u64, now: Observed) {
        let mut last = self.last.lock_or_recover();
        let previous = last.get(name).map(|l| l.note.state);
        let note = now.note(name);
        last.insert(name.to_owned(), Last { speaker: Some(generation), note: note.clone() });
        if previous != Some(note.state) {
            self.send(note);
        }
    }

    /// Instance `generation`'s state changed: sent while it speaks for `name` and the state is
    /// not the last one sent.
    pub fn changed(&self, name: &str, generation: u64, now: Observed) {
        let mut last = self.last.lock_or_recover();
        let Some(entry) = last.get_mut(name).filter(|l| l.speaker == Some(generation)) else {
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
        let Some(entry) = last.get_mut(name).filter(|l| l.speaker == Some(generation)) else {
            return;
        };
        let gone = Observed { state: PeerLinkState::Offline, last_seen, error: Some(REMOVED.into()) };
        entry.speaker = None;
        entry.note = gone.note(name);
        self.send(entry.note.clone());
    }

    /// Every name's last note, marked for the feed, for a watcher that fell behind it.
    pub fn snapshot(&self) -> Vec<Value> {
        let last = self.last.lock_or_recover();
        let mut notes: Vec<&PeerStateChanged> = last.values().map(|l| &l.note).collect();
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
        let (tx, mut rx) = broadcast::channel(64);
        let states = PeerStates::new(tx);
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
        let (tx, mut rx) = broadcast::channel(64);
        let states = PeerStates::new(tx);
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
        let (tx, _rx) = broadcast::channel(64);
        let states = PeerStates::new(tx);
        states.register("a", 1, seen(Connected));
        states.register("b", 2, seen(Connected));
        states.removed("b", 2, None);
        let notes: Vec<PeerStateChanged> = states
            .snapshot()
            .into_iter()
            .map(|v| serde_json::from_value(v[STATE_NOTE].clone()).unwrap())
            .collect();
        assert_eq!(notes.iter().map(|n| (n.peer.as_str(), n.state)).collect::<Vec<_>>(), [
            ("a", Connected),
            ("b", Offline)
        ]);
        assert_eq!(notes[1].error.as_deref(), Some(REMOVED));
    }
}
