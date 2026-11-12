//! The hub's peer-notice queue, bounded in bytes by whole lists, not only by notice count.
//!
//! Every reconnect of a peer sends its whole session list (`PeerNotice::Sessions`). The hub
//! applies notices one at a time; when lists come faster than it applies them (many peers whose
//! links drop together, every row changed), a count-bounded channel of 4096 notices held
//! thousands of whole lists, gigabytes of rows nothing would read (2026-11-12: 2.8 GB of
//! `serde_json` values queued after 10 min of fleet churn). A newer whole list from a peer
//! supersedes its older one, so the queue keeps at most one per peer instance (plus the one being
//! applied): the list waits in that peer's slot and the channel carries a small marker.
//!
//! Ordering: every list still gets its own marker at its own place in the queue, and only the
//! marker of the list in the slot yields it; an older marker yields nothing. So the newest list is
//! applied where it was sent: after every notice sent before it (whose rows it already reflects)
//! and before every change sent after it (`peer.rs` publishes a list, then the changes held while
//! it was paged). No older `SessionChanged` can follow it and regress a row, and no newer one is
//! lost. What a skipped list would have shown is shown by the newer one a few notices later.
//!
//! Counted for `_acpmux/status` as `peerLists`: the lists and rows and approximate bytes waiting,
//! and how many lists were superseded unread.

use crate::no_panic::LockExt;
use crate::peer::PeerNotice;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use tokio::sync::mpsc;
use tokio::sync::mpsc::error::SendError;

type Notice = (String, u64, PeerNotice);

/// What the coalescing channel carries: a notice, or the marker of a list in its peer's slot.
#[derive(Debug)]
enum Item {
    Notice(PeerNotice),
    List(u64),
}

struct Pending {
    seq: u64,
    rows: Vec<Value>,
    bytes: usize,
}

#[derive(Default)]
struct Slots {
    /// Per peer name and generation, its newest list not yet applied.
    pending: StdMutex<HashMap<(String, u64), Pending>>,
    next_seq: AtomicU64,
    superseded: AtomicU64,
    superseded_bytes: AtomicU64,
}

impl Slots {
    /// Puts `rows` in the slot; the marker to queue for them.
    fn put(&self, key: (String, u64), rows: Vec<Value>) -> u64 {
        let seq = self.next_seq.fetch_add(1, Ordering::Relaxed) + 1;
        let bytes = rows.iter().map(approx_bytes).sum();
        let old = self.pending.lock_or_recover().insert(key, Pending { seq, rows, bytes });
        if let Some(old) = old {
            self.superseded.fetch_add(1, Ordering::Relaxed);
            self.superseded_bytes.fetch_add(old.bytes as u64, Ordering::Relaxed);
            // Dropped here, outside the lock.
            drop(old);
        }
        seq
    }

    /// The list of marker `seq`, when it is still the newest of its peer.
    fn take(&self, key: &(String, u64), seq: u64) -> Option<Vec<Value>> {
        let mut pending = self.pending.lock_or_recover();
        if pending.get(key).is_some_and(|p| p.seq == seq) {
            pending.remove(key).map(|p| p.rows)
        } else {
            None
        }
    }
}

enum Inner {
    /// A plain channel, as tests and single-peer callers make: every notice as sent.
    Plain(mpsc::Sender<Notice>),
    Coalescing {
        tx: mpsc::Sender<(String, u64, Item)>,
        slots: Arc<Slots>,
    },
}

/// The sending half: what `Peer` holds.
#[derive(Clone)]
pub struct NoticeSender(Arc<Inner>);

impl std::fmt::Debug for NoticeSender {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("NoticeSender")
    }
}

impl From<mpsc::Sender<Notice>> for NoticeSender {
    fn from(tx: mpsc::Sender<Notice>) -> Self {
        Self(Arc::new(Inner::Plain(tx)))
    }
}

/// The receiving half: the hub's notice loop.
pub struct NoticeReceiver {
    rx: mpsc::Receiver<(String, u64, Item)>,
    slots: Arc<Slots>,
}

/// A coalescing queue of `capacity` notices (and markers), whole lists kept one per peer.
pub fn channel(capacity: usize) -> (NoticeSender, NoticeReceiver) {
    let (tx, rx) = mpsc::channel(capacity);
    let slots = Arc::new(Slots::default());
    (
        NoticeSender(Arc::new(Inner::Coalescing { tx, slots: slots.clone() })),
        NoticeReceiver { rx, slots },
    )
}

impl NoticeSender {
    pub async fn send(&self, (peer, generation, notice): Notice) -> Result<(), SendError<Notice>> {
        match &*self.0 {
            Inner::Plain(tx) => tx.send((peer, generation, notice)).await,
            Inner::Coalescing { tx, slots } => {
                let item = match notice {
                    PeerNotice::Sessions(rows) => {
                        Item::List(slots.put((peer.clone(), generation), rows))
                    }
                    notice => Item::Notice(notice),
                };
                tx.send((peer, generation, item)).await.map_err(
                    |SendError((peer, generation, item))| {
                        let notice = match item {
                            Item::Notice(n) => n,
                            Item::List(seq) => PeerNotice::Sessions(
                                slots.take(&(peer.clone(), generation), seq).unwrap_or_default(),
                            ),
                        };
                        SendError((peer, generation, notice))
                    },
                )
            }
        }
    }

    /// `peerLists` in `_acpmux/status`: whole lists waiting to be applied, and those superseded.
    pub fn lists_status(&self) -> Value {
        let Inner::Coalescing { slots, .. } = &*self.0 else { return Value::Null };
        let (lists, rows, bytes) = {
            let pending = slots.pending.lock_or_recover();
            pending.values().fold((0usize, 0usize, 0usize), |(l, r, b), p| {
                (l + 1, r + p.rows.len(), b + p.bytes)
            })
        };
        json!({
            "pendingLists": lists,
            "pendingRows": rows,
            "pendingBytes": bytes,
            "superseded": slots.superseded.load(Ordering::Relaxed),
            "supersededBytes": slots.superseded_bytes.load(Ordering::Relaxed),
        })
    }
}

impl NoticeReceiver {
    /// The next notice; a superseded list's marker is skipped.
    pub async fn recv(&mut self) -> Option<Notice> {
        loop {
            let (peer, generation, item) = self.rx.recv().await?;
            match item {
                Item::Notice(notice) => return Some((peer, generation, notice)),
                Item::List(seq) => {
                    let key = (peer, generation);
                    if let Some(rows) = self.slots.take(&key, seq) {
                        return Some((key.0, key.1, PeerNotice::Sessions(rows)));
                    }
                }
            }
        }
    }
}

/// About the heap a JSON value holds: its nodes and text. Cheap next to parsing it.
fn approx_bytes(v: &Value) -> usize {
    const NODE: usize = std::mem::size_of::<Value>();
    NODE + match v {
        Value::String(s) => s.len(),
        Value::Array(a) => a.iter().map(approx_bytes).sum(),
        Value::Object(o) => o.iter().map(|(k, v)| k.len() + NODE + approx_bytes(v)).sum(),
        _ => 0,
    }
}

#[cfg(test)]
#[path = "peer_notice_queue_tests.rs"]
mod tests;
