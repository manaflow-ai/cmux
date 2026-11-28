//! The byte protocol between a machine's projection and the Mac that serves it, on one stream the
//! Mac opened (the machine never dials the Mac). After the stream's first line, the machine asks
//! and the Mac answers, little-endian throughout:
//!
//! - ask:    `op u8, ask u32`, then for [`OP_READ`] `entry u32, offset u64, len u32`; for
//!   [`OP_BATCH`] `count u32, entry u32 * count` (whole files, answered in that order); for
//!   [`OP_PING`] nothing; for [`OP_STORED`] `since u32` (which files the Mac has put in the store,
//!   from the `since`-th on: answered with an epoch part, `u64`, then one part per file, `entry u32`
//!   and its blob id in hex; asked only of a Mac whose store is configured); for [`OP_LISTING`]
//!   `since u64` (the journal sequence the machine's listing is at: answered with one part, the
//!   encoded [`crate::listing_patch::Patch`] since then, or [`CHANGED`] when the Mac's journal no
//!   longer reaches back that far and the machine must take the whole listing; asked only of a
//!   Mac that advertised patches, an older Mac ends a stream on an ask it does not know).
//! - answer: `ask u32, count u32`, then `count` times `status u8, len u32, bytes`.
//!
//! A packed answer (RFD 0065, "Projection answers compressed and binary") carries a file's bytes
//! as one zstd frame at [`ZSTD_LEVEL`], status [`OK_ZSTD`], wherever that is smaller than the
//! bytes (about 42% of a repo's bytes are already compressed and go as they are). The Mac packs
//! only for a machine that said it reads packed answers (`cmux-tui-core`'s `"wire": 2`); every
//! reader takes both.
//!
//! Asks carry their own number, so several are in flight at once and answers may come in any
//! order.
//!
//! The protocol grows by new statuses: a machine reads a status it does not know as a failed part,
//! so an older machine fails that one read, as it did before, and the stream goes on.
//! [`RESTATED`] (RFD 0007, hard case 7) is one: its bytes start with the file's stat now
//! ([`Restat`], [`RESTAT_LEN`] bytes), then the asked range of the file as it is now.

use std::io::{self, Read, Write};

pub const OP_READ: u8 = 1;
pub const OP_BATCH: u8 = 2;
pub const OP_PING: u8 = 3;
pub const OP_STORED: u8 = 4;
pub const OP_LISTING: u8 = 5;

/// The bytes asked for.
pub const OK: u8 = 0;
/// The Mac could not read the file (gone, or unreadable).
pub const FAILED: u8 = 1;
/// The file changed on the Mac since the manifest.
pub const CHANGED: u8 = 2;
/// The Mac never shares this entry (not a file of the manifest).
pub const REFUSED: u8 = 3;
/// The bytes asked for, as one zstd frame ([`write_packed_answer`]); read back as [`OK`].
pub const OK_ZSTD: u8 = 4;

/// The zstd level a packed answer uses: 1.84x on cmux's files at 175 MB/s (RFD 0065).
pub const ZSTD_LEVEL: i32 = 3;
/// Bytes shorter than this go as they are: a zstd frame's own head eats what it would save.
const ZSTD_MIN: usize = 64;
/// The file changed on the Mac since the manifest, and the Mac re-listed it: the part is its stat
/// now ([`Restat`]), then the asked range as the file is now (the whole file, for a batch). The
/// bytes may stop at the stat when they would not fit the answer; the machine then asks again.
pub const RESTATED: u8 = 5;
/// The bytes of the [`Restat`] at the start of a [`RESTATED`] part.
pub const RESTAT_LEN: usize = 20;

/// The most bytes one read asks for.
pub const MAX_READ: u32 = 8 * 1024 * 1024;
/// The most files one batch asks for.
pub const MAX_BATCH: u32 = 1024;
/// The most bytes one answer carries.
pub const MAX_ANSWER: u64 = 64 * 1024 * 1024;

/// One ask from the machine.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Ask {
    Read { ask: u32, entry: u32, offset: u64, len: u32 },
    Batch { ask: u32, entries: Vec<u32> },
    Ping { ask: u32 },
    Stored { ask: u32, since: u32 },
    Listing { ask: u32, since: u64 },
}

impl Ask {
    #[must_use]
    pub fn number(&self) -> u32 {
        match self {
            Self::Read { ask, .. }
            | Self::Batch { ask, .. }
            | Self::Ping { ask }
            | Self::Stored { ask, .. }
            | Self::Listing { ask, .. } => *ask,
        }
    }

    /// The same ask with each entry turned by `wire` (an overlay's id into the index the Mac's
    /// manifest has, [`crate::lower::Ext::wire_of`]).
    #[must_use]
    pub fn remap(self, wire: impl Fn(u32) -> u32) -> Self {
        match self {
            Self::Read { ask, entry, offset, len } => {
                Self::Read { ask, entry: wire(entry), offset, len }
            }
            Self::Batch { ask, entries } => {
                Self::Batch { ask, entries: entries.into_iter().map(wire).collect() }
            }
            other => other,
        }
    }

    pub fn write(&self, out: &mut impl Write) -> io::Result<()> {
        let mut bytes = Vec::with_capacity(24);
        match self {
            Self::Read { ask, entry, offset, len } => {
                bytes.push(OP_READ);
                bytes.extend_from_slice(&ask.to_le_bytes());
                bytes.extend_from_slice(&entry.to_le_bytes());
                bytes.extend_from_slice(&offset.to_le_bytes());
                bytes.extend_from_slice(&len.to_le_bytes());
            }
            Self::Batch { ask, entries } => {
                bytes.push(OP_BATCH);
                bytes.extend_from_slice(&ask.to_le_bytes());
                let count = u32::try_from(entries.len()).map_err(io::Error::other)?;
                bytes.extend_from_slice(&count.to_le_bytes());
                for entry in entries {
                    bytes.extend_from_slice(&entry.to_le_bytes());
                }
            }
            Self::Ping { ask } => {
                bytes.push(OP_PING);
                bytes.extend_from_slice(&ask.to_le_bytes());
            }
            Self::Stored { ask, since } => {
                bytes.push(OP_STORED);
                bytes.extend_from_slice(&ask.to_le_bytes());
                bytes.extend_from_slice(&since.to_le_bytes());
            }
            Self::Listing { ask, since } => {
                bytes.push(OP_LISTING);
                bytes.extend_from_slice(&ask.to_le_bytes());
                bytes.extend_from_slice(&since.to_le_bytes());
            }
        }
        out.write_all(&bytes)
    }

    /// The next ask, `None` at a clean end of the stream.
    pub fn read(input: &mut impl Read) -> io::Result<Option<Self>> {
        let mut op = [0u8; 1];
        match input.read_exact(&mut op) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
            Err(error) => return Err(error),
        }
        let ask = u32_of(input)?;
        Ok(Some(match op[0] {
            OP_READ => {
                let entry = u32_of(input)?;
                let offset = u64_of(input)?;
                let len = u32_of(input)?;
                if len > MAX_READ {
                    return Err(bad("a read asks for too much"));
                }
                Self::Read { ask, entry, offset, len }
            }
            OP_BATCH => {
                let count = u32_of(input)?;
                if count > MAX_BATCH {
                    return Err(bad("a batch asks for too many files"));
                }
                let entries = (0..count).map(|_| u32_of(input)).collect::<io::Result<_>>()?;
                Self::Batch { ask, entries }
            }
            OP_PING => Self::Ping { ask },
            OP_STORED => Self::Stored { ask, since: u32_of(input)? },
            OP_LISTING => Self::Listing { ask, since: u64_of(input)? },
            _ => return Err(bad("unknown ask")),
        }))
    }
}

/// A file's stat as the Mac re-listed it after a change: its size, modification time and mode now.
/// That version is the session's base for the file from then on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Restat {
    pub size: u64,
    pub mtime_ns: i64,
    pub mode: u32,
}

impl Restat {
    fn encode(self) -> [u8; RESTAT_LEN] {
        let mut out = [0u8; RESTAT_LEN];
        for (at, byte) in self
            .size
            .to_le_bytes()
            .into_iter()
            .chain(self.mtime_ns.to_le_bytes())
            .chain(self.mode.to_le_bytes())
            .enumerate()
        {
            if let Some(slot) = out.get_mut(at) {
                *slot = byte;
            }
        }
        out
    }

    fn decode(bytes: &[u8]) -> Option<Self> {
        let size = u64::from_le_bytes(bytes.get(..8)?.try_into().ok()?);
        let mtime_ns = i64::from_le_bytes(bytes.get(8..16)?.try_into().ok()?);
        let mode = u32::from_le_bytes(bytes.get(16..RESTAT_LEN)?.try_into().ok()?);
        Some(Self { size, mtime_ns, mode })
    }
}

/// One file's part of an answer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Part {
    pub status: u8,
    pub bytes: Vec<u8>,
}

impl Part {
    #[must_use]
    pub fn ok(bytes: Vec<u8>) -> Self {
        Self { status: OK, bytes }
    }

    #[must_use]
    pub fn status(status: u8) -> Self {
        Self { status, bytes: Vec::new() }
    }

    /// A [`RESTATED`] part: the file's stat now, then `bytes` of it as it is now.
    #[must_use]
    pub fn restated(stat: Restat, bytes: &[u8]) -> Self {
        let mut out = Vec::with_capacity(RESTAT_LEN + bytes.len());
        out.extend_from_slice(&stat.encode());
        out.extend_from_slice(bytes);
        Self { status: RESTATED, bytes: out }
    }

    /// A [`RESTATED`] part's stat and bytes; `None` for any other part, or a short one.
    #[must_use]
    pub fn restat(&self) -> Option<(Restat, &[u8])> {
        if self.status != RESTATED {
            return None;
        }
        Some((Restat::decode(&self.bytes)?, self.bytes.get(RESTAT_LEN..)?))
    }

    /// Drops a [`RESTATED`] part's bytes after its stat (the machine asks for them again).
    pub fn keep_stat_only(&mut self) {
        if self.status == RESTATED {
            self.bytes.truncate(RESTAT_LEN);
        }
    }
}

/// Writes the answer to ask `ask`.
pub fn write_answer(out: &mut impl Write, ask: u32, parts: &[Part]) -> io::Result<()> {
    write_answer_as(out, ask, parts, false)
}

/// [`write_answer`], with each file's bytes as a zstd frame ([`OK_ZSTD`]) where that is smaller.
/// Only for a reader that said it takes packed answers.
pub fn write_packed_answer(out: &mut impl Write, ask: u32, parts: &[Part]) -> io::Result<()> {
    write_answer_as(out, ask, parts, true)
}

fn write_answer_as(out: &mut impl Write, ask: u32, parts: &[Part], packed: bool) -> io::Result<()> {
    let count = u32::try_from(parts.len()).map_err(io::Error::other)?;
    let mut head = Vec::with_capacity(8);
    head.extend_from_slice(&ask.to_le_bytes());
    head.extend_from_slice(&count.to_le_bytes());
    out.write_all(&head)?;
    for part in parts {
        let zstd = if packed { pack(part) } else { None };
        let (status, bytes) = match &zstd {
            Some(frame) => (OK_ZSTD, frame.as_slice()),
            None => (part.status, part.bytes.as_slice()),
        };
        let len = u32::try_from(bytes.len()).map_err(io::Error::other)?;
        out.write_all(&[status])?;
        out.write_all(&len.to_le_bytes())?;
        out.write_all(bytes)?;
    }
    Ok(())
}

/// `part`'s bytes as one zstd frame, when it is a file's bytes and the frame is smaller.
fn pack(part: &Part) -> Option<Vec<u8>> {
    let level = crate::tune::zstd_level();
    if part.status != OK || part.bytes.len() < ZSTD_MIN || level == 0 {
        return None;
    }
    let frame = zstd::bulk::compress(&part.bytes, level).ok()?;
    (frame.len() < part.bytes.len()).then_some(frame)
}

/// The bytes of zstd frame `frame`, refused past `limit` (a small frame must not inflate to
/// gigabytes).
fn unpack(frame: &[u8], limit: u64) -> io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    zstd::stream::read::Decoder::new(frame)?
        .take(limit.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|_| bad("a packed part is not zstd"))?;
    if bytes.len() as u64 > limit {
        return Err(bad("a packed part is too large"));
    }
    Ok(bytes)
}

/// The next answer, `None` at a clean end of the stream.
pub fn read_answer(input: &mut impl Read) -> io::Result<Option<(u32, Vec<Part>)>> {
    let mut first = [0u8; 4];
    match input.read_exact(&mut first) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(error) => return Err(error),
    }
    let ask = u32::from_le_bytes(first);
    let count = u32_of(input)?;
    if count > MAX_BATCH {
        return Err(bad("an answer has too many parts"));
    }
    // Counted as sent and as unpacked: neither may pass MAX_ANSWER.
    let mut total = 0u64;
    let mut unpacked = 0u64;
    let mut parts = Vec::with_capacity(count as usize);
    for _ in 0..count {
        let mut status = [0u8; 1];
        input.read_exact(&mut status)?;
        let len = u32_of(input)?;
        total += u64::from(len);
        if total > MAX_ANSWER {
            return Err(bad("an answer is too large"));
        }
        let mut bytes = vec![0u8; len as usize];
        input.read_exact(&mut bytes)?;
        let part = if status[0] == OK_ZSTD {
            let limit = u64::from(MAX_READ).min(MAX_ANSWER - unpacked);
            Part::ok(unpack(&bytes, limit)?)
        } else {
            Part { status: status[0], bytes }
        };
        unpacked += part.bytes.len() as u64;
        if unpacked > MAX_ANSWER {
            return Err(bad("an answer is too large"));
        }
        parts.push(part);
    }
    Ok(Some((ask, parts)))
}

fn u32_of(input: &mut impl Read) -> io::Result<u32> {
    let mut bytes = [0u8; 4];
    input.read_exact(&mut bytes)?;
    Ok(u32::from_le_bytes(bytes))
}

fn u64_of(input: &mut impl Read) -> io::Result<u64> {
    let mut bytes = [0u8; 8];
    input.read_exact(&mut bytes)?;
    Ok(u64::from_le_bytes(bytes))
}

fn bad(why: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, why)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn asks_and_answers_round_trip() {
        let asks = [
            Ask::Read { ask: 1, entry: 9, offset: 1 << 33, len: 4096 },
            Ask::Batch { ask: 2, entries: vec![3, 4, 5] },
            Ask::Ping { ask: 3 },
            Ask::Stored { ask: 4, since: 1025 },
            Ask::Listing { ask: 5, since: 1 << 40 },
        ];
        let mut bytes = Vec::new();
        for ask in &asks {
            ask.write(&mut bytes).unwrap();
        }
        let mut input = bytes.as_slice();
        for ask in &asks {
            assert_eq!(Ask::read(&mut input).unwrap().as_ref(), Some(ask));
        }
        assert_eq!(Ask::read(&mut input).unwrap(), None);

        let stat = Restat { size: 1 << 40, mtime_ns: -5, mode: 0o755 };
        let parts = vec![
            Part::ok(b"abc".to_vec()),
            Part::status(CHANGED),
            Part::restated(stat, b"new bytes"),
        ];
        let mut bytes = Vec::new();
        write_answer(&mut bytes, 7, &parts).unwrap();
        let mut input = bytes.as_slice();
        let (ask, read) = read_answer(&mut input).unwrap().unwrap();
        assert_eq!((ask, &read), (7, &parts));
        assert_eq!(read[2].restat(), Some((stat, &b"new bytes"[..])));
        assert_eq!(read[0].restat(), None);
        assert_eq!(read_answer(&mut input).unwrap(), None);
        let mut trimmed = read[2].clone();
        trimmed.keep_stat_only();
        assert_eq!(trimmed.restat(), Some((stat, &[][..])));
        // A part too short to hold a stat is not one.
        assert_eq!(Part { status: RESTATED, bytes: vec![1, 2, 3] }.restat(), None);
    }

    #[test]
    fn a_packed_answer_is_smaller_and_reads_back_as_the_same_parts() {
        let text = b"fn main() { println!(\"hello\"); }\n".repeat(200);
        // Bytes that do not compress (xorshift), as an image or an archive.
        let mut state = 0x9e37_79b9_7f4a_7c15u64;
        let noise: Vec<u8> = (0..4096)
            .map(|_| {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                (state >> 32) as u8
            })
            .collect();
        let parts = vec![
            Part::ok(text.clone()),
            Part::ok(noise.clone()),
            Part::ok(b"short".to_vec()),
            Part::status(CHANGED),
            Part::ok(Vec::new()),
        ];
        let mut plain = Vec::new();
        write_answer(&mut plain, 9, &parts).unwrap();
        let mut packed = Vec::new();
        write_packed_answer(&mut packed, 9, &parts).unwrap();
        assert!(packed.len() < plain.len() - text.len() / 2, "{} vs {}", packed.len(), plain.len());
        // Text went as zstd; noise and the short file went as they are.
        assert_eq!(packed[8], OK_ZSTD);
        assert!(packed.windows(noise.len()).any(|window| window == noise.as_slice()));
        assert_eq!(read_answer(&mut packed.as_slice()).unwrap(), Some((9, parts.clone())));
        assert_eq!(read_answer(&mut plain.as_slice()).unwrap(), Some((9, parts)));
    }

    #[test]
    fn a_packed_part_past_the_read_limit_is_refused() {
        let huge = vec![0u8; MAX_READ as usize + 1];
        let mut packed = Vec::new();
        write_packed_answer(&mut packed, 1, &[Part::ok(huge)]).unwrap();
        assert!(packed.len() < 4096);
        assert!(read_answer(&mut packed.as_slice()).is_err());
        let mut junk = Vec::new();
        write_answer(&mut junk, 1, &[Part { status: OK_ZSTD, bytes: b"not zstd".to_vec() }])
            .unwrap();
        assert!(read_answer(&mut junk.as_slice()).is_err());
    }

    #[test]
    fn an_oversized_ask_is_refused() {
        let mut bytes = Vec::new();
        Ask::Read { ask: 1, entry: 0, offset: 0, len: MAX_READ + 1 }.write(&mut bytes).unwrap();
        assert!(Ask::read(&mut bytes.as_slice()).is_err());
    }
}
