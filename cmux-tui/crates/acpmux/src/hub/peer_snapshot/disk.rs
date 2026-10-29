//! The on-disk form of a peer session's copy (`peer_snapshot.rs`): one file per session,
//! `peer-snapshots/<hex peer>/<hex muxSessionId>.json` in the daemon's home, beside `peers/` and
//! never in it: what lists the peer caches (`peers/<peer>.json`, `peer_cache.rs`) never sees it.
//! Its first line is the copy's `Head` (whose session it is, its generation, lastSeq, capturedAt,
//! the last-known row), then a record a line, oldest first. Names are
//! lowercase hex, so two ids that differ only in case never share a file on a case-insensitive
//! volume. A file is always written whole to a temporary file renamed over the old one
//! (`config::write_atomic`): a full disk or a crash leaves the old copy or the new one, never a
//! mix, and no file of another copy can join it. One that does not read whole (a cut line,
//! another session's head) is not a copy. Nothing here follows a symlink.

use anyhow::{Context as _, Result};
use serde_json::Value;
use std::collections::BTreeMap;
use std::io::{BufRead as _, Read as _};
use std::path::{Path, PathBuf};

pub(super) type Key = (String, String);
pub(super) type Writer = fn(&Path, &[u8]) -> Result<()>;

/// An id longer than this is not kept: its hex name must fit a file name (255 bytes) with the
/// temporary suffix `config::write_atomic` gives it, `.tmp-<u32 pid>-<u64 counter>` (36 bytes).
const ID_BYTES: usize = 100;
/// The longest temporary suffix `config::write_atomic` puts in place of `.json`.
#[cfg(test)]
const TMP_SUFFIX_BYTES: usize = ".tmp-".len() + 10 + "-".len() + 20;
const EXT: &str = "json";

#[derive(Default, Clone, PartialEq, Debug, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub(super) struct Head {
    pub peer: String,
    pub session_id: String,
    pub generation: Option<u64>,
    /// The seqs the copy covers, `first_seq..=last_seq`: every record of them the pages asked
    /// for, so a page or record joins it only next to or inside them.
    pub first_seq: u64,
    pub last_seq: u64,
    /// The highest seq the peer was seen at for this copy (its pages' `lastSeq`, its records).
    pub host_last_seq: u64,
    pub captured_at: u64,
    pub from_start: bool,
    pub summary: Value,
}

pub(super) fn record_bytes(v: &Value) -> u64 {
    serde_json::to_vec(v).map_or(0, |b| b.len() as u64 + 1)
}

/// A record's seq: from 1, and below 2^53 (what a client's number holds exactly), so no bound's
/// `seq + 1` can overflow.
pub(super) fn seq_of(v: &Value) -> Option<u64> {
    v.get("seq").and_then(Value::as_u64).filter(|s| (1..1 << 53).contains(s))
}

fn hex(s: &str) -> Option<String> {
    use std::fmt::Write as _;
    (!s.is_empty() && s.len() <= ID_BYTES).then(|| {
        s.bytes().fold(String::with_capacity(s.len() * 2), |mut out, b| {
            let _ = write!(out, "{b:02x}");
            out
        })
    })
}

fn unhex(s: &str) -> Option<String> {
    let lower = |c: u8| c.is_ascii_digit() || (b'a'..=b'f').contains(&c);
    if s.is_empty() || !s.len().is_multiple_of(2) || !s.bytes().all(lower) {
        return None;
    }
    let bytes: Option<Vec<u8>> =
        (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok()).collect();
    String::from_utf8(bytes?).ok().filter(|id| id.len() <= ID_BYTES)
}

/// Where every copy lives in the daemon's home `home`.
pub(super) fn root(home: &Path) -> PathBuf {
    home.join("peer-snapshots")
}

pub(super) fn peer_dir(root: &Path, peer: &str) -> Option<PathBuf> {
    Some(root.join(hex(peer)?))
}

/// The file of session `key`; None for an id that cannot be kept.
pub(super) fn path(root: &Path, key: &Key) -> Option<PathBuf> {
    Some(peer_dir(root, &key.0)?.join(format!("{}.{EXT}", hex(&key.1)?)))
}

/// Whether a head line of `len` bytes, with its newline, is within [`super::HEAD_BYTES`]: the one
/// bound the writer and both readers hold it to.
pub(super) fn head_fits(len: u64) -> bool {
    len < super::HEAD_BYTES
}

/// A copy as written: its head line, then its records.
pub(super) fn encode(head: &Head, records: &BTreeMap<u64, Value>) -> Vec<u8> {
    let mut out = serde_json::to_vec(head).unwrap_or_default();
    out.push(b'\n');
    for r in records.values() {
        if let Ok(line) = serde_json::to_vec(r) {
            out.extend_from_slice(&line);
            out.push(b'\n');
        }
    }
    out
}

fn open(path: &Path) -> Result<Option<std::fs::File>> {
    match crate::config::private_state_file(path) {
        Ok(file) => Ok(Some(file)),
        Err(e)
            if e.downcast_ref::<std::io::Error>().map(std::io::Error::kind)
                == Some(std::io::ErrorKind::NotFound) =>
        {
            Ok(None)
        }
        Err(e) => Err(e),
    }
}

fn head_of(line: &str, key: &Key) -> Result<Head> {
    let head: Head = serde_json::from_str(line).context("the head line does not parse")?;
    anyhow::ensure!(head.peer == key.0 && head.session_id == key.1, "another session's copy");
    Ok(head)
}

/// The head of session `key`'s copy, reading only its first line; None when there is none.
pub(super) fn read_head(path: &Path, key: &Key) -> Result<Option<Head>> {
    let Some(file) = open(path)? else { return Ok(None) };
    anyhow::ensure!(file.metadata()?.len() <= super::FILE_BYTES, "the copy is past its bound");
    let mut line = String::new();
    // The line and its newline within the bound, as `head_fits` holds a write to.
    std::io::BufReader::new(file.take(super::HEAD_BYTES)).read_line(&mut line)?;
    anyhow::ensure!(line.ends_with('\n'), "the head line is cut or past its bound");
    head_of(line.trim_end(), key).map(Some)
}

/// Session `key`'s whole copy; an error when any line does not read (never half a copy).
pub(super) fn read(path: &Path, key: &Key) -> Result<Option<(Head, BTreeMap<u64, Value>)>> {
    let Some(file) = open(path)? else { return Ok(None) };
    let mut text = String::new();
    file.take(super::FILE_BYTES + 1).read_to_string(&mut text)?;
    anyhow::ensure!(text.len() as u64 <= super::FILE_BYTES, "the copy is past its bound");
    anyhow::ensure!(text.ends_with('\n'), "the copy is cut");
    let mut lines = text.lines();
    let first = lines.next().unwrap_or_default();
    anyhow::ensure!(head_fits(first.len() as u64), "the head line is past its bound");
    let head = head_of(first, key)?;
    let mut records = BTreeMap::new();
    for line in lines {
        let v: Value = serde_json::from_str(line).context("a record line does not parse")?;
        let seq = seq_of(&v).context("a record without a seq")?;
        anyhow::ensure!(super::of_session(&v, key), "another session's record");
        records.insert(seq, v);
    }
    Ok(Some((head, records)))
}

/// Writes session `key`'s copy whole, through a temporary file renamed in.
pub(super) fn write(write: Writer, root: &Path, key: &Key, bytes: &[u8]) -> Result<u64> {
    // Never a file the readers refuse: past its bound, or a head line past its own.
    // Whole lines only (`encode`), as the readers take them.
    let head = bytes.iter().position(|b| *b == b'\n');
    anyhow::ensure!(bytes.ends_with(b"\n"), "the copy ends in a cut line");
    anyhow::ensure!(bytes.len() as u64 <= super::FILE_BYTES, "the copy is past its bound");
    anyhow::ensure!(head.is_some_and(|h| head_fits(h as u64)), "its head is past its bound");
    let dir = peer_dir(root, &key.0).context("a peer name that cannot be kept")?;
    let path = path(root, key).context("a session id that cannot be kept")?;
    crate::config::private_state_dir(root)?;
    crate::config::private_state_dir(&dir)?;
    write(&path, bytes)?;
    Ok(bytes.len() as u64)
}

/// What a scan found: each copy (its key, file and size) and every other entry, to remove.
#[derive(Default, Debug)]
pub(super) struct Found {
    pub copies: Vec<(Key, PathBuf, u64)>,
    pub stray: Vec<(PathBuf, u64)>,
    /// Peer directories with nothing in them, removed only while they stay empty.
    pub empty: Vec<PathBuf>,
}

/// Every copy under `root`. An error when a directory cannot be read, or `root` is not a private
/// directory of this user (a symlink, another owner's): then what is on disk is not known, and
/// nothing is written or removed until it is.
pub(super) fn scan(root: &Path) -> Result<Found> {
    let mut found = Found::default();
    crate::config::private_state_dir(root)?;
    let entries = std::fs::read_dir(root).with_context(|| format!("read {}", root.display()))?;
    for entry in entries {
        let entry = entry?;
        // `symlink_metadata`: a symlink is itself (stray, removed as a link), never what it names.
        let (path, meta) = (entry.path(), std::fs::symlink_metadata(entry.path())?);
        let peer = entry.file_name().to_str().and_then(unhex);
        let Some(peer) = peer.filter(|_| meta.is_dir()) else {
            found.stray.push((path, meta.len()));
            continue;
        };
        let mut held = false;
        for inner in std::fs::read_dir(&path).with_context(|| format!("read {}", path.display()))? {
            let inner = inner?;
            let (file, meta) = (inner.path(), std::fs::symlink_metadata(inner.path())?);
            let name = inner.file_name();
            let mux = name.to_str().and_then(|n| n.strip_suffix(".json")).and_then(unhex);
            // A file past the bound is not a copy whatever it holds.
            match mux.filter(|_| meta.is_file() && meta.len() <= super::FILE_BYTES) {
                Some(mux) => found.copies.push(((peer.clone(), mux), file, meta.len())),
                None => found.stray.push((file, meta.len())),
            }
            held = true;
        }
        if !held {
            found.empty.push(path);
        }
    }
    Ok(found)
}

/// Removes `path` (a file, a symlink itself, or a directory), never following a symlink.
pub(super) fn remove(path: &Path) -> std::io::Result<()> {
    let meta = match std::fs::symlink_metadata(path) {
        Ok(meta) => meta,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e),
    };
    let gone =
        if meta.is_dir() { std::fs::remove_dir_all(path) } else { std::fs::remove_file(path) };
    match gone {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        other => other,
    }
}

#[cfg(test)]
#[path = "disk_tests.rs"]
mod tests;
