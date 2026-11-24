//! The frames in the pacer whose send times are still owed to a timing line or the stage
//! ledger (split from stream.rs, which stays under the 1000-line Rust file limit).

use cmux_rd_proto::FrameTimes;
use std::collections::VecDeque;

/// A frame in the pacer whose send times are still owed to its timing line or the ledger.
pub(super) struct PacedFrame {
    /// Its datagrams not yet handed to the carrier.
    pub(super) remaining: usize,
    pub(super) stream: u16,
    pub(super) frame: u32,
    pub(super) times: FrameTimes,
    /// Its timing line, without the send times.
    pub(super) line: Option<serde_json::Value>,
}

/// The frames in the pacer, oldest first, matched to the datagrams it releases. The pacer keeps
/// frame order, so the oldest frame owns the first datagrams due.
#[derive(Default)]
pub(super) struct PacedFrames(pub(super) VecDeque<PacedFrame>);

impl PacedFrames {
    pub(super) fn push(&mut self, frame: PacedFrame) {
        self.0.push_back(frame);
    }

    /// `count` datagrams were handed to the carrier between `first_us` and `last_us`: stamps
    /// each frame's first send and returns the frames whose last datagram went.
    pub(super) fn sent(
        &mut self,
        mut count: usize,
        first_us: u64,
        last_us: u64,
    ) -> Vec<PacedFrame> {
        let mut done = Vec::new();
        while count > 0 {
            let Some(front) = self.0.front_mut() else { break };
            if front.times.first_sent_us == 0 {
                front.times.first_sent_us = first_us;
            }
            let take = count.min(front.remaining);
            front.remaining -= take;
            count -= take;
            if front.remaining > 0 {
                break;
            }
            if let Some(mut frame) = self.0.pop_front() {
                frame.times.last_sent_us = last_us;
                done.push(frame);
            }
        }
        done
    }

    /// Forgets the frames the pacer dropped unsent (an outage end, D12).
    pub(super) fn forget(&mut self, dropped: impl Fn(u16, u32) -> bool) {
        self.0.retain(|f| !dropped(f.stream, f.frame));
    }
}

#[cfg(test)]
mod tests {
    use super::{FrameTimes, PacedFrame, PacedFrames};

    fn paced(frame: u32, remaining: usize) -> PacedFrame {
        PacedFrame { remaining, stream: 0, frame, times: FrameTimes::default(), line: None }
    }

    #[test]
    fn paced_frames_get_their_first_and_last_send_from_the_pacers_releases() {
        let mut q = PacedFrames::default();
        q.push(paced(1, 3));
        q.push(paced(2, 2));
        // Two of frame 1's three datagrams: nothing done yet.
        assert!(q.sent(2, 10, 11).is_empty());
        // Frame 1's last and frame 2's first.
        let done = q.sent(2, 20, 21);
        assert_eq!(done.len(), 1);
        let (f1, t1) = (done[0].frame, done[0].times);
        assert_eq!((f1, t1.first_sent_us, t1.last_sent_us), (1, 10, 21));
        // Frame 2's last: its first send was the release at 20, not this one.
        let done = q.sent(1, 30, 31);
        let (f2, t2) = (done[0].frame, done[0].times);
        assert_eq!((f2, t2.first_sent_us, t2.last_sent_us), (2, 20, 31));
        assert!(q.sent(5, 40, 41).is_empty());
    }

    #[test]
    fn forgotten_frames_leave_the_queue() {
        let mut q = PacedFrames::default();
        q.push(paced(1, 1));
        q.push(paced(2, 1));
        q.forget(|_, frame| frame == 1);
        let left: Vec<u32> = q.0.iter().map(|f| f.frame).collect();
        assert_eq!(left, vec![2]);
    }
}
