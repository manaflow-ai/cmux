//! One chunk on the wire: a small header, then the payload.
//!
//! ```text
//! tag:u8  raw_len:varint  [dict:u32le]  [hash:32]  payload
//! ```
//!
//! The encoder only keeps a compressed payload smaller than the raw bytes;
//! otherwise it stores. So a frame is never more than `raw + MAX_OVERHEAD`,
//! and a reference frame (a chunk the receiver already has) is 34 bytes
//! whatever the chunk's size.

use std::io;

/// Most header bytes a frame adds to its raw payload (tag, a 10-byte varint, a dictionary id).
pub const MAX_OVERHEAD: usize = 1 + 10 + 4;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Encoding {
    /// The raw bytes.
    Store,
    /// zstd at a level.
    Zstd(i32),
    /// zstd with a trained dictionary.
    ZstdDict(i32, u32),
    /// A chunk the receiver already holds, named by its BLAKE3 hash.
    Ref,
}

const TAG_STORE: u8 = 0;
const TAG_ZSTD: u8 = 1;
const TAG_ZSTD_DICT: u8 = 2;
const TAG_REF: u8 = 3;

fn put_varint(out: &mut Vec<u8>, mut v: u64) {
    while v >= 0x80 {
        out.push((v as u8) | 0x80);
        v >>= 7;
    }
    out.push(v as u8);
}

fn get_varint(buf: &[u8], at: &mut usize) -> io::Result<u64> {
    let mut v = 0u64;
    for shift in (0..70).step_by(7) {
        let b = *buf.get(*at).ok_or_else(short)?;
        *at += 1;
        v |= u64::from(b & 0x7f) << shift;
        if b < 0x80 {
            return Ok(v);
        }
    }
    Err(io::Error::new(io::ErrorKind::InvalidData, "varint too long"))
}

fn array<const N: usize>(b: &[u8]) -> io::Result<[u8; N]> {
    b.try_into().map_err(|_| short())
}

fn short() -> io::Error {
    io::Error::new(io::ErrorKind::UnexpectedEof, "short frame")
}

/// Dictionaries by id, for the encoder and decoder.
pub trait Dicts {
    fn get(&self, id: u32) -> Option<&[u8]>;

    /// zstd with dictionary `id`. The default prepares the dictionary on every call; a store that
    /// sends many chunks overrides it to prepare each dictionary once.
    fn compress(&self, id: u32, level: i32, raw: &[u8]) -> Option<Vec<u8>> {
        zstd::bulk::Compressor::with_dictionary(level, self.get(id)?)
            .and_then(|mut c| c.compress(raw))
            .ok()
    }

    fn decompress(&self, id: u32, payload: &[u8], raw_len: usize) -> io::Result<Vec<u8>> {
        let dict = self
            .get(id)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "unknown dictionary"))?;
        zstd::bulk::Decompressor::with_dictionary(dict)?.decompress(payload, raw_len)
    }
}

impl Dicts for () {
    fn get(&self, _: u32) -> Option<&[u8]> {
        None
    }
}

/// Encodes `raw` as `want` asks, falling back to store when the compressed
/// payload would not be smaller than `raw` times `keep_ratio`. Returns the
/// frame and the encoding it used. `Ref` writes the hash, not the bytes.
pub fn encode(
    raw: &[u8],
    want: Encoding,
    keep_ratio: f64,
    dicts: &dyn Dicts,
) -> (Vec<u8>, Encoding) {
    let mut out = Vec::with_capacity(raw.len().min(1 << 20) + MAX_OVERHEAD);
    if want == Encoding::Ref {
        out.push(TAG_REF);
        put_varint(&mut out, raw.len() as u64);
        out.extend_from_slice(blake3::hash(raw).as_bytes());
        return (out, Encoding::Ref);
    }
    let limit = ((raw.len() as f64) * keep_ratio.min(1.0)) as usize;
    let compressed = match want {
        Encoding::Zstd(level) => zstd::bulk::compress(raw, level).ok().map(|p| (p, TAG_ZSTD, None)),
        Encoding::ZstdDict(level, id) => {
            dicts.compress(id, level, raw).map(|p| (p, TAG_ZSTD_DICT, Some(id)))
        }
        _ => None,
    };
    if let Some((payload, tag, dict)) = compressed
        && payload.len() < limit
    {
        out.push(tag);
        put_varint(&mut out, raw.len() as u64);
        if let Some(id) = dict {
            out.extend_from_slice(&id.to_le_bytes());
        }
        out.extend_from_slice(&payload);
        return (out, want);
    }
    out.push(TAG_STORE);
    put_varint(&mut out, raw.len() as u64);
    out.extend_from_slice(raw);
    (out, Encoding::Store)
}

/// What a frame decodes to.
pub enum Decoded {
    Bytes(Vec<u8>),
    /// The receiver looks the chunk up in its store; `len` checks it.
    Ref {
        hash: [u8; 32],
        len: u64,
    },
}

/// Decodes one frame; `raw_len` bounds the output so a hostile frame cannot balloon memory.
pub fn decode(frame: &[u8], dicts: &dyn Dicts) -> io::Result<Decoded> {
    let tag = *frame.first().ok_or_else(short)?;
    let mut at = 1;
    let raw_len = get_varint(frame, &mut at)?;
    let bad = |m: &str| io::Error::new(io::ErrorKind::InvalidData, m.to_string());
    if raw_len > 1 << 31 {
        return Err(bad("chunk too large"));
    }
    match tag {
        TAG_STORE => {
            let body = frame.get(at..).ok_or_else(short)?;
            if body.len() as u64 != raw_len {
                return Err(bad("stored length mismatch"));
            }
            Ok(Decoded::Bytes(body.to_vec()))
        }
        TAG_ZSTD => {
            let out = zstd::bulk::decompress(frame.get(at..).ok_or_else(short)?, raw_len as usize)?;
            if out.len() as u64 != raw_len {
                return Err(bad("zstd length mismatch"));
            }
            Ok(Decoded::Bytes(out))
        }
        TAG_ZSTD_DICT => {
            let id = u32::from_le_bytes(array(frame.get(at..at + 4).ok_or_else(short)?)?);
            at += 4;
            let out = dicts.decompress(id, frame.get(at..).ok_or_else(short)?, raw_len as usize)?;
            if out.len() as u64 != raw_len {
                return Err(bad("zstd length mismatch"));
            }
            Ok(Decoded::Bytes(out))
        }
        TAG_REF => {
            let hash: [u8; 32] = array(frame.get(at..at + 32).ok_or_else(short)?)?;
            Ok(Decoded::Ref { hash, len: raw_len })
        }
        _ => Err(bad("unknown frame tag")),
    }
}

#[cfg(test)]
#[path = "frame_tests.rs"]
mod tests;
