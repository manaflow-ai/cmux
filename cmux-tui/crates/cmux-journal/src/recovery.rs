//! Recovery: the one start path, for a clean exit, a crash, a kill -9 and an OS crash.
//!
//! 1. Take the lock; list the segments (and the ones in `quarantine/`); read and check each
//!    live header (journal id, number, LSN chain). No file stays open after its header is read.
//! 2. Fully sync the last segment. The records the replay gets are then as durable as acked ones.
//! 3. Read the records after the caller's compaction point (`from`) and hand them to the replay.
//!    An earlier segment is read only through the next segment's "previous last LSN": bytes after
//!    it are not part of the journal. A segment whose records all lie at or before `from` is read
//!    for its header only.
//! 4. The last segment is read up to its first entry that does not check out. Its records after
//!    its last sync marker (`format.rs`) are not known to be on the disk: a sync may have failed
//!    for them, and a later sync on another descriptor can report success for pages the kernel
//!    dropped. So recovery writes them again into a new segment, made whole and synced under a
//!    staging name and only then renamed into place, and the journal goes on there. A torn tail
//!    stays in its file. The bytes after the first bad entry are scanned for entries that still
//!    check out: a sync marker among them means synced records are damaged (media damage, never a
//!    crash), and their LSNs are never used again.
//! 5. Damage that is not a torn tail (a bad header, or records missing before the next segment)
//!    keeps the valid prefix; the later segments move to `quarantine/` (never deleted). New
//!    records take LSNs after every LSN that any segment, live or quarantined, holds, so no LSN
//!    is ever used twice, also after a crash in the middle of an earlier recovery. The damage is
//!    written to `DAMAGE` (whole, synced) before the new segment of step 6 hides it from later
//!    opens, and every open reports it again until `Journal::clear_damage`.
//! 6. The journal goes on in a segment this open makes (the copy of step 4, or an empty one), never
//!    in a segment an earlier process wrote: that one may hold a page its cache had and its disk
//!    never got.
//!
//! Recovery writes nothing but syncs, new segments, the renames into `quarantine/` and the damage
//! record `DAMAGE`. It never shortens or deletes a segment.

use std::path::Path;

use crate::format::{self, Entry, RECORD_HEADER_LEN, SEGMENT_HEADER_LEN, SegmentHeader};
use crate::journal::OpenError;
use crate::storage::{OpenMode, Storage, StorageFile, StorageLock, SyncLevel};
use crate::{Lsn, Record};

mod damage;
mod scan;
pub(crate) use damage::clear_damage;
use damage::{read_damage, write_damage};
use scan::{Reader, quarantine, quarantined_floor, quarantined_journal_id, scan_beyond_path};

pub(crate) const LOCK_NAME: &str = "LOCK";
pub(crate) const QUARANTINE_DIR: &str = "quarantine";
/// The damage earlier opens found ([`Damage::Corrupt`]), kept until `Journal::clear_damage`.
pub(crate) const DAMAGE_NAME: &str = "DAMAGE";
/// The name `Journal::clear_damage` gives a cleared damage record in `quarantine/`.
pub(crate) const CLEARED_DAMAGE: &str = "damage-report";
/// A segment recovery writes is first written whole under its name plus this, then renamed.
const STAGING_SUFFIX: &str = ".new";
/// Segment bytes read at once.
const READ_CHUNK: usize = 1024 * 1024;

/// What recovery found ([`crate::Journal::open`]).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct OpenReport {
    /// Live segments after recovery, the ones it made included.
    pub segments: usize,
    /// The last LSN the journal holds or skipped over, and the LSN the next append takes.
    pub last_lsn: Lsn,
    pub next_lsn: Lsn,
    /// Records handed to the replay.
    pub replayed: u64,
    /// Records of the last segment after its last sync marker, written again into a new segment.
    pub rewritten: u64,
    /// Bytes at the end of the last segment that hold no whole entry: a write that never
    /// completed. They stay in the file; the journal goes on in a new segment.
    pub torn_tail_bytes: u64,
    /// Records found after such a tear that no sync marker vouches for (an OS crash wrote some
    /// pages of an unsynced write and not others), as (first, last) LSN. They are not kept, and
    /// their LSNs are not used again.
    pub torn_lsns: Option<(Lsn, Lsn)>,
    pub damage: Vec<Damage>,
}

/// What recovery could not read, beyond a torn tail: media damage or a bug, never a crash. The
/// daemon reports it to the person; moved segments stay in `quarantine/` for a salvage. Every
/// open reports the losses ([`Damage::Corrupt`]) that earlier opens found, until the daemon calls
/// `Journal::clear_damage`; a loss that lies inside another is reported once, as the larger range.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Damage {
    /// `segment` could not be read past `offset`. The segments in `moved` are in `quarantine/`
    /// now (named `<segment>.<n>`). The records after `lost_after` through `lost_through` are not
    /// in the journal; new records take LSNs after `lost_through`.
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
    /// The live segments after recovery, oldest first (`Journal::retire_through`).
    pub(crate) live: Vec<LiveSegment>,
}

/// A live segment: its number and its header's "previous last LSN". Every record recovery reads
/// from a segment lies at or before the next segment's `prev_last`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct LiveSegment {
    pub(crate) seq: u64,
    pub(crate) prev_last: Lsn,
}

/// A live segment whose header checked out. Its file is opened again to read its records.
struct Segment {
    seq: u64,
    name: String,
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
    /// The highest LSN the journal is known to have held past the damage.
    lost_through: Lsn,
}

/// `damage` without the losses ([`Damage::Corrupt`]) whose LSN range lies inside another's; of
/// two equal ranges the first stays. Other damage stays as it is.
fn distinct_losses(damage: Vec<Damage>) -> Vec<Damage> {
    let ranges: Vec<Option<(Lsn, Lsn)>> = damage
        .iter()
        .map(|entry| match entry {
            Damage::Corrupt { lost_after, lost_through, .. } => Some((*lost_after, *lost_through)),
            _ => None,
        })
        .collect();
    let inside_another = |index: usize| {
        let Some(Some((after, through))) = ranges.get(index).copied() else { return false };
        ranges.iter().enumerate().any(|(other, range)| {
            let Some((other_after, other_through)) = *range else { return false };
            other != index
                && other_after <= after
                && through <= other_through
                && ((other_after, other_through) != (after, through) || other < index)
        })
    };
    damage
        .into_iter()
        .enumerate()
        .filter(|(index, _)| !inside_another(*index))
        .map(|(_, entry)| entry)
        .collect()
}

fn io(what: &'static str) -> impl FnOnce(std::io::Error) -> OpenError {
    move |error| OpenError::Io { what: what.into(), error }
}

pub(crate) fn len64(n: usize) -> u64 {
    u64::try_from(n).unwrap_or(u64::MAX)
}

fn usize_of(n: u64) -> usize {
    usize::try_from(n).unwrap_or(usize::MAX)
}

pub(crate) fn recover(
    storage: &dyn Storage,
    dir: &Path,
    from: Lsn,
    replay: &mut dyn FnMut(Record<'_>) -> Result<(), String>,
) -> Result<Recovered, OpenError> {
    storage.create_dir_all(dir).map_err(io("make the folder"))?;
    // The folder's own entry, durable before anything inside it counts.
    if let Some(parent) = dir.parent().filter(|parent| !parent.as_os_str().is_empty()) {
        storage.sync_dir(parent).map_err(io("sync the parent folder"))?;
    }
    let lock =
        storage.try_lock(&dir.join(LOCK_NAME)).map_err(io("lock"))?.ok_or(OpenError::Locked)?;
    let earlier = read_damage(storage, dir)?;
    let listed = list_segments(storage, dir)?;
    let quarantined = list_quarantined(storage, dir)?;
    let live_max_seq = listed.last().map_or(0, |(seq, _)| *seq);
    let q_max_seq = quarantined.iter().map(|(seq, _)| *seq).max().unwrap_or(0);

    // 1 and 2.
    let Headers { mut segments, reuse, mut bad } = read_headers(storage, dir, &listed)?;
    // The newest segment whose header checked out. Only such a header carries the LSN floor of
    // the quarantine before it (a damaged one says nothing: review G7).
    let checked_max_seq = segments.last().map_or(0, |segment| segment.seq);
    // The quarantine is unfinished, or its floor is not known from a live header.
    let quarantine_open = q_max_seq > checked_max_seq;
    if let Some(last) = segments.last() {
        storage
            .open(&dir.join(&last.name), OpenMode::Write)
            .and_then(|mut file| file.sync(SyncLevel::Full))
            .map_err(io("sync the last segment"))?;
    }

    // 3 and 4.
    let mut report = OpenReport::default();
    let mut journal_end = 0;
    // The last segment's read (the last one is never skipped: it has no next segment), and
    // whether a hole made an earlier segment the last one.
    let mut last_read = None;
    let mut hole = false;
    let mut index = 0;
    while let Some(segment) = segments.get(index) {
        let next = segments.get(index.saturating_add(1));
        let trusted_end = next.map(|next| next.header.prev_last);
        if trusted_end.is_some_and(|end| end <= from) {
            index = index.saturating_add(1);
            continue;
        }
        let read = read_segment(storage, dir, segment, trusted_end, from, replay, &mut report)?;
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
            // The next segment's header vouched for this one up to the damage: no tail to copy.
            last_read = Some(Read { vouched: read.end, ..read });
            hole = true;
            segments.truncate(index.saturating_add(1));
            break;
        }
        if next.is_none() {
            last_read = Some(read);
        }
        index = index.saturating_add(1);
    }
    // The bytes after the last segment's first bad entry. After a hole they are the damage that
    // step 5 reports; they still raise the floor.
    let mut floor = journal_end.max(from);
    if let (Some(last), Some(read)) = (segments.last(), last_read.as_ref())
        && read.offset < last.size
    {
        let beyond = scan_beyond_path(storage, &dir.join(&last.name), read.offset, read.end)?;
        floor = floor.max(beyond.max_lsn);
        if !hole {
            if beyond.marker {
                report.damage.push(Damage::Corrupt {
                    segment: last.name.clone(),
                    offset: read.offset,
                    reason: "a synced record is damaged".to_owned(),
                    moved: Vec::new(),
                    lost_after: read.end,
                    lost_through: beyond.max_lsn,
                });
            } else {
                report.torn_tail_bytes = last.size.saturating_sub(read.offset);
                if beyond.max_lsn > read.end {
                    report.torn_lsns = Some((read.end.saturating_add(1), beyond.max_lsn));
                }
            }
        }
    }

    // 5: every LSN a quarantined segment holds counts, from this open's moves and earlier ones.
    // Once a segment whose header checked out is numbered above every quarantined one, it was
    // made after their quarantine with a first LSN above all of theirs, and `journal_end` is at
    // least that: the quarantined files are not read again (review G4). The scan starts from the
    // running floor, so a quarantined file with no readable header is scanned for LSNs above
    // what is already counted (review G7).
    let before_quarantine = floor;
    let q_floor =
        if quarantine_open { quarantined_floor(storage, dir, &quarantined, floor)? } else { floor };
    floor = floor.max(q_floor);
    // Reported only when the quarantine holds LSNs that nothing else counted: an old quarantine
    // behind a segment torn by a crash at its creation holds none, and a crash is not damage.
    if quarantine_open && bad.is_none() && q_floor > before_quarantine {
        // An earlier recovery moved segments and stopped before its next segment was made, or
        // that segment's header is damaged.
        report.damage.push(Damage::Corrupt {
            segment: format::segment_name(q_max_seq),
            offset: 0,
            reason: "segments in quarantine/ hold LSNs after the newest segment that reads: an \
                     earlier recovery stopped before it made the next segment, or its header is \
                     damaged"
                .to_owned(),
            moved: quarantined.iter().map(|(_, name)| name.clone()).collect(),
            lost_after: journal_end,
            lost_through: q_floor,
        });
    }
    let mut max_seq = live_max_seq.max(q_max_seq);
    let mut reuse = reuse;
    if let Some(seq) = reuse
        && seq <= q_max_seq
    {
        // Not reachable (a torn header is the newest creation): moved, so no live segment lies
        // below a quarantined one.
        if bad.is_none() {
            bad = Some(Bad {
                from_seq: seq,
                segment: format::segment_name(seq),
                offset: 0,
                reason: "a segment with no header lies below quarantined segments",
                lost_through: journal_end,
            });
        }
        reuse = None;
    }
    if let Some(bad) = bad {
        let moved = quarantine(storage, dir, &listed, bad.from_seq, floor)?;
        let lost_through = floor.max(bad.lost_through).max(moved.highest);
        floor = lost_through;
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
    let next_lsn = floor.saturating_add(1);

    // Where the writer starts.
    let journal_id = match segments.first() {
        Some(first) => first.header.journal_id,
        None => quarantined_journal_id(storage, dir, &quarantined)?.unwrap_or_else(new_journal_id),
    };
    let copy = last_read.as_ref().filter(|read| read.end > read.vouched);
    // The damage found here, durable before the new segment hides it from every later open
    // (review G2), after the damage earlier opens recorded. A loss that lies inside another is
    // the same loss found again (after a crash, or by two steps of this open): it is recorded and
    // reported once, as the larger range (review N1).
    let mut all = earlier.clone();
    all.append(&mut report.damage);
    let all = distinct_losses(all);
    let recorded: Vec<Damage> =
        all.iter().filter(|damage| matches!(damage, Damage::Corrupt { .. })).cloned().collect();
    if recorded != earlier {
        write_damage(storage, dir, &recorded).map_err(io("record the damage"))?;
    }
    report.damage = all;
    // The writer always starts in a segment this open makes: an earlier process's segment may
    // hold a page that its cache had and its disk never got (a failed sync), so nothing is
    // appended to it again. It is read only through the next segment's "previous last LSN".
    let kept = segments.len();
    let mut live: Vec<LiveSegment> = segments
        .iter()
        .map(|segment| LiveSegment { seq: segment.seq, prev_last: segment.header.prev_last })
        .collect();
    let mut made = 0usize;
    let mut next_seq = || {
        let seq = reuse.take().unwrap_or_else(|| max_seq.saturating_add(1));
        max_seq = max_seq.max(seq);
        seq
    };
    let mut tail = None;
    let mut through = journal_end;
    if let Some(read) = copy {
        // Step 4: the unvouched records, again, in a segment of their own: the bytes the
        // checked read returned, never a second read of the file.
        let body = &read.unvouched;
        let header = SegmentHeader {
            journal_id,
            seq: next_seq(),
            first_lsn: read.vouched.saturating_add(1),
            prev_last: read.vouched,
        };
        let file = stage_segment(storage, dir, &header, body, Some(read.end))
            .map_err(io("write the unsynced records again"))?;
        let size = len64(SEGMENT_HEADER_LEN)
            .saturating_add(len64(body.len()))
            .saturating_add(len64(RECORD_HEADER_LEN));
        report.rewritten = read.end.saturating_sub(read.vouched);
        made = made.saturating_add(1);
        through = read.end;
        live.push(LiveSegment { seq: header.seq, prev_last: header.prev_last });
        tail = Some(Tail { file, seq: header.seq, size });
    }
    let tail = match tail {
        Some(tail) if next_lsn == through.saturating_add(1) => tail,
        _ => {
            let header = SegmentHeader {
                journal_id,
                seq: next_seq(),
                first_lsn: next_lsn,
                prev_last: through,
            };
            let file =
                stage_segment(storage, dir, &header, &[], None).map_err(io("make a segment"))?;
            made = made.saturating_add(1);
            live.push(LiveSegment { seq: header.seq, prev_last: header.prev_last });
            Tail { file, seq: header.seq, size: len64(SEGMENT_HEADER_LEN) }
        }
    };
    report.segments = kept.saturating_add(made);
    report.last_lsn = next_lsn.saturating_sub(1);
    report.next_lsn = next_lsn;
    Ok(Recovered { lock, next_lsn, report, writer: WriterStart { journal_id, tail }, live })
}

/// The live segment files, by number.
fn list_segments(storage: &dyn Storage, dir: &Path) -> Result<Vec<(u64, String)>, OpenError> {
    let mut listed: Vec<(u64, String)> = storage
        .list(dir)
        .map_err(io("list the folder"))?
        .into_iter()
        .filter_map(|name| Some((format::parse_segment_name(&name)?, name)))
        .collect();
    listed.sort();
    Ok(listed)
}

/// The files in `quarantine/` (named `<segment>.<n>`), by the segment number in their name.
fn list_quarantined(storage: &dyn Storage, dir: &Path) -> Result<Vec<(u64, String)>, OpenError> {
    let names = match storage.list(&dir.join(QUARANTINE_DIR)) {
        Ok(names) => names,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => {
            return Err(OpenError::Io { what: "list the quarantine folder".into(), error });
        }
    };
    let mut out: Vec<(u64, String)> = names
        .into_iter()
        .filter_map(|name| {
            let (segment, _) = name.rsplit_once('.')?;
            Some((format::parse_segment_name(segment)?, name))
        })
        .collect();
    out.sort();
    Ok(out)
}

/// Makes segment `header.seq` through a staging file: the header, `body` (whole records), and,
/// when `end_marker` is set, a sync marker for them; then a full sync, the rename into place (over
/// a torn file of the same name) and a sync of the folder. The marker needs no sync of its own
/// before it: no open reads the file before the rename, and the file is whole on the disk by then.
/// A crash before the rename leaves only the staging file, which no listing reads.
fn stage_segment(
    storage: &dyn Storage,
    dir: &Path,
    header: &SegmentHeader,
    body: &[u8],
    end_marker: Option<Lsn>,
) -> std::io::Result<Box<dyn StorageFile>> {
    let name = format::segment_name(header.seq);
    let staging = dir.join(format!("{name}{STAGING_SUFFIX}"));
    let mut file = storage.open(&staging, OpenMode::Create)?;
    let mut bytes = header.encode().to_vec();
    bytes.extend_from_slice(body);
    if let Some(lsn) = end_marker {
        format::encode_marker(&mut bytes, lsn);
    }
    file.append(&bytes)?;
    file.sync(SyncLevel::Full)?;
    storage.rename(&staging, &dir.join(&name))?;
    storage.sync_dir(dir)?;
    Ok(file)
}

/// Makes segment `header.seq` in place (the writer's rotation and its new segment after a failed
/// sync: no record in it is acknowledged yet): its header, fully synced, and its folder entry,
/// synced. A torn file of the same name is made again.
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
    /// complete): the new segment takes its number.
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
        let (size, decoded) = {
            let file =
                storage.open(&dir.join(name), OpenMode::Read).map_err(io("open a segment"))?;
            let size = file.size().map_err(io("read a segment's size"))?;
            (size, read_header(file.as_ref(), size)?)
        };
        let last = index.saturating_add(1) == listed.len();
        match decoded.and_then(|header| follows(&segments, header, *seq)) {
            Ok(header) => segments.push(Segment { seq: *seq, name: name.clone(), size, header }),
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

/// How far one segment's entries read.
struct Read {
    /// The file offset after the last good entry.
    offset: u64,
    /// The LSN of the last good record (the LSN before the segment's first when it has none).
    end: Lsn,
    /// The LSN its last sync marker vouches for (the LSN before its first record when it has
    /// none), and the offset after that marker.
    vouched: Lsn,
    vouched_offset: u64,
    /// The last segment's entries after its last marker, as the checked read returned them
    /// (header and payload): what recovery writes again (step 4). Never read from the file a
    /// second time: a page that a failed sync dropped can be evicted between two reads, and the
    /// second read then returns the disk's bytes (review G1).
    unvouched: Vec<u8>,
}

fn read_segment(
    storage: &dyn Storage,
    dir: &Path,
    segment: &Segment,
    trusted_end: Option<Lsn>,
    from: Lsn,
    replay: &mut dyn FnMut(Record<'_>) -> Result<(), String>,
    report: &mut OpenReport,
) -> Result<Read, OpenError> {
    let file =
        storage.open(&dir.join(&segment.name), OpenMode::Read).map_err(io("open a segment"))?;
    let mut reader = Reader::new(file.as_ref(), segment.size);
    let start = len64(SEGMENT_HEADER_LEN);
    let before = segment.header.first_lsn.saturating_sub(1);
    let mut read = Read {
        offset: start,
        end: before,
        vouched: before,
        vouched_offset: start,
        unvouched: Vec::new(),
    };
    // Only the last segment (no next segment bounds it) can be written again.
    let keep_tail = trusted_end.is_none();
    loop {
        let expected = read.end.saturating_add(1);
        if trusted_end.is_some_and(|end| expected > end) {
            break;
        }
        let Some(entry) = reader.entry(read.offset)? else { break };
        match entry.kind {
            Entry::Record(class) if entry.lsn == expected => {
                if expected > from || keep_tail {
                    // The bytes the check covered: `entry` read them into the buffer.
                    let payload = reader.payload(read.offset, entry.len)?;
                    if expected > from {
                        replay(Record { lsn: expected, kind: entry.record_kind, class, payload })
                            .map_err(|error| OpenError::Replay { lsn: expected, error })?;
                        report.replayed = report.replayed.saturating_add(1);
                    }
                    if keep_tail {
                        read.unvouched.extend_from_slice(&entry.head);
                        read.unvouched.extend_from_slice(payload);
                    }
                }
                read.end = expected;
            }
            Entry::Marker if entry.lsn == read.end => {
                read.vouched = read.end;
                read.vouched_offset = read.offset.saturating_add(entry.bytes);
                read.unvouched.clear();
            }
            _ => break,
        }
        read.offset = read.offset.saturating_add(entry.bytes);
    }
    Ok(read)
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
