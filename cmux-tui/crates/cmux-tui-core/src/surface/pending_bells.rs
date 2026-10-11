//! Bells rung by the parser, published after the terminal lock is released.

use super::*;
use std::sync::atomic::AtomicUsize;

/// BEL count recorded by a parser callback. `on_bell` runs inside `vt_write`
/// under the terminal lock, and `Mux::emit_terminal_bell` takes `Mux::state`,
/// which is ordered before that lock (see [`PtyTerminalRuntime`]). So the
/// callback only counts, and the reader publishes after it unlocks.
#[derive(Clone, Default)]
pub(super) struct PendingBells(Arc<AtomicUsize>);

impl PendingBells {
    /// The parser's `on_bell` callback: count one bell, never call out.
    pub(super) fn callback(&self) -> Box<dyn FnMut() + Send> {
        let rung = self.0.clone();
        Box::new(move || {
            rung.fetch_add(1, Ordering::AcqRel);
        })
    }

    /// Emit one `Bell` event per counted bell. Call without the terminal or
    /// geometry lock held.
    pub(super) fn publish(&self, mux: &Weak<Mux>, surface: SurfaceId) {
        let rung = self.0.swap(0, Ordering::AcqRel);
        if rung == 0 {
            return;
        }
        if let Some(mux) = mux.upgrade() {
            for _ in 0..rung {
                mux.emit_terminal_bell(surface);
            }
        }
    }
}
