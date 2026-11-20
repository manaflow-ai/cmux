//! A push's stat cache, by git's index rules: a file whose stat (size, mtime and ctime to the
//! nanosecond, inode, device and mode) is what it was when this Mac last hashed it is not read
//! again, so a re-push of a folder where nothing changed reads none of its bytes (it read and
//! hashed all of them before: 20 GB for a 20 GB folder). The store's chunk list of a large file
//! is kept beside its SHA-256, so a push to another machine does not cut it again.
//!
//! The cache is `<state>/link-sync/<sha256 of "stat-cache v1", NUL, the folder>.stat` (0600, next
//! to the records [`super::base`] keeps), one per folder here, never on a machine: what it says is
//! about this Mac's files only, so pushes of one folder to any machine share it, and a pull trusts
//! nothing in it (a pull still trusts only [`super::base`]'s record). A cache that is missing,
//! damaged, of another version or chunking, or of another folder is ignored, never an error; one
//! is written to a temporary name and renamed. `CMUX_SYNC_STAT_CACHE=0` turns it off.
//!
//! Racy timestamps (git's racy-git rule, made stricter): an entry is kept only when the newer of
//! its file's mtime and ctime is older than the moment this push began listing by more than the
//! clock tick the timestamps show (50 ms, or 2 s on a whole-second or millisecond volume). Any
//! later write sets ctime to a later tick, so an edit in the same tick as the hash is never
//! missed: the file is hashed again until it has been still for a tick. An entry is also not
//! trusted unless that time is older than the cache file's own mtime, as git checks.
//!
//! Format (version 1, little-endian), read in one pass in the push's path order (bounded memory
//! at any file count): `CMUXSTAT`, u32 version, the store's chunking (6 × u64), the folder's key
//! (32 bytes); then per entry, in path order: u8 1, varint bytes shared with the previous path,
//! varint length and the rest of the path, u64 device, u64 inode, u32 mode, u64 size, i64 mtime
//! seconds, u32 mtime nanoseconds, i64 ctime seconds, u32 ctime nanoseconds, the SHA-256 (32
//! bytes), u8 pushes since it was last looked up, varint chunk count and per chunk varint size and
//! SHA-256; then u8 0 and the SHA-256 of every byte before it.

use std::fs::File;
use std::io::{BufReader, BufWriter, Read, Seek as _, SeekFrom, Write as _};
use std::os::unix::fs::{DirBuilderExt as _, MetadataExt as _, OpenOptionsExt as _};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use sha2::{Digest as _, Sha256};

use super::local::{LocalFile, Source};
use super::store::{self, Piece};

const MAGIC: &[u8; 8] = b"CMUXSTAT";
const VERSION: u32 = 1;
/// Longest path an entry may hold (the machine takes 4000 bytes, [`super::local::holdable`]).
const MAX_PATH: u64 = 8192;
/// Most chunks an entry may hold (a 1 TB file cut at the store's least chunk).
const MAX_PIECES: u64 = 1 << 21;
/// A file a push did not look at (a push of part of the folder: a first pass, a head, a
/// share) keeps its entry for this many pushes.
const KEEP_UNSEEN: u8 = 8;
/// The clock tick an entry must be older than, by its timestamps' look.
const FINE_TICK_NS: i128 = 50_000_000;
const COARSE_TICK_NS: i128 = 2_000_000_000;

/// Files of the folder a push opened to read (hash, write or upload), for the timings line and
/// tests: an unchanged re-push opens none.
pub(super) static OPENED: AtomicU64 = AtomicU64::new(0);

/// Counts one open of a listed file for reading ([`OPENED`]).
pub(super) fn opened() {
    OPENED.fetch_add(1, Ordering::Relaxed);
}

/// What the cache compares: a file's stat, as git's index keeps it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Stat {
    pub dev: u64,
    pub ino: u64,
    pub mode: u32,
    pub size: u64,
    pub mtime: (i64, u32),
    pub ctime: (i64, u32),
}

impl Stat {
    /// The stat of `meta`, as [`super::place::Dir::entry`] takes it.
    pub(super) fn of(meta: &std::fs::Metadata) -> Self {
        let nanos = |value: i64| u32::try_from(value).unwrap_or(0);
        Self {
            dev: meta.dev(),
            ino: meta.ino(),
            mode: meta.mode() & 0o177_777,
            size: meta.size(),
            mtime: (meta.mtime(), nanos(meta.mtime_nsec())),
            ctime: (meta.ctime(), nanos(meta.ctime_nsec())),
        }
    }

    /// The newer of mtime and ctime, in nanoseconds since 1970.
    fn newest(&self) -> i128 {
        nanos(self.mtime).max(nanos(self.ctime))
    }

    /// Whether this stat, taken at or after `since`, is old enough that any later write would
    /// change it (see the module doc).
    fn settled(&self, since: i128) -> bool {
        let coarse = self.mtime.1 % 1_000_000 == 0 && self.ctime.1 % 1_000_000 == 0;
        let tick = if coarse { COARSE_TICK_NS } else { FINE_TICK_NS };
        self.newest().saturating_add(tick) < since
    }
}

fn nanos((seconds, nanos): (i64, u32)) -> i128 {
    i128::from(seconds).saturating_mul(1_000_000_000).saturating_add(i128::from(nanos))
}

fn now() -> i128 {
    let since =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
    i128::try_from(since.as_nanos()).unwrap_or(i128::MAX)
}

/// Whether the cache is on (`CMUX_SYNC_STAT_CACHE=0` turns it off).
fn enabled() -> bool {
    std::env::var_os("CMUX_SYNC_STAT_CACHE").is_none_or(|value| value != "0")
}

/// The name the cache of `local` (canonical) is kept under.
fn key(local: &Path) -> [u8; 32] {
    let mut key = Sha256::new();
    key.update(b"stat-cache v1\0");
    key.update(local.as_os_str().as_encoded_bytes());
    key.finalize().into()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn unhex(text: &str) -> Option<[u8; 32]> {
    let mut out = [0u8; 32];
    if text.len() != 64 {
        return None;
    }
    for (slot, pair) in out.iter_mut().zip(text.as_bytes().chunks_exact(2)) {
        let pair = std::str::from_utf8(pair).ok()?;
        *slot = u8::from_str_radix(pair, 16).ok()?;
    }
    Some(out)
}

/// Where the cache of the folder `local` (canonical) is kept.
pub(super) fn path_of(local: &Path) -> Option<PathBuf> {
    let state = cmux_tui_core::platform::workspace_state_dir()?;
    Some(state.join("link-sync").join(format!("{}.stat", hex(&key(local)))))
}

/// The header both ends check: version, the store's chunking and the folder.
fn header(local: &Path) -> Vec<u8> {
    let mut out = Vec::with_capacity(8 + 4 + 48 + 32);
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&VERSION.to_le_bytes());
    for value in store::chunking() {
        out.extend_from_slice(&value.to_le_bytes());
    }
    out.extend_from_slice(&key(local));
    out
}

/// One entry of the cache.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Entry {
    path: Vec<u8>,
    stat: Stat,
    sha256: [u8; 32],
    unseen: u8,
    /// The store's chunks (size and SHA-256); empty when not cut (a small file, or no store).
    pieces: Vec<(u64, [u8; 32])>,
}

/// An earlier cache, read entry by entry in path order.
struct Reader {
    input: BufReader<File>,
    /// The cache file's own mtime: an entry not older is not trusted.
    written: i128,
    last: Vec<u8>,
    next: Option<Entry>,
    done: bool,
}

impl Reader {
    /// The cache at `path` for `local`, when it is whole and of this version, chunking and folder.
    fn open(path: &Path, local: &Path) -> Option<Self> {
        let file = std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(path)
            .ok()?;
        let meta = file.metadata().ok()?;
        if !meta.is_file() {
            return None;
        }
        let written = nanos(Stat::of(&meta).mtime);
        let body = meta.len().checked_sub(32)?;
        let mut input = BufReader::with_capacity(1 << 20, file);
        // The whole file is checked before any entry is used.
        let mut hasher = Sha256::new();
        let copied = std::io::copy(&mut (&mut input).take(body), &mut hasher).ok()?;
        let mut trailer = [0u8; 32];
        input.read_exact(&mut trailer).ok()?;
        if copied != body || <[u8; 32]>::from(hasher.finalize()) != trailer {
            return None;
        }
        input.seek(SeekFrom::Start(0)).ok()?;
        let expected = header(local);
        let mut found = vec![0u8; expected.len()];
        input.read_exact(&mut found).ok()?;
        if found != expected {
            return None;
        }
        Some(Self { input, written, last: Vec::new(), next: None, done: false })
    }

    /// The next entry, or None at the end (or at anything that does not parse).
    fn advance(&mut self) -> Option<Entry> {
        if let Some(entry) = self.next.take() {
            return Some(entry);
        }
        if self.done {
            return None;
        }
        let entry = self.parse();
        if entry.is_none() {
            self.done = true;
        }
        entry
    }

    fn parse(&mut self) -> Option<Entry> {
        if u8_of(&mut self.input)? != 1 {
            return None;
        }
        let shared = usize::try_from(varint(&mut self.input)?).ok()?;
        let rest = varint(&mut self.input)?;
        if rest > MAX_PATH {
            return None;
        }
        let mut path = self.last.get(..shared)?.to_vec();
        let mut tail = vec![0u8; usize::try_from(rest).ok()?];
        self.input.read_exact(&mut tail).ok()?;
        path.extend_from_slice(&tail);
        let stat = Stat {
            dev: u64_of(&mut self.input)?,
            ino: u64_of(&mut self.input)?,
            mode: u32_of(&mut self.input)?,
            size: u64_of(&mut self.input)?,
            mtime: (i64_of(&mut self.input)?, u32_of(&mut self.input)?),
            ctime: (i64_of(&mut self.input)?, u32_of(&mut self.input)?),
        };
        let sha256 = sha_of(&mut self.input)?;
        let unseen = u8_of(&mut self.input)?;
        let count = varint(&mut self.input)?;
        if count > MAX_PIECES {
            return None;
        }
        let mut pieces = Vec::new();
        for _ in 0..count {
            let size = varint(&mut self.input)?;
            pieces.push((size, sha_of(&mut self.input)?));
        }
        self.last.clone_from(&path);
        Some(Entry { path, stat, sha256, unseen, pieces })
    }

    /// The entry for `path` when it is the next one; entries before it go to `passed`.
    fn find(&mut self, path: &[u8], passed: &mut dyn FnMut(Entry)) -> Option<Entry> {
        while let Some(entry) = self.advance() {
            match entry.path.as_slice().cmp(path) {
                std::cmp::Ordering::Less => passed(entry),
                std::cmp::Ordering::Equal => return Some(entry),
                std::cmp::Ordering::Greater => {
                    self.next = Some(entry);
                    return None;
                }
            }
        }
        None
    }
}

fn u8_of(input: &mut impl Read) -> Option<u8> {
    let mut byte = [0u8; 1];
    input.read_exact(&mut byte).ok()?;
    Some(u8::from_le_bytes(byte))
}

fn u32_of(input: &mut impl Read) -> Option<u32> {
    let mut bytes = [0u8; 4];
    input.read_exact(&mut bytes).ok()?;
    Some(u32::from_le_bytes(bytes))
}

fn u64_of(input: &mut impl Read) -> Option<u64> {
    let mut bytes = [0u8; 8];
    input.read_exact(&mut bytes).ok()?;
    Some(u64::from_le_bytes(bytes))
}

fn i64_of(input: &mut impl Read) -> Option<i64> {
    let mut bytes = [0u8; 8];
    input.read_exact(&mut bytes).ok()?;
    Some(i64::from_le_bytes(bytes))
}

fn sha_of(input: &mut impl Read) -> Option<[u8; 32]> {
    let mut bytes = [0u8; 32];
    input.read_exact(&mut bytes).ok()?;
    Some(bytes)
}

/// A LEB128 varint of at most 10 bytes.
fn varint(input: &mut impl Read) -> Option<u64> {
    let mut value = 0u64;
    for shift in (0..70).step_by(7) {
        let byte = u8_of(input)?;
        value |= u64::from(byte & 0x7f).checked_shl(shift)?;
        if byte & 0x80 == 0 {
            return Some(value);
        }
    }
    None
}

fn put_varint(out: &mut Vec<u8>, mut value: u64) {
    loop {
        let low = u8::try_from(value & 0x7f).unwrap_or(0);
        value >>= 7;
        if value == 0 {
            out.push(low);
            return;
        }
        out.push(low | 0x80);
    }
}

/// A new cache, written entry by entry to a temporary name and renamed in place.
struct Writer {
    out: BufWriter<File>,
    hasher: Sha256,
    part: PathBuf,
    path: PathBuf,
    last: Vec<u8>,
    scratch: Vec<u8>,
    failed: bool,
    finished: bool,
}

impl Writer {
    fn create(path: &Path, local: &Path) -> Option<Self> {
        let dir = path.parent()?;
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir).ok()?;
        let part = path.with_extension(format!("stat.{}.part", std::process::id()));
        let _ = std::fs::remove_file(&part);
        let file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&part)
            .ok()?;
        let mut writer = Self {
            out: BufWriter::with_capacity(1 << 20, file),
            hasher: Sha256::new(),
            part,
            path: path.to_path_buf(),
            last: Vec::new(),
            scratch: Vec::new(),
            failed: false,
            finished: false,
        };
        writer.put(&header(local));
        Some(writer)
    }

    fn put(&mut self, bytes: &[u8]) {
        if self.failed {
            return;
        }
        self.hasher.update(bytes);
        if self.out.write_all(bytes).is_err() {
            self.failed = true;
        }
    }

    fn add(&mut self, entry: &Entry) {
        let shared = self.last.iter().zip(&entry.path).take_while(|(a, b)| a == b).count();
        let mut out = std::mem::take(&mut self.scratch);
        out.clear();
        out.push(1);
        put_varint(&mut out, shared as u64);
        let tail = entry.path.get(shared..).unwrap_or_default();
        put_varint(&mut out, tail.len() as u64);
        out.extend_from_slice(tail);
        let stat = &entry.stat;
        out.extend_from_slice(&stat.dev.to_le_bytes());
        out.extend_from_slice(&stat.ino.to_le_bytes());
        out.extend_from_slice(&stat.mode.to_le_bytes());
        out.extend_from_slice(&stat.size.to_le_bytes());
        out.extend_from_slice(&stat.mtime.0.to_le_bytes());
        out.extend_from_slice(&stat.mtime.1.to_le_bytes());
        out.extend_from_slice(&stat.ctime.0.to_le_bytes());
        out.extend_from_slice(&stat.ctime.1.to_le_bytes());
        out.extend_from_slice(&entry.sha256);
        out.push(entry.unseen);
        put_varint(&mut out, entry.pieces.len() as u64);
        for (size, sha256) in &entry.pieces {
            put_varint(&mut out, *size);
            out.extend_from_slice(sha256);
        }
        self.put(&out);
        self.scratch = out;
        self.last.clone_from(&entry.path);
    }

    /// Ends the cache and puts it in place; nothing is left when that fails.
    fn finish(mut self) {
        self.put(&[0]);
        let trailer: [u8; 32] = std::mem::take(&mut self.hasher).finalize().into();
        if !self.failed && self.out.write_all(&trailer).is_ok() && self.out.flush().is_ok() {
            // No fsync: a cache torn by a crash fails its checksum and is ignored.
            self.finished = std::fs::rename(&self.part, &self.path).is_ok();
        }
    }
}

impl Drop for Writer {
    fn drop(&mut self) {
        if !self.finished {
            let _ = std::fs::remove_file(&self.part);
        }
    }
}

/// One file's hash as a push takes it.
pub(super) struct Hashed {
    pub sha256: String,
    /// Its length: as read, or the listed (and cached) size when it was not read.
    pub bytes: u64,
    /// The store's chunks of a file over its whole-file limit, when the push goes through the
    /// store (cut in the same read as the hash) or the cache had them.
    pub pieces: Option<Vec<Piece>>,
}

/// A push's use of the cache: each file looked up in path order, and the new cache written as
/// it goes.
pub(super) struct Pass {
    reader: Option<Reader>,
    writer: Option<Writer>,
    since: i128,
    /// Files read and hashed, their bytes, and files the cache answered.
    pub hashed: u64,
    pub hashed_bytes: u64,
    pub cached: u64,
}

impl Pass {
    /// Starts a push's pass over the folder `local` (canonical): before it is listed, so every
    /// stat the push takes is at or after this moment.
    pub(super) fn begin(local: &Path) -> Self {
        let since = now();
        let path = enabled().then(|| path_of(local)).flatten();
        Self::at(path.as_deref(), local, since)
    }

    /// [`Pass::begin`] with the cache at `path` (None: off) and the listing begun at `since`.
    fn at(path: Option<&Path>, local: &Path, since: i128) -> Self {
        let reader = path.and_then(|path| Reader::open(path, local));
        let writer = path.and_then(|path| Writer::create(path, local));
        Self { reader, writer, since, hashed: 0, hashed_bytes: 0, cached: 0 }
    }

    /// Carries an entry this push did not look at, for a while ([`KEEP_UNSEEN`]).
    fn carry(writer: Option<&mut Writer>, mut entry: Entry) {
        if entry.unseen >= KEEP_UNSEEN {
            return;
        }
        entry.unseen = entry.unseen.saturating_add(1);
        if let Some(writer) = writer {
            writer.add(&entry);
        }
    }

    /// The SHA-256 and length of `file` at `relative` (looked up in path order), and its store
    /// chunks when `store` (a push through the store) and it is over the whole-file limit. A file
    /// whose stat is the cached one is not opened.
    pub(super) fn hash(
        &mut self,
        relative: &str,
        file: &LocalFile,
        store: bool,
    ) -> anyhow::Result<Hashed> {
        let stat = match &file.source {
            Source::File(_) => file.stat,
            Source::Checked(_) | Source::Bytes(_) => None,
        };
        let writer = &mut self.writer;
        let earlier = match self.reader.as_mut() {
            Some(reader) => {
                reader.find(relative.as_bytes(), &mut |entry| Self::carry(writer.as_mut(), entry))
            }
            None => None,
        };
        let written = self.reader.as_ref().map_or(i128::MIN, |reader| reader.written);
        let big = |size: u64| store && size > store::whole_file_max();
        let hit = earlier.filter(|entry| {
            stat.is_some_and(|stat| stat == entry.stat)
                && entry.stat.newest() < written
                && (!big(entry.stat.size) || covers(&entry.pieces, entry.stat.size))
        });
        let (sha256, bytes, pieces) = match hit {
            Some(entry) => {
                self.cached = self.cached.saturating_add(1);
                (entry.sha256, entry.stat.size, entry.pieces)
            }
            None => {
                let listed = stat.map_or(0, |stat| stat.size);
                let (sha256, bytes, pieces) = read(file, big(listed))?;
                self.hashed = self.hashed.saturating_add(1);
                self.hashed_bytes = self.hashed_bytes.saturating_add(bytes);
                // Pieces of a file that turned out small are not the store's.
                let pieces = if big(bytes) { pieces } else { Vec::new() };
                (sha256, bytes, pieces)
            }
        };
        if let (Some(stat), Some(writer)) = (stat, self.writer.as_mut())
            && stat.size == bytes
            && stat.settled(self.since)
        {
            let path = relative.as_bytes().to_vec();
            writer.add(&Entry { path, stat, sha256, unseen: 0, pieces: pieces.clone() });
        }
        let pieces = (!pieces.is_empty()).then(|| {
            let mut offset = 0u64;
            pieces
                .iter()
                .map(|(size, sha256)| {
                    let piece = Piece { offset, size: *size, sha256: hex(sha256) };
                    offset = offset.saturating_add(*size);
                    piece
                })
                .collect()
        });
        Ok(Hashed { sha256: hex(&sha256), bytes, pieces })
    }

    /// Writes the new cache: every entry this push took and, for a while, the ones it did not
    /// look at.
    pub(super) fn finish(mut self) {
        let Some(mut writer) = self.writer.take() else { return };
        if let Some(reader) = self.reader.as_mut() {
            while let Some(entry) = reader.advance() {
                Self::carry(Some(&mut writer), entry);
            }
        }
        writer.finish();
    }
}

/// Whether `pieces` cut a file of `size` bytes whole.
fn covers(pieces: &[(u64, [u8; 32])], size: u64) -> bool {
    !pieces.is_empty()
        && pieces.iter().try_fold(0u64, |sum, (piece, _)| sum.checked_add(*piece)) == Some(size)
}

/// Reads `file` once: its SHA-256, its length as read and, when `cut`, the store's chunks of
/// it (in the same read).
fn read(file: &LocalFile, cut: bool) -> anyhow::Result<([u8; 32], u64, Vec<(u64, [u8; 32])>)> {
    struct Tee<'a> {
        inner: &'a mut dyn Read,
        hasher: Sha256,
        read: u64,
    }
    impl Read for Tee<'_> {
        fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
            let count = self.inner.read(buffer)?;
            let got = buffer.get(..count).ok_or_else(|| std::io::Error::other("short buffer"))?;
            self.hasher.update(got);
            self.read = self.read.saturating_add(count as u64);
            Ok(count)
        }
    }
    let mut source = super::open(file)?;
    let mut tee = Tee { inner: &mut source, hasher: Sha256::new(), read: 0 };
    let pieces = if cut {
        let mut pieces = Vec::new();
        for piece in store::chunks(&mut tee)? {
            let sha256 = unhex(&piece.sha256).ok_or_else(|| anyhow::anyhow!("bad chunk hash"))?;
            pieces.push((piece.size, sha256));
        }
        pieces
    } else {
        let mut buffer = vec![0u8; 1 << 20];
        while tee.read(&mut buffer)? != 0 {}
        Vec::new()
    };
    Ok((tee.hasher.finalize().into(), tee.read, pieces))
}

#[cfg(test)]
mod tests {
    use std::path::{Path, PathBuf};

    use sha2::{Digest as _, Sha256};

    use super::super::local::{LocalFile, Rules, Source, collect};
    use super::super::store;
    use super::{Entry, KEEP_UNSEEN, Pass, Reader, Stat, Writer, hex, now};

    const SECOND: i128 = 1_000_000_000;

    struct Folder {
        _dir: tempfile::TempDir,
        top: PathBuf,
        cache: PathBuf,
    }

    fn folder(files: &[(&str, &[u8])]) -> Folder {
        let dir = tempfile::tempdir().unwrap();
        let top = std::fs::canonicalize(dir.path()).unwrap().join("work");
        for (name, bytes) in files {
            let path = top.join(name);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, bytes).unwrap();
        }
        std::fs::create_dir_all(&top).unwrap();
        let cache = top.parent().unwrap().join("state/link-sync/folder.stat");
        Folder { _dir: dir, top, cache }
    }

    /// One push's hashing of every listed file, with the listing begun at `since`: (path, sha).
    fn pass(folder: &Folder, since: i128, store: bool) -> (Pass, Vec<(String, String)>) {
        let set = collect(&folder.top, Rules::Share, None).unwrap();
        let mut pass = Pass::at(Some(&folder.cache), &folder.top, since);
        let mut hashes = Vec::new();
        for (relative, file) in &set.files {
            let hashed = pass.hash(relative, file, store).unwrap();
            assert_eq!(hashed.bytes, std::fs::metadata(folder.top.join(relative)).unwrap().len());
            hashes.push((relative.clone(), hashed.sha256));
        }
        (pass, hashes)
    }

    fn sha256(bytes: &[u8]) -> String {
        hex(&Sha256::digest(bytes))
    }

    /// Well after now: every file just written is settled for it.
    fn later() -> i128 {
        now() + 10 * SECOND
    }

    #[test]
    fn an_unchanged_file_is_answered_without_a_read_and_an_edit_of_the_same_size_is_seen() {
        let folder = folder(&[("a.txt", b"one\n"), ("src/b.rs", b"fn b() {}\n"), ("c", b"")]);
        let (first, hashes) = pass(&folder, later(), false);
        assert_eq!((first.hashed, first.cached), (3, 0));
        first.finish();
        let (second, again) = pass(&folder, later(), false);
        assert_eq!((second.hashed, second.hashed_bytes, second.cached), (0, 0, 3));
        assert_eq!(again, hashes);
        second.finish();
        // Same size, other bytes, a later tick: its ctime moved.
        std::thread::sleep(std::time::Duration::from_millis(20));
        std::fs::write(folder.top.join("a.txt"), b"two\n").unwrap();
        let (third, edited) = pass(&folder, later(), false);
        assert_eq!((third.hashed, third.cached), (1, 2));
        assert!(edited.contains(&("a.txt".to_string(), sha256(b"two\n"))));
    }

    /// The racy rule: a stat taken in the same tick as the file's last write is never kept, so
    /// a write later in that tick (which leaves the stat as it was) is still seen. Shown with a
    /// file whose listed stat is held as it was while its bytes change, as such a write leaves it.
    #[test]
    fn a_file_written_in_the_tick_its_stat_was_taken_is_hashed_again() {
        let folder = folder(&[("a.txt", b"one\n")]);
        let path = folder.top.join("a.txt");
        let stat = Stat::of(&std::fs::metadata(&path).unwrap());
        let file = || LocalFile {
            source: Source::File(path.clone()),
            permissions: 0o644,
            id: Some((stat.dev, stat.ino)),
            stat: Some(stat),
        };
        // Listed 1 ms after the write: inside the tick, not kept.
        let racy = stat.newest() + 1_000_000;
        let mut first = Pass::at(Some(&folder.cache), &folder.top, racy);
        assert_eq!(first.hash("a.txt", &file(), false).unwrap().sha256, sha256(b"one\n"));
        first.finish();
        rewrite_in_place(&path, b"two\n");
        let mut second = Pass::at(Some(&folder.cache), &folder.top, later());
        assert_eq!(second.hash("a.txt", &file(), false).unwrap().sha256, sha256(b"two\n"));
        assert_eq!((second.hashed, second.cached), (1, 0));
        // The same steps with the stat taken long after the write: kept, and trusted while the
        // stat holds (the guarantee is that a real later write moves the stat).
        second.finish();
        let mut third = Pass::at(Some(&folder.cache), &folder.top, later());
        assert_eq!(third.hash("a.txt", &file(), false).unwrap().sha256, sha256(b"two\n"));
        assert_eq!(third.cached, 1);
    }

    fn rewrite_in_place(path: &Path, bytes: &[u8]) {
        use std::io::Write as _;
        let mut file = std::fs::OpenOptions::new().write(true).truncate(true).open(path).unwrap();
        file.write_all(bytes).unwrap();
    }

    #[test]
    fn the_tick_is_wider_for_timestamps_of_whole_milliseconds() {
        let at = |seconds: i64, nanos: u32| Stat {
            dev: 1,
            ino: 2,
            mode: 0o100_644,
            size: 3,
            mtime: (seconds, nanos),
            ctime: (seconds, nanos),
        };
        let fine = at(100, 123_456_789);
        assert!(!fine.settled(fine.newest() + 49_000_000));
        assert!(fine.settled(fine.newest() + 51_000_000));
        let coarse = at(100, 0);
        assert!(!coarse.settled(coarse.newest() + SECOND));
        assert!(coarse.settled(coarse.newest() + 3 * SECOND));
        // The newer of mtime and ctime counts (an old mtime set back by a tool, a new ctime).
        let mut set_back = fine;
        set_back.mtime = (1, 5);
        assert!(!set_back.settled(fine.newest() + 1_000_000));
    }

    #[test]
    fn a_touch_hashes_once_then_is_cached_again() {
        let folder = folder(&[("a.txt", b"one\n")]);
        pass(&folder, later(), false).0.finish();
        std::thread::sleep(std::time::Duration::from_millis(20));
        let file = std::fs::File::options().write(true).open(folder.top.join("a.txt")).unwrap();
        file.set_modified(std::time::SystemTime::now()).unwrap();
        let (touched, _) = pass(&folder, later(), false);
        assert_eq!((touched.hashed, touched.cached), (1, 0));
        touched.finish();
        let (after, _) = pass(&folder, later(), false);
        assert_eq!((after.hashed, after.cached), (0, 1));
    }

    #[test]
    fn a_replaced_file_a_mode_change_and_a_file_deleted_and_made_again_are_hashed() {
        let folder = folder(&[("a", b"aaaa"), ("b", b"bbbb"), ("c", b"cccc")]);
        pass(&folder, later(), false).0.finish();
        let old = std::fs::metadata(folder.top.join("a")).unwrap().modified().unwrap();
        // Another inode at the name, with the same size and mtime.
        let other = folder.top.join(".a.new");
        std::fs::write(&other, b"AAAA").unwrap();
        std::fs::File::options().write(true).open(&other).unwrap().set_modified(old).unwrap();
        std::fs::rename(&other, folder.top.join("a")).unwrap();
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::set_permissions(folder.top.join("b"), std::fs::Permissions::from_mode(0o755))
            .unwrap();
        std::fs::remove_file(folder.top.join("c")).unwrap();
        std::fs::write(folder.top.join("c"), b"CCCC").unwrap();
        let (after, hashes) = pass(&folder, later(), false);
        assert_eq!((after.hashed, after.cached), (3, 0));
        let expected: Vec<(String, String)> = [("a", b"AAAA"), ("b", b"bbbb"), ("c", b"CCCC")]
            .iter()
            .map(|(name, bytes)| ((*name).to_string(), sha256(*bytes)))
            .collect();
        assert_eq!(hashes, expected);
    }

    #[test]
    fn a_cache_damaged_cut_short_of_another_folder_or_version_is_ignored() {
        let folder = folder(&[("a", b"aaaa"), ("b", b"bbbb")]);
        pass(&folder, later(), false).0.finish();
        let good = std::fs::read(&folder.cache).unwrap();
        assert!(Reader::open(&folder.cache, &folder.top).is_some());
        let mut flipped = good.clone();
        let middle = flipped.len() / 2;
        flipped[middle] ^= 0x40;
        // Another version, its checksum made right: refused by its header alone.
        let mut other_version = good[..good.len() - 32].to_vec();
        other_version[8] ^= 1;
        let trailer = Sha256::digest(&other_version);
        other_version.extend_from_slice(&trailer);
        for bad in [flipped, good[..good.len() - 1].to_vec(), Vec::new(), b"garbage".to_vec()] {
            std::fs::write(&folder.cache, &bad).unwrap();
            assert!(Reader::open(&folder.cache, &folder.top).is_none());
            let (fallback, _) = pass(&folder, later(), false);
            assert_eq!((fallback.hashed, fallback.cached), (2, 0));
        }
        std::fs::write(&folder.cache, &other_version).unwrap();
        assert!(Reader::open(&folder.cache, &folder.top).is_none());
        std::fs::write(&folder.cache, &good).unwrap();
        assert!(Reader::open(&folder.cache, &folder.top.join("elsewhere")).is_none());
        assert!(Reader::open(&folder.cache, &folder.top).is_some());
    }

    #[test]
    fn a_push_of_part_of_the_folder_keeps_the_rest_for_a_while() {
        let folder = folder(&[("a", b"aaaa"), ("b", b"bbbb"), ("c", b"cccc")]);
        pass(&folder, later(), false).0.finish();
        let set = collect(&folder.top, Rules::Share, None).unwrap();
        let only_b = |folder: &Folder| {
            let mut part = Pass::at(Some(&folder.cache), &folder.top, later());
            part.hash("b", set.files.get("b").unwrap(), false).unwrap();
            part.finish();
        };
        only_b(&folder);
        let (whole, _) = pass(&folder, later(), false);
        assert_eq!((whole.hashed, whole.cached), (0, 3));
        whole.finish();
        for _ in 0..=KEEP_UNSEEN {
            only_b(&folder);
        }
        let (gone, _) = pass(&folder, later(), false);
        assert_eq!((gone.hashed, gone.cached), (2, 1));
    }

    #[test]
    fn lookups_out_of_path_order_never_answer_another_files_hash() {
        let folder = folder(&[("a", b"aaaa"), ("b", b"bbbb"), ("c", b"cccc")]);
        pass(&folder, later(), false).0.finish();
        let set = collect(&folder.top, Rules::Share, None).unwrap();
        let mut backwards = Pass::at(Some(&folder.cache), &folder.top, later());
        for name in ["c", "b", "a"] {
            let hashed = backwards.hash(name, set.files.get(name).unwrap(), false).unwrap();
            let bytes = std::fs::read(folder.top.join(name)).unwrap();
            assert_eq!(hashed.sha256, sha256(&bytes));
        }
    }

    #[test]
    fn paths_sharing_prefixes_round_trip() {
        let folder = folder(&[]);
        let names = ["", "a", "a/b", "a/b/c", "a/bc", "b", "\u{e9}t\u{e9}/x", "zz"];
        let stat = Stat { dev: 1, ino: 2, mode: 3, size: 4, mtime: (5, 6), ctime: (7, 8) };
        let mut writer = Writer::create(&folder.cache, &folder.top).unwrap();
        let entries: Vec<Entry> = names
            .iter()
            .enumerate()
            .map(|(at, name)| Entry {
                path: name.as_bytes().to_vec(),
                stat: Stat { ino: at as u64, ..stat },
                sha256: [u8::try_from(at).unwrap(); 32],
                unseen: 0,
                pieces: vec![(1, [9; 32]); at],
            })
            .collect();
        for entry in &entries {
            writer.add(entry);
        }
        writer.finish();
        let mut reader = Reader::open(&folder.cache, &folder.top).unwrap();
        let mut read = Vec::new();
        while let Some(entry) = reader.advance() {
            read.push(entry);
        }
        assert_eq!(read, entries);
    }

    /// A large file through the store is cut in the read that hashes it, and its chunks come
    /// back from the cache next time without a read.
    #[test]
    fn a_large_files_chunks_are_cut_once_and_kept() {
        let mut bytes = Vec::with_capacity(9 << 20);
        let mut state = 0x2545_f491_4f6c_dd1du64;
        while bytes.len() < 9 << 20 {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            bytes.extend_from_slice(&state.to_le_bytes());
        }
        let folder = folder(&[("big.bin", &bytes)]);
        let set = collect(&folder.top, Rules::Share, None).unwrap();
        let file = set.files.get("big.bin").unwrap();
        let expected = store::chunks(&mut bytes.as_slice()).unwrap();
        let mut first = Pass::at(Some(&folder.cache), &folder.top, later());
        let cut = first.hash("big.bin", file, true).unwrap();
        assert_eq!((cut.sha256, cut.pieces.as_ref()), (sha256(&bytes), Some(&expected)));
        first.finish();
        let mut second = Pass::at(Some(&folder.cache), &folder.top, later());
        let kept = second.hash("big.bin", file, true).unwrap();
        assert_eq!((second.hashed, second.cached), (0, 1));
        assert_eq!(kept.pieces, Some(expected));
        // Without the store nothing is cut, and the kept chunks stay for the next store push.
        second.finish();
        let mut third = Pass::at(Some(&folder.cache), &folder.top, later());
        assert_eq!(third.hash("big.bin", file, false).unwrap().sha256, sha256(&bytes));
        third.finish();
        let mut fourth = Pass::at(Some(&folder.cache), &folder.top, later());
        assert!(fourth.hash("big.bin", file, true).unwrap().pieces.is_some());
        assert_eq!(fourth.hashed, 0);
    }

    #[test]
    fn off_reads_and_writes_nothing() {
        let folder = folder(&[("a", b"aaaa")]);
        let set = collect(&folder.top, Rules::Share, None).unwrap();
        for _ in 0..2 {
            let mut off = Pass::at(None, &folder.top, later());
            off.hash("a", set.files.get("a").unwrap(), false).unwrap();
            assert_eq!((off.hashed, off.cached), (1, 0));
            off.finish();
        }
        assert!(!folder.cache.exists());
    }
}
