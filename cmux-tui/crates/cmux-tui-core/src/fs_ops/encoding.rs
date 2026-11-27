//! `fs-write-deflate-v1`: an `fs.write`, on the line path or as a write
//! stream, whose bytes come compressed: `"encoding":"deflate"` (raw RFC 1951
//! deflate) with `decoded_size`, the exact size they decode to. The wire
//! bytes are the line's `bytes_base64` or the stream's `size` raw bytes.
//!
//! The machine does not trust the sender: decoding stops at `decoded_size`
//! (more is refused, so a small payload cannot fill the disk), fewer bytes
//! or a stream that is not deflate are refused too, and the free-space
//! check and the atomic write see the decoded size. Nothing reaches the
//! target path unless all of it decoded.

use std::io::{self, Write};

use super::error::FsError;
use super::write::PendingWrite;

/// The capability that carries `encoding` on `fs.write`.
pub const FS_WRITE_DEFLATE_CAPABILITY: &str = "fs-write-deflate-v1";
/// The one `encoding` value it serves.
pub const DEFLATE: &str = "deflate";

/// How the bytes of one `fs.write` are encoded.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Encoding {
    /// The bytes as they are (every client before `fs-write-deflate-v1`).
    Identity,
    /// Raw deflate that decodes to exactly `decoded_size` bytes.
    Deflate { decoded_size: u64 },
}

impl Encoding {
    pub(crate) fn parse(
        encoding: Option<&str>,
        decoded_size: Option<u64>,
    ) -> Result<Self, FsError> {
        match (encoding, decoded_size) {
            (None, None) => Ok(Self::Identity),
            (Some(DEFLATE), Some(decoded_size)) => Ok(Self::Deflate { decoded_size }),
            (Some(DEFLATE), None) => Err(invalid("encoding deflate needs decoded_size")),
            (None, Some(_)) => Err(invalid("decoded_size needs an encoding")),
            (Some(_), _) => Err(invalid("encoding is deflate or absent")),
        }
    }
}

fn invalid(message: &str) -> FsError {
    FsError::ParamsInvalid(message.into())
}

/// Where decoded bytes go: memory (a line write) or the temporary file of
/// a write stream.
pub(crate) trait Sink {
    fn put(&mut self, bytes: &[u8]) -> Result<(), FsError>;
}

impl Sink for Vec<u8> {
    fn put(&mut self, bytes: &[u8]) -> Result<(), FsError> {
        self.extend_from_slice(bytes);
        Ok(())
    }
}

impl Sink for PendingWrite {
    fn put(&mut self, bytes: &[u8]) -> Result<(), FsError> {
        self.write(bytes)
    }
}

/// A [`Sink`] that takes at most `left` more bytes, and keeps the first
/// refusal so the caller answers it instead of an I/O error.
struct Bounded<'a, S: Sink> {
    sink: &'a mut S,
    left: u64,
    refused: Option<FsError>,
}

impl<S: Sink> Write for Bounded<'_, S> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        let length = u64::try_from(bytes.len()).unwrap_or(u64::MAX);
        let Some(left) = self.left.checked_sub(length) else {
            self.refused = Some(invalid("the bytes decode to more than decoded_size"));
            return Err(io::Error::other("over decoded_size"));
        };
        if let Err(error) = self.sink.put(bytes) {
            self.refused = Some(error);
            return Err(io::Error::other("the sink refused"));
        }
        self.left = left;
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// Decodes deflate written to it into a [`Sink`], never past
/// `decoded_size`. [`Inflater::finish`] checks that exactly that many came.
pub(crate) struct Inflater<'a, S: Sink> {
    decoder: flate2::write::DeflateDecoder<Bounded<'a, S>>,
}

impl<'a, S: Sink> Inflater<'a, S> {
    pub(crate) fn new(sink: &'a mut S, decoded_size: u64) -> Self {
        let bounded = Bounded { sink, left: decoded_size, refused: None };
        Self { decoder: flate2::write::DeflateDecoder::new(bounded) }
    }

    /// Decodes the next wire bytes.
    pub(crate) fn push(&mut self, wire: &[u8]) -> Result<(), FsError> {
        let result = self.decoder.write_all(wire);
        result.map_err(|error| self.refusal(&error))
    }

    /// Ends the stream: refused unless the deflate stream ended and decoded
    /// to exactly `decoded_size` bytes.
    pub(crate) fn finish(mut self) -> Result<(), FsError> {
        let result = self.decoder.try_finish();
        result.map_err(|error| self.refusal(&error))?;
        if self.decoder.get_ref().left != 0 {
            return Err(invalid("the bytes decode to less than decoded_size"));
        }
        Ok(())
    }

    fn refusal(&mut self, error: &io::Error) -> FsError {
        self.decoder.get_mut().refused.take().unwrap_or_else(|| {
            invalid(&format!("the bytes are not one deflate stream ({})", error.kind()))
        })
    }
}

/// Decodes the deflate `wire` of a line write into memory: exactly
/// `decoded_size` bytes, at most `limit` (the single-write limit).
pub(crate) fn inflate(wire: &[u8], decoded_size: u64, limit: usize) -> Result<Vec<u8>, FsError> {
    let capacity = usize::try_from(decoded_size)
        .ok()
        .filter(|size| *size <= limit)
        .ok_or(FsError::TooLarge { total: Some(decoded_size) })?;
    let mut out = Vec::with_capacity(capacity);
    let mut inflater = Inflater::new(&mut out, decoded_size);
    inflater.push(wire)?;
    inflater.finish()?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use std::io::Write as _;

    use super::{Encoding, inflate};
    use crate::fs_ops::FsError;

    fn deflate(bytes: &[u8]) -> Vec<u8> {
        let mut encoder =
            flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::new(3));
        encoder.write_all(bytes).unwrap();
        encoder.finish().unwrap()
    }

    #[test]
    fn deflate_round_trips_exactly() {
        let text = "fn main() { println!(\"hello\"); }\n".repeat(4000);
        let wire = deflate(text.as_bytes());
        assert!(wire.len() * 10 < text.len(), "{} -> {}", text.len(), wire.len());
        let decoded = inflate(&wire, text.len() as u64, usize::MAX).unwrap();
        assert_eq!(decoded, text.as_bytes());
    }

    /// A small payload that decodes past its declared size (a zip bomb) is
    /// refused once it reaches the bound, never held whole.
    #[test]
    fn decoding_past_decoded_size_is_refused() {
        let wire = deflate(&vec![0u8; 64 << 20]);
        let error = inflate(&wire, 1024, usize::MAX).unwrap_err();
        assert!(matches!(error, FsError::ParamsInvalid(ref m) if m.contains("more")), "{error:?}");
    }

    #[test]
    fn short_or_foreign_bytes_are_refused() {
        let wire = deflate(b"twelve bytes");
        let short = inflate(&wire, 13, usize::MAX).unwrap_err();
        assert!(matches!(short, FsError::ParamsInvalid(ref m) if m.contains("less")), "{short:?}");
        let cut = wire.get(..wire.len() / 2).unwrap();
        assert!(inflate(cut, 12, usize::MAX).is_err());
        assert!(inflate(&[0xff; 64], 12, usize::MAX).is_err());
    }

    #[test]
    fn a_decoded_size_over_the_line_limit_is_too_large() {
        let wire = deflate(&[1u8; 16]);
        assert!(matches!(inflate(&wire, 1 << 30, 12 << 20), Err(FsError::TooLarge { .. })));
    }

    #[test]
    fn the_encoding_fields_go_together() {
        assert_eq!(Encoding::parse(None, None).unwrap(), Encoding::Identity);
        assert_eq!(
            Encoding::parse(Some("deflate"), Some(7)).unwrap(),
            Encoding::Deflate { decoded_size: 7 }
        );
        assert!(Encoding::parse(Some("deflate"), None).is_err());
        assert!(Encoding::parse(None, Some(7)).is_err());
        assert!(Encoding::parse(Some("zstd"), Some(7)).is_err());
    }
}
