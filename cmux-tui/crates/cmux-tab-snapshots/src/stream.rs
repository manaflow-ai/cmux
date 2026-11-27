//! Frames on a byte stream. A link channel delivers bytes in chunks of its
//! own size, not one write per read, so every frame travels behind its
//! length: 4 bytes, big-endian, then the frame. Both directions use it.

use std::fmt;

/// Bytes before each frame.
pub const LENGTH_LEN: usize = 4;

/// The frame behind its length. `None` for a frame longer than `u32::MAX`.
pub fn length_prefixed(frame: &[u8]) -> Option<Vec<u8>> {
    let len = u32::try_from(frame.len()).ok()?;
    let mut out = Vec::with_capacity(LENGTH_LEN.saturating_add(frame.len()));
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(frame);
    Some(out)
}

/// A frame announced longer than the reader's cap.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TooLong {
    pub len: u64,
    pub cap: usize,
}

impl fmt::Display for TooLong {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "tabs frame of {} bytes, the cap is {}", self.len, self.cap)
    }
}

impl std::error::Error for TooLong {}

/// Collects stream chunks and yields whole frames.
#[derive(Debug)]
pub struct Deframer {
    buf: Vec<u8>,
    cap: usize,
}

impl Deframer {
    /// `cap`: the longest frame taken; a longer one is an error.
    pub fn new(cap: usize) -> Self {
        Self { buf: Vec::new(), cap }
    }

    pub fn push(&mut self, chunk: &[u8]) {
        self.buf.extend_from_slice(chunk);
    }

    /// Bytes held that are not a whole frame yet.
    pub fn pending(&self) -> usize {
        self.buf.len()
    }

    /// The next whole frame, `Ok(None)` when more bytes are needed.
    pub fn next_frame(&mut self) -> Result<Option<Vec<u8>>, TooLong> {
        let Some(head) = self.buf.get(..LENGTH_LEN) else { return Ok(None) };
        let mut len = [0u8; LENGTH_LEN];
        len.copy_from_slice(head);
        let len = u32::from_be_bytes(len);
        let Ok(len) = usize::try_from(len) else {
            return Err(TooLong { len: u64::from(len), cap: self.cap });
        };
        if len > self.cap {
            return Err(TooLong { len: u64::try_from(len).unwrap_or(u64::MAX), cap: self.cap });
        }
        let end = LENGTH_LEN.saturating_add(len);
        if self.buf.len() < end {
            return Ok(None);
        }
        let frame = self.buf.get(LENGTH_LEN..end).map(<[u8]>::to_vec).unwrap_or_default();
        self.buf.drain(..end);
        Ok(Some(frame))
    }
}

#[cfg(test)]
#[path = "stream_tests.rs"]
mod tests;
