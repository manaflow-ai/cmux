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
//! read asks only for the bytes after the last one and yields whole lines.

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

/// Whole lines read so far from one transcript file, by byte offset.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct TranscriptTail {
    offset: u64,
    partial: Vec<u8>,
    restarts: u64,
}

/// The longest line kept while waiting for its newline: a transcript line past this is
/// dropped whole rather than held in memory without bound.
pub const MAX_LINE_BYTES: usize = 16 * 1024 * 1024;

impl TranscriptTail {
    pub fn new() -> Self {
        Self::default()
    }

    /// The byte offset the next read starts at (`Range: bytes=<offset>-`).
    pub fn offset(&self) -> u64 {
        self.offset
    }

    /// How many times the file shrank and was read again from its start.
    pub fn restarts(&self) -> u64 {
        self.restarts
    }

    /// The `Range` header value for the next read.
    pub fn range(&self) -> String {
        format!("bytes={}-", self.offset)
    }

    /// Takes one read's answer and returns the whole lines it completed, in order, without
    /// their newline (a `\r` before it is dropped too). Empty lines are skipped. A shrunk file
    /// starts the tail over from byte 0; the caller reads again and gets its lines anew.
    pub fn take(&mut self, read: TailRead) -> Vec<String> {
        let bytes = match read {
            TailRead::Missing => return Vec::new(),
            TailRead::Shrunk => {
                self.offset = 0;
                self.partial.clear();
                self.restarts += 1;
                return Vec::new();
            }
            TailRead::Bytes(bytes) => bytes,
        };
        self.offset += bytes.len() as u64;
        let mut lines = Vec::new();
        let mut rest = bytes.as_slice();
        while let Some(end) = rest.iter().position(|b| *b == b'\n') {
            let (piece, after) = rest.split_at(end);
            rest = &after[1..];
            if self.partial.len() > MAX_LINE_BYTES {
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
        if self.partial.len() <= MAX_LINE_BYTES {
            self.partial.extend_from_slice(rest);
        }
        lines
    }
}

/// The file size a `Content-Range` header names (`bytes 0-9/120` or a 416's `bytes */120`).
pub fn content_range_size(value: &str) -> Option<u64> {
    value.trim().strip_prefix("bytes ")?.rsplit_once('/')?.1.parse().ok()
}

/// Reads an HTTP answer to a ranged read from `offset`: 206 or 200 with the bytes (a 200 is the
/// whole file, from a server that ignored `Range`); 416 (nothing at or past the offset) as no
/// bytes when the file's size (`size`, from the 416's `Content-Range`) is the offset, else as
/// shrunk; 404 as missing. Any other status is not a read.
pub fn classify(status: u16, body: Vec<u8>, offset: u64, size: Option<u64>) -> Option<TailRead> {
    match status {
        206 => Some(TailRead::Bytes(body)),
        200 => {
            let skip = usize::try_from(offset).ok()?;
            if body.len() < skip {
                return Some(TailRead::Shrunk);
            }
            Some(TailRead::Bytes(body[skip..].to_vec()))
        }
        416 => match size {
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
    /// and has no saved disk, 5xx).
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

/// Reads the bytes after `tail`'s offset from `url` (the VM API's
/// `/v1/vms/{vm}/files/content?path=<transcript>`, on a client that carries its key) and returns
/// the whole lines they complete. A shrunk file is read again from its start in the same call.
pub async fn read_next(
    http: &reqwest::Client,
    url: reqwest::Url,
    tail: &mut TranscriptTail,
) -> Result<Vec<String>, TailError> {
    for _ in 0..2 {
        let offset = tail.offset();
        let answer = http
            .get(url.clone())
            .header(reqwest::header::RANGE, tail.range())
            .send()
            .await
            .map_err(TailError::Http)?;
        let status = answer.status().as_u16();
        let size = answer
            .headers()
            .get(reqwest::header::CONTENT_RANGE)
            .and_then(|value| value.to_str().ok())
            .and_then(content_range_size);
        let body = answer.bytes().await.map_err(TailError::Http)?.to_vec();
        let read = classify(status, body, offset, size).ok_or(TailError::Status(status))?;
        let shrunk = read == TailRead::Shrunk;
        let lines = tail.take(read);
        if !shrunk {
            return Ok(lines);
        }
    }
    Ok(Vec::new())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bytes(s: &str) -> TailRead {
        TailRead::Bytes(s.as_bytes().to_vec())
    }

    #[test]
    fn a_line_split_across_reads_comes_out_once_whole() {
        let mut t = TranscriptTail::new();
        assert_eq!(t.take(bytes("{\"a\":1}\n{\"b\"")), vec!["{\"a\":1}"]);
        assert_eq!(t.offset(), 12);
        assert_eq!(t.range(), "bytes=12-");
        assert_eq!(t.take(bytes(":2}\r\n\n{\"c\":3}\n")), vec!["{\"b\":2}", "{\"c\":3}"]);
        assert_eq!(t.take(bytes("")), Vec::<String>::new());
    }

    #[test]
    fn a_shrunk_file_starts_over_from_its_first_byte() {
        let mut t = TranscriptTail::new();
        t.take(bytes("one\ntw"));
        assert_eq!(t.take(TailRead::Shrunk), Vec::<String>::new());
        assert_eq!((t.offset(), t.restarts()), (0, 1));
        assert_eq!(t.take(bytes("new\n")), vec!["new"], "the old partial line is gone");
    }

    #[test]
    fn a_missing_file_keeps_the_tail_as_it_was() {
        let mut t = TranscriptTail::new();
        t.take(bytes("x\n"));
        assert!(t.take(TailRead::Missing).is_empty());
        assert_eq!(t.offset(), 2);
    }

    #[test]
    fn an_overlong_line_is_dropped_whole_and_the_next_one_reads() {
        let mut t = TranscriptTail::new();
        let long = "x".repeat(MAX_LINE_BYTES + 10);
        assert!(t.take(TailRead::Bytes(long.into_bytes())).is_empty());
        assert_eq!(t.take(bytes("tail\nnext\n")), vec!["next"]);
    }

    #[test]
    fn http_answers_map_to_reads() {
        assert_eq!(classify(206, b"ab".to_vec(), 5, None), Some(bytes("ab")));
        assert_eq!(classify(200, b"hello world".to_vec(), 6, None), Some(bytes("world")));
        assert_eq!(classify(200, b"hi".to_vec(), 6, None), Some(TailRead::Shrunk));
        assert_eq!(classify(416, Vec::new(), 6, Some(6)), Some(bytes("")));
        assert_eq!(classify(416, Vec::new(), 6, Some(3)), Some(TailRead::Shrunk));
        assert_eq!(classify(404, Vec::new(), 0, None), Some(TailRead::Missing));
        assert_eq!(classify(502, Vec::new(), 0, None), None);
        assert_eq!(content_range_size("bytes */120"), Some(120));
        assert_eq!(content_range_size("bytes 0-9/120"), Some(120));
        assert_eq!(content_range_size("bytes 0-9/*"), None);
    }

    /// One local HTTP server that answers `answers` in order, recording each request's `Range`.
    async fn server(
        answers: Vec<(u16, Vec<(&'static str, String)>, Vec<u8>)>,
    ) -> (reqwest::Url, tokio::task::JoinHandle<Vec<String>>) {
        use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = reqwest::Url::parse(&format!(
            "http://{}/v1/vms/vm_x/files/content?path=/t.jsonl",
            listener.local_addr().unwrap()
        ))
        .unwrap();
        let task = tokio::spawn(async move {
            let mut ranges = Vec::new();
            for (status, headers, body) in answers {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut request = Vec::new();
                let mut buf = [0u8; 4096];
                while !request.windows(4).any(|w| w == b"\r\n\r\n") {
                    let n = socket.read(&mut buf).await.unwrap();
                    request.extend_from_slice(&buf[..n]);
                }
                let text = String::from_utf8_lossy(&request).to_ascii_lowercase();
                ranges.push(
                    text.lines().find_map(|l| l.strip_prefix("range: ")).unwrap_or("").to_string(),
                );
                let mut head = format!(
                    "HTTP/1.1 {status} X\r\ncontent-length: {}\r\nconnection: close\r\n",
                    body.len()
                );
                for (k, v) in headers {
                    head.push_str(&format!("{k}: {v}\r\n"));
                }
                head.push_str("\r\n");
                socket.write_all(head.as_bytes()).await.unwrap();
                socket.write_all(&body).await.unwrap();
            }
            ranges
        });
        (url, task)
    }

    #[tokio::test]
    async fn reads_ask_only_for_the_bytes_after_the_last_one() {
        let (url, server) = server(vec![
            (206, vec![("content-range", "bytes 0-9/10".into())], b"one\ntwo\nth".to_vec()),
            (416, vec![("content-range", "bytes */10".into())], Vec::new()),
            (206, vec![], b"ree\n".to_vec()),
            (416, vec![("content-range", "bytes */4".into())], Vec::new()),
            (206, vec![], b"new\n".to_vec()),
        ])
        .await;
        let http = reqwest::Client::new();
        let mut tail = TranscriptTail::new();
        assert_eq!(read_next(&http, url.clone(), &mut tail).await.unwrap(), vec!["one", "two"]);
        assert!(read_next(&http, url.clone(), &mut tail).await.unwrap().is_empty());
        assert_eq!(read_next(&http, url.clone(), &mut tail).await.unwrap(), vec!["three"]);
        // The file was replaced by a shorter one: read again from its start in the same call.
        assert_eq!(read_next(&http, url.clone(), &mut tail).await.unwrap(), vec!["new"]);
        assert_eq!(tail.restarts(), 1);
        assert_eq!(
            server.await.unwrap(),
            vec!["bytes=0-", "bytes=10-", "bytes=10-", "bytes=14-", "bytes=0-"]
        );
    }
}
