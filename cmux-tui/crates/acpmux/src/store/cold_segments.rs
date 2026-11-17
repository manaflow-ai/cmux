//! Cold segments: a chat's sealed log segments compressed off the hot path, losslessly, and read
//! back in place (`hub/cold_segments.rs` moves them; `agents.chats.coldSegments`, off by default).
//!
//! An open chat's log only grows: 152 MB at 100k rows, every byte of it local. A segment no longer
//! written (every one but the newest, never `000000`, a fork's history) is cut into chunks of
//! about [`CHUNK_RAW`] raw bytes at line ends, each its own zstd frame with its checksum, in
//! `<session>/cold-segments/NNNNNN.zst`. The chat's one index, `events/segments.cold.idx`
//! ([`INDEX_FILE`]), holds every cold segment's entry (each chunk's raw and compressed offset and
//! length and first seq; the raw length and SHA-256) beside the hot segments: one file however
//! many segments went cold, so the hot bytes stay flat (one file per segment took a 4 KiB block
//! each: 744 of 7800 hot bytes per simulated hour at 100k rows, #43562). A 400-record page decodes
//! one or two chunks, never a whole segment. Nothing is dropped: the archive holds every byte the
//! segment held, checked before the segment goes.
//!
//! Leo: "dont delete automatically but maybe we can add an option for people to opt in release
//! old chats if theyre really idle and old or store them". Compressing a sealed segment keeps
//! every byte; nothing here deletes history.
//!
//! Order, so a crash anywhere leaves a whole log ([`LocalStore::stage_cold_segments`],
//! [`LocalStore::commit_cold_segments`]):
//! 1. the archive is written under a temporary name, every chunk decoded back from the disk and
//!    checked against the segment's SHA-256, and synced (no lock held);
//! 2. it is renamed to `NNNNNN.zst` and its folder synced: an archive no index names is never read;
//! 3. the whole new index (every entry it had and the segment's) is written under a temporary name
//!    and synced;
//! 4. under the writers' lock, and only when the segment is unchanged (same file, same length,
//!    still sealed, no cut pending, the chat not archived whole): the index is renamed over the
//!    one file and `events/` synced (the commit point), then the `.ndjson` removed; `events/` is
//!    synced again after the lock. A crash before the rename leaves the old index whole: the
//!    segment is still hot. Every change to the index (a commit, a warm, a settle) holds the chat's
//!    cold lock; when the index changed after step 3 read it, step 4 writes it again from what is
//!    there now.
//!
//! Listing (`LocalStore::listed_files`) takes a segment from its `.ndjson` while there is one and
//! from its archive once the index names it and the `.ndjson` is gone, so a corrupt archive whose
//! segment is still there is never read. A reader that listed the `.ndjson` before the move
//! removed it opens the archive instead ([`open_segment`]). A damaged archive or index is a clear
//! error on read, never a silent gap. The parsed index is kept per file ([`chat_index`], keyed by
//! the file's identity, length and modification time): a listing or an open of a cold segment
//! reads it once per change, not once per segment.
//!
//! A chat written before the one index has one file per segment, `events/NNNNNN.cold.idx`
//! ([`IDX_SUFFIX`]): it reads as it did (the listing and [`read_index`] take both), and its next
//! settle moves every one into the one index (written, synced and renamed in place first, then the
//! old files removed: a crash between leaves both, which read the same).
//!
//! Every start (and every pass of the worker), [`LocalStore::settle_cold_segments`] finishes what a
//! crash left: a `.ndjson` beside a committed archive is removed once both read to the index's
//! SHA-256 (else the archive and its entry are set aside and the segment stays the log); an
//! archive no index names is removed only when its `.ndjson` is still there (else it is kept
//! aside, never removed); a temporary file goes. An index that does not read is set aside and made
//! again from the archives whose segment is gone (every frame decoded with its checksum), only
//! when every one of them decodes; else it stays as it is and the read stays a clear error.
//!
//! Readers that open a segment by path go through [`open_segment`]: forward scans, `scan_back`,
//! the kind and text copies (none for a cold segment), the v2 raw reader (`log_bytes.rs`),
//! `tail_after`, and the journal's repair reads. What writes a segment in place refuses a cold one
//! by design: retention leaves it as it is and a cut that reaches into it fails
//! (`store/compact.rs`); the journal's repair skips its write-back (its bytes are the archive's,
//! synced at the commit) and refuses a cut (`journal_store/repair.rs`). The whole-chat archive
//! (`store/cold.rs`) takes a cold segment's raw bytes into `cold.zst` like any other.
//!
//! With the setting on, the open segment rolls at [`COLD_ROLL_BYTES`] instead of
//! `store.segmentBytes` (`LocalStore::set_cold_roll`): it is the only part of a chat's log that
//! stays plain, so its size is the hot bytes' sawtooth.

use super::*;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::io::{Seek, SeekFrom};

/// The folder beside `events/` that holds the archives.
pub(crate) const COLD_DIR: &str = "cold-segments";
/// The chat's one index of its cold segments, in `events/`.
pub(crate) const INDEX_FILE: &str = "segments.cold.idx";
/// A per-segment index's name after its segment's index (`NNNNNN.cold.idx`, in `events/`), as a
/// build before [`INDEX_FILE`] wrote them; every temporary index file's name holds it too.
pub(crate) const IDX_SUFFIX: &str = ".cold.idx";
/// About how many raw bytes one chunk holds: a 400-record page of a coordinator chat is
/// 100-200 KiB.
const CHUNK_RAW: usize = 128 * 1024;
const SCHEMA: &str = "acpmux.cold-seg.v1";
const INDEX_SCHEMA: &str = "acpmux.cold-segs.v1";
/// zstd's level when the setting names none.
pub const DEFAULT_LEVEL: i32 = 3;
/// The open segment's roll size with cold segments on: the open segment is the only plain part of
/// the log, and its sawtooth read as 7055 of 7800 hot bytes per simulated hour at 8 MiB (100k
/// rows, `scripts/measure/chat-disk-growth.py`); 512 KiB is four chunks, so a page still decodes
/// one or two, and a 300-segment chat lists and reads in milliseconds (the PR's numbers).
pub const COLD_ROLL_BYTES: u64 = 512 * 1024;

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

/// The chat's one index ([`INDEX_FILE`]): each cold segment's [`Index`] by its segment's index.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ChatIndex {
    schema: String,
    pub(crate) segments: BTreeMap<u32, Index>,
}

impl Default for ChatIndex {
    fn default() -> Self {
        Self { schema: INDEX_SCHEMA.into(), segments: BTreeMap::new() }
    }
}

/// The chat's one index's path.
pub(crate) fn index_path(session: &Path) -> PathBuf {
    session.join("events").join(INDEX_FILE)
}

/// A per-segment index's path (a chat written before the one index).
pub(crate) fn idx_path(session: &Path, index: u32) -> PathBuf {
    session.join("events").join(format!("{index:06}{IDX_SUFFIX}"))
}

pub(crate) fn zst_path(session: &Path, index: u32) -> PathBuf {
    session.join(COLD_DIR).join(format!("{index:06}.zst"))
}

fn ndjson_path(session: &Path, index: u32) -> PathBuf {
    session.join("events").join(format!("{index:06}.ndjson"))
}

/// The segment index a per-segment index file's name names (`NNNNNN.cold.idx`).
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

/// What a file is now: its device and inode, length and modification time. A commit renames a new
/// file over the index, so a change is a new inode; the length and time cover an inode reused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct FileStamp {
    file: (u64, u64),
    len: u64,
    modified: Option<std::time::SystemTime>,
}

impl FileStamp {
    fn of(meta: &std::fs::Metadata) -> Self {
        Self { file: file_of(meta), len: meta.len(), modified: meta.modified().ok() }
    }
}

/// The chat indexes read, by path ([`chat_index`]); at most [`LOADED_MAX`], dropped whole past it.
type Loaded = HashMap<PathBuf, (FileStamp, std::sync::Arc<ChatIndex>)>;
static LOADED: std::sync::LazyLock<Mutex<Loaded>> = std::sync::LazyLock::new(Default::default);
const LOADED_MAX: usize = 256;

fn not_found(e: &anyhow::Error) -> bool {
    e.downcast_ref::<std::io::Error>().is_some_and(is_not_found)
}

/// The chat's one index as the disk has it now, and its stamp; None when there is none. An index
/// that does not read is an error that names it. Parsed once per change of the file (`LOADED`).
pub(crate) fn chat_index(session: &Path) -> Result<Option<(FileStamp, std::sync::Arc<ChatIndex>)>> {
    let path = index_path(session);
    let mut file = match crate::home_fs::private_state_file(&path) {
        Ok(file) => file,
        Err(e) if not_found(&e) => return Ok(None),
        Err(e) => {
            return Err(e)
                .with_context(|| format!("read the index of cold segments {}", path.display()));
        }
    };
    let stamp = FileStamp::of(&file.metadata()?);
    if let Some((held, doc)) = LOADED.lock_or_recover().get(&path)
        && *held == stamp
    {
        return Ok(Some((stamp, doc.clone())));
    }
    let mut text = Vec::new();
    file.read_to_end(&mut text)
        .with_context(|| format!("read the index of cold segments {}", path.display()))?;
    let doc: ChatIndex = serde_json::from_slice(&text)
        .with_context(|| format!("the index of cold segments {} does not read", path.display()))?;
    anyhow::ensure!(
        doc.schema == INDEX_SCHEMA && doc.segments.values().all(|d| d.schema == SCHEMA),
        "the index of cold segments {} has schema {:?}",
        path.display(),
        doc.schema
    );
    let doc = std::sync::Arc::new(doc);
    let mut loaded = LOADED.lock_or_recover();
    if loaded.len() >= LOADED_MAX {
        loaded.clear();
    }
    loaded.insert(path, (stamp, doc.clone()));
    Ok(Some((stamp, doc)))
}

/// The one index's stamp now; None when there is none.
fn index_stamp(session: &Path) -> Result<Option<FileStamp>> {
    match crate::home_fs::symlink_metadata(index_path(session)) {
        Ok(meta) => Ok(Some(FileStamp::of(&meta))),
        Err(e) if is_not_found(&e) => Ok(None),
        Err(e) => Err(e.into()),
    }
}

/// Reads a per-segment index file (a chat written before the one index).
fn read_legacy_index(session: &Path, index: u32) -> Result<Index> {
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

/// Segment `index`'s committed index: its entry in the chat's one index, else its own file (a
/// chat written before the one index). An error says which and why.
pub(crate) fn read_index(session: &Path, index: u32) -> Result<Index> {
    if let Some((_, doc)) = chat_index(session)?
        && let Some(entry) = doc.segments.get(&index)
    {
        return Ok(entry.clone());
    }
    read_legacy_index(session, index)
}

/// Whether segment `index` is committed cold: the one index names it or its own file is there.
fn is_committed(session: &Path, index: u32) -> Result<bool> {
    if chat_index(session)?.is_some_and(|(_, doc)| doc.segments.contains_key(&index)) {
        return Ok(true);
    }
    Ok(crate::home_fs::try_exists_nofollow(idx_path(session, index))?)
}

/// The cold segments' indexes for the listing (`LocalStore::listed_files`): the one index's
/// (when the listing saw it) and the per-segment files' it found (`legacy`).
pub(crate) fn cold_indexes(session: &Path, one: bool, mut legacy: Vec<u32>) -> Result<Vec<u32>> {
    if one && let Some((_, doc)) = chat_index(session)? {
        legacy.extend(doc.segments.keys().copied());
        legacy.sort_unstable();
        legacy.dedup();
    }
    Ok(legacy)
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
        return match ColdFile::open(path) {
            Ok(cold) => Ok(SegmentFile::Cold(Box::new(cold))),
            // Warmed since it was listed (`cmux chats warm`): its `.ndjson` is in place before its
            // index and archive go, so it is the segment now.
            Err(e) => match session_and_index(path) {
                Some((session, index))
                    if crate::home_fs::try_exists_nofollow(ndjson_path(session, index))
                        .unwrap_or(false) =>
                {
                    Ok(SegmentFile::Local(crate::config::private_state_file(&ndjson_path(
                        session, index,
                    ))?))
                }
                _ => Err(e),
            },
        };
    }
    match crate::config::private_state_file(path) {
        Ok(file) => Ok(SegmentFile::Local(file)),
        Err(e)
            if e.downcast_ref::<std::io::Error>()
                .is_some_and(|io| io.kind() == std::io::ErrorKind::NotFound) =>
        {
            let Some((session, index)) = session_and_index(path) else { return Err(e) };
            // An index that does not read is its own error, never "no such segment".
            if is_committed(session, index)? {
                Ok(SegmentFile::Cold(Box::new(ColdFile::open(&zst_path(session, index))?)))
            } else {
                Err(e)
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
        let Some(&[start, ..]) = chunks.get(i) else { return Ok(0) };
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
                let damaged = |e: &dyn std::fmt::Display| {
                    std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        format!(
                            "cold segment {} is damaged at chunk {i}: {e}",
                            self.path.display()
                        ),
                    )
                };
                let chunk = *self.index.chunks.get(i).ok_or_else(|| damaged(&"no such chunk"))?;
                let raw = decode_chunk(&mut self.file, &chunk).map_err(|e| damaged(&e))?;
                let slot = self.next;
                self.next = (self.next + 1) % 2;
                if let Some(held) = self.held.get_mut(slot) {
                    *held = Some((i, raw));
                }
                slot
            }
        };
        let held = self.held.get(slot).and_then(Option::as_ref);
        Ok(held.map(|(_, b)| b.as_slice()).unwrap_or_default())
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
        let Some(&[start, ..]) = self.index.chunks.get(i) else { return Ok(0) };
        let bytes = self.chunk(i)?;
        let from = usize::try_from(pos.saturating_sub(start)).unwrap_or(usize::MAX);
        let rest = bytes.get(from..).unwrap_or_default();
        let n = buf.len().min(rest.len());
        let (Some(to), Some(rest)) = (buf.get_mut(..n), rest.get(..n)) else { return Ok(0) };
        to.copy_from_slice(rest);
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

/// Checks that the cold segment whose archive is at `zst` decodes whole to what its index records:
/// every chunk in order, its raw length and its SHA-256. A whole-chat archive (`store/cold.rs`)
/// copies a cold segment through its index's `rawLen` and then drops the segment archive, so an
/// index damaged to a shorter length, still valid JSON, would otherwise archive only a prefix of
/// the history (#43562 review F1 at 8dd36113).
pub(crate) fn verify_cold(zst: &Path) -> Result<()> {
    let (session, index) = session_and_index(zst)
        .with_context(|| format!("{} is not a cold segment's archive", zst.display()))?;
    let doc = read_index(session, index)?;
    archive_holds(zst, &doc)
        .with_context(|| format!("cold segment {} does not decode to its index", zst.display()))
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
        hash.update(buf.get(..n).unwrap_or_default());
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

/// A unique temporary name beside `path`, of the store whose tag is `tag` (`LocalStore::cold_tag`).
fn tmp_of(path: &Path, tag: &str) -> PathBuf {
    static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let name = path.file_name().unwrap_or_default().to_string_lossy();
    path.with_file_name(format!("{name}.tmp-{tag}-{n}"))
}

/// The chat's one index as it is now, to change (an empty one when there is none), and the stamp
/// of the file it was read from.
fn index_now(session: &Path) -> Result<(Option<FileStamp>, ChatIndex)> {
    Ok(match chat_index(session)? {
        Some((stamp, doc)) => (Some(stamp), (*doc).clone()),
        None => (None, ChatIndex::default()),
    })
}

/// Writes `doc` as the chat's one index under a temporary name of the store whose tag is `tag`,
/// synced: what a rename puts in place. On an error nothing is left.
fn stage_index(session: &Path, doc: &ChatIndex, tag: &str) -> Result<PathBuf> {
    let tmp = tmp_of(&index_path(session), tag);
    let written = (|| -> Result<()> {
        let mut file = open_private_append(&tmp)?;
        file.write_all(&serde_json::to_vec(doc)?)?;
        file.sync_all().map_err(SyncFailed)?;
        Ok(())
    })();
    match written {
        Ok(()) => Ok(tmp),
        Err(e) => {
            let _ = crate::home_fs::remove_file(&tmp);
            Err(e)
        }
    }
}

/// Puts `doc` in place as the chat's one index (written, synced, renamed over the file, `events/`
/// synced), or removes the file when `doc` names no segment. The caller holds the chat's cold lock.
fn put_index(session: &Path, doc: &ChatIndex, tag: &str) -> Result<()> {
    let path = index_path(session);
    if doc.segments.is_empty() {
        match crate::home_fs::remove_file(&path) {
            Err(e) if !is_not_found(&e) => return Err(e.into()),
            _ => {}
        }
    } else {
        let tmp = stage_index(session, doc, tag)?;
        if let Err(e) = crate::home_fs::rename(&tmp, &path) {
            let _ = crate::home_fs::remove_file(&tmp);
            return Err(e.into());
        }
    }
    sync_directory(&session.join("events"))
}

/// A cold segment's index made again from its archive alone (its committed index does not read):
/// every frame found, decoded with its checksum, and counted. An error when a frame does not.
fn rebuilt_entry(zst: &Path) -> Result<Index> {
    let mut bytes = Vec::new();
    crate::config::private_state_file(zst)?.read_to_end(&mut bytes)?;
    let mut hash = Sha256::new();
    let (mut chunks, mut raw_off, mut comp_off) = (Vec::new(), 0u64, 0usize);
    while comp_off < bytes.len() {
        let rest = bytes.get(comp_off..).unwrap_or_default();
        let comp_len = zstd::zstd_safe::find_frame_compressed_size(rest).map_err(|code| {
            anyhow::anyhow!(
                "{} has no whole frame at byte {comp_off}: {}",
                zst.display(),
                zstd::zstd_safe::get_error_name(code)
            )
        })?;
        let frame = rest.get(..comp_len).unwrap_or_default();
        let raw = zstd::stream::decode_all(frame)
            .with_context(|| format!("{} is damaged at byte {comp_off}", zst.display()))?;
        anyhow::ensure!(!raw.is_empty(), "{} has an empty frame at byte {comp_off}", zst.display());
        hash.update(&raw);
        let first = raw.split_inclusive(|b| *b == b'\n').next().and_then(record_seq).unwrap_or(0);
        chunks.push([raw_off, raw.len() as u64, comp_off as u64, comp_len as u64, first]);
        raw_off += raw.len() as u64;
        comp_off += comp_len;
    }
    Ok(Index {
        schema: SCHEMA.into(),
        raw_len: raw_off,
        comp_len: comp_off as u64,
        sha256: hex(&hash.finalize()),
        level: 0,
        compress_ms: 0,
        chunks,
    })
}

/// The chat's one index made again from its archives ([`rebuilt_entry`]) when it does not read:
/// an entry for each archive in place (`archived`, its name and segment index) whose segment is
/// gone and that no per-segment file indexes (one whose `.ndjson` is still there was never
/// committed, or the `.ndjson` is the log). An error when any one does not decode: none is
/// guessed at.
fn rebuilt_index(session: &Path, archived: &[(String, u32)]) -> Result<ChatIndex> {
    let mut doc = ChatIndex::default();
    for (_, index) in archived {
        let index = *index;
        if crate::home_fs::try_exists_nofollow(ndjson_path(session, index))?
            || crate::home_fs::try_exists_nofollow(idx_path(session, index))?
        {
            continue;
        }
        let entry = rebuilt_entry(&zst_path(session, index))
            .with_context(|| format!("cold segment {index:06} cannot be indexed again"))?;
        doc.segments.insert(index, entry);
    }
    Ok(doc)
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
    /// A warm: the decoded segment is written under its temporary name, not yet checked.
    WarmWritten,
    /// A warm: the `.ndjson` is in place beside its index and archive.
    WarmPlaced,
    /// A warm: the index is removed (committed); the archive is still there.
    WarmCommitted,
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
    /// Tests: a warm on this thread stops once its `.ndjson` is in place beside its index and
    /// archive, before the index goes.
    pub(crate) static HOLD_WARM_PLACED: super::log_sync::HoldSlot =
        const { std::cell::RefCell::new(None) };
    /// Tests: a settle on this thread stops once it checked a `.ndjson` against its committed
    /// archive, before it removes the `.ndjson`.
    pub(crate) static HOLD_SETTLE_BEFORE_REMOVE: super::log_sync::HoldSlot =
        const { std::cell::RefCell::new(None) };
    /// Tests: a commit on this thread stops with the new index synced under its temporary name,
    /// before it takes the writers' lock.
    pub(crate) static HOLD_COMMIT_INDEX_STAGED: super::log_sync::HoldSlot =
        const { std::cell::RefCell::new(None) };
    /// Tests: a commit on this thread stops under the writers' lock with the new index synced
    /// under its temporary name, before the rename.
    pub(crate) static HOLD_COMMIT_BEFORE_RENAME: super::log_sync::HoldSlot =
        const { std::cell::RefCell::new(None) };
    /// Tests: a commit on this thread stops after the rename (the commit point), before the
    /// `.ndjson` goes.
    pub(crate) static HOLD_COMMIT_BEFORE_REMOVE: super::log_sync::HoldSlot =
        const { std::cell::RefCell::new(None) };
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

/// What a warm brought back ([`LocalStore::warm_cold_segments`]).
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct ColdWarmed {
    /// Segments that are plain `.ndjson` again.
    pub segments: u64,
    /// Their raw bytes, and what their archives took.
    pub raw: u64,
    pub comp: u64,
    /// Segments left cold, each with why: an archive that does not decode to its index, or a
    /// write that failed. Each stays as it was, readable or a clear error, never removed.
    pub left: Vec<(u32, String)>,
    /// The chat is archived whole (`store/cold.rs`): opening it brings its log back first.
    pub archived_whole: bool,
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
fn write_archive(
    src: &Path,
    dst: &Path,
    level: i32,
    tag: &str,
) -> Result<(PathBuf, Index, u64, (u64, u64))> {
    let started = std::time::Instant::now();
    let source = crate::config::private_state_file(src)?;
    let meta = source.metadata()?;
    let (len, file) = (meta.len(), file_of(&meta));
    let tmp = tmp_of(dst, tag);
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

/// Decodes cold segment `index` of `session` into a temporary file beside its index, checks it
/// against the index's length and SHA-256, and syncs it. On an error nothing is left (unless a
/// test crashed it). The temporary name holds `.cold.idx` and `.tmp-`, so a settle removes it.
fn write_warm(session: &Path, index: u32, tag: &str) -> Result<(PathBuf, Index)> {
    let doc = read_index(session, index)?;
    let zst = zst_path(session, index);
    let tmp = tmp_of(&session.join("events").join(format!("{index:06}{IDX_SUFFIX}.warm")), tag);
    #[cfg_attr(not(test), allow(unused_mut))]
    let mut crashed = false;
    let written = (|| -> Result<()> {
        let mut archive = crate::config::private_state_file(&zst)
            .with_context(|| format!("open cold segment {}", zst.display()))?;
        let mut out = Out {
            file: open_private_append(&tmp)?,
            #[cfg(test)]
            left: DISK_FULL_AFTER.with(std::cell::Cell::get),
        };
        let mut hash = Sha256::new();
        let mut raw = 0u64;
        for (i, chunk) in doc.chunks.iter().enumerate() {
            anyhow::ensure!(
                chunk[0] == raw,
                "chunk {i} starts at {} where {raw} was due",
                chunk[0]
            );
            let bytes = decode_chunk(&mut archive, chunk).with_context(|| {
                format!("cold segment {} is damaged at chunk {i}", zst.display())
            })?;
            hash.update(&bytes);
            raw += bytes.len() as u64;
            out.write_all(&bytes)?;
        }
        out.flush()?;
        drop(out);
        drop_cache_of(&archive);
        #[cfg(test)]
        if crash_after(Step::WarmWritten) {
            crashed = true;
            return Err(Crash.into());
        }
        anyhow::ensure!(
            raw == doc.raw_len && hex(&hash.finalize()) == doc.sha256,
            "cold segment {} does not decode to its segment's bytes",
            zst.display()
        );
        let synced = crate::config::private_state_file(&tmp)?;
        anyhow::ensure!(synced.metadata()?.len() == raw, "{} was cut short", tmp.display());
        synced.sync_all().map_err(SyncFailed)?;
        drop_cache_of(&synced);
        Ok(())
    })();
    match written {
        Ok(()) => Ok((tmp, doc)),
        Err(e) => {
            if !crashed {
                let _ = crate::home_fs::remove_file(&tmp);
            }
            Err(e)
        }
    }
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
            let (tmp, doc, len, file) = match write_archive(&src, &dst, level, &self.cold_tag) {
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
        // `cold-segments/` may be new (`stage_cold_segments` makes it): its entry in the chat's
        // folder is on the disk before any segment goes, or a power loss could keep the removal
        // and lose the folder its archive is in (#43562 review F2, P3-F1). Whether or not the
        // journal's checkpoint synced anything (`prepare_cold_segments` does nothing for history
        // it already covers).
        if !staged.segments.is_empty() {
            sync_directory(&session)?;
        }
        for at in 0..staged.segments.len() {
            let _sealed = self.unsealed(id)?;
            let Some(s) = staged.segments.get_mut(at) else { break };
            let (index, src, len, file) = (s.index, s.src.clone(), s.len, s.file);
            let (raw_len, comp_len, ms) = (s.doc.raw_len, s.doc.comp_len, s.doc.compress_ms);
            let entry = s.doc.clone();
            let tmp = s.tmp.take();
            let dst = zst_path(&session, index);
            // 2: the archive in place, no index naming it yet: never read, and removed by a
            // settle while its segment is still there.
            if let Some(tmp) = tmp {
                if let Err(e) = crate::home_fs::rename(&tmp, &dst) {
                    let _ = crate::home_fs::remove_file(&tmp);
                    return Err(e.into());
                }
                sync_directory(&cold_dir)?;
            }
            let archive = crate::home_fs::symlink_metadata(&dst).ok().map(|m| file_of(&m));
            #[cfg(test)]
            if crash_after(Step::Renamed) {
                staged.crashed = true;
                return Err(Crash.into());
            }
            // 3: the whole new index (every entry it has and this segment's), synced under its
            // temporary name.
            let written = index_now(&session).and_then(|(stamp, mut now)| {
                now.segments.insert(index, entry.clone());
                Ok((stamp, stage_index(&session, &now, &self.cold_tag)?))
            });
            let (read, mut idx_tmp) = match written {
                Ok(written) => written,
                Err(e) => {
                    let _ = crate::home_fs::remove_file(&dst);
                    return Err(e);
                }
            };
            #[cfg(test)]
            if crash_after(Step::IndexStaged) {
                staged.crashed = true;
                return Err(Crash.into());
            }
            #[cfg(test)]
            super::log_sync::hold(&HOLD_COMMIT_INDEX_STAGED);
            // 4: under the writers' lock and the chat's cold lock, only for the segment as it
            // was read, and its archive still the one step 2 put in place (a settle meanwhile
            // takes an archive no index names beside its segment for a crash's and removes it).
            let committed = (|| -> Result<bool> {
                let _writers = self.writers.lock_or_recover();
                let _cold = self.cold.lock(id);
                let (now, cut_pending) = self.listed_files(id)?;
                let newest = now.last().map_or(0, |(i, _)| *i);
                let unchanged = !cut_pending
                    && !crate::home_fs::try_exists_nofollow(self.cold_path(id))?
                    && index < newest
                    && now.iter().any(|(i, p)| *i == index && *p == src)
                    && crate::home_fs::symlink_metadata(&src)
                        .is_ok_and(|m| m.len() == len && file_of(&m) == file)
                    && crate::home_fs::symlink_metadata(&dst)
                        .is_ok_and(|m| Some(file_of(&m)) == archive);
                if !unchanged {
                    return Ok(false);
                }
                // The index changed since step 3 read it (a warm or a settle of this chat): it is
                // written again from what is there now, every other entry kept.
                if index_stamp(&session)? != read {
                    let _ = crate::home_fs::remove_file(&idx_tmp);
                    let (_, mut now) = index_now(&session)?;
                    now.segments.insert(index, entry.clone());
                    idx_tmp = stage_index(&session, &now, &self.cold_tag)?;
                }
                #[cfg(test)]
                super::log_sync::hold(&HOLD_COMMIT_BEFORE_RENAME);
                crate::home_fs::rename(&idx_tmp, index_path(&session))?;
                // The commit point: the index is on the disk before the segment goes.
                sync_directory(&events)?;
                #[cfg(test)]
                if crash_after(Step::Committed) {
                    staged.crashed = true;
                    return Err(Crash.into());
                }
                #[cfg(test)]
                super::log_sync::hold(&HOLD_COMMIT_BEFORE_REMOVE);
                crate::home_fs::remove_file(&src)?;
                Ok(true)
            })();
            let committed = match committed {
                Ok(committed) => committed,
                Err(e) => {
                    if !staged.crashed {
                        let _ = crate::home_fs::remove_file(&idx_tmp);
                    }
                    return Err(e);
                }
            };
            if !committed {
                let _ = crate::home_fs::remove_file(&idx_tmp);
                // Only the archive step 2 put there: never one a later move put in its place.
                if crate::home_fs::symlink_metadata(&dst)
                    .is_ok_and(|m| Some(file_of(&m)) == archive)
                {
                    let _ = crate::home_fs::remove_file(&dst);
                }
                return Ok(moved);
            }
            #[cfg(test)]
            if crash_after(Step::Removed) {
                staged.crashed = true;
                return Err(Crash.into());
            }
            sync_directory(&events)?;
            moved.segments += 1;
            moved.raw += raw_len;
            moved.comp += comp_len;
            tracing::info!(
                session = %id,
                index,
                raw = raw_len,
                comp = comp_len,
                ms,
                "a sealed log segment went cold"
            );
            if let Some(s) = staged.segments.get(at) {
                keep_for_bench(&session, index, &s.doc);
            }
        }
        Ok(moved)
    }

    /// Finishes what a crash left of a move (module docs), moves a chat's per-segment index files
    /// into its one index, and makes an index that does not read again from the archives. Nothing
    /// for a chat with no `cold-segments/`. Refused once the store is sealed.
    pub(super) fn settle_cold_segments(&self, id: &str) -> Result<()> {
        let session = self.dir(id);
        let cold_dir = session.join(COLD_DIR);
        if !crate::home_fs::try_exists_nofollow(&cold_dir)? {
            return Ok(());
        }
        let _sealed = self.unsealed(id)?;
        // From the listing through every removal: a warm, a move's commit, a whole-chat archive
        // or a rehydrate of this chat changes nothing it decides by meanwhile (#43562 review F1,
        // P2-F1, P3-F2). Every change to the chat's one index holds it too.
        let _cold = self.cold.lock(id);
        let entries = match crate::home_fs::read_dir(&cold_dir) {
            Ok(entries) => entries,
            Err(e) if is_not_found(&e) => return Ok(()),
            Err(e) => return Err(e.into()),
        };
        // A chat archived whole (`store/cold.rs`) holds every segment's bytes in `cold.zst`; what
        // a crash left of its `cold-segments/` is settled once its log is back.
        if self.is_cold(id) {
            return Ok(());
        }
        let events = session.join("events");
        let mut changed = (false, false);
        // Temporary files of another store are a crash's leftovers; this store's own are a move's
        // or a warm's that is under way (`cmux chats warm` runs beside the worker), and stay. A
        // sealed store, whose home the next daemon may own, removes none.
        let own = format!(".tmp-{}-", self.cold_tag);
        let stale_tmp = |name: &str| name.contains(".tmp-") && !name.contains(own.as_str());
        let mut legacy = Vec::new();
        for entry in crate::home_fs::read_dir(&events).unwrap_or_default() {
            let name = entry.name.to_string_lossy();
            if name.contains(IDX_SUFFIX) && stale_tmp(name.as_ref()) {
                let _ = crate::home_fs::remove_file(events.join(&entry.name));
                changed.0 = true;
            } else if let Some(index) = idx_index(name.as_ref()) {
                legacy.push(index);
            }
        }
        let archived: Vec<(String, u32)> = entries
            .iter()
            .filter_map(|entry| {
                let name = entry.name.to_string_lossy().into_owned();
                let index = name.strip_suffix(".zst").and_then(|s| s.parse::<u32>().ok())?;
                Some((name, index))
            })
            .collect();
        let tag = self.cold_tag.clone();
        // The chat's one index; one that does not read is made again from the archives.
        let (mut doc, mut rewrite) = match index_now(&session) {
            Ok((_, doc)) => (doc, false),
            Err(e) => {
                let rebuilt = rebuilt_index(&session, &archived).with_context(|| {
                    format!("{e:#}; it stays as it is, and so does every archive")
                })?;
                // The damaged file is copied aside before the made one goes over it: a crash
                // between leaves it in place, and the next settle does this again.
                let path = index_path(&session);
                let aside = events.join(format!("{INDEX_FILE}.damaged-{}", now_ms()));
                let mut bytes = Vec::new();
                crate::home_fs::private_state_file(&path)?.read_to_end(&mut bytes)?;
                crate::home_fs::write(&aside, &bytes)?;
                tracing::warn!(session = %id, "the index of cold segments does not read ({e:#}): kept as {}, and made again from {} archives", aside.display(), rebuilt.segments.len());
                put_index(&session, &rebuilt, &tag)?;
                (rebuilt, false)
            }
        };
        // Per-segment index files (a build before the one index): every one that reads goes into
        // the one index, put in place first, then the files go. One that does not read stays,
        // and its read stays a clear error.
        let mut migrated = Vec::new();
        for &index in &legacy {
            match read_legacy_index(&session, index) {
                Ok(entry) => {
                    if !doc.segments.contains_key(&index) {
                        doc.segments.insert(index, entry);
                        rewrite = true;
                    }
                    migrated.push(index);
                }
                Err(e) => {
                    tracing::warn!(session = %id, index, "a cold segment's index file does not read ({e:#}): it stays as it is");
                }
            }
        }
        if rewrite {
            put_index(&session, &doc, &tag)?;
        }
        for index in migrated {
            crate::home_fs::remove_file(idx_path(&session, index))?;
            changed.0 = true;
        }
        let legacy_left =
            |index: u32| crate::home_fs::try_exists_nofollow(idx_path(&session, index));
        for entry in &entries {
            let name = entry.name.to_string_lossy();
            if stale_tmp(name.as_ref()) {
                let _ = crate::home_fs::remove_file(cold_dir.join(&entry.name));
                changed.1 = true;
            }
        }
        let mut damaged = Vec::new();
        for (name, index) in &archived {
            let (name, index) = (name.as_str(), *index);
            let path = cold_dir.join(name);
            let src = ndjson_path(&session, index);
            let has_src = crate::home_fs::try_exists_nofollow(&src)?;
            let entry = doc.segments.get(&index).cloned();
            if entry.is_none() && !legacy_left(index)? {
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
            let archive = match entry {
                Some(entry) => Ok(entry),
                None => read_legacy_index(&session, index),
            }
            .and_then(|entry| {
                archive_holds(&path, &entry)?;
                Ok(entry)
            });
            match archive {
                Ok(entry) => {
                    let (sha, len) = file_hash(&src)?;
                    if sha == entry.sha256 && len == entry.raw_len {
                        #[cfg(test)]
                        super::log_sync::hold(&HOLD_SETTLE_BEFORE_REMOVE);
                        crate::home_fs::remove_file(&src)?;
                    } else {
                        let aside = events.join(format!("{index:06}.ndjson.orphan-{}", now_ms()));
                        tracing::warn!(session = %id, index, "a segment beside its committed archive reads differently: kept as {}", aside.display());
                        crate::home_fs::rename(&src, &aside)?;
                    }
                    changed.0 = true;
                }
                Err(e) => {
                    // The segment is the log; the damaged archive and its entry go aside, and a
                    // later pass moves the segment again.
                    tracing::warn!(session = %id, index, "a cold segment does not read back ({e:#}): its segment stays the log");
                    damaged.push((name.to_owned(), index));
                }
            }
        }
        if !damaged.is_empty() {
            // The entries leave the index first (its rename the point past which the segments
            // read from their `.ndjson` only), then the archives go aside.
            let at = now_ms();
            for (_, index) in &damaged {
                let aside = events.join(format!("{index:06}{IDX_SUFFIX}.damaged-{at}"));
                if let Some(entry) = doc.segments.remove(index) {
                    crate::home_fs::write(&aside, serde_json::to_vec(&entry)?)?;
                } else if legacy_left(*index)? {
                    crate::home_fs::rename(idx_path(&session, *index), &aside)?;
                }
            }
            put_index(&session, &doc, &tag)?;
            for (name, _) in &damaged {
                crate::home_fs::rename(
                    cold_dir.join(name),
                    cold_dir.join(format!("{name}.damaged-{at}")),
                )?;
            }
            changed = (true, true);
        }
        if changed.0 {
            sync_directory(&events)?;
        }
        if changed.1 {
            sync_directory(&cold_dir)?;
        }
        Ok(())
    }

    /// Brings every cold segment of `id` back to a plain `.ndjson` (`cmux chats warm`), oldest
    /// first, each its own commit; the reverse of a move, with the same care:
    /// 1. the archive is decoded into a temporary file beside the index, checked against the
    ///    index's length and SHA-256, and synced (no lock held);
    /// 2. under the writers' lock, and only while the index is there and no `.ndjson` is: the
    ///    file is renamed to `NNNNNN.ndjson` and `events/` synced. The listing reads the
    ///    `.ndjson` from here on, and a crash here leaves the state a move's crash after its
    ///    commit leaves, which a settle finishes losslessly (the segment goes cold again; a
    ///    second warm brings it back);
    /// 3. the index is written again without the segment's entry, synced and renamed in place,
    ///    and `events/` synced (the commit point; a per-segment file of an older build goes too):
    ///    a crash after it leaves an archive no index names beside its segment, which a settle
    ///    removes;
    /// 4. the archive is removed and `cold-segments/` synced.
    ///
    /// A segment whose archive does not decode to its index, or whose write fails (a full disk),
    /// stays cold as it was and is named in [`ColdWarmed::left`]; the others go on. Refused once
    /// the store is sealed.
    pub(super) fn warm_cold_segments(&self, id: &str) -> Result<ColdWarmed> {
        let mut warmed = ColdWarmed::default();
        if self.is_cold(id) {
            warmed.archived_whole = true;
            return Ok(warmed);
        }
        self.settle_cold_segments(id)?;
        let session = self.dir(id);
        let events = session.join("events");
        let cold_dir = session.join(COLD_DIR);
        let (segments, _) = self.listed_files(id)?;
        for (index, path) in segments {
            if !is_cold(&path) {
                continue;
            }
            let _sealed = self.unsealed(id)?;
            let (tmp, doc) = match write_warm(&session, index, &self.cold_tag) {
                Ok(written) => written,
                Err(e) if e.is::<Crash>() => return Err(e),
                Err(e) => {
                    tracing::warn!(session = %id, index, "a cold segment stays cold: {e:#}");
                    warmed.left.push((index, format!("{e:#}")));
                    continue;
                }
            };
            let idx = idx_path(&session, index);
            let src = ndjson_path(&session, index);
            {
                // The chat's cold lock from the check through the archive's removal: a settle
                // between the rename and the index's removal would take the `.ndjson` for a
                // crash's leftover beside its committed archive and remove it, and the warm then
                // the index and the archive (#43562 review F1).
                let _writers = self.writers.lock_or_recover();
                let _cold = self.cold.lock(id);
                let placeable =
                    is_committed(&session, index)? && !crate::home_fs::try_exists_nofollow(&src)?;
                if !placeable {
                    let _ = crate::home_fs::remove_file(&tmp);
                    continue;
                }
                crate::home_fs::rename(&tmp, &src)?;
                sync_directory(&events)?;
                #[cfg(test)]
                if crash_after(Step::WarmPlaced) {
                    return Err(Crash.into());
                }
                #[cfg(test)]
                super::log_sync::hold(&HOLD_WARM_PLACED);
                let (_, mut now) = index_now(&session)?;
                if now.segments.remove(&index).is_some() {
                    // The commit point: the segment is plain from here on.
                    put_index(&session, &now, &self.cold_tag)?;
                }
                if crate::home_fs::try_exists_nofollow(&idx)? {
                    crate::home_fs::remove_file(&idx)?;
                    sync_directory(&events)?;
                }
                #[cfg(test)]
                if crash_after(Step::WarmCommitted) {
                    return Err(Crash.into());
                }
                crate::home_fs::remove_file(zst_path(&session, index))?;
                sync_directory(&cold_dir)?;
            }
            warmed.segments += 1;
            warmed.raw += doc.raw_len;
            warmed.comp += doc.comp_len;
            tracing::info!(session = %id, index, raw = doc.raw_len, "a cold log segment is plain again");
        }
        // An empty `cold-segments/` goes; one that still holds an archive (left cold, or set
        // aside by a settle) stays.
        if crate::home_fs::read_dir(&cold_dir).is_ok_and(|entries| entries.is_empty()) {
            let _ = crate::home_fs::remove_dir(&cold_dir);
        }
        Ok(warmed)
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

#[cfg(test)]
#[path = "cold_segments_race_tests.rs"]
mod race_tests;

#[cfg(test)]
#[path = "cold_segments_index_tests.rs"]
mod index_tests;
