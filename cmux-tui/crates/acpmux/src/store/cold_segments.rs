//! PROTOTYPE (pricing only, `scripts/measure/chat-cold-segments.py`): an open chat's sealed log
//! segments go cold, compressed and off the hot path, and page back when a reader scrolls past
//! the local ones. Off unless `ACPMUX_COLD_SEGMENTS=1`; nothing else changes without it.
//!
//! On a segment's seal (`LocalStore::append_line` rolls to the next one), a background thread
//! moves `events/NNNNNN.ndjson` to `<session>/cold-segments/NNNNNN.zst`: the segment cut into
//! chunks of about [`CHUNK_RAW`] bytes at line ends, each its own zstd frame, so a 400-record page
//! decompresses one or two chunks, never the whole 8 MiB segment. Its index,
//! `events/NNNNNN.cold.idx` (one JSON line: each chunk's raw offset and length, compressed
//! offset and length, first seq; the raw length and SHA-256), stays local.
//!
//! Order, so a crash leaves a whole log: the archive is written under a temporary name, every
//! chunk decoded back and checked against the source's SHA-256, synced and renamed into place;
//! then the index is written durably (the commit point); only then is the `.ndjson` removed.
//! A listing (`LocalStore::listed_files`) takes a segment from its archive once its index is
//! there, and from its `.ndjson` otherwise.
//!
//! A cold segment reads through [`ColdFile`], which is `Read + Seek` over the segment's raw bytes,
//! so the readers that seek and read back (`offset_of_seq`, `for_each_line_rev_between`) work on
//! it unchanged. It holds at most two decoded chunks.

use super::*;
use sha2::{Digest, Sha256};
use std::io::{Seek, SeekFrom};

/// The folder beside `events/` that holds the archives.
pub(crate) const COLD_DIR: &str = "cold-segments";
/// About how many raw bytes one chunk holds: a 400-record page of a coordinator chat is
/// 100-200 KiB.
const CHUNK_RAW: usize = 128 * 1024;
const SCHEMA: &str = "acpmux.cold-seg.v0";

/// Whether sealed segments go cold (`ACPMUX_COLD_SEGMENTS=1`).
pub(crate) fn enabled() -> bool {
    static ON: std::sync::LazyLock<bool> = std::sync::LazyLock::new(|| {
        std::env::var("ACPMUX_COLD_SEGMENTS").is_ok_and(|v| v == "1" || v == "true")
    });
    *ON
}

/// The zstd level (`ACPMUX_COLD_SEGMENTS_LEVEL`, default 19 as `store/cold.rs`).
fn level() -> i32 {
    std::env::var("ACPMUX_COLD_SEGMENTS_LEVEL").ok().and_then(|v| v.parse().ok()).unwrap_or(19)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Index {
    schema: String,
    raw_len: u64,
    comp_len: u64,
    sha256: String,
    level: i32,
    compress_ms: u64,
    /// `[raw_off, raw_len, comp_off, comp_len, first_seq]`.
    chunks: Vec<[u64; 5]>,
}

pub(crate) fn idx_path(session: &Path, index: u32) -> PathBuf {
    session.join("events").join(format!("{index:06}.cold.idx"))
}

pub(crate) fn zst_path(session: &Path, index: u32) -> PathBuf {
    session.join(COLD_DIR).join(format!("{index:06}.zst"))
}

/// The cold segments of `session` whose index is there: `(index, archive path)`.
pub(crate) fn listed(session: &Path) -> Vec<(u32, PathBuf)> {
    let Ok(rd) = std::fs::read_dir(session.join(COLD_DIR)) else { return Vec::new() };
    let mut out = Vec::new();
    for entry in rd.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if let Some(stem) = name.strip_suffix(".zst")
            && let Ok(index) = stem.parse::<u32>()
            && idx_path(session, index).exists()
        {
            out.push((index, entry.path()));
        }
    }
    out
}

/// A segment's file, local or cold.
pub(crate) enum SegmentFile {
    Local(File),
    Cold(ColdFile),
}

impl SegmentFile {
    /// The local file, for the readers that key a copy on its inode (`Stamp::of`).
    pub(crate) fn local(&self) -> Option<&File> {
        match self {
            Self::Local(file) => Some(file),
            Self::Cold(_) => None,
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

/// Opens a path a listing gave: an archive when it ends `.zst`.
pub(crate) fn open_segment(path: &Path) -> Result<SegmentFile> {
    if path.extension().is_some_and(|e| e == "zst") {
        return Ok(SegmentFile::Cold(ColdFile::open(path)?));
    }
    Ok(SegmentFile::Local(crate::config::private_state_file(path)?))
}

/// A cold segment's raw bytes, `Read + Seek`, decoding a chunk when a read reaches it.
pub(crate) struct ColdFile {
    file: File,
    index: Index,
    pos: u64,
    /// The last two chunks decoded, `(chunk, bytes)`: a backwards block read that spans two
    /// chunks decodes each once.
    held: [Option<(usize, Vec<u8>)>; 2],
    next: usize,
}

impl ColdFile {
    fn open(path: &Path) -> Result<Self> {
        let session = path
            .parent()
            .and_then(Path::parent)
            .ok_or_else(|| anyhow::anyhow!("cold segment {} has no session", path.display()))?;
        let index: u32 = path
            .file_stem()
            .and_then(|s| s.to_str())
            .and_then(|s| s.parse().ok())
            .ok_or_else(|| anyhow::anyhow!("cold segment {} has no index", path.display()))?;
        let text = std::fs::read(idx_path(session, index))?;
        let index: Index = serde_json::from_slice(&text)?;
        let file = crate::config::private_state_file(path)?;
        Ok(Self { file, index, pos: 0, held: [None, None], next: 0 })
    }

    /// `log_line::offset_of_seq` from the index: the chunks' first seqs name the one chunk the
    /// offset is in, and only that one is decoded.
    pub(crate) fn offset_of_seq(&mut self, before: u64) -> Result<u64> {
        let chunks = &self.index.chunks;
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
                let [_, raw_len, comp_off, comp_len, _] = self.index.chunks[i];
                let mut comp = vec![0u8; comp_len as usize];
                self.file.seek(SeekFrom::Start(comp_off))?;
                self.file.read_exact(&mut comp)?;
                let raw = zstd::bulk::decompress(&comp, raw_len as usize)?;
                let slot = self.next;
                self.next = (self.next + 1) % 2;
                self.held[slot] = Some((i, raw));
                slot
            }
        };
        Ok(self.held[slot].as_ref().map(|(_, b)| b.as_slice()).unwrap_or_default())
    }
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
        let from = (pos - start) as usize;
        let n = buf.len().min(bytes.len().saturating_sub(from));
        buf[..n].copy_from_slice(&bytes[from..from + n]);
        self.pos += n as u64;
        Ok(n)
    }
}

impl Seek for ColdFile {
    fn seek(&mut self, pos: SeekFrom) -> std::io::Result<u64> {
        let to = match pos {
            SeekFrom::Start(n) => n as i128,
            SeekFrom::End(d) => self.index.raw_len as i128 + d as i128,
            SeekFrom::Current(d) => self.pos as i128 + d as i128,
        };
        if to < 0 {
            return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "seek before 0"));
        }
        self.pos = to as u64;
        Ok(self.pos)
    }
}

/// Moves sealed segment `index` of the chat in `session` cold, on its own thread.
pub(crate) fn spawn_move(session: PathBuf, index: u32) {
    let _ = std::thread::Builder::new().name("cold-segment".into()).spawn(move || {
        if let Err(e) = move_cold(&session, index) {
            tracing::warn!(session = %session.display(), index, "cold segment: {e:#}");
        }
    });
}

fn move_cold(session: &Path, index: u32) -> Result<()> {
    let started = std::time::Instant::now();
    let src = session.join("events").join(format!("{index:06}.ndjson"));
    let dir = session.join(COLD_DIR);
    crate::config::private_state_dir(&dir)?;
    let dst = zst_path(session, index);
    let tmp = dst.with_extension(format!("zst.tmp-{}", std::process::id()));
    let level = level();
    let mut reader = BufReader::with_capacity(256 * 1024, crate::config::private_state_file(&src)?);
    let mut out = crate::home_fs::create_file(&tmp)?;
    let mut hash = Sha256::new();
    let (mut chunks, mut raw_off, mut comp_off) = (Vec::new(), 0u64, 0u64);
    let mut chunk = Vec::with_capacity(CHUNK_RAW + 64 * 1024);
    let mut line = Vec::new();
    let mut first: Option<u64> = None;
    let mut flush = |chunk: &mut Vec<u8>, first: &mut Option<u64>, out: &mut File| -> Result<()> {
        if chunk.is_empty() {
            return Ok(());
        }
        let comp = zstd::bulk::compress(chunk, level)?;
        out.write_all(&comp)?;
        chunks.push([raw_off, chunk.len() as u64, comp_off, comp.len() as u64, first.unwrap_or(0)]);
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
    drop(flush);
    out.sync_all()?;
    drop(out);
    let sha = hex(&hash.finalize());
    let index_doc = Index {
        schema: SCHEMA.into(),
        raw_len: raw_off,
        comp_len: comp_off,
        sha256: sha.clone(),
        level,
        compress_ms: u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX),
        chunks,
    };
    // Every chunk decoded back and checked before anything is in place.
    {
        let mut file = crate::config::private_state_file(&tmp)?;
        let mut check = Sha256::new();
        for [_, raw_len, off, len, _] in &index_doc.chunks {
            let mut comp = vec![0u8; *len as usize];
            file.seek(SeekFrom::Start(*off))?;
            file.read_exact(&mut comp)?;
            check.update(zstd::bulk::decompress(&comp, *raw_len as usize)?);
        }
        anyhow::ensure!(hex(&check.finalize()) == sha, "cold segment {index} decoded differently");
    }
    crate::home_fs::rename(&tmp, &dst)?;
    crate::home_fs::sync_dir(&dir)?;
    super::compact::write_durably(&idx_path(session, index), &serde_json::to_vec(&index_doc)?)?;
    // `ACPMUX_COLD_SEGMENTS_KEEP=<dir>` (the bench's equality check): the source is moved there
    // instead of removed.
    match std::env::var_os("ACPMUX_COLD_SEGMENTS_KEEP") {
        Some(keep) => {
            let id = session.file_name().unwrap_or_default();
            let keep = Path::new(&keep).join(id);
            std::fs::create_dir_all(&keep)?;
            std::fs::rename(&src, keep.join(format!("{index:06}.ndjson")))?;
        }
        None => crate::home_fs::remove_file(&src)?,
    }
    crate::home_fs::sync_dir(&session.join("events"))?;
    tracing::info!(
        session = %session.display(),
        index,
        raw = index_doc.raw_len,
        comp = index_doc.comp_len,
        ms = index_doc.compress_ms,
        "cold segment"
    );
    Ok(())
}

fn hex(digest: &[u8]) -> String {
    digest.iter().map(|b| format!("{b:02x}")).collect()
}
