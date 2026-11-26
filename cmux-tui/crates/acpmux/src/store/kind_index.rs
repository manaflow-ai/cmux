//! A log segment's records of the kinds a chat's log load reads, kept beside the log.
//!
//! A restored chat's first open waits for its log load (`hub/log_load.rs`), and the load scans the
//! whole log for its queue, turn, branch and agent pair records (`restore_queue`,
//! `mark_unknown_outcome`): a 102 MB Codex log read 307 MB before its open page (`cold_open_perf`,
//! 2026-10-30). Those records are few. A segment is only ever appended to, or replaced whole by a
//! rename (a retention rewrite, `store/compact.rs`). So a scan for [`INDEXED_KINDS`]
//! ([`LocalStore::scan_kinds`]) copies a segment's records of those kinds, as written, to
//! `<session>/events-index/NNNNNN.ndjson`, with the file they came from (device, inode, birth) and
//! how many of its bytes they cover; a later scan reads the copy, then the segment past those
//! bytes only.
//!
//! A copy whose file is gone (replaced, or another log's after a move) or shorter than it covers
//! is read past and made again. A new copy is written whole under a temporary name and renamed
//! into place, so a crash leaves the old copy or none. A scan that read at least [`COPY_AFTER`]
//! bytes past a copy it took adds only the lines it read to it: the new lines go at the end of
//! the copy's lines, then its fixed-width header ([`HEADER_WIDTH`]) is written again in place. A
//! crash between the two leaves the old header, which covers the old lines only (the bytes past
//! them are read past, and the next addition cuts them off); a torn header or a lost line fails
//! the copy's seal, so the copy is read past and made again, never read wrong. So each indexed
//! line is written to its copy once, not once per [`COPY_AFTER`] bytes of log: a chat whose
//! prompts were megabytes each rewrote its whole copy, every prompt in it, on every scan
//! (cmuxterm-hq#9263: `logged_inbox_answer` → `scan_kinds`, 131 of 757 samples of 549 GB of
//! writes in a day). The append path writes one copy per segment, of the segment a rotation just
//! filled (`store/segment_writer.rs`), so a chat never scanned still has a copy of every segment
//! but the open one; a chat's folder is deleted with its copies.
//!
//! A strict scan ([`Store::scan_kinds_strict`], the transfer authority's) fails on a line that
//! does not read, as one of the whole log would: a copy says whether every line it covers read,
//! and a strict scan takes no other.
//!
//! Two of a log load's reads still read the whole log, each only in a state a restart rarely
//! leaves: a subagent retry the saved meta marks open (`settle_subagent_retries`, whose
//! `subagent_state_update` records are an agent's own and many), and a turn cut with its host gone
//! (`log_restart_continuation`, which reads every record's head up to the cut turn).

use super::*;

/// The kinds a chat's log load reads (`hub/queue.rs` `QUEUE_KINDS`, `hub/inbox.rs` `INBOX_KINDS`
/// and `hub/transfer_authority.rs` `TRANSFER_KINDS`, which a test keeps within these, `hub/log_load.rs` `mark_unknown_outcome` and
/// `hub/message_events.rs`): a scan for these only reads the copies. A copy made for another list
/// is read past ([`Header::kinds`]).
pub const INDEXED_KINDS: &[&str] = &[
    "git",
    "queued",
    "transfer_out",
    "transfer_aborted",
    "imported",
    "transferred_in",
    "dequeued",
    "queue_removed",
    "user_message",
    "turn_started",
    "queue_updated",
    "queue_paused",
    "queue_resumed",
    "queue_order",
    // The owner's answer to a prompt that waits for them (`hub/queue_approve.rs`).
    "queue_approved",
    "queue_declined",
    "turn_result",
    "prompt_refused",
    "agent_pair_held",
    "agent_pair_released",
    "agent_pair_dropped",
    "agent_pair_paused",
    "agent_pair_resumed",
    // A log load's recovery of agent message projections (`hub/message_events.rs`), and the
    // projections' ids, read once per chat (`hub/mod.rs`).
    "forked",
    "_acpmux/message",
    // A log load's transfer authority (`hub/transfer_authority.rs`, a strict scan).
    "transferred",
    // A log load's restored inbox (`hub/inbox.rs` `restore_inbox`).
    "inbox",
    "inbox_triaged",
    "inbox_noticed",
    "inbox_returned",
    "inbox_answered",
    "inbox_read",
    "inbox_removed",
    // Reads that run per turn, per prompt or per open, each a few records a turn at most: a
    // chat of a million records answers them from the copies, not its log (Leo, 2026-11-06:
    // "we need to be able to work with a 1 million event chat ... it's not like you're reading
    // 1 million events on each turn"). A resent prompt's state (`hub/prompt_ledger.rs`), a
    // child's offer result at each of its turn ends (`hub/offer_results.rs`, `hub/offers.rs`),
    // a turn's stop fence (`hub/auto_resume.rs`), the secrets a machine_info call lists
    // (`hub/machine_info.rs`) and the team messages a chat sent or read (`hub/team_sent.rs`,
    // `hub/team_information.rs`).
    "turn_stop_requested",
    "session_offer",
    "session_offer_decision",
    "prompt_stop_requested",
    "auto_resume_scheduled",
    "secret_request",
    "secret_decision",
    "team_message",
    "team_message_consumed",
    "team_message_read",
    "team_work_received",
    "team_message_sent",
    // A chat's process table (`hub/processes.rs`), read on its first touch: the idle sweep's.
    "background_task_update",
    "process_update",
    "stopped",
    "exited",
    "host_started",
    // A withdrawn prompt's end (`hub/withdraw.rs`).
    "prompt_retracted",
    "turn_end",
    "turn_error",
    // A chat's thread owners, read by each surge triage pass (`hub/surge_triage.rs`).
    "inbox_subscription",
    // A recipient's grants of its threads to owners, read with them.
    "inbox_owner_grant",
    // A log load's rate-limit hold (`hub/rate_hold.rs` `restore_rate_hold`), read back to the
    // newest completed turn: a chat with none near its end read its whole log at every start.
    "rate_limit_held",
    "rate_limit_parked",
    "rate_limit_lifted",
    "rate_limit_unparked",
];

/// The folder of a chat's copies, beside its `events`.
pub const DIR: &str = "events-index";
const SCHEMA: &str = "acpmux.kind-index.v5";

/// A copy's first line, its header, padded with spaces to this many bytes and a newline, so an
/// addition writes it again in place ([`LocalStore::append_kind_index`]).
pub(super) const HEADER_WIDTH: usize = 512;

/// A scan that read this many bytes of a segment past its copy saves the copy again.
pub(super) const COPY_AFTER: u64 = 1 << 20;

/// The longest tail past a copy a page reads whole: past it the page seeks for its `before`
/// (`offset_of_seq`, whose probes read 64 KiB each), as the read back from the end does.
const TAIL_SEEK_BYTES: u64 = 256 * 1024;

/// What a copy was read from: the segment file, and the bytes of it the copy covers.
#[derive(Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct Header {
    schema: String,
    dev: u64,
    ino: u64,
    /// When the file was made (ns since the epoch; 0 where the system does not say): an inode a
    /// later file reuses is not the same file.
    born_ns: u64,
    len: u64,
    /// [`INDEXED_KINDS`] when the copy was made: a copy holds no line of a kind added since.
    kinds: u64,
    /// Every line of the bytes it covers read as a record: a strict scan takes no other copy.
    parsed: bool,
    /// The copied lines' length and their FNV-1a hash, which an addition carries on from; `seal`,
    /// a hash of every other field: a damaged or cut copy is read past.
    lines_len: u64,
    lines_hash: u64,
    seal: u64,
}

impl Header {
    fn new(id: (u64, u64, u64), len: u64, parsed: bool, lines_len: u64, lines_hash: u64) -> Self {
        let kinds = kinds();
        Self {
            schema: SCHEMA.into(),
            dev: id.0,
            ino: id.1,
            born_ns: id.2,
            len,
            kinds,
            parsed,
            lines_len,
            lines_hash,
            seal: seal(id, len, kinds, parsed, lines_len, lines_hash),
        }
    }

    /// The header line, padded to [`HEADER_WIDTH`]; None if it would not fit (it always does).
    fn line(&self) -> Option<Vec<u8>> {
        let mut out = serde_json::to_vec(self).ok()?;
        if out.len() >= HEADER_WIDTH {
            return None;
        }
        out.resize(HEADER_WIDTH - 1, b' ');
        out.push(b'\n');
        Some(out)
    }
}

/// The copy `copy` of a segment's kinds, written to `to` as the copy of `segment`, a file with the
/// same bytes the copy covers but another device or inode: a staged prefix that could not be
/// linked into the chat's folder (another file system) and was copied (`hub/transfer_precopy.rs`
/// `adopt_index`). A copy names its file by device, inode and birth, so the stage's did not pass
/// for the copied segment, and the move's first scan read the whole log again, inside its
/// freeze: 3.2 s of a 3.4 s freeze on 248 MB of log (2026-11-22,
/// `a_live_move_freezes_for_the_tail_only_over_a_slow_link`). The caller vouches that the bytes
/// are the same. False, and nothing written, when the copy is not whole or not of these kinds:
/// the first scan makes one then, as for any segment.
pub fn carry_copy(copy: &Path, segment: &Path, to: &Path) -> Result<bool> {
    use std::io::Read as _;
    let mut bytes = Vec::new();
    crate::config::private_state_file(copy)?.read_to_end(&mut bytes)?;
    let Some(end) = bytes.iter().position(|b| *b == b'\n') else { return Ok(false) };
    let Ok(header) = serde_json::from_slice::<Header>(&bytes[..end]) else { return Ok(false) };
    let mut lines = bytes.split_off(end.saturating_add(1));
    lines.truncate(usize::try_from(header.lines_len)?);
    let file = (header.dev, header.ino, header.born_ns);
    let whole = lines.len() as u64 == header.lines_len
        && fnv_on(FNV_START, &lines) == header.lines_hash
        && seal(file, header.len, header.kinds, header.parsed, header.lines_len, header.lines_hash)
            == header.seal
        && lines.last().is_none_or(|b| *b == b'\n');
    let stamp = Stamp::of(&crate::config::private_state_file(segment)?)?;
    if !whole
        || header.schema != SCHEMA
        || header.kinds != kinds()
        || stamp.id.2 == 0
        || stamp.len < header.len
    {
        return Ok(false);
    }
    let carried =
        Header::new(stamp.id, header.len, header.parsed, header.lines_len, header.lines_hash);
    let mut out = carried.line().ok_or_else(|| anyhow::anyhow!("kind index header too long"))?;
    out.extend_from_slice(&lines);
    crate::config::write_atomic_unsynced(to, &out)?;
    Ok(true)
}

/// FNV-1a, 64 bits, of a copy's file, coverage, kinds and its lines' length and hash: stable
/// across builds, so a copy one daemon wrote checks in the next.
fn seal(
    id: (u64, u64, u64),
    len: u64,
    kinds: u64,
    parsed: bool,
    lines_len: u64,
    lines: u64,
) -> u64 {
    let fields = [id.0, id.1, id.2, len, kinds, u64::from(parsed), lines_len, lines];
    fnv(fields.iter().flat_map(|f| f.to_le_bytes()))
}

/// The FNV-1a offset basis: the hash of no bytes, which [`fnv_on`] carries on from.
const FNV_START: u64 = 0xcbf2_9ce4_8422_2325;

/// FNV-1a from `state` (a hash of the bytes before) over `bytes`.
fn fnv_on(state: u64, bytes: &[u8]) -> u64 {
    #[cfg(test)]
    HASHED.with(|n| n.set(n.get() + bytes.len() as u64));
    bytes.iter().fold(state, |h, b| (h ^ u64::from(*b)).wrapping_mul(0x100_0000_01b3))
}

#[cfg(test)]
thread_local! {
    /// Bytes this thread's copy reads and writes hashed ([`fnv_on`]).
    pub(super) static HASHED: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
    /// Bytes of copies this thread read ([`LocalStore::read_kind_index`]).
    pub(super) static COPY_BYTES: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

/// The most copies [`Checked`] remembers; past it, it forgets them all (each is then hashed
/// whole once more).
const CHECKED_MAX: usize = 1 << 16;

/// What a copy file was when its lines last checked: its device, inode and birth, its length and
/// modify time, and the length and FNV-1a hash of the lines its header covered.
#[derive(Clone, Copy, PartialEq, Eq)]
struct Check {
    file: (u64, u64, u64),
    len: u64,
    mtime: Option<std::time::SystemTime>,
    lines_len: u64,
    lines_hash: u64,
}

/// The copies a store's reads checked ([`LocalStore::read_kind_index`]), so a read hashes only
/// the lines added since. Each read hashed every line of the copy to check it: a prompt's resend
/// (`logged_inbox_answer`, `logged_prompt_records`) read every copy of a chat past the held heads
/// again, and `fnv_on` led the busiest worker threads of Leo's NIGHTLY daemon at 112% of a core
/// (f3b932edb979, 2026-11-23). A copy is only added to in place ([`LocalStore::append_kind_index`],
/// which leaves the lines before untouched) or written whole under a new inode, so the lines a
/// read checked stay as checked while the file is the same and no shorter: a later read hashes
/// the lines past them only, carried on from their hash. A file that is another (inode, birth),
/// shorter, or changed with no new bytes (modify time) is hashed whole, as is any copy whose
/// carried hash does not match.
#[derive(Default)]
pub(super) struct Checked {
    map: Mutex<HashMap<(String, u32), Check>>,
}

impl Checked {
    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<(String, u32), Check>> {
        self.map.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Whether `lines`, the lines a header of copy `index` of chat `id` covers, read from the copy
    /// file `now` (no `lines_len` set yet), hash to `want`: the lines past those of the last check
    /// of the same file only, else all of them.
    fn lines_match(&self, id: &str, index: u32, mut now: Check, lines: &[u8], want: u64) -> bool {
        let key = (id.to_owned(), index);
        let prior = self.lock().get(&key).copied();
        now.lines_len = lines.len() as u64;
        now.lines_hash = want;
        let carried = prior.filter(|c| {
            c.file == now.file
                && now.file.2 != 0
                && c.lines_len <= now.lines_len
                && (c.len < now.len || (c.len == now.len && c.mtime == now.mtime))
        });
        let matched = carried.is_some_and(|c| {
            usize::try_from(c.lines_len)
                .ok()
                .and_then(|from| lines.get(from..))
                .is_some_and(|added| fnv_on(c.lines_hash, added) == want)
        }) || fnv_on(FNV_START, lines) == want;
        let mut map = self.lock();
        if matched {
            if map.len() >= CHECKED_MAX && !map.contains_key(&key) {
                map.clear();
            }
            map.insert(key, now);
        } else {
            map.remove(&key);
        }
        matched
    }

    /// Forgets chat `id`'s copies (its folder is gone).
    pub(super) fn forget(&self, id: &str) {
        self.lock().retain(|(chat, _), _| chat != id);
    }
}

/// A copy as [`LocalStore::read_kind_index`] read it: its lines, the bytes of the segment they
/// cover, whether every line of those bytes read, and the lines' hash.
pub(super) struct Copied {
    pub(super) lines: Vec<u8>,
    pub(super) len: u64,
    pub(super) parsed: bool,
    pub(super) hash: u64,
}

/// One addition to a copy at a time in this process: two scans of a chat that added at once
/// would each cut the other's lines (the seal would catch it, and the copy be made again).
static APPENDS: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// FNV-1a, 64 bits, of [`INDEXED_KINDS`].
fn kinds() -> u64 {
    fnv(INDEXED_KINDS.iter().flat_map(|k| k.bytes().chain([b'\n'])))
}

pub(super) fn fnv(bytes: impl Iterator<Item = u8>) -> u64 {
    bytes.fold(FNV_START, |h, b| (h ^ u64::from(b)).wrapping_mul(0x100_0000_01b3))
}

/// What a copy is of: the segment file (its device, inode and birth time) and its length now.
pub(super) struct Stamp {
    pub(super) id: (u64, u64, u64),
    pub(super) len: u64,
}

impl Stamp {
    /// The open segment `file`'s, however its path changes meanwhile.
    pub(super) fn of(file: &std::fs::File) -> std::io::Result<Self> {
        let meta = file.metadata()?;
        Ok(Self { id: file_id(file, &meta), len: meta.len() })
    }
}

/// The file's device, inode and birth time (ns since the epoch; 0 where the system does not say).
fn file_id(file: &std::fs::File, meta: &std::fs::Metadata) -> (u64, u64, u64) {
    let born = birth_ns(file).unwrap_or_else(|| {
        meta.created()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map_or(0, |d| u64::try_from(d.as_nanos()).unwrap_or(u64::MAX))
    });
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let _ = file;
        (meta.dev(), meta.ino(), born)
    }
    #[cfg(not(unix))]
    {
        let _ = (file, meta);
        (0, 0, born)
    }
}

/// The birth time Linux keeps for `file` ([`cmux_tui_platform::file_birth::birth_ns`]). Without
/// it every log load read and parsed whole logs: four passes over each live chat's log on a
/// restart, about 12 GB on a host with 3.1 GB of them. None: the kernel or file system keeps no
/// birth time (the copy then stays off, as before).
pub(super) fn birth_ns(file: &std::fs::File) -> Option<u64> {
    cmux_tui_platform::file_birth::birth_ns(file)
}

/// Whether a line belongs in a copy: its kind is indexed, or its head does not say (it is parsed
/// where it is read, as the segment's would be).
pub(super) fn indexed(line: &[u8]) -> bool {
    record_kind(line).is_none_or(|kind| INDEXED_KINDS.iter().any(|k| k.as_bytes() == kind))
}

/// Debug builds only: `ACPMUX_TEST_SCAN_DELAY_MS` holds each log scan, as a slow disk or a long
/// log does (`tests/restart_reattach.rs`). Bounded; release builds have no seam.
pub(super) fn test_scan_delay() {
    #[cfg(debug_assertions)]
    if let Some(ms) =
        std::env::var("ACPMUX_TEST_SCAN_DELAY_MS").ok().and_then(|v| v.parse::<u64>().ok())
    {
        std::thread::sleep(std::time::Duration::from_millis(ms.min(1_000)));
    }
}

/// One scan for `kinds`: whether it may take copies, and whether it is strict.
pub(super) struct Scan<'a> {
    pub(super) kinds: &'a [&'a str],
    pub(super) copied: bool,
    pub(super) strict: bool,
    /// A copy made by line heads alone, no line parsed ([`LocalStore::copy_for_read_back`]): it
    /// says its lines were not all read (`parsed` false), so a strict scan makes it again.
    pub(super) heads: bool,
}

impl Scan<'_> {
    /// Visits `line` when it is a record of a wanted kind; false when `visit` stops the scan. A
    /// line that does not read is skipped, or in a strict scan an error.
    fn line(
        &self,
        path: &Path,
        line: &[u8],
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<bool> {
        if line.iter().all(u8::is_ascii_whitespace)
            || record_kind(line)
                .is_some_and(|kind| !self.kinds.iter().any(|k| k.as_bytes() == kind))
        {
            return Ok(true);
        }
        let rec = match parse_record(line) {
            Ok(rec) => rec,
            Err(e) if self.strict => {
                anyhow::bail!("{}: a record could not be read: {e}", path.display())
            }
            Err(_) => return Ok(true),
        };
        Ok(!self.kinds.contains(&rec.kind.as_str()) || visit(rec))
    }
}

impl LocalStore {
    /// `scan_back` (`indexed`: `scan_back_indexed`, whose `skip` passes only [`INDEXED_KINDS`]).
    /// Segments are read newest first; an indexed read takes a segment's copy where it is of that
    /// very file and whole ([`Self::read_kind_index`]): the segment's bytes past the copy back from
    /// the end, then the copy's lines newest first. Anywhere else (no copy yet, a copy a
    /// compaction or an upgrade left stale, a file system with no birth time) it reads the segment
    /// back from its end, as `scan_back` does. A segment with no copy, or [`COPY_AFTER`] bytes
    /// past its copy, gets one first ([`Self::copy_for_read_back`]).
    pub(super) fn scan_back_in(
        &self,
        id: &str,
        after: u64,
        before: u64,
        skip: &dyn Fn(&[u8], &[u8]) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
        indexed: bool,
    ) -> Result<()> {
        let done = std::cell::Cell::new(false);
        // One line, newest first: false once the read is over (`visit` stopped, or `after`).
        let mut line = |line: &[u8]| {
            match record_seq(line) {
                Some(seq) if seq >= before => return true,
                Some(seq) if seq <= after => {
                    done.set(true);
                    return false;
                }
                _ => {}
            }
            if let (Some(dir), Some(kind)) = (record_dir(line), record_kind(line))
                && skip(dir, kind)
            {
                return true;
            }
            let Ok(rec) = serde_json::from_slice::<EventRecord>(line) else { return true };
            if rec.seq >= before {
                return true;
            }
            if rec.seq <= after || !visit(rec) {
                done.set(true);
                return false;
            }
            true
        };
        let segments = self.segments(id)?;
        let end = self.segment_starts.end(id, &segments, before)?;
        for (index, path) in segments[..end].iter().rev() {
            let index = *index;
            if self.segment_starts.first_seq(id, index, path)?.is_some_and(|first| first >= before)
            {
                continue;
            }
            let mut file = super::cold_segments::open_segment(path)?;
            let copy = match file.local() {
                Some(local) if indexed => self.copy_for_read_back(id, index, path, local)?,
                _ => None,
            };
            match copy {
                // A copy covers the segment's first `from` bytes, whole lines: what was written
                // after them (none in a segment a log load sealed and copied, at most the segment
                // in the one being written) is read from the segment, then the copy. A long tail
                // is first cut at `before`, as `scan_back` cuts the segment; a short one is read
                // whole, which costs less than the seek's probes.
                Some((lines, from, _)) => {
                    let len = std::io::Seek::seek(&mut file, std::io::SeekFrom::End(0))?;
                    let end = if before != u64::MAX && len.saturating_sub(from) > TAIL_SEEK_BYTES {
                        offset_of_seq(&mut file, before)?.max(from)
                    } else {
                        u64::MAX
                    };
                    for_each_line_rev_between(&mut file, from, end, &mut line)?;
                    if !done.get() {
                        for copied in lines.split(|b| *b == b'\n').rev() {
                            if !copied.is_empty() && !line(copied) {
                                break;
                            }
                        }
                    }
                }
                None => {
                    let end = match &mut file {
                        super::cold_segments::SegmentFile::Cold(cold) => {
                            cold.offset_of_seq(before)?
                        }
                        local => offset_of_seq(local, before)?,
                    };
                    for_each_line_rev_from(&mut file, end, &mut line)?;
                }
            }
            if done.get() {
                return Ok(());
            }
        }
        Ok(())
    }

    /// Segment `index`'s copy for an indexed read back, made or brought up to date first when the
    /// segment has none or is [`COPY_AFTER`] bytes past it. Only a log load made copies, so a
    /// chat that ran on since its load had none for the segments written after it: each page of
    /// its prompts (every open and attach asks for one, `turn_opener.rs`) read every such segment
    /// whole, back from its end. A busy chat 16 minutes old read its whole 26 MB log for each
    /// 16-prompt page, and an app asked for that page every few seconds (cmuxterm-hq#13733). The
    /// copy is made by the lines' heads, no line parsed (an adoption reads many chats' logs this
    /// way and parses only what it folds, `hosts_tests.rs`), once per sealed segment and once per
    /// [`COPY_AFTER`] bytes of the one being written. None on a system with no birth time, or when
    /// the copy is of another file than `file` (a compaction renamed it meanwhile).
    fn copy_for_read_back(
        &self,
        id: &str,
        index: u32,
        path: &Path,
        file: &std::fs::File,
    ) -> Result<Option<(Vec<u8>, u64, bool)>> {
        let read = |stamp: &Stamp| {
            self.read_kind_index(id, index, stamp).map(|c| (c.lines, c.len, c.parsed))
        };
        let stamp = Stamp::of(file)?;
        let copy = read(&stamp);
        let behind =
            copy.as_ref().map_or(stamp.len, |(_, from, _)| stamp.len.saturating_sub(*from));
        if stamp.id.2 == 0 || behind < COPY_AFTER {
            return Ok(copy);
        }
        let scan = Scan { kinds: &[], copied: true, strict: false, heads: true };
        if let Err(e) = self.scan_segment(id, index, path, &scan, &mut |_| true) {
            tracing::debug!(session = %id, segment = index, "copying a segment for a read back failed: {e}");
            return Ok(copy);
        }
        Ok(read(&Stamp::of(file)?).or(copy))
    }

    pub(super) fn kind_index_path(&self, id: &str, index: u32) -> PathBuf {
        self.dir(id).join(DIR).join(format!("{index:06}.ndjson"))
    }

    /// `scan_kinds` (`strict`: `scan_kinds_strict`). A scan for the kinds a log load reads takes
    /// each segment's copy of them, then the segment past it, and saves the copy again.
    pub(super) fn scan_kinds_in(
        &self,
        id: &str,
        kinds: &[&str],
        strict: bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_kinds_from(id, 0, kinds, strict, visit)
    }

    /// [`Self::scan_kinds_in`] of the records past `after` only. The segments before the one
    /// that holds `after + 1` hold no such record (seqs only grow from segment to segment,
    /// `store/segment_starts.rs`), so they are not read, copies or segments: a log load past a
    /// restore point read every segment's copy from the log's start, a share of the whole
    /// history on every daemon start (goal infinite-chats: 69 MB of a 514 MB chat). The visitor
    /// still sees only records past `after`; the segment it starts in is read whole.
    pub(super) fn scan_kinds_past(
        &self,
        id: &str,
        after: u64,
        kinds: &[&str],
        strict: bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        self.scan_kinds_from(id, after, kinds, strict, &mut |rec| rec.seq <= after || visit(rec))
    }

    fn scan_kinds_from(
        &self,
        id: &str,
        after: u64,
        kinds: &[&str],
        strict: bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        test_scan_delay();
        // A strict read learns that the log's segments could not be listed (`segments` lists
        // none then), as `scan_strict` does.
        if strict {
            self.rehydrate(id)?;
            std::fs::read_dir(self.dir(id).join("events"))?;
        }
        let copied = kinds.iter().all(|k| INDEXED_KINDS.contains(k));
        let scan = Scan { kinds, copied, strict, heads: false };
        let segments = self.segments(id)?;
        let start = self.segment_starts.start(id, &segments, after)?;
        for (index, path) in segments.into_iter().skip(start) {
            if !self.scan_segment(id, index, &path, &scan, visit)? {
                break;
            }
        }
        Ok(())
    }

    /// One segment of [`Self::scan_kinds_in`]; false when `visit` stopped the scan.
    pub(super) fn scan_segment(
        &self,
        id: &str,
        index: u32,
        path: &Path,
        scan: &Scan<'_>,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<bool> {
        let mut file = super::cold_segments::open_segment(path)?;
        // What a copy is of: the file this reads, however its path changes meanwhile.
        let stamp = match file.local() {
            Some(local) if scan.copied => Some(Stamp::of(local)?),
            _ => None,
        };
        let (mut copy, from, mut parsed, copy_hash) =
            match stamp.as_ref().and_then(|s| self.read_kind_index(id, index, s)) {
                Some(c) if c.parsed || !scan.strict => (Some(c.lines), c.len, c.parsed, c.hash),
                _ => (None, 0, true, 0),
            };
        for line in copy.iter().flat_map(|lines| lines.split(|b| *b == b'\n')) {
            if !scan.line(path, line, visit)? {
                return Ok(false);
            }
        }
        if from > 0 {
            std::io::Seek::seek(&mut file, std::io::SeekFrom::Start(from))?;
        }
        let had_copy = copy.is_some();
        let lines = copy.get_or_insert_with(Vec::new);
        // The copy's own lines: an addition writes only the lines past them.
        let copied = lines.len();
        // The bytes past `from` read up to the end of their last whole line.
        let mut covered = 0u64;
        let mut reader = BufReader::with_capacity(256 * 1024, file);
        let mut line = Vec::new();
        loop {
            line.clear();
            if reader.read_until(b'\n', &mut line)? == 0 {
                break;
            }
            // A line still being written ends the read of this segment: the bytes of it that
            // arrive later are no line of their own, and the copy covers none of it.
            let torn = !line.ends_with(b"\n");
            let blank = line.iter().all(u8::is_ascii_whitespace);
            // A strict scan, and one that makes a copy, reads every line: a copy says whether
            // all of its bytes read, so a strict scan of it fails where one of the segment would.
            // A copy by heads reads none, and says so.
            if scan.heads && !blank && !torn {
                parsed = false;
            } else if !blank
                && (scan.strict || stamp.is_some())
                && let Err(e) = parse_record(&line)
            {
                if scan.strict {
                    anyhow::bail!("{}: a record could not be read: {e}", path.display());
                }
                if !torn {
                    parsed = false;
                }
            }
            if !torn {
                covered = covered.saturating_add(line.len() as u64);
                if stamp.is_some() && indexed(&line) {
                    lines.extend_from_slice(&line);
                }
            }
            if !scan.line(path, &line, visit)? {
                return Ok(false);
            }
            if torn {
                break;
            }
        }
        if let Some(stamp) = stamp
            && (!had_copy || covered >= COPY_AFTER)
        {
            let len = from.saturating_add(covered);
            let added = had_copy
                && self
                    .append_kind_index(id, index, &stamp, len, parsed, lines, (copied, copy_hash))
                    .unwrap_or_else(|e| {
                        tracing::debug!(session = %id, segment = index, "adding to the log's kind index failed: {e}");
                        false
                    });
            if !added && let Err(e) = self.write_kind_index(id, index, &stamp, len, parsed, lines) {
                tracing::warn!(session = %id, segment = index, "saving the log's kind index failed: {e}");
            }
        }
        Ok(true)
    }

    /// The copied lines of segment `index`, the bytes of it they cover, and whether every line of
    /// those bytes read, when the copy is of the file `segment` (the open segment's stamp) and
    /// [`INDEXED_KINDS`], no longer than it, and whole. A system that names no birth time keeps no
    /// copy: an inode a later file reuses would pass for the same. Of a copy read before, only the
    /// lines added since are hashed ([`Checked`]).
    ///
    /// The header is read first and the lines only for a copy of this segment, into one buffer of
    /// their length: a whole-file `read_to_end` grew its buffer by doubling and the header's split
    /// copied the lines again, 2.3 GB of transient blocks over a 1 GB chat's restart (dhat,
    /// `chat_size_sweep`), churn the allocator kept resident as restart RSS.
    pub(super) fn read_kind_index(&self, id: &str, index: u32, segment: &Stamp) -> Option<Copied> {
        use std::io::Read as _;
        let mut file = crate::config::private_state_file(&self.kind_index_path(id, index)).ok()?;
        // The copy file as it was before its bytes were read: an addition meanwhile only grows it.
        let meta = file.metadata().ok()?;
        let now = Check {
            file: file_id(&file, &meta),
            len: meta.len(),
            mtime: meta.modified().ok(),
            lines_len: 0,
            lines_hash: 0,
        };
        let mut head = Vec::with_capacity(HEADER_WIDTH);
        (&mut file).take(HEADER_WIDTH as u64).read_to_end(&mut head).ok()?;
        let end = head.iter().position(|b| *b == b'\n')?;
        let header: Header = serde_json::from_slice(&head[..end]).ok()?;
        let file_of = (header.dev, header.ino, header.born_ns);
        let same = header.schema == SCHEMA
            && header.kinds == kinds()
            && segment.id.2 != 0
            && file_of == segment.id
            && segment.len >= header.len;
        if !same {
            #[cfg(test)]
            COPY_BYTES.with(|n| n.set(n.get() + head.len() as u64));
            return None;
        }
        // Bytes past the lines the header covers are an addition a crash cut before its header.
        let want = header.lines_len.min(now.len.saturating_sub(end as u64 + 1));
        let mut lines = Vec::with_capacity(usize::try_from(want).ok()?);
        lines.extend_from_slice(&head[end + 1..]);
        lines.truncate(usize::try_from(want).ok()?);
        let rest = want.saturating_sub(lines.len() as u64);
        (&mut file).take(rest).read_to_end(&mut lines).ok()?;
        #[cfg(test)]
        COPY_BYTES.with(|n| n.set(n.get() + (end + 1 + lines.len()) as u64));
        let whole = same
            && lines.len() as u64 == header.lines_len
            && seal(
                file_of,
                header.len,
                header.kinds,
                header.parsed,
                header.lines_len,
                header.lines_hash,
            ) == header.seal
            && lines.last().is_none_or(|b| *b == b'\n')
            && self.kind_index_checks.lines_match(id, index, now, &lines, header.lines_hash);
        whole.then_some(Copied {
            lines,
            len: header.len,
            parsed: header.parsed,
            hash: header.lines_hash,
        })
    }

    /// Saves `lines`, the indexed lines of the first `len` bytes of segment `index`, read from a
    /// file with stamp `segment`; `parsed`: every line of those bytes read as a record.
    pub(super) fn write_kind_index(
        &self,
        id: &str,
        index: u32,
        segment: &Stamp,
        len: u64,
        parsed: bool,
        lines: &[u8],
    ) -> Result<()> {
        let (dev, ino, born_ns) = segment.id;
        if born_ns == 0 {
            return Ok(());
        }
        // Never makes the chat's folder: a scan that outlived a delete leaves none behind. Owner-only
        // whatever the umask: under 002 it would be group-writable, and `private_state_dir`
        // refuses that.
        let dir = self.dir(id).join(DIR);
        if let Err(e) = crate::home_fs::create_dir(&dir, 0o700)
            && e.kind() != std::io::ErrorKind::AlreadyExists
        {
            return Err(e.into());
        }
        crate::config::private_state_dir(&dir)?;
        let header = Header::new(
            (dev, ino, born_ns),
            len,
            parsed,
            lines.len() as u64,
            fnv_on(FNV_START, lines),
        );
        let mut out = header.line().ok_or_else(|| anyhow::anyhow!("kind index header too long"))?;
        out.extend_from_slice(lines);
        crate::config::write_atomic_unsynced(&self.kind_index_path(id, index), &out)
    }

    /// Adds `lines[copied..]`, the lines read past the copy of segment `index` that `lines[..copied]`
    /// is (`copy`: `copied` and those lines' hash, as the scan read the copy), to that copy, which
    /// now covers the segment's first `len` bytes: the new lines at the end of the copy's lines,
    /// then its header again in place ([module docs](self)). False (nothing written) when the copy
    /// on disk is not the one the scan read, so the caller writes it whole. The copy's lines are
    /// not hashed again: the scan's read checked them against the hash this compares.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn append_kind_index(
        &self,
        id: &str,
        index: u32,
        segment: &Stamp,
        len: u64,
        parsed: bool,
        lines: &[u8],
        copy: (usize, u64),
    ) -> Result<bool> {
        let (copied, copied_hash) = copy;
        use std::io::{Read as _, Seek as _, SeekFrom, Write as _};
        if segment.id.2 == 0 {
            return Ok(true);
        }
        let _one = APPENDS.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let path = self.kind_index_path(id, index);
        crate::config::refuse_lost_home(&path)?;
        let mut options = crate::home_fs::OpenOptions::new();
        options.read(true).write(true);
        #[cfg(unix)]
        options.custom_flags(libc::O_NOFOLLOW);
        let mut file = options.open(&path)?;
        let mut head = vec![0u8; HEADER_WIDTH];
        if file.read_exact(&mut head).is_err() || head.last() != Some(&b'\n') {
            return Ok(false);
        }
        let Ok(old) = serde_json::from_slice::<Header>(&head) else { return Ok(false) };
        let (old_lines, new_lines) = lines.split_at(copied.min(lines.len()));
        if old.schema != SCHEMA
            || (old.dev, old.ino, old.born_ns) != segment.id
            || old.lines_len != old_lines.len() as u64
            || old.lines_hash != copied_hash
        {
            return Ok(false);
        }
        let header = Header::new(
            segment.id,
            len,
            old.parsed && parsed,
            lines.len() as u64,
            fnv_on(old.lines_hash, new_lines),
        );
        let Some(line) = header.line() else { return Ok(false) };
        let end = (HEADER_WIDTH as u64).saturating_add(old.lines_len);
        // A crash's addition past the header's lines goes first.
        file.set_len(end)?;
        file.seek(SeekFrom::Start(end))?;
        file.write_all(new_lines)?;
        file.seek(SeekFrom::Start(0))?;
        file.write_all(&line)?;
        Ok(true)
    }
}

#[cfg(test)]
#[path = "kind_index_tests.rs"]
mod tests;
