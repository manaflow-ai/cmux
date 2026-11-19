//! A log segment opened for a read, plain or compressed.
//!
//! A chat's log is `events/NNNNNN.ndjson` segments of about 8 MiB each (`store.segmentBytes`). A
//! closed chat's segments are compressed in place to `NNNNNN.ndjson.zst` (`store/log_zst.rs`, on
//! close; a host's own disk cleanup makes the same files with `zstd FILE`): one zstd frame of
//! the segment's bytes, as plain `zstd` writes it. Every read of the log lists both names and
//! opens either through [`SegmentFile`], so a compressed log reads as the plain one did.
//!
//! - **Plain wins.** A segment whose plain and compressed files are both there (a compression or
//!   a cleanup cut short between its rename and its removal of the plain file) is read from the
//!   plain file: it is the one an append may have gone on in.
//! - **Offsets are the plain file's.** Every reader seeks by byte offset in a segment (a page's
//!   marks, the kind index's coverage, a journal repair's pieces). A compressed segment answers
//!   the same offsets: its bytes are decoded once, streamed, into an unlinked scratch file, and
//!   read there by position. Its length comes from the frames' headers, so a read that needs only
//!   the length (a kind index copy that covers the whole segment) decodes nothing. The scratch
//!   copies of the last few segments read are kept ([`SCRATCH_KEPT`], [`SCRATCH_BYTES`]), so a
//!   page that reads a segment in chunks decodes it once. Memory stays a buffer and zstd's
//!   window whatever the segment's size; the decode writes to the temporary folder, not the
//!   log's.
//! - **A compressed segment is never written.** An append to a chat whose last segment is
//!   compressed starts the next one (`LocalStore::open_writer`), so the old one stays as the
//!   cleanup left it and every reader agrees on its bytes.
//! - **Its identity is the compressed file's** (device, inode, birth time): a kind or text index
//!   copy of it, or a page's mark in it, holds across reads and scratch copies.

use super::*;
use std::io::{Seek, SeekFrom};
use std::sync::Arc;

/// The name a compressed segment adds to its plain one.
pub(crate) const ZST: &str = ".zst";

/// How many decoded segments are kept for the reads that follow.
const SCRATCH_KEPT: usize = 4;
/// The most decoded bytes kept: a segment larger than this is decoded for its read alone.
const SCRATCH_BYTES: u64 = 64 << 20;
/// The largest zstd window a compressed segment may ask for: `--long=31`, what a host cleanup
/// checks its output with (`zstd -t --long=31`). The decoder holds at most the frame's content
/// size of it (one segment, about 8 MiB), so a large window costs no more memory.
pub(crate) const WINDOW_LOG_MAX: u32 = 31;

/// A segment file name's index and whether it is the compressed one: `NNNNNN.ndjson` or
/// `NNNNNN.ndjson.zst`.
pub(crate) fn segment_name(name: &str) -> Option<(u32, bool)> {
    let (stem, zst) = match name.strip_suffix(".ndjson.zst") {
        Some(stem) => (stem, true),
        None => (name.strip_suffix(".ndjson")?, false),
    };
    Some((stem.parse().ok()?, zst))
}

/// Whether `path` names a compressed segment.
pub(crate) fn is_zst(path: &Path) -> bool {
    path.file_name().and_then(|n| n.to_str()).and_then(segment_name).is_some_and(|(_, zst)| zst)
}

/// The plain segment's path for either name.
pub(crate) fn plain_path(path: &Path) -> PathBuf {
    match path.to_str().and_then(|p| p.strip_suffix(ZST)) {
        Some(plain) if is_zst(path) => PathBuf::from(plain),
        _ => path.to_path_buf(),
    }
}

/// The compressed segment's path for a plain one.
pub(crate) fn zst_path(plain: &Path) -> PathBuf {
    let mut name = plain.as_os_str().to_os_string();
    name.push(ZST);
    PathBuf::from(name)
}

/// A file's device, inode and birth time (0 where the system keeps none).
pub(crate) type FileId = (u64, u64, u64);

/// One segment open for a read.
pub(crate) struct SegmentFile {
    inner: Inner,
}

enum Inner {
    Plain(File),
    Zst(Zst),
}

struct Zst {
    file: File,
    id: FileId,
    meta: std::fs::Metadata,
    /// The decoded length, once known.
    len: Option<u64>,
    /// The decoded bytes, once a read needed them out of order.
    data: Option<Arc<File>>,
    /// A decode from the start, while every read so far went forward from it.
    stream: Option<Stream>,
    pos: u64,
}

/// A decoder of the whole segment and how far it has decoded.
struct Stream {
    decoder: zstd::stream::read::Decoder<'static, std::io::BufReader<File>>,
    at: u64,
}

impl SegmentFile {
    /// Opens the segment at `path` (either name) with the checks every read of a segment makes
    /// (`config::private_state_file`). A segment listed under one name and gone from it by the
    /// open is opened under the other: a compression renamed it meanwhile (plain to
    /// compressed), or a retention rewrite put its plain bytes back (compressed to plain).
    pub(crate) fn open(path: &Path) -> Result<Self> {
        let other = if is_zst(path) { plain_path(path) } else { zst_path(path) };
        let path = match crate::config::private_state_file(path) {
            Ok(file) => return Self::of(path, file),
            Err(error) if is_not_found(&error) => other,
            Err(error) => return Err(error),
        };
        let file = crate::config::private_state_file(&path)?;
        Self::of(&path, file)
    }

    fn of(path: &Path, file: File) -> Result<Self> {
        if !is_zst(path) {
            return Ok(Self { inner: Inner::Plain(file) });
        }
        let meta = file.metadata()?;
        let id = file_id(&file, &meta);
        Ok(Self {
            inner: Inner::Zst(Zst { file, id, meta, len: None, data: None, stream: None, pos: 0 }),
        })
    }

    /// Whether this is a compressed segment.
    pub(crate) fn is_zst(&self) -> bool {
        matches!(self.inner, Inner::Zst(_))
    }

    /// The plain file, for what only a plain file takes (a cache hint).
    pub(crate) fn plain(&self) -> Option<&File> {
        match &self.inner {
            Inner::Plain(file) => Some(file),
            Inner::Zst(_) => None,
        }
    }

    /// The segment's length in plain bytes: the file's now, or what the compressed one decodes to.
    pub(crate) fn len(&mut self) -> std::io::Result<u64> {
        match &mut self.inner {
            Inner::Plain(file) => Ok(file.metadata()?.len()),
            Inner::Zst(zst) => zst.len(),
        }
    }

    /// The file's device, inode and birth time: the compressed file's for a compressed segment.
    pub(crate) fn id(&self) -> std::io::Result<FileId> {
        match &self.inner {
            Inner::Plain(file) => Ok(file_id(file, &file.metadata()?)),
            Inner::Zst(zst) => Ok(zst.id),
        }
    }

    /// The file's metadata (the compressed file's for a compressed segment).
    pub(crate) fn metadata(&self) -> std::io::Result<std::fs::Metadata> {
        match &self.inner {
            Inner::Plain(file) => file.metadata(),
            Inner::Zst(zst) => Ok(zst.meta.clone()),
        }
    }

    /// Reads at `offset`, by position: short only at the end.
    pub(crate) fn read_at(&mut self, offset: u64, out: &mut [u8]) -> std::io::Result<usize> {
        match &mut self.inner {
            Inner::Plain(file) => {
                let mut filled = 0;
                while let Some(rest) = out.get_mut(filled..).filter(|rest| !rest.is_empty()) {
                    let n = read_at(file, offset.saturating_add(filled as u64), rest)?;
                    if n == 0 {
                        break;
                    }
                    filled += n;
                }
                Ok(filled)
            }
            Inner::Zst(zst) => {
                let mut filled = 0;
                while let Some(rest) = out.get_mut(filled..).filter(|rest| !rest.is_empty()) {
                    let n = zst.read_at(offset.saturating_add(filled as u64), rest)?;
                    if n == 0 {
                        break;
                    }
                    filled += n;
                }
                Ok(filled)
            }
        }
    }
}

impl Read for SegmentFile {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        match &mut self.inner {
            Inner::Plain(file) => file.read(buf),
            Inner::Zst(zst) => {
                let n = zst.read_at(zst.pos, buf)?;
                zst.pos = zst.pos.saturating_add(n as u64);
                Ok(n)
            }
        }
    }
}

impl Seek for SegmentFile {
    fn seek(&mut self, to: SeekFrom) -> std::io::Result<u64> {
        match &mut self.inner {
            Inner::Plain(file) => file.seek(to),
            Inner::Zst(zst) => {
                let at = match to {
                    SeekFrom::Start(at) => Some(at),
                    SeekFrom::End(by) => zst.len()?.checked_add_signed(by),
                    SeekFrom::Current(by) => zst.pos.checked_add_signed(by),
                };
                zst.pos = at.ok_or_else(|| {
                    std::io::Error::new(std::io::ErrorKind::InvalidInput, "seek before the start")
                })?;
                Ok(zst.pos)
            }
        }
    }
}

impl Zst {
    fn len(&mut self) -> std::io::Result<u64> {
        if let Some(len) = self.len {
            return Ok(len);
        }
        let len = match frames_len(&self.file)? {
            Some(len) => len,
            // A frame that does not say its size: the decode says.
            None => self.data()?.metadata()?.len(),
        };
        self.len = Some(len);
        Ok(len)
    }

    /// Reads at `offset`: from a kept decode, else from the decode from the start while the
    /// reads go forward (a scan, a segment's first line), else from a scratch copy decoded now.
    fn read_at(&mut self, offset: u64, out: &mut [u8]) -> std::io::Result<usize> {
        if out.is_empty() || self.len.is_some_and(|len| offset >= len) {
            return Ok(0);
        }
        let kept =
            if self.data.is_none() { scratch().get(&Key::of(self.id, &self.meta)) } else { None };
        if let Some(data) = kept {
            self.stream = None;
            self.data = Some(data);
        }
        if let Some(data) = &self.data {
            return read_at(data, offset, out);
        }
        let forward = match &self.stream {
            Some(stream) => offset >= stream.at,
            None => offset == 0,
        };
        if !forward {
            self.stream = None;
            let data = self.data()?;
            return read_at(&data, offset, out);
        }
        if self.stream.is_none() {
            let mut file = self.file.try_clone()?;
            file.seek(SeekFrom::Start(0))?;
            self.stream = Some(Stream { decoder: decoder(file)?, at: 0 });
        }
        let Some(stream) = self.stream.as_mut() else { return Ok(0) };
        let skip = offset - stream.at;
        if skip > 0 {
            let skipped =
                std::io::copy(&mut (&mut stream.decoder).take(skip), &mut std::io::sink())?;
            stream.at += skipped;
            if skipped < skip {
                self.len = Some(stream.at);
                return Ok(0);
            }
        }
        let n = stream.decoder.read(out)?;
        stream.at += n as u64;
        if n == 0 {
            self.len = Some(stream.at);
        }
        Ok(n)
    }

    /// The decoded bytes: kept from an earlier read of this file, or decoded now.
    fn data(&mut self) -> std::io::Result<Arc<File>> {
        if let Some(data) = &self.data {
            return Ok(data.clone());
        }
        let key = Key::of(self.id, &self.meta);
        // The lock is let go before a decode: `put` takes it again.
        let kept = scratch().get(&key);
        let data = match kept {
            Some(data) => data,
            None => {
                let mut file = self.file.try_clone()?;
                file.seek(SeekFrom::Start(0))?;
                let decoded = decode_to_scratch(file)?;
                let len = decoded.metadata()?.len();
                let decoded = Arc::new(decoded);
                scratch().put(key, decoded.clone(), len);
                decoded
            }
        };
        self.len = Some(data.metadata()?.len());
        self.data = Some(data.clone());
        Ok(data)
    }
}

/// Reads at `offset` of `file`, by position.
fn read_at(file: &File, offset: u64, out: &mut [u8]) -> std::io::Result<usize> {
    #[cfg(unix)]
    {
        std::os::unix::fs::FileExt::read_at(file, out, offset)
    }
    #[cfg(windows)]
    {
        std::os::windows::fs::FileExt::seek_read(file, out, offset)
    }
}

/// Fills `out` from `offset` of `file`; false when the file ends first.
fn read_exact_at(file: &File, offset: u64, out: &mut [u8]) -> std::io::Result<bool> {
    let mut filled = 0;
    while let Some(rest) = out.get_mut(filled..).filter(|rest| !rest.is_empty()) {
        let n = read_at(file, offset.saturating_add(filled as u64), rest)?;
        if n == 0 {
            return Ok(false);
        }
        filled += n;
    }
    Ok(true)
}

/// A zstd decoder of `from` with this store's window limit.
pub(crate) fn decoder<R: Read>(
    from: R,
) -> std::io::Result<zstd::stream::read::Decoder<'static, std::io::BufReader<R>>> {
    let mut decoder = zstd::stream::read::Decoder::new(from)?;
    decoder.window_log_max(WINDOW_LOG_MAX)?;
    Ok(decoder)
}

/// Decodes `zst` into an unlinked temporary file, streamed: a buffer and the frame's window at
/// most in memory, whatever the segment's size.
fn decode_to_scratch(zst: File) -> std::io::Result<File> {
    let mut out = tempfile::tempfile()?;
    {
        let mut writer = std::io::BufWriter::with_capacity(256 * 1024, &mut out);
        let mut decoder = decoder(zst)?;
        std::io::copy(&mut decoder, &mut writer)?;
        writer.flush()?;
    }
    Ok(out)
}

/// The decoded length of the zstd frames in `file`, from their headers alone: the sum of each
/// frame's content size, skippable frames counting none. None when a frame does not say its size
/// (a stream compressed from a pipe); an error when the frames do not read as zstd.
pub(crate) fn frames_len(file: &File) -> std::io::Result<Option<u64>> {
    const MAGIC: u32 = 0xFD2F_B528;
    let bad = |what: &str| std::io::Error::new(std::io::ErrorKind::InvalidData, what.to_owned());
    let end = file.metadata()?.len();
    let mut at = 0u64;
    let mut total = 0u64;
    while at < end {
        let mut word = [0u8; 4];
        if !read_exact_at(file, at, &mut word)? {
            return Err(bad("a zstd frame is cut short"));
        }
        let magic = u32::from_le_bytes(word);
        if magic & 0xFFFF_FFF0 == 0x184D_2A50 {
            // A skippable frame: its size, then that many bytes.
            if !read_exact_at(file, at + 4, &mut word)? {
                return Err(bad("a skippable frame is cut short"));
            }
            at = at.saturating_add(8).saturating_add(u64::from(u32::from_le_bytes(word)));
            continue;
        }
        if magic != MAGIC {
            return Err(bad("not a zstd frame"));
        }
        // The frame header: its descriptor, then the window, dictionary and content size fields.
        let mut fhd = [0u8; 1];
        if !read_exact_at(file, at + 4, &mut fhd)? {
            return Err(bad("a zstd frame header is cut short"));
        }
        let fhd = fhd[0];
        let single = fhd & 0x20 != 0;
        let checksum = fhd & 0x04 != 0;
        let dict = [0u64, 1, 2, 4][usize::from(fhd & 0x03)];
        let fcs = match fhd >> 6 {
            0 if single => 1u64,
            0 => 0,
            1 => 2,
            2 => 4,
            _ => 8,
        };
        let fcs_at = at + 5 + u64::from(!single) + dict;
        if fcs == 0 {
            return Ok(None);
        }
        let mut size = [0u8; 8];
        let fcs_len = usize::try_from(fcs).unwrap_or(8);
        if !read_exact_at(file, fcs_at, &mut size[..fcs_len])? {
            return Err(bad("a zstd frame header is cut short"));
        }
        let mut content = u64::from_le_bytes(size);
        if fcs == 2 {
            content += 256;
        }
        total = total.saturating_add(content);
        // The blocks: each a 3-byte header naming its type and size, the last one marked.
        let mut block = fcs_at + fcs;
        loop {
            let mut head = [0u8; 3];
            if !read_exact_at(file, block, &mut head)? {
                return Err(bad("a zstd block is cut short"));
            }
            let head = u32::from(head[0]) | u32::from(head[1]) << 8 | u32::from(head[2]) << 16;
            let last = head & 1 != 0;
            let size = u64::from(head >> 3);
            block += 3 + match (head >> 1) & 3 {
                // Raw and compressed blocks hold their size in bytes; an RLE block holds one byte.
                0 | 2 => size,
                1 => 1,
                _ => return Err(bad("a reserved zstd block type")),
            };
            if last {
                break;
            }
        }
        at = block + if checksum { 4 } else { 0 };
    }
    if at != end {
        return Err(bad("a zstd frame runs past the file's end"));
    }
    Ok(Some(total))
}

/// The file's device, inode and birth time.
pub(crate) fn file_id(file: &File, meta: &std::fs::Metadata) -> FileId {
    let born = super::kind_index::birth_ns(file).unwrap_or_else(|| {
        meta.created()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map_or(0, |d| u64::try_from(d.as_nanos()).unwrap_or(u64::MAX))
    });
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        (meta.dev(), meta.ino(), born)
    }
    #[cfg(not(unix))]
    {
        let _ = meta;
        (0, 0, born)
    }
}

/// A compressed file as it was when decoded: a file changed or replaced since is decoded again.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
struct Key {
    id: FileId,
    len: u64,
    modified: Option<std::time::SystemTime>,
}

impl Key {
    fn of(id: FileId, meta: &std::fs::Metadata) -> Self {
        Self { id, len: meta.len(), modified: meta.modified().ok() }
    }
}

/// The decoded segments kept for the reads that follow ([module docs](self)).
#[derive(Default)]
struct Scratch {
    kept: Vec<(Key, Arc<File>, u64, u64)>,
    clock: u64,
}

#[cfg(test)]
thread_local! {
    /// Tests: how many segments this thread decoded (per thread, so parallel tests don't mix).
    static DECODED: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

fn scratch() -> std::sync::MutexGuard<'static, Scratch> {
    static SCRATCH: Mutex<Scratch> = Mutex::new(Scratch { kept: Vec::new(), clock: 0 });
    SCRATCH.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

impl Scratch {
    fn get(&mut self, key: &Key) -> Option<Arc<File>> {
        self.clock += 1;
        let clock = self.clock;
        let kept = self.kept.iter_mut().find(|(k, ..)| k == key)?;
        kept.3 = clock;
        Some(kept.1.clone())
    }

    fn put(&mut self, key: Key, data: Arc<File>, len: u64) {
        #[cfg(test)]
        DECODED.with(|n| n.set(n.get() + 1));
        if len > SCRATCH_BYTES {
            return;
        }
        self.clock += 1;
        self.kept.retain(|(k, ..)| *k != key);
        self.kept.push((key, data, len, self.clock));
        while self.kept.len() > SCRATCH_KEPT
            || self.kept.iter().map(|(_, _, len, _)| *len).sum::<u64>() > SCRATCH_BYTES
        {
            let Some(oldest) =
                self.kept.iter().enumerate().min_by_key(|(_, k)| k.3).map(|(i, _)| i)
            else {
                break;
            };
            self.kept.swap_remove(oldest);
        }
    }
}

/// Tests: how many segments this thread decoded into a scratch file so far.
#[cfg(test)]
pub(crate) fn decoded_count() -> u64 {
    DECODED.with(std::cell::Cell::get)
}

/// Tests: drops every kept scratch copy, so the next read of a compressed segment decodes it.
#[cfg(test)]
pub(crate) fn forget_scratch() {
    scratch().kept.clear();
}

#[cfg(test)]
#[path = "segment_file_tests.rs"]
mod tests;
