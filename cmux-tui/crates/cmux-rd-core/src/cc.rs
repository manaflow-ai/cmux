//! Delay-based congestion control for real-time video. The sender records
//! when each transport sequence number left; feedback reports when it
//! arrived. Packets are grouped into send bursts, and the change in one-way
//! delay between consecutive groups goes through a trend filter (a least
//! squares slope over the last groups) whose threshold adapts to the path's
//! own jitter, so a Wi-Fi radio's scatter does not read as a queue while a
//! steadily growing queue still does. Overuse cuts the target to a little
//! under the throughput the viewer measured; a flat delay grows it, fast
//! while the path's capacity is unknown or far above the target, slowly near
//! the capacity measured at the last overuse. Loss caps the target further.
//! The target drives the encoder per frame; nothing is ever queued to
//! "catch up".

use std::collections::{HashMap, VecDeque};

use crate::pacer::PACING_FACTOR;
use crate::profile::EncodeProfile;
use cmux_rd_proto::Arrival;

mod ultra;
pub use ultra::UltraConfig;
use ultra::UltraState;

/// The network path class reported by the link (transport.md section 4).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PathKind {
    DirectLan,
    DirectWan,
    ViaCloudRegion,
    DoRelay,
}

/// Congestion controller limits.
#[derive(Debug, Clone, Copy)]
pub struct CcConfig {
    pub min_bps: u64,
    pub max_bps: u64,
    pub start_bps: u64,
    /// Cap applied on [`PathKind::DoRelay`] (`remoteDesktop.relay.maxBitrateMbps`).
    pub relay_max_bps: u64,
    /// Start on a path whose measured round trip is under `lan_rtt_us`, until the
    /// first overuse (a LAN carries this at once; a rising delay still cuts it). The
    /// round trip is the carrier's ([`CongestionController::on_rtt`]) or, on a carrier
    /// without one, the first feedback's: a datagram's departure to the feedback that
    /// reports it.
    pub lan_start_bps: u64,
    pub lan_rtt_us: u64,
}

/// A round trip under this is a LAN: the start jumps to `lan_start_bps`. Wi-Fi in one home
/// (an iPhone or laptop viewing a Mac) sits at 5 to 10 ms, under a 5 ms limit it started at
/// 8 Mbit/s and reached 15 Mbit/s only after about 1 s of motion. A WAN is 20 ms and up.
pub const LAN_RTT_US: u64 = 10_000;

impl Default for CcConfig {
    fn default() -> Self {
        Self {
            min_bps: 1_000_000,
            max_bps: 80_000_000,
            start_bps: 8_000_000,
            relay_max_bps: 4_000_000,
            lan_start_bps: 30_000_000,
            lan_rtt_us: LAN_RTT_US,
        }
    }
}

/// The controller's view of the path.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Usage {
    Normal,
    Overuse,
    Underuse,
}

/// Packets sent within this span form one group.
const GROUP_SPAN_US: i64 = 5_000;
/// A packet arriving this soon after the group's last one, with less delay than it,
/// joins the group (a radio delivering an aggregate at once).
const BURST_ARRIVAL_US: i64 = 5_000;
/// No group spans longer than this on arrival.
const MAX_BURST_US: i64 = 100_000;
/// Groups in the trend window.
const TREND_WINDOW: usize = 20;
/// The slope is fitted once this many groups are in the window (fewer is noise).
const TREND_MIN_POINTS: usize = 8;
const TREND_SMOOTHING: f64 = 0.9;
const TREND_GAIN: f64 = 4.0;
/// The adaptive threshold on the modified trend, in milliseconds.
const THRESHOLD_START_MS: f64 = 12.5;
const THRESHOLD_MIN_MS: f64 = 6.0;
const THRESHOLD_MAX_MS: f64 = 600.0;
const THRESHOLD_K_UP: f64 = 0.0087;
const THRESHOLD_K_DOWN: f64 = 0.039;
/// A sample this far over the threshold is an outlier and does not move it.
const THRESHOLD_MAX_OFFSET_MS: f64 = 15.0;
/// Over the threshold this long (and twice) before it counts as overuse.
const OVERUSE_TIME_MS: f64 = 10.0;
/// The cut on overuse, as a share of the measured throughput.
const BETA: f64 = 0.85;
/// The throughput window, on the viewer's arrival clock.
const ACKED_WINDOW_US: i64 = 500_000;
/// Growth per second while the capacity is unknown or below the target (probing).
const PROBE_GROWTH_PER_S: f64 = 2.0;
/// Growth per second well below the measured capacity (recovering after a cut,
/// a loss burst or a quiet screen).
const RECOVER_GROWTH_PER_S: f64 = 4.0;
/// Growth per second near the measured capacity.
const NEAR_GROWTH_PER_S: f64 = 1.15;
/// Time credited to one increase at most, so a long quiet gap is not one jump.
const MAX_STEP_US: u64 = 200_000;
/// Shortest time between two cuts.
const MIN_DECREASE_INTERVAL_US: u64 = 200_000;
/// D12: no feedback, or no arrival while datagrams were in flight, for longer than
/// this (or four round trips) is an outage, not congestion.
pub const OUTAGE_MIN_US: u64 = 100_000;

/// D12: the one outage threshold, max(100 ms, 4 x RTT). Silence or a one-way
/// delay jump longer than this is a path that went away, not congestion. Every
/// outage reader (the host's controller, the viewer's link state) uses this.
/// `rtt_us` is the path's smallest round trip, if one has been measured.
pub fn outage_threshold_us(rtt_us: Option<u64>) -> u64 {
    rtt_us.map_or(OUTAGE_MIN_US, |rtt| rtt.saturating_mul(4).max(OUTAGE_MIN_US))
}

/// An outage's freeze ends at the first arrival of a datagram sent after it, or
/// after this long at most.
const OUTAGE_FREEZE_MAX_US: u64 = 1_000_000;
/// One response window never cuts the target below this share of where it began.
const CUT_FLOOR: f64 = 0.5;

/// One send group: packets sent within [`GROUP_SPAN_US`].
#[derive(Debug, Clone, Copy)]
struct Group {
    first_send_us: i64,
    last_send_us: i64,
    first_arrival_us: i64,
    last_arrival_us: i64,
}

/// Groups packets and yields (send delta, arrival delta) between consecutive groups.
#[derive(Debug, Default)]
struct InterArrival {
    current: Option<Group>,
    prev: Option<Group>,
}

impl InterArrival {
    fn add(&mut self, send_us: i64, arrival_us: i64) -> Option<(i64, i64, i64)> {
        let Some(cur) = self.current.as_mut() else {
            self.current = Some(Group {
                first_send_us: send_us,
                last_send_us: send_us,
                first_arrival_us: arrival_us,
                last_arrival_us: arrival_us,
            });
            return None;
        };
        if send_us < cur.first_send_us {
            // Reordered from an older group: its timing is already accounted.
            return None;
        }
        let arrival_delta = arrival_us - cur.last_arrival_us;
        let send_delta = send_us - cur.last_send_us;
        let burst = send_delta == 0
            || (arrival_delta >= 0
                && arrival_delta - send_delta < 0
                && arrival_delta <= BURST_ARRIVAL_US
                && arrival_us - cur.first_arrival_us < MAX_BURST_US);
        if burst || send_us - cur.first_send_us <= GROUP_SPAN_US {
            cur.last_send_us = cur.last_send_us.max(send_us);
            cur.last_arrival_us = cur.last_arrival_us.max(arrival_us);
            return None;
        }
        let done = *cur;
        let out = self.prev.map(|p| {
            (
                done.last_send_us - p.last_send_us,
                done.last_arrival_us - p.last_arrival_us,
                done.last_arrival_us,
            )
        });
        self.prev = Some(done);
        self.current = Some(Group {
            first_send_us: send_us,
            last_send_us: send_us,
            first_arrival_us: arrival_us,
            last_arrival_us: arrival_us,
        });
        out
    }
}

/// The delay-gradient filter: a least-squares slope of the smoothed accumulated
/// delay over the last groups, against an adaptive threshold.
#[derive(Debug)]
struct Trendline {
    history: VecDeque<(f64, f64)>,
    first_arrival_ms: Option<f64>,
    accumulated_ms: f64,
    smoothed_ms: f64,
    deltas: u32,
    trend: f64,
    threshold_ms: f64,
    last_threshold_ms: Option<f64>,
    time_over_ms: f64,
    over_count: u32,
    hypothesis: Usage,
}

impl Default for Trendline {
    fn default() -> Self {
        Self {
            history: VecDeque::with_capacity(TREND_WINDOW + 1),
            first_arrival_ms: None,
            accumulated_ms: 0.0,
            smoothed_ms: 0.0,
            deltas: 0,
            trend: 0.0,
            threshold_ms: THRESHOLD_START_MS,
            last_threshold_ms: None,
            time_over_ms: -1.0,
            over_count: 0,
            hypothesis: Usage::Normal,
        }
    }
}

impl Trendline {
    fn update(&mut self, send_delta_ms: f64, arrival_delta_ms: f64, arrival_ms: f64) -> Usage {
        self.deltas = self.deltas.saturating_add(1).min(1000);
        self.accumulated_ms += arrival_delta_ms - send_delta_ms;
        self.smoothed_ms =
            TREND_SMOOTHING * self.smoothed_ms + (1.0 - TREND_SMOOTHING) * self.accumulated_ms;
        let first = *self.first_arrival_ms.get_or_insert(arrival_ms);
        self.history.push_back((arrival_ms - first, self.smoothed_ms));
        if self.history.len() > TREND_WINDOW {
            self.history.pop_front();
        }
        let prev_trend = self.trend;
        if self.history.len() >= TREND_MIN_POINTS
            && let Some(slope) = slope(&self.history)
        {
            self.trend = slope;
        }
        self.detect(prev_trend, send_delta_ms, arrival_ms);
        self.hypothesis
    }

    fn detect(&mut self, prev_trend: f64, send_delta_ms: f64, now_ms: f64) {
        if self.deltas < 2 {
            self.hypothesis = Usage::Normal;
            return;
        }
        let modified = f64::from(self.deltas.min(60)) * self.trend * TREND_GAIN;
        if modified > self.threshold_ms {
            if self.time_over_ms < 0.0 {
                self.time_over_ms = send_delta_ms / 2.0;
            } else {
                self.time_over_ms += send_delta_ms;
            }
            self.over_count += 1;
            if self.time_over_ms > OVERUSE_TIME_MS
                && self.over_count > 1
                && self.trend >= prev_trend
            {
                self.time_over_ms = 0.0;
                self.over_count = 0;
                self.hypothesis = Usage::Overuse;
            }
        } else if modified < -self.threshold_ms {
            self.time_over_ms = -1.0;
            self.over_count = 0;
            self.hypothesis = Usage::Underuse;
        } else {
            self.time_over_ms = -1.0;
            self.over_count = 0;
            self.hypothesis = Usage::Normal;
        }
        self.update_threshold(modified, now_ms);
    }

    /// The threshold follows the modified trend's magnitude: up slowly while the
    /// trend runs over it (jitter that is the path's normal), down faster under it.
    fn update_threshold(&mut self, modified: f64, now_ms: f64) {
        let last = *self.last_threshold_ms.get_or_insert(now_ms);
        let magnitude = modified.abs();
        if magnitude > self.threshold_ms + THRESHOLD_MAX_OFFSET_MS {
            self.last_threshold_ms = Some(now_ms);
            return;
        }
        let k = if magnitude < self.threshold_ms { THRESHOLD_K_DOWN } else { THRESHOLD_K_UP };
        let dt = (now_ms - last).clamp(0.0, 100.0);
        self.threshold_ms += k * (magnitude - self.threshold_ms) * dt;
        self.threshold_ms = self.threshold_ms.clamp(THRESHOLD_MIN_MS, THRESHOLD_MAX_MS);
        self.last_threshold_ms = Some(now_ms);
    }
}

impl Trendline {
    /// A new delay baseline that keeps the path's learned jitter threshold: what
    /// accumulated before (an outage's burst) never reaches the trend.
    fn rebase(&mut self) {
        *self = Self { threshold_ms: self.threshold_ms, ..Self::default() };
    }
}

/// How an outage ended, for the host (D12): what queued during it is stale.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OutageEnd {
    /// How long the path was silent.
    pub silent_us: u64,
    /// The target held through it, and resumed at once.
    pub target_bps: u64,
}

/// D12, "an outage is not congestion": a Wi-Fi radio leaves for hundreds of
/// milliseconds and then delivers everything at once. The controller freezes
/// through it, throws away the burst's delay samples and resumes where it was.
#[derive(Debug, Default)]
struct OutageWatch {
    /// The smallest round trip on this path (a stall inflates the others).
    min_rtt_us: Option<u64>,
    /// When the oldest datagram sent since the last feedback left.
    unanswered_since_us: Option<u64>,
    /// When the previous feedback arrived. Silence counts from the later of this
    /// and the oldest unanswered send, so a long but flowing path (a growing
    /// queue) is never silence: its feedback keeps arriving.
    last_feedback_us: Option<u64>,
    /// The newest timed sample: (send time, raw viewer arrival time).
    last_sample: Option<(u64, u32)>,
    /// Datagrams sent before this host time crossed the outage: their delay and
    /// throughput say nothing about congestion.
    burst_sent_before_us: u64,
    link: LinkState,
    /// The current response window: (ends at, the target when it began).
    cut_window: Option<(u64, u64)>,
    ended: Option<OutageEnd>,
}

/// Whether the controller may act. Every field an outage needs lives in its
/// variant, so a frozen controller always knows the rate it resumes at.
#[derive(Debug, Clone, Copy, Default)]
enum LinkState {
    /// Feedback flows: delay and loss drive the target.
    #[default]
    Up,
    /// The path went away: no cut, no growth, until a datagram sent after
    /// `since_us` arrives (or [`OUTAGE_FREEZE_MAX_US`] passes); then the
    /// target is `resume_bps` again at once.
    Away { since_us: u64, resume_bps: u64 },
}

impl OutageWatch {
    fn on_rtt(&mut self, rtt_us: u64) {
        if rtt_us > 0 {
            self.min_rtt_us = Some(self.min_rtt_us.map_or(rtt_us, |m| m.min(rtt_us)));
        }
    }

    /// [`outage_threshold_us`] on this path.
    fn threshold_us(&self) -> u64 {
        outage_threshold_us(self.min_rtt_us)
    }

    /// A response window: at least [`MIN_DECREASE_INTERVAL_US`] or one round trip.
    fn window_us(&self) -> u64 {
        self.min_rtt_us.unwrap_or(0).max(MIN_DECREASE_INTERVAL_US)
    }
}

fn slope(points: &VecDeque<(f64, f64)>) -> Option<f64> {
    let n = points.len() as f64;
    let (sx, sy) = points.iter().fold((0.0, 0.0), |(a, b), &(x, y)| (a + x, b + y));
    let (mx, my) = (sx / n, sy / n);
    let (num, den) = points
        .iter()
        .fold((0.0, 0.0), |(a, b), &(x, y)| (a + (x - mx) * (y - my), b + (x - mx) * (x - mx)));
    (den > 0.0).then(|| num / den)
}

#[derive(Debug, Clone, Copy)]
struct Sent {
    at_us: u64,
    bytes: u32,
}

/// Delay-gradient bandwidth estimator.
#[derive(Debug)]
pub struct CongestionController {
    config: CcConfig,
    profile: EncodeProfile,
    ultra: UltraState,
    path_generation: u64,
    target_bps: u64,
    path: PathKind,
    sent: HashMap<u16, Sent>,
    /// Send order, for evicting the oldest entries (sequence numbers wrap).
    sent_order: VecDeque<u16>,
    groups: InterArrival,
    trend: Trendline,
    /// The viewer's arrival clock, unwrapped from u32: (last raw, last unwrapped).
    arrival_clock: Option<(u32, i64)>,
    /// Bytes that arrived, by unwrapped arrival time, for the measured throughput.
    acked: VecDeque<(i64, u32)>,
    acked_bytes: u64,
    /// Bytes sent, by send time, over the same window: sending more than arrives is a queue
    /// of ours; sending about what arrives, far under the target, is a quiet screen.
    sent_window: VecDeque<(u64, u32)>,
    sent_window_bytes: u64,
    /// D12: outage detection, the freeze and the cut floor (see [`OutageWatch`]).
    outage: OutageWatch,
    /// Throughput measured at overuse, smoothed: the path's capacity until it changes.
    capacity_bps: Option<f64>,
    last_increase_us: Option<u64>,
    last_decrease_us: Option<u64>,
    /// One round trip (at least [`MIN_DECREASE_INTERVAL_US`]) between cuts, fixed
    /// when a cut is taken: delay and loss cuts share it (ultra's too).
    response_window_us: u64,
    next_decrease_us: u64,
    usage: Usage,
}

impl CongestionController {
    pub fn new(config: CcConfig, path: PathKind) -> Self {
        let mut cc = Self {
            config,
            profile: EncodeProfile::Standard,
            ultra: UltraState::default(),
            path_generation: 0,
            target_bps: config.start_bps,
            path,
            sent: HashMap::new(),
            sent_order: VecDeque::new(),
            groups: InterArrival::default(),
            trend: Trendline::default(),
            arrival_clock: None,
            acked: VecDeque::new(),
            acked_bytes: 0,
            sent_window: VecDeque::new(),
            sent_window_bytes: 0,
            outage: OutageWatch::default(),
            capacity_bps: None,
            last_increase_us: None,
            last_decrease_us: None,
            response_window_us: MIN_DECREASE_INTERVAL_US,
            next_decrease_us: 0,
            usage: Usage::Normal,
        };
        cc.clamp();
        cc
    }

    /// The bitrate the encoder should aim for now.
    pub fn target_bps(&self) -> u64 {
        self.target_bps
    }

    pub fn profile(&self) -> EncodeProfile {
        self.profile
    }

    /// Selection alone is not a capacity measurement. Ultra starts at the configured
    /// startup rate, including its FEC, and moves by standard's rules until a probe
    /// train measures the path.
    pub fn set_profile(&mut self, profile: EncodeProfile) {
        if self.profile == profile {
            return;
        }
        self.profile = profile;
        self.on_path_changed(self.path);
        self.target_bps = self.config.start_bps;
        self.ultra.wire_bps = self.config.start_bps;
        self.clamp();
    }

    pub fn configure_ultra(&mut self, config: UltraConfig) {
        self.ultra.config = config;
        self.clamp();
    }

    /// Capture this token when a probe train starts, not when feedback arrives.
    pub fn probe_generation(&self) -> u64 {
        self.path_generation
    }

    /// A completed, planner-validated probe. An old route's measurement cannot
    /// apply after a route/profile change, even if its feedback arrives late.
    pub fn on_probe_capacity(&mut self, generation: u64, capacity_bps: u64) -> bool {
        if self.profile != EncodeProfile::Ultra
            || generation != self.path_generation
            || capacity_bps < 2
        {
            return false;
        }
        self.ultra.capacity_bps = Some(capacity_bps);
        if let Some(held) = self.ultra.held_wire_bps(self.ultra_path_ceiling()) {
            // A new estimate cannot clear a queue that has not drained, or a loss that
            // has not stopped.
            self.ultra.wire_bps =
                if self.ultra.cutting() { self.ultra.wire_bps.min(held) } else { held };
        }
        self.clamp();
        true
    }

    /// Total departure budget for the strict Ultra pacer. Repairs and probes
    /// are charged by the pacer; parity is owned by the FEC lane.
    pub fn wire_budget_bps(&self) -> u64 {
        if self.profile == EncodeProfile::Ultra { self.ultra.wire_bps } else { self.target_bps }
    }

    /// How fast the strict Ultra pacer lets datagrams leave: the probed capacity (never
    /// under the held rate), else [`PACING_FACTOR`] times it until a train measures one.
    /// Pacing at the held rate itself left no slack: the encoder fills that rate, so a
    /// burst queued for good and whole frames were dropped (netem at 30 Mbit/s: 1.5 fps,
    /// key to frame p50 490 ms). The held rate stays the encoder's target.
    pub fn pacing_bps(&self) -> u64 {
        let held = self.wire_budget_bps();
        if self.profile != EncodeProfile::Ultra {
            return held;
        }
        match self.ultra.capacity_bps {
            Some(capacity) => capacity.max(held),
            None => (held as f64 * PACING_FACTOR) as u64,
        }
    }

    fn ultra_path_ceiling(&self) -> u64 {
        if self.path == PathKind::DoRelay {
            self.ultra.config.max_wire_bps.min(self.config.relay_max_bps)
        } else {
            self.ultra.config.max_wire_bps
        }
        .max(1)
    }

    pub fn usage(&self) -> Usage {
        self.usage
    }

    pub fn path(&self) -> PathKind {
        self.path
    }

    /// The throughput measured at the last overuse, smoothed (`None` until one).
    pub fn capacity_bps(&self) -> Option<u64> {
        self.capacity_bps.map(|c| c as u64)
    }

    /// Records the send time of a datagram of unknown size.
    pub fn on_sent(&mut self, transport_seq: u16, now_us: u64) {
        self.on_sent_bytes(transport_seq, now_us, 0);
    }

    /// A datagram recorded by `on_sent_bytes` really left now (a pacer held it): its
    /// delay counts from here. Unknown sequences are ignored.
    pub fn on_departed(&mut self, transport_seq: u16, now_us: u64) {
        if let Some(sent) = self.sent.get_mut(&transport_seq) {
            sent.at_us = now_us;
        }
    }

    /// Records the send time and size of a datagram.
    pub fn on_sent_bytes(&mut self, transport_seq: u16, now_us: u64, bytes: usize) {
        let bytes = u32::try_from(bytes).unwrap_or(u32::MAX);
        if let Some(sent) = self.sent.get_mut(&transport_seq) {
            sent.at_us = now_us;
            return;
        }
        self.outage.unanswered_since_us.get_or_insert(now_us);
        self.sent.insert(transport_seq, Sent { at_us: now_us, bytes });
        if bytes > 0 {
            self.sent_window.push_back((now_us, bytes));
            self.sent_window_bytes += u64::from(bytes);
            self.prune_sent_window(now_us);
        }
        self.sent_order.push_back(transport_seq);
        while self.sent_order.len() > 4096 {
            if let Some(old) = self.sent_order.pop_front() {
                self.sent.remove(&old);
            }
        }
    }

    /// A retransmission keeps the original transport sequence, so its
    /// receipt cannot distinguish the original packet from the repair.
    /// Exclude that ambiguous sample rather than counting the repair wait
    /// as new queueing delay on the path.
    pub fn on_retransmitted(&mut self, transport_seq: u16) {
        self.sent.remove(&transport_seq);
    }

    /// A datagram recorded by `on_sent_bytes` was dropped before it left (the
    /// host's pacer queue after an outage, D12): it is never timed. (The outage
    /// end already emptied the send-rate window it was counted in.)
    pub fn on_dropped(&mut self, transport_seq: u16) {
        self.sent.remove(&transport_seq);
    }

    /// A path change resets the delay baseline and the measured capacity (RTT and
    /// capacity change at once) and applies the relay cap immediately.
    pub fn on_path_changed(&mut self, path: PathKind) {
        self.path_generation = self.path_generation.wrapping_add(1);
        self.path = path;
        if self.profile == EncodeProfile::Ultra {
            self.ultra.reset_path();
            self.ultra.wire_bps = self.config.start_bps;
            // No old-path sample can seed a new-path delay or capacity estimate.
            self.sent.clear();
            self.sent_order.clear();
        }
        self.groups = InterArrival::default();
        self.trend = Trendline::default();
        self.arrival_clock = None;
        self.acked.clear();
        self.acked_bytes = 0;
        self.sent_window.clear();
        self.sent_window_bytes = 0;
        self.outage = OutageWatch::default();
        self.capacity_bps = None;
        self.last_decrease_us = None;
        self.response_window_us = MIN_DECREASE_INTERVAL_US;
        self.next_decrease_us = 0;
        self.usage = Usage::Normal;
        self.clamp();
    }

    /// The path's measured round trip. Under `lan_rtt_us`, before any overuse, the
    /// target starts at `lan_start_bps`.
    pub fn on_rtt(&mut self, rtt_us: u64) {
        self.response_window_us = rtt_us.max(MIN_DECREASE_INTERVAL_US);
        self.lan_start(rtt_us);
        self.outage.on_rtt(rtt_us);
    }

    /// Under `lan_rtt_us`, before any overuse, the target jumps to `lan_start_bps`.
    fn lan_start(&mut self, rtt_us: u64) {
        // Ultra starts from probes, not from a LAN guess.
        if self.profile == EncodeProfile::Standard
            && rtt_us < self.config.lan_rtt_us
            && self.path != PathKind::DoRelay
            && self.capacity_bps.is_none()
            && self.last_decrease_us.is_none()
            && self.target_bps < self.config.lan_start_bps
        {
            self.target_bps = self.config.lan_start_bps;
            self.clamp();
        }
        self.outage.on_rtt(rtt_us);
    }

    fn unwrap_arrival(&mut self, raw: u32) -> i64 {
        let unwrapped = match self.arrival_clock {
            None => i64::from(raw),
            Some((last_raw, last)) => last + i64::from(raw.wrapping_sub(last_raw) as i32),
        };
        // Track the newest arrival so a late, reordered one does not move the base.
        if self.arrival_clock.is_none_or(|(_, last)| unwrapped >= last) {
            self.arrival_clock = Some((raw, unwrapped));
        }
        unwrapped
    }

    fn prune_sent_window(&mut self, now_us: u64) {
        while self
            .sent_window
            .front()
            .is_some_and(|&(t, _)| now_us.saturating_sub(t) > ACKED_WINDOW_US as u64)
        {
            if let Some((_, b)) = self.sent_window.pop_front() {
                self.sent_window_bytes -= u64::from(b);
            }
        }
    }

    /// The send rate over the last [`ACKED_WINDOW_US`].
    fn sent_bps(&mut self, now_us: u64) -> Option<f64> {
        self.prune_sent_window(now_us);
        let &(first, _) = self.sent_window.front()?;
        let span = now_us.saturating_sub(first).max(ACKED_WINDOW_US as u64 / 5);
        Some(self.sent_window_bytes as f64 * 8.0 * 1e6 / span as f64)
    }

    /// The throughput over the last [`ACKED_WINDOW_US`] of arrivals.
    fn acked_bps(&self) -> Option<f64> {
        let (&(first, _), &(last, _)) = (self.acked.front()?, self.acked.back()?);
        let span = (last - first).max(ACKED_WINDOW_US / 5);
        (self.acked_bytes > 0).then(|| self.acked_bytes as f64 * 8.0 * 1e6 / span as f64)
    }

    /// Processes one feedback received at `now_us`: arrivals and the fraction
    /// of shards lost since the previous feedback (0.0 to 1.0). The target
    /// grows only on evidence (feedback whose arrivals complete a send group
    /// and show no overuse), by time elapsed, never more than
    /// [`MAX_STEP_US`] of growth at once.
    pub fn on_feedback(&mut self, arrivals: &[Arrival], loss: f64, now_us: u64) {
        let before_bps = self.target_bps;
        let (screened, loss) = self.screen_outage(arrivals, loss, now_us);
        let arrivals = &screened[..];
        let mut samples: Vec<(u64, i64, u32)> = arrivals
            .iter()
            .filter_map(|a| {
                let sent = self.sent.remove(&a.transport_seq)?;
                Some((sent.at_us, i64::from(a.arrival_us), sent.bytes))
            })
            .collect();
        samples.sort_unstable_by_key(|s| s.0);
        // A carrier without a round trip of its own (the plain UDP socket) left the start
        // at `start_bps`, and the frame-ack round trip the engine falls back to counts the
        // pacing of a frame sent at that start rate, so it never read as a LAN: a motion
        // share sat at 8 to 14 Mbit/s for its first second and the encoder at 30 fps for
        // seconds after. A datagram's departure to the feedback that reports it is at most
        // the round trip plus the viewer's wait, never less, so a short one is a LAN.
        if let Some(rtt_us) = samples.iter().map(|s| now_us.saturating_sub(s.0)).min() {
            self.lan_start(rtt_us);
        }
        let mut evidence = false;
        let has_samples = !samples.is_empty();
        for (sent_us, raw_arrival, bytes) in samples {
            let arrival = self.unwrap_arrival(raw_arrival as u32);
            if self.profile == EncodeProfile::Ultra {
                self.ultra.observe_delay(sent_us, arrival);
            }
            if bytes > 0 {
                self.acked.push_back((arrival, bytes));
                self.acked_bytes += u64::from(bytes);
            }
            // The send clock is the host's; only differences matter, so i64 is safe.
            let send = sent_us as i64;
            if let Some((send_delta, arrival_delta, at)) = self.groups.add(send, arrival) {
                self.usage = self.trend.update(
                    send_delta as f64 / 1000.0,
                    arrival_delta as f64 / 1000.0,
                    at as f64 / 1000.0,
                );
                evidence = true;
            }
        }
        if let Some(&(newest, _)) = self.acked.back() {
            while self.acked.front().is_some_and(|&(t, _)| newest - t > ACKED_WINDOW_US) {
                if let Some((_, b)) = self.acked.pop_front() {
                    self.acked_bytes -= u64::from(b);
                }
            }
        }
        if self.profile == EncodeProfile::Ultra {
            self.ultra.observe_loss(loss, now_us);
            if self.ultra.capacity_bps.is_some() {
                // Ultra holds its probe-measured rate: only a standing queue, or loss over
                // what FEC covers lasting over a second, cuts it (loss at or under 5% never
                // does), and there is no growth on media feedback. `loss` is after the
                // outage screen: a radio outage's loss is not a cut signal.
                if has_samples || self.ultra.sustained_loss {
                    self.update_ultra(now_us);
                }
                self.clamp();
                return;
            }
            // No train has measured this path yet (a lossy or jittery path's trains yield
            // none): until one does, ultra's rate moves by standard's measured rules
            // below, within ultra's ceiling, rather than sitting at the start rate.
        }
        let overuse = evidence && self.usage == Usage::Overuse;
        if overuse || loss > 0.10 {
            self.decrease(now_us, overuse, loss);
        } else if evidence {
            match self.usage {
                // The queue is draining: hold until it is empty.
                Usage::Underuse | Usage::Overuse => self.last_increase_us = Some(now_us),
                Usage::Normal => self.increase(now_us),
            }
        }
        if self.profile == EncodeProfile::Ultra {
            // Unmeasured ultra (above): the standard rules set the wire rate.
            self.ultra.wire_bps = self.target_bps;
        }
        self.clamp();
        self.after_feedback(before_bps, now_us);
    }

    fn decrease(&mut self, now_us: u64, overuse: bool, loss: f64) {
        self.last_increase_us = Some(now_us);
        // Delay and loss describe the same bottleneck. Give a reduction at least
        // one round trip to take effect before either signal can reduce it again.
        // Keep the deadline fixed if the RTT estimate changes during that window.
        if self.last_decrease_us.is_some() && now_us < self.next_decrease_us {
            return;
        }
        let before = self.target_bps as f64;
        let acked = self.acked_bps();
        let mut target = before;
        if overuse {
            target = before * BETA;
            if let Some(acked) = acked {
                let sending_more = self.sent_bps(now_us).is_some_and(|sent| sent > 1.2 * acked);
                // A quiet screen does not measure capacity. Only cut to delivered
                // throughput when the stream fills the target or is building a queue.
                if acked >= 0.5 * before || sending_more {
                    self.capacity_bps = Some(match self.capacity_bps {
                        Some(c) if (acked - c).abs() < 0.5 * c => 0.7 * c + 0.3 * acked,
                        _ => acked,
                    });
                    target = (BETA * acked).min(before);
                }
            }
        }
        if loss > 0.10 {
            // Combine both candidates against the original target, never apply a
            // second multiplicative cut to the delay reduction in the same report.
            target = target.min(before * (1.0 - 0.5 * loss.min(1.0)));
            if let Some(acked) = acked.filter(|&a| a >= 0.5 * before || loss > 0.3) {
                self.capacity_bps = Some(acked);
                target = target.min(BETA * acked);
            }
        }
        if (target as u64) < self.target_bps {
            self.target_bps = target as u64;
            self.last_decrease_us = Some(now_us);
            self.next_decrease_us = now_us.saturating_add(self.response_window_us);
        }
    }

    fn update_ultra(&mut self, now_us: u64) {
        if self.ultra.cutting() {
            self.usage = Usage::Overuse;
            if self.last_decrease_us.is_none() || now_us >= self.next_decrease_us {
                let before = self.ultra.wire_bps;
                // A standing queue or sustained loss over 5% permits this cut. A low-rate
                // encoder does not turn its throughput into a capacity estimate.
                let mut next = (before as f64 * BETA) as u64;
                if let Some(acked) = self.acked_bps()
                    && self.sent_bps(now_us).is_some_and(|sent| sent > 1.2 * acked)
                {
                    next = next.min((acked * BETA) as u64);
                }
                self.ultra.wire_bps = next.max(1);
                self.last_decrease_us = Some(now_us);
                self.next_decrease_us = now_us.saturating_add(self.response_window_us);
            }
        } else if self.ultra.queue_clear {
            self.usage = Usage::Normal;
            if let Some(held) = self.ultra.held_wire_bps(self.ultra_path_ceiling()) {
                self.ultra.wire_bps = held;
            }
        }
        // There is no multiplicative growth on sparse/idle media feedback.
    }

    fn increase(&mut self, now_us: u64) {
        let dt = self
            .last_increase_us
            .map_or(MAX_STEP_US / 2, |t| now_us.saturating_sub(t).min(MAX_STEP_US));
        self.last_increase_us = Some(now_us);
        let dt_s = dt as f64 / 1e6;
        let target = self.target_bps as f64;
        // Do not run ahead of what the encoder sends (a quiet screen): the target
        // grows only while the stream uses a good share of it.
        if let Some(acked) = self.acked_bps()
            && target > 2.0 * acked + 2_000_000.0
        {
            return;
        }
        let growth = match self.capacity_bps {
            Some(c) if target < 0.8 * c => RECOVER_GROWTH_PER_S,
            Some(c) if target <= 1.25 * c => NEAR_GROWTH_PER_S,
            _ => {
                // Well over the last measured capacity without a queue: it moved.
                self.capacity_bps = None;
                PROBE_GROWTH_PER_S
            }
        };
        let mut next = target * growth.powf(dt_s);
        if let Some(c) = self.capacity_bps
            && growth == RECOVER_GROWTH_PER_S
        {
            next = next.min(0.9 * c).max(target);
        }
        self.target_bps = next as u64;
    }

    fn clamp(&mut self) {
        if self.profile == EncodeProfile::Ultra {
            let ceiling = self
                .ultra
                .held_wire_bps(self.ultra_path_ceiling())
                .unwrap_or_else(|| self.ultra_path_ceiling());
            self.ultra.wire_bps = self.ultra.wire_bps.clamp(1, ceiling);
            self.target_bps = self.ultra.wire_bps.max(1);
            return;
        }
        let max = if self.path == PathKind::DoRelay {
            self.config.max_bps.min(self.config.relay_max_bps)
        } else {
            self.config.max_bps
        };
        self.target_bps = self.target_bps.clamp(self.config.min_bps, max.max(self.config.min_bps));
    }
}

/// D12: outages and the cut floor. Kept apart from the delay and loss responses
/// above, which only see what this screens through.
impl CongestionController {
    /// An outage ended since the last call: the host drops what queued during it,
    /// sends only the newest frame and stops waiting for stale acknowledgements.
    pub fn take_outage_end(&mut self) -> Option<OutageEnd> {
        self.outage.ended.take()
    }

    /// The controller holds its estimate through an outage.
    pub fn frozen(&self) -> bool {
        matches!(self.outage.link, LinkState::Away { .. })
    }

    /// Detects an outage and returns the arrivals and loss the controller may act
    /// on. An outage is feedback going silent while something we sent is
    /// unanswered, or a datagram's one-way delay jumping, by more than max(100 ms, 4 round trips): no queue grows that
    /// fast between two datagrams, a radio that went away does. Its burst (every
    /// datagram sent before the outage was seen) is never timed or counted as
    /// throughput, and until a datagram sent after it arrives nothing cuts or grows.
    fn screen_outage(
        &mut self,
        arrivals: &[Arrival],
        loss: f64,
        now_us: u64,
    ) -> (Vec<Arrival>, f64) {
        let threshold = self.outage.threshold_us();
        // Silence needs a feedback to be silent after: a path's first feedback (at
        // start or after a path change) may be slow to set up, and is not an outage.
        let last_feedback = self.outage.last_feedback_us.replace(now_us);
        let unanswered = self.outage.unanswered_since_us.take();
        let silent = match (last_feedback, unanswered) {
            (Some(feedback), Some(sent)) => now_us.saturating_sub(sent.max(feedback)),
            _ => 0,
        };
        let mut timed: Vec<(u64, u32)> = arrivals
            .iter()
            .filter_map(|a| self.sent.get(&a.transport_seq).map(|s| (s.at_us, a.arrival_us)))
            .filter(|&(sent, _)| sent >= self.outage.burst_sent_before_us)
            .collect();
        timed.sort_unstable_by_key(|t| t.0);
        let mut jump = 0u64;
        for (sent, arrived) in timed {
            if let Some((last_sent, last_arrived)) = self.outage.last_sample {
                if sent < last_sent {
                    continue;
                }
                let arrival_delta = i64::from(arrived.wrapping_sub(last_arrived) as i32);
                let delay_delta = arrival_delta - (sent - last_sent) as i64;
                jump = jump.max(u64::try_from(delay_delta).unwrap_or(0));
            }
            self.outage.last_sample = Some((sent, arrived));
        }
        if silent > threshold || jump > threshold {
            let resume_bps = match self.outage.link {
                LinkState::Away { resume_bps, .. } => resume_bps,
                LinkState::Up => self.target_bps,
            };
            self.outage.link = LinkState::Away { since_us: now_us, resume_bps };
            self.outage.burst_sent_before_us = now_us;
            self.outage.last_sample = None;
            self.outage.ended =
                Some(OutageEnd { silent_us: silent.max(jump), target_bps: resume_bps });
            // The burst's accumulated delay never reaches the trend, and the
            // throughput measured across the hold never becomes the capacity.
            self.groups = InterArrival::default();
            self.trend.rebase();
            self.acked.clear();
            self.acked_bytes = 0;
            self.sent_window.clear();
            self.sent_window_bytes = 0;
            self.usage = Usage::Normal;
        }
        let cutoff = self.outage.burst_sent_before_us;
        let mut kept = Vec::with_capacity(arrivals.len());
        for a in arrivals {
            match self.sent.get(&a.transport_seq) {
                Some(s) if s.at_us < cutoff => {
                    self.sent.remove(&a.transport_seq);
                }
                _ => kept.push(*a),
            }
        }
        let LinkState::Away { since_us, resume_bps } = self.outage.link else {
            return (kept, loss);
        };
        let fresh = kept.iter().any(|a| self.sent.contains_key(&a.transport_seq));
        if fresh || now_us.saturating_sub(since_us) > OUTAGE_FREEZE_MAX_US.max(threshold) {
            // Resume at the rate held before the outage at once, with no climb back,
            // and no growth credited for the frozen time.
            self.outage.link = LinkState::Up;
            self.target_bps = self.target_bps.max(resume_bps);
            self.last_increase_us = Some(now_us);
            self.clamp();
            return (kept, loss);
        }
        (Vec::new(), 0.0)
    }

    /// One response window never cuts the target under [`CUT_FLOOR`] of where it
    /// began, whatever delay or loss asked for: a measurement that a stall made
    /// low cannot collapse the rate to the floor.
    fn after_feedback(&mut self, before_bps: u64, now_us: u64) {
        if self.target_bps >= before_bps {
            return;
        }
        let anchor = match self.outage.cut_window {
            Some((until, anchor)) if now_us < until => anchor,
            _ => {
                self.outage.cut_window =
                    Some((now_us.saturating_add(self.outage.window_us()), before_bps));
                before_bps
            }
        };
        let floor = (anchor as f64 * CUT_FLOOR) as u64;
        if self.target_bps < floor {
            self.target_bps = floor;
            if self.profile == EncodeProfile::Ultra {
                // Unmeasured ultra (`on_feedback`): the wire rate is standard's target.
                self.ultra.wire_bps = floor;
            }
            self.clamp();
        }
    }
}
