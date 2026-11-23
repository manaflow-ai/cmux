//! Bounded startup/idle bandwidth probes.
//!
//! The planner only makes a train when its caller asks for one. Transport
//! sequence numbers and departure timestamps remain caller-owned so probe
//! packets share the media sequence space without racing the packetizer. A
//! train expires quickly and a capacity estimate is returned only when enough
//! distinct, ordered feedback samples make a conservative dispersion
//! measurement possible.
//!
//! The media engine sends a train as one back-to-back burst (at most
//! [`MAX_PROBE_BYTES`], 128 KB; 16 x MTU by default), not at the configured
//! spacing: a host wakes about once a millisecond, so a spaced train would
//! measure its wakeups. The measurement is the dispersion at the receiver: the
//! bottleneck spreads the burst out, and each probe's socket departure
//! ([`ProbePlanner::record_departure`]) bounds the span from below. The spacing
//! then only orders the enqueue stamps.
//!
//! D10 (amendment 2026-11-17): a held rate comes only from what a train
//! delivered at under 2% loss ([`MAX_PROBE_LOSS_PPM`]). A train is judged once
//! all of it has left and all but under 2% of it has arrived; a lossier train
//! never yields a capacity and expires, so ultra keeps its rate and the next
//! idle probe tries again. Neither does a train that arrived out of the order it
//! left: its spread is the path's jitter, not its capacity.

use cmux_rd_proto::{Arrival, DatagramHeader, DatagramKind, HEADER_LEN, MAX_DATAGRAM_DEFAULT};

/// Hard upper bound on one train's packet count.
pub const MAX_PROBE_PACKETS: usize = 64;
/// Hard upper bound on one train's wire bytes.
pub const MAX_PROBE_BYTES: usize = 128 * 1024;
/// Hard upper bound on the configured probe send rate.
pub const MAX_PROBE_RATE_BPS: u64 = 150_000_000;
/// Hard upper bound on how long an unfinished train may retain state.
pub const MAX_PROBE_EXPIRY_US: u64 = 5_000_000;
/// A train lossier than this (parts per million of its packets, 2%) yields no capacity.
pub const MAX_PROBE_LOSS_PPM: u64 = 20_000;
const MAX_PROBE_SPACING_US: u64 = 1_000_000;
const CLOCK_HALF_RANGE: u32 = u32::MAX / 2;

/// Why the caller requested a train.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProbeReason {
    Startup,
    Idle,
}

/// Limits and wire shape for one probe train.
#[derive(Debug, Clone, Copy)]
pub struct ProbeConfig {
    pub stream: u16,
    /// Wire bytes per probe datagram, including the 16-byte header.
    pub datagram_bytes: usize,
    pub packet_count: usize,
    pub spacing_us: u64,
    pub expiry_us: u64,
    /// At least this many distinct arrivals are required for an estimate.
    pub min_samples: usize,
    /// Maximum wire rate of the train; the hard cap is 150 Mbps.
    pub max_rate_bps: u64,
    /// Capacity estimates are capped before the caller applies its profile
    /// policy (for example, `min(150 Mbps, 0.8 * capacity)`).
    pub max_capacity_bps: u64,
}

impl ProbeConfig {
    /// Creates the normal ultra-link shape for a stream and MTU.
    pub fn for_datagram(stream: u16, datagram_bytes: usize) -> Self {
        Self { stream, datagram_bytes, ..Self::default() }
    }

    fn normalized(self) -> NormalizedConfig {
        let datagram_bytes = self.datagram_bytes.clamp(HEADER_LEN + 1, MAX_DATAGRAM_DEFAULT);
        let max_train_bytes = MAX_PROBE_BYTES.max(datagram_bytes * 2);
        let packet_count =
            self.packet_count.clamp(2, MAX_PROBE_PACKETS).min(max_train_bytes / datagram_bytes);
        let packet_count = packet_count.max(2);
        let requested_spacing_us = self.spacing_us.clamp(1, MAX_PROBE_SPACING_US);
        let max_rate_bps = self.max_rate_bps.clamp(1, MAX_PROBE_RATE_BPS);
        let wire_bits_per_second =
            (datagram_bytes as u64).saturating_mul(8).saturating_mul(1_000_000);
        let rate_spacing_us =
            (wire_bits_per_second + max_rate_bps.saturating_sub(1)) / max_rate_bps;
        let spacing_cap_us = (MAX_PROBE_EXPIRY_US / packet_count as u64).max(1);
        let spacing_us =
            requested_spacing_us.max(rate_spacing_us).min(MAX_PROBE_SPACING_US).min(spacing_cap_us);
        let train_time_us = spacing_us.saturating_mul((packet_count.saturating_sub(1)) as u64);
        let expiry_us = self.expiry_us.max(train_time_us.saturating_add(spacing_us).max(1));
        let expiry_us = expiry_us.min(MAX_PROBE_EXPIRY_US);
        NormalizedConfig {
            stream: self.stream,
            datagram_bytes,
            packet_count,
            spacing_us,
            expiry_us,
            min_samples: self.min_samples.clamp(2, packet_count),
            max_capacity_bps: self.max_capacity_bps.clamp(1, 1_000_000_000),
        }
    }
}

impl Default for ProbeConfig {
    fn default() -> Self {
        Self {
            stream: 0,
            datagram_bytes: MAX_DATAGRAM_DEFAULT,
            packet_count: 16,
            spacing_us: 100,
            expiry_us: 250_000,
            min_samples: 4,
            max_rate_bps: MAX_PROBE_RATE_BPS,
            max_capacity_bps: 1_000_000_000,
        }
    }
}

#[derive(Debug, Clone, Copy)]
struct NormalizedConfig {
    stream: u16,
    datagram_bytes: usize,
    packet_count: usize,
    spacing_us: u64,
    expiry_us: u64,
    min_samples: usize,
    max_capacity_bps: u64,
}

/// Metadata for a train in progress.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProbeTrain {
    pub id: u32,
    pub reason: ProbeReason,
    pub started_us: u64,
    pub expires_us: u64,
    pub packet_count: usize,
    pub first_seq: Option<u16>,
    pub emitted_packets: usize,
    pub emitted_bytes: usize,
}

/// One ready-to-send probe datagram.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProbeDatagram {
    pub train_id: u32,
    pub index: usize,
    pub transport_seq: u16,
    /// Enqueue time; use [`ProbePlanner::record_departure`] for the socket
    /// departure timestamp used by dispersion estimation.
    pub enqueued_us: u64,
    pub departed_us: Option<u64>,
    pub bytes: Vec<u8>,
}

#[derive(Debug, Clone, Copy)]
struct SentProbe {
    transport_seq: u16,
    departed_us: Option<u64>,
    bytes: usize,
}

#[derive(Debug, Clone, Copy)]
struct ReceivedProbe {
    transport_seq: u16,
    arrival_us: u32,
    bytes: usize,
}

#[derive(Debug)]
struct ActiveTrain {
    summary: ProbeTrain,
    next_index: usize,
    next_due_us: u64,
    sent: Vec<SentProbe>,
    received: Vec<ReceivedProbe>,
}

/// Conservative capacity result for one completed train.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProbeEstimate {
    pub train_id: u32,
    pub reason: ProbeReason,
    pub capacity_bps: u64,
    pub received_bytes: usize,
    pub received_packets: usize,
    pub sent_packets: usize,
    pub dispersion_us: u32,
    /// The train's loss, parts per million of its packets (always under
    /// [`MAX_PROBE_LOSS_PPM`]: a lossier train yields no estimate).
    pub loss_ppm: u32,
}

impl ProbeEstimate {
    /// The share of the train that never arrived (0.0 to under 0.02).
    pub fn loss_fraction(&self) -> f64 {
        f64::from(self.loss_ppm) / 1_000_000.0
    }
}

/// A caller-driven, bounded probe train planner and dispersion estimator.
#[derive(Debug)]
pub struct ProbePlanner {
    config: NormalizedConfig,
    next_train_id: u32,
    active: Option<ActiveTrain>,
}

impl ProbePlanner {
    pub fn new(config: ProbeConfig) -> Self {
        Self { config: config.normalized(), next_train_id: 1, active: None }
    }

    /// Begins a train after the caller has made its startup/idle decision.
    /// Sequence numbers are intentionally not reserved here; pass the shared
    /// transport sequence to [`Self::next_packet`].
    pub fn start(&mut self, reason: ProbeReason, now_us: u64) -> Option<ProbeTrain> {
        self.expire(now_us);
        if self.active.is_some() {
            return None;
        }
        let id = self.next_train_id;
        self.next_train_id = self.next_train_id.wrapping_add(1).max(1);
        let summary = ProbeTrain {
            id,
            reason,
            started_us: now_us,
            expires_us: now_us.saturating_add(self.config.expiry_us),
            packet_count: self.config.packet_count,
            first_seq: None,
            emitted_packets: 0,
            emitted_bytes: 0,
        };
        self.active = Some(ActiveTrain {
            summary,
            next_index: 0,
            next_due_us: now_us,
            sent: Vec::with_capacity(self.config.packet_count),
            received: Vec::with_capacity(self.config.packet_count),
        });
        Some(summary)
    }

    /// The active train, if any. It remains active while waiting for feedback.
    pub fn active(&self) -> Option<ProbeTrain> {
        self.active.as_ref().map(|train| train.summary)
    }

    /// The next time the caller may emit a packet for the active train.
    ///
    /// The planner intentionally exposes only a deadline; transport sequence
    /// allocation and actual socket departure remain owned by the caller.
    pub fn next_deadline_us(&self) -> Option<u64> {
        self.active.as_ref().map(|train| train.next_due_us)
    }

    /// Enqueues the next packet when its spacing deadline has arrived.
    /// `transport_seq` and `now_us` are supplied by the shared sender. The
    /// `now_us` value is only an enqueue timestamp; call
    /// [`Self::record_departure`] after the socket accepts the packet.
    pub fn next_packet(&mut self, now_us: u64, transport_seq: u16) -> Option<ProbeDatagram> {
        self.expire(now_us);
        let train = self.active.as_mut()?;
        if train.next_index >= train.summary.packet_count || now_us < train.next_due_us {
            return None;
        }
        let index = train.next_index;
        let mut bytes = Vec::with_capacity(self.config.datagram_bytes);
        DatagramHeader {
            flags: 0,
            kind: DatagramKind::Probe,
            stream: self.config.stream,
            frame: 0,
            index: index as u16,
            count: train.summary.packet_count as u16,
            fec_count: 0,
            transport_seq,
        }
        .encode_into(&mut bytes);
        bytes.resize(self.config.datagram_bytes, 0);
        train.sent.push(SentProbe { transport_seq, departed_us: None, bytes: bytes.len() });
        train.next_index += 1;
        train.next_due_us = now_us.saturating_add(self.config.spacing_us);
        train.summary.first_seq.get_or_insert(transport_seq);
        train.summary.emitted_packets += 1;
        train.summary.emitted_bytes += bytes.len();
        Some(ProbeDatagram {
            train_id: train.summary.id,
            index,
            transport_seq,
            enqueued_us: now_us,
            departed_us: None,
            bytes,
        })
    }

    /// Records the actual socket departure of an enqueued probe. Departure
    /// timestamps are caller-owned so queueing cannot be mistaken for path
    /// dispersion. Returns `false` when the sequence is not in the active
    /// train or was already stamped.
    pub fn record_departure(&mut self, transport_seq: u16, departed_us: u64) -> bool {
        self.expire(departed_us);
        let Some(train) = self.active.as_mut() else { return false };
        if departed_us < train.summary.started_us {
            return false;
        }
        let Some(sample) = train
            .sent
            .iter_mut()
            .find(|sample| sample.transport_seq == transport_seq && sample.departed_us.is_none())
        else {
            return false;
        };
        sample.departed_us = Some(departed_us);
        true
    }

    /// Adds transport feedback and returns an estimate once it is defensible.
    /// Unknown, duplicate and reordered arrivals are ignored. Feedback after
    /// expiry cannot revive a train.
    pub fn on_feedback(&mut self, now_us: u64, arrivals: &[Arrival]) -> Option<ProbeEstimate> {
        self.expire(now_us);
        let train = self.active.as_mut()?;
        for arrival in arrivals {
            if train.received.iter().any(|sample| sample.transport_seq == arrival.transport_seq) {
                continue;
            }
            let Some(sent) =
                train.sent.iter().find(|sample| sample.transport_seq == arrival.transport_seq)
            else {
                continue;
            };
            train.received.push(ReceivedProbe {
                transport_seq: arrival.transport_seq,
                arrival_us: arrival.arrival_us,
                bytes: sent.bytes,
            });
        }
        let estimate = estimate(train, &self.config)?;
        self.active = None;
        Some(estimate)
    }

    fn expire(&mut self, now_us: u64) {
        if self.active.as_ref().is_some_and(|train| now_us >= train.summary.expires_us) {
            self.active = None;
        }
    }
}

fn estimate(train: &ActiveTrain, config: &NormalizedConfig) -> Option<ProbeEstimate> {
    let sent_packets = train.sent.len();
    let received_packets = train.received.len();
    if sent_packets < config.min_samples
        || received_packets < config.min_samples
        || received_packets.saturating_mul(2) < sent_packets
    {
        return None;
    }
    // D10: only a train that arrived with under 2% loss is a capacity. Judge it once
    // all of it has left; until then (or until its expiry) the rest may still arrive.
    if sent_packets < train.summary.packet_count {
        return None;
    }
    let lost = sent_packets.saturating_sub(received_packets) as u64;
    let loss_ppm = lost.saturating_mul(1_000_000) / sent_packets as u64;
    if loss_ppm >= MAX_PROBE_LOSS_PPM {
        return None;
    }
    // A caller-supplied departure is required for every emitted packet. An
    // enqueue timestamp is not a wire observation and must not produce a
    // seemingly precise capacity result.
    if train.sent.iter().any(|sample| sample.departed_us.is_none()) {
        return None;
    }
    if train.sent.windows(2).any(|window| {
        matches!(window, [a, b] if b.departed_us.unwrap_or_default() < a.departed_us.unwrap_or_default())
    }) {
        return None;
    }

    let mut earliest = 0usize;
    let mut span_us = 0u32;
    let mut found_earliest = false;
    for (candidate, sample) in train.received.iter().enumerate() {
        let mut max_distance = 0u32;
        let mut valid = true;
        for other in &train.received {
            let distance = other.arrival_us.wrapping_sub(sample.arrival_us);
            if distance > CLOCK_HALF_RANGE {
                valid = false;
                break;
            }
            max_distance = max_distance.max(distance);
        }
        if valid && max_distance >= span_us {
            earliest = candidate;
            span_us = max_distance;
            found_earliest = true;
        }
    }
    // A train cannot span half of the 32-bit arrival clock. If no candidate
    // was valid, timestamps crossed an ambiguous wrap and the sample is unsafe.
    if !found_earliest {
        return None;
    }
    let earliest_us = train.received.get(earliest)?.arrival_us;
    if train
        .received
        .iter()
        .any(|sample| sample.arrival_us.wrapping_sub(earliest_us) > CLOCK_HALF_RANGE)
    {
        return None;
    }
    // A bottleneck is first in, first out. A train that arrived out of the order it left
    // crossed a path whose per-packet delay varies, and its spread measures that jitter,
    // not a capacity (netem, 15 ms of jitter: 16 x 1.2 KB spread over about 35 ms read as
    // 5 Mbit/s on a link that carried 80). Like a lossy train, it yields none.
    let mut by_departure: Vec<(usize, u32)> = train
        .received
        .iter()
        .filter_map(|sample| {
            let index =
                train.sent.iter().position(|sent| sent.transport_seq == sample.transport_seq)?;
            Some((index, sample.arrival_us.wrapping_sub(earliest_us)))
        })
        .collect();
    by_departure.sort_unstable_by_key(|&(index, _)| index);
    if by_departure.windows(2).any(|pair| matches!(pair, [a, b] if b.1 < a.1)) {
        return None;
    }

    let sent_span_us = train
        .sent
        .first()
        .zip(train.sent.last())
        .map(|(first, last)| {
            last.departed_us
                .unwrap_or_default()
                .saturating_sub(first.departed_us.unwrap_or_default())
        })
        .unwrap_or(0);
    let sent_span_us = u32::try_from(sent_span_us).ok()?;
    span_us = span_us.max(sent_span_us);
    if span_us == 0 {
        return None;
    }

    // The first packet establishes the start of the dispersion interval. Its
    // bytes are excluded, so N packets over N-1 intervals cannot look faster
    // merely because the first packet was counted in the numerator.
    let mut ordered = train.received.clone();
    ordered.sort_by_key(|sample| sample.arrival_us.wrapping_sub(earliest_us));
    let first_bytes = ordered.first()?.bytes;
    let received_bytes = ordered.iter().map(|sample| sample.bytes).sum::<usize>();
    let measured_bytes = received_bytes.checked_sub(first_bytes)?;
    if measured_bytes == 0 {
        return None;
    }
    let bits = (measured_bytes as u128).saturating_mul(8).saturating_mul(1_000_000);
    let capacity_bps =
        (bits / u128::from(span_us)).min(u128::from(config.max_capacity_bps)).try_into().ok()?;
    if capacity_bps == 0 {
        return None;
    }
    Some(ProbeEstimate {
        train_id: train.summary.id,
        reason: train.summary.reason,
        capacity_bps,
        received_bytes,
        received_packets,
        sent_packets,
        dispersion_us: span_us,
        loss_ppm: loss_ppm as u32,
    })
}
