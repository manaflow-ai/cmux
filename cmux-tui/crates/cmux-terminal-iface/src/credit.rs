//! The one credit and offset rule (`dataPlane.credit`, `dataPlane.continuity`).
//!
//! Each direction of a channel has one [`SendWindow`] at the sender and one
//! [`ReceiveWindow`] at the receiver, both starting at the open answer's
//! `window_bytes`. The receiver grants credit as it consumes, so bytes in
//! flight plus bytes received and not yet consumed never pass the window.

use crate::error::BackendError;
use crate::frames::{Direction, FrameBody, Lost};

/// The sender's side: never sends past the granted credit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SendWindow {
    window: u32,
    offset: u64,
    limit: u64,
}

impl SendWindow {
    /// A new channel: offset 0, `window_bytes` of credit.
    pub fn new(window_bytes: u32) -> Self {
        Self::resume_at(0, window_bytes)
    }

    /// A resumed terminal: its offsets continue from `offset`.
    pub fn resume_at(offset: u64, window_bytes: u32) -> Self {
        Self { window: window_bytes, offset, limit: offset.saturating_add(u64::from(window_bytes)) }
    }

    /// The running byte total sent so far.
    pub fn offset(&self) -> u64 {
        self.offset
    }

    /// Bytes that may be sent now.
    pub fn available(&self) -> u64 {
        self.limit - self.offset
    }

    /// Takes credit for `bytes` and answers the data frame to send. More
    /// than [`Self::available`] is `unavailable` (retryable after credit);
    /// nothing is taken then.
    pub fn send(&mut self, bytes: Vec<u8>) -> Result<FrameBody, BackendError> {
        let _ = bytes;
        todo!("credit: send")
    }

    /// A credit frame from the receiver. Credit that would let more than
    /// one window be in flight is a protocol violation: the answer is the
    /// `lost` that ends the channel, and nothing is granted.
    pub fn grant(&mut self, bytes: u32) -> Result<(), Lost> {
        let _ = bytes;
        todo!("credit: grant")
    }
}

/// The receiver's side: checks continuity and credit, and grants credit as
/// it consumes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReceiveWindow {
    window: u32,
    /// Running byte total received.
    offset: u64,
    /// Running byte total the receiver has consumed (at most `offset`).
    consumed: u64,
    /// Running byte total the sender may reach.
    limit: u64,
}

impl ReceiveWindow {
    pub fn new(window_bytes: u32) -> Self {
        Self::resume_at(0, window_bytes)
    }

    /// A resumed terminal: data continues from `offset`.
    pub fn resume_at(offset: u64, window_bytes: u32) -> Self {
        Self {
            window: window_bytes,
            offset,
            consumed: offset,
            limit: offset.saturating_add(u64::from(window_bytes)),
        }
    }

    /// The running byte total received so far.
    pub fn offset(&self) -> u64 {
        self.offset
    }

    /// Checks one data frame. A gap, an overlap or data past the credit ends
    /// the channel: the answer is the `lost` to send, never retryable.
    pub fn receive(&mut self, offset: u64, len: usize) -> Result<(), Lost> {
        let _ = (offset, len);
        todo!("credit: receive")
    }

    /// The receiver consumed `bytes` more; answers the credit frame to send
    /// (`None` when nothing new is granted). Consuming more than was received
    /// is `invalid`.
    pub fn consume(
        &mut self,
        direction: Direction,
        bytes: u64,
    ) -> Result<Option<FrameBody>, BackendError> {
        let _ = (direction, bytes);
        todo!("credit: consume")
    }
}
