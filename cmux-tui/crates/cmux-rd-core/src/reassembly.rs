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

use crate::fec;

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

#[derive(Debug)]
struct Pending {
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
    times: u8,
}

/// The shortest RTT-derived NACK retry ([`Reassembler::set_rtt_nack_retry`]),
/// whatever the measured repair round trip.
pub const NACK_RETRY_FLOOR_US: u64 = 5_000;

/// Reassembly state for one display stream.
#[derive(Debug)]
pub struct Reassembler {
    deadline_us: u64,
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
    /// Retry NACKs at an interval derived from the measured repair round trip
    /// ([`Self::set_rtt_nack_retry`]); off: at the caller's `retry_us`.
    rtt_retry: bool,
    /// Smoothed round trip from a NACK to the shard it asked for, and its deviation,
    /// from shards asked for once (the answer to a retried shard is ambiguous).
    repair_srtt_us: Option<u64>,
    repair_rttvar_us: u64,
}

/// Most payload bytes held for incomplete frames; shards beyond it are ignored.
pub const MAX_PENDING_BYTES: usize = 32 << 20;

/// Most frames waiting for shards at once; datagrams of further frames are ignored.
pub const MAX_PENDING_FRAMES: usize = 64;

/// How far ahead of the newest finished frame a frame number may be.
pub const MAX_FRAME_LEAD: u32 = 4096;

/// Released frames a recovery frame may reference.
pub const RECOVERY_WINDOW: usize = 64;

impl Reassembler {
    /// `deadline_us`: how long a frame may wait for missing shards.
    pub fn new(deadline_us: u64) -> Self {
        Self {
            deadline_us,
            pending: BTreeMap::new(),
            last_released: 0,
            finished_through: 0,
            losses: Vec::new(),
            need_recovery: false,
            pending_bytes: 0,
            released_recent: VecDeque::new(),
            rtt_retry: false,
            repair_srtt_us: None,
            repair_rttvar_us: 0,
        }
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
        self.repair_srtt_us
    }

    /// The NACK retry interval in force for a caller cadence of `retry_us`.
    pub fn nack_retry_us(&self, retry_us: u64) -> u64 {
        let retry_us = retry_us.max(1);
        match self.repair_srtt_us {
            Some(srtt) if self.rtt_retry => srtt
                .saturating_mul(2)
                .saturating_add(self.repair_rttvar_us.saturating_mul(4))
                .max(NACK_RETRY_FLOOR_US)
                .min(retry_us),
            _ => retry_us,
        }
    }

    fn on_repair_sample(&mut self, sample_us: u64) {
        match self.repair_srtt_us {
            None => {
                self.repair_srtt_us = Some(sample_us);
                self.repair_rttvar_us = sample_us / 2;
            }
            Some(srtt) => {
                let dev = srtt.abs_diff(sample_us);
                self.repair_rttvar_us = (3 * self.repair_rttvar_us + dev) / 4;
                self.repair_srtt_us = Some((7 * srtt + sample_us) / 8);
            }
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
        let entry = self.pending.entry(header.frame).or_insert_with(|| Pending {
            first_seen_us: now_us,
            last_seen_us: now_us,
            complete_us: None,
            highest_index: header.index,
            nacked: vec![None; usize::from(header.count)],
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
            && let Some(slot) = entry.shards.get_mut(usize::from(header.index))
            && slot.is_none()
        {
            entry.shard_len = Some(payload.len());
            entry.last_seen_us = now_us;
            entry.highest_index = entry.highest_index.max(header.index);
            self.pending_bytes += payload.len();
            entry.held += payload.len();
            *slot = Some(payload.to_vec());
            if let Some(Some(mark)) = entry.nacked.get(usize::from(header.index))
                && mark.times == 1
            {
                repair_sample = Some(now_us.saturating_sub(mark.at_us));
            }
            if entry.complete_us.is_none() && Self::decodable(entry) {
                entry.complete_us = Some(now_us);
            }
        }
        if let Some(sample) = repair_sample {
            self.on_repair_sample(sample);
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
        self.pending
            .values()
            .filter(|p| !Self::decodable(p))
            .filter_map(|p| Self::nack_at(p, after_us, retry_us))
            .min()
    }

    /// When the earliest missing data shard of `p` is due for a request.
    fn nack_at(p: &Pending, after_us: u64, retry_us: u64) -> Option<u64> {
        (0..usize::from(p.count))
            .filter(|&i| p.shards.get(i).is_some_and(Option::is_none))
            .map(|i| Self::shard_nack_at(p, i, after_us, retry_us))
            .min()
    }

    fn shard_nack_at(p: &Pending, i: usize, after_us: u64, retry_us: u64) -> u64 {
        match p.nacked.get(i).copied().flatten() {
            Some(mark) => mark.at_us.saturating_add(retry_us),
            // A large frame may still be arriving after the reorder grace. An
            // observed gap can be requested now; its unseen tail only becomes
            // a gap after arrivals stop for a grace period.
            None if i < Self::observed_data(p) => p.first_seen_us.saturating_add(after_us),
            None => p.last_seen_us.saturating_add(after_us),
        }
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
        self.pending
            .iter_mut()
            .filter(|(_, p)| {
                !Self::decodable(p)
                    && Self::nack_at(p, after_us, retry_us).is_some_and(|at| now_us >= at)
            })
            .take(MAX_NACK_FRAMES)
            .map(|(&frame, p)| {
                let indexes: Vec<u16> = (0..usize::from(p.count))
                    .filter(|&i| {
                        p.shards.get(i).is_some_and(Option::is_none)
                            && now_us >= Self::shard_nack_at(p, i, after_us, retry_us)
                    })
                    .take(MAX_NACK_INDEXES)
                    .map(|i| i as u16)
                    .collect();
                for &i in &indexes {
                    if let Some(slot) = p.nacked.get_mut(usize::from(i)) {
                        let times = slot.map_or(0, |m| m.times).saturating_add(1);
                        *slot = Some(NackMark { at_us: now_us, times });
                    }
                }
                Nack { frame, indexes }
            })
            .collect()
    }

    /// The earliest time at which [`Self::tick`] drops an incomplete frame,
    /// or `None` when no frame waits. Callers arm one timer for it instead of
    /// ticking on a fixed period.
    pub fn next_expiry_us(&self) -> Option<u64> {
        self.pending
            .values()
            .filter(|p| !Self::decodable(p))
            .map(|p| p.first_seen_us.saturating_add(self.deadline_us).saturating_add(1))
            .min()
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
        let expired: Vec<u32> = self
            .pending
            .iter()
            .filter(|(_, p)| {
                !Self::decodable(p) && now_us.saturating_sub(p.first_seen_us) > self.deadline_us
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
