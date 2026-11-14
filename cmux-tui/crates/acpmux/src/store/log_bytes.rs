//! A chat's log as bytes, by seq: what v2's raw source reads (`hub/v1_source.rs`; the design
//! doc's "Files, per chat"). A line's place is its `seq`, and a read gives whole lines as they
//! were written, never parsed, at most [`CHUNK_BYTES`] of them (or one line when a line is
//! larger), with whether no whole line was left after them.
//!
//! - **A read that follows the one before costs its chunk.** The reader keeps [`LogMarks`]: where
//!   its last chunk ended and where the first line of its last read began, each a seq, a segment
//!   and a byte offset. A read at a mark's seq starts at its offset; a read at a later seq in the
//!   mark's segment goes on from it, lines skipped unparsed. Any other read (the first after a
//!   start, a body read back) reads the first bytes of each segment to find the one that holds
//!   the seq, and scans that one from its start, its lines skipped unparsed: at most one segment,
//!   8 MiB. So a catch-up reads each byte of the log about once, never a segment per chunk.
//! - **The stamp is a count**, one `u64` per chat in [`STAMP`] beside its `events/` (absent reads
//!   0). Every change that makes a line already written read differently, or gives its seq to
//!   another line, bumps it, under the writers' lock, once before its first rename and once
//!   after its last: a compaction, the cut a journal restore makes, and the finish of a cut a
//!   crash left halfway (`store/compact.rs`), and a fork's history written into its own log
//!   (`store/fork_view.rs`). A cold archive and its rehydrate keep every byte and do not bump it.
//!   The write is not synced: a power loss is another boot, which the book takes as a changed
//!   stamp by itself. The store keeps each count it read in memory, so reading one is a lookup
//!   under the writers' lock, never a file read, and a count is never read inside a change.
//! - **A mark is good for the count it was taken under** and the segment file it was taken in:
//!   another count, or another file at the segment's name (a compaction's rename, a rehydrated
//!   cold archive), drops it.
//! - **No lock is held while a chunk is read.** A line being appended has no newline yet and is
//!   not there; a segment replaced meanwhile is read whole from the file that was opened. The
//!   reader reads the count before and after the chunk (`hub/v1_source.rs`): two equal counts
//!   mean no line of it changed.

use super::*;
use acpmux_core::chat::source::CHUNK_BYTES;
use std::io::{Seek, SeekFrom};

/// The chat's count of changes to lines already written, beside `events/` (so a cold archive,
/// which moves `events/`, leaves it as it is).
pub const STAMP: &str = "log-stamp";

/// How many first bytes of a segment are read to learn its first seq: `{"seq":N,` fits.
const HEAD: usize = 32;

/// Where a read of a chat's log was: every line before `offset` in segment `segment` of chat
/// `log`'s events has a seq under `seq` or is one a read drops, as the segment was under count
/// `stamp` and in file `file`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LogMark {
    log: String,
    seq: u64,
    segment: u32,
    offset: u64,
    file: u64,
    stamp: u64,
}

/// A reader's marks ([module docs](self)): where its last chunk ended, and where the first line
/// of its last read began.
#[derive(Clone, Debug, Default)]
pub struct LogMarks {
    pub end: Option<LogMark>,
    pub found: Option<LogMark>,
}

impl LogMarks {
    pub fn clear(&mut self) {
        self.end = None;
        self.found = None;
    }

    /// The seq the last chunk ended at.
    pub fn end_seq(&self) -> Option<u64> {
        self.end.as_ref().map(|mark| mark.seq)
    }

    /// How many marks are held, for tests.
    pub fn held(&self) -> usize {
        usize::from(self.end.is_some()) + usize::from(self.found.is_some())
    }

    /// The marks taken under `stamp`; the rest are dropped.
    fn keep_stamp(&mut self, stamp: u64) {
        for mark in [&mut self.end, &mut self.found] {
            if mark.as_ref().is_some_and(|m| m.stamp != stamp) {
                *mark = None;
            }
        }
    }
}

/// Which lines of the log a read gives: those with `seq <= through` (a fork's view of its chat
/// ends at the seq it was forked through), of `kinds` when named.
#[derive(Clone, Copy)]
pub struct LogFilter<'a> {
    pub through: u64,
    pub kinds: Option<&'a [&'a str]>,
}

impl LogFilter<'_> {
    pub const ALL: LogFilter<'static> = LogFilter { through: u64::MAX, kinds: None };

    fn keeps(&self, line: &[u8]) -> bool {
        self.kinds.is_none_or(|kinds| {
            record_kind(line).is_some_and(|kind| kinds.iter().any(|k| k.as_bytes() == kind))
        })
    }
}

/// What a read gave besides its lines.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct LogChunk {
    /// The place after its last line: that line's seq + 1, or the seq read from when it holds
    /// none.
    pub next: u64,
    /// No whole line was left after it at this read (a line still being written is not there).
    pub at_end: bool,
    /// Bytes this read took from the log's files.
    pub read: u64,
}

/// A segment file opened for a read, with the bytes taken from it counted.
struct Segment {
    index: u32,
    file: File,
    id: u64,
    read: u64,
}

impl Segment {
    fn open(index: u32, path: &Path) -> Result<Self> {
        let file = crate::config::private_state_file(path)?;
        let id = file_id(&file.metadata()?);
        Ok(Self { index, file, id, read: 0 })
    }

    fn read_at(&mut self, offset: u64, out: &mut [u8]) -> Result<usize> {
        self.file.seek(SeekFrom::Start(offset))?;
        let mut filled = 0;
        while let Some(rest) = out.get_mut(filled..).filter(|rest| !rest.is_empty()) {
            let n = self.file.read(rest)?;
            if n == 0 {
                break;
            }
            filled += n;
        }
        self.read += filled as u64;
        Ok(filled)
    }

    /// The seq of the segment's first line, from its first bytes alone; None when they do not
    /// say (an empty segment, a blank or older first line).
    fn first_seq(&mut self) -> Result<Option<u64>> {
        let mut head = [0u8; HEAD];
        let n = self.read_at(0, &mut head)?;
        Ok(head.get(..n).and_then(record_seq))
    }
}

#[cfg(unix)]
fn file_id(meta: &std::fs::Metadata) -> u64 {
    use std::os::unix::fs::MetadataExt;
    meta.ino() ^ meta.dev().rotate_left(32)
}

#[cfg(not(unix))]
fn file_id(_meta: &std::fs::Metadata) -> u64 {
    0
}

/// A log line's seq, read from its first bytes; None for a blank line or one whose seq does not
/// read (no read gives such a line).
pub fn line_seq(line: &[u8]) -> Option<u64> {
    if line.iter().all(u8::is_ascii_whitespace) { None } else { record_seq(line) }
}

impl LocalStore {
    /// `Store::log_stamp`.
    pub(super) fn read_stamp(&self, id: &str) -> Result<u64> {
        let mut writers = self.writers.lock_or_recover();
        self.stamp_locked(id, &mut writers)
    }

    /// The count of chat `id`, under the writers' lock: from memory once read.
    pub(super) fn stamp_locked(&self, id: &str, writers: &mut Writers) -> Result<u64> {
        if let Some(count) = writers.stamps.get(id) {
            return Ok(*count);
        }
        let count = match std::fs::read(self.dir(id).join(STAMP)) {
            Ok(text) => std::str::from_utf8(&text)
                .ok()
                .and_then(|text| text.trim().parse::<u64>().ok())
                .with_context(|| format!("chat {id}: its log's count does not read"))?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => 0,
            Err(e) => return Err(e).with_context(|| format!("read chat {id}'s log count")),
        };
        writers.stamps.insert(id.to_owned(), count);
        Ok(count)
    }

    /// Adds `by` to chat `id`'s count, under the writers' lock. Not synced ([module docs](self)).
    pub(super) fn bump_stamp_locked(&self, id: &str, writers: &mut Writers, by: u64) -> Result<()> {
        let count = self.stamp_locked(id, writers)?.saturating_add(by);
        crate::config::private_state_dir(&self.dir(id))?;
        crate::config::write_atomic_unsynced(
            &self.dir(id).join(STAMP),
            count.to_string().as_bytes(),
        )?;
        writers.stamps.insert(id.to_owned(), count);
        Ok(())
    }

    /// `Store::bump_log_stamp`.
    pub(super) fn bump_stamp(&self, id: &str, by: u64) -> Result<()> {
        let mut writers = self.writers.lock_or_recover();
        self.bump_stamp_locked(id, &mut writers, by)
    }

    /// `Store::read_log`: the lines of chat `id` from seq `from` that `filter` keeps, into
    /// `out`, read under count `stamp` with `marks`. No lock is held.
    pub(super) fn read_log_bytes(
        &self,
        id: &str,
        from: u64,
        filter: LogFilter<'_>,
        stamp: u64,
        marks: &mut LogMarks,
        out: &mut Vec<u8>,
    ) -> Result<LogChunk> {
        out.clear();
        marks.keep_stamp(stamp);
        let segments = self.segments(id)?;
        let mut chunk = LogChunk { next: from, at_end: true, read: 0 };
        let Some((mut segment, mut offset)) =
            self.start(id, from, stamp, &segments, marks, &mut chunk)?
        else {
            return Ok(chunk);
        };
        let mut position = segments.iter().position(|(i, _)| *i == segment.index).unwrap_or(0);
        let mut last: Option<u64> = None;
        // The first kept line: its segment, offset and segment file.
        let mut first: Option<(u32, u64, u64)> = None;
        // Whole kept lines are `out[..kept]`; bytes read after them and not yet split wait in
        // `out[kept..]`, and start at `offset` in the segment.
        let mut kept = 0usize;
        'read: loop {
            let waiting = out.len() - kept;
            // The chunk's room, or a chunk more while no line is kept (one line may be larger
            // than a chunk, and lines before `from` are passed over).
            let want = match (kept, waiting) {
                (0, waiting) if waiting >= CHUNK_BYTES => CHUNK_BYTES,
                (kept, waiting) => CHUNK_BYTES.saturating_sub(kept + waiting),
            };
            if want == 0 {
                chunk.at_end = false;
                break;
            }
            let start = out.len();
            // Exactly: the buffer is one chunk, or one line when a line is larger.
            out.reserve_exact(want);
            out.resize(start + want, 0);
            let n = segment
                .read_at(offset + waiting as u64, out.get_mut(start..).unwrap_or_default())?;
            out.truncate(start + n);
            let mut at = kept;
            while let Some(newline) =
                out.get(at..).and_then(|rest| rest.iter().position(|b| *b == b'\n'))
            {
                let end = at + newline + 1;
                let line = out.get(at..end).unwrap_or_default();
                let seq = line_seq(line);
                if seq.is_some_and(|seq| seq > filter.through) {
                    // The view ends here: nothing after it is this reader's.
                    chunk.at_end = true;
                    break 'read;
                }
                let keep = seq.is_some_and(|seq| {
                    seq >= from && last.is_none_or(|last| seq > last) && filter.keeps(line)
                });
                let length = end - at;
                if keep && kept > 0 && kept + length > CHUNK_BYTES {
                    chunk.at_end = false;
                    break 'read;
                }
                if keep {
                    first.get_or_insert((segment.index, offset, segment.id));
                    out.copy_within(at..end, kept);
                    kept += length;
                    last = seq;
                }
                offset += length as u64;
                at = end;
            }
            // What follows the last newline is part of a line.
            out.copy_within(at.., kept);
            out.truncate(kept + (start + n - at));
            if n == want {
                if kept > 0 && out.len() > kept {
                    // A line the chunk has no room left for: it starts the next read.
                    chunk.at_end = false;
                    break;
                }
                continue;
            }
            // The segment's end. A line with no newline there is being written (the last
            // segment) or was torn (a closed one, whose writer has moved on): no line either way.
            chunk.read += std::mem::take(&mut segment.read);
            out.truncate(kept);
            let Some((index, path)) = segments.get(position + 1) else {
                chunk.at_end = true;
                break;
            };
            position += 1;
            segment = Segment::open(*index, path)?;
            offset = 0;
        }
        out.truncate(kept);
        chunk.read += segment.read;
        if let Some(last) = last {
            chunk.next = last.saturating_add(1);
        }
        let mark = |seq: u64, index: u32, offset: u64, file: u64| LogMark {
            log: id.to_owned(),
            seq,
            segment: index,
            offset,
            file,
            stamp,
        };
        marks.end = Some(mark(chunk.next, segment.index, offset, segment.id));
        if let (Some((index, offset, file)), Some(seq)) = (first, record_seq(out)) {
            marks.found = Some(mark(seq, index, offset, file));
        }
        Ok(chunk)
    }

    /// The segment and offset a read at `from` starts at, from a mark when one serves, else
    /// found by the segments' first seqs and a scan of the one that holds it. None: no log.
    fn start(
        &self,
        id: &str,
        from: u64,
        stamp: u64,
        segments: &[(u32, PathBuf)],
        marks: &LogMarks,
        chunk: &mut LogChunk,
    ) -> Result<Option<(Segment, u64)>> {
        if segments.is_empty() {
            return Ok(None);
        }
        let usable = [&marks.end, &marks.found]
            .into_iter()
            .flatten()
            .filter(|m| m.log == id && m.stamp == stamp && m.seq <= from)
            .max_by_key(|m| m.seq);
        if let Some(mark) = usable
            && let Some(position) = segments.iter().position(|(i, _)| *i == mark.segment)
            && let Some((index, path)) = segments.get(position)
        {
            let mut segment = Segment::open(*index, path)?;
            if segment.id == mark.file {
                // A later seq goes on from the mark only while it is in the mark's segment: the
                // next segment's first seq says.
                let here = mark.seq == from
                    || match segments.get(position + 1) {
                        None => true,
                        Some((next, path)) => {
                            let mut next = Segment::open(*next, path)?;
                            let first = next.first_seq()?;
                            chunk.read += next.read;
                            first.is_none_or(|first| first > from)
                        }
                    };
                if here {
                    return Ok(Some((segment, mark.offset)));
                }
            }
            chunk.read += segment.read;
        }
        // The last segment whose first seq is at or before `from` holds it.
        let mut position = 0;
        for (n, (index, path)) in segments.iter().enumerate().skip(1) {
            let mut segment = Segment::open(*index, path)?;
            let first = segment.first_seq()?;
            chunk.read += segment.read;
            match first {
                Some(first) if first <= from => position = n,
                Some(_) => break,
                None => {}
            }
        }
        let Some((index, path)) = segments.get(position) else { return Ok(None) };
        let mut segment = Segment::open(*index, path)?;
        let offset = scan_to(&mut segment, from)?;
        Ok(Some((segment, offset)))
    }
}

/// The offset of the first line in `segment` whose seq is `from` or more, read from its start
/// with every line before it skipped unparsed (only its first bytes are looked at): the
/// segment's end when it has none. A line with no seq is passed over.
fn scan_to(segment: &mut Segment, from: u64) -> Result<u64> {
    segment.file.seek(SeekFrom::Start(0))?;
    let found = {
        let mut reader = BufReader::with_capacity(64 * 1024, &segment.file);
        let mut offset = 0u64;
        let mut head = Vec::with_capacity(HEAD);
        let mut length = 0u64;
        loop {
            let buffer = reader.fill_buf()?;
            if buffer.is_empty() {
                // A last line with no newline is not a line: the read goes on from its start.
                break offset;
            }
            let newline = buffer.iter().position(|b| *b == b'\n');
            let upto = newline.map_or(buffer.len(), |at| at + 1);
            if head.len() < HEAD {
                let room = HEAD - head.len();
                head.extend_from_slice(buffer.get(..upto.min(room)).unwrap_or_default());
            }
            length += upto as u64;
            reader.consume(upto);
            if newline.is_some() {
                if line_seq(&head).is_some_and(|seq| seq >= from) {
                    break offset;
                }
                offset += length;
                length = 0;
                head.clear();
            }
        }
    };
    // What the scan took from the file, its read-ahead included.
    segment.read += segment.file.stream_position()?;
    Ok(found)
}

#[cfg(test)]
#[path = "log_bytes_tests.rs"]
pub(super) mod tests;
