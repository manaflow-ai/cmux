//! Replies queued behind the events their request emitted (p05-ipc-120;
//! cmux-tui/spec/transports.md "Reply and event order").
//!
//! A request emits its events into each subscriber's mailbox; the
//! subscription thread moves them to the connection's writer later. A reply
//! the request thread wrote at once could overtake them. Instead the request
//! parks its reply in every mailbox of its connection's subscriptions, after
//! the events already there; whichever subscription thread releases the last
//! park sends the reply, so it reaches the one control FIFO after every event
//! emitted before it. Mojo gives Chrome the same order on one message pipe
//! (mojo/core/channel.cc writes messages in send order); here the mailbox is
//! that pipe, and nothing waits.
//!
//! A park that is dropped without being reached (the mailbox closes, its
//! subscription ends) releases too, so a reply is never lost.

use std::sync::{Arc, Weak};

use super::MuxEventMailbox;

/// The send of one parked reply, run once by whoever releases it last.
struct ReplySend(Box<dyn FnOnce() + Send + Sync>);

/// One mailbox's hold on a parked reply. Dropping it releases that hold.
pub(super) struct ParkedReply(Option<Arc<ReplySend>>);

impl Drop for ParkedReply {
    fn drop(&mut self) {
        // `Arc::into_inner` returns the value to exactly one of the holds
        // released concurrently: the last one.
        if let Some(send) = self.0.take().and_then(Arc::into_inner) {
            (send.0)();
        }
    }
}

/// A subscription mailbox a reply can be parked in. Holds the mailbox
/// weakly: a connection's writer must not keep a finished subscription's
/// mailbox alive.
#[derive(Clone)]
pub(crate) struct ReplyFenceTarget(Weak<MuxEventMailbox>);

impl ReplyFenceTarget {
    pub(super) fn of(mailbox: &Arc<MuxEventMailbox>) -> Self {
        Self(Arc::downgrade(mailbox))
    }

    /// False once the subscription's receiver is gone (no mailbox lock: a
    /// closed but live mailbox refuses the park and releases it at once).
    pub(crate) fn is_live(&self) -> bool {
        self.0.strong_count() > 0
    }
}

/// Park `send` behind every event now queued in each of `targets`; it runs
/// once every target delivered what was ahead of it (or closed). With no
/// open target it runs now, on this thread.
pub(crate) fn park_reply(targets: &[ReplyFenceTarget], send: Box<dyn FnOnce() + Send + Sync>) {
    let send = Arc::new(ReplySend(send));
    for target in targets {
        let Some(mailbox) = target.0.upgrade() else { continue };
        let park = ParkedReply(Some(send.clone()));
        if let Err(park) = mailbox.park(park) {
            drop(park);
        }
    }
    drop(ParkedReply(Some(send)));
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::super::MuxEventBroadcaster;
    use super::*;
    use crate::MuxEvent;
    use crate::stream_interrupt::StreamInterrupt;

    fn counting_send(sent: &Arc<AtomicUsize>) -> Box<dyn FnOnce() + Send + Sync> {
        let sent = sent.clone();
        Box::new(move || {
            sent.fetch_add(1, Ordering::SeqCst);
        })
    }

    #[test]
    fn a_parked_reply_goes_out_after_the_events_queued_before_it() {
        let bus = MuxEventBroadcaster::default();
        let (first, second) = (bus.subscribe(), bus.subscribe());
        bus.emit(MuxEvent::TreeChanged);
        let sent = Arc::new(AtomicUsize::new(0));
        let targets = [first.reply_fence_target(), second.reply_fence_target()];
        park_reply(&targets, counting_send(&sent));
        bus.emit(MuxEvent::TreeSelectionChanged);

        let interrupt = StreamInterrupt::new();
        assert!(matches!(first.recv_until_interrupted(&interrupt), Ok(MuxEvent::TreeChanged)));
        assert_eq!(sent.load(Ordering::SeqCst), 0, "the reply waits for its event");
        assert!(matches!(
            first.recv_until_interrupted(&interrupt),
            Ok(MuxEvent::TreeSelectionChanged)
        ));
        assert_eq!(sent.load(Ordering::SeqCst), 0, "the other subscription still holds it");
        assert!(matches!(second.recv_until_interrupted(&interrupt), Ok(MuxEvent::TreeChanged)));
        assert!(matches!(
            second.recv_until_interrupted(&interrupt),
            Ok(MuxEvent::TreeSelectionChanged)
        ));
        assert_eq!(sent.load(Ordering::SeqCst), 1, "sent once, after both delivered");
    }

    /// A later event with the same coalesce key folds into the request's own
    /// event: the merged event keeps its place before the reply.
    #[test]
    fn a_coalesced_event_merged_after_the_park_still_goes_out_before_the_reply() {
        let bus = MuxEventBroadcaster::default();
        let receiver = bus.subscribe();
        bus.emit(MuxEvent::ConfigReloadRequested);
        let sent = Arc::new(AtomicUsize::new(0));
        park_reply(&[receiver.reply_fence_target()], counting_send(&sent));
        bus.emit(MuxEvent::ConfigReloadRequested);
        bus.emit(MuxEvent::TreeChanged);

        let interrupt = StreamInterrupt::new();
        assert!(matches!(
            receiver.recv_until_interrupted(&interrupt),
            Ok(MuxEvent::ConfigReloadRequested)
        ));
        assert_eq!(sent.load(Ordering::SeqCst), 0, "the reply waits for its merged event");
        assert!(matches!(receiver.recv_until_interrupted(&interrupt), Ok(MuxEvent::TreeChanged)));
        assert_eq!(sent.load(Ordering::SeqCst), 1, "sent after the merged event");
        assert!(receiver.try_recv().is_err(), "the two reloads were one event");
    }

    #[test]
    fn a_closed_or_dropped_subscription_never_strands_a_reply() {
        let bus = MuxEventBroadcaster::default();
        let (closed, dropped) = (bus.subscribe(), bus.subscribe());
        bus.emit(MuxEvent::TreeChanged);
        let sent = Arc::new(AtomicUsize::new(0));
        park_reply(&[closed.reply_fence_target()], counting_send(&sent));
        closed.close();
        assert_eq!(sent.load(Ordering::SeqCst), 1, "closing releases the reply");

        park_reply(&[dropped.reply_fence_target()], counting_send(&sent));
        drop(dropped);
        assert_eq!(sent.load(Ordering::SeqCst), 2, "dropping the receiver releases it");

        park_reply(&[closed.reply_fence_target()], counting_send(&sent));
        assert_eq!(sent.load(Ordering::SeqCst), 3, "a closed mailbox refuses the park");
    }
}
