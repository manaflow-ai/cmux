use crate::error::DecodeError;
use crate::local::{MAX_LOCAL_FRAME, STREAM_LOCAL_FRAME, STREAM_LOCAL_REPORT};

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

/// The largest payload of `kind`, or `None` when the type is unknown. The local hop's
/// types ([`crate::LocalFrame`], [`crate::LocalReport`]) count only when `local` is set.
fn max_payload(kind: u8, local: bool) -> Option<usize> {
    match kind {
        STREAM_CONTROL | STREAM_DATAGRAM | STREAM_BULK => Some(MAX_STREAM_FRAME),
        STREAM_LOCAL_FRAME if local => Some(MAX_LOCAL_FRAME),
        STREAM_LOCAL_REPORT if local => Some(MAX_STREAM_FRAME),
        _ => None,
    }
}

/// Appends one stream frame (`u8 type`, `u32 len`, payload) to `out`.
///
/// The stream carrier (one reliable byte stream through the overlay) carries
/// control messages and datagrams in these frames until the overlay datagram
/// service is available on a path. The local hop's types are accepted too: only
/// the viewer's connect process and its app write them.
pub fn encode_stream_frame(kind: u8, payload: &[u8], out: &mut Vec<u8>) -> Result<(), DecodeError> {
    let Some(max) = max_payload(kind, true) else {
        return Err(DecodeError::Invalid("stream frame type"));
    };
    if payload.len() > max {
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
    /// Also accepts the local hop's frame types (a host never sends them).
    local: bool,
}

impl StreamDeframer {
    /// From now on also accepts the local hop's frame types
    /// ([`STREAM_LOCAL_FRAME`], [`STREAM_LOCAL_REPORT`]): only on a stream from the
    /// viewer's own connect process, which the app asked for them.
    pub fn accept_local(&mut self) {
        self.local = true;
    }

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
        let rest = self.buf.get(self.read..).unwrap_or_default();
        let Some(([kind, l0, l1, l2, l3], body)) = rest.split_first_chunk::<STREAM_PREFIX_LEN>()
        else {
            return Ok(None);
        };
        let kind = *kind;
        let len = usize::try_from(u32::from_le_bytes([*l0, *l1, *l2, *l3])).unwrap_or(usize::MAX);
        if max_payload(kind, self.local).is_none_or(|max| len > max) {
            self.failed = true;
            self.buf = Vec::new();
            self.read = 0;
            return Err(DecodeError::Invalid("stream"));
        }
        let Some(payload) = body.get(..len) else {
            return Ok(None);
        };
        let payload = payload.to_vec();
        // `len` is at most the type's maximum and `read` at most `buf.len()`.
        self.read = self.read.saturating_add(STREAM_PREFIX_LEN).saturating_add(len);
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

#[cfg(test)]
mod local_tests {
    use super::*;

    #[test]
    fn local_types_need_accept_local() {
        let mut bytes = Vec::new();
        encode_stream_frame(STREAM_LOCAL_REPORT, &[0; 16], &mut bytes).unwrap();
        let mut host = StreamDeframer::default();
        host.extend(&bytes);
        assert!(host.next_frame().is_err(), "a host stream refuses the local hop's types");
        let mut local = StreamDeframer::default();
        local.accept_local();
        local.extend(&bytes);
        assert_eq!(local.next_frame().unwrap(), Some((STREAM_LOCAL_REPORT, vec![0; 16])));
    }

    #[test]
    fn local_frame_may_pass_the_datagram_limit() {
        let big = vec![7u8; MAX_STREAM_FRAME + 1];
        let mut bytes = Vec::new();
        assert!(encode_stream_frame(STREAM_DATAGRAM, &big, &mut bytes).is_err());
        encode_stream_frame(STREAM_LOCAL_FRAME, &big, &mut bytes).unwrap();
        let mut local = StreamDeframer::default();
        local.accept_local();
        local.extend(&bytes);
        assert_eq!(
            local.next_frame().unwrap().map(|(k, p)| (k, p.len())),
            Some((STREAM_LOCAL_FRAME, big.len()))
        );
    }
}
