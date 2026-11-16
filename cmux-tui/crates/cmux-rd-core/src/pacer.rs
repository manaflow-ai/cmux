//! Pure scheduling for remote-desktop datagrams.
//!
//! [`Pacer`] keeps the original balanced frame pacing as its default.  An ultra
//! sender can opt into [`PacerPolicy::Strict`], which uses one integer token
//! bucket for every media, FEC, repair, and bandwidth-probe datagram.  The
//! bucket is charged the complete wire datagram length, including its header.
//! Control traffic has a separate, bounded queue so a handshake, input event,
//! or acknowledgement remains responsive without silently borrowing media
//! budget.

use std::collections::VecDeque;

use cmux_rd_proto::DatagramHeader;

/// The balanced pacing rate is at least this multiple of the target bitrate.
pub const PACING_FACTOR: f64 = 2.5;
/// A frame leaves within this share of the frame interval at most.
pub const SPREAD_SHARE: f64 = 0.5;
/// Balanced-mode burst allowance in microseconds of the rate.
pub const BURST_US: u64 = 2_000;
/// Balanced mode always sends at least this many datagrams per wakeup.
pub const MIN_BURST_DATAGRAMS: usize = 4;

const MICROBITS_PER_BYTE_US: u128 = 8_000_000;
const DEFAULT_BURST_BYTES: usize = 64 * 1024;
const DEFAULT_MAX_QUEUE_BYTES: usize = 4 * 1024 * 1024;
const DEFAULT_MAX_CONTROL_BYTES: usize = 64 * 1024;

/// The accounting class of a queued datagram.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DatagramClass {
    /// Encoded display or audio media.
    Media,
    /// Forward-error-correction parity for media.
    Fec,
    /// A loss-repair or retransmitted media datagram.
    Repair,
    /// Bandwidth or clock probe padding.
    Probe,
    /// Handshake, input, acknowledgement, or other tiny control traffic.
    Control,
}

impl DatagramClass {
    const fn is_budgeted(self) -> bool {
        !matches!(self, Self::Control)
    }
}

/// The transport-wide departure identifier carried by `DatagramHeader`.
pub type DepartureId = u16;

/// A datagram released by [`Pacer::due_with_metadata`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PacedDatagram {
    /// Complete wire bytes, including the cmux-rd header.
    pub datagram: Vec<u8>,
    /// The `DatagramHeader::transport_seq` for this departure.
    pub departure_id: DepartureId,
    /// The queue accounting class chosen by the sender.
    pub class: DatagramClass,
}

impl PacedDatagram {
    fn new(datagram: Vec<u8>, departure_id: DepartureId, class: DatagramClass) -> Self {
        Self { datagram, departure_id, class }
    }
}

/// Fixed-rate, bounded accounting for the opt-in ultra profile.
///
/// `rate_bps` is measured by the caller and then held.  `burst_bytes` bounds
/// the normal token allowance; a datagram larger than that allowance may still
/// be sent once enough tokens accrue.  `max_queue_bytes` bounds budgeted wire
/// bytes retained by the pacer, while `max_control_bytes` bounds the bypass
/// queue.  A zero rate intentionally never releases budgeted traffic.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StrictWireBudget {
    pub rate_bps: u64,
    pub burst_bytes: usize,
    pub max_queue_bytes: usize,
    pub max_control_bytes: usize,
}

impl StrictWireBudget {
    /// Builds a strict budget with conservative bounded defaults.
    pub const fn new(rate_bps: u64) -> Self {
        Self {
            rate_bps,
            burst_bytes: DEFAULT_BURST_BYTES,
            max_queue_bytes: DEFAULT_MAX_QUEUE_BYTES,
            max_control_bytes: DEFAULT_MAX_CONTROL_BYTES,
        }
    }

    /// Replaces all queue and burst limits while retaining the measured rate.
    pub const fn with_limits(
        rate_bps: u64,
        burst_bytes: usize,
        max_queue_bytes: usize,
        max_control_bytes: usize,
    ) -> Self {
        Self { rate_bps, burst_bytes, max_queue_bytes, max_control_bytes }
    }
}

/// Pacing policy selected by a profile.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PacerPolicy {
    /// Existing target-driven 2.5x pacing and burst behavior.
    Balanced,
    /// Fixed measured total-wire budget shared by all media classes.
    Strict(StrictWireBudget),
}

#[derive(Debug, Clone)]
struct QueuedDatagram {
    datagram: Vec<u8>,
    departure_id: DepartureId,
    class: DatagramClass,
}

impl QueuedDatagram {
    fn new(datagram: Vec<u8>, departure_id: DepartureId, class: DatagramClass) -> Self {
        Self { datagram, departure_id, class }
    }

    fn into_public(self) -> PacedDatagram {
        PacedDatagram::new(self.datagram, self.departure_id, self.class)
    }
}

/// A no-I/O pacer. The caller queues datagrams, drains [`Pacer::due`] (or its
/// metadata-preserving sibling), and wakes again at [`Pacer::next_deadline_us`].
#[derive(Debug)]
pub struct Pacer {
    /// Budgeted FIFO: in strict mode this is the one shared wire budget.
    queue: VecDeque<QueuedDatagram>,
    /// Strict-mode bypass queue for small control traffic.
    control_queue: VecDeque<QueuedDatagram>,
    queued_bytes: usize,
    control_queued_bytes: usize,
    policy: PacerPolicy,

    // Balanced-mode state is intentionally retained for compatibility.
    rate_bytes_per_us: f64,
    budget_bytes: f64,
    last_us: Option<u64>,

    // Strict mode uses integer tokens and a fractional numerator. This avoids
    // floating-point drift and never turns idle time into a burst.
    strict_credit_bytes: u64,
    strict_remainder: u64,
    strict_last_us: Option<u64>,
}

impl Default for Pacer {
    fn default() -> Self {
        Self {
            queue: VecDeque::new(),
            control_queue: VecDeque::new(),
            queued_bytes: 0,
            control_queued_bytes: 0,
            policy: PacerPolicy::Balanced,
            rate_bytes_per_us: 0.0,
            budget_bytes: 0.0,
            last_us: None,
            strict_credit_bytes: 0,
            strict_remainder: 0,
            strict_last_us: None,
        }
    }
}

impl Pacer {
    /// Creates the legacy balanced pacer.
    pub fn new() -> Self {
        Self::default()
    }

    /// Creates a pacer with an explicit profile policy.
    pub fn with_policy(policy: PacerPolicy) -> Self {
        Self { policy, ..Self::default() }
    }

    /// Creates a strict pacer for a measured ultra-link rate.
    pub fn strict(budget: StrictWireBudget) -> Self {
        Self::with_policy(PacerPolicy::Strict(budget))
    }

    /// Returns the selected policy.
    pub fn policy(&self) -> PacerPolicy {
        self.policy
    }

    /// Updates the measured rate for a strict budget without disturbing queued
    /// datagrams or the current credit. Balanced pacing ignores this setter.
    pub fn set_rate_bps(&mut self, rate_bps: u64) {
        if let PacerPolicy::Strict(mut config) = self.policy {
            config.rate_bps = rate_bps;
            self.policy = PacerPolicy::Strict(config);
        }
    }

    /// Queues one frame's media datagrams. In strict mode, `target_bps` and
    /// `frame_interval_us` are intentionally ignored: the measured strict
    /// rate is the one budget shared by media, FEC, repair, and probes.
    ///
    /// Frame datagrams produced by `Packetizer` carry their departure ID in the
    /// existing header; this method extracts that ID. Call the explicit
    /// `enqueue_*` methods when queueing a non-protocol test/datagram.
    pub fn push_frame(
        &mut self,
        datagrams: Vec<Vec<u8>>,
        target_bps: u64,
        frame_interval_us: u64,
        now_us: u64,
    ) {
        if matches!(self.policy, PacerPolicy::Strict(_)) {
            for datagram in datagrams {
                let departure_id = wire_departure_id(&datagram);
                let _ = self.enqueue_media(datagram, departure_id, now_us);
            }
            return;
        }

        if self.queue.is_empty() {
            // Idle: the frame's head goes at once.
            self.last_us = Some(now_us);
            self.budget_bytes = 0.0;
        }
        for datagram in datagrams {
            self.queued_bytes = self.queued_bytes.saturating_add(datagram.len());
            self.queue.push_back(QueuedDatagram::new(datagram, 0, DatagramClass::Media));
        }
        let window_us = (frame_interval_us as f64 * SPREAD_SHARE).max(1_000.0);
        let floor = target_bps as f64 * PACING_FACTOR / 8.0 / 1e6;
        let fit = self.queued_bytes as f64 / window_us;
        self.rate_bytes_per_us = floor.max(fit);
        if self.budget_bytes <= 0.0 {
            self.budget_bytes = self.burst_bytes();
        }
    }

    /// Queues a media datagram with its transport-wide departure ID.
    pub fn enqueue_media(
        &mut self,
        datagram: Vec<u8>,
        departure_id: DepartureId,
        now_us: u64,
    ) -> bool {
        self.enqueue_budgeted(datagram, departure_id, DatagramClass::Media, now_us)
    }

    /// Queues an FEC parity datagram against the same strict wire budget.
    pub fn enqueue_fec(
        &mut self,
        datagram: Vec<u8>,
        departure_id: DepartureId,
        now_us: u64,
    ) -> bool {
        self.enqueue_budgeted(datagram, departure_id, DatagramClass::Fec, now_us)
    }

    /// Queues a repair/retransmission datagram against the same strict budget.
    pub fn enqueue_repair(
        &mut self,
        datagram: Vec<u8>,
        departure_id: DepartureId,
        now_us: u64,
    ) -> bool {
        self.enqueue_budgeted(datagram, departure_id, DatagramClass::Repair, now_us)
    }

    /// Queues a bandwidth or clock probe against the same strict budget.
    pub fn enqueue_probe(
        &mut self,
        datagram: Vec<u8>,
        departure_id: DepartureId,
        now_us: u64,
    ) -> bool {
        self.enqueue_budgeted(datagram, departure_id, DatagramClass::Probe, now_us)
    }

    /// Queues a handshake, input, or acknowledgement datagram. Strict mode
    /// keeps these in a separate bounded queue and releases them before media.
    pub fn enqueue_control(
        &mut self,
        datagram: Vec<u8>,
        departure_id: DepartureId,
        now_us: u64,
    ) -> bool {
        if let PacerPolicy::Strict(config) = self.policy {
            let len = datagram.len();
            if len > config.max_control_bytes
                || self.control_queued_bytes > config.max_control_bytes.saturating_sub(len)
            {
                return false;
            }
            self.control_queued_bytes = self.control_queued_bytes.saturating_add(len);
            self.control_queue.push_back(QueuedDatagram::new(
                datagram,
                departure_id,
                DatagramClass::Control,
            ));
            // Control traffic does not start or refill the media clock.
            let _ = now_us;
            return true;
        }

        // Balanced mode preserves one FIFO and its historical pacing policy.
        if self.queue.is_empty() {
            self.last_us = Some(now_us);
            self.budget_bytes = 0.0;
        }
        self.queued_bytes = self.queued_bytes.saturating_add(datagram.len());
        self.queue.push_back(QueuedDatagram::new(datagram, departure_id, DatagramClass::Control));
        true
    }

    /// Queues a datagram by class. This is the common adapter for a sender
    /// that already has a class and `DatagramHeader::transport_seq`.
    pub fn enqueue_datagram(
        &mut self,
        datagram: Vec<u8>,
        departure_id: DepartureId,
        class: DatagramClass,
        now_us: u64,
    ) -> bool {
        if class.is_budgeted() {
            self.enqueue_budgeted(datagram, departure_id, class, now_us)
        } else {
            self.enqueue_control(datagram, departure_id, now_us)
        }
    }

    fn enqueue_budgeted(
        &mut self,
        datagram: Vec<u8>,
        departure_id: DepartureId,
        class: DatagramClass,
        now_us: u64,
    ) -> bool {
        debug_assert!(class.is_budgeted());
        if let PacerPolicy::Strict(config) = self.policy {
            let len = datagram.len();
            if len > config.max_queue_bytes
                || self.queued_bytes > config.max_queue_bytes.saturating_sub(len)
            {
                return false;
            }
            if self.queue.is_empty() {
                // A new busy period starts with no credit. Idle time never
                // accumulates into the next frame's burst.
                self.strict_last_us = Some(now_us);
                self.strict_credit_bytes = 0;
                self.strict_remainder = 0;
            }
        } else if self.queue.is_empty() {
            self.last_us = Some(now_us);
            self.budget_bytes = 0.0;
        }
        self.queued_bytes = self.queued_bytes.saturating_add(datagram.len());
        self.queue.push_back(QueuedDatagram::new(datagram, departure_id, class));
        true
    }

    fn burst_bytes(&self) -> f64 {
        let head = self.queue.front().map_or(0, |d| d.datagram.len()) as f64;
        (self.rate_bytes_per_us * BURST_US as f64).max(head * MIN_BURST_DATAGRAMS as f64)
    }

    /// The datagrams due now, in FIFO order. Metadata is discarded for this
    /// compatibility API; use [`Pacer::due_with_metadata`] for departure IDs.
    pub fn due(&mut self, now_us: u64) -> Vec<Vec<u8>> {
        self.due_with_metadata(now_us).into_iter().map(|datagram| datagram.datagram).collect()
    }

    /// The datagrams due now, retaining class and departure ID metadata.
    pub fn due_with_metadata(&mut self, now_us: u64) -> Vec<PacedDatagram> {
        if matches!(self.policy, PacerPolicy::Strict(_)) {
            return self.due_strict(now_us);
        }

        let mut out = Vec::new();
        if self.queue.is_empty() {
            return out;
        }
        let last = self.last_us.unwrap_or(now_us);
        let elapsed = now_us.saturating_sub(last) as f64;
        self.last_us = Some(now_us);
        self.budget_bytes = (self.budget_bytes + elapsed * self.rate_bytes_per_us)
            .min(self.burst_bytes().max(self.budget_bytes));
        while self.budget_bytes > 0.0 {
            let Some(datagram) = self.queue.pop_front() else { break };
            self.budget_bytes -= datagram.datagram.len() as f64;
            self.queued_bytes = self.queued_bytes.saturating_sub(datagram.datagram.len());
            out.push(datagram.into_public());
        }
        if self.queue.is_empty() {
            self.budget_bytes = 0.0;
        }
        out
    }

    fn due_strict(&mut self, now_us: u64) -> Vec<PacedDatagram> {
        let mut out = Vec::new();

        // Control is deliberately bounded and never consumes the strict wire
        // bucket. Drain it first so input/handshake remains responsive.
        while let Some(datagram) = self.control_queue.pop_front() {
            self.control_queued_bytes =
                self.control_queued_bytes.saturating_sub(datagram.datagram.len());
            out.push(datagram.into_public());
        }

        if self.queue.is_empty() {
            return out;
        }
        let last = self.strict_last_us.unwrap_or(now_us);
        self.refill_strict(now_us, last);
        while let Some(datagram) = self.queue.front() {
            let len = datagram.datagram.len() as u64;
            if self.strict_credit_bytes < len {
                break;
            }
            let Some(datagram) = self.queue.pop_front() else {
                break;
            };
            self.strict_credit_bytes -= len;
            self.queued_bytes = self.queued_bytes.saturating_sub(len as usize);
            out.push(datagram.into_public());
        }
        if self.queue.is_empty() {
            // Reset all token state at the end of a busy period. In particular,
            // a long idle gap cannot become an accumulated burst later.
            self.strict_credit_bytes = 0;
            self.strict_remainder = 0;
            self.strict_last_us = None;
        }
        out
    }

    fn refill_strict(&mut self, now_us: u64, last_us: u64) {
        let PacerPolicy::Strict(config) = self.policy else { return };
        let elapsed = now_us.saturating_sub(last_us) as u128;
        if config.rate_bps == 0 || elapsed == 0 {
            return;
        }
        let numerator = elapsed
            .saturating_mul(config.rate_bps as u128)
            .saturating_add(self.strict_remainder as u128);
        let added = numerator / MICROBITS_PER_BYTE_US;
        self.strict_remainder = (numerator % MICROBITS_PER_BYTE_US) as u64;
        let head_len = self.queue.front().map_or(0, |d| d.datagram.len());
        let cap = config.burst_bytes.max(head_len) as u128;
        let credit = (self.strict_credit_bytes as u128).saturating_add(added).min(cap);
        self.strict_credit_bytes = credit as u64;
        self.strict_last_us = Some(now_us);
    }

    /// When the next datagram is due (`None` while nothing is queued or a zero
    /// strict rate has no budgeted progress). Control traffic is immediately
    /// due in strict mode and is bounded by `max_control_bytes`.
    pub fn next_deadline_us(&self) -> Option<u64> {
        if let PacerPolicy::Strict(config) = self.policy {
            if !self.control_queue.is_empty() {
                return Some(self.strict_last_us.unwrap_or(0));
            }
            let head = self.queue.front()?.datagram.len() as u64;
            let last = self.strict_last_us?;
            if self.strict_credit_bytes >= head {
                return Some(last);
            }
            if config.rate_bps == 0 {
                return None;
            }
            let need = (head - self.strict_credit_bytes) as u128;
            let numerator = need
                .saturating_mul(MICROBITS_PER_BYTE_US)
                .saturating_sub(self.strict_remainder as u128);
            let wait = numerator
                .saturating_add(config.rate_bps as u128 - 1)
                .checked_div(config.rate_bps as u128)
                .unwrap_or(u128::MAX);
            let wait = wait.min(u64::MAX as u128) as u64;
            return Some(last.saturating_add(wait.max(1)));
        }

        self.queue.front()?;
        let last = self.last_us?;
        if self.budget_bytes > 0.0 {
            return Some(last);
        }
        let need = -self.budget_bytes + 1.0;
        let wait = (need / self.rate_bytes_per_us.max(1e-6)).ceil() as u64;
        Some(last.saturating_add(wait.max(1)))
    }

    /// Whether all queues are empty.
    pub fn is_empty(&self) -> bool {
        self.queue.is_empty() && self.control_queue.is_empty()
    }

    /// Total queued wire bytes, including bounded control traffic.
    pub fn queued_bytes(&self) -> usize {
        self.queued_bytes.saturating_add(self.control_queued_bytes)
    }

    /// Drops everything queued (the session ended).
    pub fn clear(&mut self) {
        self.queue.clear();
        self.control_queue.clear();
        self.queued_bytes = 0;
        self.control_queued_bytes = 0;
        self.budget_bytes = 0.0;
        self.strict_credit_bytes = 0;
        self.strict_remainder = 0;
        self.last_us = None;
        self.strict_last_us = None;
    }
}

fn wire_departure_id(datagram: &[u8]) -> DepartureId {
    // Packetizer output is always a valid cmux-rd datagram. A zero fallback
    // keeps the legacy infallible `push_frame` API usable for tests; callers
    // handling arbitrary wire bytes should use an explicit enqueue method.
    DatagramHeader::decode(datagram).map_or(0, |(header, _)| header.transport_seq)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strict_integer_refill_keeps_fractional_remainder() {
        let mut p = Pacer::strict(StrictWireBudget::with_limits(1, 64, 256, 64));
        assert!(p.enqueue_media(vec![0; 1], 7, 0));
        assert!(p.due_with_metadata(0).is_empty());
        assert!(p.due_with_metadata(1_000_000).is_empty());
        // One bit per second is one byte every eight seconds; the first byte is now due.
        assert_eq!(p.due_with_metadata(8_000_000).len(), 1);
    }
}
