//! Spreads a frame's datagrams over a short window instead of one burst. A
//! keyframe is hundreds of datagrams; written back to back they arrive at a
//! Wi-Fi radio or a switch port faster than it drains, so the tail is queued
//! (read as delay by congestion control) or dropped (read as loss, and
//! repaired a round trip later). The pacer releases them at a rate above
//! the target bitrate, fast enough that a frame still leaves within a
//! fraction of its frame interval, with a small burst allowance so one wakeup
//! sends several datagrams. No I/O: the caller pushes a frame, asks what is
//! due, and wakes at `next_deadline_us`.
//!
//! Repairs (NACK resends and tail-loss probes) go through the same pacer, ahead
//! of queued frames, under the same rule: a 64-datagram resend written back to
//! back is lost the way a keyframe burst is (design D6, cmuxterm-hq
//! docs/design/screen-share-under-100ms.md).
//!
//! Why a large frame raises the rate rather than taking longer than half a frame
//! interval: pacing a keyframe at only 2.5 times a target that loss has cut held
//! recovery keyframes and their repairs past the viewer's deadline. On the
//! Wi-Fi-away netem profile that meant 31 recovery keyframes instead of 2, and a
//! key-to-decoded p95 of 272 ms instead of 132 ms. That deadline ran from a frame's
//! first shard; it now runs from its newest. Raised without a bound, a 1080p motion
//! keyframe (0.5 MB) left in 8 ms, about 550 Mbit/s, and a bottleneck of under
//! 20 Mbit/s dropped its tail every time (hq#19915), so the raise stops at
//! [`LARGE_FRAME_FACTOR`] times the target.
//!
//! An ultra sender can opt into [`PacerPolicy::Strict`], which uses one integer
//! token bucket for every media, FEC, repair, and bandwidth-probe datagram. The
//! bucket is charged the complete wire datagram length, including its header.
//! Control traffic has a separate, bounded queue so a handshake, input event,
//! or acknowledgement remains responsive without silently borrowing media
//! budget. The balanced policy above stays the default.

use std::collections::VecDeque;

use cmux_rd_proto::DatagramHeader;

/// The balanced pacing rate is at least this multiple of the target bitrate.
pub const PACING_FACTOR: f64 = 2.5;
/// What is queued (repairs, frames) leaves within this share of the frame interval
/// at most (the rate rises to fit a large frame: a keyframe).
pub const SPREAD_SHARE: f64 = 0.5;
/// ... and within this many microseconds whatever the frame rate. The send stage
/// adds its span to every frame's glass-to-glass time, so it is bounded in time,
/// not only as a share of the interval: at 30 fps half an interval is 16.7 ms
/// and an at-budget frame took 11.4 ms to leave (goal screen-share-rate-control,
/// "Send stage p50 at most 8 ms at any rate").
pub const MAX_SPREAD_US: f64 = 8_000.0;
/// A large frame (a keyframe) raises the rate to leave within [`MAX_SPREAD_US`], but to
/// at most this multiple of the target bitrate ...
///
/// Uncapped, a 1080p motion keyframe (0.5 MB) left in 8 ms, about 550 Mbit/s, on a path
/// of under 20 Mbit/s: the bottleneck dropped its tail, every keyframe lost datagrams,
/// each loss asked for another keyframe, and a Linux host to Mac viewer showed 3 fps with
/// 20 % loss (hq#19915). An at-budget frame (a P-frame at the target's per-frame size)
/// needs under 4.2 times the target at 30 fps, so it still leaves within 8 ms.
pub const LARGE_FRAME_FACTOR: f64 = 6.0;
/// ... unless that would take longer than this: a frame still leaves well inside the
/// viewer's reassembly deadline (200 ms from its newest shard).
pub const MAX_LARGE_SPREAD_US: f64 = 150_000.0;
/// Burst allowance: what one wakeup may send at once, in microseconds of the rate.
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

    /// A frame's own datagram (what `push_frame` queues), as opposed to a repair,
    /// probe or control datagram.
    const fn is_frame(self) -> bool {
        matches!(self, Self::Media | Self::Fec)
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
    /// Strict mode: the ordinal of the `push_frame` call that queued it (0 for anything
    /// else), so a frame is dropped whole or not at all.
    frame: u64,
}

impl QueuedDatagram {
    fn new(datagram: Vec<u8>, departure_id: DepartureId, class: DatagramClass) -> Self {
        Self { datagram, departure_id, class, frame: 0 }
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
    /// How many datagrams at the queue's head are repairs from
    /// [`Pacer::push_repair`] (they go first).
    repairs_queued: usize,
    /// Frame datagrams (not repairs) `due` returned since the last
    /// [`Pacer::take_frame_datagrams_sent`].
    frame_datagrams_sent: usize,
    /// The stream's frame interval, from the last frame pushed.
    frame_interval_us: u64,

    // Balanced-mode state is intentionally retained for compatibility.
    rate_bytes_per_us: f64,
    budget_bytes: f64,
    last_us: Option<u64>,

    // Strict mode uses integer tokens and a fractional numerator. This avoids
    // floating-point drift and never turns idle time into a burst.
    strict_credit_bytes: u64,
    strict_remainder: u64,
    strict_last_us: Option<u64>,
    /// Strict mode: bytes sent outside the queue ([`Pacer::charge`], a probe train) hold
    /// budgeted datagrams back until this time, the wire time they took at the held rate.
    strict_charged_until_us: u64,
    /// Strict mode: the ordinal of the last frame pushed, and of the newest frame a
    /// datagram of which has left (frames after it are unstarted).
    last_frame: u64,
    started_frame: u64,
    /// Strict mode: whole frames dropped at the queue limit (D2), counted and kept
    /// for [`Pacer::take_dropped`].
    frames_dropped: u64,
    dropped: Vec<Vec<u8>>,
}

impl Default for Pacer {
    fn default() -> Self {
        Self {
            queue: VecDeque::new(),
            control_queue: VecDeque::new(),
            queued_bytes: 0,
            control_queued_bytes: 0,
            policy: PacerPolicy::Balanced,
            repairs_queued: 0,
            frame_datagrams_sent: 0,
            frame_interval_us: 0,
            rate_bytes_per_us: 0.0,
            budget_bytes: 0.0,
            last_us: None,
            strict_credit_bytes: 0,
            strict_remainder: 0,
            strict_last_us: None,
            strict_charged_until_us: 0,
            last_frame: 0,
            started_frame: 0,
            frames_dropped: 0,
            dropped: Vec::new(),
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
    ///
    /// Strict mode bounds its queue by the D2 rule, newest frame wins: when this
    /// frame does not fit under `max_queue_bytes`, whole older frames none of whose
    /// datagrams has left are dropped, oldest first, until it fits (or none is
    /// left), and nothing is asked for. They are counted ([`Pacer::frames_dropped`])
    /// and handed back by [`Pacer::take_dropped`] so the sender can retire them. A
    /// frame never loses datagrams out of its middle; the newest frame is always
    /// queued, even when a started frame and repairs leave it over the bound.
    pub fn push_frame(
        &mut self,
        datagrams: Vec<Vec<u8>>,
        target_bps: u64,
        frame_interval_us: u64,
        now_us: u64,
    ) {
        if let PacerPolicy::Strict(config) = self.policy {
            let bytes = datagrams.iter().map(Vec::len).sum::<usize>();
            self.make_room(bytes, config.max_queue_bytes);
            if self.queue.is_empty() {
                // A new busy period starts with no credit (as `enqueue_budgeted`).
                self.strict_last_us = Some(now_us);
                self.strict_credit_bytes = 0;
                self.strict_remainder = 0;
            }
            self.last_frame += 1;
            for datagram in datagrams {
                let departure_id = wire_departure_id(&datagram);
                self.queued_bytes = self.queued_bytes.saturating_add(datagram.len());
                self.queue.push_back(QueuedDatagram {
                    frame: self.last_frame,
                    ..QueuedDatagram::new(datagram, departure_id, DatagramClass::Media)
                });
            }
            return;
        }

        self.frame_interval_us = frame_interval_us;
        self.wake(now_us);
        for datagram in datagrams {
            self.queued_bytes = self.queued_bytes.saturating_add(datagram.len());
            self.queue.push_back(QueuedDatagram::new(datagram, 0, DatagramClass::Media));
        }
        self.set_rate(target_bps);
    }

    /// Queues repairs (resent datagrams of frames already sent: NACK answers,
    /// tail-loss probes) ahead of any queued frame, after earlier repairs, at the
    /// same rate as frames: never as one burst, and never behind a queued frame.
    /// In strict mode they are charged to the one wire budget (and refused past
    /// its queue bound) like every other budgeted datagram.
    pub fn push_repair(&mut self, datagrams: Vec<Vec<u8>>, target_bps: u64, now_us: u64) {
        if datagrams.is_empty() {
            return;
        }
        if let PacerPolicy::Strict(config) = self.policy {
            for datagram in datagrams {
                let len = datagram.len();
                if len > config.max_queue_bytes
                    || self.queued_bytes > config.max_queue_bytes.saturating_sub(len)
                {
                    continue;
                }
                if self.queue.is_empty() {
                    self.strict_last_us = Some(now_us);
                    self.strict_credit_bytes = 0;
                    self.strict_remainder = 0;
                }
                let departure_id = wire_departure_id(&datagram);
                self.queued_bytes = self.queued_bytes.saturating_add(len);
                self.queue.insert(
                    self.repairs_queued,
                    QueuedDatagram::new(datagram, departure_id, DatagramClass::Repair),
                );
                self.repairs_queued += 1;
            }
            return;
        }
        self.wake(now_us);
        for datagram in datagrams {
            self.queued_bytes = self.queued_bytes.saturating_add(datagram.len());
            self.queue.insert(
                self.repairs_queued,
                QueuedDatagram::new(datagram, 0, DatagramClass::Repair),
            );
            self.repairs_queued += 1;
        }
        self.set_rate(target_bps);
    }

    /// Strict mode, D2: drops whole unstarted frames, oldest first, until `incoming`
    /// more bytes fit under `max_queue_bytes` or no unstarted frame is left. Repairs
    /// and the rest of a frame that has started to leave stay.
    fn make_room(&mut self, incoming: usize, max_queue_bytes: usize) {
        while self.queued_bytes.saturating_add(incoming) > max_queue_bytes {
            let started = self.started_frame;
            let Some(oldest) = self.queue.iter().map(|d| d.frame).find(|&frame| frame > started)
            else {
                return;
            };
            let mut kept = VecDeque::with_capacity(self.queue.len());
            for d in self.queue.drain(..) {
                if d.frame == oldest {
                    self.queued_bytes = self.queued_bytes.saturating_sub(d.datagram.len());
                    self.dropped.push(d.datagram);
                } else {
                    kept.push_back(d);
                }
            }
            self.queue = kept;
            self.frames_dropped += 1;
        }
    }

    /// Whole frames the strict queue dropped at its limit (D2), since the pacer began.
    pub fn frames_dropped(&self) -> u64 {
        self.frames_dropped
    }

    /// The datagrams of frames dropped at the strict queue limit since the last call,
    /// never sent: the sender retires them so they are not read as loss.
    pub fn take_dropped(&mut self) -> Vec<Vec<u8>> {
        std::mem::take(&mut self.dropped)
    }

    /// Idle: what is pushed next starts at once.
    fn wake(&mut self, now_us: u64) {
        if self.queue.is_empty() {
            self.last_us = Some(now_us);
            self.budget_bytes = 0.0;
        }
    }

    /// `PACING_FACTOR` times the target, or faster when that would hold what is
    /// queued longer than `SPREAD_SHARE` of a frame interval or `MAX_SPREAD_US`, but
    /// no faster than `LARGE_FRAME_FACTOR` times the target unless what is queued
    /// would then take longer than `MAX_LARGE_SPREAD_US`.
    fn set_rate(&mut self, target_bps: u64) {
        let interval_us = if self.frame_interval_us == 0 { 16_667 } else { self.frame_interval_us };
        let window_us = (interval_us as f64 * SPREAD_SHARE).clamp(1_000.0, MAX_SPREAD_US);
        let floor = target_bps as f64 * PACING_FACTOR / 8.0 / 1e6;
        let queued = self.queued_bytes as f64;
        let ceiling =
            (target_bps as f64 * LARGE_FRAME_FACTOR / 8.0 / 1e6).max(queued / MAX_LARGE_SPREAD_US);
        let fit = (queued / window_us).min(ceiling);
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
            self.count_departure(datagram.class);
            out.push(datagram.into_public());
        }
        if self.queue.is_empty() {
            self.budget_bytes = 0.0;
        }
        out
    }

    /// Keeps the head-repair count and the frame-datagram count in step with a
    /// budgeted datagram leaving the queue's head.
    fn count_departure(&mut self, class: DatagramClass) {
        if self.repairs_queued > 0 {
            self.repairs_queued -= 1;
        } else if class.is_frame() {
            self.frame_datagrams_sent += 1;
        }
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
            self.count_departure(datagram.class);
            self.started_frame = self.started_frame.max(datagram.frame);
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

    /// Strict only: `bytes` left outside the queue (an ultra probe train, sent back to
    /// back so its dispersion measures the path) and still count against the one wire
    /// budget. Credit already earned pays first; the rest holds budgeted datagrams back
    /// for the time those bytes take at the held rate. Balanced pacing ignores it.
    pub fn charge(&mut self, bytes: usize, now_us: u64) {
        let PacerPolicy::Strict(config) = self.policy else { return };
        if config.rate_bps == 0 || bytes == 0 {
            return;
        }
        if let Some(last) = self.strict_last_us {
            self.refill_strict(now_us, last);
        }
        let paid = self.strict_credit_bytes.min(bytes as u64);
        self.strict_credit_bytes -= paid;
        let owed = (bytes as u64 - paid) as u128;
        if owed == 0 {
            return;
        }
        let wait = owed.saturating_mul(MICROBITS_PER_BYTE_US).div_ceil(config.rate_bps as u128);
        let wait = wait.min(u64::MAX as u128) as u64;
        self.strict_charged_until_us =
            self.strict_charged_until_us.max(now_us).saturating_add(wait);
    }

    fn refill_strict(&mut self, now_us: u64, last_us: u64) {
        let PacerPolicy::Strict(config) = self.policy else { return };
        // Nothing accrues while charged bytes (a probe train) still hold the wire.
        let elapsed = now_us.saturating_sub(last_us.max(self.strict_charged_until_us)) as u128;
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
            // Credit starts accruing once charged bytes (a probe train) have had their time.
            let last = last.max(self.strict_charged_until_us);
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

    /// How many of the datagrams `due` returned since the last call were frame
    /// datagrams rather than repairs (for per-frame send times).
    pub fn take_frame_datagrams_sent(&mut self) -> usize {
        std::mem::take(&mut self.frame_datagrams_sent)
    }

    /// Drops everything queued (the session ended).
    pub fn clear(&mut self) {
        self.queue.clear();
        self.control_queue.clear();
        self.queued_bytes = 0;
        self.control_queued_bytes = 0;
        self.repairs_queued = 0;
        self.budget_bytes = 0.0;
        self.strict_credit_bytes = 0;
        self.strict_remainder = 0;
        self.last_us = None;
        self.strict_last_us = None;
        self.strict_charged_until_us = 0;
    }

    /// The queued frame datagrams, in send order (to decide what an outage end drops,
    /// D12). Repairs are left out: they resend frames that already left, and a
    /// tail-loss probe of a one-datagram frame would otherwise read as that whole
    /// frame unstarted. Probes and control datagrams are not frames either.
    pub fn queued(&self) -> impl Iterator<Item = &[u8]> {
        self.queue
            .iter()
            .skip(self.repairs_queued)
            .filter(|d| d.class.is_frame())
            .map(|d| d.datagram.as_slice())
    }

    /// Takes the queued frame datagrams `stale` picks, in order, so the caller can
    /// retire them (an outage ended and they are stale, D12); the rest, and every
    /// queued repair, keep their place and pacing. When nothing is left the next
    /// frame pushed goes at once.
    pub fn take_where(&mut self, mut stale: impl FnMut(&[u8]) -> bool) -> Vec<Vec<u8>> {
        let mut taken = Vec::new();
        let mut kept = VecDeque::with_capacity(self.queue.len());
        for (i, d) in self.queue.drain(..).enumerate() {
            if i >= self.repairs_queued && d.class.is_frame() && stale(&d.datagram) {
                self.queued_bytes = self.queued_bytes.saturating_sub(d.datagram.len());
                taken.push(d.datagram);
            } else {
                kept.push_back(d);
            }
        }
        self.queue = kept;
        if self.queue.is_empty() {
            self.budget_bytes = 0.0;
            self.strict_credit_bytes = 0;
            self.strict_remainder = 0;
            self.strict_last_us = None;
        }
        taken
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

    fn frame(n: usize) -> Vec<Vec<u8>> {
        (0..n).map(|i| vec![i as u8; 1152]).collect()
    }

    /// Runs the pacer by its own deadlines; returns (send time, datagram) pairs.
    fn drain(p: &mut Pacer, from: u64) -> Vec<(u64, Vec<u8>)> {
        let mut out = Vec::new();
        let mut now = from;
        for _ in 0..100_000 {
            for d in p.due(now) {
                out.push((now, d));
            }
            match p.next_deadline_us() {
                Some(t) => now = t.max(now + 1),
                None => break,
            }
        }
        out
    }

    #[test]
    fn a_keyframe_leaves_at_most_the_large_frame_factor_in_order() {
        let mut p = Pacer::new();
        // 300 datagrams (345 KB) at 30 Mbps and 60 fps: 8 ms would be 345 Mbit/s, so it
        // goes at 6 times the target (180 Mbit/s, 22.5 bytes/us), in about 15 ms.
        p.push_frame(frame(300), 30_000_000, 16_667, 1_000);
        let sent = drain(&mut p, 1_000);
        assert_eq!(sent.len(), 300);
        let last = sent.last().unwrap().0;
        assert!(last - 1_000 <= 15_600, "keyframe took {} us", last - 1_000);
        // Less the first burst allowance, which goes at once.
        assert!(last - 1_000 >= 12_000, "keyframe was not spread: {} us", last - 1_000);
        for (i, (_, d)) in sent.iter().enumerate() {
            assert_eq!(d[0], i as u8, "order");
        }
        // No wakeup sends more than the burst allowance plus one datagram.
        let mut per_time = std::collections::BTreeMap::new();
        for (t, _) in &sent {
            *per_time.entry(*t).or_insert(0usize) += 1;
        }
        let rate = 30_000_000.0 * LARGE_FRAME_FACTOR / 8.0 / 1e6; // bytes per us
        let burst = (rate * BURST_US as f64 / 1152.0).ceil() as usize + 1;
        assert!(per_time.values().all(|&n| n <= burst), "{per_time:?}");
    }

    /// Design D6, detector for the class "a recovery leaves as an unpaced burst": a
    /// NACK answer (64 resends, the most one feedback asks for) leaves ahead of the
    /// queued frame, in order, no more than the burst allowance per wakeup, and within
    /// half a frame interval.
    #[test]
    fn repairs_leave_paced_ahead_of_queued_frames() {
        let mut p = Pacer::new();
        p.push_frame(frame(100), 10_000_000, 16_667, 0);
        let first = p.due(0).len();
        assert_eq!(p.take_frame_datagrams_sent(), first);
        let repairs: Vec<Vec<u8>> = (0..64).map(|_| vec![0xaa; 1152]).collect();
        p.push_repair(repairs, 10_000_000, 1_000);
        p.push_repair(vec![vec![0xbb; 1152]], 10_000_000, 1_000);
        let sent = drain(&mut p, 1_000);
        assert_eq!(sent.len(), 100 - first + 65);
        assert!(sent[..64].iter().all(|(_, d)| d[0] == 0xaa), "repairs first, in order");
        assert_eq!(sent[64].1[0], 0xbb);
        assert_eq!(p.take_frame_datagrams_sent(), 100 - first);
        let at_once = sent.iter().filter(|(t, _)| *t == 1_000).count();
        assert!(at_once < 65, "the repairs left as one burst: {at_once} datagrams at once");
        let last = sent.last().unwrap().0 - 1_000;
        assert!(last <= 8_400, "repairs and the frame behind them took {last} us");
    }

    /// D12 with D6: an outage-end drop sees and takes only queued frame datagrams. A
    /// queued repair (a NACK answer or tail-loss probe of a frame that already left)
    /// is neither a candidate nor taken, stays ahead of the frames and still counts as
    /// a repair, so the frames left keep their send times.
    #[test]
    fn an_outage_drop_leaves_queued_repairs_alone() {
        let mut p = Pacer::new();
        p.push_frame(frame(100), 10_000_000, 16_667, 0);
        let first = p.due(0).len();
        p.take_frame_datagrams_sent();
        p.push_repair(vec![vec![0xee; 1152], vec![0xaa; 1152]], 10_000_000, 1_000);
        p.push_frame(vec![vec![0xee; 1152]; 10], 10_000_000, 16_667, 1_000);
        assert_eq!(p.queued().count(), 100 - first + 10, "repairs are not candidates");
        let stale = p.take_where(|d| d[0] == 0xee);
        assert_eq!(stale.len(), 10, "only the queued frame's datagrams");
        let sent = drain(&mut p, 1_000);
        assert_eq!(sent.len(), 2 + 100 - first);
        assert_eq!((sent[0].1[0], sent[1].1[0]), (0xee, 0xaa), "repairs still first");
        assert_eq!(p.take_frame_datagrams_sent(), 100 - first);
    }

    #[test]
    fn a_repair_on_an_idle_pacer_goes_at_once() {
        let mut p = Pacer::new();
        p.push_repair(vec![vec![1; 1152]; 3], 30_000_000, 5_000);
        assert_eq!(p.due(5_000).len(), 3);
        assert!(p.is_empty());
        assert_eq!(p.take_frame_datagrams_sent(), 0);
    }

    #[test]
    fn a_small_frame_goes_at_once_and_a_p_frame_at_two_and_a_half_times_the_target() {
        let mut p = Pacer::new();
        p.push_frame(frame(3), 30_000_000, 16_667, 0);
        assert_eq!(p.due(0).len(), 3);
        assert!(p.is_empty());
        assert_eq!(p.next_deadline_us(), None);
        // 54 datagrams (62 KB, one 30 Mbps frame at 60 fps) at 75 Mbps: about 6.6 ms, less
        // the first burst allowance.
        p.push_frame(frame(54), 30_000_000, 16_667, 100_000);
        let sent = drain(&mut p, 100_000);
        let span = sent.last().unwrap().0 - 100_000;
        assert!((4_200..=7_000).contains(&span), "span {span}");
    }

    /// Detector for the class "the send stage scales with the frame interval": an
    /// at-budget frame at 30 fps (and at 15 fps) leaves within `MAX_SPREAD_US`, not
    /// 0.4 of its interval.
    #[test]
    fn a_low_frame_rate_frame_leaves_within_the_absolute_spread_window() {
        for (fps, interval_us) in [(30u64, 33_333u64), (15, 66_667)] {
            let mut p = Pacer::new();
            // One 30 Mbps frame at this rate.
            let n = (30_000_000 / 8 / fps as usize).div_ceil(1152);
            p.push_frame(frame(n), 30_000_000, interval_us, 0);
            let sent = drain(&mut p, 0);
            assert_eq!(sent.len(), n);
            let span = sent.last().unwrap().0;
            assert!(span <= MAX_SPREAD_US as u64, "{fps} fps: span {span} us");
        }
    }

    #[test]
    fn a_frame_pushed_while_one_is_queued_follows_it() {
        let mut p = Pacer::new();
        p.push_frame(frame(100), 10_000_000, 16_667, 0);
        let first = p.due(0).len();
        assert!(first < 100);
        p.push_frame(vec![vec![0xee; 1152]], 10_000_000, 16_667, 1_000);
        let rest = drain(&mut p, 1_000);
        assert_eq!(first + rest.len(), 101);
        assert_eq!(rest.last().unwrap().1[0], 0xee);
    }

    #[test]
    fn taking_the_whole_queue_leaves_an_idle_pacer_that_sends_the_next_frame_at_once() {
        let mut p = Pacer::new();
        p.push_frame(frame(100), 10_000_000, 16_667, 0);
        let first = p.due(0).len();
        assert_eq!(p.queued().count(), 100 - first);
        let stale = p.take_where(|_| true);
        assert_eq!(first + stale.len(), 100);
        assert_eq!(stale[0][0], first as u8, "the unsent tail, in order");
        assert!(p.is_empty());
        assert_eq!(p.queued_bytes(), 0);
        assert_eq!(p.next_deadline_us(), None);
        p.push_frame(frame(2), 10_000_000, 16_667, 1_000);
        assert_eq!(p.due(1_000).len(), 2, "the newest frame is not paced behind the stale one");
    }

    #[test]
    fn taking_part_of_the_queue_keeps_the_rest_in_order() {
        let mut p = Pacer::new();
        p.push_frame(frame(10), 10_000_000, 16_667, 0);
        p.push_frame(vec![vec![0xee; 1200]; 5], 10_000_000, 16_667, 0);
        let first = p.due(0).len();
        let stale = p.take_where(|d| d[0] == 0xee);
        assert_eq!(stale.len(), 5);
        assert_eq!(p.queued_bytes(), (10 - first) * 1152);
        let rest: Vec<u8> = p.queued().map(|d| d[0]).collect();
        assert_eq!(rest, (first as u8..10).collect::<Vec<_>>());
    }

    #[test]
    fn a_late_wakeup_does_not_release_a_burst() {
        let mut p = Pacer::new();
        p.push_frame(frame(200), 20_000_000, 16_667, 0);
        p.due(0);
        // The caller slept 5 ms instead of the deadline: still at most the burst allowance.
        let late = p.due(5_000).len();
        let rate = 230_400.0 / 8_333.0;
        assert!(late as f64 <= (rate * BURST_US as f64 / 1152.0).ceil() + 1.0, "{late}");
    }

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
