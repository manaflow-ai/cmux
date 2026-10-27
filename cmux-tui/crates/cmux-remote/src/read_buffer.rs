//! The bytes one `read` call filled.

/// The first `read` bytes of `buffer`, where `read` is what one
/// `Read::read` or `AsyncReadExt::read` call into `buffer` returned.
#[allow(
    clippy::indexing_slicing,
    reason = "INVARIANT: Read::read and AsyncRead (through ReadBuf) return at most buffer.len() \
              bytes, so `read` is in range"
)]
pub(crate) fn filled(buffer: &[u8], read: usize) -> &[u8] {
    &buffer[..read]
}
