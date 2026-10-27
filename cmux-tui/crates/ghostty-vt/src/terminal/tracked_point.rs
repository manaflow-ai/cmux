//! Tracked screen points and where their libghostty handles are freed.
//!
//! Freeing a tracked grid ref unlinks its pin from the terminal's page list
//! and its terminal's tracked-ref list (`ghostty-next`,
//! `src/terminal/c/grid_ref_tracked.zig`), so it must not run while another
//! thread uses that terminal. A [`TrackedScreenPoint`] may still drop
//! anywhere: its handle goes back to its terminal, which frees it under
//! `&mut Terminal`. This is Chrome's `SequencedTaskRunner::DeleteSoon`
//! (`base/task/sequenced_task_runner.h`): an object bound to one sequence is
//! destroyed on that sequence, whichever thread lets go of it.

use std::ptr;
use std::sync::mpsc::{self, Receiver, SendError, Sender};

use super::sys;

/// One tracked grid ref, non-null, owned by this value alone. It is dropped
/// in only two places: by its terminal under `&mut Terminal`
/// ([`AnchorReleases::free_released`]), or after that terminal's handle was
/// freed, which libghostty allows (`grid_ref_tracked.h`).
pub(super) struct AnchorHandle(sys::GhosttyTrackedGridRef);

impl Drop for AnchorHandle {
    fn drop(&mut self) {
        // SAFETY: a non-null ref from `ghostty_terminal_grid_ref_track`, freed
        // only here; where this drop runs is serialized with its terminal
        // (the type's docs).
        unsafe { sys::ghostty_tracked_grid_ref_free(self.0) };
    }
}

// SAFETY: the synchronization is the terminal's exclusive access. Whoever holds
// a handle never reads it; every read takes its originating `Terminal`, whose
// callers serialize. Its drop runs on the terminal under `&mut Terminal`
// (`free_released`), or once the terminal's libghostty handle is gone: the
// queue's `Receiver` is a `Terminal` field, dropped after `Terminal::drop` freed
// that handle, and it drops the handles still queued; a later `send` hands the
// handle back to its sender, ordered after that drop by the channel's atomics.
// Test: `terminal::tracked_point::tests::a_point_dropped_on_another_thread_is_freed_by_its_terminal`
// and `terminal::tracked_point::tests::a_point_outliving_its_terminal_frees_on_any_thread`.
unsafe impl Send for AnchorHandle {}

/// An owned terminal cell anchor that follows its row through scrollback
/// growth, pruning, and reflow. It may move to and drop on any thread: its
/// terminal frees the anchor (see the module docs).
pub struct TrackedScreenPoint {
    /// `Some` until drop.
    anchor: Option<AnchorHandle>,
    terminal_instance_id: u64,
    release: Sender<AnchorHandle>,
}

impl TrackedScreenPoint {
    /// The libghostty handle, for a call that holds the originating terminal.
    pub(super) fn raw(&self) -> sys::GhosttyTrackedGridRef {
        self.anchor.as_ref().map_or(ptr::null_mut(), |anchor| anchor.0)
    }

    pub(super) fn terminal_instance_id(&self) -> u64 {
        self.terminal_instance_id
    }
}

impl Drop for TrackedScreenPoint {
    fn drop(&mut self) {
        let Some(anchor) = self.anchor.take() else { return };
        if let Err(SendError(anchor)) = self.release.send(anchor) {
            // The queue closed: the terminal is gone, so the anchor frees here.
            drop(anchor);
        }
    }
}

/// A terminal's queue of anchors its dropped points gave back, made at its
/// first tracked point.
#[derive(Default)]
pub(super) struct AnchorReleases(Option<(Sender<AnchorHandle>, Receiver<AnchorHandle>)>);

impl AnchorReleases {
    /// A point owning `raw`, a non-null ref the terminal of
    /// `terminal_instance_id` just tracked.
    pub(super) fn point(
        &mut self,
        raw: sys::GhosttyTrackedGridRef,
        terminal_instance_id: u64,
    ) -> TrackedScreenPoint {
        let (release, _) = self.0.get_or_insert_with(mpsc::channel);
        TrackedScreenPoint {
            anchor: Some(AnchorHandle(raw)),
            terminal_instance_id,
            release: release.clone(),
        }
    }

    /// Frees the anchors of the points dropped since the last call and
    /// returns how many. The caller holds `&mut Terminal`.
    pub(super) fn free_released(&mut self) -> usize {
        let Some((_, released)) = &self.0 else { return 0 };
        let mut freed = 0;
        for anchor in released.try_iter() {
            drop(anchor);
            freed += 1;
        }
        freed
    }
}

#[cfg(test)]
mod tests {
    use crate::{Callbacks, Terminal};

    fn terminal() -> Terminal {
        let mut terminal = Terminal::new(20, 5, 0, Callbacks::default()).expect("terminal");
        terminal.vt_write(b"hello\r\nworld");
        terminal
    }

    /// A point dropped on another thread no longer frees its anchor there
    /// (that raced with the terminal's writer in cmux-tui's selection): its
    /// terminal frees it at its next tracked point, under `&mut Terminal`.
    #[test]
    fn a_point_dropped_on_another_thread_is_freed_by_its_terminal() {
        let mut terminal = terminal();
        let point = terminal.track_screen_point(1, 1).expect("tracked");
        assert_eq!(terminal.tracked_screen_point(&point), Some((1, 1)));
        assert_eq!(terminal.tracked_points.free_released(), 0, "nothing dropped yet");
        std::thread::spawn(move || drop(point)).join().expect("drop thread");
        terminal.vt_write(b"\r\nmore output");
        assert_eq!(terminal.tracked_points.free_released(), 1, "the terminal frees it");
        let next = terminal.track_screen_point(0, 0).expect("tracked again");
        assert_eq!(terminal.tracked_screen_point(&next), Some((0, 0)));
        std::thread::spawn(move || drop(terminal)).join().expect("terminal drop thread");
        drop(next);
    }

    /// A point that outlives its terminal frees its anchor on whichever
    /// thread drops it (libghostty allows a free after the terminal's), and
    /// anchors still queued when the terminal drops are freed with it.
    #[test]
    fn a_point_outliving_its_terminal_frees_on_any_thread() {
        let mut terminal = terminal();
        let queued = terminal.track_screen_point(0, 0).expect("tracked");
        let outliving = terminal.track_screen_point(2, 1).expect("tracked");
        drop(queued);
        drop(terminal);
        std::thread::spawn(move || drop(outliving)).join().expect("drop thread");
    }
}
