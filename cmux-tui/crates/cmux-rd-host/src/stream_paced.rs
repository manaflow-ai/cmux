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
#[path = "stream_paced_tests.rs"]
mod tests;
