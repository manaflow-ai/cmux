//! Retention of a closed chat's event log (`hub/retention.rs`): the log is rewritten without what
//! only a running chat needs, every kept record's `seq` unchanged, so the chat still lists, opens
//! and resumes from it.
//!
//! What goes: the harness's raw lines (`claude.*` and `codex.*` from the agent), which the ACP
//! records beside them repeat; and inside tool call records, every string longer than [`LONG`]
//! bytes (a command's output, a file's text, an edit's diff), cut to its first [`KEPT`] bytes and a
//! note of what was cut. Everything else stays as written: the prompts and the agent's messages (a
//! rehydrated agent is told them, `hub/transcript.rs`), the turn, queue and status records the log
//! load reads, and `session.json`.
//!
//! Each segment is rewritten beside itself (`NNNNNN.ndjson.compact`) with no lock held
//! ([`LocalStore::stage_compaction`]) and renamed over it once nothing was appended since
//! ([`LocalStore::commit_compaction`], under the chat's append lock), so a segment on disk is
//! always either the old one or the compacted one. `events/compacted.json` records the pass; a log
//! with it is never taken for a purged chat's (`has_records`).

use super::*;
use std::borrow::Cow;

/// The record of a log's compaction, beside its segments.
pub const MARKER: &str = "compacted.json";
/// A tool call string longer than this is cut.
const LONG: usize = 2048;
/// How much of a cut string is kept.
const KEPT: usize = 512;

/// What a compaction removed (or would remove).
#[derive(Debug, Default, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Compaction {
    pub bytes_before: u64,
    pub bytes_after: u64,
    /// Raw harness lines dropped.
    pub dropped: u64,
    /// Tool call records whose long strings were cut.
    pub trimmed: u64,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Marker {
    /// The log's last record when it was compacted: a later pass skips it unless the chat logged
    /// more since.
    last_seq: u64,
    at: u64,
    #[serde(flatten)]
    stats: Compaction,
}

/// Whether a pass writes the compacted log, and where the old segments go.
#[derive(Clone, Copy)]
pub enum CompactMode<'a> {
    /// Only measure.
    DryRun,
    /// Write the compacted segments; with `archive`, hard-link (or copy) each old segment into
    /// `<archive>/<id>/events/` first, so nothing is lost.
    Write { archive: Option<&'a Path> },
}

/// A log's compacted segments, written beside the old ones and not yet in place. Dropping it
/// removes them.
pub struct Staged {
    pub stats: Compaction,
    last_seq: u64,
    segments: Vec<StagedSegment>,
}

struct StagedSegment {
    path: PathBuf,
    /// The old segment's length when it was read: a commit refuses a log that grew since.
    len: u64,
    /// The compacted copy (none in a dry run).
    tmp: Option<PathBuf>,
}

impl Drop for Staged {
    fn drop(&mut self) {
        for tmp in self.segments.iter().filter_map(|s| s.tmp.as_ref()) {
            let _ = std::fs::remove_file(tmp);
        }
    }
}

impl LocalStore {
    pub(super) fn marker(&self, id: &str) -> PathBuf {
        self.dir(id).join("events").join(MARKER)
    }

    /// The last `seq` of the log when it was last compacted.
    pub(super) fn compacted_seq(&self, id: &str) -> Option<u64> {
        let text = std::fs::read(self.marker(id)).ok()?;
        serde_json::from_slice::<Marker>(&text).ok().map(|m| m.last_seq)
    }

    /// Reads the log and, unless `mode` is a dry run, writes its compacted segments beside it.
    /// None for a chat with no log.
    pub(super) fn stage_compaction(&self, id: &str, mode: CompactMode) -> Result<Option<Staged>> {
        let segments = self.segments(id)?;
        if segments.is_empty() {
            return Ok(None);
        }
        let (write, archive) = match mode {
            CompactMode::DryRun => (false, None),
            CompactMode::Write { archive } => (true, archive.map(|a| a.join(id))),
        };
        if let Some(archive) = &archive {
            // Owner-only, as the chat's own folder is.
            std::fs::create_dir_all(archive.parent().unwrap_or(archive))?;
            crate::config::private_state_dir(archive)?;
            crate::config::private_state_dir(&archive.join("events"))?;
            let meta = self.dir(id).join("session.json");
            if meta.exists() {
                std::fs::copy(&meta, archive.join("session.json"))?;
            }
        }
        let mut staged = Staged { stats: Compaction::default(), last_seq: 0, segments: Vec::new() };
        let mut line = Vec::new();
        for (_, path) in segments {
            let file = crate::config::private_state_file(&path)?;
            let len = file.metadata()?.len();
            let tmp = write.then(|| path.with_extension("ndjson.compact"));
            let mut out = match &tmp {
                Some(tmp) => {
                    let _ = std::fs::remove_file(tmp);
                    let file = open_private_append(tmp)?;
                    Some(std::io::BufWriter::with_capacity(256 * 1024, file))
                }
                None => None,
            };
            staged.segments.push(StagedSegment { path: path.clone(), len, tmp });
            // Only what was there when it was opened: a record appended since makes the commit
            // refuse the log, never a half-read line.
            let mut reader = BufReader::with_capacity(256 * 1024, (&file).take(len));
            loop {
                line.clear();
                if reader.read_until(b'\n', &mut line)? == 0 {
                    break;
                }
                staged.stats.bytes_before += line.len() as u64;
                if let Some(seq) = record_seq(&line) {
                    staged.last_seq = staged.last_seq.max(seq);
                }
                if let Some(record) = compact_line(&line, &mut staged.stats) {
                    staged.stats.bytes_after += record.len() as u64;
                    if let Some(out) = out.as_mut() {
                        out.write_all(&record)?;
                    }
                }
            }
            if let Some(out) = out {
                let out = out.into_inner().map_err(|e| e.into_error())?;
                out.sync_all()?;
                drop_cache(&out);
            }
            drop_cache(&file);
            if let (Some(archive), Some(name)) = (&archive, path.file_name()) {
                let to = archive.join("events").join(name);
                let _ = std::fs::remove_file(&to);
                if std::fs::hard_link(&path, &to).is_err() {
                    std::fs::copy(&path, &to)?;
                }
            }
        }
        Ok(Some(staged))
    }

    /// Puts `staged` in place of the log it was read from, unless the log changed since (false).
    /// The caller holds the chat's append lock, so no record lands meanwhile.
    pub(super) fn commit_compaction(&self, id: &str, mut staged: Staged) -> Result<bool> {
        let now = self.segments(id)?;
        let unchanged = now.len() == staged.segments.len()
            && now.iter().zip(&staged.segments).all(|((_, path), s)| {
                *path == s.path
                    && std::fs::symlink_metadata(path).is_ok_and(|m| m.len() == s.len)
                    && s.tmp.is_some()
            });
        if !unchanged {
            return Ok(false);
        }
        // The record goes first: a crash between two renames leaves a log that may hold nothing,
        // and the record keeps it from passing for a purged chat's.
        let marker = Marker { last_seq: staged.last_seq, at: now_ms(), stats: staged.stats };
        write_atomic(&self.marker(id), &serde_json::to_vec_pretty(&marker)?)?;
        // Its next append opens the compacted segment, not the old one's descriptor.
        self.close_log(id);
        // Every segment stays, an empty one too: a reader that listed the segments a moment ago
        // opens each by its name.
        for segment in &mut staged.segments {
            if let Some(tmp) = segment.tmp.take() {
                std::fs::rename(&tmp, &segment.path)?;
            }
        }
        sync_directory(&self.dir(id).join("events"))?;
        Ok(true)
    }
}

/// One log line as compaction keeps it, or None when it goes.
fn compact_line<'a>(line: &'a [u8], stats: &mut Compaction) -> Option<Cow<'a, [u8]>> {
    let kind = record_kind(line);
    if record_dir(line) == Some(b"in")
        && kind.is_some_and(|k| k.starts_with(b"claude.") || k.starts_with(b"codex."))
    {
        stats.dropped += 1;
        return None;
    }
    if line.len() > LONG
        && kind.is_some_and(|k| k.starts_with(b"tool_call"))
        && let Ok(mut record) = serde_json::from_slice::<EventRecord>(line)
        && cut_long_strings(&mut record.msg)
        && let Ok(mut out) = serde_json::to_vec(&record)
    {
        out.push(b'\n');
        stats.trimmed += 1;
        return Some(Cow::Owned(out));
    }
    Some(Cow::Borrowed(line))
}

/// Cuts every string in `value` longer than [`LONG`] bytes; whether any was.
fn cut_long_strings(value: &mut Value) -> bool {
    match value {
        Value::String(text) if text.len() > LONG => {
            let mut cut = KEPT;
            while !text.is_char_boundary(cut) {
                cut -= 1;
            }
            let removed = text.len() - cut;
            text.truncate(cut);
            text.push_str(&format!("… [{removed} bytes removed by log retention]"));
            true
        }
        Value::Array(items) => items.iter_mut().fold(false, |cut, v| cut_long_strings(v) | cut),
        Value::Object(fields) => {
            fields.values_mut().fold(false, |cut, v| cut_long_strings(v) | cut)
        }
        _ => false,
    }
}

/// Drops a log file's pages from the page cache once it is read or written: a pass reads every
/// old log once, and a daemon under a memory limit (huge-blue's cgroup) is charged for its cache.
#[cfg(target_os = "linux")]
fn drop_cache(file: &File) {
    use std::os::fd::AsRawFd;
    // SAFETY: the descriptor is open for the call; the advice changes no file content.
    unsafe {
        libc::posix_fadvise(file.as_raw_fd(), 0, 0, libc::POSIX_FADV_DONTNEED);
    }
}

#[cfg(not(target_os = "linux"))]
fn drop_cache(_file: &File) {}

#[cfg(test)]
#[path = "compact_tests.rs"]
mod tests;
