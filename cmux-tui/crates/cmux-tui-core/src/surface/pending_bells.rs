//! Bells rung by the parser, published after the terminal lock is released.

use super::*;
use std::sync::atomic::AtomicUsize;

/// The least time between two bell notifications of one terminal: a program that rings in a loop
/// marks its tab once, not once per BEL.
const BELL_NOTIFICATION_COOLDOWN: Duration = Duration::from_secs(10);

/// BEL count recorded by a parser callback. `on_bell` runs inside `vt_write`
/// under the terminal lock, and `Mux::emit_terminal_bell` takes `Mux::state`,
/// which is ordered before that lock (see [`PtyTerminalRuntime`]). So the
/// callback only counts, and the reader publishes after it unlocks.
#[derive(Clone, Default)]
pub(super) struct PendingBells {
    rung: Arc<AtomicUsize>,
    /// When this terminal's last bell posted its attention notification (cx-on7iu).
    notified_at: Arc<Mutex<Option<Instant>>>,
}

impl PendingBells {
    /// The parser's `on_bell` callback: count one bell, never call out.
    pub(super) fn callback(&self) -> Box<dyn FnMut() + Send> {
        let rung = self.rung.clone();
        Box::new(move || {
            rung.fetch_add(1, Ordering::AcqRel);
        })
    }

    /// Emit one `Bell` event for the bells counted since the last publish (one
    /// read), and mark the terminal's tab for attention like a notification (at
    /// most once per cooldown). A read full of BEL bytes is one event: each
    /// event takes `Mux::state` and a slot in every subscriber's mailbox. Call
    /// without the terminal or geometry lock held.
    pub(super) fn publish(&self, mux: &Weak<Mux>, surface: SurfaceId) {
        let rung = self.rung.swap(0, Ordering::AcqRel);
        if rung == 0 {
            return;
        }
        if let Some(mux) = mux.upgrade() {
            mux.emit_terminal_bell(surface);
            // The mark is a durable notification: the terminal publisher
            // commits it, not the reader (#35413).
            if self.notification_due(Instant::now()) {
                mux.queue_bell_notification(surface);
            }
        }
    }

    /// Whether a bell at `now` posts a notification, recording it when it does.
    fn notification_due(&self, now: Instant) -> bool {
        let mut notified_at =
            self.notified_at.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if notified_at
            .is_some_and(|at| now.saturating_duration_since(at) < BELL_NOTIFICATION_COOLDOWN)
        {
            return false;
        }
        *notified_at = Some(now);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// One read that holds thousands of BEL bytes is one `Bell` event, not one per byte: each
    /// event takes `Mux::state` and fills every subscriber's mailbox.
    #[test]
    fn a_read_with_many_bells_publishes_one_bell_event() {
        let mux = Mux::new_for_test("bells", SurfaceOptions::default());
        let source = mux.new_workspace(None, Some((80, 24))).unwrap();
        let events = mux.subscribe();
        let bells = PendingBells::default();
        let mut ring = bells.callback();
        for _ in 0..10_000 {
            ring();
        }
        bells.publish(&Arc::downgrade(&mux), source.id);
        assert!(!events.overflowed(), "one read of bells closed the subscriber");
        let mut published = 0;
        while let Ok(event) = events.try_recv() {
            if matches!(event, MuxEvent::Bell(surface) if surface == source.id) {
                published += 1;
            }
        }
        assert_eq!(published, 1);
    }
}
