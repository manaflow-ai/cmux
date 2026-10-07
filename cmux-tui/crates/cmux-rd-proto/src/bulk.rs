//! Placeholder (red commit).

use crate::error::DecodeError;

pub const BULK_PREFIX_LEN: usize = 16;
pub const MAX_BULK_CHUNK: usize = 64 * 1024 - BULK_PREFIX_LEN;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BulkFrame {
    pub transfer: u64,
    pub offset: u64,
    pub bytes: Vec<u8>,
}

impl BulkFrame {
    pub fn encode(&self) -> Vec<u8> {
        Vec::new()
    }
    pub fn decode(_bytes: &[u8]) -> Result<Self, DecodeError> {
        Err(DecodeError::Invalid("bulk"))
    }
}
