//! Bulk chunks (rd change C5): file bytes (uploads and downloads of a
//! service such as the remote browser) on the reliable stream as frame type
//! [`crate::STREAM_BULK`], so file bytes never ride JSON. Payload: `u64
//! transfer`, `u64 offset`, then the bytes. Flow control and pacing live in
//! cmux-rd-core::bulk.

use crate::error::{DecodeError, Reader};

/// Size of the chunk prefix (`u64 transfer`, `u64 offset`).
pub const BULK_PREFIX_LEN: usize = 16;
/// Most bytes in one chunk: a bulk frame is at most 64 KiB, so control
/// messages behind it wait for at most one frame.
pub const MAX_BULK_CHUNK: usize = 64 * 1024 - BULK_PREFIX_LEN;

/// One chunk of a transfer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BulkFrame {
    pub transfer: u64,
    /// Byte offset of `bytes` in the transfer.
    pub offset: u64,
    pub bytes: Vec<u8>,
}

impl BulkFrame {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(BULK_PREFIX_LEN + self.bytes.len());
        out.extend_from_slice(&self.transfer.to_le_bytes());
        out.extend_from_slice(&self.offset.to_le_bytes());
        out.extend_from_slice(&self.bytes);
        out
    }

    /// Parses a chunk; refuses one larger than [`MAX_BULK_CHUNK`].
    pub fn decode(bytes: &[u8]) -> Result<Self, DecodeError> {
        let mut r = Reader::new(bytes);
        let transfer = r.u64()?;
        let offset = r.u64()?;
        let rest = r.rest();
        if rest.len() > MAX_BULK_CHUNK {
            return Err(DecodeError::Invalid("bulk chunk length"));
        }
        Ok(Self { transfer, offset, bytes: rest.to_vec() })
    }
}
