//! The keyframe gate of one display stream: when a loss may cost an IDR, and
//! how large that IDR may be.
//!
//! A loss keyframe (a viewer's recovery request, or a tail probe that ran out)
//! is the most expensive frame the host sends: three to ten times a P-frame,
//! in one burst. On a congested path that burst causes the next loss, whose
//! recovery is another keyframe, and the stream stops (measured on a Mac pair:
//! 13 to 39 IDRs per 10 s and about 0 fps at every pinned rate from 20 to
//! 150 Mbps). Three rules break that loop:
//!
//! - **Repair first.** A keyframe the viewer has not acknowledged yet is still
//!   being received or NACK-repaired. A recovery request that arrives meanwhile
//!   was sent before that keyframe could land (or while it was repairing), so
//!   it is held until the viewer acknowledges the keyframe or the keyframe's
//!   repair window ([`IDR_REPAIR_WAIT_US`] plus a round trip) has passed.
//! - **Spacing.** Two loss keyframes are at least [`MIN_FORCED_IDR_INTERVAL_US`]
//!   apart. A recovery request checks it; a tail probe's keyframe needs no
//!   check (its probes restart with every frame sent, so it comes a second
//!   after the last one) but counts for the next recovery's spacing.
//! - **Size.** A loss keyframe asks the encoder for a rate at which it takes
//!   at most [`IDR_SEND_BUDGET_US`] of the target to send, from the size the
//!   last one came out at; the next P-frame asks for the full target again.
//!
//! Session start, resize and a frame too large to packetize are not loss
//! keyframes: the stream cannot continue without them, so they pass.

/// Shortest time between two keyframes asked for after a loss.
pub const MIN_FORCED_IDR_INTERVAL_US: u64 = 250_000;
/// How long the viewer may take to receive and repair a keyframe, besides
/// the round trip: the viewer's reassembly deadline (200 ms) is when it gives
/// a frame up, so before that the keyframe may still be repaired by NACK.
pub const IDR_REPAIR_WAIT_US: u64 = 200_000;
/// Longest a held keyframe waits for its acknowledgement, at any round trip.
pub const MAX_IDR_REPAIR_WAIT_US: u64 = 1_000_000;
/// A loss keyframe should leave in at most this much of the target rate.
pub const IDR_SEND_BUDGET_US: u64 = 100_000;
/// A loss keyframe's rate is never cut below this share of the target.
pub const MIN_IDR_RATE_DIVISOR: u32 = 4;

/// Why the engine did not answer a loss with a keyframe now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IdrHold {
    /// Keyframe `frame` is not acknowledged yet and may still be repaired.
    Repairing { frame: u32 },
    /// The last loss keyframe went out less than [`MIN_FORCED_IDR_INTERVAL_US`] ago.
    Spacing,
}

impl IdrHold {
    pub fn as_str(self) -> &'static str {
        match self {
            IdrHold::Repairing { .. } => "repairing",
            IdrHold::Spacing => "spacing",
        }
    }
}

/// One stream's keyframe gate. Times are the engine's clock in microseconds.
#[derive(Debug, Default, Clone)]
pub struct IdrGate {
    /// When the engine last asked for a loss keyframe.
    last_forced_us: Option<u64>,
    /// The newest keyframe sent and not yet acknowledged, and when it went out.
    unacked: Option<(u32, u64)>,
    /// The last loss keyframe's size and the rate it was asked for at.
    last_loss_idr: Option<(usize, u32)>,
    /// Loss keyframes held back, for the stats.
    held: u64,
}

impl IdrGate {
    /// A keyframe (any reason, the encoder's own too) went out as `frame`.
    pub fn on_keyframe_sent(&mut self, frame: u32, now_us: u64) {
        self.unacked = Some((frame, now_us));
    }

    /// A loss keyframe of `bytes` came out of a request at `kbps`.
    pub fn on_loss_keyframe_sized(&mut self, bytes: usize, kbps: u32) {
        if bytes > 0 && kbps > 0 {
            self.last_loss_idr = Some((bytes, kbps));
        }
    }

    /// The viewer released every frame up to `acked_frame`.
    pub fn on_ack(&mut self, acked_frame: u32) {
        if self.unacked.is_some_and(|(frame, _)| acked_frame >= frame) {
            self.unacked = None;
        }
    }

    fn repair_wait_us(rtt_us: u64) -> u64 {
        IDR_REPAIR_WAIT_US
            .saturating_add(rtt_us)
            .clamp(MIN_FORCED_IDR_INTERVAL_US, MAX_IDR_REPAIR_WAIT_US)
    }

    /// Whether a loss may be answered with a keyframe now.
    pub fn check(&self, now_us: u64, rtt_us: u64) -> Result<(), IdrHold> {
        if let Some((frame, sent_us)) = self.unacked
            && now_us.saturating_sub(sent_us) < Self::repair_wait_us(rtt_us)
        {
            return Err(IdrHold::Repairing { frame });
        }
        if self
            .last_forced_us
            .is_some_and(|t| now_us.saturating_sub(t) < MIN_FORCED_IDR_INTERVAL_US)
        {
            return Err(IdrHold::Spacing);
        }
        Ok(())
    }

    /// Records a held loss keyframe.
    pub fn note_held(&mut self) {
        self.held = self.held.saturating_add(1);
    }

    /// Loss keyframes held back so far.
    pub fn held(&self) -> u64 {
        self.held
    }

    /// The engine asks for a loss keyframe now.
    pub fn on_forced(&mut self, now_us: u64) {
        self.last_forced_us = Some(now_us);
    }

    /// The rate to ask a loss keyframe at, for a `target_kbps` stream: the
    /// target, or lower when the last loss keyframe came out larger than
    /// [`IDR_SEND_BUDGET_US`] of the target, never under a quarter of it.
    pub fn bounded_kbps(&self, target_kbps: u32) -> u32 {
        let Some((bytes, kbps)) = self.last_loss_idr else { return target_kbps };
        let budget = u64::from(target_kbps) * IDR_SEND_BUDGET_US / 8_000;
        let bytes = bytes as u64;
        if bytes <= budget {
            return target_kbps;
        }
        // Size follows the asked rate: bytes per kbps from the last one.
        let fit = u64::from(kbps).saturating_mul(budget) / bytes.max(1);
        let floor = target_kbps / MIN_IDR_RATE_DIVISOR;
        u32::try_from(fit).unwrap_or(u32::MAX).clamp(floor.max(1), target_kbps.max(1))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_unacknowledged_keyframe_holds_recovery_until_its_repair_window_ends() {
        let mut g = IdrGate::default();
        g.on_keyframe_sent(7, 1_000_000);
        let rtt = 150_000;
        assert_eq!(g.check(1_349_999, rtt), Err(IdrHold::Repairing { frame: 7 }));
        assert_eq!(g.check(1_350_000, rtt), Ok(()));
    }

    #[test]
    fn an_acknowledged_keyframe_releases_the_hold_and_spacing_remains() {
        let mut g = IdrGate::default();
        g.on_forced(0);
        g.on_keyframe_sent(3, 0);
        g.on_ack(2);
        assert!(matches!(g.check(100_000, 0), Err(IdrHold::Repairing { frame: 3 })));
        g.on_ack(3);
        assert_eq!(g.check(100_000, 0), Err(IdrHold::Spacing));
        assert_eq!(g.check(MIN_FORCED_IDR_INTERVAL_US, 0), Ok(()));
    }

    #[test]
    fn a_large_loss_keyframe_lowers_the_next_ones_rate_within_bounds() {
        let mut g = IdrGate::default();
        assert_eq!(g.bounded_kbps(20_000), 20_000, "nothing known yet");
        // 20 Mbps for 100 ms is 250 KB; the last one was 500 KB at 20 Mbps.
        g.on_loss_keyframe_sized(500_000, 20_000);
        assert_eq!(g.bounded_kbps(20_000), 10_000);
        // Never under a quarter of the target.
        g.on_loss_keyframe_sized(5_000_000, 20_000);
        assert_eq!(g.bounded_kbps(20_000), 5_000);
        // One that fits leaves the target alone.
        g.on_loss_keyframe_sized(100_000, 20_000);
        assert_eq!(g.bounded_kbps(20_000), 20_000);
    }
}
