//! Bounded readers for append-only JSONL stores. Nothing here keeps line
//! content beyond the call; callers fold what they need into metadata.

use std::fs::File;
use std::io::{self, BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::Path;

use serde_json::Value;

/// Head and tail window size, as Claude Code's own session picker reads.
pub(crate) const WINDOW: u64 = 64 * 1024;
/// Upper bound for a whole-file JSON parse (Gemini legacy, Amp threads).
pub(crate) const WHOLE_FILE_MAX: u64 = 8 * 1024 * 1024;
/// Upper bound for one first line (Codex `session_meta` carries instructions).
pub(crate) const FIRST_LINE_MAX: u64 = 4 * 1024 * 1024;

/// Complete lines of the first and last `WINDOW` bytes, parsed as JSON.
/// A small file is all head. Partial lines at the cut points are dropped.
pub(crate) struct HeadTail {
    pub head: Vec<Value>,
    pub tail: Vec<Value>,
}

impl HeadTail {
    /// Head records, then tail records.
    pub fn all(&self) -> impl Iterator<Item = &Value> {
        self.head.iter().chain(self.tail.iter())
    }
}

pub(crate) fn read_head_tail(path: &Path) -> io::Result<HeadTail> {
    let mut file = File::open(path)?;
    let len = file.metadata()?.len();
    if len <= 2 * WINDOW {
        let mut bytes = Vec::with_capacity(usize::try_from(len).unwrap_or(0));
        file.read_to_end(&mut bytes)?;
        return Ok(HeadTail { head: parse_lines(&bytes, false, false), tail: Vec::new() });
    }
    let mut head = vec![0; WINDOW as usize];
    file.read_exact(&mut head)?;
    file.seek(SeekFrom::Start(len - WINDOW))?;
    let mut tail = vec![0; WINDOW as usize];
    file.read_exact(&mut tail)?;
    Ok(HeadTail { head: parse_lines(&head, false, true), tail: parse_lines(&tail, true, false) })
}

fn parse_lines(bytes: &[u8], drop_first: bool, drop_last: bool) -> Vec<Value> {
    let mut slice = bytes;
    if drop_first {
        slice = slice.iter().position(|byte| *byte == b'\n').map_or(&[][..], |at| &slice[at + 1..]);
    }
    if drop_last {
        slice = slice.iter().rposition(|byte| *byte == b'\n').map_or(&[][..], |at| &slice[..at]);
    }
    slice
        .split(|byte| *byte == b'\n')
        .filter(|line| !line.iter().all(u8::is_ascii_whitespace))
        .filter_map(|line| serde_json::from_slice(line).ok())
        .collect()
}

/// The first line of a file, parsed, when it is at most `FIRST_LINE_MAX` bytes.
pub(crate) fn read_first_record(path: &Path) -> io::Result<Option<Value>> {
    let file = File::open(path)?;
    let mut line = Vec::new();
    BufReader::new(file).take(FIRST_LINE_MAX).read_until(b'\n', &mut line)?;
    Ok(serde_json::from_slice(&line).ok())
}

/// Calls `fold` for each complete line from `from`, and returns the offset
/// after the last complete line. A trailing partial line is left for the
/// next read (the writer is still appending it).
pub(crate) fn fold_lines(path: &Path, from: u64, mut fold: impl FnMut(&[u8])) -> io::Result<u64> {
    let mut file = File::open(path)?;
    file.seek(SeekFrom::Start(from))?;
    let mut reader = BufReader::new(file);
    let mut offset = from;
    let mut line = Vec::new();
    loop {
        line.clear();
        let read = reader.read_until(b'\n', &mut line)?;
        if read == 0 || line.last() != Some(&b'\n') {
            return Ok(offset);
        }
        offset += read as u64;
        fold(&line[..line.len() - 1]);
    }
}

/// Whole file as JSON when it is at most `WHOLE_FILE_MAX` bytes.
pub(crate) fn read_whole_json(path: &Path) -> io::Result<Option<Value>> {
    let file = File::open(path)?;
    if file.metadata()?.len() > WHOLE_FILE_MAX {
        return Ok(None);
    }
    let mut bytes = Vec::new();
    BufReader::new(file).read_to_end(&mut bytes)?;
    Ok(serde_json::from_slice(&bytes).ok())
}

/// True when `haystack` contains `needle` (byte search, no JSON parse).
pub(crate) fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|window| window == needle)
}
