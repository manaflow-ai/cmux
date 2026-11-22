//! Viewer-side frame reassembly. Collects shards, rebuilds lost data shards
//! from parity, drops frames that miss their deadline, and releases a frame
//! only when its reference frame was released (so a frame that predicts from
//! a lost frame is never decoded and shown corrupted).

use std::collections::{BTreeMap, VecDeque};

use cmux_rd_proto::{DatagramHeader, DatagramKind, FrameBody, REF_NONE, flags};

use crate::fec;

/// A frame ready to decode.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompleteFrame {
    pub frame: u32,
    pub flags: u8,
    pub body: FrameBody,
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
    flags: u8,
    count: u16,
    shard_len: Option<usize>,
    shards: Vec<Option<Vec<u8>>>,
}

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
            return self.release_ready();
        }
        let total = usize::from(header.count) + usize::from(header.fec_count);
        let entry = self.pending.entry(header.frame).or_insert_with(|| Pending {
            first_seen_us: now_us,
            flags: header.flags,
            count: header.count,
            shard_len: None,
            shards: vec![None; total],
        });
        // Every shard of a frame has the same length (the session's shard size); a shard
        // of another length is refused, and pending payload bytes are capped.
        let shard_len_ok = entry.shard_len.is_none_or(|l| l == payload.len());
        if entry.shards.len() == total
            && entry.count == header.count
            && shard_len_ok
            && self.pending_bytes + payload.len() <= MAX_PENDING_BYTES
            && let Some(slot) = entry.shards.get_mut(usize::from(header.index))
            && slot.is_none()
        {
            entry.shard_len = Some(payload.len());
            self.pending_bytes += payload.len();
            *slot = Some(payload.to_vec());
        }
        self.expire(now_us);
        self.release_ready()
    }

    /// Advances time with no new datagram: drops frames past their deadline.
    pub fn tick(&mut self, now_us: u64) -> Vec<CompleteFrame> {
        self.expire(now_us);
        self.release_ready()
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
        p.shards.iter().filter(|s| s.is_some()).count() >= usize::from(p.count)
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

    /// The frame to try next: the oldest pending frame, or a decodable
    /// keyframe that lets the viewer skip older incomplete frames.
    fn next_candidate(&self) -> Option<u32> {
        let (&oldest, p) = self.pending.iter().next()?;
        if Self::decodable(p) {
            return Some(oldest);
        }
        self.pending
            .iter()
            // A tile frame is standalone too, so a complete one skips older gaps.
            .find(|(_, p)| Self::decodable(p) && p.flags & (flags::KEYFRAME | flags::TILE) != 0)
            .map(|(&f, _)| f)
    }

    /// Removes a pending frame and releases its bytes from the budget.
    fn take_pending(&mut self, frame: &u32) -> Option<Pending> {
        let p = self.pending.remove(frame)?;
        let held: usize = p.shards.iter().flatten().map(Vec::len).sum();
        self.pending_bytes = self.pending_bytes.saturating_sub(held);
        Some(p)
    }

    fn lose(&mut self, frame: u32) {
        self.losses.push(FrameLoss::Incomplete { frame });
        self.need_recovery = true;
        self.finished_through = self.finished_through.max(frame);
    }

    fn release_ready(&mut self) -> Vec<CompleteFrame> {
        let mut out = Vec::new();
        while let Some(frame) = self.next_candidate() {
            let older: Vec<u32> = self.pending.range(..frame).map(|(&f, _)| f).collect();
            for f in older {
                self.take_pending(&f);
                self.lose(f);
            }
            let Some(mut p) = self.take_pending(&frame) else { break };
            let count = usize::from(p.count);
            if fec::reconstruct(&mut p.shards, count).is_err() {
                self.lose(frame);
                continue;
            }
            let bytes: Vec<u8> = p.shards[..count].iter().flatten().flatten().copied().collect();
            let Ok(body) = FrameBody::decode(&bytes) else {
                self.lose(frame);
                continue;
            };
            self.finished_through = self.finished_through.max(frame);
            if p.flags & flags::TILE != 0 {
                // A tile top-off (rd change C3) depends on no frame of this
                // stream; its ref_frame names the surface stream's video frame.
                self.last_released = frame;
                self.need_recovery = false;
                out.push(CompleteFrame { frame, flags: p.flags, body });
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
                out.push(CompleteFrame { frame, flags: p.flags, body });
            } else {
                self.losses.push(FrameLoss::BrokenReference { frame, ref_frame: body.ref_frame });
                self.need_recovery = true;
            }
        }
        out
    }
}
