//! Big-endian reads with the limits every server-supplied length passes.

use std::io::Read;

use crate::error::{Result, VncError};

/// Largest text a server may send (reason strings, desktop names, cut text).
/// Larger cut text is read and dropped, never held.
pub const MAX_TEXT_BYTES: usize = 1 << 20;
/// Largest compressed payload of one Zlib, ZRLE or Tight rectangle.
pub const MAX_COMPRESSED_BYTES: usize = 64 << 20;

/// A buffered reader of server bytes.
pub struct WireReader<R> {
    inner: R,
}

impl<R: Read> WireReader<R> {
    pub fn new(inner: R) -> Self {
        Self { inner }
    }

    pub fn into_inner(self) -> R {
        self.inner
    }

    pub fn exact(&mut self, buf: &mut [u8]) -> Result<()> {
        self.inner.read_exact(buf)?;
        Ok(())
    }

    pub fn bytes(&mut self, len: usize) -> Result<Vec<u8>> {
        let mut buf = vec![0; len];
        self.exact(&mut buf)?;
        Ok(buf)
    }

    pub fn u8(&mut self) -> Result<u8> {
        let mut b = [0; 1];
        self.exact(&mut b)?;
        Ok(b[0])
    }

    pub fn u16(&mut self) -> Result<u16> {
        let mut b = [0; 2];
        self.exact(&mut b)?;
        Ok(u16::from_be_bytes(b))
    }

    pub fn u32(&mut self) -> Result<u32> {
        let mut b = [0; 4];
        self.exact(&mut b)?;
        Ok(u32::from_be_bytes(b))
    }

    pub fn i32(&mut self) -> Result<i32> {
        let mut b = [0; 4];
        self.exact(&mut b)?;
        Ok(i32::from_be_bytes(b))
    }

    pub fn skip(&mut self, mut len: usize) -> Result<()> {
        let mut scratch = [0; 4096];
        while len > 0 {
            let take = len.min(scratch.len());
            self.exact(&mut scratch[..take])?;
            len -= take;
        }
        Ok(())
    }

    /// A `u32` length followed by that many Latin-1 bytes (RFB's string).
    pub fn text(&mut self, what: &str) -> Result<String> {
        let len = self.u32()? as usize;
        if len > MAX_TEXT_BYTES {
            return Err(VncError::protocol(format!("{what} of {len} bytes")));
        }
        Ok(latin1(&self.bytes(len)?))
    }

    /// A `u32` length and a compressed payload, bounded.
    pub fn compressed(&mut self, what: &str) -> Result<Vec<u8>> {
        let len = self.u32()? as usize;
        if len > MAX_COMPRESSED_BYTES {
            return Err(VncError::protocol(format!("{what} payload of {len} bytes")));
        }
        self.bytes(len)
    }
}

/// RFB text is Latin-1 (ISO 8859-1): each byte is the code point.
pub fn latin1(bytes: &[u8]) -> String {
    bytes.iter().map(|&b| char::from(b)).collect()
}

/// Encodes text as Latin-1 for ClientCutText; characters outside it become `?`.
pub fn to_latin1(text: &str) -> Vec<u8> {
    text.chars().map(|c| u8::try_from(u32::from(c)).unwrap_or(b'?')).collect()
}
