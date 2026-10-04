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
        Self { offset, limit: offset.saturating_add(u64::from(window_bytes)) }
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
        let len = bytes.len() as u64;
        if len > self.available() {
            return Err(BackendError::Unavailable {
                reason: format!("{len} bytes exceed the {} bytes of credit", self.available()),
                retryable: true,
            });
        }
        self.offset += len;
        Ok(FrameBody::Data { offset: self.offset, bytes })
    }

    /// A credit frame from the receiver.
    pub fn grant(&mut self, bytes: u32) {
        self.limit = self.limit.saturating_add(u64::from(bytes));
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
        let expected = self.offset.saturating_add(len as u64);
        if offset < expected {
            return Err(Lost::new("overlap", false));
        }
        if offset > expected {
            return Err(Lost::new("gap", false));
        }
        if expected > self.limit {
            return Err(Lost::new("credit", false));
        }
        self.offset = expected;
        Ok(())
    }

    /// The receiver consumed `bytes` more; answers the credit frame to send
    /// (`None` when nothing new is granted). Consuming more than was received
    /// is `invalid`.
    pub fn consume(
        &mut self,
        direction: Direction,
        bytes: u64,
    ) -> Result<Option<FrameBody>, BackendError> {
        let consumed = self.consumed.saturating_add(bytes);
        if consumed > self.offset {
            return Err(BackendError::invalid("consumed more bytes than were received"));
        }
        self.consumed = consumed;
        let limit = consumed.saturating_add(u64::from(self.window));
        let grant = limit.saturating_sub(self.limit);
        if grant == 0 {
            return Ok(None);
        }
        self.limit = limit;
        // The window is at most 1 MiB, so one grant always fits in u32.
        let bytes = u32::try_from(grant).unwrap_or(u32::MAX);
        Ok(Some(FrameBody::Credit { direction, bytes }))
    }
}
