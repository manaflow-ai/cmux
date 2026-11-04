//! Reading segments entry by entry, and the scans that find every LSN a damaged or quarantined
//! segment holds (steps 3 to 5 of `recovery.rs`).

use std::path::Path;

use super::{QUARANTINE_DIR, READ_CHUNK, io, len64, read_header, usize_of};
use crate::Lsn;
use crate::format::{
    self, Entry, MAX_PAYLOAD_LEN, RECORD_HEADER_LEN, RecordHeader, SEGMENT_HEADER_LEN,
};
use crate::journal::OpenError;
use crate::storage::{OpenMode, Storage, StorageFile};

/// One entry that checked out.
pub(super) struct Checked {
    pub(super) kind: Entry,
    /// The header bytes the check covered.
    pub(super) head: [u8; RECORD_HEADER_LEN],
    pub(super) lsn: Lsn,
    pub(super) record_kind: u16,
    /// The payload length and the entry's whole length.
    pub(super) len: usize,
    pub(super) bytes: u64,
}

/// Reads a segment in chunks.
pub(super) struct Reader<'a> {
    file: &'a dyn StorageFile,
    size: u64,
    buf: Vec<u8>,
    /// The file offset of `buf`'s first byte.
    at: u64,
}

impl<'a> Reader<'a> {
    pub(super) fn new(file: &'a dyn StorageFile, size: u64) -> Self {
        Self { file, size, buf: Vec::new(), at: 0 }
    }

    /// `len` bytes at `offset`, or `None` when the file ends first.
    pub(super) fn bytes(&mut self, offset: u64, len: usize) -> Result<Option<&[u8]>, OpenError> {
        let Some(end) = offset.checked_add(len64(len)) else { return Ok(None) };
        if end > self.size {
            return Ok(None);
        }
        let buffered_end = self.at.saturating_add(len64(self.buf.len()));
        if offset < self.at || end > buffered_end {
            let left = usize_of(self.size.saturating_sub(offset));
            self.buf.resize(len.max(READ_CHUNK).min(left), 0);
            self.file.read_at(offset, &mut self.buf).map_err(io("read a segment"))?;
            self.at = offset;
        }
        let start = usize_of(offset.saturating_sub(self.at));
        Ok(self.buf.get(start..start.saturating_add(len)))
    }

    /// The entry at `offset` when it checks out (its checksum, flags and size), whatever its LSN.
    pub(super) fn entry(&mut self, offset: u64) -> Result<Option<Checked>, OpenError> {
        self.entry_where(offset, &|_, _| true)
    }

    /// The entry at `offset` when it checks out and `fits(kind, lsn)`: the cheap test runs before
    /// the payload is read and its checksum computed.
    pub(super) fn entry_where(
        &mut self,
        offset: u64,
        fits: &dyn Fn(Entry, Lsn) -> bool,
    ) -> Result<Option<Checked>, OpenError> {
        let Some(head) = self.bytes(offset, RECORD_HEADER_LEN)? else { return Ok(None) };
        let Ok(head) = <[u8; RECORD_HEADER_LEN]>::try_from(head) else { return Ok(None) };
        let Some(header) = RecordHeader::decode(&head) else { return Ok(None) };
        if header.len > MAX_PAYLOAD_LEN {
            return Ok(None);
        }
        let guess = match header.flags {
            format::MARKER => Entry::Marker,
            _ => Entry::Record(crate::Class::Ack),
        };
        if !fits(guess, header.lsn) {
            return Ok(None);
        }
        let payload_at = offset.saturating_add(len64(RECORD_HEADER_LEN));
        let Some(payload) = self.bytes(payload_at, header.len)? else { return Ok(None) };
        let Ok(kind) = header.check(&head, payload) else { return Ok(None) };
        Ok(Some(Checked {
            kind,
            head,
            lsn: header.lsn,
            record_kind: header.kind,
            len: header.len,
            bytes: len64(RECORD_HEADER_LEN).saturating_add(len64(header.len)),
        }))
    }

    /// The payload of the entry at `offset` (already checked by `entry`).
    pub(super) fn payload(&mut self, offset: u64, len: usize) -> Result<&[u8], OpenError> {
        let at = offset.saturating_add(len64(RECORD_HEADER_LEN));
        Ok(self.bytes(at, len)?.unwrap_or_default())
    }
}

/// What the bytes after a bad entry hold.
pub(super) struct Beyond {
    /// The highest LSN of an entry that checks out there (the base when none does).
    pub(super) max_lsn: Lsn,
    /// A sync marker checks out there: the bad entry was synced.
    pub(super) marker: bool,
}

pub(super) fn scan_beyond_path(
    storage: &dyn Storage,
    path: &Path,
    start: u64,
    base: Lsn,
) -> Result<Beyond, OpenError> {
    let file = storage.open(path, OpenMode::Read).map_err(io("open a segment"))?;
    let size = file.size().map_err(io("read a segment's size"))?;
    scan_beyond(&mut Reader::new(file.as_ref(), size), start, base)
}

/// Scans from `start` to the end, one byte at a time, for entries that check out and continue
/// past `base`: a record with an LSN above the last one found, or a marker at or above it. Such
/// LSNs are bounded by the number of entries the bytes can hold, so random bytes almost never
/// pass the LSN test, and their checksum is never computed.
pub(super) fn scan_beyond(
    reader: &mut Reader<'_>,
    start: u64,
    base: Lsn,
) -> Result<Beyond, OpenError> {
    let span = reader.size.saturating_sub(start).checked_div(len64(RECORD_HEADER_LEN)).unwrap_or(0);
    let high = base.saturating_add(span).saturating_add(1);
    let mut beyond = Beyond { max_lsn: base, marker: false };
    let mut pos = start;
    while pos.saturating_add(len64(RECORD_HEADER_LEN)) <= reader.size {
        let low = beyond.max_lsn;
        let fits = |kind: Entry, lsn: Lsn| match kind {
            Entry::Record(_) => lsn > low && lsn <= high,
            Entry::Marker => lsn >= low && lsn <= high,
        };
        match reader.entry_where(pos, &fits)? {
            Some(entry) => {
                beyond.max_lsn = beyond.max_lsn.max(entry.lsn);
                beyond.marker |= entry.kind == Entry::Marker;
                pos = pos.saturating_add(entry.bytes);
            }
            None => pos = pos.saturating_add(1),
        }
    }
    Ok(beyond)
}

/// The highest LSN a segment file holds. Its records are read in order from its first LSN, then
/// the bytes after the first bad entry are scanned. The first LSN comes from the header or, when
/// the header is damaged, from the record right after it (each record's checksum covers its
/// LSN). When neither reads, the scan takes records above `base`.
pub(super) fn highest_lsn(storage: &dyn Storage, path: &Path, base: Lsn) -> Result<Lsn, OpenError> {
    let file = storage.open(path, OpenMode::Read).map_err(io("open a quarantined segment"))?;
    let size = file.size().map_err(io("read a segment's size"))?;
    let header = read_header(file.as_ref(), size)?.ok();
    let mut reader = Reader::new(file.as_ref(), size);
    let start = len64(SEGMENT_HEADER_LEN);
    let before = match header {
        Some(header) => Some(header.first_lsn.saturating_sub(1)),
        None => match reader.entry(start)? {
            Some(Checked { kind: Entry::Record(_), lsn, .. }) => Some(lsn.saturating_sub(1)),
            _ => None,
        },
    };
    let (offset, from_lsn) = match before {
        Some(before) => {
            let mut end = before;
            let mut offset = start;
            while let Some(entry) = reader.entry(offset)? {
                match entry.kind {
                    Entry::Record(_) if entry.lsn == end.saturating_add(1) => end = entry.lsn,
                    Entry::Marker if entry.lsn == end => {}
                    _ => break,
                }
                offset = offset.saturating_add(entry.bytes);
            }
            (offset, end.max(header.map_or(0, |header| header.prev_last)))
        }
        None => (start, base),
    };
    Ok(scan_beyond(&mut reader, offset, from_lsn)?.max_lsn.max(from_lsn))
}

/// The highest LSN of the quarantined segments that lies above `base`.
pub(super) fn quarantined_floor(
    storage: &dyn Storage,
    dir: &Path,
    quarantined: &[(u64, String)],
    base: Lsn,
) -> Result<Lsn, OpenError> {
    let mut floor = base;
    for (_, name) in quarantined {
        floor = floor.max(highest_lsn(storage, &dir.join(QUARANTINE_DIR).join(name), floor)?);
    }
    Ok(floor)
}

/// The journal id of a quarantined segment whose header reads, when no live one is left.
pub(super) fn quarantined_journal_id(
    storage: &dyn Storage,
    dir: &Path,
    quarantined: &[(u64, String)],
) -> Result<Option<u64>, OpenError> {
    for (_, name) in quarantined {
        let file = storage
            .open(&dir.join(QUARANTINE_DIR).join(name), OpenMode::Read)
            .map_err(io("open a quarantined segment"))?;
        let size = file.size().map_err(io("read a segment's size"))?;
        if let Ok(header) = read_header(file.as_ref(), size)? {
            return Ok(Some(header.journal_id));
        }
    }
    Ok(None)
}

/// The segments moved to quarantine, and the highest LSN they hold.
pub(super) struct Moved {
    pub(super) names: Vec<String>,
    pub(super) highest: Lsn,
}

/// Moves every listed segment from number `from_seq` on into `quarantine/`, under a name no
/// earlier recovery used. Their highest LSN is read first, then all are moved, then both folders
/// are synced. A crash in between is safe: the next open counts the LSNs of every quarantined
/// segment, and reports a quarantine that no new segment followed.
pub(super) fn quarantine(
    storage: &dyn Storage,
    dir: &Path,
    listed: &[(u64, String)],
    from_seq: u64,
    base: Lsn,
) -> Result<Moved, OpenError> {
    let target = dir.join(QUARANTINE_DIR);
    storage.create_dir_all(&target).map_err(io("make the quarantine folder"))?;
    let taken = storage.list(&target).map_err(io("list the quarantine folder"))?;
    let moving: Vec<&String> =
        listed.iter().filter(|(seq, _)| *seq >= from_seq).map(|(_, name)| name).collect();
    let mut moved = Moved { names: Vec::new(), highest: base };
    for name in &moving {
        moved.highest = moved.highest.max(highest_lsn(storage, &dir.join(name), moved.highest)?);
    }
    for name in moving {
        let mut attempt = 0u32;
        let new_name = loop {
            let candidate = format!("{name}.{attempt}");
            if !taken.contains(&candidate) {
                break candidate;
            }
            attempt = attempt.saturating_add(1);
        };
        storage.rename(&dir.join(name), &target.join(&new_name)).map_err(io("move a segment"))?;
        moved.names.push(new_name);
    }
    storage.sync_dir(&target).map_err(io("sync the quarantine folder"))?;
    storage.sync_dir(dir).map_err(io("sync the folder"))?;
    Ok(moved)
}
