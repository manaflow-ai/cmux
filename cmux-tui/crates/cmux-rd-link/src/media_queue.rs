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
mod tests {
    use super::*;

    #[test]
    fn newest_frame_replaces_oldest_as_a_whole() {
        let mut queue = MediaQueue::default();
        queue.push(MediaFrame {
            datagrams: vec![b"old-a".to_vec(), b"old-b".to_vec(), b"old-c".to_vec()],
            droppable: true,
        });
        queue.push(MediaFrame {
            datagrams: vec![b"new-a".to_vec(), b"new-b".to_vec()],
            droppable: true,
        });

        assert_eq!(queue.stats().dropped_frames, 1);
        assert_eq!(queue.stats().dropped_datagrams, 3);
        assert_eq!(queue.stats().dropped_replaced_frames, 1);
        assert_eq!(queue.stats().dropped_replaced_datagrams, 3);
        assert_eq!(queue.stats().queue_frames, 1);
        assert_eq!(queue.stats().queue_datagrams, 2);
        assert_eq!(
            queue.pop().map(|frame| frame.datagrams),
            Some(vec![b"new-a".to_vec(), b"new-b".to_vec()])
        );
        assert!(queue.pop().is_none(), "old frame fragments must not survive");
        assert_eq!(queue.stats().queue_datagrams, 0);
    }

    #[test]
    fn empty_frame_does_not_consume_capacity_or_count_as_drop() {
        let mut queue = MediaQueue::default();
        queue.push(MediaFrame { datagrams: Vec::new(), droppable: true });
        assert_eq!(queue.stats(), NetStats::default());
    }

    #[test]
    fn protected_frames_survive_a_new_protected_frame() {
        let mut queue = MediaQueue::default();
        queue.push(MediaFrame { datagrams: vec![b"delta".to_vec()], droppable: true });
        queue.push(MediaFrame { datagrams: vec![b"key".to_vec()], droppable: false });
        queue.push(MediaFrame { datagrams: vec![b"recovery".to_vec()], droppable: false });

        assert_eq!(queue.stats().dropped_datagrams, 1);
        assert_eq!(queue.stats().dropped_evicted_for_protected_frames, 1);
        assert_eq!(queue.stats().dropped_evicted_for_protected_datagrams, 1);
        assert_eq!(queue.pop().map(|frame| frame.datagrams), Some(vec![b"key".to_vec()]));
        assert_eq!(queue.pop().map(|frame| frame.datagrams), Some(vec![b"recovery".to_vec()]));
    }

    #[test]
    fn droppable_frame_is_rejected_behind_two_protected_frames() {
        let mut queue = MediaQueue::default();
        queue.push(MediaFrame { datagrams: vec![b"key".to_vec()], droppable: false });
        queue.push(MediaFrame { datagrams: vec![b"recovery".to_vec()], droppable: false });
        queue.push(MediaFrame {
            datagrams: vec![b"delta".to_vec(), b"fec".to_vec()],
            droppable: true,
        });

        let stats = queue.stats();
        assert_eq!(stats.queue_frames, 2);
        assert_eq!(stats.queue_datagrams, 2);
        assert_eq!(stats.dropped_rejected_protected_frames, 1);
        assert_eq!(stats.dropped_rejected_protected_datagrams, 2);
        assert_eq!(queue.pop().map(|frame| frame.datagrams), Some(vec![b"key".to_vec()]));
        assert_eq!(queue.pop().map(|frame| frame.datagrams), Some(vec![b"recovery".to_vec()]));
        assert!(queue.pop().is_none());
        assert_eq!(queue.stats().queue_datagrams, 0);
    }
}
