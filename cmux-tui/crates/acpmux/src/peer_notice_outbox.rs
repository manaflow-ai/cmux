//! A link's notices on their way to the hub (`Hub::peer_notices`, one bounded queue every peer
//! shares). A link's serve loop also reads the peer's frames and writes its pings; awaiting a full
//! hub queue there stopped every link at once while the hub was behind, so each looked silent to
//! its peer and to itself together. Here a notice is handed over without waiting: straight into
//! the hub's queue when it has room and nothing of this link's waits ahead of it, else into this
//! link's own backlog, which one short-lived task moves on in order.
//!
//! In the backlog a changed row supersedes the same row's earlier change of the same kind (the
//! hub keeps only the latest row anyway), but never across a notice that must keep its place
//! (`Connected`, `Disconnected`, a list, a notification, which may carry a caller's answer): those
//! are never dropped and nothing moves past them. Only a backlog of `LINK_BACKLOG` notices that
//! cannot be merged makes the link wait, which bounds the memory a stalled hub can take.

use crate::no_panic::LockExt;
use crate::peer::PeerNotice;
use std::collections::VecDeque;
use std::sync::{Arc, Mutex, OnceLock};

#[path = "peer_list_slot.rs"]
mod peer_list_slot;
use tokio::sync::{Notify, mpsc};

pub(crate) type Item = (String, u64, PeerNotice);

/// The notices one link holds back while the hub is behind before its loop waits for room.
pub(crate) const LINK_BACKLOG: usize = 4096;

/// The hub went away (its notice loop stopped): nothing more is taken.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Closed;

pub(crate) struct NoticeOutbox {
    inner: Arc<Inner>,
    /// Owns the task that moves the backlog on: a part of its peer's scope, so the peer's close
    /// joins it (`Peer::close_tasks`).
    scope: cmux_scope::Scope,
}

struct Inner {
    hub: mpsc::Sender<Item>,
    state: Mutex<State>,
    room: Notify,
    cap: usize,
    lists: OnceLock<peer_list_slot::ListSlot>,
}

#[derive(Default)]
struct State {
    backlog: VecDeque<Item>,
    /// A task is moving the backlog on (it may hold one notice taken from it).
    draining: bool,
    closed: bool,
}

/// What a changed row is keyed by when it may supersede another: its session and kind.
fn merge_key(notice: &PeerNotice) -> Option<(&str, &str)> {
    let PeerNotice::SessionChanged { session, kind, .. } = notice else { return None };
    // A purge is kept as it came: what follows a purge is a new row.
    if kind == "purged" {
        return None;
    }
    Some((session.get("sessionId")?.as_str()?, kind.as_str()))
}

impl NoticeOutbox {
    pub(crate) fn new(hub: mpsc::Sender<Item>, scope: cmux_scope::Scope) -> Self {
        Self::with_cap(hub, scope, LINK_BACKLOG)
    }

    pub(crate) fn with_cap(hub: mpsc::Sender<Item>, scope: cmux_scope::Scope, cap: usize) -> Self {
        Self {
            scope,
            inner: Arc::new(Inner {
                hub,
                state: Mutex::new(State::default()),
                room: Notify::new(),
                cap: cap.max(1),
                lists: OnceLock::new(),
            }),
        }
    }

    pub(crate) fn coalesce_lists(&self) {
        self.inner.lists.get_or_init(Default::default);
    }

    pub(crate) fn take_waiting_list(&self, number: u64) -> Option<Vec<Arc<str>>> {
        self.inner.lists.get()?.take(number)
    }

    // Publish only *after* securing room. A cancelled send waiting on a full backlog
    // cannot supersede a list whose marker the hub already accepted.
    fn accepted(&self, item: Item) -> Item {
        match (self.inner.lists.get(), item) {
            (Some(slot), (peer, generation, PeerNotice::Sessions(rows))) => {
                (peer, generation, PeerNotice::WaitingList(slot.hold(rows)))
            }
            (_, item) => item,
        }
    }

    /// The notices this link holds back now.
    #[cfg(test)]
    pub(crate) fn backlog(&self) -> usize {
        self.inner.state.lock_or_recover().backlog.len()
    }

    /// Hand `item` to the hub in this link's order. Returns at once unless the backlog is full of
    /// notices that cannot be merged; `Err` once the hub stopped taking notices.
    pub(crate) async fn send(&self, item: Item) -> Result<(), Closed> {
        let mut item = Some(item);
        loop {
            let room = self.inner.room.notified();
            tokio::pin!(room);
            room.as_mut().enable();
            {
                let mut state = self.inner.state.lock_or_recover();
                if state.closed {
                    return Err(Closed);
                }
                if state.backlog.is_empty() && !state.draining {
                    match self.inner.hub.try_reserve() {
                        Ok(permit) => {
                            let Some(next) = item.take() else { return Ok(()) };
                            permit.send(self.accepted(next));
                            return Ok(());
                        }
                        Err(mpsc::error::TrySendError::Closed(_)) => {
                            state.closed = true;
                            return Err(Closed);
                        }
                        Err(mpsc::error::TrySendError::Full(())) => {}
                    }
                }
                let Some(next) = item.take() else { return Ok(()) };
                let merged = merge_into(&mut state.backlog, &next.0, next.1, &next.2);
                if merged || state.backlog.len() < self.inner.cap {
                    state.backlog.push_back(self.accepted(next));
                    crate::gauges::peer_notices().link_held(state.backlog.len() as u64, merged);
                    if !state.draining {
                        state.draining = true;
                        self.scope
                            .spawn_named("peer notices to the hub", drain(self.inner.clone()));
                    }
                    return Ok(());
                }
                item = Some(next);
                crate::gauges::peer_notices().link_waited();
            }
            room.await;
        }
    }
}

/// Take out of `backlog` the notice `notice` supersedes, if one waits after the last notice
/// that keeps its place.
fn merge_into(
    backlog: &mut VecDeque<Item>,
    peer: &str,
    generation: u64,
    notice: &PeerNotice,
) -> bool {
    let Some(key) = merge_key(notice) else { return false };
    for at in (0..backlog.len()).rev() {
        let (p, g, waiting) = &backlog[at];
        let Some(theirs) = merge_key(waiting) else { break };
        if theirs == key && p == peer && *g == generation {
            backlog.remove(at);
            return true;
        }
    }
    false
}

/// Hand the backlog to the hub in order. A notice leaves the backlog only once the hub has room
/// for it, so until then it still merges with newer changes to its row and counts toward the cap.
async fn drain(inner: Arc<Inner>) {
    loop {
        let Ok(permit) = inner.hub.reserve().await else {
            let mut state = inner.state.lock_or_recover();
            state.closed = true;
            state.draining = false;
            state.backlog.clear();
            drop(state);
            inner.room.notify_waiters();
            return;
        };
        let next = {
            let mut state = inner.state.lock_or_recover();
            match state.backlog.pop_front() {
                Some(next) => next,
                None => {
                    state.draining = false;
                    return;
                }
            }
        };
        permit.send(next);
        inner.room.notify_waiters();
    }
}

#[cfg(test)]
#[path = "peer_notice_outbox_tests.rs"]
mod tests;
