//! Every link that carries a request the peer still owes an answer to, and the epoch it was
//! sent at: the one record a cancel, a path switch and dual send read (review F1 of #41392,
//! F1 of #41361).
//!
//! - A request goes out on the link of epoch E: carried by `Link(E)`. A request bound to its
//!   link's connection (a load, an attach) keeps its line here, and a path switch sends it
//!   again on the next link (`Peer::resend_switched`), which then carries it instead.
//! - While the link's path is in doubt, its copy on the shadow makes the shadow a carrier too
//!   (`peer_dual.rs`). That copy runs on after the link moves on: the shadow keeps reading
//!   answers to what it carried.
//! - A cancel goes to every carrier still live (a link of the current epoch, a shadow whose
//!   queue is open), never only to the link it first went on. A full queue is waited out, never
//!   a reason to drop it; only a carrier that is gone (its link ended, its shadow closed) drops
//!   it, and that is logged. Each live carrier owes its own late answer, and each is dropped
//!   and logged (`request_cancel::Cancelled`).
//!
//! Bounded: an entry goes when its request's caller is done (`ForgetPending`, whatever ended
//! it: an answer, a timeout, a cancel) or when no carrier of it is left (a link that ended
//! without a switch, a shadow that ended).

use super::Outbound;
use crate::no_panic::LockExt;
use crate::rpc::method;
use serde_json::json;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use tokio::sync::mpsc;

/// One link that carries a request.
enum Carrier {
    /// The peer link of this epoch: what goes out on it is tagged with it, and a later link
    /// drops the frame.
    Link(u64),
    /// The shadow of the link of epoch `link`, by its copies' queue.
    Shadow { link: u64, tx: mpsc::Sender<String> },
}

impl Carrier {
    /// Whether it still carries the request: its link is the live one, or its shadow is open.
    fn live(&self, epoch: u64) -> bool {
        match self {
            Carrier::Link(link) => *link == epoch,
            Carrier::Shadow { tx, .. } => !tx.is_closed(),
        }
    }
}

/// A request's carriers.
struct Carried {
    /// Its line, when it is bound to its link's connection: sent again on the next link after
    /// a path switch.
    bound: Option<String>,
    carriers: Vec<Carrier>,
}

impl Carried {
    fn on_link(&self) -> Option<u64> {
        self.carriers.iter().find_map(|c| match c {
            Carrier::Link(link) => Some(*link),
            Carrier::Shadow { .. } => None,
        })
    }
}

/// Each request still owed an answer, by pending key, with every link that carries it.
#[derive(Default)]
pub(super) struct Carriers {
    entries: HashMap<String, Carried>,
    /// Cancels waiting for room on the shadow of each link, not in its queue yet: the shadow
    /// does not end before they are (review F2 of #41392), or the copy it carried runs on.
    writing: HashMap<u64, usize>,
}

impl Carriers {
    /// Request `key` is queued to go out on the link of epoch `link`; `bound`: its line, sent
    /// again on the next link after a switch.
    pub(super) fn sent(&mut self, key: String, link: u64, bound: Option<String>) {
        self.entries.insert(key, Carried { bound, carriers: vec![Carrier::Link(link)] });
    }

    /// `copy` of request `key` onto the shadow of link `link`, when the request is still owed:
    /// the shadow carries it from now. False when nothing went (its request is done or
    /// cancelled, or the shadow's queue is full: the link's own frame still goes out).
    pub(super) fn copy(
        &mut self,
        key: &str,
        link: u64,
        tx: &mpsc::Sender<String>,
        copy: String,
    ) -> bool {
        let Some(entry) = self.entries.get_mut(key) else { return false };
        if tx.try_send(copy).is_err() {
            return false;
        }
        entry.carriers.push(Carrier::Shadow { link, tx: tx.clone() });
        true
    }

    /// The bound requests an earlier link than `link` carried: those a switch to `link` sends
    /// again.
    pub(super) fn bound_before(&self, link: u64) -> Vec<String> {
        self.entries
            .iter()
            .filter(|(_, e)| e.bound.is_some() && e.on_link().is_none_or(|on| on < link))
            .map(|(key, _)| key.clone())
            .collect()
    }

    /// Bound request `key` goes again on link `link`, which carries it from now: its line, or
    /// None when it is gone or already went on `link`.
    pub(super) fn resend(&mut self, key: &str, link: u64) -> Option<String> {
        let entry = self.entries.get_mut(key)?;
        let line = entry.bound.clone()?;
        if entry.on_link().is_some_and(|on| on >= link) {
            return None;
        }
        // The earlier link is gone: only the one it goes on now carries it.
        entry.carriers.retain(|c| !matches!(c, Carrier::Link(_)));
        entry.carriers.push(Carrier::Link(link));
        Some(line)
    }

    /// Whether request `key` is bound to its link's connection.
    pub(super) fn is_bound(&self, key: &str) -> bool {
        self.entries.get(key).is_some_and(|e| e.bound.is_some())
    }

    /// Whether an open shadow carries a copy of request `key`: its answer may still come there.
    pub(super) fn on_live_shadow(&self, key: &str) -> bool {
        self.entries.get(key).is_some_and(|e| {
            e.carriers.iter().any(|c| matches!(c, Carrier::Shadow { tx, .. } if !tx.is_closed()))
        })
    }

    /// Whether the shadow of link `link` carries any request still owed.
    /// Whether a cancel to the shadow of link `link` still waits for room in its queue.
    pub(super) fn cancels_due(&self, link: u64) -> bool {
        self.writing.get(&link).is_some_and(|n| *n > 0)
    }

    pub(super) fn shadow_carries(&self, link: u64) -> bool {
        self.entries.values().any(|e| {
            e.carriers.iter().any(|c| matches!(c, Carrier::Shadow { link: l, .. } if *l == link))
        })
    }

    /// The shadow of link `link` ends: it carries nothing from now. Returns the requests it
    /// leaves with no live carrier, which leave the record too (the live link is epoch `epoch`).
    pub(super) fn shadow_ended(&mut self, link: u64, epoch: u64) -> Vec<String> {
        let mut orphans = Vec::new();
        self.entries.retain(|key, e| {
            let before = e.carriers.len();
            e.carriers.retain(|c| !matches!(c, Carrier::Shadow { link: l, .. } if *l == link));
            if e.carriers.len() == before || e.carriers.iter().any(|c| c.live(epoch)) {
                return true;
            }
            orphans.push(key.clone());
            false
        });
        orphans
    }

    /// A link ended (the live one is epoch `epoch` now): requests no live link carries leave the
    /// record, but for bound ones a switch sends again (`switched`).
    pub(super) fn link_ended(&mut self, epoch: u64, switched: bool) {
        self.entries.retain(|_, e| {
            (switched && e.bound.is_some()) || e.carriers.iter().any(|c| c.live(epoch))
        });
    }

    /// Request `key`'s caller is done: its entry goes.
    pub(super) fn forget(&mut self, key: &str) {
        self.entries.remove(key);
    }

    /// The pending keys it holds an entry for.
    #[cfg(test)]
    pub(super) fn keys(&self) -> Vec<String> {
        self.entries.keys().cloned().collect()
    }
}

/// What a request queued to the peer needs to cancel it there (`request_cancel.rs`).
pub(super) struct PeerCancel {
    pub(super) out: mpsc::Sender<Outbound>,
    /// The live link's epoch (`Peer::link_epoch`): a link carrier of another is gone.
    pub(super) link_epoch: Arc<AtomicU64>,
    pub(super) carried: Arc<StdMutex<Carriers>>,
    pub(super) id: i64,
    pub(super) method: String,
    pub(super) cancelled: Arc<StdMutex<crate::request_cancel::Cancelled>>,
    /// The peer listed `cancelRequestV2`: it hears the cancel.
    pub(super) tell: bool,
    pub(super) peer: String,
}

impl PeerCancel {
    /// Request `key` was cancelled by its client; `owed`: no answer took its pending entry
    /// first. Every live carrier hears `$/cancel_request` (a peer that answered already, or an
    /// older one that ignores it, hears nothing), and each owes a late answer, dropped and
    /// logged when it comes.
    pub(super) fn cancel(self, key: &str, owed: bool) {
        // Under the record's lock from taking its carriers to queuing the cancel on each: no
        // copy goes out after this (`Carriers::copy`), no resend (`Carriers::resend`), and a
        // shadow that ends drains what it was given (`Peer::shadow_end`).
        let mut carried = self.carried.lock_or_recover();
        let entry = carried.entries.remove(key);
        let epoch = self.link_epoch.load(Ordering::SeqCst);
        let live: Vec<&Carrier> =
            entry.iter().flat_map(|e| e.carriers.iter()).filter(|c| c.live(epoch)).collect();
        {
            let mut cancelled = self.cancelled.lock_or_recover();
            for _ in 0..live.len().max(1) {
                cancelled.remember(key.to_owned(), self.method.clone());
            }
            // An answer that took the entry first went to a waiter that is gone: late too.
            if !owed {
                cancelled.take_late(key, "peer");
                return;
            }
        }
        // An older peer ignores the notification: it is not sent, but each late answer is
        // still dropped and logged.
        if !self.tell {
            return;
        }
        if live.is_empty() {
            tracing::debug!(target: crate::request_cancel::LOG_TARGET, peer = %self.peer, id = self.id, "no link carries the cancelled request any more");
            return;
        }
        let note = crate::rpc::Message::notification(
            method::CANCEL_REQUEST,
            json!({"requestId": self.id}),
        )
        .to_line();
        for carrier in live {
            match carrier {
                Carrier::Link(link) => {
                    // Its epoch is the link's that carries the request as the cancel is queued,
                    // under the record's lock: a resend after it finds the request gone and
                    // sends nothing (review F1 of #41392).
                    let frame = Outbound { epoch: *link, key: None, line: note.clone() };
                    queue(&self.out, frame, &self.peer, self.id, "link", || {});
                }
                Carrier::Shadow { tx, link } => {
                    let line = note.trim_end_matches('\n').to_owned();
                    // One that waits for room is counted until it is in the shadow's queue: the
                    // shadow ends only after (`Carriers::cancels_due`).
                    let (record, link) = (self.carried.clone(), *link);
                    let waits = queue(tx, line, &self.peer, self.id, "shadow", move || {
                        let mut carried = record.lock_or_recover();
                        if let Some(n) = carried.writing.get_mut(&link) {
                            *n = n.saturating_sub(1);
                            if *n == 0 {
                                carried.writing.remove(&link);
                            }
                        }
                    });
                    if waits {
                        *carried.writing.entry(link).or_default() += 1;
                    }
                }
            }
        }
    }
}

/// `item` on `tx` now, or once there is room: never dropped for a full queue, only for a
/// closed one (its carrier is gone), which is logged. True when it waits for room: then
/// `written` runs in the task that waits, once it is in the queue or its carrier is gone (the
/// caller may hold the record's lock until it returns, never the task).
fn queue<T: Send + 'static>(
    tx: &mpsc::Sender<T>,
    item: T,
    peer: &str,
    id: i64,
    on: &'static str,
    written: impl FnOnce() + Send + 'static,
) -> bool {
    let item = match tx.try_send(item) {
        Ok(()) => return false,
        Err(mpsc::error::TrySendError::Full(item)) => Some(item),
        Err(mpsc::error::TrySendError::Closed(_)) => None,
    };
    let peer = peer.to_owned();
    let gone = move |peer: &str| {
        tracing::debug!(target: crate::request_cancel::LOG_TARGET, peer = %peer, id, on, "its carrier was gone before the cancel went out");
    };
    match (item, tokio::runtime::Handle::try_current()) {
        (Some(item), Ok(rt)) => {
            let tx = tx.clone();
            rt.spawn(async move {
                if tx.send(item).await.is_err() {
                    gone(&peer);
                }
                written();
            });
            true
        }
        _ => {
            gone(&peer);
            false
        }
    }
}
