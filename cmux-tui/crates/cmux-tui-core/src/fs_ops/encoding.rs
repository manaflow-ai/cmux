//! `fs-write-deflate-v1`: an `fs.write`, on the line path or as a write
//! stream, whose bytes come compressed: `"encoding":"deflate"` (raw RFC 1951
//! deflate) with `decoded_size`, the exact size they decode to. The wire
//! bytes are the line's `bytes_base64` or the stream's `size` raw bytes.
//! `fs-write-zstd-v1` adds `"encoding":"zstd"` (zstd frames), the same way:
//! the sender (cmux-bytes's per-part choice) picks zstd at a level the link
//! and its CPU allow, or sends the bytes as they are when they would not
//! shrink, so a payload never grows past its raw size.
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
/// The capability that adds `"encoding":"zstd"` on `fs.write`.
pub const FS_WRITE_ZSTD_CAPABILITY: &str = "fs-write-zstd-v1";
/// The `encoding` value of zstd bytes.
pub const ZSTD: &str = "zstd";

/// How the bytes of one `fs.write` are encoded.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Encoding {
    /// The bytes as they are (every client before `fs-write-deflate-v1`).
    Identity,
    /// Raw deflate that decodes to exactly `decoded_size` bytes.
    Deflate { decoded_size: u64 },
    /// zstd frames that decode to exactly `decoded_size` bytes.
    Zstd { decoded_size: u64 },
}

/// The compressor behind a compressed [`Encoding`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Codec {
    Deflate,
    Zstd,
}

impl Encoding {
    pub(crate) fn parse(
        encoding: Option<&str>,
        decoded_size: Option<u64>,
    ) -> Result<Self, FsError> {
        match (encoding, decoded_size) {
            (None, None) => Ok(Self::Identity),
            (Some(DEFLATE), Some(decoded_size)) => Ok(Self::Deflate { decoded_size }),
            (Some(ZSTD), Some(decoded_size)) => Ok(Self::Zstd { decoded_size }),
            (Some(DEFLATE), None) => Err(invalid("encoding deflate needs decoded_size")),
            (Some(ZSTD), None) => Err(invalid("encoding zstd needs decoded_size")),
            (None, Some(_)) => Err(invalid("decoded_size needs an encoding")),
            (Some(_), _) => Err(invalid("encoding is deflate, zstd or absent")),
        }
    }

    /// The codec and decoded size, when the bytes are compressed.
    pub(crate) fn compressed(self) -> Option<(Codec, u64)> {
        match self {
            Self::Identity => None,
            Self::Deflate { decoded_size } => Some((Codec::Deflate, decoded_size)),
            Self::Zstd { decoded_size } => Some((Codec::Zstd, decoded_size)),
        }
    }

    /// The size the file has once written: `decoded_size`, or `wire` itself.
    pub(crate) fn decoded_size(self, wire: u64) -> u64 {
        self.compressed().map_or(wire, |(_, size)| size)
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

/// The largest zstd window a write may use (2^24 bytes): every level up to
/// 19 on any input fits, and the machine never holds more for one write.
pub const ZSTD_WINDOW_LOG_MAX: u32 = 24;

enum Inner<'a, S: Sink> {
    Deflate(flate2::write::DeflateDecoder<Bounded<'a, S>>),
    Zstd(zstd::stream::write::Decoder<'static, Bounded<'a, S>>),
}

/// Decodes deflate or zstd written to it into a [`Sink`], never past
/// `decoded_size`. [`Inflater::finish`] checks that exactly that many came.
pub(crate) struct Inflater<'a, S: Sink> {
    decoder: Inner<'a, S>,
    codec: Codec,
}

impl<'a, S: Sink> Inflater<'a, S> {
    pub(crate) fn new(sink: &'a mut S, codec: Codec, decoded_size: u64) -> Result<Self, FsError> {
        let bounded = Bounded { sink, left: decoded_size, refused: None };
        let decoder = match codec {
            Codec::Deflate => Inner::Deflate(flate2::write::DeflateDecoder::new(bounded)),
            Codec::Zstd => {
                let mut decoder = zstd::stream::write::Decoder::new(bounded)
                    .map_err(|_| invalid("the zstd decoder could not start"))?;
                // A frame may ask for a window up to this (16 MiB): more is refused, so
                // a small payload cannot make the machine hold a 2 GiB window.
                decoder
                    .window_log_max(ZSTD_WINDOW_LOG_MAX)
                    .map_err(|_| invalid("the zstd decoder could not start"))?;
                Inner::Zstd(decoder)
            }
        };
        Ok(Self { decoder, codec })
    }

    /// Decodes the next wire bytes.
    pub(crate) fn push(&mut self, wire: &[u8]) -> Result<(), FsError> {
        let result = match &mut self.decoder {
            Inner::Deflate(decoder) => decoder.write_all(wire),
            Inner::Zstd(decoder) => decoder.write_all(wire),
        };
        result.map_err(|error| self.refusal(&error))
    }

    /// Ends the stream: refused unless the stream ended and decoded to
    /// exactly `decoded_size` bytes.
    pub(crate) fn finish(mut self) -> Result<(), FsError> {
        let result = match &mut self.decoder {
            Inner::Deflate(decoder) => decoder.try_finish(),
            Inner::Zstd(decoder) => decoder.flush(),
        };
        result.map_err(|error| self.refusal(&error))?;
        if self.bounded().left != 0 {
            return Err(invalid("the bytes decode to less than decoded_size"));
        }
        Ok(())
    }

    fn bounded(&mut self) -> &mut Bounded<'a, S> {
        match &mut self.decoder {
            Inner::Deflate(decoder) => decoder.get_mut(),
            Inner::Zstd(decoder) => decoder.get_mut(),
        }
    }

    fn refusal(&mut self, error: &io::Error) -> FsError {
        let name = match self.codec {
            Codec::Deflate => DEFLATE,
            Codec::Zstd => ZSTD,
        };
        self.bounded().refused.take().unwrap_or_else(|| {
            invalid(&format!("the bytes are not one {name} stream ({})", error.kind()))
        })
    }
}

/// Decodes the compressed `wire` of a line write into memory: exactly
/// `decoded_size` bytes, at most `limit` (the single-write limit).
pub(crate) fn decode(
    wire: &[u8],
    codec: Codec,
    decoded_size: u64,
    limit: usize,
) -> Result<Vec<u8>, FsError> {
    let capacity = usize::try_from(decoded_size)
        .ok()
        .filter(|size| *size <= limit)
        .ok_or(FsError::TooLarge { total: Some(decoded_size) })?;
    let mut out = Vec::with_capacity(capacity);
    let mut inflater = Inflater::new(&mut out, codec, decoded_size)?;
    inflater.push(wire)?;
    inflater.finish()?;
    Ok(out)
}

/// [`decode`] of deflate.
#[cfg(test)]
pub(crate) fn inflate(wire: &[u8], decoded_size: u64, limit: usize) -> Result<Vec<u8>, FsError> {
    decode(wire, Codec::Deflate, decoded_size, limit)
}

#[cfg(test)]
#[path = "encoding_tests.rs"]
mod tests;
