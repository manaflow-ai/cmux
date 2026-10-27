//! One connection's replies after their events (p05-ipc-120;
//! cmux-tui/spec/transports.md "Reply and event order").
//!
//! A request whose handler emitted events, on a connection with live
//! `subscribe` streams, parks its reply in those streams' mailboxes behind
//! the events (`event_bus::park_reply`): the reply reaches the control FIFO
//! after them, and the request thread never waits. While a parked reply is
//! still out, later replies of the connection park too, so replies keep the
//! order the requests answered in.

use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use cmux_threads::sync::Mutex;

use crate::event_bus::{ReplyFenceTarget, park_reply};
use crate::panic_free::RecoverPoison;

/// The subscription mailboxes of one connection and its parked replies;
/// shared by every clone of its `MessageWriter`.
#[derive(Default)]
pub(super) struct ReplyOrder {
    targets: Mutex<Vec<ReplyFenceTarget>>,
    parked: AtomicUsize,
}

impl ReplyOrder {
    /// A `subscribe` stream of this connection: replies park behind it.
    pub(super) fn register(&self, target: ReplyFenceTarget) {
        let mut targets = self.targets.lock().recover_poison();
        targets.retain(ReplyFenceTarget::is_live);
        targets.push(target);
    }

    /// The mailboxes a reply must park in: `None` (send it now) unless the
    /// request `emitted` events or an earlier reply is still parked, and the
    /// connection has a live subscription.
    pub(super) fn fences_for(&self, emitted: bool) -> Option<Vec<ReplyFenceTarget>> {
        if !emitted && self.parked.load(Ordering::Acquire) == 0 {
            return None;
        }
        let mut targets = self.targets.lock().recover_poison();
        targets.retain(ReplyFenceTarget::is_live);
        (!targets.is_empty()).then(|| targets.clone())
    }

    /// Park `send` behind every event pending in `fences` now.
    pub(super) fn park(
        self: &Arc<Self>,
        fences: &[ReplyFenceTarget],
        send: impl FnOnce() + Send + Sync + 'static,
    ) {
        self.parked.fetch_add(1, Ordering::AcqRel);
        let order = Arc::clone(self);
        park_reply(
            fences,
            Box::new(move || {
                send();
                order.parked.fetch_sub(1, Ordering::AcqRel);
            }),
        );
    }
}
