use super::NetStats;
use std::collections::VecDeque;

/// A complete encoded media frame waiting for the link thread.
pub(super) struct MediaFrame {
    pub(super) datagrams: Vec<Vec<u8>>,
    /// Protected frames (keyframe, recovery or repair) must never be evicted.
    pub(super) droppable: bool,
}

/// The link queue keeps at most one frame being drained plus one waiting. A
/// new droppable frame replaces the waiting frame, so media never waits behind
/// an unbounded burst while control traffic continues to use the lossless
/// command channel. Protected frames may exceed this bound until they drain.
const MAX_WAITING_MEDIA_FRAMES: usize = 1;

#[derive(Clone, Copy)]
enum DropReason {
    Replaced,
    EvictedForProtected,
    RejectedProtected,
}

#[derive(Default)]
pub(super) struct MediaQueue {
    // A droppable frame can only be the sole pending frame. Protected arrivals
    // evict it, and droppable arrivals cannot join a protected backlog.
    pub(super) frames: VecDeque<MediaFrame>,
    queued_datagrams: usize,
    dropped_frames: u64,
    dropped_datagrams: u64,
    dropped_replaced_frames: u64,
    dropped_replaced_datagrams: u64,
    dropped_evicted_for_protected_frames: u64,
    dropped_evicted_for_protected_datagrams: u64,
    dropped_rejected_protected_frames: u64,
    dropped_rejected_protected_datagrams: u64,
}

impl MediaQueue {
    pub(super) fn push(&mut self, datagrams: MediaFrame) {
        if datagrams.datagrams.is_empty() {
            return;
        }
        if datagrams.droppable {
            if self.frames.front().is_some_and(|frame| frame.droppable) {
                if let Some(old) = self.pop() {
                    self.record_drop(old, DropReason::Replaced);
                }
            } else if self.frames.len() >= MAX_WAITING_MEDIA_FRAMES {
                // Protected frames are never evicted. The newest droppable
                // frame is rejected until one of them leaves the queue.
                self.record_drop(datagrams, DropReason::RejectedProtected);
                return;
            }
        } else if self.frames.front().is_some_and(|frame| frame.droppable)
            && let Some(old) = self.pop()
        {
            self.record_drop(old, DropReason::EvictedForProtected);
        }
        self.queued_datagrams += datagrams.datagrams.len();
        self.frames.push_back(datagrams);
    }

    pub(super) fn pop(&mut self) -> Option<MediaFrame> {
        let frame = self.frames.pop_front()?;
        self.queued_datagrams -= frame.datagrams.len();
        Some(frame)
    }

    pub(super) fn stats(&self) -> NetStats {
        NetStats {
            departure_overflows: 0,
            queue_frames: self.frames.len(),
            queue_datagrams: self.queued_datagrams,
            dropped_frames: self.dropped_frames,
            dropped_datagrams: self.dropped_datagrams,
            dropped_replaced_frames: self.dropped_replaced_frames,
            dropped_replaced_datagrams: self.dropped_replaced_datagrams,
            dropped_evicted_for_protected_frames: self.dropped_evicted_for_protected_frames,
            dropped_evicted_for_protected_datagrams: self.dropped_evicted_for_protected_datagrams,
            dropped_rejected_protected_frames: self.dropped_rejected_protected_frames,
            dropped_rejected_protected_datagrams: self.dropped_rejected_protected_datagrams,
        }
    }

    fn record_drop(&mut self, frame: MediaFrame, reason: DropReason) {
        let datagrams = u64::try_from(frame.datagrams.len()).unwrap_or(u64::MAX);
        self.dropped_frames = self.dropped_frames.saturating_add(1);
        self.dropped_datagrams = self.dropped_datagrams.saturating_add(datagrams);
        let (frames, packets) = match reason {
            DropReason::Replaced => {
                (&mut self.dropped_replaced_frames, &mut self.dropped_replaced_datagrams)
            }
            DropReason::EvictedForProtected => (
                &mut self.dropped_evicted_for_protected_frames,
                &mut self.dropped_evicted_for_protected_datagrams,
            ),
            DropReason::RejectedProtected => (
                &mut self.dropped_rejected_protected_frames,
                &mut self.dropped_rejected_protected_datagrams,
            ),
        };
        *frames = frames.saturating_add(1);
        *packets = packets.saturating_add(datagrams);
    }
}

#[cfg(test)]
#[path = "media_queue_tests.rs"]
mod tests;
