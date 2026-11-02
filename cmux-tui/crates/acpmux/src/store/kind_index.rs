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
//! is read past and made again. A copy is written whole under a temporary name and renamed into
//! place, so a crash leaves the old copy or none. A scan writes one when it had none or read at
//! least [`COPY_AFTER`] bytes past it; nothing is written on the append path, and a chat's folder
//! is deleted with its copies.
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
    "inbox_noticed",
    "inbox_answered",
    "inbox_read",
    "inbox_removed",
];

/// The folder of a chat's copies, beside its `events`.
pub const DIR: &str = "events-index";
const SCHEMA: &str = "acpmux.kind-index.v4";

/// A scan that read this many bytes of a segment past its copy saves the copy again.
pub(super) const COPY_AFTER: u64 = 1 << 20;

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
    /// The copied lines' length, and an FNV-1a hash of every other field and the lines: a damaged
    /// or cut copy is read past.
    lines_len: u64,
    lines_hash: u64,
}

/// FNV-1a, 64 bits, of a copy's file, coverage, kinds and lines: stable across builds, so a copy
/// one daemon wrote checks in the next.
fn seal(id: (u64, u64, u64), len: u64, kinds: u64, parsed: bool, lines: &[u8]) -> u64 {
    let fields = [id.0, id.1, id.2, len, kinds, u64::from(parsed), lines.len() as u64];
    fnv(fields.iter().flat_map(|f| f.to_le_bytes()).chain(lines.iter().copied()))
}

/// FNV-1a, 64 bits, of [`INDEXED_KINDS`].
fn kinds() -> u64 {
    fnv(INDEXED_KINDS.iter().flat_map(|k| k.bytes().chain([b'\n'])))
}

fn fnv(bytes: impl Iterator<Item = u8>) -> u64 {
    bytes.fold(0xcbf2_9ce4_8422_2325, |h, b| (h ^ u64::from(b)).wrapping_mul(0x100_0000_01b3))
}

/// What a copy is of: the segment file (its device, inode and birth time) and its length now.
pub(super) struct Stamp {
    id: (u64, u64, u64),
    len: u64,
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

/// The birth time Linux keeps for `file`, read with `statx`. Rust's `Metadata::created` asks
/// `statx` only on glibc: on musl, the static build every Linux daemon runs, it always fails, so
/// no copy was ever written or read there, and every log load read and parsed whole logs: four
/// passes over each live chat's log on a restart, about 12 GB on a host with 3.1 GB of them. None: the kernel or
/// file system keeps no birth time (the copy then stays off, as before).
#[cfg(target_os = "linux")]
pub(super) fn birth_ns(file: &std::fs::File) -> Option<u64> {
    use std::os::fd::AsRawFd;
    /// The kernel's `struct statx` (`linux/stat.h`): `stx_mask` first, `stx_btime` at byte 80
    /// (after `stx_atime`), padded to its full 256 bytes.
    #[repr(C)]
    struct Statx {
        mask: u32,
        head: [u32; 19],
        btime_sec: i64,
        btime_nsec: u32,
        rest: [u32; 41],
    }
    const _: () = assert!(std::mem::size_of::<Statx>() == 256);
    const _: () = assert!(std::mem::offset_of!(Statx, btime_sec) == 80);
    const STATX_BTIME: u32 = 0x800;
    let mut buf = Statx { mask: 0, head: [0; 19], btime_sec: 0, btime_nsec: 0, rest: [0; 41] };
    // SAFETY: statx writes at most `sizeof(struct statx)` (256) bytes into `buf`, which is that
    // size; the path is an empty C string and `AT_EMPTY_PATH` makes it read the open fd itself.
    let result = unsafe {
        libc::syscall(
            libc::SYS_statx,
            file.as_raw_fd(),
            c"".as_ptr(),
            libc::AT_EMPTY_PATH,
            STATX_BTIME,
            &mut buf as *mut Statx,
        )
    };
    if result != 0 || buf.mask & STATX_BTIME == 0 || buf.btime_sec < 0 {
        return None;
    }
    Some(buf.btime_sec as u64 * 1_000_000_000 + u64::from(buf.btime_nsec))
}

#[cfg(not(target_os = "linux"))]
pub(super) fn birth_ns(_file: &std::fs::File) -> Option<u64> {
    None
}

/// Whether a line belongs in a copy: its kind is indexed, or its head does not say (it is parsed
/// where it is read, as the segment's would be).
pub(super) fn indexed(line: &[u8]) -> bool {
    record_kind(line).is_none_or(|kind| INDEXED_KINDS.iter().any(|k| k.as_bytes() == kind))
}

/// One scan for `kinds`: whether it may take copies, and whether it is strict.
struct Scan<'a> {
    kinds: &'a [&'a str],
    copied: bool,
    strict: bool,
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
    fn kind_index_path(&self, id: &str, index: u32) -> PathBuf {
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
        // Debug builds only: `ACPMUX_TEST_SCAN_DELAY_MS` holds each log scan, as a slow disk or a
        // long log does (`tests/restart_reattach.rs`). Bounded; release builds have no seam.
        #[cfg(debug_assertions)]
        if let Some(ms) =
            std::env::var("ACPMUX_TEST_SCAN_DELAY_MS").ok().and_then(|v| v.parse::<u64>().ok())
        {
            std::thread::sleep(std::time::Duration::from_millis(ms.min(1_000)));
        }
        // A strict read learns that the log's segments could not be listed (`segments` lists
        // none then), as `scan_strict` does.
        if strict {
            std::fs::read_dir(self.dir(id).join("events"))?;
        }
        let copied = kinds.iter().all(|k| INDEXED_KINDS.contains(k));
        let scan = Scan { kinds, copied, strict };
        for (index, path) in self.segments(id)? {
            if !self.scan_segment(id, index, &path, &scan, visit)? {
                break;
            }
        }
        Ok(())
    }

    /// One segment of [`Self::scan_kinds_in`]; false when `visit` stopped the scan.
    fn scan_segment(
        &self,
        id: &str,
        index: u32,
        path: &Path,
        scan: &Scan<'_>,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<bool> {
        let mut file = crate::config::private_state_file(path)?;
        // What a copy is of: the file this reads, however its path changes meanwhile.
        let stamp = if scan.copied { Some(Stamp::of(&file)?) } else { None };
        let (mut copy, from, mut parsed) = match stamp
            .as_ref()
            .and_then(|s| self.read_kind_index(id, index, s))
        {
            Some((lines, from, parsed)) if parsed || !scan.strict => (Some(lines), from, parsed),
            _ => (None, 0, true),
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
            if !blank
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
            && let Err(e) = self.write_kind_index(
                id,
                index,
                &stamp,
                from.saturating_add(covered),
                parsed,
                lines,
            )
        {
            tracing::warn!(session = %id, segment = index, "saving the log's kind index failed: {e}");
        }
        Ok(true)
    }

    /// The copied lines of segment `index`, the bytes of it they cover, and whether every line of
    /// those bytes read, when the copy is of the file `segment` (the open segment's stamp) and
    /// [`INDEXED_KINDS`], no longer than it, and whole. A system that names no birth time keeps no
    /// copy: an inode a later file reuses would pass for the same.
    pub(super) fn read_kind_index(
        &self,
        id: &str,
        index: u32,
        segment: &Stamp,
    ) -> Option<(Vec<u8>, u64, bool)> {
        let mut bytes = Vec::new();
        let copy = self.kind_index_path(id, index);
        crate::config::private_state_file(&copy).ok()?.read_to_end(&mut bytes).ok()?;
        let end = bytes.iter().position(|b| *b == b'\n')?;
        let header: Header = serde_json::from_slice(&bytes[..end]).ok()?;
        let id = segment.id;
        let lines = bytes.split_off(end.saturating_add(1));
        let file = (header.dev, header.ino, header.born_ns);
        let whole = lines.len() as u64 == header.lines_len
            && seal(file, header.len, header.kinds, header.parsed, &lines) == header.lines_hash
            && lines.last().is_none_or(|b| *b == b'\n');
        let same = header.schema == SCHEMA && header.kinds == kinds() && id.2 != 0 && file == id;
        (same && whole && segment.len >= header.len).then_some((lines, header.len, header.parsed))
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
        let mut made = std::fs::DirBuilder::new();
        #[cfg(unix)]
        std::os::unix::fs::DirBuilderExt::mode(&mut made, 0o700);
        if let Err(e) = made.create(&dir)
            && e.kind() != std::io::ErrorKind::AlreadyExists
        {
            return Err(e.into());
        }
        crate::config::private_state_dir(&dir)?;
        let kinds = kinds();
        let lines_len = lines.len() as u64;
        let lines_hash = seal((dev, ino, born_ns), len, kinds, parsed, lines);
        let header = Header {
            schema: SCHEMA.into(),
            dev,
            ino,
            born_ns,
            len,
            kinds,
            parsed,
            lines_len,
            lines_hash,
        };
        let mut out = serde_json::to_vec(&header)?;
        out.push(b'\n');
        out.extend_from_slice(lines);
        write_atomic(&self.kind_index_path(id, index), &out)
    }
}

#[cfg(test)]
#[path = "kind_index_tests.rs"]
mod tests;
