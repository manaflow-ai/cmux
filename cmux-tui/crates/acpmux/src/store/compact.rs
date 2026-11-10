//! Retention of a closed chat's event log (`hub/retention.rs`): the log is rewritten without what
//! only a running chat needs, every kept record's `seq` unchanged, so the chat still lists, opens
//! and resumes from it.
//!
//! What goes: in the harness's raw lines (`claude.*`, `codex.*`) and in tool call records, every
//! string longer than [`LONG`] bytes (a command's output, a file's text, an edit's diff, a model's
//! text the ACP records beside them repeat), cut to its first [`KEPT`] bytes and a note of what was
//! cut; and Claude's raw `stream_event` lines that time no request, which the tap no longer logs
//! (`hub/tap.rs` `times_request`). Every other record, and every field a reader takes from a raw
//! line (OptChat's request timing and usage, `fold.rs`; a subagent's heartbeat, `sub_watch.rs`; an
//! API retry, `transcript.rs`), stays as written: the prompts and the agent's messages (a
//! rehydrated agent is told them, `hub/transcript.rs`), the turn, queue and status records the log
//! load reads, and `session.json`.
//!
//! Each segment is rewritten beside itself (`NNNNNN.ndjson.compact`) with no lock held
//! ([`LocalStore::stage_compaction`]) and renamed over it once nothing was appended since
//! ([`LocalStore::commit_compaction`], under the chat's append lock and the store's writers'
//! lock, which every `append` takes), so a segment on disk is
//! always either the old one or the compacted one, with the same records in the same order.
//! `events/compacted.json` records the pass in two steps: written before the first rename, so a
//! log that may hold nothing is never taken for a purged chat's (`has_records`), and marked
//! complete after the last, so a pass a crash cut short is done again (`compacted_seq`).
//!
//! A cut (`CompactMode::Truncate`, a journal restore's) writes its target, `events/cut.json`
//! ([`CUT`]), durably before its first rename, and removes it after the last: a crash or a
//! failure between two renames leaves segments cut to different ends, and every later reader or
//! append of the log finishes the cut to that target first ([`LocalStore::finish_cut_locked`]).
//! Without it a log of records 1-50 and 201-350 (the cut of 51-350 stopped after the first
//! segment) read as one whose recovery begins at 200, and a restore then skipped 51-200 (review
//! of #37284 at b7496c3f, F2).

use super::*;
use compact_archive::Archive;
use std::borrow::Cow;

#[path = "compact_archive.rs"]
mod compact_archive;

/// The record of a log's compaction, beside its segments.
pub const MARKER: &str = "compacted.json";
/// A cut's target while its segments are replaced, beside them.
pub const CUT: &str = "cut.json";
/// A string longer than this, in a raw line or a tool call record, is cut.
const LONG: usize = 2048;
/// How much of a cut string is kept.
const KEPT: usize = 512;

/// What a compaction removed (or would remove).
#[derive(Debug, Default, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Compaction {
    pub bytes_before: u64,
    pub bytes_after: u64,
    /// Raw stream lines dropped.
    pub dropped: u64,
    /// Records whose long strings were cut.
    pub trimmed: u64,
}

/// What a cut leaves beside the segments until each is replaced ([`CUT`]).
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CutIntent {
    /// Every record past it goes.
    after: u64,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Marker {
    /// The log's last record when it was compacted: a later pass skips it unless the chat logged
    /// more since.
    last_seq: u64,
    at: u64,
    /// Every compacted segment is in place.
    #[serde(default)]
    complete: bool,
    #[serde(flatten)]
    stats: Compaction,
}

/// Whether a pass writes the compacted log, and where the old segments go.
#[derive(Clone, Copy)]
pub enum CompactMode<'a> {
    /// Only measure.
    DryRun,
    /// Write the compacted segments; with `archive`, hard-link (or copy) each old segment into
    /// `<archive>/<id>/<pass>/events/` first, so nothing is lost. Each pass has its own folder (its
    /// start, in Unix ms): a pass done again after a crash never replaces the first one's copies.
    Write { archive: Option<&'a Path> },
    /// Write the log with every record past `after` left out, every other line as it is: a
    /// journal restore takes back the seqs this machine's own recovery wrote past where the
    /// owner's copy goes on (`hub/journal_restore.rs`). Nothing is compacted.
    Truncate { after: u64 },
}

/// A log's compacted segments, written beside the old ones and not yet in place. Dropping it
/// removes them.
pub struct Staged {
    pub stats: Compaction,
    last_seq: u64,
    /// A truncation's (`CompactMode::Truncate`): its commit does not count as a compaction.
    cut: Option<u64>,
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

    fn cut_intent(&self, id: &str) -> PathBuf {
        self.dir(id).join("events").join(CUT)
    }

    /// Finishes a cut of `id`'s log a crash or a failure left between two of its renames
    /// ([`CUT`]): every segment is cut again to the cut's target (a segment already cut is
    /// unchanged by it), the compaction's record is marked complete as the commit would have,
    /// and the target goes. Nothing when no cut is left. The caller holds the writers' lock, so
    /// no record is appended meanwhile; every read and the first append of the log come here
    /// first (`store.rs` `segments`, `append_line`).
    pub(super) fn finish_cut_locked(&self, id: &str, writers: &mut Writers) -> Result<()> {
        let path = self.cut_intent(id);
        let text = match std::fs::read(&path) {
            Ok(text) => text,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(e) => return Err(e).with_context(|| format!("read {}", path.display())),
        };
        let intent: CutIntent = serde_json::from_slice(&text)
            .with_context(|| format!("read the cut left in {}", path.display()))?;
        tracing::warn!(session = %id, after = intent.after, "a cut of this log was left halfway; it is finished first");
        if let Some(w) = writers.open.remove(id) {
            w.close(id, &self.sync_failed);
        }
        let (segments, _) = self.list_segments(id)?;
        if let Some(mut staged) =
            self.stage_segments(id, segments, CompactMode::Truncate { after: intent.after })?
        {
            for segment in &mut staged.segments {
                if let Some(tmp) = segment.tmp.take() {
                    std::fs::rename(&tmp, &segment.path)?;
                }
            }
        }
        sync_directory(&self.dir(id).join("events"))?;
        if let Ok(text) = std::fs::read(self.marker(id))
            && let Ok(mut marker) = serde_json::from_slice::<Marker>(&text)
            && !marker.complete
        {
            marker.complete = true;
            write_durably(&self.marker(id), &serde_json::to_vec_pretty(&marker)?)?;
        }
        std::fs::remove_file(&path)?;
        sync_directory(&self.dir(id).join("events"))?;
        Ok(())
    }

    /// When the log was last written, in ms: its newest segment's modification time. A record
    /// appended, a compaction put in place and a copy an import made all set it; a status write
    /// that logs nothing does not.
    pub(super) fn log_written_at(&self, id: &str) -> Option<u64> {
        let (_, newest) = self.segments(id).ok()?.pop()?;
        let at = std::fs::metadata(newest).ok()?.modified().ok()?;
        let ms = at.duration_since(std::time::UNIX_EPOCH).ok()?.as_millis();
        u64::try_from(ms).ok()
    }

    /// The last `seq` of the log when its last compaction completed.
    pub(super) fn compacted_seq(&self, id: &str) -> Option<u64> {
        let text = std::fs::read(self.marker(id)).ok()?;
        serde_json::from_slice::<Marker>(&text).ok().filter(|m| m.complete).map(|m| m.last_seq)
    }

    /// Reads the log and, unless `mode` is a dry run, writes its compacted segments beside it.
    /// None for a chat with no log.
    pub(super) fn stage_compaction(&self, id: &str, mode: CompactMode) -> Result<Option<Staged>> {
        let segments = self.segments(id)?;
        self.stage_segments(id, segments, mode)
    }

    /// [`Self::stage_compaction`] of `segments`, the log's as listed.
    fn stage_segments(
        &self,
        id: &str,
        segments: Vec<(u32, PathBuf)>,
        mode: CompactMode,
    ) -> Result<Option<Staged>> {
        if segments.is_empty() {
            return Ok(None);
        }
        let (write, archive, cut) = match mode {
            CompactMode::DryRun => (false, None, None),
            CompactMode::Write { archive } => (true, archive, None),
            CompactMode::Truncate { after } => (true, None, Some(after)),
        };
        let archive = match archive {
            Some(root) => {
                let kept = Archive::create(root, id, &now_ms().to_string())?;
                let meta = self.dir(id).join("session.json");
                if meta.exists() {
                    // A copy: the chat's own file may be written again in place.
                    kept.keep(&meta, false, true)?;
                }
                Some(kept)
            }
            None => None,
        };
        let mut staged =
            Staged { stats: Compaction::default(), last_seq: 0, cut, segments: Vec::new() };
        let mut line = Vec::new();
        let mut timing = Timing::default();
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
                if let Some(after) = cut {
                    // A line whose seq does not read stays, as compaction keeps it.
                    if record_seq(&line).is_none_or(|seq| seq <= after) {
                        staged.stats.bytes_after += line.len() as u64;
                        if let Some(out) = out.as_mut() {
                            out.write_all(&line)?;
                        }
                    }
                    continue;
                }
                if let Some(record) = compact_line(&line, &mut timing, &mut staged.stats) {
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
            if let Some(archive) = &archive {
                archive.keep(&path, true, false)?;
            }
        }
        // The copies, and every folder that names them, are on disk before any segment is
        // replaced.
        if let Some(archive) = &archive {
            archive.sync()?;
        }
        Ok(Some(staged))
    }

    /// Puts `staged` in place of the log it was read from, unless the log changed since (false).
    /// The caller holds the chat's append lock; the store's own writers' lock is held from the
    /// check to the last rename, so no record lands meanwhile from any writer (an import's
    /// `append` takes no chat lock).
    pub(super) fn commit_compaction(&self, id: &str, mut staged: Staged) -> Result<bool> {
        if staged.segments.iter().any(|s| s.tmp.is_none()) {
            return Ok(false);
        }
        // A truncation compacted nothing: the marker keeps the last compaction's end (at most
        // where the log ends now), so retention still compacts what came since.
        let last_seq = match staged.cut {
            Some(after) => self.compacted_seq(id).unwrap_or(0).min(after),
            None => staged.last_seq,
        };
        let mut marker = Marker { last_seq, at: now_ms(), complete: false, stats: staged.stats };
        {
            let mut writers = self.writers.lock_or_recover();
            // Listed as they are: a cut left halfway is a change (`stage_compaction` finished
            // any before it read the log).
            let (now, cut_pending) = self.list_segments(id)?;
            let unchanged = !cut_pending
                && now.len() == staged.segments.len()
                && now.iter().zip(&staged.segments).all(|((_, path), s)| {
                    *path == s.path
                        && std::fs::symlink_metadata(path).is_ok_and(|m| m.len() == s.len)
                });
            if !unchanged {
                return Ok(false);
            }
            // The record goes before the renames: a crash between two of them leaves a log that
            // may hold nothing, and the record keeps it from passing for a purged chat's. Until it
            // says complete, a later pass compacts the log again. Only a commit that goes ahead
            // writes it, so a refused one leaves the chat's folder as it was.
            write_durably(&self.marker(id), &serde_json::to_vec_pretty(&marker)?)?;
            // A cut's target is on disk before its first rename (review of #37284 at b7496c3f,
            // F2): a crash or a failure between two renames leaves segments cut to different
            // ends, and the next read or append finishes the cut to it (`finish_cut_locked`).
            // b7496c3f kept it nowhere: a restart read the half-cut log as it was.
            let intent = staged.cut.filter(|_| !crate::hub::journal_restore::rules_of_b749());
            if let Some(after) = intent {
                write_durably(&self.cut_intent(id), &serde_json::to_vec(&CutIntent { after })?)?;
            }
            // Its next append opens the compacted segment, not the old one's descriptor.
            if let Some(w) = writers.open.remove(id) {
                w.close(id, &self.sync_failed);
            }
            // Every segment stays, an empty one too: a reader that listed the segments a moment
            // ago opens each by its name.
            for (n, segment) in staged.segments.iter_mut().enumerate() {
                // Tests only: a crash between two renames.
                #[cfg(test)]
                if n > 0 {
                    between_segments(id);
                }
                #[cfg(not(test))]
                let _ = n;
                if let Some(tmp) = segment.tmp.take() {
                    std::fs::rename(&tmp, &segment.path)?;
                }
            }
            sync_directory(&self.dir(id).join("events"))?;
            if intent.is_some() {
                std::fs::remove_file(self.cut_intent(id))?;
            }
        }
        sync_directory(&self.dir(id).join("events"))?;
        #[cfg(test)]
        if fails_before_marker(id) {
            anyhow::bail!("test: the compaction's marker fails after its segments are in place");
        }
        marker.complete = true;
        write_durably(&self.marker(id), &serde_json::to_vec_pretty(&marker)?)?;
        Ok(true)
    }
}

/// Writes `bytes` to `path` whole and durably, as `config::write_atomic` does, but a failed sync
/// of the file or of its folder is an error (a [`SyncFailed`] for the folder's), not ignored: a
/// compaction's record is what keeps a log that may hold nothing from passing for a purged chat's,
/// and the journal store freezes on a failed sync of its files (#35905).
pub(super) fn write_durably(path: &Path, bytes: &[u8]) -> Result<()> {
    crate::config::refuse_lost_home(path)?;
    static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let tmp = path.with_extension(format!("tmp-{}-{n}", std::process::id()));
    let written = (|| -> Result<()> {
        let mut options = OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
        }
        let mut file = options.open(&tmp).with_context(|| format!("write {}", tmp.display()))?;
        file.write_all(bytes).with_context(|| format!("write {}", tmp.display()))?;
        file.sync_all().map_err(SyncFailed).with_context(|| format!("sync {}", tmp.display()))?;
        drop(file);
        std::fs::rename(&tmp, path).with_context(|| format!("rename to {}", path.display()))?;
        match path.parent() {
            Some(dir) => sync_directory(dir).with_context(|| format!("sync {}", dir.display())),
            None => Ok(()),
        }
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    written
}

/// Which of Claude's raw `stream_event` lines a request's timing reads, as the tap keeps them
/// (`hub/tap.rs` `times_request`): the main agent's `message_start`, and the first
/// `content_block_delta` after one.
#[derive(Default)]
struct Timing {
    awaiting_first_delta: bool,
}

impl Timing {
    fn keeps(&mut self, msg: &Value) -> bool {
        if msg.get("parent_tool_use_id").is_some_and(|p| !p.is_null()) {
            return false;
        }
        match msg.pointer("/event/type").and_then(Value::as_str) {
            Some("message_start") => {
                self.awaiting_first_delta = true;
                true
            }
            Some("content_block_delta") => std::mem::take(&mut self.awaiting_first_delta),
            _ => false,
        }
    }
}

/// One log line as compaction keeps it, or None when it goes.
fn compact_line<'a>(
    line: &'a [u8],
    timing: &mut Timing,
    stats: &mut Compaction,
) -> Option<Cow<'a, [u8]>> {
    let kind = record_kind(line).unwrap_or_default();
    let raw = kind.starts_with(b"claude.") || kind.starts_with(b"codex.");
    if kind == b"claude.stream_event" && record_dir(line) == Some(b"in") {
        let keep =
            serde_json::from_slice::<EventRecord>(line).map_or(true, |r| timing.keeps(&r.msg));
        if !keep {
            stats.dropped += 1;
            return None;
        }
    }
    if line.len() > LONG
        && (raw || kind.starts_with(b"tool_call"))
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
        // An image's base64 cut short draws as a broken image: it goes whole, so the pane falls
        // back to the image's path, as before tool results kept their images.
        Value::Object(fields)
            if fields.get("type").and_then(Value::as_str) == Some("image")
                && fields.get("data").and_then(Value::as_str).is_some_and(|d| d.len() > LONG) =>
        {
            fields.remove("data");
            true
        }
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
