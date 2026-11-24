//! A segment's lines to its chunks' bytes and back (the layout is in `lib.rs`).
//!
//! The events chunk is `[head column length, u32 LE][head column][remainders]`. The head column
//! has one line per log line: `<seq - previous seq> <at - previous at> <dir> <kind>` for a line
//! that starts `{"seq":N,"at":N,"dir":"D","kind":"K",` exactly (an acpmux record), `!` for any
//! other. The remainders are what follows that start (the whole line for a `!` one), each ended
//! by a newline, ordered by kind and then by line. In a remainder, byte 1 then digits then `;`
//! stands for the blob of that number, and byte 1 twice for a byte 1 of the log.
//!
//! The blob table is 21 bytes a blob: its length in the blobs chunk (u32 LE), its encoding (0 as
//! in the log, 1 decoded from base64) and the first 16 bytes of the BLAKE3 hash of the string as
//! the log has it.

use crate::Result;
use crate::manifest::Params;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use std::collections::HashMap;
use std::io::Write as _;

const ESC: u8 = 1;
const ENTRY: usize = 21;
const ENC_RAW: u8 = 0;
const ENC_B64: u8 = 1;
/// A string shorter than this is not tried as base64.
const B64_MIN: usize = 1024;

/// The blobs a session holds so far: each string's hash to its number.
#[derive(Default)]
pub struct BlobIndex {
    map: HashMap<[u8; 16], u64>,
    /// The next new blob's number.
    pub next: u64,
}

impl BlobIndex {
    /// Adds a sealed segment's blobs, the first numbered `first`.
    pub fn add_table(&mut self, first: u64, table: &[u8]) -> Result<()> {
        if !table.len().is_multiple_of(ENTRY) {
            return Err("a blob table's length is not a whole number of entries".into());
        }
        let mut n = first;
        for e in table.chunks_exact(ENTRY) {
            let h = *e.last_chunk::<16>().ok_or("a blob table entry is short")?;
            self.map.insert(h, n);
            n += 1;
        }
        self.next = self.next.max(n);
        Ok(())
    }

    fn intern(&mut self, s: &[u8], blobs: &mut Vec<u8>, table: &mut Vec<u8>) -> Option<u64> {
        let mut h = [0u8; 16];
        h.copy_from_slice(&blake3::hash(s).as_bytes()[..16]);
        if let Some(n) = self.map.get(&h) {
            return Some(*n);
        }
        let decoded = (s.len() >= B64_MIN && s.len().is_multiple_of(4))
            .then(|| STANDARD.decode(s).ok())
            .flatten()
            .filter(|d| STANDARD.encode(d).as_bytes() == s);
        let (enc, body) = match &decoded {
            Some(d) => (ENC_B64, &d[..]),
            None => (ENC_RAW, s),
        };
        let len = u32::try_from(body.len()).ok()?;
        blobs.extend_from_slice(body);
        table.extend_from_slice(&len.to_le_bytes());
        table.push(enc);
        table.extend_from_slice(&h);
        let n = self.next;
        self.next += 1;
        self.map.insert(h, n);
        Some(n)
    }
}

struct Head<'a> {
    seq: u64,
    at: u64,
    dir: &'a [u8],
    kind: &'a [u8],
    rest: usize,
}

fn number(b: &[u8], i: &mut usize) -> Option<u64> {
    let tail = b.get(*i..)?;
    let d = tail.get(..tail.iter().take_while(|c| c.is_ascii_digit()).count())?;
    *i += d.len();
    if d.is_empty() || d.len() > 19 || (d.len() > 1 && d.first() == Some(&b'0')) {
        return None;
    }
    std::str::from_utf8(d).ok()?.parse().ok()
}

fn token<'a>(b: &'a [u8], i: &mut usize) -> Option<&'a [u8]> {
    let tail = b.get(*i..)?;
    let n = tail
        .iter()
        .take_while(|c| c.is_ascii_alphanumeric() || matches!(c, b'_' | b'.' | b'/' | b'-'))
        .count();
    *i += n;
    tail.get(..n).filter(|t| !t.is_empty())
}

fn eat(b: &[u8], i: &mut usize, lit: &[u8]) -> Option<()> {
    b.get(*i..)?.starts_with(lit).then(|| *i += lit.len())
}

fn parse_head(line: &[u8]) -> Option<Head<'_>> {
    let mut i = 0;
    eat(line, &mut i, b"{\"seq\":")?;
    let seq = number(line, &mut i)?;
    eat(line, &mut i, b",\"at\":")?;
    let at = number(line, &mut i)?;
    eat(line, &mut i, b",\"dir\":\"")?;
    let dir = token(line, &mut i)?;
    eat(line, &mut i, b"\",\"kind\":\"")?;
    let kind = token(line, &mut i)?;
    eat(line, &mut i, b"\",")?;
    Some(Head { seq, at, dir, kind, rest: i })
}

fn push_escaped(out: &mut Vec<u8>, mut span: &[u8]) {
    while let Some(p) = memchr::memchr(ESC, span)
        && let Some((text, tail)) = span.split_at_checked(p + 1)
    {
        out.extend_from_slice(text);
        out.push(ESC);
        span = tail;
    }
    out.extend_from_slice(span);
}

/// `rest` with each long string replaced by its blob's number.
fn slim(
    rest: &[u8],
    min: usize,
    index: &mut BlobIndex,
    blobs: &mut Vec<u8>,
    table: &mut Vec<u8>,
) -> Vec<u8> {
    let mut out = Vec::with_capacity(rest.len().min(1 << 16));
    let (mut copied, mut i) = (0, 0);
    while let Some(q) = rest.get(i..).and_then(|r| memchr::memchr(b'"', r)) {
        let start = i + q + 1;
        let mut j = start;
        let end = loop {
            let Some(tail) = rest.get(j..) else { break None };
            match memchr::memchr2(b'"', b'\\', tail) {
                None => break None,
                Some(p) if tail.get(p) == Some(&b'"') => break Some(j + p),
                Some(p) => j += p + 2,
            }
        };
        let Some(end) = end else { break };
        if end - start >= min
            && let Some(before) = rest.get(copied..start)
            && let Some(s) = rest.get(start..end)
            && let Some(n) = index.intern(s, blobs, table)
        {
            push_escaped(&mut out, before);
            out.push(ESC);
            let _ = write!(out, "{n};");
            copied = end;
        }
        i = end + 1;
    }
    if let Some(tail) = rest.get(copied..) {
        push_escaped(&mut out, tail);
    }
    out
}

/// A segment's chunks before compression, and what the manifest says of it.
pub struct Encoded {
    pub events: Vec<u8>,
    pub blobs: Vec<u8>,
    pub table: Vec<u8>,
    pub seq: Option<(u64, u64)>,
    pub marks: Vec<u64>,
}

/// Encodes a segment's lines (each without its newline), the first of them line `first_line`.
pub fn encode_segment(
    lines: &[&[u8]],
    first_line: u64,
    params: &Params,
    index: &mut BlobIndex,
) -> Encoded {
    let mut head = Vec::new();
    // Each line's kind and remainder, in line order.
    let mut rows: Vec<(&[u8], Vec<u8>)> = Vec::with_capacity(lines.len());
    let (mut blobs, mut table) = (Vec::new(), Vec::new());
    let (mut prev_seq, mut prev_at) = (0u64, 0u64);
    let mut seq: Option<(u64, u64)> = None;
    let mut marks = Vec::new();
    let min = params.blob_min as usize;
    for (i, line) in lines.iter().enumerate() {
        let (kind, rest) = match parse_head(line).and_then(|h| Some((line.get(h.rest..)?, h))) {
            Some((rest, h)) => {
                let (ds, da) = (
                    i128::from(h.seq) - i128::from(prev_seq),
                    i128::from(h.at) - i128::from(prev_at),
                );
                let _ = write!(head, "{ds} {da} ");
                head.extend_from_slice(h.dir);
                head.push(b' ');
                head.extend_from_slice(h.kind);
                head.push(b'\n');
                (prev_seq, prev_at) = (h.seq, h.at);
                seq = Some(seq.map_or((h.seq, h.seq), |(lo, hi)| (lo.min(h.seq), hi.max(h.seq))));
                if params.marks.iter().any(|m| m.as_bytes() == h.kind) {
                    marks.push(first_line + i as u64);
                }
                (h.kind, rest)
            }
            None => {
                head.extend_from_slice(b"!\n");
                (&b""[..], *line)
            }
        };
        rows.push((kind, slim(rest, min, index, &mut blobs, &mut table)));
    }
    // A stable sort: by kind, then by line.
    rows.sort_by(|a, b| a.0.cmp(b.0));
    let body: usize = rows.iter().map(|(_, s)| s.len() + 1).sum();
    let mut events = Vec::with_capacity(4 + head.len() + body);
    events.extend_from_slice(&(head.len() as u32).to_le_bytes());
    events.extend_from_slice(&head);
    for (_, s) in &rows {
        events.extend_from_slice(s);
        events.push(b'\n');
    }
    Encoded { events, blobs, table, seq, marks }
}

/// A decoded events chunk.
pub struct Events {
    payload: Vec<u8>,
    prefixes: Vec<Vec<u8>>,
    rests: Vec<(usize, usize)>,
    /// Each line's `seq`, when it is an acpmux record.
    pub seqs: Vec<Option<u64>>,
}

impl Events {
    /// Reads an events chunk's bytes.
    pub fn decode(payload: Vec<u8>) -> Result<Self> {
        let bad = || "an events chunk is damaged";
        let head_len = u32::from_le_bytes(*payload.first_chunk::<4>().ok_or_else(bad)?) as usize;
        let head = payload.get(4..4 + head_len).ok_or_else(bad)?;
        let (mut prefixes, mut kinds, mut seqs) = (Vec::new(), Vec::new(), Vec::new());
        let (mut prev_seq, mut prev_at) = (0i128, 0i128);
        for row in head.split_inclusive(|b| *b == b'\n') {
            let row = row.strip_suffix(b"\n").ok_or_else(bad)?;
            if row == b"!" {
                prefixes.push(Vec::new());
                kinds.push(&b""[..]);
                seqs.push(None);
                continue;
            }
            let mut f = row.split(|b| *b == b' ');
            let mut num =
                || -> Result<i128> { Ok(std::str::from_utf8(f.next().ok_or_else(bad)?)?.parse()?) };
            prev_seq += num()?;
            prev_at += num()?;
            let (dir, kind) = (f.next().ok_or_else(bad)?, f.next().ok_or_else(bad)?);
            let mut p = Vec::with_capacity(48 + dir.len() + kind.len());
            let _ = write!(p, "{{\"seq\":{prev_seq},\"at\":{prev_at},\"dir\":\"");
            p.extend_from_slice(dir);
            p.extend_from_slice(b"\",\"kind\":\"");
            p.extend_from_slice(kind);
            p.extend_from_slice(b"\",");
            prefixes.push(p);
            kinds.push(kind);
            seqs.push(u64::try_from(prev_seq).ok());
        }
        let mut order: Vec<usize> = (0..kinds.len()).collect();
        order.sort_by_key(|i| kinds.get(*i));
        let mut rests = vec![(0, 0); order.len()];
        let mut at = 4 + head_len;
        for i in order {
            let end =
                at + payload.get(at..).and_then(|t| memchr::memchr(b'\n', t)).ok_or_else(bad)?;
            *rests.get_mut(i).ok_or_else(bad)? = (at, end);
            at = end + 1;
        }
        if at != payload.len() {
            return Err(bad().into());
        }
        Ok(Self { payload, prefixes, rests, seqs })
    }

    /// How many lines it holds.
    pub fn len(&self) -> usize {
        self.rests.len()
    }

    /// The numbers of the blobs line `i` names, appended to `out`.
    /// A line past the chunk names none.
    pub fn blob_refs(&self, i: usize, out: &mut Vec<u64>) {
        let Some(mut span) = self.rest(i) else { return };
        while let Some(p) = memchr::memchr(ESC, span)
            && let Some(tail) = span.get(p + 1..)
        {
            span = tail;
            if let [ESC, after @ ..] = span {
                span = after;
            } else if let Some(end) = memchr::memchr(b';', span)
                && let Some((d, after)) = span.split_at_checked(end)
                && let Some(n) = std::str::from_utf8(d).ok().and_then(|d| d.parse().ok())
            {
                out.push(n);
                span = after.get(1..).unwrap_or_default();
            }
        }
    }

    /// Line `i`'s remainder, as the chunk holds it.
    fn rest(&self, i: usize) -> Option<&[u8]> {
        let (s, e) = *self.rests.get(i)?;
        self.payload.get(s..e)
    }

    /// Appends line `i` (without a newline) to `out`; `blob` appends a blob by its number.
    pub fn line(
        &self,
        i: usize,
        blob: &mut dyn FnMut(u64, &mut Vec<u8>) -> Result<()>,
        out: &mut Vec<u8>,
    ) -> Result<()> {
        let past = "a line number past its events chunk";
        out.extend_from_slice(self.prefixes.get(i).ok_or(past)?);
        let mut span = self.rest(i).ok_or(past)?;
        let damaged = "a blob reference is damaged";
        while let Some(p) = memchr::memchr(ESC, span) {
            let (text, tail) = span.split_at_checked(p).ok_or(damaged)?;
            out.extend_from_slice(text);
            span = tail.get(1..).ok_or(damaged)?;
            if let [ESC, after @ ..] = span {
                out.push(ESC);
                span = after;
                continue;
            }
            let end = memchr::memchr(b';', span).ok_or(damaged)?;
            let (d, after) = span.split_at_checked(end).ok_or(damaged)?;
            blob(std::str::from_utf8(d)?.parse()?, out)?;
            span = after.get(1..).ok_or(damaged)?;
        }
        out.extend_from_slice(span);
        Ok(())
    }
}

/// A segment's own blobs: its decoded blobs chunk and table.
pub struct Blobs {
    bytes: Vec<u8>,
    entries: Vec<(usize, u32, u8)>,
}

impl Blobs {
    /// Reads a blobs chunk and its table.
    pub fn decode(bytes: Vec<u8>, table: &[u8]) -> Result<Self> {
        if !table.len().is_multiple_of(ENTRY) {
            return Err("a blob table's length is not a whole number of entries".into());
        }
        let mut at = 0usize;
        let mut entries = Vec::with_capacity(table.len() / ENTRY);
        for e in table.chunks_exact(ENTRY) {
            let &[a, b, c, d, enc, ..] = e else {
                return Err("a blob table entry is short".into());
            };
            let len = u32::from_le_bytes([a, b, c, d]);
            entries.push((at, len, enc));
            at += len as usize;
        }
        if at != bytes.len() {
            return Err("a blob table does not add up to its blobs chunk".into());
        }
        Ok(Self { bytes, entries })
    }

    /// Appends the segment's `i`th blob, as the log has it, to `out`.
    pub fn get(&self, i: usize, out: &mut Vec<u8>) -> Result<()> {
        let (at, len, enc) =
            *self.entries.get(i).ok_or("a blob number past its segment's blobs")?;
        let body =
            self.bytes.get(at..at + len as usize).ok_or("a blob past its blobs chunk's end")?;
        match enc {
            ENC_RAW => out.extend_from_slice(body),
            ENC_B64 => out.extend_from_slice(STANDARD.encode(body).as_bytes()),
            other => {
                return Err(
                    format!("a blob has encoding {other}, which this build does not read").into()
                );
            }
        }
        Ok(())
    }
}
