//! A reader that hashes and counts what passes through it (journal segment
//! decode; moved out of session_journal.rs, behavior unchanged).

use std::io::{Read, Result as IoResult};

use sha2::{Digest, Sha256};

pub(super) struct DigestReader<R> {
    inner: R,
    hasher: Sha256,
    bytes_read: usize,
}
impl<R: Read> DigestReader<R> {
    pub(super) fn new(inner: R) -> Self {
        Self { inner, hasher: Sha256::new(), bytes_read: 0 }
    }
    pub(super) fn finish(self) -> (R, usize, sha2::digest::Output<Sha256>) {
        (self.inner, self.bytes_read, self.hasher.finalize())
    }
}
impl<R: Read> Read for DigestReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> IoResult<usize> {
        let n = self.inner.read(buf)?;
        self.bytes_read = self.bytes_read.saturating_add(n);
        self.hasher.update(&buf[..n]);
        Ok(n)
    }
}
