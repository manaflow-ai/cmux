//! A peer's live asks for a session it has not listed yet (`Hub::peer_ask_run` says
//! `Unlisted`): its new chat asked before its `_acpmux/session_changed` reached this
//! daemon, or a lossy notice of it was left out. Dropping such an ask as forged left
//! the Mac with no record of a live ask, so a person's Allow once went out unsigned
//! and the peer refused it ("That answer didn't go through", 2026-11-03). Each is
//! held here and applied again once the peer lists that session; the rule it must
//! pass is unchanged. Bounded: at most `MAX_HELD` notices per peer, each for `HOLD_FOR`.

use std::time::{Duration, Instant};

use crate::peer::PeerNotice;

/// How long a held ask waits for its session to be listed.
const HOLD_FOR: Duration = Duration::from_secs(120);
/// How many held asks the daemon keeps per peer; that peer's oldest go first, so one peer
/// never pushes out another's.
const MAX_HELD: usize = 64;

struct Held {
    peer: String,
    generation: u64,
    session: String,
    at: Instant,
    notice: PeerNotice,
}

#[derive(Default)]
pub(crate) struct HeldAsks {
    held: std::sync::Mutex<Vec<Held>>,
}

impl HeldAsks {
    /// Hold `notice`, peer `peer`'s ask for its unlisted session `session`.
    pub(crate) fn hold(&self, peer: &str, generation: u64, session: &str, notice: PeerNotice) {
        let mut held = self.held.lock().unwrap_or_else(|e| e.into_inner());
        let now = Instant::now();
        held.retain(|h| now.duration_since(h.at) < HOLD_FOR);
        if held.iter().filter(|h| h.peer == peer).count() >= MAX_HELD
            && let Some(oldest) = held.iter().position(|h| h.peer == peer)
        {
            held.remove(oldest);
        }
        held.push(Held {
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
        let mut keep = Vec::with_capacity(held.len());
        for h in held.drain(..) {
            if h.peer != peer {
                keep.push(h);
            } else if h.generation != generation || now.duration_since(h.at) >= HOLD_FOR {
                // A replaced peer's, or one whose session never came: dropped.
            } else if listed(&h.session) {
                out.push(h.notice);
            } else {
                keep.push(h);
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
mod tests;
