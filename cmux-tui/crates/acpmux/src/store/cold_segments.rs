//! Cold segments: a chat's sealed log segments compressed off the hot path, losslessly, and read
//! back in place (`hub/cold_segments.rs` moves them; `agents.chats.coldSegments`, off by default).
//!
//! An open chat's log only grows: 152 MB at 100k rows, every byte of it local. A segment no longer
//! written (every one but the newest, never `000000`, a fork's history) is cut into chunks of
//! about [`CHUNK_RAW`] raw bytes at line ends, each its own zstd frame with its checksum, in
//! `<session>/cold-segments/NNNNNN.zst`. Its index, `events/NNNNNN.cold.idx` (each chunk's raw and
//! compressed offset and length and first seq; the raw length and SHA-256), stays beside the hot
//! segments. A 400-record page decodes one or two chunks, never the whole 8 MiB segment. Nothing
//! is dropped: the archive holds every byte the segment held, checked before the segment goes.
//!
//! Leo: "dont delete automatically but maybe we can add an option for people to opt in release
//! old chats if theyre really idle and old or store them". Compressing a sealed segment keeps
//! every byte; nothing here deletes history.
//!
//! Order, so a crash anywhere leaves a whole log ([`LocalStore::stage_cold_segments`],
//! [`LocalStore::commit_cold_segments`]):
//! 1. the archive is written under a temporary name, every chunk decoded back from the disk and
//!    checked against the segment's SHA-256, and synced (no lock held);
//! 2. it is renamed to `NNNNNN.zst` and its folder synced: an archive with no index is never read;
//! 3. the index is written under a temporary name and synced;
//! 4. under the writers' lock, and only when the segment is unchanged (same file, same length,
//!    still sealed, no cut pending, the chat not archived whole): the index is renamed into place
//!    and `events/` synced (the commit point), then the `.ndjson` removed; `events/` is synced
//!    again after the lock.
//!
//! Listing (`LocalStore::listed_files`) takes a segment from its `.ndjson` while there is one and
//! from its archive once only the index is left, so a corrupt archive whose segment is still there
//! is never read. A reader that listed the `.ndjson` before the move removed it opens the archive
//! instead ([`open_segment`]). A damaged archive is a clear error on read, never a silent gap.
//!
//! Every start (and every pass of the worker), [`LocalStore::settle_cold_segments`] finishes what a
//! crash left: a `.ndjson` beside a committed archive is removed once both read to the index's
//! SHA-256 (else the archive is set aside and the segment stays the log); an archive with no index
//! is removed only when its `.ndjson` is still there (else it is kept aside, never removed); a
//! temporary file goes.
//!
//! Readers that open a segment by path go through [`open_segment`]: forward scans, `scan_back`,
//! the kind and text copies (none for a cold segment), the v2 raw reader (`log_bytes.rs`),
//! `tail_after`, and the journal's repair reads. What writes a segment in place refuses a cold one
//! by design: retention leaves it as it is and a cut that reaches into it fails
//! (`store/compact.rs`); the journal's repair skips its write-back (its bytes are the archive's,
//! synced at the commit) and refuses a cut (`journal_store/repair.rs`). The whole-chat archive
//! (`store/cold.rs`) takes a cold segment's raw bytes into `cold.zst` like any other.

use super::*;
use sha2::{Digest, Sha256};
use std::io::{Seek, SeekFrom};

/// The folder beside `events/` that holds the archives.
pub(crate) const COLD_DIR: &str = "cold-segments";
/// An index's name after its segment's index (`NNNNNN.cold.idx`, in `events/`).
pub(crate) const IDX_SUFFIX: &str = ".cold.idx";
/// About how many raw bytes one chunk holds: a 400-record page of a coordinator chat is
/// 100-200 KiB.
const CHUNK_RAW: usize = 128 * 1024;
const SCHEMA: &str = "acpmux.cold-seg.v1";
/// zstd's level when the setting names none.
pub const DEFAULT_LEVEL: i32 = 3;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Index {
    schema: String,
    pub(crate) raw_len: u64,
    pub(crate) comp_len: u64,
    pub(crate) sha256: String,
    level: i32,
    compress_ms: u64,
    /// `[raw_off, raw_len, comp_off, comp_len, first_seq]`.
    chunks: Vec<[u64; 5]>,
}

pub(crate) fn idx_path(session: &Path, index: u32) -> PathBuf {
    session.join("events").join(format!("{index:06}{IDX_SUFFIX}"))
}

pub(crate) fn zst_path(session: &Path, index: u32) -> PathBuf {
    session.join(COLD_DIR).join(format!("{index:06}.zst"))
}

fn ndjson_path(session: &Path, index: u32) -> PathBuf {
    session.join("events").join(format!("{index:06}.ndjson"))
}

/// The segment index an index file's name names (`NNNNNN.cold.idx`).
pub(crate) fn idx_index(name: &str) -> Option<u32> {
    let stem = name.strip_suffix(IDX_SUFFIX)?;
    (stem.len() == 6 && stem.bytes().all(|b| b.is_ascii_digit())).then(|| stem.parse().ok())?
}

/// Whether `path` is a cold segment's archive.
pub(crate) fn is_cold(path: &Path) -> bool {
    path.extension().is_some_and(|e| e == "zst")
}

/// The chat folder and segment index of a segment's path (`<session>/events/NNNNNN.ndjson` or
/// `<session>/cold-segments/NNNNNN.zst`).
fn session_and_index(path: &Path) -> Option<(&Path, u32)> {
    let index = path.file_stem()?.to_str()?;
    let index = index.strip_suffix(".ndjson").unwrap_or(index);
    let index: u32 = (index.len() == 6).then(|| index.parse().ok())??;
    Some((path.parent()?.parent()?, index))
}

/// Reads a committed index; an error says which and why.
pub(crate) fn read_index(session: &Path, index: u32) -> Result<Index> {
    let path = idx_path(session, index);
    let text = crate::home_fs::private_state_file(&path)
        .and_then(|mut f| {
            let mut text = Vec::new();
            f.read_to_end(&mut text)?;
            Ok(text)
        })
        .with_context(|| format!("read the index of cold segment {}", path.display()))?;
    let doc: Index = serde_json::from_slice(&text)
        .with_context(|| format!("the index of cold segment {} does not read", path.display()))?;
    anyhow::ensure!(
        doc.schema == SCHEMA,
        "cold segment index {} has schema {:?}",
        path.display(),
        doc.schema
    );
    Ok(doc)
}

/// A segment's file, local or cold.
pub(crate) enum SegmentFile {
    Local(File),
    Cold(Box<ColdFile>),
}

impl SegmentFile {
    /// The local file, for the readers that key a copy on its inode (`Stamp::of`).
    pub(crate) fn local(&self) -> Option<&File> {
        match self {
            Self::Local(file) => Some(file),
            Self::Cold(_) => None,
        }
    }

    /// The segment's length in raw bytes.
    pub(crate) fn len(&self) -> std::io::Result<u64> {
        match self {
            Self::Local(file) => Ok(file.metadata()?.len()),
            Self::Cold(cold) => Ok(cold.index.raw_len),
        }
    }

    /// The file's metadata: the archive's for a cold segment (its identity, never its length).
    pub(crate) fn metadata(&self) -> std::io::Result<std::fs::Metadata> {
        match self {
            Self::Local(file) => file.metadata(),
            Self::Cold(cold) => cold.file.metadata(),
        }
    }
}

impl Read for SegmentFile {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        match self {
            Self::Local(f) => f.read(buf),
            Self::Cold(f) => f.read(buf),
        }
    }
}

impl Seek for SegmentFile {
    fn seek(&mut self, pos: SeekFrom) -> std::io::Result<u64> {
        match self {
            Self::Local(f) => f.seek(pos),
            Self::Cold(f) => f.seek(pos),
        }
    }
}

/// Opens a path a listing gave: the archive when it is a cold segment's, and the archive too when
/// a `.ndjson` the listing named went cold since (its index is committed: the move removes the
/// segment only after).
pub(crate) fn open_segment(path: &Path) -> Result<SegmentFile> {
    if is_cold(path) {
        return Ok(SegmentFile::Cold(Box::new(ColdFile::open(path)?)));
    }
    match crate::config::private_state_file(path) {
        Ok(file) => Ok(SegmentFile::Local(file)),
        Err(e)
            if e.downcast_ref::<std::io::Error>()
                .is_some_and(|io| io.kind() == std::io::ErrorKind::NotFound) =>
        {
            match session_and_index(path) {
                Some((session, index))
                    if crate::home_fs::try_exists_nofollow(idx_path(session, index))
                        .unwrap_or(false) =>
                {
                    Ok(SegmentFile::Cold(Box::new(ColdFile::open(&zst_path(session, index))?)))
                }
                _ => Err(e),
            }
        }
        Err(e) => Err(e),
    }
}

/// A cold segment's raw bytes, `Read + Seek`, decoding a chunk when a read reaches it.
pub(crate) struct ColdFile {
    file: File,
    path: PathBuf,
    index: Index,
    pos: u64,
    /// The last two chunks decoded, `(chunk, bytes)`: a backwards block read that spans two
    /// chunks decodes each once.
    held: [Option<(usize, Vec<u8>)>; 2],
    next: usize,
}

impl ColdFile {
    fn open(path: &Path) -> Result<Self> {
        let (session, index) = session_and_index(path)
            .ok_or_else(|| anyhow::anyhow!("{} is not a cold segment", path.display()))?;
        let index = read_index(session, index)?;
        let file = crate::config::private_state_file(path)
            .with_context(|| format!("open cold segment {}", path.display()))?;
        Ok(Self { file, path: path.to_owned(), index, pos: 0, held: [None, None], next: 0 })
    }

    /// `log_line::offset_of_seq` from the index: the chunks' first seqs name the one chunk the
    /// offset is in, and only that one is decoded.
    pub(crate) fn offset_of_seq(&mut self, before: u64) -> Result<u64> {
        let chunks = self.index.chunks.clone();
        if chunks.iter().any(|c| c[4] == 0) {
            return log_line::offset_of_seq(self, before);
        }
        // The first chunk that starts at or past `before`: the offset is in the one before it.
        let next = chunks.partition_point(|c| c[4] < before);
        let Some(i) = next.checked_sub(1) else { return Ok(0) };
        let start = chunks[i][0];
        let fallback = chunks.get(next).map_or(self.index.raw_len, |c| c[0]);
        let bytes = self.chunk(i)?;
        let mut off = 0usize;
        for line in bytes.split_inclusive(|b| *b == b'\n') {
            if record_seq(line).is_some_and(|seq| seq >= before) {
                return Ok(start + off as u64);
            }
            off += line.len();
        }
        Ok(fallback)
    }

    /// The segment's first seq, from its index: nothing decoded.
    pub(crate) fn first_seq(&self) -> Option<u64> {
        self.index.chunks.first().map(|c| c[4]).filter(|s| *s > 0)
    }

    fn chunk(&mut self, i: usize) -> std::io::Result<&[u8]> {
        let slot = match self.held.iter().position(|h| h.as_ref().is_some_and(|(c, _)| *c == i)) {
            Some(slot) => slot,
            None => {
                let raw = decode_chunk(&mut self.file, &self.index.chunks[i]).map_err(|e| {
                    std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        format!(
                            "cold segment {} is damaged at chunk {i}: {e}",
                            self.path.display()
                        ),
                    )
                })?;
                let slot = self.next;
                self.next = (self.next + 1) % 2;
                self.held[slot] = Some((i, raw));
                slot
            }
        };
        Ok(self.held[slot].as_ref().map(|(_, b)| b.as_slice()).unwrap_or_default())
    }
}

/// One chunk's raw bytes, its frame's checksum and length checked.
fn decode_chunk(file: &mut File, chunk: &[u64; 5]) -> std::io::Result<Vec<u8>> {
    let [_, raw_len, comp_off, comp_len, _] = *chunk;
    let mut comp = vec![0u8; usize::try_from(comp_len).unwrap_or(usize::MAX)];
    file.seek(SeekFrom::Start(comp_off))?;
    file.read_exact(&mut comp)?;
    let raw = zstd::stream::decode_all(comp.as_slice())?;
    if raw.len() as u64 != raw_len {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("{} bytes where the index says {raw_len}", raw.len()),
        ));
    }
    Ok(raw)
}

impl Read for ColdFile {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if self.pos >= self.index.raw_len || buf.is_empty() {
            return Ok(0);
        }
        let pos = self.pos;
        let i = self.index.chunks.partition_point(|c| c[0] <= pos).saturating_sub(1);
        let start = self.index.chunks[i][0];
        let bytes = self.chunk(i)?;
        let from = usize::try_from(pos - start).unwrap_or(usize::MAX);
        let n = buf.len().min(bytes.len().saturating_sub(from));
        buf[..n].copy_from_slice(&bytes[from..from + n]);
        self.pos += n as u64;
        Ok(n)
    }
}

impl Seek for ColdFile {
    fn seek(&mut self, pos: SeekFrom) -> std::io::Result<u64> {
        let to = match pos {
            SeekFrom::Start(n) => i128::from(n),
            SeekFrom::End(d) => i128::from(self.index.raw_len) + i128::from(d),
            SeekFrom::Current(d) => i128::from(self.pos) + i128::from(d),
        };
        if to < 0 {
            return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "seek before 0"));
        }
        self.pos = u64::try_from(to).unwrap_or(u64::MAX);
        Ok(self.pos)
    }
}

/// Whether the archive at `zst` decodes to `index`'s bytes (its SHA-256 and length).
fn archive_holds(zst: &Path, index: &Index) -> Result<()> {
    let mut file = crate::config::private_state_file(zst)?;
    let mut hash = Sha256::new();
    let mut raw = 0u64;
    for (i, chunk) in index.chunks.iter().enumerate() {
        anyhow::ensure!(chunk[0] == raw, "chunk {i} starts at {} where {raw} was due", chunk[0]);
        let bytes = decode_chunk(&mut file, chunk).with_context(|| format!("chunk {i}"))?;
        raw += bytes.len() as u64;
        hash.update(&bytes);
    }
    anyhow::ensure!(raw == index.raw_len, "{raw} bytes where the index says {}", index.raw_len);
    anyhow::ensure!(hex(&hash.finalize()) == index.sha256, "its bytes are not the segment's");
    Ok(())
}

/// The SHA-256 and length of the file at `path`.
fn file_hash(path: &Path) -> Result<(String, u64)> {
    let mut file = crate::config::private_state_file(path)?;
    let mut hash = Sha256::new();
    let mut buf = vec![0u8; 256 * 1024];
    let mut len = 0u64;
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            return Ok((hex(&hash.finalize()), len));
        }
        hash.update(&buf[..n]);
        len += n as u64;
    }
}

/// The file a segment is: its device and inode (its length alone elsewhere).
fn file_of(meta: &std::fs::Metadata) -> (u64, u64) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        (meta.dev(), meta.ino())
    }
    #[cfg(not(unix))]
    {
        let _ = meta;
        (0, 0)
    }
}

fn hex(digest: &[u8]) -> String {
    digest.iter().map(|b| format!("{b:02x}")).collect()
}

fn is_not_found(e: &std::io::Error) -> bool {
    e.kind() == std::io::ErrorKind::NotFound
}

/// A unique temporary name beside `path`, of this process.
fn tmp_of(path: &Path) -> PathBuf {
    static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let name = path.file_name().unwrap_or_default().to_string_lossy();
    path.with_file_name(format!("{name}.tmp-{}-{n}", std::process::id()))
}

/// Tests: the steps of a move a crash can stop after ([`crash_after`]).
#[cfg(test)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Step {
    /// The temporary archive is written, not yet checked or synced.
    Written,
    /// The archive is checked, synced and renamed into place; no index.
    Renamed,
    /// The index is written under its temporary name.
    IndexStaged,
    /// The index is in place and synced (committed); the `.ndjson` is still there.
    Committed,
    /// The `.ndjson` is removed; `events/` not synced since.
    Removed,
}

#[cfg(test)]
thread_local! {
    /// Tests: a move on this thread "crashes" after this step: it stops there and leaves every
    /// file as it is, temporary ones too.
    pub(crate) static CRASH_AFTER: std::cell::Cell<Option<Step>> = const { std::cell::Cell::new(None) };
    /// Tests: the archive's write on this thread fails as a full disk does after this many bytes.
    pub(crate) static DISK_FULL_AFTER: std::cell::Cell<Option<u64>> = const { std::cell::Cell::new(None) };
    /// Tests: this thread flips a byte of the temporary archive before it is checked.
    pub(crate) static FLIP_BEFORE_CHECK: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// An injected crash ([`Step`]).
#[derive(Debug)]
pub(crate) struct Crash;

impl std::fmt::Display for Crash {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("an injected crash (a test)")
    }
}

impl std::error::Error for Crash {}

#[cfg(test)]
fn crash_after(step: Step) -> bool {
    CRASH_AFTER.with(|c| c.get() == Some(step))
}

/// A writer that fails as a full disk does once [`DISK_FULL_AFTER`] bytes went through it.
struct Out {
    file: File,
    #[cfg(test)]
    left: Option<u64>,
}

impl Write for Out {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        #[cfg(test)]
        if let Some(left) = self.left.as_mut() {
            if *left < buf.len() as u64 {
                let n = usize::try_from(*left).unwrap_or(0);
                if n > 0 {
                    self.file.write_all(&buf[..n])?;
                }
                *left = 0;
                return Err(std::io::Error::new(
                    std::io::ErrorKind::StorageFull,
                    "no space left on device (a test)",
                ));
            }
            *left -= buf.len() as u64;
        }
        self.file.write(buf)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.file.flush()
    }
}

/// One sealed segment's archive, written, checked and synced, not in place yet.
struct StagedSegment {
    index: u32,
    src: PathBuf,
    len: u64,
    file: (u64, u64),
    doc: Index,
    /// The temporary archive (none once renamed into place).
    tmp: Option<PathBuf>,
}

/// Sealed segments' archives staged by [`LocalStore::stage_cold_segments`]. Dropping it removes
/// what is not committed (unless a test crashed it).
pub struct StagedColdSegments {
    session: PathBuf,
    segments: Vec<StagedSegment>,
    /// More sealed segments than were staged wait.
    pub(crate) more: bool,
    /// The chat's newest journal record when the pass staged (`store/journal_store.rs`): every
    /// line of the staged segments is at or before it.
    pub(super) lsn: Option<u64>,
    /// Tests: a crash keeps every file where it was.
    crashed: bool,
}

impl StagedColdSegments {
    /// The segments staged.
    pub fn indexes(&self) -> Vec<u32> {
        self.segments.iter().map(|s| s.index).collect()
    }
}

impl Drop for StagedColdSegments {
    fn drop(&mut self) {
        if self.crashed {
            return;
        }
        for tmp in self.segments.iter().filter_map(|s| s.tmp.as_ref()) {
            let _ = crate::home_fs::remove_file(tmp);
        }
    }
}

/// What a commit put in place.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct ColdMoved {
    pub segments: u64,
    pub raw: u64,
    pub comp: u64,
}

/// Writes segment `src`'s archive under a temporary name in `dir`, decodes it back from the disk
/// and checks it, and syncs it. On an error nothing is left (unless a test crashed it).
fn write_archive(src: &Path, dst: &Path, level: i32) -> Result<(PathBuf, Index, u64, (u64, u64))> {
    let started = std::time::Instant::now();
    let source = crate::config::private_state_file(src)?;
    let meta = source.metadata()?;
    let (len, file) = (meta.len(), file_of(&meta));
    let tmp = tmp_of(dst);
    // Tests only: an injected crash keeps the temporary archive.
    #[cfg_attr(not(test), allow(unused_mut))]
    let mut crashed = false;
    let written = (|| -> Result<Index> {
        let mut reader = BufReader::with_capacity(256 * 1024, (&source).take(len));
        let mut out = Out {
            file: open_private_append(&tmp)?,
            #[cfg(test)]
            left: DISK_FULL_AFTER.with(std::cell::Cell::get),
        };
        let mut hash = Sha256::new();
        let (mut chunks, mut raw_off, mut comp_off) = (Vec::new(), 0u64, 0u64);
        let mut chunk = Vec::with_capacity(CHUNK_RAW + 64 * 1024);
        let mut line = Vec::new();
        let mut first: Option<u64> = None;
        let mut flush =
            |chunk: &mut Vec<u8>, first: &mut Option<u64>, out: &mut Out| -> Result<()> {
                if chunk.is_empty() {
                    return Ok(());
                }
                let mut encoder = zstd::stream::write::Encoder::new(Vec::new(), level)?;
                encoder.include_checksum(true)?;
                encoder.write_all(chunk)?;
                let comp = encoder.finish()?;
                out.write_all(&comp)?;
                chunks.push([
                    raw_off,
                    chunk.len() as u64,
                    comp_off,
                    comp.len() as u64,
                    first.unwrap_or(0),
                ]);
                raw_off += chunk.len() as u64;
                comp_off += comp.len() as u64;
                chunk.clear();
                *first = None;
                Ok(())
            };
        loop {
            line.clear();
            if reader.read_until(b'\n', &mut line)? == 0 {
                break;
            }
            hash.update(&line);
            if first.is_none() {
                first = record_seq(&line);
            }
            chunk.extend_from_slice(&line);
            if chunk.len() >= CHUNK_RAW {
                flush(&mut chunk, &mut first, &mut out)?;
            }
        }
        flush(&mut chunk, &mut first, &mut out)?;
        anyhow::ensure!(raw_off == len, "{} got shorter while it was read", src.display());
        let doc = Index {
            schema: SCHEMA.into(),
            raw_len: raw_off,
            comp_len: comp_off,
            sha256: hex(&hash.finalize()),
            level,
            compress_ms: u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
            chunks,
        };
        out.flush()?;
        drop(out);
        #[cfg(test)]
        if crash_after(Step::Written) {
            crashed = true;
            return Err(Crash.into());
        }
        #[cfg(test)]
        if FLIP_BEFORE_CHECK.with(std::cell::Cell::get) {
            let mut bytes = std::fs::read(&tmp)?;
            let at = bytes.len() / 2;
            bytes[at] ^= 0x5a;
            crate::home_fs::write(&tmp, &bytes)?;
        }
        // Every chunk decoded back from the disk and checked before anything is in place.
        archive_holds(&tmp, &doc)
            .with_context(|| format!("the archive of {} does not read back", src.display()))?;
        let synced = crate::config::private_state_file(&tmp)?;
        synced.sync_all().map_err(SyncFailed)?;
        drop_cache_of(&synced);
        Ok(doc)
    })();
    drop_cache_of(&source);
    match written {
        Ok(doc) => Ok((tmp, doc, len, file)),
        Err(e) => {
            if !crashed {
                let _ = crate::home_fs::remove_file(&tmp);
            }
            Err(e)
        }
    }
}

fn drop_cache_of(file: &File) {
    compact::drop_cache(file);
}

impl LocalStore {
    /// Writes the archives of at most `max` of `id`'s sealed segments that are still hot, oldest
    /// first, beside them (module docs, steps 1-2). None when there is none, the chat is archived
    /// whole, or a cut is pending. Refused once the store is sealed.
    pub(super) fn stage_cold_segments(
        &self,
        id: &str,
        max: usize,
        level: i32,
    ) -> Result<Option<StagedColdSegments>> {
        let _sealed = self.unsealed(id)?;
        if self.is_cold(id) {
            return Ok(None);
        }
        let (segments, cut_pending) = self.listed_files(id)?;
        if cut_pending {
            return Ok(None);
        }
        let newest = segments.last().map_or(0, |(i, _)| *i);
        let mut todo = segments
            .into_iter()
            .filter(|(i, path)| *i > 0 && *i < newest && !is_cold(path))
            .collect::<Vec<_>>();
        if todo.is_empty() {
            return Ok(None);
        }
        let more = todo.len() > max;
        todo.truncate(max);
        let session = self.dir(id);
        crate::config::private_state_dir(&session.join(COLD_DIR))?;
        let mut staged = StagedColdSegments {
            session: session.clone(),
            segments: Vec::new(),
            more,
            lsn: None,
            crashed: false,
        };
        for (index, src) in todo {
            let dst = zst_path(&session, index);
            let (tmp, doc, len, file) = match write_archive(&src, &dst, level) {
                Ok(written) => written,
                Err(e) => {
                    staged.crashed = e.is::<Crash>();
                    return Err(e);
                }
            };
            staged.segments.push(StagedSegment { index, src, len, file, doc, tmp: Some(tmp) });
        }
        Ok(Some(staged))
    }

    /// Puts staged archives in place (module docs, steps 2-4), each segment its own commit, oldest
    /// first; stops at the first segment that changed, went, or is the newest now. What it moved.
    pub(super) fn commit_cold_segments(
        &self,
        id: &str,
        mut staged: StagedColdSegments,
    ) -> Result<ColdMoved> {
        let mut moved = ColdMoved::default();
        let session = staged.session.clone();
        let events = session.join("events");
        let cold_dir = session.join(COLD_DIR);
        for at in 0..staged.segments.len() {
            let _sealed = self.unsealed(id)?;
            let (index, dst) = {
                let s = &staged.segments[at];
                (s.index, zst_path(&session, s.index))
            };
            // 2: the archive in place, with no index yet: never read, and removed by a settle
            // while its segment is still there.
            if let Some(tmp) = staged.segments[at].tmp.take() {
                if let Err(e) = crate::home_fs::rename(&tmp, &dst) {
                    let _ = crate::home_fs::remove_file(&tmp);
                    return Err(e.into());
                }
                sync_directory(&cold_dir)?;
            }
            #[cfg(test)]
            if crash_after(Step::Renamed) {
                staged.crashed = true;
                return Err(Crash.into());
            }
            // 3: the index, synced under its temporary name.
            let idx = idx_path(&session, index);
            let idx_tmp = tmp_of(&idx);
            let doc = serde_json::to_vec(&staged.segments[at].doc)?;
            let written = (|| -> Result<()> {
                let mut file = open_private_append(&idx_tmp)?;
                file.write_all(&doc)?;
                file.sync_all().map_err(SyncFailed)?;
                Ok(())
            })();
            if let Err(e) = written {
                let _ = crate::home_fs::remove_file(&idx_tmp);
                let _ = crate::home_fs::remove_file(&dst);
                return Err(e);
            }
            #[cfg(test)]
            if crash_after(Step::IndexStaged) {
                staged.crashed = true;
                return Err(Crash.into());
            }
            // 4: under the writers' lock, only for the segment as it was read.
            let (src, len, file) = {
                let s = &staged.segments[at];
                (s.src.clone(), s.len, s.file)
            };
            let committed = {
                let _writers = self.writers.lock_or_recover();
                let (now, cut_pending) = self.listed_files(id)?;
                let newest = now.last().map_or(0, |(i, _)| *i);
                let unchanged = !cut_pending
                    && !crate::home_fs::try_exists_nofollow(self.cold_path(id))?
                    && index < newest
                    && now.iter().any(|(i, p)| *i == index && *p == src)
                    && crate::home_fs::symlink_metadata(&src)
                        .is_ok_and(|m| m.len() == len && file_of(&m) == file);
                if unchanged {
                    crate::home_fs::rename(&idx_tmp, &idx)?;
                    // The commit point: the index is on the disk before the segment goes.
                    sync_directory(&events)?;
                    #[cfg(test)]
                    if crash_after(Step::Committed) {
                        staged.crashed = true;
                        return Err(Crash.into());
                    }
                    crate::home_fs::remove_file(&src)?;
                }
                unchanged
            };
            if !committed {
                let _ = crate::home_fs::remove_file(&idx_tmp);
                let _ = crate::home_fs::remove_file(&dst);
                return Ok(moved);
            }
            #[cfg(test)]
            if crash_after(Step::Removed) {
                staged.crashed = true;
                return Err(Crash.into());
            }
            sync_directory(&events)?;
            let s = &staged.segments[at];
            moved.segments += 1;
            moved.raw += s.doc.raw_len;
            moved.comp += s.doc.comp_len;
            tracing::info!(
                session = %id,
                index,
                raw = s.doc.raw_len,
                comp = s.doc.comp_len,
                ms = s.doc.compress_ms,
                "a sealed log segment went cold"
            );
            keep_for_bench(&session, index, &s.doc);
        }
        Ok(moved)
    }

    /// Finishes what a crash left of a move (module docs). Nothing for a chat with no
    /// `cold-segments/`. Refused once the store is sealed.
    pub(super) fn settle_cold_segments(&self, id: &str) -> Result<()> {
        let session = self.dir(id);
        let cold_dir = session.join(COLD_DIR);
        let entries = match crate::home_fs::read_dir(&cold_dir) {
            Ok(entries) => entries,
            Err(e) if is_not_found(&e) => return Ok(()),
            Err(e) => return Err(e.into()),
        };
        let _sealed = self.unsealed(id)?;
        // A chat archived whole (`store/cold.rs`) holds every segment's bytes in `cold.zst`; what
        // a crash left of its `cold-segments/` is settled once its log is back.
        if self.is_cold(id) {
            return Ok(());
        }
        let events = session.join("events");
        let mut changed = (false, false);
        // Temporary files are a crash's (or a failed move's) leftovers: the one worker that moves
        // segments settles first (`hub/cold_segments.rs`), and a sealed store, whose home the
        // next daemon may own, does neither.
        let stale_tmp = |name: &str| name.contains(".tmp-");
        for entry in crate::home_fs::read_dir(&events).unwrap_or_default() {
            let name = entry.name.to_string_lossy();
            if name.contains(IDX_SUFFIX) && stale_tmp(name.as_ref()) {
                let _ = crate::home_fs::remove_file(events.join(&entry.name));
                changed.0 = true;
            }
        }
        for entry in entries {
            let name = entry.name.to_string_lossy().into_owned();
            let path = cold_dir.join(&entry.name);
            if stale_tmp(name.as_str()) {
                let _ = crate::home_fs::remove_file(&path);
                changed.1 = true;
                continue;
            }
            let Some(index) = name.strip_suffix(".zst").and_then(|s| s.parse::<u32>().ok()) else {
                continue;
            };
            let src = ndjson_path(&session, index);
            let has_src = crate::home_fs::try_exists_nofollow(&src)?;
            let idx = idx_path(&session, index);
            if !crate::home_fs::try_exists_nofollow(&idx)? {
                if has_src {
                    // Never committed: the segment is the log.
                    crate::home_fs::remove_file(&path)?;
                    changed.1 = true;
                } else {
                    // No index and no segment: kept, never read, never removed.
                    let aside = cold_dir.join(format!("{name}.orphan-{}", now_ms()));
                    tracing::warn!(session = %id, "a cold segment with no index and no segment is kept as {}", aside.display());
                    crate::home_fs::rename(&path, &aside)?;
                    changed.1 = true;
                }
                continue;
            }
            if !has_src {
                continue;
            }
            // A crash between the commit and the segment's removal: both must read to the index.
            let archive = read_index(&session, index).and_then(|doc| {
                archive_holds(&path, &doc)?;
                Ok(doc)
            });
            match archive {
                Ok(doc) => {
                    let (sha, len) = file_hash(&src)?;
                    if sha == doc.sha256 && len == doc.raw_len {
                        crate::home_fs::remove_file(&src)?;
                    } else {
                        let aside = events.join(format!("{index:06}.ndjson.orphan-{}", now_ms()));
                        tracing::warn!(session = %id, index, "a segment beside its committed archive reads differently: kept as {}", aside.display());
                        crate::home_fs::rename(&src, &aside)?;
                    }
                    changed.0 = true;
                }
                Err(e) => {
                    // The segment is the log; the damaged archive and its index go aside, and a
                    // later pass moves the segment again.
                    let at = now_ms();
                    tracing::warn!(session = %id, index, "a cold segment does not read back ({e:#}): its segment stays the log");
                    crate::home_fs::rename(
                        &idx,
                        events.join(format!("{index:06}{IDX_SUFFIX}.damaged-{at}")),
                    )?;
                    crate::home_fs::rename(&path, cold_dir.join(format!("{name}.damaged-{at}")))?;
                    changed = (true, true);
                }
            }
        }
        if changed.0 {
            sync_directory(&events)?;
        }
        if changed.1 {
            sync_directory(&cold_dir)?;
        }
        Ok(())
    }

    /// Calls the seal hook (`append_line`, as a segment rolls over).
    pub(super) fn note_sealed(&self, id: &str) {
        if let Some(hook) = self.seal_hook.get() {
            hook(id);
        }
    }
}

/// [`Store::on_segment_sealed`]'s hook.
pub type SealHook = std::sync::Arc<dyn Fn(&str) + Send + Sync>;

/// `ACPMUX_COLD_SEGMENTS_KEEP=<dir>` (`scripts/measure/chat-cold-segments.py`'s equality check
/// only): a raw copy of each segment moved, decoded from its archive, goes there. It only ever
/// keeps more.
fn keep_for_bench(session: &Path, index: u32, doc: &Index) {
    let Some(keep) = std::env::var_os("ACPMUX_COLD_SEGMENTS_KEEP") else { return };
    let kept = (|| -> Result<()> {
        let dir = Path::new(&keep).join(session.file_name().unwrap_or_default());
        crate::home_fs::create_dirs(&dir)?;
        let mut file = crate::config::private_state_file(&zst_path(session, index))?;
        let mut out = crate::home_fs::create_file(dir.join(format!("{index:06}.ndjson")))?;
        for chunk in &doc.chunks {
            out.write_all(&decode_chunk(&mut file, chunk)?)?;
        }
        Ok(())
    })();
    if let Err(e) = kept {
        tracing::warn!("ACPMUX_COLD_SEGMENTS_KEEP: {e:#}");
    }
}

#[cfg(test)]
#[path = "cold_segments_tests.rs"]
mod tests;
