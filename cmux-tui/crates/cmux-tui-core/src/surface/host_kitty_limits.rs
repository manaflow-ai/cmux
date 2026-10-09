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
        // The requester may already have stored these limits when the early
        // acknowledgement arrived (`set_kitty_graphics_limits_until`), before
        // this reader reached the frame. That window is harmless: the field
        // only answers "is this request already applied", and the mirror's
        // parser changes here, at the host's stream position.
        *self.kitty_graphics_limits.lock().unwrap() = limits;
        // Attach mirrors carry the limits in their replay state.
        self.resynchronize_attach_taps_locked(&mut term);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn resync(payload: Vec<u8>) -> Frame {
        let mut frame = Frame::new(MessageKind::ResyncRequired, payload);
        frame.sequence = 1;
        frame
    }

    fn encoded(limits: KittyGraphicsLimits) -> Vec<u8> {
        [limits.image_bytes, limits.inflight_bytes, limits.images, limits.placements]
            .iter()
            .flat_map(|value| value.to_le_bytes())
            .collect()
    }

    fn staged(smart: bool, payload: Vec<u8>) -> HostedTransition {
        HostedFrameStager::new(0, smart).push(resync(payload)).unwrap().unwrap()
    }

    /// Only a smart connection applies a limits payload in place; an empty
    /// payload (older host), an attach gap, a payload of another size or
    /// out-of-range limits reconnect as before.
    #[test]
    fn only_valid_limits_on_a_smart_stream_skip_the_reconnect() {
        let limits = KittyGraphicsLimits::disabled();
        assert!(matches!(
            staged(true, encoded(limits)),
            HostedTransition::KittyGraphicsLimits(applied) if applied == limits
        ));
        assert!(matches!(staged(false, encoded(limits)), HostedTransition::ResyncRequired));
        assert!(matches!(staged(true, Vec::new()), HostedTransition::ResyncRequired));
        assert!(matches!(staged(true, vec![0; 9]), HostedTransition::ResyncRequired));
        assert!(matches!(staged(true, vec![0; 17]), HostedTransition::ResyncRequired));
        assert!(matches!(staged(true, vec![0; 33]), HostedTransition::ResyncRequired));
        let out_of_range = KittyGraphicsLimits { images: u64::MAX, ..limits };
        assert!(out_of_range.validate().is_err());
        assert!(matches!(staged(true, encoded(out_of_range)), HostedTransition::ResyncRequired));
    }
}
