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

    /// Emit one `Bell` event per counted bell, and mark the terminal's tab for
    /// attention like a notification (at most once per cooldown). Call without
    /// the terminal or geometry lock held. The notification is a registry
    /// commit, which the output thread calling this may not make: it goes to
    /// the terminal's publication sequence, as its other notifications do
    /// ([`Surface::post_output_notifications`]).
    pub(super) fn publish(&self, mux: &Weak<Mux>, surface: &Surface) {
        let rung = self.rung.swap(0, Ordering::AcqRel);
        if rung == 0 {
            return;
        }
        if let Some(mux) = mux.upgrade() {
            for _ in 0..rung {
                mux.emit_terminal_bell(surface.id);
            }
            if self.notification_due(Instant::now()) {
                surface.post_bell_notification();
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
