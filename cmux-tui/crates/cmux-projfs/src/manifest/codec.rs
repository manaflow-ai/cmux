//! The manifest's byte encoding.
//!
//! Layout: the 4-byte [`MAGIC`], a little-endian `u16` format version, then one zstd frame holding
//! the body. The version comes before the compressed part so a newer manifest is refused before
//! anything is decompressed. The body is plain little-endian fields: the root label, the skipped
//! count, the entry count, then per entry its name, parent index, kind, flags, mode, size, times,
//! and the optional link text and hash. Children ranges are not stored; decoding rebuilds them and
//! checks every rule the in-memory form relies on, so hostile or truncated input is an error,
//! never a panic or an out-of-range index.

use std::io::Read;

use super::{Entry, Kind, MAX_LINK, MAX_NAME, Manifest, ManifestError, ROOT, Stat, check_name};

/// The first four bytes of an encoded manifest.
pub const MAGIC: [u8; 4] = *b"CMPF";

/// The format version this build writes and the newest it reads.
pub const FORMAT_VERSION: u16 = 1;

/// The largest decompressed body [`Manifest::decode`] accepts (1 GiB, about 15 million entries).
pub const MAX_DECODED_BYTES: u64 = 1 << 30;

const HEADER: usize = MAGIC.len() + 2;
const FLAG_WITHHELD: u8 = 1;
const FLAG_LINK: u8 = 2;
const FLAG_HASH: u8 = 4;
const FLAG_GONE: u8 = 8;
const KNOWN_FLAGS: u8 = FLAG_WITHHELD | FLAG_LINK | FLAG_HASH | FLAG_GONE;
/// The fixed part of an encoded entry: name length, parent, kind, flags, mode, size, two times.
const MIN_ENTRY: usize = 4 + 4 + 1 + 1 + 4 + 8 + 8 + 8;
const ZSTD_LEVEL: i32 = 3;

impl Manifest {
    /// Encodes the manifest (gone marks included) as described in this module.
    pub fn encode(&self) -> Result<Vec<u8>, ManifestError> {
        let mut body = Vec::with_capacity(64 + self.entries.len() * 48);
        put_str(&mut body, &self.root);
        body.extend_from_slice(&self.skipped.to_le_bytes());
        body.extend_from_slice(&(self.entries.len() as u32).to_le_bytes());
        for e in &self.entries {
            put_entry(&mut body, e);
        }
        let packed = zstd::stream::encode_all(body.as_slice(), ZSTD_LEVEL)
            .map_err(|e| ManifestError::Corrupt(format!("compression failed: {e}")))?;
        let mut out = Vec::with_capacity(HEADER + packed.len());
        out.extend_from_slice(&MAGIC);
        out.extend_from_slice(&FORMAT_VERSION.to_le_bytes());
        out.extend_from_slice(&packed);
        Ok(out)
    }

    /// Decodes and validates an encoded manifest.
    pub fn decode(bytes: &[u8]) -> Result<Manifest, ManifestError> {
        let Some((magic, rest)) = bytes.split_first_chunk::<4>() else {
            return Err(ManifestError::NotAManifest);
        };
        let Some((version, packed)) = rest.split_first_chunk::<2>() else {
            return Err(ManifestError::NotAManifest);
        };
        if *magic != MAGIC {
            return Err(ManifestError::NotAManifest);
        }
        let found = u16::from_le_bytes(*version);
        if found > FORMAT_VERSION {
            return Err(ManifestError::NewerVersion { found, supported: FORMAT_VERSION });
        }
        if found == 0 {
            return Err(corrupt("format version 0"));
        }
        let body = decompress(packed)?;
        parse_body(&body)
    }
}

fn corrupt(why: impl Into<String>) -> ManifestError {
    ManifestError::Corrupt(why.into())
}

fn decompress(packed: &[u8]) -> Result<Vec<u8>, ManifestError> {
    let decoder = zstd::stream::read::Decoder::with_buffer(packed)
        .map_err(|e| corrupt(format!("decompression failed: {e}")))?;
    let mut body = Vec::new();
    decoder
        .take(MAX_DECODED_BYTES + 1)
        .read_to_end(&mut body)
        .map_err(|e| corrupt(format!("decompression failed: {e}")))?;
    if body.len() as u64 > MAX_DECODED_BYTES {
        return Err(corrupt("body is larger than the decode limit"));
    }
    Ok(body)
}

fn put_str(out: &mut Vec<u8>, s: &str) {
    out.extend_from_slice(&(s.len() as u32).to_le_bytes());
    out.extend_from_slice(s.as_bytes());
}

fn put_entry(out: &mut Vec<u8>, e: &Entry) {
    let s = &e.stat;
    put_str(out, &e.name);
    out.extend_from_slice(&e.parent.to_le_bytes());
    out.push(match s.kind {
        Kind::File => 0,
        Kind::Dir => 1,
        Kind::Symlink => 2,
    });
    let mut flags = 0;
    if s.withheld {
        flags |= FLAG_WITHHELD;
    }
    if s.link.is_some() {
        flags |= FLAG_LINK;
    }
    if s.hash.is_some() {
        flags |= FLAG_HASH;
    }
    if e.gone {
        flags |= FLAG_GONE;
    }
    out.push(flags);
    out.extend_from_slice(&s.mode.to_le_bytes());
    out.extend_from_slice(&s.size.to_le_bytes());
    out.extend_from_slice(&s.mtime_ns.to_le_bytes());
    out.extend_from_slice(&s.ctime_ns.to_le_bytes());
    if let Some(link) = &s.link {
        put_str(out, link);
    }
    if let Some(hash) = &s.hash {
        out.extend_from_slice(hash);
    }
}

/// A bounds-checked reader over the decompressed body.
struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn remaining(&self) -> usize {
        self.buf.len().saturating_sub(self.pos)
    }

    fn take(&mut self, n: usize) -> Result<&'a [u8], ManifestError> {
        let end = self.pos.checked_add(n).ok_or_else(|| corrupt("truncated body"))?;
        let out = self.buf.get(self.pos..end).ok_or_else(|| corrupt("truncated body"))?;
        self.pos = end;
        Ok(out)
    }

    fn array<const N: usize>(&mut self) -> Result<[u8; N], ManifestError> {
        <[u8; N]>::try_from(self.take(N)?).map_err(|_| corrupt("truncated body"))
    }

    fn u8(&mut self) -> Result<u8, ManifestError> {
        self.array().map(u8::from_le_bytes)
    }

    fn u32(&mut self) -> Result<u32, ManifestError> {
        self.array().map(u32::from_le_bytes)
    }

    fn u64(&mut self) -> Result<u64, ManifestError> {
        self.array().map(u64::from_le_bytes)
    }

    fn i64(&mut self) -> Result<i64, ManifestError> {
        self.array().map(i64::from_le_bytes)
    }

    fn string(&mut self, max: usize) -> Result<String, ManifestError> {
        let len = self.u32()? as usize;
        if len > max {
            return Err(corrupt("string longer than allowed"));
        }
        let raw = self.take(len)?;
        std::str::from_utf8(raw).map(str::to_owned).map_err(|_| corrupt("string is not UTF-8"))
    }
}

fn parse_body(body: &[u8]) -> Result<Manifest, ManifestError> {
    let mut r = Reader { buf: body, pos: 0 };
    let root = r.string(usize::MAX)?;
    let skipped = r.u64()?;
    let count = r.u32()? as usize;
    if count == 0 {
        return Err(corrupt("no root entry"));
    }
    if count > r.remaining() / MIN_ENTRY {
        return Err(corrupt("entry count exceeds the body"));
    }
    let mut entries: Vec<Entry> = Vec::with_capacity(count);
    for i in 0..count {
        let e = parse_entry(&mut r)?;
        link_entry(&mut entries, i, &e)?;
        entries.push(e);
    }
    if r.remaining() != 0 {
        return Err(corrupt("trailing bytes after the last entry"));
    }
    Ok(Manifest { root, entries, skipped })
}

fn parse_entry(r: &mut Reader<'_>) -> Result<Entry, ManifestError> {
    let name = r.string(MAX_NAME)?;
    let parent = r.u32()?;
    let kind = match r.u8()? {
        0 => Kind::File,
        1 => Kind::Dir,
        2 => Kind::Symlink,
        k => return Err(corrupt(format!("unknown kind {k}"))),
    };
    let flags = r.u8()?;
    if flags & !KNOWN_FLAGS != 0 {
        return Err(corrupt("unknown entry flags"));
    }
    let mode = r.u32()?;
    let size = r.u64()?;
    let mtime_ns = r.i64()?;
    let ctime_ns = r.i64()?;
    let link = if flags & FLAG_LINK != 0 { Some(r.string(MAX_LINK)?) } else { None };
    let hash = if flags & FLAG_HASH != 0 { Some(r.array::<32>()?) } else { None };
    let stat = Stat {
        kind,
        mode,
        size,
        mtime_ns,
        ctime_ns,
        link,
        hash,
        withheld: flags & FLAG_WITHHELD != 0,
    };
    stat.check().map_err(corrupt)?;
    let mut e = Entry::new(name, parent, stat);
    e.gone = flags & FLAG_GONE != 0;
    Ok(e)
}

/// Checks entry `i` against the ones before it and records it in its parent's children range:
/// the parent comes first and is a directory, siblings are contiguous and strictly sorted.
fn link_entry(entries: &mut [Entry], i: usize, e: &Entry) -> Result<(), ManifestError> {
    if i == 0 {
        if !e.name.is_empty() || e.parent != ROOT || e.stat.kind != Kind::Dir || e.gone {
            return Err(corrupt("the first entry is not a live root directory"));
        }
        return Ok(());
    }
    check_name(&e.name).map_err(corrupt)?;
    let p = e.parent as usize;
    if p >= i {
        return Err(corrupt("an entry comes before its parent"));
    }
    // `entries` holds exactly the `i` entries before this one, so `i - 1` and `p` are in it.
    let Some((prev_at, prev)) = i.checked_sub(1).and_then(|at| Some((at, entries.get(at)?))) else {
        return Err(corrupt("an entry comes before its parent"));
    };
    let contiguous = prev_at != 0 && prev.parent == e.parent;
    let sorted = prev.name.as_str() < e.name.as_str();
    let parent = entries.get_mut(p).ok_or_else(|| corrupt("an entry comes before its parent"))?;
    if parent.stat.kind != Kind::Dir {
        return Err(corrupt("an entry's parent is not a directory"));
    }
    if parent.n_children == 0 {
        parent.first_child = i as u32;
    } else if !contiguous {
        return Err(corrupt("a directory's children are not contiguous"));
    } else if !sorted {
        return Err(corrupt("a directory's children are not sorted and unique"));
    }
    parent.n_children += 1;
    Ok(())
}
