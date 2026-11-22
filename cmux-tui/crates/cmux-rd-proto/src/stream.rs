use crate::error::DecodeError;

/// Stream frame type of a control message (JSON).
pub const STREAM_CONTROL: u8 = 1;
/// Stream frame type of one datagram (header and payload) carried on the stream.
pub const STREAM_DATAGRAM: u8 = 2;
/// Stream frame type of one bulk chunk (file bytes; rd change C5): see
/// [`crate::BulkFrame`]. Sent only when both sides list the `bulk` cap: an
/// older deframer refuses the type and ends the session.
pub const STREAM_BULK: u8 = 3;
/// Size of the stream frame prefix: `u8 type`, `u32 len`.
pub const STREAM_PREFIX_LEN: usize = 5;
/// Largest stream frame payload.
pub const MAX_STREAM_FRAME: usize = 1 << 20;

/// Appends one stream frame (`u8 type`, `u32 len`, payload) to `out`.
///
/// The stream carrier (one reliable byte stream through the overlay) carries
/// control messages and datagrams in these frames until the overlay datagram
/// service is available on a path.
pub fn encode_stream_frame(kind: u8, payload: &[u8], out: &mut Vec<u8>) -> Result<(), DecodeError> {
    if !matches!(kind, STREAM_CONTROL | STREAM_DATAGRAM | STREAM_BULK) {
        return Err(DecodeError::Invalid("stream frame type"));
    }
    if payload.len() > MAX_STREAM_FRAME {
        return Err(DecodeError::Invalid("stream frame length"));
    }
    out.reserve(STREAM_PREFIX_LEN + payload.len());
    out.push(kind);
    out.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    out.extend_from_slice(payload);
    Ok(())
}

/// Splits a byte stream into stream frames. Bytes may arrive in any chunks;
/// the deframer holds at most one chunk plus one partial frame. Frames are
/// read at an offset and the consumed prefix is dropped once per
/// [`Self::extend`], so many small frames in one chunk cost linear time.
#[derive(Debug, Default)]
pub struct StreamDeframer {
    buf: Vec<u8>,
    /// Start of the first unread byte in `buf`.
    read: usize,
    failed: bool,
}

impl StreamDeframer {
    /// Adds received bytes.
    pub fn extend(&mut self, bytes: &[u8]) {
        if self.failed {
            return;
        }
        if self.read > 0 {
            self.buf.drain(..self.read);
            self.read = 0;
        }
        self.buf.extend_from_slice(bytes);
    }

    /// Returns the next complete frame `(type, payload)`, `Ok(None)` when more
    /// bytes are needed, or an error for an unknown type or an oversized
    /// length. After an error the stream is unusable and every later call
    /// returns the error again.
    pub fn next_frame(&mut self) -> Result<Option<(u8, Vec<u8>)>, DecodeError> {
        if self.failed {
            return Err(DecodeError::Invalid("stream"));
        }
        let rest = &self.buf[self.read..];
        if rest.len() < STREAM_PREFIX_LEN {
            return Ok(None);
        }
        let kind = rest[0];
        let len = u32::from_le_bytes([rest[1], rest[2], rest[3], rest[4]]) as usize;
        if !matches!(kind, STREAM_CONTROL | STREAM_DATAGRAM | STREAM_BULK) || len > MAX_STREAM_FRAME
        {
            self.failed = true;
            self.buf = Vec::new();
            self.read = 0;
            return Err(DecodeError::Invalid("stream"));
        }
        if rest.len() < STREAM_PREFIX_LEN + len {
            return Ok(None);
        }
        let payload = rest[STREAM_PREFIX_LEN..STREAM_PREFIX_LEN + len].to_vec();
        self.read += STREAM_PREFIX_LEN + len;
        if self.read == self.buf.len() {
            self.buf.clear();
            self.read = 0;
        }
        Ok(Some((kind, payload)))
    }

    /// Bytes held for a partial frame.
    pub fn buffered(&self) -> usize {
        self.buf.len() - self.read
    }
}
