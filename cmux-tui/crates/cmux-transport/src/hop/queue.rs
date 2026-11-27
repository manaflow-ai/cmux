//! A leg's egress queue: classes bounded by bytes (as
//! `cmux-mobile-link`'s `class_queue`) and latest-wins for class 1 (R5).

use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant};

use super::{HopClass, Record, StreamTag, seq_newer};

/// Bytes each class may hold, by class index. Past its bound a class drops
/// its oldest record.
pub(crate) const CLASS_BYTES: [usize; 5] =
    [16 * 1024, 64 * 1024, 64 * 1024, 256 * 1024, 256 * 1024];
/// Media queued longer than this is dropped: a late video packet is worthless.
pub(crate) const MEDIA_MAX_AGE: Duration = Duration::from_millis(250);
/// Streams whose last sent `key_seq` the queue remembers.
const MAX_KEYS: usize = 4096;

struct Queued {
    record: Record,
    at: Instant,
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub(crate) struct PushOutcome {
    /// Records R5 dropped: the queued one it replaced, or the new one when
    /// it was already stale.
    pub superseded: u64,
    /// Records dropped past the class's byte bound.
    pub overflow: u64,
}

pub(crate) struct EgressQueue {
    lanes: [VecDeque<Queued>; 5],
    bytes: [usize; 5],
    latest_wins: bool,
    /// Bytes sent from bulk and media, for their byte share.
    shared_sent: [u64; 2],
    /// Highest `key_seq` sent per stream key.
    sent_tags: HashMap<u32, u32>,
    pub(crate) media_expired: u64,
}

impl EgressQueue {
    pub(crate) fn new(latest_wins: bool) -> Self {
        Self {
            lanes: Default::default(),
            bytes: [0; 5],
            latest_wins,
            shared_sent: [0; 2],
            sent_tags: HashMap::new(),
            media_expired: 0,
        }
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.lanes.iter().all(VecDeque::is_empty)
    }

    pub(crate) fn bytes(&self) -> usize {
        self.bytes.iter().sum()
    }

    pub(crate) fn push(&mut self, record: Record, now: Instant) -> PushOutcome {
        let mut outcome = PushOutcome::default();
        let index = record.class.index();
        if self.latest_wins
            && record.class == HopClass::Interactive
            && let Some(tag) = record.tag
        {
            if self.superseded(tag) {
                outcome.superseded += 1;
                return outcome;
            }
            let Some(lane) = self.lanes.get_mut(index) else { return outcome };
            if let Some(queued) =
                lane.iter_mut().find(|q| q.record.tag.is_some_and(|t| t.key == tag.key))
            {
                let queued_seq = queued.record.tag.map_or(tag.seq, |t| t.seq);
                outcome.superseded += 1;
                if seq_newer(tag.seq, queued_seq) {
                    // Replace in place: the newest state goes out in the
                    // oldest one's slot.
                    if let Some(bytes) = self.bytes.get_mut(index) {
                        *bytes =
                            bytes.saturating_sub(queued.record.bytes.len()) + record.bytes.len();
                    }
                    queued.record = record;
                }
                return outcome;
            }
        }
        let len = record.bytes.len();
        let limit = CLASS_BYTES.get(index).copied().unwrap_or(0);
        let (Some(lane), Some(bytes)) = (self.lanes.get_mut(index), self.bytes.get_mut(index))
        else {
            return outcome;
        };
        lane.push_back(Queued { record, at: now });
        *bytes += len;
        while *bytes > limit && lane.len() > 1 {
            let Some(oldest) = lane.pop_front() else { break };
            *bytes = bytes.saturating_sub(oldest.record.bytes.len());
            outcome.overflow += 1;
        }
        outcome
    }

    /// Drops media queued past [`MEDIA_MAX_AGE`].
    pub(crate) fn expire(&mut self, now: Instant) {
        let index = HopClass::Media.index();
        let (Some(lane), Some(bytes)) = (self.lanes.get_mut(index), self.bytes.get_mut(index))
        else {
            return;
        };
        while lane.front().is_some_and(|q| now.saturating_duration_since(q.at) > MEDIA_MAX_AGE) {
            if let Some(old) = lane.pop_front() {
                *bytes = bytes.saturating_sub(old.record.bytes.len());
                self.media_expired += 1;
            }
        }
    }

    /// The lane that sends next: control, interactive, input in strict
    /// order, then whichever of bulk and media has sent fewer bytes.
    fn next_lane(&self) -> Option<usize> {
        for index in 0..3 {
            if self.lanes.get(index).is_some_and(|lane| !lane.is_empty()) {
                return Some(index);
            }
        }
        let bulk = self.lanes.get(3).is_some_and(|lane| !lane.is_empty());
        let media = self.lanes.get(4).is_some_and(|lane| !lane.is_empty());
        match (bulk, media) {
            (true, true) => Some(if self.shared_sent[0] <= self.shared_sent[1] { 3 } else { 4 }),
            (true, false) => Some(3),
            (false, true) => Some(4),
            (false, false) => None,
        }
    }

    /// The encoded length of the record that would be popped next.
    pub(crate) fn peek_len(&self) -> Option<usize> {
        let index = self.next_lane()?;
        self.lanes.get(index)?.front().map(|q| q.record.encoded_len())
    }

    pub(crate) fn pop(&mut self) -> Option<Record> {
        let index = self.next_lane()?;
        let queued = self.lanes.get_mut(index)?.pop_front()?;
        if let Some(bytes) = self.bytes.get_mut(index) {
            *bytes = bytes.saturating_sub(queued.record.bytes.len());
        }
        let len = queued.record.bytes.len() as u64;
        match index {
            3 => self.shared_sent[0] += len,
            4 => self.shared_sent[1] += len,
            _ => {}
        }
        // Keep the share relative so neither counter grows without bound.
        let floor = self.shared_sent[0].min(self.shared_sent[1]);
        self.shared_sent = [self.shared_sent[0] - floor, self.shared_sent[1] - floor];
        if let (HopClass::Interactive, Some(tag)) = (queued.record.class, queued.record.tag) {
            self.note_sent(tag);
        }
        Some(queued.record)
    }

    fn note_sent(&mut self, tag: StreamTag) {
        if self.sent_tags.len() >= MAX_KEYS && !self.sent_tags.contains_key(&tag.key) {
            self.sent_tags.clear();
        }
        let entry = self.sent_tags.entry(tag.key).or_insert(tag.seq);
        if seq_newer(tag.seq, *entry) {
            *entry = tag.seq;
        }
    }

    /// A record of this stream at or after `tag.seq` has been sent.
    pub(crate) fn superseded(&self, tag: StreamTag) -> bool {
        self.sent_tags.get(&tag.key).is_some_and(|&sent| !seq_newer(tag.seq, sent))
    }

    /// A newer record of this stream has been sent (a resend of `tag` is
    /// worthless).
    pub(crate) fn strictly_superseded(&self, tag: StreamTag) -> bool {
        self.sent_tags.get(&tag.key).is_some_and(|&sent| seq_newer(sent, tag.seq))
    }
}
