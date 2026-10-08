//! Kitty quota changes from a smart host that evicted nothing (nx-scale 1b).
//!
//! The daemon divides one process image budget among its terminals by a
//! power-of-two capacity, so passing 2^k terminals changes the limits of
//! every existing host. A host answered every change with ResyncRequired and
//! the daemon reconnected each host from a fresh snapshot: N reconnects at
//! each doubling, plus one per launch. When the host's change evicted no
//! image, placement or upload, its ResyncRequired carries the new limits.
//! The mirror applies them to its own parser at the same stream position,
//! exactly as the host did, and keeps reading. If the mirror's own state
//! changes anyway, it reconnects as before.

use super::*;

impl PtySurface {
    /// Apply limits a smart host committed at this stream position. Returns
    /// whether the mirror kept its state; `false` means the caller reopens
    /// the host stream from a snapshot.
    pub(super) fn apply_host_kitty_graphics_limits(&self, limits: KittyGraphicsLimits) -> bool {
        let mut term = self.term.lock().unwrap();
        if term.kitty_upload_in_progress() {
            return false;
        }
        let Ok(generation) = term.kitty_image_generation() else { return false };
        if term.set_kitty_graphics_limits(limits).is_err()
            || term.kitty_image_generation().ok() != Some(generation)
        {
            return false;
        }
        *self.kitty_graphics_limits.lock().unwrap() = limits;
        // Attach mirrors carry the limits in their replay state.
        self.resynchronize_attach_taps_locked(&mut term);
        true
    }
}
