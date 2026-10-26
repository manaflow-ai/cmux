//! The on-disk form of a peer session's copy (`peer_snapshot.rs`): beside `peers/<peer>.json`
//! (`peer_cache.rs`), `peers/<peer>/<muxSessionId>/meta.json` (generation, lastSeq, capturedAt,
//! the last-known row) and `seg-<n>.ndjson`, a record a line. A segment is always written whole,
//! from its parsed records, to a temporary file renamed in (`config::write_atomic`), so a full
//! disk or a crash never leaves a cut one, and one with a line that does not parse (another
//! writer's) is never written again. A removal renames the path into `peers/.trash-*` first, in
//! one step, so a crash never leaves a copy that reads; a scan removes trash, and any session
//! without its `meta.json`. Nothing here follows a symlink.

use anyhow::Result;
use serde_json::Value;
use std::collections::BTreeSet;
use std::io::Read as _;
use std::path::{Path, PathBuf};

/// Records and bytes one peer session keeps; more than an attach page (400).
pub(crate) const SESSION_EVENTS: usize = if cfg!(test) { 40 } else { 1000 };
pub(crate) const SESSION_BYTES: u64 = if cfg!(test) { 16 << 10 } else { 2 << 20 };
/// A segment past either is sealed: a session has about four.
pub(super) const SEGMENT_EVENTS: usize = SESSION_EVENTS / 4;
pub(super) const SEGMENT_BYTES: u64 = SESSION_BYTES / 4;

pub(super) type Key = (String, String);
pub(super) type Writer = fn(&Path, &[u8]) -> Result<()>;

#[derive(Debug, Clone)]
pub(super) struct Segment {
    pub path: PathBuf,
    pub n: u64,
    pub bytes: u64,
    /// What it holds, once read (`load`).
    pub seqs: BTreeSet<u64>,
    /// It holds a line that does not parse: never written again.
    pub sealed: bool,
}

impl Segment {
    pub fn last(&self) -> u64 {
        self.seqs.last().copied().unwrap_or(0)
    }
}

#[derive(Default, PartialEq, Debug, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub(super) struct Meta {
    pub generation: Option<u64>,
    pub last_seq: u64,
    pub host_last_seq: u64,
    pub captured_at: u64,
    pub from_start: bool,
    pub summary: Value,
}

/// A session an earlier run kept: its meta and its segments, not yet read.
#[derive(Debug)]
pub(super) struct Kept {
    pub meta: Meta,
    pub meta_bytes: u64,
    pub segments: Vec<Segment>,
}

pub(super) fn valid_mux_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && !id.starts_with('.')
        && id.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
}

pub(super) fn record_bytes(v: &Value) -> u64 {
    serde_json::to_vec(v).map_or(0, |b| b.len() as u64 + 1)
}

pub(super) fn seq_of(v: &Value) -> Option<u64> {
    v.get("seq").and_then(Value::as_u64).filter(|s| *s > 0)
}

/// Runs disk work called from async code without holding up the runtime's other tasks: on a
/// worker of a multi-thread runtime (the daemon's, `cli/entry.rs`) it tells the runtime first,
/// as `persist_retry.rs` and `session_scope.rs` do. A current-thread runtime (a test, a one-shot
/// CLI) has no other worker to hold up.
pub(super) fn blocking<T>(f: impl FnOnce() -> T) -> T {
    let multi = tokio::runtime::Handle::try_current()
        .is_ok_and(|h| h.runtime_flavor() == tokio::runtime::RuntimeFlavor::MultiThread);
    if multi { tokio::task::block_in_place(f) } else { f() }
}

/// A state file's text, never through a symlink; None when it is missing.
fn read_private(path: &Path) -> Result<Option<String>> {
    let missing = |e: &anyhow::Error| {
        e.downcast_ref::<std::io::Error>().map(std::io::Error::kind)
            == Some(std::io::ErrorKind::NotFound)
    };
    let mut file = match crate::config::private_state_file(path) {
        Ok(file) => file,
        Err(e) if missing(&e) => return Ok(None),
        Err(e) => return Err(e),
    };
    let mut text = String::new();
    file.read_to_string(&mut text)?;
    Ok(Some(text))
}

/// A segment's records, and whether a line did not parse. A missing file has none; any other
/// error is an error.
pub(super) fn read_segment(path: &Path) -> Result<(Vec<Value>, bool)> {
    let text = read_private(path)?.unwrap_or_default();
    let records: Vec<Value> = text
        .lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .filter(|v| seq_of(v).is_some())
        .collect();
    let cut = records.len() != text.lines().count();
    Ok((records, cut))
}

/// The directories in `dir`, by name, never through a symlink.
fn dirs(dir: &Path) -> Vec<(String, PathBuf)> {
    let entries = std::fs::read_dir(dir).into_iter().flatten().flatten();
    entries
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
        .filter_map(|e| Some((e.file_name().into_string().ok()?, e.path())))
        .collect()
}

/// The bytes of the files under `path`, never through a symlink (a session's or a peer's
/// directory holds two levels at most; deeper is not counted).
pub(super) fn tree_bytes(path: &Path) -> u64 {
    fn walk(path: &Path, depth: u8) -> u64 {
        let Ok(meta) = std::fs::symlink_metadata(path) else { return 0 };
        if meta.is_file() {
            return meta.len();
        }
        if !meta.is_dir() || depth == 0 {
            return 0;
        }
        let entries = std::fs::read_dir(path).into_iter().flatten().flatten();
        entries.map(|e| walk(&e.path(), depth - 1)).sum()
    }
    walk(path, 3)
}

/// What an earlier run kept under `dir` (`peers/`), and what is to be removed, with its bytes:
/// what a removal left in `peers/.trash-*`, and the session directories that are not a copy (no
/// `meta.json`, no segment, or more than a session ever holds).
pub(super) fn scan(dir: &Path) -> (Vec<(Key, Kept)>, Vec<(PathBuf, u64)>) {
    let (mut kept, mut stray) = (Vec::new(), Vec::new());
    for e in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        if e.file_name().to_string_lossy().starts_with(TRASH) {
            stray.push((e.path(), tree_bytes(&e.path())));
        }
    }
    for (peer, peer_dir) in dirs(dir) {
        if crate::session_name::validate(&peer).is_err() {
            continue;
        }
        for (mux, path) in dirs(&peer_dir).into_iter().filter(|(mux, _)| valid_mux_id(mux)) {
            match scan_session(&path) {
                Some(k) => kept.push(((peer.clone(), mux), k)),
                None => stray.push((path.clone(), tree_bytes(&path))),
            }
        }
    }
    (kept, stray)
}

fn scan_session(dir: &Path) -> Option<Kept> {
    let text = read_private(&dir.join("meta.json")).ok().flatten()?;
    let meta = serde_json::from_str::<Meta>(&text).ok()?;
    let mut segments = Vec::new();
    for f in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let Ok(name) = f.file_name().into_string() else { continue };
        if name.contains(".tmp-") {
            // A write that was never renamed in.
            let _ = std::fs::remove_file(f.path());
            continue;
        }
        let n = name.strip_prefix("seg-").and_then(|s| s.strip_suffix(".ndjson"));
        let n = n.and_then(|n| n.parse::<u64>().ok()).filter(|n| *n < 1 << 32);
        if let Some(n) = n
            && f.file_type().is_ok_and(|t| t.is_file())
        {
            let bytes = f.metadata().map_or(0, |m| m.len());
            // Sealed until `load` reads it.
            segments.push(Segment {
                path: f.path(),
                n,
                bytes,
                seqs: BTreeSet::new(),
                sealed: true,
            });
        }
    }
    segments.sort_by_key(|s| s.n);
    let bytes: u64 = segments.iter().map(|s| s.bytes).sum();
    // A session holds its bound plus the one segment a write opens before pruning.
    let most = SESSION_EVENTS.div_ceil(SEGMENT_EVENTS) + 1;
    if segments.is_empty() || bytes > SESSION_BYTES + SEGMENT_BYTES || segments.len() > most {
        return None;
    }
    Some(Kept { meta, meta_bytes: text.len() as u64, segments })
}

/// Reads each segment's seqs. A segment past a segment's bound is not one this daemon wrote: an
/// error, as a read that fails is.
pub(super) fn load(segments: &mut [Segment]) -> Result<()> {
    for seg in segments {
        let (records, cut) = read_segment(&seg.path)?;
        anyhow::ensure!(
            records.len() <= SEGMENT_EVENTS && seg.bytes <= SEGMENT_BYTES,
            "{} holds more than a segment does",
            seg.path.display()
        );
        seg.seqs = records.iter().filter_map(seq_of).collect();
        seg.sealed = cut;
    }
    Ok(())
}

/// The newest of `segments` with room for a record of `first` bytes, else a new one after it.
pub(super) fn open_segment(segments: &[Segment], dir: &Path, first: u64) -> Segment {
    let fits = |s: &&Segment| {
        !s.sealed && s.seqs.len() < SEGMENT_EVENTS && s.bytes + first <= SEGMENT_BYTES
    };
    if let Some(seg) = segments.last().filter(fits) {
        return seg.clone();
    }
    let n = segments.last().map_or(0, |s| s.n + 1);
    Segment {
        path: dir.join(format!("seg-{n}.ndjson")),
        n,
        bytes: 0,
        seqs: BTreeSet::new(),
        sealed: false,
    }
}

/// The records of `pending` (in seq order) that fit in `seg`.
pub(super) fn batch<'a>(seg: &Segment, pending: impl Iterator<Item = &'a Value>) -> Vec<Value> {
    let (mut room, mut count) = (SEGMENT_BYTES.saturating_sub(seg.bytes), seg.seqs.len());
    let mut records = Vec::new();
    for r in pending {
        let b = record_bytes(r);
        if b > room || count >= SEGMENT_EVENTS {
            break;
        }
        (room, count) = (room - b, count + 1);
        records.push(r.clone());
    }
    records
}

/// Writes `seg` as the records it holds on disk plus those of `records` it does not (a retry
/// after a write whose `meta.json` failed adds nothing twice). Answers its size and seqs.
pub(super) fn write_segment(
    write: Writer,
    dir: &Path,
    seg: &Segment,
    records: &[Value],
) -> Result<(u64, BTreeSet<u64>)> {
    let (kept, _) = if seg.bytes > 0 { read_segment(&seg.path)? } else { Default::default() };
    let mut seqs: BTreeSet<u64> = kept.iter().filter_map(seq_of).collect();
    let new = records.iter().filter(|r| seq_of(r).is_some_and(|seq| seqs.insert(seq)));
    let mut body = Vec::new();
    for r in kept.iter().chain(new.collect::<Vec<_>>()) {
        body.extend_from_slice(&serde_json::to_vec(r)?);
        body.push(b'\n');
    }
    crate::config::private_state_dir(dir)?;
    write(&seg.path, &body)?;
    Ok((body.len() as u64, seqs))
}

/// Writes a session's `meta.json` (`Meta`, serialized).
pub(super) fn write_meta(write: Writer, dir: &Path, body: &[u8]) -> Result<()> {
    crate::config::private_state_dir(dir)?;
    write(&dir.join("meta.json"), body)
}

const TRASH: &str = ".trash-";

/// Removes `path` (a session's or a peer's directory, a segment, or trash, under `root`,
/// `peers/`): it is renamed into `root/.trash-*` in one step, which a crash cannot cut, then
/// deleted. A refusal answers the path still on disk (`path`, or the trash it became) to try
/// again. Never through a symlink: a symlink is renamed, not followed.
pub(super) fn remove(root: &Path, path: &Path) -> Result<(), (PathBuf, std::io::Error)> {
    static N: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = N.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let trash = root.join(format!("{TRASH}{}-{n}", std::process::id()));
    match std::fs::rename(path, &trash) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err((path.to_owned(), e)),
        Ok(()) => {}
    }
    let dir = std::fs::symlink_metadata(&trash).is_ok_and(|m| m.is_dir());
    let gone = if dir { std::fs::remove_dir_all(&trash) } else { std::fs::remove_file(&trash) };
    match gone {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err((trash, e)),
        _ => Ok(()),
    }
}

#[cfg(test)]
#[path = "disk_tests.rs"]
mod tests;
