//! Persistence tiers for session metadata and the event log.
//!
//! `Local` writes `sessions/<id>/session.json` and append-only
//! `events/NNNNNN.ndjson` segments. `Memory` keeps the same data in RAM.
//! Both expose the same API so the hub does not care which is active.

use crate::config::{StoreConfig, StoreMode, write_atomic};
use crate::goal::GoalState;
use crate::no_panic::LockExt;
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

mod compact;
pub use compact::{CompactMode, Compaction, Staged};
mod deferred;
pub use deferred::{Deferral, HeldBack, Keep, held_file};
mod cold;
pub(crate) mod cold_segments;
pub use cold::{COLD_FILE, ColdStats, RehydrateHook, StagedCold};
pub use cold_segments::{ColdMoved, ColdWarmed, SealHook, StagedColdSegments};
mod superseded;
pub use superseded::{Superseded, starts_prompt};
mod kind_heads;
mod kind_index;
mod sealed_segments;
mod segment_starts;
#[cfg(test)]
pub(crate) use kind_heads::KEYED_KINDS;
mod segment_table;
pub use kind_heads::KindHead;
pub use kind_index::{DIR as KIND_INDEX_DIR, INDEXED_KINDS, carry_copy as carry_kind_index};
use segment_table::SegmentList;
mod fork_view;
pub use fork_view::{
    ForkView, HISTORY_KINDS, HistoryFence, HistoryRef, HistoryWriter, fence_history,
    folder_to_replace,
};
mod log_bytes;
pub use log_bytes::{
    LogChunk, LogFilter, LogMark, LogMarks, LogPart, STAMP as LOG_STAMP, line_seq as log_line_seq,
};
mod meta_parts;
pub use meta_parts::PARTS_FILE;
pub(crate) use meta_parts::to_writer_without_parts;
mod shared_value;
mod text_index;
pub use shared_value::{SharedRows, SharedText, SharedValue};

mod session_records;
pub use session_records::{
    ApprovedPlan, AwayRecap, CapacityFallback, EventRecord, ForkBefore, ForkRequest, ForkStart,
    LastReturn, NewestWindow, SessionStatus, TerminalDriver, TerminalInput, WaitReason,
    WatchedTurn, Watching,
};

mod session_meta;
pub use session_meta::{
    AuthChange, ColdPreview, CreatedBy, CreatorKind, Lineage, PreviewMessage,
    RETIRED_AGENT_SESSION_IDS, SessionMeta, StartLevel, SubagentForkOf, SubsessionLimits,
    SubsessionLink, ToolInventory, ToolRow, TurnUsage,
};

/// One chat store root a spawn's env named: `harness` is a chat index
/// adapter id (`claude-code`, `codex`, ...) or, for a profile's own `sessions`
/// roots, the profile id. Never carries other env values.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct HarnessRoot {
    pub harness: String,
    pub path: PathBuf,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Tag {
    pub value: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<u64>,
}

pub const META_SCHEMA: &str = "acpmux.session.v1";

pub fn now_ms() -> u64 {
    #[cfg(test)]
    if let Some(now) = test_clock::followed_now_ms() {
        return now;
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    #[cfg(test)]
    let now = now + test_clock::ahead_ms();
    now
}

/// Compressed time for tests (`stress/`): this thread's [`now_ms`] runs ahead of the wall clock
/// by what it was moved, so a day of timestamps passes in a loop. Other threads see wall time.
/// Followed (`follow_tokio`), it is the wall time at the follow plus tokio's ticked time, never
/// the real time since.
#[cfg(test)]
pub(crate) mod test_clock;

pub trait Store: Send + Sync {
    fn list(&self) -> Result<Vec<SessionMeta>>;
    /// The chats whose metadata the last `list` found and could not read, so left out. A caller
    /// that must know every chat (a delete that writes each fork's history in first) reads these
    /// again. None for a store that leaves none out.
    fn unlisted(&self) -> Vec<String> {
        Vec::new()
    }
    fn load(&self, id: &str) -> Result<Option<SessionMeta>>;
    /// One startup entry, with the same visibility rules as `list`. Raw `load` may still
    /// return a purged chat's late metadata save for recovery/maintenance callers.
    fn load_startup(&self, id: &str) -> Result<Option<SessionMeta>> {
        self.load(id)
    }
    fn save(&self, meta: &SessionMeta) -> Result<()>;
    /// `save` of a kept change ([`ShowAfter::Written`]: a draft, a name): with the event journal, a
    /// line that shows it waits only for its record's write, not its sync. Without the journal
    /// there is no gate, and this is `save`.
    fn save_kept(&self, meta: &SessionMeta) -> Result<()> {
        self.save(meta)
    }
    fn append(&self, id: &str, record: &EventRecord) -> Result<()>;
    /// Flush one session's event log and metadata to stable storage.
    ///
    /// The default is sufficient for memory stores and older implementations; local stores
    /// override it to sync the segment and its containing directories.
    fn flush_session(&self, _id: &str) -> Result<()> {
        self.flush()
    }
    /// v2's raw source (`hub/v1_source.rs`, `store/log_bytes.rs`): chat `id`'s lines from seq
    /// `from` that `filter` keeps, whole and as written, at most one chunk of them (or one line
    /// when a line is larger), into `out`, read under count `stamp` with `marks`. A store that
    /// holds parsed records writes each as its line.
    fn read_log(
        &self,
        id: &str,
        from: u64,
        filter: LogFilter<'_>,
        _stamp: u64,
        marks: &mut LogMarks,
        out: &mut Vec<u8>,
    ) -> Result<LogChunk> {
        use acpmux_core::chat::source::CHUNK_BYTES;
        out.clear();
        marks.clear();
        let mut chunk = LogChunk { next: from, at_end: true, read: 0 };
        let mut failed = None;
        self.scan(id, from.saturating_sub(1), &mut |record| {
            if record.seq < from {
                return true;
            }
            if record.seq > filter.through {
                return false;
            }
            if filter.kinds.is_some_and(|kinds| !kinds.contains(&record.kind.as_str())) {
                return true;
            }
            let line = match serde_json::to_vec(&record) {
                Ok(line) => line,
                Err(e) => {
                    failed = Some(e);
                    return false;
                }
            };
            if !out.is_empty() && out.len() + line.len() + 1 > CHUNK_BYTES {
                chunk.at_end = false;
                return false;
            }
            out.extend_from_slice(&line);
            out.push(b'\n');
            chunk.next = record.seq.saturating_add(1);
            true
        })?;
        if let Some(e) = failed {
            return Err(e.into());
        }
        chunk.read = out.len() as u64;
        Ok(chunk)
    }
    /// v2's `RawSource::read_at`: at most `max` bytes of chat `id`'s line at seq `seq`, from
    /// `offset` in it, into `out`, read under count `stamp` with `marks`; and whether the line
    /// ends there. A store whose lines are files reads that part alone; this default reads the
    /// line whole through `read_log`.
    #[allow(clippy::too_many_arguments)]
    fn read_log_part(
        &self,
        id: &str,
        seq: u64,
        offset: u64,
        max: usize,
        stamp: u64,
        marks: &mut LogMarks,
        out: &mut Vec<u8>,
    ) -> Result<LogPart> {
        let chunk = self.read_log(id, seq, LogFilter::ALL, stamp, marks, out)?;
        let line = out.iter().position(|b| *b == b'\n').unwrap_or(out.len());
        out.truncate(line);
        if log_line_seq(out) != Some(seq) {
            anyhow::bail!("chat {id} holds no line at seq {seq}");
        }
        let start = usize::try_from(offset).unwrap_or(usize::MAX).min(line);
        let end = start.saturating_add(max).min(line);
        out.copy_within(start..end, 0);
        out.truncate(end - start);
        Ok(LogPart { ends: end == line, read: chunk.read })
    }
    /// Chat `id`'s count of changes to lines already written (`store/log_bytes.rs`): 0 for a
    /// store whose lines never change.
    fn log_stamp(&self, _id: &str) -> Result<u64> {
        Ok(0)
    }
    /// Adds `by` to chat `id`'s count: its lines read differently from now.
    fn bump_log_stamp(&self, _id: &str, _by: u64) -> Result<()> {
        Ok(())
    }
    /// Chat `id`'s log durable through `seq`: v2's book is never ahead of its raw.
    fn sync_log_through(&self, id: &str, _seq: u64) -> Result<()> {
        self.flush_session(id)
    }
    /// Events with `seq > after`, at most `limit`.
    fn events(&self, id: &str, after: u64, limit: usize) -> Result<Vec<EventRecord>>;
    /// Visit records with `seq > after` in order until `visit` returns false.
    fn scan(&self, id: &str, after: u64, visit: &mut dyn FnMut(EventRecord) -> bool) -> Result<()> {
        for rec in self.events(id, after, usize::MAX)? {
            if !visit(rec) {
                break;
            }
        }
        Ok(())
    }
    /// `scan` for a reader that wants only some records: a line `may_match` is false for holds
    /// none of them, and a file store passes it without parsing it (a store that holds parsed
    /// records may ignore it; `visit` still decides on the rest). A subagent pane's read of an
    /// old subagent passed a long chat's every later line through a parse, on each of its pages.
    fn scan_matching(
        &self,
        id: &str,
        after: u64,
        _may_match: &dyn Fn(&[u8]) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan(id, after, visit)
    }
    /// `scan`, but a record that cannot be read (a torn or malformed line) is an error instead of
    /// being skipped: a reader that must see every record (the full-access bound's readback of a
    /// left host, #23322) learns that it did not. A memory store holds only whole records.
    fn scan_strict(
        &self,
        id: &str,
        after: u64,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan(id, after, visit)
    }
    /// [`Store::scan_back`] for a read whose `skip` passes only kinds in [`INDEXED_KINDS`] (a
    /// page of prompts, the queue, turn results): a file store reads a segment's copy of those
    /// kinds where the copy is good (`store/kind_index.rs`), and the segment itself back from its
    /// end where it is not, so the read never costs more than `scan_back`'s and stops where it
    /// does. Every other store reads as `scan_back`.
    fn scan_back_indexed(
        &self,
        id: &str,
        after: u64,
        before: u64,
        skip: &dyn Fn(&[u8], &[u8]) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_back(id, after, before, skip, visit)
    }
    /// Visit records with `after < seq < before` newest first until `visit`
    /// returns false: the reverse of `scan`, for pages taken from the end.
    /// `skip(dir, kind)` true says a record is surely not wanted: a file store
    /// passes such a line without parsing it (a store that holds parsed
    /// records may ignore it; `visit` still decides on the rest).
    fn scan_back(
        &self,
        id: &str,
        after: u64,
        before: u64,
        skip: &dyn Fn(&[u8], &[u8]) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        let mut found = Vec::new();
        self.scan(id, after, &mut |rec| {
            if rec.seq >= before {
                return false;
            }
            if !skip(rec.dir.as_bytes(), rec.kind.as_bytes()) {
                found.push(rec);
            }
            true
        })?;
        for rec in found.into_iter().rev() {
            if !visit(rec) {
                break;
            }
        }
        Ok(())
    }
    /// How many records follow `after`, and the last one's `seq` (`after` when none): the
    /// catch-up of a log that ran ahead of its saved meta. A file store reads only the tail
    /// past `after`, never the whole log (daemon start, 2026-10-20).
    fn tail_after(&self, id: &str, after: u64) -> Result<(u64, u64)> {
        let mut count = 0;
        let mut last = after;
        self.scan(id, after, &mut |rec| {
            count += 1;
            last = last.max(rec.seq);
            true
        })?;
        Ok((count, last))
    }
    /// Where the newest `n` records before seq `before` start ([`NewestWindow`]): a replay that
    /// may send only `n` records sends the newest ones (`session/load`), not the oldest. A file
    /// store reads the lines' seqs back from the end and parses none, so the answer costs `n`
    /// lines however long the log is.
    fn newest_window(&self, id: &str, before: u64, n: u64) -> Result<NewestWindow> {
        newest_window_by_scan(self, id, before, n)
    }
    /// `scan` from the start, visiting only records whose `kind` is in `kinds`. A file store
    /// parses no other line (the queue restore at daemon start reads its few kinds out of
    /// logs that are mostly agent output).
    fn scan_kinds(
        &self,
        id: &str,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan(id, 0, &mut |rec| {
            if kinds.contains(&rec.kind.as_str()) { visit(rec) } else { true }
        })
    }
    /// `scan_kinds`, but strict as `scan_strict` is: a record that cannot be read is an error. A
    /// file store reads a segment's copy of its kinds (`store/kind_index.rs`) only when every line
    /// the copy covers read whole.
    fn scan_kinds_strict(
        &self,
        id: &str,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_strict(id, 0, &mut |rec| {
            if kinds.contains(&rec.kind.as_str()) { visit(rec) } else { true }
        })
    }
    /// `scan_kinds` of the records past `after` only: a log load that begins at a restore point
    /// (`hub/restore_point.rs`). A file store reads from the segment that holds `after + 1`.
    fn scan_kinds_after(
        &self,
        id: &str,
        after: u64,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        if after == 0 {
            return self.scan_kinds(id, kinds, visit);
        }
        self.scan(id, after, &mut |rec| {
            if kinds.contains(&rec.kind.as_str()) { visit(rec) } else { true }
        })
    }
    /// `scan_kinds_after`, strict as `scan_kinds_strict` is.
    fn scan_kinds_after_strict(
        &self,
        id: &str,
        after: u64,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        if after == 0 {
            return self.scan_kinds_strict(id, kinds, visit);
        }
        self.scan_strict(id, after, &mut |rec| {
            if kinds.contains(&rec.kind.as_str()) { visit(rec) } else { true }
        })
    }
    /// `scan_kinds`, visiting only the records whose head (`store/kind_heads.rs`) `keep` keeps,
    /// shown in order: a caller that wants one prompt's few records out of a chat's many says so,
    /// and a file store reads and parses no other once it knows the chat's heads. `keep` may
    /// keep more than the caller needs (an unread head, a list of prompts), never fewer, and may
    /// be shown a head more than once (a fork's join, a segment read again whole).
    fn scan_kinds_keyed(
        &self,
        id: &str,
        kinds: &[&str],
        keep: &mut dyn FnMut(&KindHead<'_>) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_kinds(id, kinds, &mut |rec| {
            let kept = keep(&KindHead::of(&rec));
            !kept || visit(rec)
        })
    }
    /// The restore point `id`'s last log load saved (`hub/restore_point.rs`), as saved. None in a
    /// store that keeps none.
    fn restore_point(&self, _id: &str) -> Option<Vec<u8>> {
        None
    }
    /// Saves `bytes` as `id`'s restore point, whole or not at all. A store that keeps none
    /// drops it.
    fn save_restore_point(&self, _id: &str, _bytes: &[u8]) -> Result<()> {
        Ok(())
    }
    /// Records used by the whole-store search, including an archive without thawing it.
    fn search_records(&self, id: &str, visit: &mut dyn FnMut(EventRecord)) -> Result<()> {
        self.scan_kinds(id, crate::session_search::KINDS, &mut |rec| {
            visit(rec);
            true
        })
    }

    /// Use the warm text index, or stream the messages out of an archived log.
    fn conversation_entries(
        &self,
        id: &str,
        visit: &mut dyn FnMut(crate::session_search::Entry),
    ) -> Result<()> {
        if self.is_cold(id) {
            crate::session_search::project_records(|feed| self.search_records(id, feed), visit)
        } else {
            self.text_entries(id, visit)
        }
    }

    /// `scan` from the start, passing each record's head ([`RecordHead`]) until `visit` returns
    /// false; the reader parses only the records it needs (`RecordHead::record`). A file store
    /// reads a head without parsing its line: adopting a host after a restart reads its whole
    /// log four times, and parsing every line held big-red's daemon at a full core for minutes.
    fn scan_heads(&self, id: &str, visit: &mut dyn FnMut(&RecordHead<'_>) -> bool) -> Result<()> {
        self.scan(id, 0, &mut |rec| visit(&RecordHead::parsed(&rec)))
    }
    /// `scan_heads` of the records from `from` on, each with where its line is ([`LinePos`]) in
    /// a store that knows: an adoption that resumes from its checkpoint
    /// (`hub/hosts/checkpoint.rs`). `hint` is where the line of `from` was; a file store reads
    /// from there, when that line still holds `from`, and from the segment that holds `from`
    /// otherwise. Never more records than `scan_heads`, never fewer past `from`.
    fn scan_heads_from(
        &self,
        id: &str,
        from: u64,
        _hint: Option<LinePos>,
        visit: &mut dyn FnMut(&RecordHead<'_>, Option<LinePos>) -> bool,
    ) -> Result<()> {
        self.scan_heads(id, &mut |head| head.seq < from || visit(head, None))
    }
    /// The adoption checkpoint of `id` (`hub/hosts/checkpoint.rs`), as saved. None in a store
    /// that keeps none.
    fn adoption_checkpoint(&self, _id: &str) -> Option<Vec<u8>> {
        None
    }
    /// Saves `bytes` as `id`'s adoption checkpoint, whole or not at all. A store that keeps none
    /// drops it.
    fn save_adoption_checkpoint(&self, _id: &str, _bytes: &[u8]) -> Result<()> {
        Ok(())
    }
    /// The log's messages (`session_search.rs`), oldest first. A file store reads each segment's
    /// text copy (`store/text_index.rs`) and only the bytes appended past it.
    fn text_entries(
        &self,
        id: &str,
        visit: &mut dyn FnMut(crate::session_search::Entry),
    ) -> Result<()> {
        let mut projector = crate::session_search::Projector::default();
        self.scan_kinds(id, crate::session_search::KINDS, &mut |rec| {
            projector.feed(&rec);
            true
        })?;
        projector.entries.into_iter().for_each(visit);
        Ok(())
    }
    /// Make every appended record durable (called on shutdown).
    fn flush(&self) -> Result<()> {
        Ok(())
    }
    /// Waits up to `timeout` until every record appended so far is durable; false when the time
    /// ran out. For tests and tools: a request never blocks on the disk. The Local and Memory
    /// stores do not sync an append, so they return true at once (their appends are as durable
    /// as they will be until `flush`).
    fn wait_durable(&self, timeout: std::time::Duration) -> Result<bool> {
        let _ = timeout;
        Ok(true)
    }
    /// How durable its appends are (`server/durable_gate.rs`). None: appends are not journaled,
    /// and no connection waits for them.
    fn durability(&self) -> Option<Durability> {
        None
    }
    /// Why the store asks the daemon to stop with a restart, as it changes: `Some(reason)` once
    /// the store cannot go on safely (the journal store's frozen checkpoint, whose logs only a
    /// restart's replay writes again). None: a store that never asks.
    fn stop_reason(&self) -> Option<tokio::sync::watch::Receiver<Option<String>>> {
        None
    }
    /// The daemon's shutdown is done: from now on every write is refused. It lets go of
    /// `daemon.lock` before its process exits, so the next daemon may already read this store;
    /// what it reads is the old daemon's last word (`Hub::shutdown_all`). Waits for writes under
    /// way.
    fn seal(&self) {}
    /// Close the session's log until it is next written (a closed session's).
    fn close_log(&self, _id: &str) {}
    /// Retention (`store/compact.rs`): the log's last `seq` when it was last compacted.
    fn compacted_seq(&self, _id: &str) -> Option<u64> {
        None
    }
    /// Retention: when the log was last written, in ms, from its newest segment. None: the store
    /// keeps no log on disk, or the chat has none.
    fn log_written_at(&self, _id: &str) -> Option<u64> {
        None
    }
    /// Reads the log and, unless a dry run, writes its compacted segments beside it. None: the
    /// store keeps no log on disk, or the chat has none.
    fn stage_compaction(&self, _id: &str, _mode: CompactMode) -> Result<Option<Staged>> {
        Ok(None)
    }
    /// Puts a staged compaction in place unless the log changed since (false). The caller holds
    /// the chat's append lock.
    fn commit_compaction(&self, _id: &str, _staged: Staged) -> Result<bool> {
        Ok(false)
    }
    /// Leaves out every record of chat `id` past `after`, in place (`CompactMode::Truncate`):
    /// false when the log changed meanwhile, or the store cannot. Its caller holds the chat's
    /// append lock. A journal restore's only (`hub/journal_restore.rs`).
    fn truncate_after(&self, id: &str, after: u64) -> Result<bool> {
        match self.stage_compaction(id, CompactMode::Truncate { after })? {
            Some(staged) => self.commit_compaction(id, staged),
            None => Ok(false),
        }
    }
    /// Keeps `kept`, the records chat `id` keeps while a journal restore holds it
    /// (`hub/restore_writer.rs`), whole and durably beside its log, in place of what it kept
    /// before; None removes them. They take no seq: the restore needs the seqs past the log's
    /// end. Done only when it answers Ok. A store that keeps nothing across a restart keeps
    /// nothing here.
    fn keep_parked(&self, _id: &str, _kept: Option<&[u8]>) -> Result<()> {
        Ok(())
    }
    /// What [`Store::keep_parked`] last kept for chat `id`.
    fn kept_parked(&self, _id: &str) -> Result<Option<Vec<u8>>> {
        Ok(None)
    }
    /// Keeps `held`, the body of a tool output snapshot or turn diff chat `id` holds back from
    /// its log (`store/deferred.rs`), as slot `slot` (lowercase hex, `Deferral::slot`) beside the
    /// log, in place of what the slot kept; None removes it, and a slot with nothing is Ok. The
    /// body is kept before its stub is logged, so the next start stores what a killed daemon held
    /// (`Hub::take_back_held`). Not synced: a kill keeps it, a power cut may not. Never makes a
    /// chat's folder that is gone. A store that keeps nothing across a restart keeps nothing here.
    fn keep_held(&self, _id: &str, _slot: &str, _held: Option<&[u8]>) -> Result<()> {
        Ok(())
    }
    /// What [`Store::keep_held`] keeps for chat `id`: each slot and its bytes, in no order.
    fn kept_held(&self, _id: &str) -> Result<Vec<(String, Vec<u8>)>> {
        Ok(Vec::new())
    }
    /// Writes a cold archive of `id`'s log beside it and checks it (`store/cold.rs`); None
    /// without a log to archive, or for a store that keeps none.
    fn stage_cold(&self, _id: &str) -> Result<Option<StagedCold>> {
        Ok(None)
    }
    /// Puts `staged` in place of the log, unless the log changed since (false). The caller holds
    /// the chat's append lock.
    fn commit_cold(&self, _id: &str, _staged: StagedCold) -> Result<bool> {
        Ok(false)
    }
    /// Puts a cold-archived chat's log back; false when it was not archived. Any read of the log
    /// does this on its own; the hub calls it to open a chat on purpose.
    fn rehydrate(&self, _id: &str) -> Result<bool> {
        Ok(false)
    }
    /// The chat's log is in its cold archive. A few `lstat`s, no read.
    fn is_cold(&self, _id: &str) -> bool {
        false
    }
    /// Moves a cold-archived chat's archive to the person's cloud history store (opt-in,
    /// `cmux-session-cloud`), leaving a stub; its next read fetches it back. The bytes freed, or
    /// None when the chat is not archived here, cloud history is off, or the archive changed.
    fn offload_cold(&self, _id: &str) -> Result<Option<u64>> {
        Ok(None)
    }
    /// Registers this machine's cloud history GC root: one tree naming the blob of every chat
    /// offloaded here, so the store keeps them (roots expire unless registered again within 90
    /// days). Call it after a batch of offloads, not per chat. The blobs named, or None when cloud
    /// history is off.
    fn register_cloud_root(&self) -> Result<Option<usize>> {
        Ok(None)
    }
    /// Called with a chat's id each time its log comes back from its cold archive, on any path
    /// (a read, an append, a fork's history): the hub drops the chat's preview
    /// (`hub/cold_archive.rs`). Called inside the store's own locks: it must take none of its
    /// own that a store caller may hold. Set once.
    fn on_rehydrate(&self, _hook: RehydrateHook) {}
    /// Writes and checks the archives of at most `max` of `id`'s sealed segments still hot, at
    /// zstd `level`, beside them (`store/cold_segments.rs`). None: nothing to move, or a store
    /// that keeps no segments.
    fn stage_cold_segments(
        &self,
        _id: &str,
        _max: usize,
        _level: i32,
    ) -> Result<Option<StagedColdSegments>> {
        Ok(None)
    }
    /// Readies the store for a cold segments' commit, with no lock of the chat held: the journal
    /// store's checkpoint must cover every line of them. False: not now.
    fn prepare_cold_segments(&self, _id: &str, _staged: &StagedColdSegments) -> Result<bool> {
        Ok(true)
    }
    /// Puts staged archives in place of their segments, each unless it changed since. The caller
    /// holds the chat's append lock. What it moved.
    fn commit_cold_segments(&self, _id: &str, _staged: StagedColdSegments) -> Result<ColdMoved> {
        Ok(ColdMoved::default())
    }
    /// Finishes what a crash left of a move of `id`'s segments (`store/cold_segments.rs`).
    fn settle_cold_segments(&self, _id: &str) -> Result<()> {
        Ok(())
    }
    /// Brings every cold segment of `id` back to a plain `.ndjson`, each checked against its
    /// index's SHA-256 before it goes in place (`store/cold_segments.rs`, `cmux chats warm`).
    fn warm_cold_segments(&self, _id: &str) -> Result<ColdWarmed> {
        Ok(ColdWarmed::default())
    }
    /// Called with a chat's id when its log seals a segment (rolls over to the next), under the
    /// store's writers' lock: it may only note the id and wake a worker. Set once.
    fn on_segment_sealed(&self, _hook: SealHook) {}
    /// Called with a chat's id each time its log grows past another [`GROWN_EVERY`] bytes
    /// (`hub/pack_as_it_grows.rs`), on the appending thread after the write, outside the store's
    /// writers' and segment's locks (the caller's append lock may be held): it may only note the
    /// id and wake a worker. Set once.
    fn on_log_grown(&self, _hook: SealHook) {}
    fn delete(&self, id: &str) -> Result<()>;
    fn session_dir(&self, _id: &str) -> Option<PathBuf> {
        None
    }
    /// The chat's folder path only, for a caller that needs the path or its parent and reads or
    /// moves none of the chat's own files: no lock, no wait, no write. `session_dir` is for code
    /// that reads or moves them (the journal store writes the chat's metadata first).
    fn session_path(&self, id: &str) -> Option<PathBuf> {
        self.session_dir(id)
    }
    /// Where handoff records live: `handoffs/` beside `sessions/`, or none
    /// (in memory) for the memory store.
    fn handoff_dir(&self) -> Option<PathBuf> {
        None
    }
    /// Where each peer's last-known sessions are saved: `peers/` beside
    /// `sessions/`, or none (in memory) for the memory store.
    fn peer_cache_dir(&self) -> Option<PathBuf> {
        None
    }
    /// Where the brief and task ledger is saved (`hub/dispatch.rs`): `briefs.json` beside
    /// `sessions/`, or none (in memory) for the memory store, so a hub's tasks always name
    /// sessions of its own store.
    fn briefs_path(&self) -> Option<PathBuf> {
        None
    }
    /// Whether [`Store::history_writer`] can write a fork's history into its log
    /// (`store/fork_view.rs`). False: forks copy their history as records.
    fn writes_history(&self) -> bool {
        false
    }
    /// Names `fork` a fork of `reference` before its meta is saved, so a delete or compaction of
    /// the chat from now on writes the history into it first (`store/fork_view.rs`). An error:
    /// the chat is gone.
    fn reserve_reference(&self, _fork: &str, _reference: &HistoryRef) -> Result<()> {
        Ok(())
    }
    /// Takes back a [`Store::reserve_reference`] of a fork that was not made.
    fn forget_reference(&self, _fork: &str) {}
    /// Before `id`'s folder is replaced whole (a chat moved back here) or removed: every fork that
    /// references its history holds that history itself first, and no new fork references it
    /// until [`Store::end_release`] (review of #37020). Use [`fence_history`].
    fn release_history(&self, _id: &str) -> Result<()> {
        Ok(())
    }
    /// Ends one [`Store::release_history`].
    fn end_release(&self, _id: &str) {}
    /// A writer of the history a fork referenced, as its log's first segment. None: this store
    /// writes none ([`Store::writes_history`]).
    fn history_writer(&self, _id: &str) -> Result<Option<Box<dyn HistoryWriter + '_>>> {
        Ok(None)
    }
    /// Where the approvals audit trail is kept (`hub/audit_log.rs`): `audit/` beside
    /// `sessions/`, or none (in memory) for the memory store.
    fn audit_dir(&self) -> Option<PathBuf> {
        None
    }
}

/// [`Store::newest_window`] by `scan_back`, for a store with no cheaper read of its seqs.
pub(crate) fn newest_window_by_scan<S: Store + ?Sized>(
    store: &S,
    id: &str,
    before: u64,
    n: u64,
) -> Result<NewestWindow> {
    let mut window = NewestWindow::default();
    let mut seen = 0u64;
    store.scan_back(id, 0, before, &|_, _| false, &mut |rec| {
        window.newest = window.newest.max(rec.seq);
        seen += 1;
        if seen > n {
            window.after = rec.seq;
            return false;
        }
        true
    })?;
    Ok(window)
}

mod log_line;
pub use log_line::RecordHead;

/// Where a log line is: its segment's number and the byte offset its line starts at
/// (`Store::scan_heads_from`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct LinePos {
    pub segment: u32,
    pub offset: u64,
}

#[cfg(test)]
pub(crate) use log_line::PARSED_LINES;

use log_line::{
    first_seq, for_each_line_rev, for_each_line_rev_between, for_each_line_rev_from, offset_of_seq,
    parse_record, record_dir, record_kind, record_seq, start_of_seq,
};

pub fn open(config: &StoreConfig, root: &Path) -> Result<Box<dyn Store>> {
    Ok(match config.mode {
        StoreMode::Memory => Box::new(MemoryStore::default()),
        StoreMode::Local => Box::new(journal_store::JournalStore::open(
            config,
            root,
            std::sync::Arc::new(journal_store::FencedStorage::daemon()),
            cmux_journal::Config::default(),
        )?),
    })
}

/// Writes the event journal a run left in `home`, if any, into that home's logs and
/// `session.json` files, checkpoints it and retires its records: afterwards the home's `sessions/`
/// hold every acknowledged change on their own. For code that moves or merges a home's chat
/// folders without a daemon (the build adoption, `cmux-tui`'s `build_adopt`): a daemon that
/// stopped without a shutdown leaves changes only its journal holds (a new chat's `session.json`
/// is written by a checkpoint). Nothing to do without a journal. No daemon may run in `home`: the
/// caller holds its `daemon.lock`.
pub fn catch_up_journal(config: &StoreConfig, home: &Path) -> Result<()> {
    journal_store::catch_up(config, home)
}

mod durability;
pub use durability::{Durability, FULL_WAIT, ShowAfter};
pub(crate) use durability::{RecordClass, record_class, streamed};
mod journal_store;
#[cfg(test)]
pub(crate) use journal_store::open_with_journal;
#[cfg(test)]
pub(crate) use journal_store::{DISK_RESERVE, set_test_free};
mod log_sync;
mod segment_writer;
pub use segment_writer::GROWN_EVERY;
use segment_writer::SegmentWriter;
pub mod open_logs;
#[cfg(test)]
pub(crate) use journal_store::{
    hold_next_read_fence_on_this_thread, pause_next_log_write_on_this_thread,
};
pub(crate) use log_sync::SyncFailed;
#[cfg(all(test, unix))]
mod sync_model;

mod memory;
pub use memory::MemoryStore;
#[cfg(test)]
pub(crate) use memory::{COPY_FORKS, REFUSE_APPENDS};

// ----------------------------------------------------------------- local

/// A chat's restore point, beside its `session.json` (`hub/restore_point.rs`).
const RESTORE_POINT: &str = "restore-point.json";
/// A chat's adoption checkpoint, beside its `session.json` (`hub/hosts/checkpoint.rs`).
const ADOPTION_CHECKPOINT: &str = "adoption-checkpoint.json";

/// `path`'s bytes, read in the held home (`None` when it is missing or unreadable).
fn held_file_bytes(path: &Path) -> Option<Vec<u8>> {
    let mut bytes = Vec::new();
    crate::home_fs::private_state_file(path).ok()?.read_to_end(&mut bytes).ok()?;
    Some(bytes)
}

pub struct LocalStore {
    root: PathBuf,
    segment_bytes: u64,
    writers: Mutex<Writers>,
    /// The most logs held open ([`open_logs`]).
    open_logs: usize,
    /// Read-held by every write, true once `seal` ran: a write either lands before the seal
    /// returns or not at all.
    sealed: std::sync::RwLock<bool>,
    /// A log's sync on its close failed (`SegmentWriter::close`): its lines may be lost on the
    /// disk. The journal store then keeps every line in its journal (`store/journal_store.rs`).
    sync_failed: std::sync::atomic::AtomicBool,
    /// [`Store::unlisted`]: folders whose `session.json` is there and did not read.
    unlisted: Mutex<std::collections::BTreeSet<String>>,
    /// One lock per chat ([`cold::ChatLocks`]), held by every change that removes one of the
    /// chat's log's copies: a cold archive's commit, a rehydrate and its settle
    /// (`store/cold.rs`), and a cold segment's commit, warm and settle
    /// (`store/cold_segments.rs`). Always after the writers' lock when both are taken: two reads
    /// of an archived chat rehydrate it once.
    cold: cold::ChatLocks,
    /// What this store's temporary cold-segment files carry in their names
    /// (`store/cold_segments.rs`): a settle removes only those of another store, a crash's,
    /// never one a move or warm of this store is writing (#43562 review F1).
    cold_tag: String,
    /// [`Store::on_rehydrate`].
    rehydrate_hook: std::sync::OnceLock<RehydrateHook>,
    /// [`Store::on_segment_sealed`].
    seal_hook: std::sync::OnceLock<SealHook>,
    /// [`Store::on_log_grown`].
    grow_hook: std::sync::OnceLock<SealHook>,
    /// The parts files written or read (`store/meta_parts.rs`).
    parts: meta_parts::PartsMemo,
    /// The segments' record heads a keyed scan read (`store/kind_heads.rs`).
    kind_heads: kind_heads::KindHeads,
    /// The copies of segments' indexed kinds the reads checked (`store/kind_index.rs`).
    kind_index_checks: kind_index::Checked,
    /// Each segment's first seq, once read (`store/segment_starts.rs`).
    pub(crate) segment_starts: segment_starts::SegmentStarts,
    segment_table: segment_table::SegmentTable,
    #[cfg(test)]
    pub(crate) meta_saves: std::sync::Arc<std::sync::atomic::AtomicU64>,
}

/// The logs held open, at most `LocalStore::open_logs` (`store/open_logs.rs`): the least
/// recently written one is closed for a new one.
#[derive(Default)]
struct Writers {
    open: HashMap<String, SegmentWriter>,
    /// Counts appends; a writer's `used` is the count at its last one.
    clock: u64,
    /// Each chat's count of changes to lines already written, once read (`store/log_bytes.rs`):
    /// read and bumped only under this lock.
    stamps: HashMap<String, u64>,
}

/// What a chat keeps while a journal restore holds it (`Store::keep_parked`), beside its log.
const PARKED: &str = "parked.json";
/// The folder of a chat's held tool output bodies (`Store::keep_held`), beside its log.
const HELD: &str = "held";

impl LocalStore {
    pub fn new(root: PathBuf, segment_bytes: u64) -> Result<Self> {
        crate::config::private_state_dir(&root)
            .with_context(|| format!("create private store {}", root.display()))?;
        Ok(Self {
            root,
            segment_bytes: segment_bytes.max(64 * 1024),
            writers: Mutex::new(Writers::default()),
            open_logs: open_logs::now(),
            sealed: Default::default(),
            sync_failed: Default::default(),
            unlisted: Default::default(),
            cold: Default::default(),
            cold_tag: format!("{}x{}", std::process::id(), uuid::Uuid::now_v7().simple()),
            rehydrate_hook: Default::default(),
            seal_hook: Default::default(),
            grow_hook: Default::default(),
            parts: Default::default(),
            kind_heads: Default::default(),
            kind_index_checks: Default::default(),
            segment_starts: Default::default(),
            segment_table: Default::default(),
            #[cfg(test)]
            meta_saves: Default::default(),
        })
    }

    /// Held through a write; refused once the store is sealed (`Store::seal`).
    fn writable(&self) -> Result<std::sync::RwLockReadGuard<'_, bool>> {
        let sealed = self.sealed.read().unwrap_or_else(std::sync::PoisonError::into_inner);
        if *sealed {
            anyhow::bail!("the store is sealed: the daemon has shut down");
        }
        Ok(sealed)
    }

    fn dir(&self, id: &str) -> PathBuf {
        self.root.join(id)
    }

    /// The log's segments, in order. A cut a crash or a failure left halfway
    /// (`store/compact.rs` `finish_cut_locked`) is finished first: no reader ever sees a log
    /// whose segments were cut to different ends (review of #37284 at b7496c3f, F2).
    /// The log's segments, oldest first. A cold-archived chat's log is rehydrated first
    /// (`store/cold.rs`): only a chat with no segment pays for the look, one `lstat` and a second
    /// listing. The listing is taken again whatever `rehydrate` answers: another thread's
    /// rehydrate may have put the log back since the first, and this one then answers false
    /// (review of #39141: an append went on in `000001` of a log that ran on past it).
    fn segments(&self, id: &str) -> Result<SegmentList> {
        let (segments, cut_pending) = self.list_segments(id)?;
        if !cut_pending {
            return Ok(segments);
        }
        // A sealed store writes nothing: the next daemon finishes it.
        let Ok(_open) = self.writable() else { return Ok(segments) };
        let mut writers = self.writers.lock_or_recover();
        self.finish_cut_locked(id, &mut writers)?;
        drop(writers);
        Ok(self.list_segments(id)?.0)
    }

    /// The log's segments, in order, as the folder lists them, and whether a cut's intent
    /// (`store/compact.rs` `CUT`) is beside them: read in the same listing, so it costs nothing.
    /// A cold archive's log is rehydrated first (`store/cold.rs`).
    /// Segments zstd'd in place by a tool outside acpmux are decoded back first
    /// (`store/sealed_segments.rs`): the same listing says whether there are any.
    fn list_segments(&self, id: &str) -> Result<(SegmentList, bool)> {
        let (mut segments, mut cut_pending, sealed) = self.listed_files(id)?;
        if sealed {
            match self.thaw_sealed(id) {
                Ok(0) => {}
                Ok(_) => (segments, cut_pending, _) = self.listed_files(id)?,
                Err(e) => tracing::warn!(session = %id, "sealed segments stay sealed: {e:#}"),
            }
        }
        if segments.is_empty() {
            self.rehydrate(id)?;
            let (segments, cut_pending, _) = self.listed_files(id)?;
            return Ok((segments, cut_pending));
        }
        Ok((segments, cut_pending))
    }

    /// The segments on the disk now, never rehydrated.
    fn segment_files(&self, id: &str) -> Result<SegmentList> {
        Ok(self.listed_files(id)?.0)
    }

    /// [`Self::segment_files`], whether a cut's intent is beside them, and whether a segment
    /// zstd'd in place with no plain one of its name is (`store/sealed_segments.rs`).
    fn listed_files(&self, id: &str) -> Result<(SegmentList, bool, bool)> {
        self.segment_table.list(id, &self.dir(id).join("events"))
    }

    fn list_entry(
        &self,
        root: &crate::home_fs::PrivateDir,
        name: &std::ffi::OsStr,
    ) -> Result<Option<SessionMeta>> {
        let entry = match root.entry(name) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            other => other?,
        };
        let session = root.path().join(name);
        anyhow::ensure!(!entry.is_symlink, "session entry {} is a link", session.display());
        if !entry.is_dir {
            return Ok(None);
        }
        let held = self.validate_session_dir(root, name)?;
        let path = session.join("session.json");
        let id = name.to_string_lossy().into_owned();
        let file = match held.private_file(std::ffi::OsStr::new("session.json")) {
            Ok(file) => file,
            Err(error) => {
                if !is_not_found(&error) {
                    self.mark_unlisted(&id, true);
                }
                return Ok(None);
            }
        };
        let mut text = String::new();
        BufReader::new(file).read_to_string(&mut text)?;
        // Only a closed chat can be a purged chat revived by a late save. Open chats need
        // no segment enumeration: that work belongs to their on-demand log read.
        if let Ok(meta) = serde_json::from_str::<StatusOnly>(&text)
            && self.purged_startup_entry(&id, meta.status)?
        {
            return Ok(None);
        }
        match serde_json::from_str::<SessionMeta>(&text) {
            Ok(mut meta) => {
                self.parts.merge_held(&held, text.as_bytes(), &mut meta);
                self.mark_unlisted(&id, false);
                Ok(Some(meta))
            }
            Err(e) => {
                tracing::warn!("skip {}: {e}", path.display());
                self.mark_unlisted(&id, true);
                Ok(None)
            }
        }
    }

    fn mark_unlisted(&self, id: &str, unread: bool) {
        let mut unlisted = self.unlisted.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if unread {
            unlisted.insert(id.to_owned());
        } else {
            unlisted.remove(id);
        }
    }

    /// Exact on-demand reads use the same directory checks as the background list before
    /// trusting metadata or reading any log. In particular, neither directory may be a link.
    fn validate_session_dir(
        &self,
        root: &crate::home_fs::PrivateDir,
        name: &std::ffi::OsStr,
    ) -> Result<crate::home_fs::PrivateDir> {
        let session = root.child(name)?;
        match session.child(std::ffi::OsStr::new("events")) {
            Err(error) if is_not_found(&error) => {}
            Err(error) => return Err(error),
            Ok(_) => {}
        }
        Ok(session)
    }

    fn purged_startup_entry(&self, id: &str, status: SessionStatus) -> Result<bool> {
        Ok(status == SessionStatus::Closed && !self.has_records(id)?)
    }

    /// Whether the session's log holds a record: a segment with a byte in it (no line
    /// is read), or a compaction's record (`store/compact.rs`), which keeps a closed
    /// chat's log however little of it stays. Every session the hub creates logs `created`
    /// right after its first save, so a record without a log is a purged session's that a
    /// late save wrote back.
    /// A cold archive (`store/cold.rs`) is a log too, and is not opened; so is its cloud stub
    /// (an archive offloaded to cloud history), and a segment zstd'd in place
    /// (`store/sealed_segments.rs`), which its first read decodes back.
    fn has_records(&self, id: &str) -> Result<bool> {
        // A home that is no longer the held one is an error, never "no record" (#41721
        // review F1): a closed chat with no record reads as purged.
        if crate::home_fs::try_exists_nofollow(self.marker(id))?
            || crate::home_fs::try_exists_nofollow(self.cold_path(id))?
            || crate::home_fs::try_exists_nofollow(self.cloud_stub_path(id))?
        {
            return Ok(true);
        }
        let (segments, _, sealed) = self.listed_files(id)?;
        if sealed {
            return Ok(true);
        }
        for (_, path) in segments {
            // An unreadable segment counts as a log: the session is listed as before.
            match crate::home_fs::symlink_metadata(&path) {
                Ok(meta) if meta.len() == 0 => {}
                _ => return Ok(true),
            }
        }
        Ok(false)
    }

    fn open_writer(&self, id: &str) -> Result<SegmentWriter> {
        let dir = self.dir(id).join("events");
        crate::config::private_state_dir(&self.dir(id))?;
        crate::config::private_state_dir(&dir)?;
        // Under the writers' lock (`append_line`), which finished any cut left halfway first.
        let (segs, _) = self.list_segments(id)?;
        // Never segment `000000`: it holds only a fork's history, written whole and renamed in
        // place (`history_writer`), which would replace a record appended to it (review of
        // #37020). A log whose only segment it is goes on in `000001`.
        // Nor a cold segment's archive (`store/cold_segments.rs`): the log goes on in the next.
        let (index, path) = match segs.last().filter(|(i, _)| *i > 0) {
            Some((i, p)) if cold_segments::is_cold(p) => {
                (i + 1, dir.join(format!("{:06}.ndjson", i + 1)))
            }
            Some((i, p)) => (*i, p.clone()),
            None => (1, dir.join("000001.ndjson")),
        };
        let file = open_private_append(&path)?;
        let written = cut_torn_tail(&file, &path)?;
        Ok(SegmentWriter::new(index, file, written, 0))
    }
}

fn is_not_found(error: &anyhow::Error) -> bool {
    error.downcast_ref::<std::io::Error>().is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound)
}

/// A session record's status alone, read without the rest of the record.
#[derive(Deserialize)]
struct StatusOnly {
    status: SessionStatus,
}

/// The event logs' write budget per kind (`cmux_tui_platform::write_budget`): a kind past 8 MiB
/// or 20,000 records an hour, or one whose records mostly repeat, is a writer to fix.
static EVENT_LOG_BUDGET: std::sync::LazyLock<cmux_tui_platform::write_budget::WriteBudget> =
    std::sync::LazyLock::new(|| {
        cmux_tui_platform::write_budget::WriteBudget::new(
            "acpmux event log",
            cmux_tui_platform::write_budget::WriteLimits {
                bytes: 8 << 20,
                records: 20_000,
                repeat_percent: 50,
                repeat_floor: 200,
            },
        )
    });

/// Counts `record`, `bytes` on disk, against [`EVENT_LOG_BUDGET`] where budgets count (debug
/// builds, tests, `CMUX_WRITE_BUDGET=1`), and warns once a kind is over.
fn note_write_budget(record: &EventRecord, bytes: usize) {
    if !cmux_tui_platform::write_budget::WriteBudget::enabled() {
        return;
    }
    if let Some(warning) = EVENT_LOG_BUDGET.note(&record.kind, bytes, &record.msg, now_ms()) {
        tracing::warn!("{warning}");
    }
}

/// Cuts the log segment at `path` to `len` bytes, through its own handle opened to write: the
/// writer's handle may only append (Windows grants it `FILE_APPEND_DATA` alone, and a truncate
/// needs `FILE_WRITE_DATA`). The handle gets the same owner-only, no-link checks as every other
/// open of a segment (`journal_store::repair::open_segment_to_write`).
fn cut_back(path: &Path, len: u64) -> Result<()> {
    #[cfg(test)]
    if test_write_fault::take_cut_failure() {
        anyhow::bail!("a failed cut (a test)");
    }
    let file = journal_store::repair::open_segment_to_write(path)?;
    file.set_len(len)?;
    #[cfg(all(test, unix))]
    sync_model::cut(&file, len);
    Ok(())
}

/// Cuts a segment opened for appending back to its last whole line and returns its length
/// after. Every record is written with its newline, so bytes after the last one are a torn
/// append (a process killed mid-write, a full disk): left there, the next record would be glued
/// onto them and lost. They never were a record, so nothing kept is cut.
fn cut_torn_tail(file: &File, path: &Path) -> Result<u64> {
    use std::io::{Seek, SeekFrom};
    let len = file.metadata()?.len();
    if len == 0 {
        return Ok(0);
    }
    let mut reader = crate::config::private_state_file(path)?;
    let mut end = len;
    let mut chunk = vec![0u8; 64 * 1024];
    while end > 0 {
        let start = end.saturating_sub(chunk.len() as u64);
        // `end - start` is at most the chunk length, so `get_mut` always finds the part.
        let want = usize::try_from(end - start)?;
        let Some(part) = chunk.get_mut(..want) else {
            anyhow::bail!("torn-tail read of {want} bytes is past its {} byte chunk", chunk.len());
        };
        reader.seek(SeekFrom::Start(start))?;
        reader.read_exact(part)?;
        if let Some(at) = part.iter().rposition(|b| *b == b'\n') {
            end = start + at as u64 + 1;
            break;
        }
        end = start;
    }
    if end < len {
        tracing::warn!(
            path = %path.display(),
            torn = len - end,
            "cutting a torn append from the end of an event log"
        );
        cut_back(path, end)?;
    }
    Ok(end)
}

#[cfg(debug_assertions)]
pub(crate) mod disk_fault;
#[cfg(test)]
pub(crate) mod test_write_fault;

/// [`LocalStore::history_writer`]'s segment `000000`.
struct SegmentZero {
    /// Taken by `commit`.
    file: Option<std::io::BufWriter<File>>,
    tmp: PathBuf,
    path: PathBuf,
    dir: PathBuf,
}

impl HistoryWriter for SegmentZero {
    fn write(&mut self, record: &EventRecord) -> Result<()> {
        let Some(file) = self.file.as_mut() else { anyhow::bail!("history segment committed") };
        serde_json::to_writer(&mut *file, record)?;
        file.write_all(b"\n")?;
        Ok(())
    }
    fn commit(mut self: Box<Self>) -> Result<()> {
        let Some(file) = self.file.take() else { anyhow::bail!("history segment committed") };
        let file = file.into_inner().map_err(|e| anyhow::anyhow!("{e}"))?;
        file.sync_all()?;
        crate::home_fs::rename(&self.tmp, &self.path)?;
        sync_directory(&self.dir)?;
        // `events/`, and the chat's folder, may be new (a fork with no record of its own yet): the
        // folders that name them are synced too, or a power loss could keep the meta that drops the
        // reference and lose the history it now stands for (review of #37020).
        for made in self.dir.ancestors().skip(1).take(2) {
            sync_directory(made)?;
        }
        Ok(())
    }
}

impl Drop for SegmentZero {
    /// One never committed leaves nothing; a committed one was renamed away.
    fn drop(&mut self) {
        let _ = crate::home_fs::remove_file(&self.tmp);
    }
}

impl Store for LocalStore {
    fn list(&self) -> Result<Vec<SessionMeta>> {
        // No sessions folder yet: no chat. One that is there and does not read is a failed list,
        // never an empty one: an empty list proves every chat gone (`hub/hosts.rs`).
        if !crate::home_fs::try_exists_nofollow(&self.root)? {
            return Ok(Vec::new());
        }
        let root = match crate::home_fs::PrivateDir::open(&self.root) {
            Ok(root) => root,
            Err(error) if is_not_found(&error) => return Ok(Vec::new()),
            Err(error) => return Err(error.context(format!("list {}", self.root.display()))),
        };
        // Only enumeration fails the pass. Entry checks belong to each worker.
        let entries = root.names()?;
        if entries.is_empty() {
            return Ok(Vec::new());
        }
        // Hold the checked store for the pass. Each worker checks only its chats and their
        // events folders, never the same ancestors again.
        let workers = std::thread::available_parallelism().map_or(1, usize::from).min(8);
        std::thread::scope(|scope| {
            let workers: Vec<_> = entries
                .chunks(entries.len().div_ceil(workers))
                .map(|chunk| {
                    let root = &root;
                    scope.spawn(move || {
                        let mut metas = Vec::new();
                        for name in chunk {
                            // One chat that is refused or does not read is left out (and
                            // counted unread), never the reason no chat is listed.
                            match self.list_entry(root, name) {
                                Ok(Some(meta)) => metas.push(meta),
                                Ok(None) => {}
                                Err(e) => {
                                    tracing::warn!(
                                        "skip {}: {e:#}",
                                        root.path().join(name).display()
                                    );
                                    let id = name.to_string_lossy().into_owned();
                                    self.mark_unlisted(&id, true);
                                }
                            }
                        }
                        Ok::<_, anyhow::Error>(metas)
                    })
                })
                .collect();
            let mut metas = Vec::new();
            for worker in workers {
                metas.extend(
                    worker.join().map_err(|_| anyhow::anyhow!("store list worker failed"))??,
                );
            }
            Ok(metas)
        })
    }

    fn unlisted(&self) -> Vec<String> {
        let unlisted = self.unlisted.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        unlisted.iter().cloned().collect()
    }

    fn load(&self, id: &str) -> Result<Option<SessionMeta>> {
        // An absent chat needs only search access, before opening folders for reading.
        if !crate::home_fs::try_exists_nofollow(self.dir(id))? {
            return Ok(None);
        }
        let root = match crate::home_fs::PrivateDir::open(&self.root) {
            Err(error) if is_not_found(&error) => return Ok(None),
            other => other?,
        };
        let held = match self.validate_session_dir(&root, std::ffi::OsStr::new(id)) {
            Err(error) if is_not_found(&error) => return Ok(None),
            other => other?,
        };
        let file = match held.private_file(std::ffi::OsStr::new("session.json")) {
            Err(error) if is_not_found(&error) => return Ok(None),
            other => other?,
        };
        let mut text = String::new();
        BufReader::new(file).read_to_string(&mut text)?;
        let mut meta: SessionMeta = serde_json::from_str(&text)?;
        self.parts.merge_held(&held, text.as_bytes(), &mut meta);
        Ok(Some(meta))
    }

    fn load_startup(&self, id: &str) -> Result<Option<SessionMeta>> {
        let Some(meta) = self.load(id)? else { return Ok(None) };
        if self.purged_startup_entry(id, meta.status)? {
            return Ok(None);
        }
        Ok(Some(meta))
    }

    fn save(&self, meta: &SessionMeta) -> Result<()> {
        #[cfg(test)]
        self.meta_saves.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let _open = self.writable()?;
        let dir = self.dir(&meta.id);
        crate::config::private_state_dir(&dir)?;
        // The large fields only when they changed (`store/meta_parts.rs`), then the rest.
        let parts = self.parts.write(&dir, meta)?;
        let text = meta_parts::to_string_pretty(meta, &parts)?;
        meta_parts::note_written(text.len());
        write_atomic(&dir.join("session.json"), text.as_bytes())
    }

    fn flush_session(&self, id: &str) -> Result<()> {
        let writers = self.writers.lock_or_recover();
        if let Some(writer) = writers.open.get(id) {
            log_sync::sync_segment(writer.file(), true).map_err(SyncFailed)?;
        }
        let session = self.dir(id);
        sync_directory(&session.join("events"))?;
        sync_directory(&session)?;
        sync_directory(&self.root)?;
        Ok(())
    }

    fn append(&self, id: &str, record: &EventRecord) -> Result<()> {
        let mut line = serde_json::to_string(record)?;
        line.push('\n');
        note_write_budget(record, line.len());
        self.append_line(id, line.as_bytes())
    }

    fn read_log(
        &self,
        id: &str,
        from: u64,
        filter: LogFilter<'_>,
        stamp: u64,
        marks: &mut LogMarks,
        out: &mut Vec<u8>,
    ) -> Result<LogChunk> {
        self.read_log_bytes(id, from, filter, stamp, marks, out)
    }

    fn read_log_part(
        &self,
        id: &str,
        seq: u64,
        offset: u64,
        max: usize,
        stamp: u64,
        marks: &mut LogMarks,
        out: &mut Vec<u8>,
    ) -> Result<LogPart> {
        self.read_log_part_bytes(id, seq, offset, max, stamp, marks, out)
    }

    fn log_stamp(&self, id: &str) -> Result<u64> {
        self.read_stamp(id)
    }

    fn bump_log_stamp(&self, id: &str, by: u64) -> Result<()> {
        self.bump_stamp(id, by)
    }

    fn writes_history(&self) -> bool {
        true
    }

    /// Segment `000000`, written beside the log under a temporary name and renamed in whole.
    fn history_writer(&self, id: &str) -> Result<Option<Box<dyn HistoryWriter + '_>>> {
        // An archived log comes back before a segment is written beside it.
        self.rehydrate(id)?;
        #[cfg(test)]
        log_sync::hold(&cold::HOLD_AFTER_HISTORY_REHYDRATE);
        let _open = self.writable()?;
        let dir = self.dir(id).join("events");
        crate::config::private_state_dir(&self.dir(id))?;
        crate::config::private_state_dir(&dir)?;
        let path = dir.join("000000.ndjson");
        let tmp = dir.join("000000.ndjson.history");
        let _ = crate::home_fs::remove_file(&tmp);
        let file = std::io::BufWriter::with_capacity(256 * 1024, open_private_append(&tmp)?);
        Ok(Some(Box::new(SegmentZero { file: Some(file), tmp, path, dir })))
    }

    /// Reads only past `after`: a segment whose successor starts at or before `after + 1`
    /// holds nothing past it and is not opened, and a line at or before `after` is passed
    /// on its `seq` alone, unparsed. A forward page of a long log costs its own records,
    /// not the log's prefix (perf100: a 70 MB log read in 10,000-record pages parsed
    /// every earlier record again on each page).
    fn scan(&self, id: &str, after: u64, visit: &mut dyn FnMut(EventRecord) -> bool) -> Result<()> {
        self.scan_lines(id, after, false, None, visit)
    }

    fn scan_matching(
        &self,
        id: &str,
        after: u64,
        may_match: &dyn Fn(&[u8]) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_lines(id, after, false, Some(may_match), visit)
    }

    fn scan_strict(
        &self,
        id: &str,
        after: u64,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_lines(id, after, true, None, visit)
    }

    /// Reads from `hint` when the line there holds `from` (an adoption's checkpoint: no byte
    /// before it), else from the start of the segment that holds `from`, passing the lines
    /// before `from` on their `seq` alone.
    fn scan_heads_from(
        &self,
        id: &str,
        from: u64,
        hint: Option<LinePos>,
        visit: &mut dyn FnMut(&RecordHead<'_>, Option<LinePos>) -> bool,
    ) -> Result<()> {
        use std::io::{Seek, SeekFrom};
        let segments = self.segments(id)?;
        let mut line = Vec::new();
        let hinted = hint.and_then(|h| {
            let (index, (_, path)) =
                segments.iter().enumerate().find(|(_, (n, _))| *n == h.segment)?;
            let mut reader =
                BufReader::with_capacity(64 * 1024, crate::config::private_state_file(path).ok()?);
            reader.seek(SeekFrom::Start(h.offset)).ok()?;
            line.clear();
            reader.read_until(b'\n', &mut line).ok()?;
            (record_seq(&line) == Some(from)).then_some((index, h.offset, reader))
        });
        let (start, mut first) = match hinted {
            Some((index, offset, reader)) => (index, Some((offset, reader))),
            None => (self.segment_starts.start(id, &segments, from.saturating_sub(1))?, None),
        };
        for (index, path) in segments.get(start..).unwrap_or_default() {
            let (mut pos, mut reader) = match first.take() {
                Some((offset, reader)) => (offset, reader),
                None => {
                    line.clear();
                    let file = crate::config::private_state_file(path)?;
                    (0, BufReader::with_capacity(256 * 1024, file))
                }
            };
            loop {
                // The hinted line was read already.
                let n =
                    if line.is_empty() { reader.read_until(b'\n', &mut line)? } else { line.len() };
                if n == 0 {
                    break;
                }
                let at = LinePos { segment: *index, offset: pos };
                pos += n as u64;
                let more = if line.iter().all(u8::is_ascii_whitespace)
                    || record_seq(&line).is_some_and(|seq| seq < from)
                {
                    true
                } else {
                    match RecordHead::read(&line) {
                        Some(head) => visit(&head, Some(at)),
                        None => match parse_record(&line) {
                            Ok(rec) if rec.seq >= from => {
                                visit(&RecordHead::parsed(&rec), Some(at))
                            }
                            _ => true,
                        },
                    }
                };
                line.clear();
                if !more {
                    return Ok(());
                }
            }
        }
        Ok(())
    }

    /// None once the log was compacted since it was saved: a compaction cuts records' strings
    /// in place (`store/compact.rs`), which a fold of them would read differently. The file's
    /// first line is the digest of the compaction marker it was saved under.
    fn adoption_checkpoint(&self, id: &str) -> Option<Vec<u8>> {
        let bytes = held_file_bytes(&self.dir(id).join(ADOPTION_CHECKPOINT))?;
        let nl = bytes.iter().position(|&b| b == b'\n')?;
        let (head, body) = bytes.split_at(nl);
        (head == self.compaction_digest(id).as_bytes())
            .then(|| body.get(1..).unwrap_or_default().to_vec())
    }

    fn save_adoption_checkpoint(&self, id: &str, bytes: &[u8]) -> Result<()> {
        let _open = self.writable()?;
        let dir = self.dir(id);
        // As `save_restore_point`: a chat whose folder went away gets no file of its own again.
        let folder = crate::home_fs::symlink_metadata(&dir).is_ok_and(|m| m.file_type().is_dir());
        anyhow::ensure!(folder, "no folder for {id}");
        let mut file = self.compaction_digest(id).into_bytes();
        file.push(b'\n');
        file.extend_from_slice(bytes);
        write_atomic(&dir.join(ADOPTION_CHECKPOINT), &file)
    }

    /// Reads each line's head (`RecordHead::read`) and parses only the lines the reader asks
    /// for, or a line whose head does not read.
    fn scan_heads(&self, id: &str, visit: &mut dyn FnMut(&RecordHead<'_>) -> bool) -> Result<()> {
        let mut line = Vec::new();
        let mut pass = crate::perf_watch::LogPass::start(id, true);
        for (_, path) in self.segments(id)? {
            let mut reader =
                BufReader::with_capacity(256 * 1024, cold_segments::open_segment(&path)?);
            loop {
                line.clear();
                if reader.read_until(b'\n', &mut line)? == 0 {
                    break;
                }
                crate::perf_watch::LogPass::line(&mut pass, line.len());
                if line.iter().all(u8::is_ascii_whitespace) {
                    continue;
                }
                let more = match RecordHead::read(&line) {
                    Some(head) => visit(&head),
                    None => {
                        let Ok(rec) = parse_record(&line) else { continue };
                        visit(&RecordHead::parsed(&rec))
                    }
                };
                if !more {
                    return Ok(());
                }
            }
        }
        Ok(())
    }

    fn tail_after(&self, id: &str, after: u64) -> Result<(u64, u64)> {
        let mut count = 0;
        let mut last = after;
        let mut done = false;
        for (_, path) in self.segments(id)?.into_iter().rev() {
            for_each_line_rev(&path, &mut |line| {
                let Ok(rec) = serde_json::from_slice::<EventRecord>(line) else { return true };
                if rec.seq <= after {
                    done = true;
                    return false;
                }
                count += 1;
                last = last.max(rec.seq);
                true
            })?;
            if done {
                break;
            }
        }
        Ok((count, last))
    }

    fn scan_kinds(
        &self,
        id: &str,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_kinds_in(id, kinds, false, visit)
    }

    fn scan_kinds_strict(
        &self,
        id: &str,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_kinds_in(id, kinds, true, visit)
    }

    /// Back from the end of the records before `before`, segment by segment, reading each line's
    /// seq from its first bytes: no line is parsed but one whose header does not read.
    fn newest_window(&self, id: &str, before: u64, n: u64) -> Result<NewestWindow> {
        let mut window = NewestWindow::default();
        let mut seen = 0u64;
        let mut done = false;
        for (_, path) in self.segments(id)?.into_iter().rev() {
            if first_seq(&path)?.is_some_and(|first| first >= before) {
                continue;
            }
            let mut file = crate::config::private_state_file(&path)?;
            let end = offset_of_seq(&mut file, before)?;
            for_each_line_rev_from(&mut file, end, &mut |line| {
                let Some(seq) = record_seq(line).or_else(|| parse_record(line).ok().map(|r| r.seq))
                else {
                    return true;
                };
                if seq >= before {
                    return true;
                }
                window.newest = window.newest.max(seq);
                seen += 1;
                if seen > n {
                    window.after = seq;
                    done = true;
                    return false;
                }
                true
            })?;
            if done {
                break;
            }
        }
        Ok(window)
    }

    /// Through the copies of the kinds (`store/kind_index.rs`), past `after`: a scan of the log
    /// from the segment that holds `after + 1` parses that whole segment, for each fold of a
    /// load, and read more than the copies do (`a_restored_chats_log_load_reads_the_copies_not_its_log`).
    /// Only the copies from the segment that holds `after + 1` on (`scan_kinds_past`).
    fn scan_kinds_after(
        &self,
        id: &str,
        after: u64,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_kinds_past(id, after, kinds, false, visit)
    }

    fn scan_kinds_after_strict(
        &self,
        id: &str,
        after: u64,
        kinds: &[&str],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_kinds_past(id, after, kinds, true, visit)
    }

    fn scan_kinds_keyed(
        &self,
        id: &str,
        kinds: &[&str],
        keep: &mut dyn FnMut(&KindHead<'_>) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_kinds_keyed_in(id, kinds, keep, visit)
    }

    fn restore_point(&self, id: &str) -> Option<Vec<u8>> {
        std::fs::read(self.dir(id).join(RESTORE_POINT)).ok()
    }

    fn save_restore_point(&self, id: &str, bytes: &[u8]) -> Result<()> {
        let _open = self.writable()?;
        let dir = self.dir(id);
        // A chat whose folder went away (a delete) gets no file of its own again. Read in the
        // held home, never by path (#41721 review F1).
        let folder = crate::home_fs::symlink_metadata(&dir).is_ok_and(|m| m.file_type().is_dir());
        anyhow::ensure!(folder, "no folder for {id}");
        write_atomic(&dir.join(RESTORE_POINT), bytes)
    }

    fn text_entries(
        &self,
        id: &str,
        visit: &mut dyn FnMut(crate::session_search::Entry),
    ) -> Result<()> {
        self.text_entries_in(id, visit)
    }

    fn search_records(&self, id: &str, visit: &mut dyn FnMut(EventRecord)) -> Result<()> {
        if self.is_cold(id) {
            self.cold_search_records(id, visit)
        } else {
            self.scan_kinds(id, crate::session_search::KINDS, &mut |rec| {
                visit(rec);
                true
            })
        }
    }

    /// Segments newest first, so a page from the end reads only the segments it
    /// needs however long the log is. A segment whose first record is at or past
    /// `before` holds nothing for the page and is skipped after one line.
    /// Reads backwards from the end of the records before `before` only: the
    /// segment is read in blocks from the offset where `before` starts (found
    /// by a search on the line headers), never whole, and a line `skip` names,
    /// or one at or past `before`, is passed on its header unparsed. A page
    /// costs its own bytes, not its segment's (perf100: every older page of a
    /// scroll to the first message read and parsed its whole 8 MiB segment,
    /// and opening a chat read the log once for each of its three reads).
    fn scan_back(
        &self,
        id: &str,
        after: u64,
        before: u64,
        skip: &dyn Fn(&[u8], &[u8]) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_back_in(id, after, before, skip, visit, false)
    }

    fn scan_back_indexed(
        &self,
        id: &str,
        after: u64,
        before: u64,
        skip: &dyn Fn(&[u8], &[u8]) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_back_in(id, after, before, skip, visit, true)
    }

    fn flush(&self) -> Result<()> {
        for w in self.writers.lock_or_recover().open.values() {
            log_sync::sync_segment(w.file(), false)?;
        }
        Ok(())
    }

    fn events(&self, id: &str, after: u64, limit: usize) -> Result<Vec<EventRecord>> {
        let mut out = Vec::new();
        self.scan(id, after, &mut |rec| {
            out.push(rec);
            out.len() < limit
        })?;
        Ok(out)
    }

    fn close_log(&self, id: &str) {
        let mut writers = self.writers.lock_or_recover();
        self.close_writer_locked(id, &mut writers);
    }

    fn compacted_seq(&self, id: &str) -> Option<u64> {
        LocalStore::compacted_seq(self, id)
    }

    fn log_written_at(&self, id: &str) -> Option<u64> {
        LocalStore::log_written_at(self, id)
    }

    fn stage_compaction(&self, id: &str, mode: CompactMode) -> Result<Option<Staged>> {
        // Not under the seal: staging writes only copies beside the log, and a large log's
        // stage would hold a shutdown's seal for as long as it reads (router review of #28503).
        // The commit that puts them in place is sealed.
        LocalStore::stage_compaction(self, id, mode)
    }

    fn commit_compaction(&self, id: &str, staged: Staged) -> Result<bool> {
        let _open = self.writable()?;
        LocalStore::commit_compaction(self, id, staged)
    }

    fn stage_cold(&self, id: &str) -> Result<Option<StagedCold>> {
        LocalStore::stage_cold(self, id)
    }

    fn commit_cold(&self, id: &str, staged: StagedCold) -> Result<bool> {
        let _open = self.writable()?;
        LocalStore::commit_cold(self, id, staged)
    }

    fn rehydrate(&self, id: &str) -> Result<bool> {
        LocalStore::rehydrate(self, id)
    }

    fn is_cold(&self, id: &str) -> bool {
        LocalStore::is_cold(self, id)
    }

    fn offload_cold(&self, id: &str) -> Result<Option<u64>> {
        let _open = self.writable()?;
        LocalStore::offload_cold(self, id)
    }

    fn register_cloud_root(&self) -> Result<Option<usize>> {
        LocalStore::register_cloud_root(self)
    }

    fn on_rehydrate(&self, hook: RehydrateHook) {
        let _ = self.rehydrate_hook.set(hook);
    }

    fn stage_cold_segments(
        &self,
        id: &str,
        max: usize,
        level: i32,
    ) -> Result<Option<StagedColdSegments>> {
        LocalStore::stage_cold_segments(self, id, max, level)
    }

    fn prepare_cold_segments(&self, _id: &str, _staged: &StagedColdSegments) -> Result<bool> {
        Ok(true)
    }

    fn commit_cold_segments(&self, id: &str, staged: StagedColdSegments) -> Result<ColdMoved> {
        LocalStore::commit_cold_segments(self, id, staged)
    }

    fn settle_cold_segments(&self, id: &str) -> Result<()> {
        LocalStore::settle_cold_segments(self, id)
    }

    fn warm_cold_segments(&self, id: &str) -> Result<ColdWarmed> {
        LocalStore::warm_cold_segments(self, id)
    }

    fn on_segment_sealed(&self, hook: SealHook) {
        let _ = self.seal_hook.set(hook);
    }

    fn on_log_grown(&self, hook: SealHook) {
        let _ = self.grow_hook.set(hook);
    }

    fn seal(&self) {
        *self.sealed.write().unwrap_or_else(std::sync::PoisonError::into_inner) = true;
    }

    /// `<id>/parked.json`, beside the chat's `events/`: written whole by a rename, its file and
    /// folder synced before it answers. Never makes the chat's folder: a purged chat keeps none.
    fn keep_parked(&self, id: &str, kept: Option<&[u8]>) -> Result<()> {
        let _open = self.writable()?;
        let path = self.dir(id).join(PARKED);
        match kept {
            Some(bytes) => compact::write_durably(&path, bytes),
            None => match crate::home_fs::remove_file(&path) {
                Ok(()) => sync_directory(&self.dir(id)),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(e) => Err(e).with_context(|| format!("remove {}", path.display())),
            },
        }
    }

    fn kept_parked(&self, id: &str) -> Result<Option<Vec<u8>>> {
        #[cfg(test)]
        if fails_kept_read(id) {
            anyhow::bail!("a test failed this read of {id}'s kept records");
        }
        let path = self.dir(id).join(PARKED);
        match crate::config::private_state_file(&path) {
            Ok(file) => {
                let mut bytes = Vec::new();
                BufReader::new(file).read_to_end(&mut bytes)?;
                Ok(Some(bytes))
            }
            Err(_) if crate::home_fs::symlink_metadata(&path).is_err() => Ok(None),
            Err(e) => Err(e),
        }
    }

    /// `<id>/held/<slot>.json`, beside the chat's `events/`: written whole by a rename, not
    /// synced (a kill keeps what the kernel was given). Never makes the chat's folder: a deleted
    /// chat gets no file of its own again.
    fn keep_held(&self, id: &str, slot: &str, held: Option<&[u8]>) -> Result<()> {
        anyhow::ensure!(deferred::is_slot(slot), "{slot:?} names no held slot");
        let _open = self.writable()?;
        let dir = self.dir(id).join(HELD);
        let path = dir.join(format!("{slot}.json"));
        match held {
            Some(bytes) => {
                // `held/` alone, never its parent: whenever a delete removed the chat's folder,
                // this fails. Read in the held home, never by path (#41721 review F1).
                if crate::home_fs::symlink_metadata(&dir).is_err() {
                    match crate::home_fs::create_dir(&dir, 0o700) {
                        Ok(()) => {}
                        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
                        Err(e) => {
                            return Err(e).with_context(|| format!("create {}", dir.display()));
                        }
                    }
                }
                crate::config::write_atomic_unsynced(&path, bytes)
            }
            None => match crate::home_fs::remove_file(&path) {
                Ok(()) => Ok(()),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(e) => Err(e).with_context(|| format!("remove {}", path.display())),
            },
        }
    }

    /// Every `<slot>.json` in `<id>/held/`; none without the folder. A copy a write left (named
    /// `<slot>.tmp-<pid>`) is no slot's.
    fn kept_held(&self, id: &str) -> Result<Vec<(String, Vec<u8>)>> {
        let dir = self.dir(id).join(HELD);
        let entries = match crate::home_fs::read_dir(&dir) {
            Ok(entries) => entries,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(e).with_context(|| format!("list {}", dir.display())),
        };
        let mut out = Vec::new();
        for entry in entries {
            let name = entry.name.to_str().and_then(|n| n.strip_suffix(".json"));
            let Some(slot) = name.filter(|s| entry.is_file && deferred::is_slot(s)) else {
                continue;
            };
            let mut bytes = Vec::new();
            crate::home_fs::private_state_file(dir.join(&entry.name))?.read_to_end(&mut bytes)?;
            out.push((slot.to_owned(), bytes));
        }
        Ok(out)
    }

    fn delete(&self, id: &str) -> Result<()> {
        let _open = self.writable()?;
        if let Some(w) = self.writers.lock_or_recover().open.remove(id) {
            w.retire();
        }
        self.kind_heads.forget(id);
        self.kind_index_checks.forget(id);
        self.segment_starts.forget(id);
        self.segment_table.forget(id);
        let dir = self.dir(id);
        // macOS returns ENOTEMPTY when a file lands mid-removal; retry briefly.
        let mut last = None;
        for _ in 0..5 {
            if !crate::home_fs::try_exists_nofollow(&dir)? {
                return Ok(());
            }
            match crate::home_fs::remove_dir_all(&dir) {
                Ok(()) => return Ok(()),
                Err(e) => {
                    last = Some(e);
                    std::thread::sleep(std::time::Duration::from_millis(40));
                }
            }
        }
        match last {
            Some(e) => Err(e.into()),
            None => Ok(()),
        }
    }

    fn session_dir(&self, id: &str) -> Option<PathBuf> {
        Some(self.dir(id))
    }

    fn handoff_dir(&self) -> Option<PathBuf> {
        self.root.parent().map(|home| home.join("handoffs"))
    }

    fn peer_cache_dir(&self) -> Option<PathBuf> {
        self.root.parent().map(|home| home.join("peers"))
    }

    fn briefs_path(&self) -> Option<PathBuf> {
        self.root.parent().map(|home| home.join("briefs.json"))
    }

    fn audit_dir(&self) -> Option<PathBuf> {
        self.root.parent().map(|home| home.join("audit"))
    }
}

/// Sync a directory entry after a file or subdirectory was created or replaced.
#[cfg(unix)]
fn sync_directory(path: &Path) -> Result<()> {
    #[cfg(test)]
    if log_sync::fail_dir_sync(path) {
        return Err(SyncFailed(std::io::Error::other("a failed folder sync (a test)")).into());
    }
    // The folder the held home has at `path` (`home_fs`), the one a rename through it changed.
    let dir = crate::home_fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(path)?;
    log_sync::sync_full(&dir).map_err(SyncFailed)?;
    #[cfg(test)]
    sync_model::folder_synced(path);
    Ok(())
}

#[cfg(not(unix))]
fn sync_directory(_path: &Path) -> Result<()> {
    Ok(())
}

/// Open one event segment for append, owner-only from creation and after an
/// older build left it with wider permissions.
#[cfg(unix)]
pub(crate) fn open_private_append(path: &Path) -> Result<File> {
    use std::os::unix::fs::PermissionsExt;
    crate::config::refuse_lost_home(path)?;

    // Through the folder this daemon holds (`home_fs`): a home replaced after the check never
    // gets the segment.
    let file = crate::home_fs::OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    if file.metadata()?.permissions().mode() & 0o077 != 0 {
        file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    }
    Ok(file)
}

#[cfg(windows)]
pub(crate) fn open_private_append(path: &Path) -> Result<File> {
    crate::config::refuse_lost_home(path)?;
    Ok(crate::owner_only::open_append(path)?)
}

#[cfg(all(test, unix))]
mod permission_tests;

#[cfg(test)]
mod torn_tail_tests;

#[cfg(all(test, unix))]
mod list_entry_tests;

#[cfg(all(test, unix))]
mod line_rev_tests;

#[cfg(test)]
mod agent_session_history_tests;

fn is_zero(v: &u64) -> bool {
    *v == 0
}

#[cfg(test)]
mod head_tests;
#[cfg(test)]
mod no_rolling_summary_tests;

#[cfg(all(test, unix))]
mod journal_meta_tests;
#[cfg(all(test, unix))]
mod journal_pause_tests;
#[cfg(all(test, unix))]
mod journal_store_tests;
#[cfg(all(test, unix))]
mod journal_sync_tests;
#[cfg(all(test, unix))]
mod journal_write_back_tests;

#[cfg(test)]
mod torn_append_tests;

#[cfg(test)]
mod held_home_reads_tests;

impl LocalStore {
    /// `Store::scan`, and with `strict` `Store::scan_strict`.
    fn scan_lines(
        &self,
        id: &str,
        after: u64,
        strict: bool,
        may_match: Option<&dyn Fn(&[u8]) -> bool>,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        // A strict read learns that the log's segments could not be listed (`segments` lists
        // none then).
        if strict {
            self.rehydrate(id)?;
            std::fs::read_dir(self.dir(id).join("events"))?;
        }
        let segments = self.segments(id)?;
        let mut line = Vec::new();
        let mut pass = crate::perf_watch::LogPass::start(id, after == 0);
        // The segment that holds `after + 1`, found from the segments' kept first seqs: the read
        // opens only the segments it reads (`store/segment_starts.rs`).
        let start = self.segment_starts.start(id, &segments, after)?;
        for (n, (_, path)) in segments.get(start..).unwrap_or_default().iter().enumerate() {
            let mut file = cold_segments::open_segment(path)?;
            // The segment that holds `after + 1` is read from a line at or before it, found by a
            // search, not from its start: a read near the log's end (a settled attach's records
            // since its view) cost the whole segment being written (`log_line::start_of_seq`).
            // A cold segment is read from its start, as before.
            if n == 0 && after > 0 && file.local().is_some() {
                let from = start_of_seq(&mut file, after.saturating_add(1))?;
                std::io::Seek::seek(&mut file, std::io::SeekFrom::Start(from))?;
            }
            let mut reader = BufReader::with_capacity(256 * 1024, file);
            loop {
                line.clear();
                if reader.read_until(b'\n', &mut line)? == 0 {
                    break;
                }
                crate::perf_watch::LogPass::line(&mut pass, line.len());
                #[cfg(test)]
                FORWARD_READ_BYTES.with(|n| n.set(n.get() + line.len() as u64));
                if line.iter().all(u8::is_ascii_whitespace) {
                    continue;
                }
                if record_seq(&line).is_some_and(|seq| seq <= after) {
                    continue;
                }
                if may_match.is_some_and(|may_match| !may_match(&line)) {
                    continue;
                }
                let rec = match parse_record(&line) {
                    Ok(rec) => rec,
                    Err(e) if strict => {
                        anyhow::bail!("{}: a record could not be read: {e}", path.display())
                    }
                    Err(_) => continue,
                };
                if rec.seq > after && !visit(rec) {
                    return Ok(());
                }
            }
        }
        Ok(())
    }
}

#[cfg(test)]
thread_local! {
    /// Tests only: the bytes of the lines this thread's forward reads (`scan_lines`) read.
    pub(crate) static FORWARD_READ_BYTES: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

#[cfg(all(test, unix))]
#[path = "store/startup_tests.rs"]
mod startup_tests;

/// Tests only: the chat whose next commit (`compact.rs` `commit_compaction`) fails once its
/// segments are in place, before its record says it is complete, as a failed write of that
/// record does: the log is the shorter one already, and the call fails (review of #37284 at
/// fd33a65b, F2).
#[cfg(test)]
static FAIL_BEFORE_MARKER: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());

/// Tests only: arms [`FAIL_BEFORE_MARKER`] for chat `id`, once.
#[cfg(test)]
pub(crate) fn fail_before_marker_once(id: &str) {
    FAIL_BEFORE_MARKER.lock().unwrap_or_else(|e| e.into_inner()).push(id.to_owned());
}

/// Tests only: what runs once a commit of chat `id`'s staged log (`compact.rs`
/// `commit_compaction`) replaced its first segment, before its second: a crash there, as a test
/// copies what the disk holds then (review of #37284 at b7496c3f, F2).
#[cfg(test)]
type Crash = Box<dyn FnOnce() + Send>;

// test-hook-allow: armed per chat id, and only that chat's run takes it
#[cfg(test)]
static BETWEEN_SEGMENTS: std::sync::Mutex<Vec<(String, Crash)>> = std::sync::Mutex::new(Vec::new());

/// Tests only: arms [`BETWEEN_SEGMENTS`] for chat `id`, once. The hook is process-wide and tests
/// run in parallel: `id` is a chat no other test uses, or another test's commit takes the crash.
#[cfg(test)]
pub(crate) fn between_segments_once(id: &str, crash: Crash) {
    BETWEEN_SEGMENTS.lock().unwrap_or_else(|e| e.into_inner()).push((id.to_owned(), crash));
}

/// Runs [`between_segments_once`]'s crash of chat `id`, on the committing thread.
#[cfg(test)]
fn between_segments(id: &str) {
    let crash = {
        let mut armed = BETWEEN_SEGMENTS.lock().unwrap_or_else(|e| e.into_inner());
        let at = armed.iter().position(|(at, _)| at == id);
        at.map(|at| armed.swap_remove(at).1)
    };
    if let Some(crash) = crash {
        crash();
    }
}

/// Tests only: the chats whose reads of their kept records (`parked.json`, `Store::kept_parked`)
/// fail, as a transient read error does, until [`kept_reads_again`] (review of #37284 at
/// 23e76b07, F2). Per chat: tests run at once.
#[cfg(test)]
static FAIL_KEPT_READ: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());

/// Tests only: every read of chat `id`'s kept records fails from now ([`FAIL_KEPT_READ`]).
#[cfg(test)]
pub(crate) fn fail_kept_reads(id: &str) {
    FAIL_KEPT_READ.lock().unwrap_or_else(|e| e.into_inner()).push(id.to_owned());
}

/// Tests only: chat `id`'s kept records read again.
#[cfg(test)]
pub(crate) fn kept_reads_again(id: &str) {
    FAIL_KEPT_READ.lock().unwrap_or_else(|e| e.into_inner()).retain(|a| a != id);
}

#[cfg(test)]
fn fails_kept_read(id: &str) -> bool {
    FAIL_KEPT_READ.lock().unwrap_or_else(|e| e.into_inner()).iter().any(|a| a == id)
}

#[cfg(test)]
fn fails_before_marker(id: &str) -> bool {
    let mut armed = FAIL_BEFORE_MARKER.lock().unwrap_or_else(|e| e.into_inner());
    let at = armed.iter().position(|a| a == id);
    at.map(|at| armed.swap_remove(at)).is_some()
}
