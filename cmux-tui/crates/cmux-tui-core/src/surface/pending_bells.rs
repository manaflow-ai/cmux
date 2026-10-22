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
    /// The terminal host reports bells (its Bell frames, perf100 cut 1): the
    /// mirror's parser callback then counts nothing.
    from_host: Arc<AtomicBool>,
    /// When this terminal's last bell posted its attention notification (cx-on7iu).
    notified_at: Arc<Mutex<Option<Instant>>>,
}

impl PendingBells {
    /// The parser's `on_bell` callback: count one bell, never call out.
    pub(super) fn callback(&self) -> Box<dyn FnMut() + Send> {
        let rung = self.rung.clone();
        let from_host = self.from_host.clone();
        Box::new(move || {
            if !from_host.load(Ordering::Acquire) {
                rung.fetch_add(1, Ordering::AcqRel);
            }
        })
    }

    /// Whether bells come from the host's Bell frames (true) or from the
    /// mirror's parser (false), for the current host connection.
    pub(super) fn set_from_host(&self, from_host: bool) {
        self.from_host.store(from_host, Ordering::Release);
    }

    /// One bell the host reported (a Bell frame).
    pub(super) fn ring(&self) {
        self.rung.fetch_add(1, Ordering::AcqRel);
    }

    /// Emit one `Bell` event per counted bell, and mark the terminal's tab for
    /// attention like a notification (at most once per cooldown). Call without
    /// the terminal or geometry lock held.
    pub(super) fn publish(&self, mux: &Weak<Mux>, surface: SurfaceId) {
        let rung = self.rung.swap(0, Ordering::AcqRel);
        if rung == 0 {
            return;
        }
        if let Some(mux) = mux.upgrade() {
            for _ in 0..rung {
                mux.emit_terminal_bell(surface);
            }
            if self.notification_due(Instant::now()) {
                mux.post_bell_notification(surface);
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
