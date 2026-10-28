//! Hiding a snapshot viewer (`set-stream-priority hidden`).

use super::{AttachFrameReceiver, AttachTapQueue, AttachTapState};
use crate::panic_free::RecoverPoison;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Weak};

/// Hides a snapshot viewer, as Chrome's `WasHidden()` stops a
/// hidden widget's frames while its renderer keeps running
/// (content/browser/renderer_host/render_widget_host_impl.cc): the terminal
/// still parses every byte, the viewer queues none of it and is not woken,
/// and it owes one READY when it shows if anything changed meanwhile. A
/// viewer that changed nothing continues at its offset.
#[derive(Clone)]
pub(crate) struct TapVisibility {
    state: Weak<AttachTapState>,
}

impl TapVisibility {
    /// No-op for a replay viewer, which resyncs only by replay.
    pub(crate) fn set_hidden(&self, hidden: bool) {
        let Some(state) = self.state.upgrade() else { return };
        let mut queue = state.queue.lock().recover_poison();
        if !queue.snapshot_mode || state.hidden.load(Ordering::Acquire) == hidden {
            return;
        }
        state.hidden.store(hidden, Ordering::Release);
        if hidden {
            if !queue.frames.is_empty() {
                queue.mark_dirty();
            }
            return;
        }
        let pending = queue.needs_snapshot || !queue.frames.is_empty();
        drop(queue);
        if pending {
            state.wake_one();
        }
    }
}

impl AttachTapQueue {
    /// A hidden viewer's output: dropped, and the viewer owes a READY when
    /// it shows. Not a backlog resync.
    pub(super) fn mark_dirty(&mut self) {
        self.frames.clear();
        self.retained_bytes = 0;
        self.needs_snapshot = true;
        self.snapshot_deferred = false;
    }
}

impl AttachFrameReceiver {
    /// Hides and shows this viewer from outside its drain
    /// (`set-stream-priority`). Holds no strong reference to the queue.
    pub(crate) fn visibility_handle(&self) -> TapVisibility {
        TapVisibility { state: Arc::downgrade(&self.state) }
    }

    /// The surface is gone: nothing will be queued any more. A hidden
    /// viewer reads only this, so it still ends with its surface.
    pub(crate) fn is_disconnected(&self) -> bool {
        !self.state.queue.lock().recover_poison().sender_alive
    }
}
