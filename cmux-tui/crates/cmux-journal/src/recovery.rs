//! Recovery: the one start path, for a clean exit, a crash, a kill -9 and an OS crash.
//!
//! 1. Take the lock; list the segments in number order; read and check each header (its
//!    journal id, number, and LSN range against the segment before it).
//! 2. Fully sync the last segment: the last process may have died after a write and before its
//!    sync. So every record handed to the replay is durable before the daemon serves.
//! 3. Read the records after the caller's compaction point (`from`) and hand them to the replay.
//!    An earlier segment is read only through the next segment's "previous last LSN": bytes after
//!    it (left by a write or sync that failed, after which the writer started a new segment) are
//!    not part of the journal. A segment whose records all lie at or before `from` is not read.
//! 4. The last segment is read up to its first record that does not check out: a torn write that
//!    never completed, so it was never acknowledged. Those bytes stay in the file; the journal
//!    goes on in a new segment whose header names the last good LSN.
//! 5. Damage that is not a torn tail (a bad header, or records missing before the next segment)
//!    keeps the valid prefix. That segment's successors move to `quarantine/` (never deleted), the
//!    report names them and the LSNs they may hold, and new records take LSNs after all of them,
//!    so no LSN is ever used twice.
//!
//! Recovery writes nothing but a sync and, when the journal does not go on in its last segment, a
//! new segment. It never truncates or deletes a segment that holds a record.

use std::path::Path;

use crate::format::{
    self, MAX_PAYLOAD_LEN, RECORD_HEADER_LEN, RecordHeader, SEGMENT_HEADER_LEN, SegmentHeader,
};
use crate::journal::OpenError;
use crate::storage::{OpenMode, Storage, StorageFile, StorageLock, SyncLevel};
use crate::{Lsn, Record};

pub(crate) const LOCK_NAME: &str = "LOCK";
pub(crate) const QUARANTINE_DIR: &str = "quarantine";
/// Segment bytes read at once.
const READ_CHUNK: usize = 1024 * 1024;

/// What recovery found ([`crate::Journal::open`]).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct OpenReport {
    /// Segments the journal holds after recovery, a new one included.
    pub segments: usize,
    /// The last LSN the journal holds or skipped over, and the LSN the next append takes.
    pub last_lsn: Lsn,
    pub next_lsn: Lsn,
    /// Records handed to the replay.
    pub replayed: u64,
    /// Bytes at the end of the last segment that hold no whole record: a write that never
    /// completed (never acknowledged). They stay in the file; the journal goes on after them in a
    /// new segment.
    pub torn_tail_bytes: u64,
    pub damage: Vec<Damage>,
}

/// What recovery could not read, beyond a torn tail. The daemon reports it to the person; moved
/// segments stay in `quarantine/` for a salvage.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Damage {
    /// `segment` could not be read past `offset` (media damage or a bug, never a crash). The
    /// segments in `moved` (every later one, and this one too when its header was bad) are in
    /// `quarantine/` now. The records after `lost_after` through `lost_through` are not in the
    /// journal; new records take LSNs after `lost_through`.
    Corrupt {
        segment: String,
        offset: u64,
        reason: String,
        moved: Vec<String>,
        lost_after: Lsn,
        lost_through: Lsn,
    },
    /// The records after `after` through `through` are not in the journal: the caller's
    /// compaction point is older than the oldest record kept.
    Missing { after: Lsn, through: Lsn },
    /// The caller's compaction point is past the journal's end: the caller has records the
    /// journal lost. New records take LSNs after the compaction point, so none is used twice.
    Ahead { journal_end: Lsn, from: Lsn },
}

/// The segment the writer appends to first.
pub(crate) struct Tail {
    pub(crate) file: Box<dyn StorageFile>,
    pub(crate) seq: u64,
    pub(crate) size: u64,
}

pub(crate) struct WriterStart {
    pub(crate) journal_id: u64,
    pub(crate) tail: Tail,
}

pub(crate) struct Recovered {
    pub(crate) lock: Box<dyn StorageLock>,
    pub(crate) next_lsn: Lsn,
    pub(crate) report: OpenReport,
    pub(crate) writer: WriterStart,
}

struct Segment {
    seq: u64,
    name: String,
    file: Box<dyn StorageFile>,
    size: u64,
    header: SegmentHeader,
}

/// Where the valid journal ends early (step 5).
struct Bad {
    /// The first listed segment to move to quarantine.
    from_seq: u64,
    segment: String,
    offset: u64,
    reason: &'static str,
    /// The highest LSN the journal is known to have held before the damage.
    lost_through: Lsn,
}

fn io(what: &'static str) -> impl FnOnce(std::io::Error) -> OpenError {
    move |error| OpenError::Io { what: what.into(), error }
}

pub(crate) fn len64(n: usize) -> u64 {
    u64::try_from(n).unwrap_or(u64::MAX)
}

pub(crate) fn recover(
    storage: &dyn Storage,
    dir: &Path,
    from: Lsn,
    replay: &mut dyn FnMut(Record<'_>) -> Result<(), String>,
) -> Result<Recovered, OpenError> {
    storage.create_dir_all(dir).map_err(io("make the folder"))?;
    let lock =
        storage.try_lock(&dir.join(LOCK_NAME)).map_err(io("lock"))?.ok_or(OpenError::Locked)?;
    let mut listed: Vec<(u64, String)> = storage
        .list(dir)
        .map_err(io("list the folder"))?
        .into_iter()
        .filter_map(|name| Some((format::parse_segment_name(&name)?, name)))
        .collect();
    listed.sort();
    let max_seq = listed.last().map_or(0, |(seq, _)| *seq);

    // 1 and 2.
    let Headers { mut segments, reuse, mut bad } = read_headers(storage, dir, &listed)?;
    if let Some(last) = segments.last_mut() {
        let mut file = storage
            .open(&dir.join(&last.name), OpenMode::Write)
            .map_err(io("open the last segment"))?;
        file.sync(SyncLevel::Full).map_err(io("sync the last segment"))?;
        last.file = file;
    }

    // 3 and 4.
    let mut report = OpenReport::default();
    let mut journal_end = 0;
    let mut tail_cut = None;
    let mut index = 0;
    while let Some(segment) = segments.get(index) {
        let next = segments.get(index.saturating_add(1));
        let trusted_end = next.map(|next| next.header.prev_last);
        if trusted_end.is_some_and(|end| end <= from) {
            index = index.saturating_add(1);
            continue;
        }
        let read = read_records(segment, trusted_end, from, replay, &mut report)?;
        journal_end = read.end;
        if let (Some(end), Some(next)) = (trusted_end, next)
            && read.end < end
        {
            bad = Some(Bad {
                from_seq: next.seq,
                segment: segment.name.clone(),
                offset: read.offset,
                reason: "records are missing before the next segment",
                lost_through: end,
            });
            segments.truncate(index.saturating_add(1));
            break;
        }
        if trusted_end.is_none() && read.offset < segment.size {
            tail_cut = Some(segment.size.saturating_sub(read.offset));
        }
        index = index.saturating_add(1);
    }

    // 5.
    let damaged = bad.is_some();
    let mut lost_through = journal_end;
    if let Some(bad) = bad {
        let moved = quarantine(storage, dir, &listed, bad.from_seq)?;
        lost_through = lost_through.max(bad.lost_through).max(moved.highest);
        report.damage.push(Damage::Corrupt {
            segment: bad.segment,
            offset: bad.offset,
            reason: bad.reason.to_owned(),
            moved: moved.names,
            lost_after: journal_end,
            lost_through,
        });
    }
    if let Some(first) = segments.first()
        && from < first.header.prev_last
    {
        report.damage.push(Damage::Missing { after: from, through: first.header.prev_last });
    }
    if from > journal_end {
        report.damage.push(Damage::Ahead { journal_end, from });
    }
    let next_lsn = journal_end.max(lost_through).max(from).saturating_add(1);

    // The writer goes on in the last segment only when it ends in a whole record, nothing is
    // damaged and no LSN is skipped; else a new segment starts now, before any append.
    let journal_id = segments.first().map_or_else(new_journal_id, |first| first.header.journal_id);
    let go_on = !damaged
        && reuse.is_none()
        && tail_cut.is_none()
        && next_lsn == journal_end.saturating_add(1);
    let kept = segments.len();
    let tail = match segments.pop() {
        Some(last) if go_on => Tail { file: last.file, seq: last.seq, size: last.size },
        _ => {
            let header = SegmentHeader {
                journal_id,
                seq: reuse.unwrap_or_else(|| max_seq.saturating_add(1)),
                first_lsn: next_lsn,
                prev_last: journal_end,
            };
            let file = make_segment(storage, dir, &header).map_err(io("make a segment"))?;
            report.segments = 1;
            Tail { file, seq: header.seq, size: len64(SEGMENT_HEADER_LEN) }
        }
    };
    report.segments = report.segments.saturating_add(kept);
    report.last_lsn = next_lsn.saturating_sub(1);
    report.next_lsn = next_lsn;
    report.torn_tail_bytes = tail_cut.unwrap_or(0);
    Ok(Recovered { lock, next_lsn, report, writer: WriterStart { journal_id, tail } })
}

/// Makes segment `header.seq` (a file that holds a torn header is made again): its header,
/// fully synced, and its folder entry, synced.
pub(crate) fn make_segment(
    storage: &dyn Storage,
    dir: &Path,
    header: &SegmentHeader,
) -> std::io::Result<Box<dyn StorageFile>> {
    let mut file = storage.open(&dir.join(format::segment_name(header.seq)), OpenMode::Create)?;
    file.append(&header.encode())?;
    file.sync(SyncLevel::Full)?;
    storage.sync_dir(dir)?;
    Ok(file)
}

struct Headers {
    segments: Vec<Segment>,
    /// The last segment's number when its header never got whole (its creation did not
    /// complete): the writer makes it again.
    reuse: Option<u64>,
    bad: Option<Bad>,
}

fn read_headers(
    storage: &dyn Storage,
    dir: &Path,
    listed: &[(u64, String)],
) -> Result<Headers, OpenError> {
    let mut segments: Vec<Segment> = Vec::new();
    let mut reuse = None;
    let mut bad = None;
    for (index, (seq, name)) in listed.iter().enumerate() {
        let file = storage.open(&dir.join(name), OpenMode::Read).map_err(io("open a segment"))?;
        let size = file.size().map_err(io("read a segment's size"))?;
        let last = index.saturating_add(1) == listed.len();
        let decoded = read_header(file.as_ref(), size)?;
        match decoded.and_then(|header| follows(&segments, header, *seq)) {
            Ok(header) => {
                segments.push(Segment { seq: *seq, name: name.clone(), file, size, header });
            }
            Err(Unreadable::Header(_)) if last && size <= len64(SEGMENT_HEADER_LEN) => {
                reuse = Some(*seq);
            }
            Err(reason) => {
                let lost_through =
                    segments.last().map_or(0, |prev| prev.header.first_lsn.saturating_sub(1));
                bad = Some(Bad {
                    from_seq: *seq,
                    segment: name.clone(),
                    offset: 0,
                    reason: reason.text(),
                    lost_through,
                });
                break;
            }
        }
    }
    Ok(Headers { segments, reuse, bad })
}

/// Why a header does not start the next segment of this journal.
enum Unreadable {
    Header(&'static str),
    Chain(&'static str),
}

impl Unreadable {
    fn text(&self) -> &'static str {
        match self {
            Self::Header(text) | Self::Chain(text) => text,
        }
    }
}

fn read_header(
    file: &dyn StorageFile,
    size: u64,
) -> Result<Result<SegmentHeader, Unreadable>, OpenError> {
    if size < len64(SEGMENT_HEADER_LEN) {
        return Ok(Err(Unreadable::Header("short segment header")));
    }
    let mut bytes = [0u8; SEGMENT_HEADER_LEN];
    file.read_at(0, &mut bytes).map_err(io("read a segment header"))?;
    Ok(SegmentHeader::decode(&bytes).map_err(Unreadable::Header))
}

/// `header` when it is segment `seq` of the journal `segments` holds, right after its last one.
fn follows(
    segments: &[Segment],
    header: SegmentHeader,
    seq: u64,
) -> Result<SegmentHeader, Unreadable> {
    if header.seq != seq {
        return Err(Unreadable::Chain("the segment number does not match its file name"));
    }
    if header.first_lsn <= header.prev_last {
        return Err(Unreadable::Chain("the segment's LSN range is empty"));
    }
    if let Some(first) = segments.first()
        && first.header.journal_id != header.journal_id
    {
        return Err(Unreadable::Chain("the segment belongs to another journal"));
    }
    if let Some(prev) = segments.last()
        && header.prev_last < prev.header.first_lsn.saturating_sub(1)
    {
        return Err(Unreadable::Chain("the segment does not follow the one before it"));
    }
    Ok(header)
}

/// How far one segment's records read: the file offset after the last good record, and the
/// LSN of that record (the LSN before the segment's first when it has none).
struct Read {
    offset: u64,
    end: Lsn,
}

fn read_records(
    segment: &Segment,
    trusted_end: Option<Lsn>,
    from: Lsn,
    replay: &mut dyn FnMut(Record<'_>) -> Result<(), String>,
    report: &mut OpenReport,
) -> Result<Read, OpenError> {
    let mut reader =
        Reader { file: segment.file.as_ref(), size: segment.size, buf: Vec::new(), at: 0 };
    let mut offset = len64(SEGMENT_HEADER_LEN);
    let mut expected = segment.header.first_lsn;
    loop {
        if trusted_end.is_some_and(|end| expected > end) {
            break;
        }
        let Some(head) = reader.bytes(offset, RECORD_HEADER_LEN)? else { break };
        let Ok(head) = <[u8; RECORD_HEADER_LEN]>::try_from(head) else { break };
        let Some(header) = RecordHeader::decode(&head) else { break };
        if header.len > MAX_PAYLOAD_LEN {
            break;
        }
        let payload_at = offset.saturating_add(len64(RECORD_HEADER_LEN));
        let Some(payload) = reader.bytes(payload_at, header.len)? else { break };
        let Ok(class) = header.verify(&head, payload, expected) else { break };
        if expected > from {
            replay(Record { lsn: expected, kind: header.kind, class, payload })
                .map_err(|error| OpenError::Replay { lsn: expected, error })?;
            report.replayed = report.replayed.saturating_add(1);
        }
        offset = payload_at.saturating_add(len64(header.len));
        expected = expected.saturating_add(1);
    }
    Ok(Read { offset, end: expected.saturating_sub(1) })
}

/// Reads a segment in chunks.
struct Reader<'a> {
    file: &'a dyn StorageFile,
    size: u64,
    buf: Vec<u8>,
    /// The file offset of `buf`'s first byte.
    at: u64,
}

impl Reader<'_> {
    /// `len` bytes at `offset`, or `None` when the file ends first.
    fn bytes(&mut self, offset: u64, len: usize) -> Result<Option<&[u8]>, OpenError> {
        let Some(end) = offset.checked_add(len64(len)) else { return Ok(None) };
        if end > self.size {
            return Ok(None);
        }
        let buffered_end = self.at.saturating_add(len64(self.buf.len()));
        if offset < self.at || end > buffered_end {
            let left = usize::try_from(self.size.saturating_sub(offset)).unwrap_or(usize::MAX);
            self.buf.resize(len.max(READ_CHUNK).min(left), 0);
            self.file.read_at(offset, &mut self.buf).map_err(io("read a segment"))?;
            self.at = offset;
        }
        let start = usize::try_from(offset.saturating_sub(self.at)).unwrap_or(usize::MAX);
        Ok(self.buf.get(start..start.saturating_add(len)))
    }
}

/// The segments moved to quarantine, and the highest LSN they hold.
struct Moved {
    names: Vec<String>,
    highest: Lsn,
}

/// Moves every listed segment from number `from_seq` on into `quarantine/`, under a name no
/// earlier recovery used.
fn quarantine(
    storage: &dyn Storage,
    dir: &Path,
    listed: &[(u64, String)],
    from_seq: u64,
) -> Result<Moved, OpenError> {
    let target = dir.join(QUARANTINE_DIR);
    storage.create_dir_all(&target).map_err(io("make the quarantine folder"))?;
    let taken = storage.list(&target).map_err(io("list the quarantine folder"))?;
    let mut moved = Moved { names: Vec::new(), highest: 0 };
    for (_, name) in listed.iter().filter(|(seq, _)| *seq >= from_seq) {
        let path = dir.join(name);
        moved.highest = moved.highest.max(highest_lsn(storage, &path)?);
        let mut attempt = 0u32;
        let new_name = loop {
            let candidate = format!("{name}.{attempt}");
            if !taken.contains(&candidate) {
                break candidate;
            }
            attempt = attempt.saturating_add(1);
        };
        storage.rename(&path, &target.join(&new_name)).map_err(io("move a damaged segment"))?;
        moved.names.push(new_name);
    }
    storage.sync_dir(&target).map_err(io("sync the quarantine folder"))?;
    storage.sync_dir(dir).map_err(io("sync the folder"))?;
    Ok(moved)
}

/// The highest LSN a segment's readable records and header name (0 when its header is bad).
fn highest_lsn(storage: &dyn Storage, path: &Path) -> Result<Lsn, OpenError> {
    let file = storage.open(path, OpenMode::Read).map_err(io("open a damaged segment"))?;
    let size = file.size().map_err(io("read a damaged segment's size"))?;
    let Ok(header) = read_header(file.as_ref(), size)? else { return Ok(0) };
    let segment = Segment { seq: header.seq, name: String::new(), file, size, header };
    let read = read_records(&segment, None, Lsn::MAX, &mut |_| Ok(()), &mut OpenReport::default())?;
    Ok(read.end.max(header.prev_last))
}

/// A random journal id (never 0), from a per-process random hasher key and the clock.
fn new_journal_id() -> u64 {
    use std::hash::{BuildHasher, Hasher};
    let mut hasher = std::collections::hash_map::RandomState::new().build_hasher();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_nanos());
    hasher.write_u128(now);
    hasher.write_u32(std::process::id());
    hasher.finish() | 1
}
