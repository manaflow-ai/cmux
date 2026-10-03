use crate::error::DecodeError;

/// Stream frame type of a control message (JSON).
pub const STREAM_CONTROL: u8 = 1;
/// Stream frame type of one datagram (header and payload) carried on the stream.
pub const STREAM_DATAGRAM: u8 = 2;
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
    if !matches!(kind, STREAM_CONTROL | STREAM_DATAGRAM) {
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
/// the deframer holds at most one partial frame.
#[derive(Debug, Default)]
pub struct StreamDeframer {
    buf: Vec<u8>,
    failed: bool,
}

impl StreamDeframer {
    /// Adds received bytes.
    pub fn extend(&mut self, bytes: &[u8]) {
        if !self.failed {
            self.buf.extend_from_slice(bytes);
        }
    }

    /// Returns the next complete frame `(type, payload)`, `Ok(None)` when more
    /// bytes are needed, or an error for an unknown type or an oversized
    /// length. After an error the stream is unusable and every later call
    /// returns the error again.
    pub fn next_frame(&mut self) -> Result<Option<(u8, Vec<u8>)>, DecodeError> {
        if self.failed {
            return Err(DecodeError::Invalid("stream"));
        }
        if self.buf.len() < STREAM_PREFIX_LEN {
            return Ok(None);
        }
        let kind = self.buf[0];
        let len = u32::from_le_bytes([self.buf[1], self.buf[2], self.buf[3], self.buf[4]]) as usize;
        if !matches!(kind, STREAM_CONTROL | STREAM_DATAGRAM) || len > MAX_STREAM_FRAME {
            self.failed = true;
            self.buf = Vec::new();
            return Err(DecodeError::Invalid("stream"));
        }
        if self.buf.len() < STREAM_PREFIX_LEN + len {
            return Ok(None);
        }
        let payload = self.buf[STREAM_PREFIX_LEN..STREAM_PREFIX_LEN + len].to_vec();
        self.buf.drain(..STREAM_PREFIX_LEN + len);
        Ok(Some((kind, payload)))
    }

    /// Bytes held for a partial frame.
    pub fn buffered(&self) -> usize {
        self.buf.len()
    }
}
