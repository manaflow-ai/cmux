//! Rare JSONL records that span a page. Keep their source bytes folded until explicitly read.
//! A newline witnessed by the newer page proves that a fragment inside the older page belongs
//! to a complete record. An unfinished append can span many pages without ever being published.

use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::ops::Range;

use serde::Serialize;
use serde_json::{Value, json};

use crate::adopt_replay::TranscriptPage;
use crate::rpc::RpcError;

const CHUNK: u64 = 64 * 1024;

#[derive(Serialize)]
pub(super) struct Part {
    pub start: u64,
    pub end: u64,
    position: &'static str,
}

fn invalid(error: io::Error) -> RpcError {
    RpcError::invalid_params(format!("could not read transcript source: {error}"))
}

fn bytes(file: &mut File, range: Range<u64>) -> Result<Vec<u8>, RpcError> {
    let mut data = vec![0; (range.end - range.start) as usize];
    file.seek(SeekFrom::Start(range.start)).map_err(invalid)?;
    file.read_exact(&mut data).map_err(invalid)?;
    Ok(data)
}

/// The same boundary on two adjacent pages rounds the same way, without splitting UTF-8.
fn boundary(file: &mut File, at: u64, size: u64) -> Result<u64, RpcError> {
    if at == 0 || at == size {
        return Ok(at);
    }
    let start = at.saturating_sub(3);
    let data = bytes(file, start..at + 1)?;
    Ok(start + data.iter().rposition(|b| b & 0xc0 != 0x80).unwrap_or(0) as u64)
}

pub(super) fn witness(
    file: &mut File,
    size: u64,
    supplied: Option<&Value>,
) -> Result<Option<u64>, RpcError> {
    if let Some(value) = supplied.filter(|v| !v.is_null()) {
        let at = value
            .as_u64()
            .filter(|at| *at > 0 && *at <= size)
            .ok_or_else(|| RpcError::invalid_params("invalid completeThrough offset"))?;
        if bytes(file, at - 1..at)?.as_slice() != b"\n" {
            return Err(RpcError::invalid_params("completeThrough must follow a newline"));
        }
        return Ok(Some(at));
    }
    // Fresh requests (e.g. a bookmark into an older page) can use the normal complete EOF.
    if size > 0 && bytes(file, size - 1..size)?.as_slice() == b"\n" {
        Ok(Some(size))
    } else {
        Ok(None)
    }
}

pub(super) fn parts(
    file: &mut File,
    page: &TranscriptPage,
    size: u64,
    through: &mut Option<u64>,
) -> Result<Vec<Part>, RpcError> {
    *through = (*through).max(page.last_break);
    let mut out = Vec::new();
    let mut add = |source: Range<u64>, position| -> Result<(), RpcError> {
        let start = boundary(file, source.start, size)?;
        let end = boundary(file, source.end, size)?;
        if start < end {
            out.push(Part { start, end, position });
        }
        Ok(())
    };
    if let Some(range) = &page.clipped_head {
        add(range.clone(), "before")?;
    }
    let from = page.last_break.unwrap_or(page.start).max(page.start);
    if from < page.end && through.is_some_and(|n| n > page.end) {
        add(from..page.end, "after")?;
    }
    Ok(out)
}

pub(super) struct Request {
    pub start: u64,
    pub end: u64,
    offset: u64,
}

impl Request {
    pub fn parse(params: &Value, can_read: bool) -> Result<Option<Self>, RpcError> {
        let keys = ["rawStart", "rawEnd", "rawOffset"];
        if !keys.iter().any(|key| params.get(*key).is_some()) {
            return Ok(None);
        }
        let coords = keys.map(|key| params.get(key).and_then(Value::as_u64));
        let [Some(start), Some(end), Some(offset)] = coords else {
            return Err(RpcError::invalid_params("rawStart, rawEnd and rawOffset are required"));
        };
        if !can_read || start > offset || offset >= end {
            return Err(RpcError::invalid_params("invalid raw source range"));
        }
        Ok(Some(Self { start, end, offset }))
    }

    pub fn read(&self, file: &mut File, size: u64) -> Result<Value, RpcError> {
        if boundary(file, self.offset, size)? != self.offset {
            return Err(RpcError::invalid_params(
                "raw range is not part of this page or UTF-8 offset is invalid",
            ));
        }
        let next = boundary(file, self.end.min(self.offset.saturating_add(CHUNK)), size)?;
        let text = String::from_utf8(bytes(file, self.offset..next)?)
            .map_err(|_| RpcError::invalid_params("transcript source is not UTF-8"))?;
        Ok(json!({"text": text, "nextOffset": (next < self.end).then_some(next)}))
    }
}

/// Match the literal JSONL spelling. Unlike ordinary folded roles, this view also contains
/// JSON escapes (e.g. a literal newline is written as backslash-n). A small overlap handles a
/// match split across read chunks or adjacent exceptional page ranges without growing memory.
pub(super) fn find(
    file: &mut File,
    part: &Part,
    query: &str,
    through: u64,
    page_end: u64,
) -> Result<Option<Value>, RpcError> {
    let needle = query.as_bytes().to_ascii_lowercase();
    if needle.is_empty() || needle.contains(&b'\n') {
        return Ok(None);
    }
    let overlap = (needle.len() - 1) as u64;
    let limit = through.min(part.end.saturating_add(overlap));
    let mut pos = part.start;
    while pos < part.end {
        let next = part.end.min(pos + CHUNK);
        let mut data = bytes(file, pos..limit.min(next + overlap))?;
        data.make_ascii_lowercase();
        if let Some(index) = memchr::memmem::find(&data, &needle) {
            let at = pos + index as u64;
            if at < part.end {
                return Ok(Some(json!({"role":"raw", "pageEnd":page_end, "rawStart":part.start,
                    "rawEnd":part.end, "rawOffset":at, "completeThrough":through, "snippet":query})));
            }
        }
        pos = next;
    }
    Ok(None)
}
