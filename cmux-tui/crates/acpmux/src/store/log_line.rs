//! Reading the event log's lines: a record's head fields without a parse ([`RecordHead`]), the
//! offset of a seq in a segment, and a segment's lines newest first.

use super::*;

/// One record as [`Store::scan_heads`] passes it: the fields a log line holds before its `msg`,
/// and the whole record on demand.
pub struct RecordHead<'a> {
    pub seq: u64,
    pub at: u64,
    pub dir: &'a str,
    pub kind: &'a str,
    pub host_seq: Option<u64>,
    body: HeadBody<'a>,
}

enum HeadBody<'a> {
    /// A log line, not parsed yet.
    Line(&'a [u8]),
    /// A record the store holds parsed, or a line whose head did not read.
    Parsed(&'a EventRecord),
}

impl<'a> RecordHead<'a> {
    pub(super) fn parsed(rec: &'a EventRecord) -> Self {
        Self {
            seq: rec.seq,
            at: rec.at,
            dir: &rec.dir,
            kind: &rec.kind,
            host_seq: rec.host_seq,
            body: HeadBody::Parsed(rec),
        }
    }

    /// The head of a line the daemon wrote (`{"seq":N,"at":N,"dir":"..","kind":"..","msg":..}`,
    /// then `"hostSeq":N` when it has one); None for any other shape, which the caller parses.
    pub(super) fn read(line: &'a [u8]) -> Option<Self> {
        let body = line.trim_ascii_end();
        if body.last() != Some(&b'}') {
            return None;
        }
        let text = |field: &'a [u8]| {
            std::str::from_utf8(field).ok().filter(|s| !s.contains('\\') && !s.is_empty())
        };
        let host_seq = record_host_seq(body);
        // A `hostSeq` anywhere but last is not the daemon's field order.
        let head = body.get(..160).unwrap_or(body);
        let head = head.get(..memchr::memmem::find(head, b"\"msg\":")?).unwrap_or_default();
        if host_seq.is_none() && memchr::memmem::find(head, b"\"hostSeq\"").is_some() {
            return None;
        }
        Some(Self {
            seq: record_seq(body)?,
            at: record_at(body)?,
            dir: text(record_dir(body)?)?,
            kind: text(record_kind(body)?)?,
            host_seq,
            body: HeadBody::Line(body),
        })
    }

    /// The whole record (None for a line that does not parse, which `scan` passes too).
    pub fn record(&self) -> Option<EventRecord> {
        match self.body {
            HeadBody::Line(line) => parse_record(line).ok(),
            HeadBody::Parsed(rec) => Some(rec.clone()),
        }
    }

    /// Whether the record's line may hold `needle`: true for a record held parsed, so a reader
    /// uses it only to pass a record it surely does not need.
    pub fn may_contain(&self, needle: &[u8]) -> bool {
        match self.body {
            HeadBody::Line(line) => memchr::memmem::find(line, needle).is_some(),
            HeadBody::Parsed(_) => true,
        }
    }
}

#[cfg(test)]
thread_local! {
    /// Log lines parsed on this thread by `scan` and `scan_heads` (tests count them).
    pub(crate) static PARSED_LINES: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

/// Parses one log line into its record.
pub(super) fn parse_record(line: &[u8]) -> serde_json::Result<EventRecord> {
    #[cfg(test)]
    PARSED_LINES.with(|n| n.set(n.get() + 1));
    serde_json::from_slice(line)
}

/// The seq of a segment's first readable record.
/// The `kind` of one serialized record, read without parsing it: records are written
/// `{"seq":..,"at":..,"dir":"..","kind":"..","msg":..}`, so the first `"kind":"` is the
/// record's own (its fields before `msg` hold numbers and a fixed word). None for a line
/// that does not start that way; the caller then parses it.
pub(super) fn record_kind(line: &[u8]) -> Option<&[u8]> {
    record_head_field(line, b"\"kind\":\"")
}

/// The string value after `key` (`"name":"`) in the first 160 bytes of a record, before
/// its `"msg":`; None when it is not there.
fn record_head_field<'a>(line: &'a [u8], key: &[u8]) -> Option<&'a [u8]> {
    let head = line.get(..160).unwrap_or(line);
    let msg = head.windows(6).position(|w| w == b"\"msg\":").unwrap_or(head.len());
    let start = head.get(..msg)?.windows(key.len()).position(|w| w == key)? + key.len();
    let rest = line.get(start..)?;
    let len = rest.iter().position(|&b| b == b'"')?;
    rest.get(..len)
}

/// The `seq` of one serialized record, read without parsing it: records are written
/// `{"seq":N,...}`. None for a line that does not start that way; the caller parses it.
pub(super) fn record_seq(line: &[u8]) -> Option<u64> {
    let rest = line.strip_prefix(b"{\"seq\":")?;
    let digits = rest.iter().take_while(|b| b.is_ascii_digit()).count();
    if digits == 0 || digits > 19 || rest.get(digits) != Some(&b',') {
        return None;
    }
    std::str::from_utf8(rest.get(..digits)?).ok()?.parse().ok()
}

/// The `at` of one serialized record, read without parsing it: `{"seq":N,"at":N,...`.
fn record_at(line: &[u8]) -> Option<u64> {
    let rest = line.strip_prefix(b"{\"seq\":")?;
    let rest = rest.get(rest.iter().take_while(|b| b.is_ascii_digit()).count()..)?;
    let rest = rest.strip_prefix(b",\"at\":")?;
    let digits = rest.iter().take_while(|b| b.is_ascii_digit()).count();
    if digits == 0 || digits > 19 || rest.get(digits) != Some(&b',') {
        return None;
    }
    std::str::from_utf8(rest.get(..digits)?).ok()?.parse().ok()
}

/// The `hostSeq` of one serialized record, read without parsing it: the daemon writes it last
/// (`...,"hostSeq":N}`), so a nested one is followed by more than the record's closing brace.
fn record_host_seq(line: &[u8]) -> Option<u64> {
    let rest = line.strip_suffix(b"}")?;
    let digits = rest.iter().rev().take_while(|b| b.is_ascii_digit()).count();
    if digits == 0 || digits > 19 {
        return None;
    }
    let (rest, number) = rest.split_at(rest.len() - digits);
    rest.strip_suffix(b",\"hostSeq\":")?;
    std::str::from_utf8(number).ok()?.parse().ok()
}

/// The `dir` of one serialized record, read without parsing it, as `record_kind` reads its kind.
pub(super) fn record_dir(line: &[u8]) -> Option<&[u8]> {
    record_head_field(line, b"\"dir\":\"")
}

/// The byte offset in segment `path` where its first record with `seq >= before` starts (the
/// file's length when it has none), found by a binary search on line headers: the records of a
/// segment are appended in `seq` order. A line whose header does not read (an older field
/// order) ends the search at the file's length, which reads the segment from its end as before.
/// The caller reads back from the offset through the same `file`: log retention may rename a
/// compacted segment over the path meanwhile (`store/compact.rs`).
pub(super) fn offset_of_seq(file: &mut File, before: u64) -> Result<u64> {
    use std::io::{Seek, SeekFrom};
    const PROBE: usize = 64 * 1024;
    let len = file.seek(SeekFrom::End(0))?;
    let mut buf = vec![0u8; PROBE];
    // A segment whose last record is before `before` (every older segment of a page) needs no
    // search: its end is the offset.
    if len > PROBE as u64 {
        file.seek(SeekFrom::Start(len - PROBE as u64))?;
        file.read_exact(&mut buf)?;
        let body = buf.strip_suffix(b"\n").unwrap_or(&buf);
        if let Some(nl) = body.iter().rposition(|&b| b == b'\n')
            && body.get(nl + 1..).and_then(record_seq).is_some_and(|seq| seq < before)
        {
            return Ok(len);
        }
    }
    // The first line starting at or after `pos`: its offset and seq; None past the end, or when
    // no line starts in the probe (a line over 64 KiB) or its header does not read.
    let mut line_at = |pos: u64| -> Result<Option<(u64, Option<u64>)>> {
        file.seek(SeekFrom::Start(pos))?;
        let mut filled = 0;
        while let Some(rest) = buf.get_mut(filled..).filter(|rest| !rest.is_empty()) {
            let n = file.read(rest)?;
            if n == 0 {
                break;
            }
            filled += n;
        }
        let data = buf.get(..filled).unwrap_or_default();
        let start = if pos == 0 {
            0
        } else {
            match data.iter().position(|&b| b == b'\n') {
                Some(nl) => nl + 1,
                None => return Ok(None),
            }
        };
        if start >= data.len() {
            return Ok(None);
        }
        Ok(Some((pos + start as u64, data.get(start..).and_then(record_seq))))
    };
    let (mut lo, mut hi, mut end) = (0u64, len, len);
    while hi - lo > PROBE as u64 {
        let mid = lo + (hi - lo) / 2;
        match line_at(mid)? {
            Some((_, None)) | None => return Ok(len),
            Some((start, Some(seq))) if seq >= before => {
                hi = mid;
                end = start;
            }
            Some(_) => lo = mid,
        }
    }
    Ok(end)
}

/// Visits `path`'s lines newest first, reading 64 KiB blocks from the end, until `visit`
/// returns false: a tail costs its own bytes, not the segment's.
pub(super) fn for_each_line_rev(path: &Path, visit: &mut dyn FnMut(&[u8]) -> bool) -> Result<()> {
    for_each_line_rev_from(&mut crate::config::private_state_file(path)?, u64::MAX, visit)
}

/// `for_each_line_rev` over the bytes of `file` before offset `end` (a line start, or past the end).
pub(super) fn for_each_line_rev_from(
    file: &mut File,
    end: u64,
    visit: &mut dyn FnMut(&[u8]) -> bool,
) -> Result<()> {
    for_each_line_rev_between(file, 0, end, visit)
}

/// [`for_each_line_rev_from`] over the bytes of `file` from offset `start` (a line start) to `end`.
pub(super) fn for_each_line_rev_between(
    file: &mut File,
    start: u64,
    end: u64,
    visit: &mut dyn FnMut(&[u8]) -> bool,
) -> Result<()> {
    use std::io::{Seek, SeekFrom};
    const BLOCK: u64 = 64 * 1024;
    let floor = start;
    let mut end = file.seek(SeekFrom::End(0))?.min(end);
    if end <= floor {
        return Ok(());
    }
    // The blocks of a line whose start is in an earlier block, newest first: each block is read
    // and scanned once, so a line of many megabytes costs its length, not its length squared.
    let mut carry: Vec<Vec<u8>> = Vec::new();
    let joined = |head: &[u8], carry: &mut Vec<Vec<u8>>| {
        let mut line = head.to_vec();
        for piece in carry.drain(..).rev() {
            line.extend_from_slice(&piece);
        }
        line
    };
    while end > floor {
        let start = end.saturating_sub(BLOCK).max(floor);
        let mut block = vec![0u8; (end - start) as usize];
        file.seek(SeekFrom::Start(start))?;
        file.read_exact(&mut block)?;
        let mut cut = block.len();
        while let Some(newline) =
            block.get(..cut).unwrap_or_default().iter().rposition(|&b| b == b'\n')
        {
            let head = block.get(newline + 1..cut).unwrap_or_default();
            let whole;
            let line = if carry.is_empty() {
                head
            } else {
                whole = joined(head, &mut carry);
                whole.as_slice()
            };
            if !line.iter().all(u8::is_ascii_whitespace) && !visit(line) {
                return Ok(());
            }
            cut = newline;
        }
        block.truncate(cut);
        carry.push(block);
        end = start;
    }
    let line = joined(&[], &mut carry);
    if !line.iter().all(u8::is_ascii_whitespace) {
        visit(&line);
    }
    Ok(())
}

pub(super) fn first_seq(path: &Path) -> Result<Option<u64>> {
    let mut reader = BufReader::new(crate::config::private_state_file(path)?);
    let mut line = Vec::new();
    loop {
        line.clear();
        if reader.read_until(b'\n', &mut line)? == 0 {
            return Ok(None);
        }
        // The header alone when the line has the daemon's field order; else a parse.
        if let Some(seq) = record_seq(&line) {
            return Ok(Some(seq));
        }
        if let Ok(rec) = serde_json::from_slice::<EventRecord>(&line) {
            return Ok(Some(rec.seq));
        }
    }
}
