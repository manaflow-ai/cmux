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

use cmux_rd_proto::Arrival;

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
    /// first overuse (a LAN carries this at once; a rising delay still cuts it).
    pub lan_start_bps: u64,
    pub lan_rtt_us: u64,
}

impl Default for CcConfig {
    fn default() -> Self {
        Self {
            min_bps: 1_000_000,
            max_bps: 80_000_000,
            start_bps: 8_000_000,
            relay_max_bps: 4_000_000,
            lan_start_bps: 30_000_000,
            lan_rtt_us: 5_000,
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
    /// Throughput measured at overuse, smoothed: the path's capacity until it changes.
    capacity_bps: Option<f64>,
    last_increase_us: Option<u64>,
    last_decrease_us: Option<u64>,
    usage: Usage,
}

impl CongestionController {
    pub fn new(config: CcConfig, path: PathKind) -> Self {
        let mut cc = Self {
            config,
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
            capacity_bps: None,
            last_increase_us: None,
            last_decrease_us: None,
            usage: Usage::Normal,
        };
        cc.clamp();
        cc
    }

    /// The bitrate the encoder should aim for now.
    pub fn target_bps(&self) -> u64 {
        self.target_bps
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

    /// A path change resets the delay baseline and the measured capacity (RTT and
    /// capacity change at once) and applies the relay cap immediately.
    pub fn on_path_changed(&mut self, path: PathKind) {
        self.path = path;
        self.groups = InterArrival::default();
        self.trend = Trendline::default();
        self.arrival_clock = None;
        self.acked.clear();
        self.acked_bytes = 0;
        self.sent_window.clear();
        self.sent_window_bytes = 0;
        self.capacity_bps = None;
        self.last_decrease_us = None;
        self.usage = Usage::Normal;
        self.clamp();
    }

    /// The path's measured round trip. Under `lan_rtt_us`, before any overuse, the
    /// target starts at `lan_start_bps`.
    pub fn on_rtt(&mut self, rtt_us: u64) {
        if rtt_us < self.config.lan_rtt_us
            && self.path != PathKind::DoRelay
            && self.capacity_bps.is_none()
            && self.last_decrease_us.is_none()
            && self.target_bps < self.config.lan_start_bps
        {
            self.target_bps = self.config.lan_start_bps;
            self.clamp();
        }
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
        let mut samples: Vec<(u64, i64, u32)> = arrivals
            .iter()
            .filter_map(|a| {
                let sent = self.sent.remove(&a.transport_seq)?;
                Some((sent.at_us, i64::from(a.arrival_us), sent.bytes))
            })
            .collect();
        samples.sort_unstable_by_key(|s| s.0);
        let mut evidence = false;
        for (sent_us, raw_arrival, bytes) in samples {
            let arrival = self.unwrap_arrival(raw_arrival as u32);
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
        if evidence {
            match self.usage {
                Usage::Overuse => self.decrease(now_us),
                // The queue is draining: hold until it is empty.
                Usage::Underuse => self.last_increase_us = Some(now_us),
                Usage::Normal => self.increase(now_us),
            }
        }
        if loss > 0.10 {
            let before = self.target_bps as f64;
            let mut target = before * (1.0 - 0.5 * loss.min(1.0));
            // Heavy loss while the stream fills the target is a full queue (a queue too
            // short or too fast-filling for the delay trend to see): what still arrives
            // is the capacity, so growth afterwards is slow near it, not a 2x probe.
            if let Some(acked) = self.acked_bps().filter(|&a| a >= 0.5 * before || loss > 0.3) {
                self.capacity_bps = Some(acked);
                // A full queue holds its delay flat, so the cut goes under what arrives.
                target = target.min(BETA * acked);
            }
            self.target_bps = target as u64;
            self.last_increase_us = Some(now_us);
        }
        self.clamp();
    }

    fn decrease(&mut self, now_us: u64) {
        self.last_increase_us = Some(now_us);
        if self
            .last_decrease_us
            .is_some_and(|t| now_us.saturating_sub(t) < MIN_DECREASE_INTERVAL_US)
        {
            return;
        }
        let target = self.target_bps as f64;
        let Some(acked) = self.acked_bps() else {
            self.target_bps = (target * BETA) as u64;
            self.last_decrease_us = Some(now_us);
            return;
        };
        let sending_more = self.sent_bps(now_us).is_some_and(|sent| sent > 1.2 * acked);
        if acked < 0.5 * target && !sending_more {
            // Our own traffic is far under the target and all of it gets through (a quiet
            // screen): the throughput says nothing about the path's capacity. A queue that
            // still grows (the trend filter qualified it) is someone else's; step down from
            // the target, not to our small throughput, so the next motion does not start low.
            self.target_bps = (target * BETA) as u64;
            self.last_decrease_us = Some(now_us);
            return;
        }
        self.capacity_bps = Some(match self.capacity_bps {
            // A capacity far off the last one is a new path condition, not noise.
            Some(c) if (acked - c).abs() < 0.5 * c => 0.7 * c + 0.3 * acked,
            _ => acked,
        });
        self.target_bps = (BETA * acked).min(target) as u64;
        self.last_decrease_us = Some(now_us);
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
        let max = if self.path == PathKind::DoRelay {
            self.config.max_bps.min(self.config.relay_max_bps)
        } else {
            self.config.max_bps
        };
        self.target_bps = self.target_bps.clamp(self.config.min_bps, max.max(self.config.min_bps));
    }
}
