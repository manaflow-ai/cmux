//! Reading a Cloud chat's transcript (an agent's JSONL) from its machine's files, not a live
//! stream through the machine (cmux#36050).
//!
//! The VM API serves a machine's file with `Range` (`GET /v1/vms/{vm}/files/content?path=`,
//! backed by Freestyle `GET /v5/vms/{id}/fs/read`). Measured on Freestyle (2026-11-04):
//! - a running machine: a line the guest wrote is readable at once (30-100 ms a read, a ranged
//!   tail about 50 ms);
//! - a paused machine: the read does not wake it (about 100 ms), but it sees the saved disk only,
//!   so a write not yet flushed at the pause is missing. acpmux flushes before it lets the
//!   machine pause (`daemon/cloud_activity.rs`, `flushes_before`).
//!
//! [`TranscriptTail`] keeps a byte offset and a trailing partial line across reads, so each
//! read asks only for the bytes after the last one, at most [`CHUNK_BYTES`] at a time, and
//! yields whole lines.

/// What a read of the transcript's next bytes found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TailRead {
    /// The bytes from the tail's offset (possibly none).
    Bytes(Vec<u8>),
    /// The file is shorter than the offset: it was replaced or truncated.
    Shrunk,
    /// No file at the path (yet).
    Missing,
}

/// The longest line kept while waiting for its newline: a transcript line past this is
/// dropped whole rather than held in memory without bound.
pub const MAX_LINE_BYTES: usize = 16 * 1024 * 1024;

/// The most bytes one request asks for (`Range: bytes=<offset>-<offset + CHUNK_BYTES - 1>`).
pub const CHUNK_BYTES: u64 = 4 * 1024 * 1024;

/// The most requests one [`read_next`] makes before it returns what it has; the tail's
/// [`TranscriptTail::more`] then says the file had more.
pub const CHUNKS_PER_READ: usize = 8;

/// Whole lines read so far from one transcript file, by byte offset.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TranscriptTail {
    offset: u64,
    partial: Vec<u8>,
    /// Inside a line past [`MAX_LINE_BYTES`]: its bytes are skipped up to its newline.
    dropping: bool,
    restarts: u64,
    chunk: u64,
    more: bool,
}

impl Default for TranscriptTail {
    fn default() -> Self {
        Self::with_chunk(CHUNK_BYTES)
    }
}

impl TranscriptTail {
    pub fn new() -> Self {
        Self::default()
    }

    /// A tail whose requests ask for at most `chunk` bytes (at least 1).
    pub fn with_chunk(chunk: u64) -> Self {
        Self {
            offset: 0,
            partial: Vec::new(),
            dropping: false,
            restarts: 0,
            chunk: chunk.max(1),
            more: false,
        }
    }

    /// The byte offset the next read starts at.
    pub fn offset(&self) -> u64 {
        self.offset
    }

    /// How many times the file shrank and was read again from its start.
    pub fn restarts(&self) -> u64 {
        self.restarts
    }

    /// Whether the last [`read_next`] stopped with bytes maybe still unread: at
    /// [`CHUNKS_PER_READ`], or at a request that failed after earlier chunks were read.
    pub fn more(&self) -> bool {
        self.more
    }

    /// The `Range` header value for the next read: one closed chunk from the offset.
    pub fn range(&self) -> String {
        format!(
            "bytes={}-{}",
            self.offset,
            self.offset.saturating_add(self.chunk.saturating_sub(1))
        )
    }

    /// Takes one read's answer and returns the whole lines it completed, in order, without
    /// their newline (a `\r` before it is dropped too). Empty lines are skipped, and so is a
    /// line longer than [`MAX_LINE_BYTES`], whole, however its bytes arrive. A shrunk file
    /// starts the tail over from byte 0; the caller reads again and gets its lines anew.
    pub fn take(&mut self, read: TailRead) -> Vec<String> {
        let bytes = match read {
            TailRead::Missing => return Vec::new(),
            TailRead::Shrunk => {
                self.offset = 0;
                self.partial.clear();
                self.dropping = false;
                self.restarts = self.restarts.saturating_add(1);
                return Vec::new();
            }
            TailRead::Bytes(bytes) => bytes,
        };
        self.offset = self.offset.saturating_add(len_u64(&bytes));
        let mut lines = Vec::new();
        let mut rest = bytes.as_slice();
        while let Some(end) = rest.iter().position(|b| *b == b'\n') {
            let (piece, after) = rest.split_at(end);
            rest = after.get(1..).unwrap_or_default();
            if std::mem::take(&mut self.dropping)
                || self.partial.len().saturating_add(piece.len()) > MAX_LINE_BYTES
            {
                // The overlong line ends here: drop it whole.
                self.partial.clear();
                continue;
            }
            self.partial.extend_from_slice(piece);
            let mut line = std::mem::take(&mut self.partial);
            if line.last() == Some(&b'\r') {
                line.pop();
            }
            if !line.is_empty() {
                lines.push(String::from_utf8_lossy(&line).into_owned());
            }
        }
        if self.dropping || self.partial.len().saturating_add(rest.len()) > MAX_LINE_BYTES {
            self.partial.clear();
            self.dropping = true;
        } else {
            self.partial.extend_from_slice(rest);
        }
        lines
    }
}

/// A `Content-Range` header: `bytes 0-9/120` (start 0, size 120), a 416's `bytes */120`
/// (size only), or `bytes 0-9/*` (start only).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ContentRange {
    pub start: Option<u64>,
    pub size: Option<u64>,
}

impl ContentRange {
    pub fn parse(value: &str) -> Option<Self> {
        let (span, size) = value.trim().strip_prefix("bytes ")?.rsplit_once('/')?;
        let start = match span {
            "*" => None,
            span => Some(span.split_once('-')?.0.parse().ok()?),
        };
        Some(Self { start, size: if size == "*" { None } else { Some(size.parse().ok()?) } })
    }
}

/// Reads an HTTP answer to a ranged read from `offset`:
/// - 206 with the bytes, when it starts at `offset` (a `Content-Range` naming another start is
///   not a read);
/// - 200 with the whole file, from a server that ignored `Range`: the bytes past `offset`, or
///   shrunk when the file is shorter;
/// - 416 (nothing at or past the offset): shrunk when the file's size (`range.size`) is below
///   the offset, else no bytes; the caller learns the size first when the 416 did not say it
///   ([`read_next`] asks for byte 0);
/// - 404: missing.
///
/// Any other answer is not a read.
pub fn classify(
    status: u16,
    body: Vec<u8>,
    offset: u64,
    range: Option<ContentRange>,
) -> Option<TailRead> {
    match status {
        206 => match range.and_then(|r| r.start) {
            Some(start) if start != offset => None,
            _ => Some(TailRead::Bytes(body)),
        },
        200 => {
            let skip = usize::try_from(offset).ok()?;
            if body.len() < skip {
                return Some(TailRead::Shrunk);
            }
            Some(body.get(skip..).map_or(TailRead::Shrunk, |rest| TailRead::Bytes(rest.to_vec())))
        }
        416 => match range.and_then(|r| r.size) {
            Some(size) if size < offset => Some(TailRead::Shrunk),
            _ => Some(TailRead::Bytes(Vec::new())),
        },
        404 => Some(TailRead::Missing),
        _ => None,
    }
}

/// A transcript read that did not answer as a file read.
#[derive(Debug)]
pub enum TailError {
    Http(reqwest::Error),
    /// The status the files route answered (401, 403, 409 for a machine that is not running
    /// and has no saved disk, 5xx), or a 206 for bytes other than the ones asked for.
    Status(u16),
}

impl std::fmt::Display for TailError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Http(error) => write!(f, "transcript read failed: {error}"),
            Self::Status(status) => write!(f, "transcript read answered HTTP {status}"),
        }
    }
}

impl std::error::Error for TailError {}

struct Answer {
    status: u16,
    range: Option<ContentRange>,
    body: Vec<u8>,
}

async fn get(http: &reqwest::Client, url: &reqwest::Url, range: &str) -> Result<Answer, TailError> {
    let answer = http
        .get(url.clone())
        .header(reqwest::header::RANGE, range)
        .send()
        .await
        .map_err(TailError::Http)?;
    let status = answer.status().as_u16();
    let range = answer
        .headers()
        .get(reqwest::header::CONTENT_RANGE)
        .and_then(|value| value.to_str().ok())
        .and_then(ContentRange::parse);
    let body = answer.bytes().await.map_err(TailError::Http)?.to_vec();
    Ok(Answer { status, range, body })
}

/// A byte count as a file offset (a `usize` always fits in a `u64` on the targets cmux runs on).
fn len_u64(bytes: &[u8]) -> u64 {
    u64::try_from(bytes.len()).unwrap_or(u64::MAX)
}

/// The file's size, from a read of its first byte, for a 416 that did not name it.
async fn size_of(http: &reqwest::Client, url: &reqwest::Url) -> Result<Option<u64>, TailError> {
    let probe = get(http, url, "bytes=0-0").await?;
    Ok(match probe.status {
        206 => probe.range.and_then(|r| r.size),
        416 => Some(0),
        200 => Some(len_u64(&probe.body)),
        404 => None,
        status => return Err(TailError::Status(status)),
    })
}

/// Reads the bytes after `tail`'s offset from `url` (the VM API's
/// `/v1/vms/{vm}/files/content?path=<transcript>`, on a client that carries its key) and returns
/// the whole lines they complete. It reads chunk by chunk until a short one, at most
/// [`CHUNKS_PER_READ`] of them (then [`TranscriptTail::more`] is true). A shrunk file is read
/// again from its start in the same call. A failed first request is the error; a failed later one
/// returns the lines read before it, with `more` set.
pub async fn read_next(
    http: &reqwest::Client,
    url: reqwest::Url,
    tail: &mut TranscriptTail,
) -> Result<Vec<String>, TailError> {
    let mut lines = Vec::new();
    let mut shrinks: u8 = 0;
    let mut chunks: usize = 0;
    tail.more = false;
    while chunks < CHUNKS_PER_READ {
        let (status, read) = match next_read(http, &url, tail).await {
            Ok(answer) => answer,
            // The offset already stands past the lines read so far: hand them over, and have
            // the caller read again, where the failure surfaces on its own.
            Err(_) if chunks > 0 => {
                tail.more = true;
                return Ok(lines);
            }
            Err(error) => return Err(error),
        };
        let full = matches!(&read, TailRead::Bytes(b) if status == 206 && len_u64(b) >= tail.chunk);
        if read == TailRead::Shrunk {
            shrinks = shrinks.saturating_add(1);
            tail.take(read);
            if shrinks > 1 {
                break;
            }
            continue;
        }
        lines.extend(tail.take(read));
        chunks = chunks.saturating_add(1);
        if !full {
            return Ok(lines);
        }
    }
    tail.more = chunks >= CHUNKS_PER_READ;
    Ok(lines)
}

/// One ranged read from `tail`'s offset, classified: the answer's status and what it read.
async fn next_read(
    http: &reqwest::Client,
    url: &reqwest::Url,
    tail: &TranscriptTail,
) -> Result<(u16, TailRead), TailError> {
    let offset = tail.offset();
    let mut answer = get(http, url, &tail.range()).await?;
    if answer.status == 416 && answer.range.and_then(|r| r.size).is_none() {
        let size = size_of(http, url).await?;
        answer.range = Some(ContentRange { start: None, size });
    }
    let status = answer.status;
    let read =
        classify(status, answer.body, offset, answer.range).ok_or(TailError::Status(status))?;
    Ok((status, read))
}

#[cfg(test)]
#[path = "transcript_tests.rs"]
mod tests;
