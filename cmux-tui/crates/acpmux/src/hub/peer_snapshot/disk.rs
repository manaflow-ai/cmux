//! The on-disk form of a peer session's copy (`peer_snapshot.rs`): beside `peers/<peer>.json`
//! (`peer_cache.rs`), `peers/<peer>/<muxSessionId>/meta.json` (generation, lastSeq, capturedAt,
//! the last-known row) and `seg-<n>.ndjson`, a record a line. A segment is always written whole,
//! from its parsed records, to a temporary file renamed in (`config::write_atomic`), so a full
//! disk or a crash never leaves a cut one, and one with a line that does not parse (another
//! writer's) is never written again. A session with no `meta.json` is not a copy: a removal
//! unlinks it first, and a scan removes what is left of one. Nothing here follows a symlink.

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

/// What an earlier run kept under `dir` (`peers/`), and the session directories that are not a
/// copy (no `meta.json`, no segment, or more than a session ever holds), for the caller to remove.
pub(super) fn scan(dir: &Path) -> (Vec<(Key, Kept)>, Vec<PathBuf>) {
    let (mut kept, mut stray) = (Vec::new(), Vec::new());
    for (peer, peer_dir) in dirs(dir) {
        if crate::session_name::validate(&peer).is_err() {
            continue;
        }
        for (mux, path) in dirs(&peer_dir).into_iter().filter(|(mux, _)| valid_mux_id(mux)) {
            match scan_session(&path) {
                Some(k) => kept.push(((peer.clone(), mux), k)),
                None => stray.push(path),
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
    if segments.is_empty() || bytes > SESSION_BYTES + SEGMENT_BYTES || segments.len() > 8 {
        return None;
    }
    Some(Kept { meta, meta_bytes: text.len() as u64, segments })
}

/// Reads each segment's seqs; an error leaves the rest unread.
pub(super) fn load(segments: &mut [Segment]) -> Result<()> {
    for seg in segments {
        let (records, cut) = read_segment(&seg.path)?;
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

/// Removes `path`, a session's or a peer's directory or a segment, never through a symlink. A
/// directory's `meta.json`s go first: without one, what is left is not a copy.
pub(super) fn remove(path: &Path) -> std::io::Result<()> {
    let dir = std::fs::symlink_metadata(path).is_ok_and(|m| m.is_dir());
    let removed = if dir {
        let sessions = dirs(path).into_iter().map(|(_, p)| p.join("meta.json"));
        for meta in sessions.chain([path.join("meta.json")]) {
            let _ = std::fs::remove_file(meta);
        }
        std::fs::remove_dir_all(path)
    } else {
        std::fs::remove_file(path)
    };
    match removed {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        other => other,
    }
}

#[cfg(test)]
#[path = "disk_tests.rs"]
mod tests;
