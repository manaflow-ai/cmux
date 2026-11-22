//! A peer's live asks for a session it has not listed yet (`Hub::peer_ask_run` says
//! `Unlisted`): its new chat asked before its `_acpmux/session_changed` reached this
//! daemon, or a lossy notice of it was left out. Dropping such an ask as forged left
//! the Mac with no record of a live ask, so a person's Allow once went out unsigned
//! and the peer refused it ("That answer didn't go through", 2026-11-03). Each is
//! held here and applied again once the peer lists that session; the rule it must
//! pass is unchanged. Bounded by time, not count: each notice is held for `HOLD_FOR`.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use crate::peer::PeerNotice;

/// How long a held ask waits for its session to be listed.
const HOLD_FOR: Duration = Duration::from_secs(120);

struct Held {
    peer: String,
    generation: u64,
    session: String,
    at: Instant,
    notice: PeerNotice,
}

#[derive(Default)]
pub(crate) struct HeldAsks {
    /// Oldest first: every change keeps the order, so the expired ones are a prefix.
    held: std::sync::Mutex<VecDeque<Held>>,
}

impl HeldAsks {
    /// Hold `notice`, peer `peer`'s ask for its unlisted session `session`.
    pub(crate) fn hold(&self, peer: &str, generation: u64, session: &str, notice: PeerNotice) {
        let mut held = self.held.lock().unwrap_or_else(|e| e.into_inner());
        let now = Instant::now();
        // Constant time per hold: only the expired front is touched.
        while held.front().is_some_and(|h| now.duration_since(h.at) >= HOLD_FOR) {
            held.pop_front();
        }
        held.push_back(Held {
            peer: peer.to_owned(),
            generation,
            session: session.to_owned(),
            at: now,
            notice,
        });
    }

    /// Drops peer `peer`'s held asks for its session `session` that `permission` names (every
    /// one of that session's for None): answered, decided or withdrawn there before the peer
    /// listed the session, so none comes back as a live card.
    pub(crate) fn forget(&self, peer: &str, session: &str, permission: Option<&str>) {
        let mut held = self.held.lock().unwrap_or_else(|e| e.into_inner());
        held.retain(|h| {
            h.peer != peer
                || h.session != session
                || permission.is_some_and(|p| h.permission() != Some(p))
        });
    }

    /// Takes peer `peer`'s held asks (of link generation `generation`) whose session
    /// `listed` now finds, in the order they came; an older generation's are dropped.
    pub(crate) fn take_listed(
        &self,
        peer: &str,
        generation: u64,
        listed: impl Fn(&str) -> bool,
    ) -> Vec<PeerNotice> {
        let mut held = self.held.lock().unwrap_or_else(|e| e.into_inner());
        if !held.iter().any(|h| h.peer == peer) {
            return Vec::new();
        }
        let now = Instant::now();
        let mut out = Vec::new();
        let mut keep = VecDeque::with_capacity(held.len());
        for h in held.drain(..) {
            if h.peer != peer {
                keep.push_back(h);
            } else if h.generation != generation || now.duration_since(h.at) >= HOLD_FOR {
                // A replaced peer's, or one whose session never came: dropped.
            } else if listed(&h.session) {
                out.push(h.notice);
            } else {
                keep.push_back(h);
            }
        }
        *held = keep;
        out
    }
}

impl Held {
    /// The `permissionId` of the held ask: a pending notice's own, or its event record's `msg`.
    fn permission(&self) -> Option<&str> {
        let PeerNotice::Notification { params, .. } = &self.notice else { return None };
        params
            .get("permissionId")
            .or_else(|| params.pointer("/msg/permissionId"))
            .and_then(serde_json::Value::as_str)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn ask(id: &str) -> PeerNotice {
        PeerNotice::Notification {
            method: "_acpmux/permission_pending".into(),
            params: json!({"sessionId": id}),
            link: 1,
        }
    }

    #[test]
    fn only_a_listed_sessions_asks_of_the_same_peer_and_generation_come_back() {
        let held = HeldAsks::default();
        held.hold("p", 1, "s1", ask("s1"));
        held.hold("p", 1, "s2", ask("s2"));
        held.hold("q", 1, "s1", ask("s1"));
        held.hold("p", 0, "s1", ask("s1"));
        let back = held.take_listed("p", 1, |s| s == "s1");
        assert_eq!(back.len(), 1);
        assert!(held.take_listed("p", 1, |s| s == "s1").is_empty());
        assert_eq!(held.take_listed("p", 1, |_| true).len(), 1);
        assert_eq!(held.take_listed("q", 1, |_| true).len(), 1);
    }

    #[test]
    fn a_resolved_ask_is_forgotten() {
        let held = HeldAsks::default();
        let pending = |id: &str, p: &str| PeerNotice::Notification {
            method: "_acpmux/permission_pending".into(),
            params: json!({"sessionId": id, "permissionId": p}),
            link: 1,
        };
        let record = |id: &str, p: &str| PeerNotice::Notification {
            method: "_acpmux/event".into(),
            params: json!({"sessionId": id, "kind": "permission_request", "msg": {"permissionId": p}}),
            link: 1,
        };
        held.hold("p", 1, "s", pending("s", "a"));
        held.hold("p", 1, "s", record("s", "a"));
        held.hold("p", 1, "s", pending("s", "b"));
        held.hold("p", 1, "t", pending("t", "a"));
        held.forget("p", "s", Some("a"));
        assert_eq!(held.take_listed("p", 1, |id| id == "s").len(), 1);
        held.hold("p", 1, "s", pending("s", "c"));
        held.forget("p", "s", None);
        assert!(held.take_listed("p", 1, |id| id == "s").is_empty());
        assert_eq!(held.take_listed("p", 1, |_| true).len(), 1);
    }

    #[test]
    fn a_peer_holds_more_than_sixty_four_asks() {
        let held = HeldAsks::default();
        held.hold("q", 1, "s", ask("s"));
        for i in 0..200 {
            held.hold("p", 1, &format!("s{i}"), ask("s"));
        }
        assert_eq!(held.take_listed("p", 1, |_| true).len(), 200);
        assert_eq!(
            held.take_listed("q", 1, |_| true).len(),
            1,
            "one peer's asks pushed out another's"
        );
    }
}
