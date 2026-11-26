//! Viewer-side frame reassembly. Collects shards, rebuilds lost data shards
//! from parity, drops frames that miss their deadline, and releases a frame
//! only when its reference frame was released (so a frame that predicts from
//! a lost frame is never decoded and shown corrupted).
//!
//! Nothing waits on a timer: a frame goes out in the call that completes it.
//! A complete frame that depends on no waiting older frame (a keyframe, a
//! tile, or one whose reference is already released) goes out at once and
//! drops the older incomplete frames, which could never be shown after it.
//! A complete frame whose reference still waits for repair waits with it, up
//! to the deadline: skipping it would break the chain and cost a recovery
//! round trip, longer than the repair.

use std::collections::{BTreeMap, VecDeque};

use cmux_rd_proto::{
    DatagramHeader, DatagramKind, FrameBody, MAX_NACK_FRAMES, MAX_NACK_INDEXES, Nack, REF_NONE,
    fec_blocks, flags,
};

use crate::cc::{OUTAGE_FREEZE_MAX_US, outage_threshold_us};
use crate::fec;
use crate::link::ViewerLinkState;

/// A frame ready to decode.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompleteFrame {
    pub frame: u32,
    pub flags: u8,
    pub body: FrameBody,
    /// When the frame's first shard arrived (the caller's clock, as passed to `push`).
    pub first_shard_us: u64,
    /// When the shard that made it decodable arrived (its last needed shard).
    pub last_shard_us: u64,
    /// When it was released to the decoder: later than `last_shard_us` while it
    /// waited for an older frame.
    pub released_us: u64,
}

/// What [`Reassembler`] reports for a frame that will never be released.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameLoss {
    /// Shards still missing at the deadline.
    Incomplete { frame: u32 },
    /// Complete, but its reference frame was never released.
    BrokenReference { frame: u32, ref_frame: u32 },
}

/// The NACK schedule's intervals, read once per call.
struct Timing {
    nack_after_us: u64,
    /// The reorder grace counts from when each gap is first seen
    /// ([`Reassembler::set_gap_grace`]).
    gap_grace: bool,
    deadline_us: u64,
    window_us: u64,
    /// The D12 outage threshold ([`crate::cc::outage_threshold_us`]): no frame
    /// is given up sooner than this after its first shard.
    outage_us: u64,
    /// The link's time away so far, the current outage included: the
    /// give-up clock stands still for it.
    away_us: u64,
}

#[derive(Debug)]
struct Pending {
    /// The link's time away when this frame's first shard arrived: the time
    /// away since then is what this frame's give-up clock skips.
    away_base_us: u64,
    first_seen_us: u64,
    last_seen_us: u64,
    /// When the frame first had enough shards to decode.
    complete_us: Option<u64>,
    highest_index: u16,
    /// When each data shard was last requested, and how often (`None`: never). Each
    /// shard keeps its own retry clock: a gap exposed after the frame's first request
    /// is asked for at once, not a whole retry interval later (that wait was most of
    /// the ~45 ms one lost shard cost at 1% loss).
    nacked: Vec<Option<NackMark>>,
    /// When each missing data shard was first seen missing (a higher index
    /// of this frame arrived): its reorder grace counts from then, so a shard
    /// overtaken in a burst is not requested the moment the gap shows.
    gap_seen_us: Vec<Option<u64>>,
    flags: u8,
    count: u16,
    shard_len: Option<usize>,
    shards: Vec<Option<Vec<u8>>>,
    /// Received payload bytes counted against [`MAX_PENDING_BYTES`] (shards
    /// rebuilt from parity are not counted).
    held: usize,
    /// The rebuilt body once the frame is decodable (`Err`: it did not
    /// rebuild or parse). Kept so a frame is rebuilt once.
    body: Option<Result<FrameBody, ()>>,
}

#[derive(Debug, Clone, Copy)]
struct NackMark {
    at_us: u64,
    /// When the shard was first requested: the frame's give-up counts from it.
    first_us: u64,
    times: u8,
}

/// The shortest RTT-derived NACK retry ([`Reassembler::set_rtt_nack_retry`]),
/// whatever the measured repair round trip.
pub const NACK_RETRY_FLOOR_US: u64 = 5_000;

/// Reassembly state for one display stream.
#[derive(Debug)]
pub struct Reassembler {
    /// The longest a frame may wait for missing shards: the ceiling of the
    /// repair window, and a hard cap counted from the frame's first shard.
    deadline_us: u64,
    /// The reorder grace before a gap is NACKed, for the give-up schedule
    /// (the NACK calls take their own).
    nack_after_us: u64,
    /// The reorder grace counts from when each gap is first seen
    /// ([`Self::set_gap_grace`]); off: from the frame's first shard.
    gap_grace: bool,
    /// Retry NACKs at an interval derived from the measured repair round trip
    /// ([`Self::set_rtt_nack_retry`]); off: at the caller's `retry_us`.
    rtt_retry: bool,
    /// The session's round trip from outside (clock pings, the link's path).
    path_rtt_us: Option<u64>,
    /// Smoothed round trip from a NACK to the shard it asked for, and its
    /// deviation, from shards asked for once (the answer to a retried shard is
    /// ambiguous).
    repair_rtt: RttEstimator,
    /// Recent gaps between the first shards of new frames (the frame interval).
    frame_gaps: VecDeque<u64>,
    /// The newest frame seen so far and when its first shard arrived.
    newest_started: Option<(u32, u64)>,
    pending: BTreeMap<u32, Pending>,
    /// Newest frame released to the decoder (0 = none).
    last_released: u32,
    /// Frames at or below this number are finished (released or lost).
    finished_through: u32,
    losses: Vec<FrameLoss>,
    need_recovery: bool,
    pending_bytes: usize,
    /// Recently released frames that a recovery frame may reference.
    released_recent: VecDeque<u32>,
    /// Whether the link is up or away (an outage, design D12), from the
    /// arrivals of datagrams of any kind.
    link: ViewerLinkState,
}

/// Most payload bytes held for incomplete frames; shards beyond it are ignored.
pub const MAX_PENDING_BYTES: usize = 32 << 20;

/// Most frames waiting for shards at once; datagrams of further frames are ignored.
pub const MAX_PENDING_FRAMES: usize = 64;

/// How far ahead of the newest finished frame a frame number may be.
pub const MAX_FRAME_LEAD: u32 = 4096;

/// Released frames a recovery frame may reference.
pub const RECOVERY_WINDOW: usize = 64;

/// The reorder grace before a gap is NACKed, unless the caller sets another.
pub const NACK_AFTER_US: u64 = 5_000;

/// What the repair window adds to the round trip for the host's turnaround
/// and jitter (design D6: give up after RTT + 10 ms).
pub const REPAIR_MARGIN_US: u64 = 10_000;

/// Frame intervals the repair window never goes under, so a round trip
/// measured too short does not give up frames a repair would have saved.
pub const MIN_REPAIR_FRAMES: u64 = 2;

/// Repair windows a frame waits after its newest gap was first requested,
/// so the request and a retry each get one round trip: at 1% loss about 2%
/// of single requests fail, and the retry turns those frames from losses (a
/// recovery frame and a stall) into one more window. Never past the
/// deadline, so on a long path the wait is the base's 200 ms.
pub const REPAIR_WINDOWS: u64 = 2;

/// The frame interval assumed until frames arrive (60 fps).
pub const DEFAULT_FRAME_INTERVAL_US: u64 = 16_667;
/// Bounds of the measured frame interval (120 fps to 30 fps), so a burst or an
/// idle screen does not move the floor of the repair window far.
const MIN_FRAME_INTERVAL_US: u64 = 8_333;
const MAX_FRAME_INTERVAL_US: u64 = 33_333;

/// Samples kept for the repair round trip and the frame interval.
const TIMING_SAMPLES: usize = 16;

/// Repair samples needed before they count toward the round trip.
const MIN_REPAIR_SAMPLES: u32 = 3;

/// A smoothed round trip and its variation, as TCP keeps them (RFC 6298:
/// SRTT and RTTVAR with gains 1/8 and 1/4). Timers wait SRTT + 4 RTTVAR, so
/// one fast or slow sample moves them a little and a jittery path waits
/// longer than a steady one.
#[derive(Debug, Clone, Default)]
pub struct RttEstimator {
    srtt_us: u64,
    rttvar_us: u64,
    samples: u32,
}

impl RttEstimator {
    /// Adds one round-trip sample.
    pub fn sample(&mut self, rtt_us: u64) {
        if self.samples == 0 {
            self.srtt_us = rtt_us;
            self.rttvar_us = rtt_us / 2;
        } else {
            let err = self.srtt_us.abs_diff(rtt_us);
            self.rttvar_us = (self.rttvar_us.saturating_mul(3).saturating_add(err)) / 4;
            self.srtt_us = (self.srtt_us.saturating_mul(7).saturating_add(rtt_us)) / 8;
        }
        self.samples = self.samples.saturating_add(1);
    }

    /// The smoothed round trip (SRTT), once a sample arrived.
    pub fn smoothed_us(&self) -> Option<u64> {
        (self.samples > 0).then_some(self.srtt_us)
    }

    /// SRTT + 4 RTTVAR, once at least `min_samples` samples arrived.
    pub fn estimate_us(&self, min_samples: u32) -> Option<u64> {
        (self.samples >= min_samples.max(1))
            .then(|| self.srtt_us.saturating_add(self.rttvar_us.saturating_mul(4)))
    }
}

/// The repair window for a path with round trip `rtt_us`: RTT + 10 ms, at
/// least [`MIN_REPAIR_FRAMES`] frame intervals, at most `ceiling_us`. With no
/// round trip known yet, the ceiling.
pub fn repair_window_us(rtt_us: Option<u64>, frame_interval_us: u64, ceiling_us: u64) -> u64 {
    let floor = frame_interval_us.saturating_mul(MIN_REPAIR_FRAMES).min(ceiling_us);
    rtt_us.map_or(ceiling_us, |rtt| rtt.saturating_add(REPAIR_MARGIN_US).clamp(floor, ceiling_us))
}

fn median(samples: &VecDeque<u64>) -> Option<u64> {
    let mut sorted: Vec<u64> = samples.iter().copied().collect();
    sorted.sort_unstable();
    sorted.get(sorted.len() / 2).copied()
}

fn push_sample(samples: &mut VecDeque<u64>, sample: u64) {
    if samples.len() >= TIMING_SAMPLES {
        samples.pop_front();
    }
    samples.push_back(sample);
}

impl Reassembler {
    /// `deadline_us`: the longest a frame may wait for missing shards. A
    /// missing shard is NACKed after the caller's reorder grace, again every
    /// retry interval ([`Self::nack_retry_us`]) while missing, and the frame is given up
    /// [`REPAIR_WINDOWS`] repair windows ([`Self::repair_window_us`]) after
    /// its newest gap's first request, never later than `deadline_us`.
    pub fn new(deadline_us: u64) -> Self {
        Self::with_nack_after(deadline_us, NACK_AFTER_US)
    }

    /// As [`Self::new`], with a reorder grace of `nack_after_us` before a gap is NACKed.
    pub fn with_nack_after(deadline_us: u64, nack_after_us: u64) -> Self {
        Self {
            deadline_us,
            nack_after_us,
            gap_grace: false,
            rtt_retry: false,
            path_rtt_us: None,
            repair_rtt: RttEstimator::default(),
            frame_gaps: VecDeque::new(),
            newest_started: None,
            pending: BTreeMap::new(),
            last_released: 0,
            finished_through: 0,
            losses: Vec::new(),
            need_recovery: false,
            pending_bytes: 0,
            released_recent: VecDeque::new(),
            link: ViewerLinkState::default(),
        }
    }

    /// Records that a datagram of any kind arrived on the link at `now_us`
    /// (video goes through [`Self::push`], which records it too): an outage
    /// in progress ends.
    pub fn note_datagram(&mut self, now_us: u64) {
        let rtt = self.rtt_us();
        self.link.on_arrival(now_us, rtt);
    }

    /// True while the link is away (silent past
    /// [`crate::cc::outage_threshold_us`]).
    pub fn link_away(&self, now_us: u64) -> bool {
        self.link.is_away(now_us, self.rtt_us())
    }

    /// The session's round trip as measured outside reassembly (clock pings,
    /// the link's path probe); `None` when unknown.
    pub fn set_path_rtt_us(&mut self, rtt_us: Option<u64>) {
        self.path_rtt_us = rtt_us;
    }

    /// The round trip a repair takes: the larger of the path's round trip and
    /// the smoothed NACK-to-repair time plus its variation once a few repairs
    /// arrived.
    pub fn rtt_us(&self) -> Option<u64> {
        let repair = self.repair_rtt.estimate_us(MIN_REPAIR_SAMPLES);
        match (self.path_rtt_us, repair) {
            (Some(a), Some(b)) => Some(a.max(b)),
            (a, b) => a.or(b),
        }
    }

    /// The interval between frames, from recent first-shard arrivals.
    pub fn frame_interval_us(&self) -> u64 {
        median(&self.frame_gaps)
            .unwrap_or(DEFAULT_FRAME_INTERVAL_US)
            .clamp(MIN_FRAME_INTERVAL_US, MAX_FRAME_INTERVAL_US)
    }

    /// How long a frame waits for its NACKed shards before it is given up.
    pub fn repair_window_us(&self) -> u64 {
        repair_window_us(self.rtt_us(), self.frame_interval_us(), self.deadline_us)
    }

    /// Counts each gap's reorder grace from when the gap is first seen (a
    /// higher shard of its frame arrived), not from the frame's first shard:
    /// a shard overtaken late in a frame's arrival is not requested the
    /// moment the gap shows. Off by default.
    pub fn set_gap_grace(&mut self, on: bool) {
        self.gap_grace = on;
    }

    /// Retries NACKs every `max(2 x smoothed repair RTT + 4 x its deviation,
    /// NACK_RETRY_FLOOR_US)`, at most the caller's `retry_us`, once a repair was
    /// measured. Off by default: a retry sooner than the caller's cadence can ask
    /// again for a resend that was only slow, so the host sends it twice.
    pub fn set_rtt_nack_retry(&mut self, on: bool) {
        self.rtt_retry = on;
    }

    /// The smoothed round trip from a NACK to its repaired shard, once measured.
    pub fn repair_rtt_us(&self) -> Option<u64> {
        self.repair_rtt.smoothed_us()
    }

    /// The NACK retry interval in force for a caller cadence of `retry_us`.
    pub fn nack_retry_us(&self, retry_us: u64) -> u64 {
        let retry_us = retry_us.max(1);
        match self.repair_rtt.smoothed_us() {
            Some(srtt) if self.rtt_retry => srtt
                .saturating_mul(2)
                .saturating_add(self.repair_rtt.rttvar_us.saturating_mul(4))
                .max(NACK_RETRY_FLOOR_US)
                .min(retry_us),
            _ => retry_us,
        }
    }

    /// Newest frame released to the decoder (the feedback `acked_frame`).
    pub fn last_released(&self) -> u32 {
        self.last_released
    }

    /// True after a loss until a keyframe or a frame that references
    /// [`Self::last_released`] is released.
    pub fn need_recovery(&self) -> bool {
        self.need_recovery
    }

    /// Takes the losses recorded since the last call.
    pub fn take_losses(&mut self) -> Vec<FrameLoss> {
        std::mem::take(&mut self.losses)
    }

    /// Adds one video or parity datagram received at `now_us`. Returns the
    /// frames that became ready, oldest first.
    pub fn push(
        &mut self,
        header: &DatagramHeader,
        payload: &[u8],
        now_us: u64,
    ) -> Vec<CompleteFrame> {
        self.note_datagram(now_us);
        self.expire(now_us);
        let too_far = self.finished_through != 0
            && header.frame > self.finished_through.saturating_add(MAX_FRAME_LEAD);
        let no_room =
            self.pending.len() >= MAX_PENDING_FRAMES && !self.pending.contains_key(&header.frame);
        if !matches!(header.kind, DatagramKind::Video | DatagramKind::Fec | DatagramKind::UpMedia)
            || header.frame <= self.finished_through
            || too_far
            || no_room
        {
            self.expire(now_us);
            return self.release_ready(now_us);
        }
        let total = usize::from(header.count) + usize::from(header.fec_count);
        match self.newest_started {
            Some((frame, _)) if header.frame <= frame => {}
            Some((_, at)) => {
                if now_us > at {
                    push_sample(&mut self.frame_gaps, now_us - at);
                }
                self.newest_started = Some((header.frame, now_us));
            }
            None => self.newest_started = Some((header.frame, now_us)),
        }
        let away_base_us = self.link.away_total_us();
        let entry = self.pending.entry(header.frame).or_insert_with(|| Pending {
            away_base_us,
            first_seen_us: now_us,
            last_seen_us: now_us,
            complete_us: None,
            highest_index: header.index,
            nacked: vec![None; usize::from(header.count)],
            gap_seen_us: vec![None; usize::from(header.count)],
            flags: header.flags,
            count: header.count,
            shard_len: None,
            shards: vec![None; total],
            held: 0,
            body: None,
        });
        // Every shard of a frame has the same length (the session's shard size); a shard
        // of another length is refused, and pending payload bytes are capped.
        let shard_len_ok = entry.shard_len.is_none_or(|l| l == payload.len());
        let mut repair_sample = None;
        if entry.shards.len() == total
            && entry.count == header.count
            && shard_len_ok
            && self.pending_bytes + payload.len() <= MAX_PENDING_BYTES
            && entry.shards.get(usize::from(header.index)).is_some_and(Option::is_none)
        {
            entry.shard_len = Some(payload.len());
            // A shard requested once arriving times the repair round trip.
            if let Some(Some(mark)) = entry.nacked.get(usize::from(header.index))
                && mark.times == 1
            {
                repair_sample = Some(now_us.saturating_sub(mark.at_us));
            }
            entry.last_seen_us = now_us;
            // Data shards this arrival skipped over are gaps from now on. Those
            // under the previous highest index were marked when it arrived.
            let index = usize::from(header.index);
            let from = if entry.held == 0 { 0 } else { usize::from(entry.highest_index) + 1 };
            for j in from..index.min(usize::from(entry.count)) {
                if entry.shards.get(j).is_some_and(Option::is_none)
                    && let Some(seen) = entry.gap_seen_us.get_mut(j)
                {
                    seen.get_or_insert(now_us);
                }
            }
            entry.highest_index = entry.highest_index.max(header.index);
            self.pending_bytes += payload.len();
            entry.held += payload.len();
            if let Some(slot) = entry.shards.get_mut(index) {
                *slot = Some(payload.to_vec());
            }
            if entry.complete_us.is_none() && Self::decodable(entry) {
                entry.complete_us = Some(now_us);
            }
        }
        if let Some(sample) = repair_sample {
            self.repair_rtt.sample(sample);
        }
        self.expire(now_us);
        self.release_ready(now_us)
    }

    /// Advances time with no new datagram: drops frames past their deadline.
    pub fn tick(&mut self, now_us: u64) -> Vec<CompleteFrame> {
        self.expire(now_us);
        self.release_ready(now_us)
    }

    /// Missing data shard indexes of incomplete frames that waited at least
    /// `after_us`, for NACKs.
    pub fn missing(&self, now_us: u64, after_us: u64) -> Vec<(u32, Vec<u16>)> {
        self.pending
            .iter()
            .filter(|(_, p)| {
                now_us.saturating_sub(p.first_seen_us) >= after_us && !Self::decodable(p)
            })
            .map(|(&frame, p)| {
                let missing =
                    (0..p.count).filter(|&i| p.shards[usize::from(i)].is_none()).collect();
                (frame, missing)
            })
            .collect()
    }

    /// The next missing-shard request: first after the reorder grace, then
    /// at the retry cadence. Each shard has its own deadline, so neither a
    /// request for another frame nor one for another shard of the same frame
    /// can delay its repair request.
    pub fn next_nack_us(&self, after_us: u64, retry_us: u64) -> Option<u64> {
        let retry_us = self.nack_retry_us(retry_us);
        let grace = self.gap_grace;
        self.pending
            .values()
            .filter(|p| !Self::decodable(p))
            .filter_map(|p| Self::nack_at(p, after_us, retry_us, grace))
            .min()
    }

    fn timing(&self) -> Timing {
        Timing {
            nack_after_us: self.nack_after_us,
            gap_grace: self.gap_grace,
            deadline_us: self.deadline_us,
            window_us: self.repair_window_us(),
            outage_us: outage_threshold_us(self.rtt_us()),
            away_us: self.link.away_total_us(),
        }
    }

    /// [`Self::timing`] with the time away at `now_us`, the current outage included.
    fn timing_at(&self, now_us: u64) -> Timing {
        Timing { away_us: self.link.away_total_us_at(now_us, self.rtt_us()), ..self.timing() }
    }

    /// When the earliest missing data shard of `p` is due for a request.
    fn nack_at(p: &Pending, after_us: u64, retry_us: u64, grace: bool) -> Option<u64> {
        (0..usize::from(p.count))
            .filter(|&i| p.shards.get(i).is_some_and(Option::is_none))
            .map(|i| Self::shard_nack_at(p, i, after_us, retry_us, grace))
            .min()
    }

    fn shard_nack_at(p: &Pending, i: usize, after_us: u64, retry_us: u64, grace: bool) -> u64 {
        match p.nacked.get(i).copied().flatten() {
            Some(mark) => mark.at_us.saturating_add(retry_us),
            None => Self::first_request_due(p, i, after_us, grace),
        }
    }

    /// When missing data shard `i`, not requested yet, is due. A large frame
    /// may still be arriving after the reorder grace: an observed gap can be
    /// requested after the grace (from when the gap was first seen with the
    /// gap grace on, else from the frame's first shard); its unseen tail only
    /// becomes a gap after arrivals stop for a grace period.
    fn first_request_due(p: &Pending, i: usize, after_us: u64, grace: bool) -> u64 {
        if i >= Self::observed_data(p) {
            return p.last_seen_us.saturating_add(after_us);
        }
        let seen = if grace { p.gap_seen_us.get(i).copied().flatten() } else { None };
        seen.unwrap_or(p.first_seen_us).saturating_add(after_us)
    }

    /// When the first request of a gap not requested yet is due, if any.
    fn first_request_at(p: &Pending, after_us: u64, grace: bool) -> Option<u64> {
        (0..usize::from(p.count))
            .filter(|&i| {
                p.shards.get(i).is_some_and(Option::is_none)
                    && p.nacked.get(i).is_some_and(Option::is_none)
            })
            .map(|i| Self::first_request_due(p, i, after_us, grace))
            .min()
    }

    fn observed_data(p: &Pending) -> usize {
        (usize::from(p.highest_index) + 1).min(usize::from(p.count))
    }

    /// Takes the due NACKs that fit in one feedback packet: the shards whose
    /// own request is due. Only shards actually requested advance their retry
    /// deadlines. Repaired frames disappear from this schedule as soon as
    /// their data is complete.
    pub fn take_nacks(&mut self, now_us: u64, after_us: u64, retry_us: u64) -> Vec<Nack> {
        let retry_us = self.nack_retry_us(retry_us);
        let grace = self.gap_grace;
        self.pending
            .iter_mut()
            .filter(|(_, p)| {
                !Self::decodable(p)
                    && Self::nack_at(p, after_us, retry_us, grace).is_some_and(|at| now_us >= at)
            })
            .take(MAX_NACK_FRAMES)
            .map(|(&frame, p)| {
                let indexes: Vec<u16> = (0..usize::from(p.count))
                    .filter(|&i| {
                        p.shards.get(i).is_some_and(Option::is_none)
                            && now_us >= Self::shard_nack_at(p, i, after_us, retry_us, grace)
                    })
                    .take(MAX_NACK_INDEXES)
                    .map(|i| i as u16)
                    .collect();
                for &i in &indexes {
                    if let Some(slot) = p.nacked.get_mut(usize::from(i)) {
                        let (first_us, times) = slot.map_or((now_us, 0), |m| (m.first_us, m.times));
                        *slot = Some(NackMark {
                            at_us: now_us,
                            first_us,
                            times: times.saturating_add(1),
                        });
                    }
                }
                Nack { frame, indexes }
            })
            .collect()
    }

    /// The earliest time at which [`Self::tick`] drops an incomplete frame,
    /// or `None` when no frame waits. Callers arm one timer for it instead of
    /// ticking on a fixed period.
    ///
    /// An outage that starts before a frame's give-up time holds its clock,
    /// so with nothing arriving it is given up only once the pause runs out
    /// ([`OUTAGE_FREEZE_MAX_US`]); an arrival moves the time again.
    pub fn next_expiry_us(&self) -> Option<u64> {
        let t = self.timing();
        let last_arrival = self.link.last_arrival_us();
        self.pending
            .values()
            .filter(|p| !Self::decodable(p))
            .map(|p| {
                let unpaused = Self::give_up_unpaused_at(p, &t);
                let at = Self::give_up_at(p, &t).saturating_add(1);
                match last_arrival {
                    // Inside the current silence: an arrival decides it (the
                    // push expires the frame then); with none, the silence
                    // becomes an outage and the clock stands still until the cap.
                    Some(last) if at > last => {
                        unpaused.saturating_add(OUTAGE_FREEZE_MAX_US).saturating_add(1)
                    }
                    _ => at,
                }
            })
            .min()
    }

    /// When an incomplete frame is given up: [`REPAIR_WINDOWS`] repair
    /// windows after its newest gap was first requested (or is due to be, or
    /// after the time its tail would be NACKed when shards kept arriving),
    /// and never later than the deadline from its first shard: the base's
    /// wait is the most a frame waits. Both stand still while the link is
    /// away (an outage, design D12), for at most [`OUTAGE_FREEZE_MAX_US`].
    fn give_up_at(p: &Pending, t: &Timing) -> u64 {
        let paused = t.away_us.saturating_sub(p.away_base_us).min(OUTAGE_FREEZE_MAX_US);
        Self::give_up_unpaused_at(p, t).saturating_add(paused)
    }

    fn give_up_unpaused_at(p: &Pending, t: &Timing) -> u64 {
        let tail_nack = p.last_seen_us.saturating_add(t.nack_after_us);
        let newest_first_request = (0..usize::from(p.count))
            .filter(|&i| p.shards.get(i).is_some_and(Option::is_none))
            .filter_map(|i| p.nacked.get(i).copied().flatten().map(|m| m.first_us))
            .max();
        let first_request = Self::first_request_at(p, t.nack_after_us, t.gap_grace);
        let from = [Some(tail_nack), newest_first_request, first_request]
            .into_iter()
            .flatten()
            .max()
            .unwrap_or(tail_nack);
        // Never sooner than the outage threshold from the first shard: a hold
        // shorter than it is not an outage, so the give-up pause never starts,
        // and a frame given up inside it would be one its burst completes.
        from.saturating_add(t.window_us.saturating_mul(REPAIR_WINDOWS))
            .max(p.first_seen_us.saturating_add(t.outage_us))
            .min(p.first_seen_us.saturating_add(t.deadline_us))
    }

    /// A give-up time `at` that fell inside the link's current silence waits
    /// until the silence is known to be an outage or not: an arrival before
    /// the outage threshold ([`crate::cc::outage_threshold_us`]) gives the
    /// frame up then, and past it the outage's time away holds its clock.
    fn silence_may_be_outage(&self, at: u64, now_us: u64) -> bool {
        let rtt = self.rtt_us();
        match (self.link.last_arrival_us(), self.link.away_from_us(rtt)) {
            (Some(last), Some(from)) => at > last && now_us <= from,
            _ => false,
        }
    }

    fn decodable(p: &Pending) -> bool {
        let count = usize::from(p.count);
        if p.shards.iter().filter(|s| s.is_some()).count() < count {
            return false;
        }
        // A frame over one FEC block needs enough shards in every block (design D6).
        let blocks = Self::blocks(p);
        blocks == 1
            || p.shards.get(..count).is_some_and(|data| data.iter().all(Option::is_some))
            || fec::decodable_blocks(&p.shards, count, blocks)
    }

    /// The frame's FEC blocks (cmux-rd-proto `fec_blocks`): one unless it is larger.
    fn blocks(p: &Pending) -> usize {
        let parity = p.shards.len().saturating_sub(usize::from(p.count));
        fec_blocks(p.count, u16::try_from(parity).unwrap_or(u16::MAX))
    }

    fn expire(&mut self, now_us: u64) {
        let t = self.timing_at(now_us);
        let expired: Vec<u32> = self
            .pending
            .iter()
            .filter(|(_, p)| {
                let at = Self::give_up_at(p, &t);
                !Self::decodable(p) && now_us > at && !self.silence_may_be_outage(at, now_us)
            })
            .map(|(&f, _)| f)
            .collect();
        for frame in expired {
            self.take_pending(&frame);
            self.lose(frame);
        }
        // Frames older than a finished frame can never be released in order.
        let stale: Vec<u32> =
            self.pending.range(..=self.finished_through).map(|(&f, _)| f).collect();
        for frame in stale {
            self.take_pending(&frame);
            self.lose(frame);
        }
    }

    /// The frame to try next: the oldest pending frame if it is decodable,
    /// else the oldest decodable frame that needs none of the older waiting
    /// frames (a keyframe, a tile, or a frame whose reference was released).
    fn next_candidate(&mut self) -> Option<u32> {
        let (&oldest, p) = self.pending.iter().next()?;
        if Self::decodable(p) {
            return Some(oldest);
        }
        let (last_released, recent) = (self.last_released, &self.released_recent);
        for (&frame, p) in self.pending.iter_mut().skip(1) {
            if !Self::decodable(p) {
                continue;
            }
            // A tile frame is standalone too, so a complete one skips older gaps.
            if p.flags & (flags::KEYFRAME | flags::TILE) != 0 {
                return Some(frame);
            }
            let recovery = p.flags & flags::RECOVERY != 0;
            let Ok(body) = Self::assemble(p) else { continue };
            if body.ref_frame == REF_NONE
                || (last_released != 0 && body.ref_frame == last_released)
                || (recovery && recent.contains(&body.ref_frame))
            {
                return Some(frame);
            }
        }
        None
    }

    /// Rebuilds and parses a decodable frame's body, once.
    fn assemble(p: &mut Pending) -> &Result<FrameBody, ()> {
        let (count, blocks) = (usize::from(p.count), Self::blocks(p));
        let shards = &mut p.shards;
        p.body.get_or_insert_with(|| {
            fec::reconstruct_blocks(shards, count, blocks).map_err(|_| ())?;
            let bytes: Vec<u8> = shards[..count].iter().flatten().flatten().copied().collect();
            FrameBody::decode(&bytes).map_err(|_| ())
        })
    }

    /// Removes a pending frame and releases its bytes from the budget.
    fn take_pending(&mut self, frame: &u32) -> Option<Pending> {
        let p = self.pending.remove(frame)?;
        self.pending_bytes = self.pending_bytes.saturating_sub(p.held);
        Some(p)
    }

    fn lose(&mut self, frame: u32) {
        self.losses.push(FrameLoss::Incomplete { frame });
        self.need_recovery = true;
        self.finished_through = self.finished_through.max(frame);
    }

    fn complete(frame: u32, p: &Pending, body: FrameBody, now_us: u64) -> CompleteFrame {
        CompleteFrame {
            frame,
            flags: p.flags,
            body,
            first_shard_us: p.first_seen_us,
            last_shard_us: p.complete_us.unwrap_or(p.last_seen_us),
            released_us: now_us,
        }
    }

    fn release_ready(&mut self, now_us: u64) -> Vec<CompleteFrame> {
        let mut out = Vec::new();
        while let Some(frame) = self.next_candidate() {
            let older: Vec<u32> = self.pending.range(..frame).map(|(&f, _)| f).collect();
            for f in older {
                self.take_pending(&f);
                self.lose(f);
            }
            let Some(mut p) = self.take_pending(&frame) else { break };
            Self::assemble(&mut p);
            let Some(Ok(body)) = p.body.take() else {
                self.lose(frame);
                continue;
            };
            self.finished_through = self.finished_through.max(frame);
            if p.flags & flags::TILE != 0 {
                // A tile top-off (rd change C3) depends on no frame of this
                // stream; its ref_frame names the surface stream's video frame.
                self.last_released = frame;
                self.need_recovery = false;
                out.push(Self::complete(frame, &p, body, now_us));
                continue;
            }
            let keyframe = p.flags & flags::KEYFRAME != 0 || body.ref_frame == REF_NONE;
            let referenced = self.last_released != 0 && body.ref_frame == self.last_released;
            let recovers =
                p.flags & flags::RECOVERY != 0 && self.released_recent.contains(&body.ref_frame);
            if keyframe || referenced || recovers {
                self.last_released = frame;
                if keyframe {
                    // An IDR flushes every reference before it.
                    self.released_recent.clear();
                }
                if self.released_recent.len() >= RECOVERY_WINDOW {
                    self.released_recent.pop_front();
                }
                self.released_recent.push_back(frame);
                self.need_recovery = false;
                out.push(Self::complete(frame, &p, body, now_us));
            } else {
                self.losses.push(FrameLoss::BrokenReference { frame, ref_frame: body.ref_frame });
                self.need_recovery = true;
            }
        }
        out
    }
}
