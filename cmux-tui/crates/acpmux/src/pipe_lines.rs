//! Lines of a child's pipe (a harness's stdout or stderr), read as bytes.
//!
//! A pipe carries bytes, not text: one line that is not UTF-8 (a tool's
//! stderr, a stray byte in a child's output) must not end the reader.
//! `tokio::io::Lines` returns `InvalidData` for such a line, which callers took
//! as the end of the pipe. [`PipeLines`] decodes each line lossily (U+FFFD for
//! a bad sequence) and keeps reading. Valid UTF-8 lines come out exactly as
//! `Lines` gives them: without the `\n` and one `\r` before it, and a last
//! line without `\n` at the end of the pipe.

use tokio::io::{AsyncBufRead, AsyncBufReadExt as _};

/// Reads lines of a pipe; see the module docs.
pub(crate) struct PipeLines<R> {
    reader: R,
    /// The line read so far. It lives here, not in `next_line`'s frame, so a
    /// `next_line` dropped in a `select!` loses nothing: the next call goes on.
    line: Vec<u8>,
    /// Bytes of the current line were read (an empty line still counts).
    started: bool,
    /// The current line was longer than `max_line_bytes`.
    cut: bool,
    /// Bytes a line may keep; the rest up to its `\n` is read and dropped.
    max_line_bytes: usize,
}

impl<R: AsyncBufRead + Unpin> PipeLines<R> {
    /// Every line whole, however long (the caller bounds what it keeps).
    pub(crate) fn new(reader: R) -> Self {
        Self::with_max_line_bytes(reader, usize::MAX)
    }

    /// Lines cut to `max_line_bytes`: the rest of a longer line is read and
    /// dropped, so one line without `\n` cannot grow without bound.
    pub(crate) fn with_max_line_bytes(reader: R, max_line_bytes: usize) -> Self {
        Self { reader, line: Vec::new(), started: false, cut: false, max_line_bytes }
    }

    /// The next line; `None` at the end of the pipe. An I/O error is the
    /// pipe's own (a decode error never happens here). Cancel safe: the only
    /// await is the read, and bytes are taken from the reader only together
    /// with their copy into the line.
    pub(crate) async fn next_line(&mut self) -> std::io::Result<Option<String>> {
        let ended = loop {
            let available = self.reader.fill_buf().await?;
            if available.is_empty() {
                break false;
            }
            self.started = true;
            let newline = memchr::memchr(b'\n', available);
            let body = available.get(..newline.unwrap_or(available.len())).unwrap_or(&[]);
            let room = self.max_line_bytes.saturating_sub(self.line.len());
            self.cut |= body.len() > room;
            self.line.extend_from_slice(body.get(..room.min(body.len())).unwrap_or(&[]));
            let consumed = body.len().saturating_add(usize::from(newline.is_some()));
            self.reader.consume(consumed);
            if newline.is_some() {
                break true;
            }
        };
        let cut = std::mem::take(&mut self.cut);
        if !std::mem::take(&mut self.started) {
            return Ok(None);
        }
        // `\r\n` ends a line; a lone `\r` at the end of the pipe is kept.
        if ended && !cut && self.line.last() == Some(&b'\r') {
            self.line.pop();
        }
        let line = String::from_utf8_lossy(&self.line).into_owned();
        self.line.clear();
        // A capacity left by one huge line is not kept for the pipe's life.
        self.line.shrink_to(KEEP_LINE_CAPACITY);
        Ok(Some(line))
    }
}

/// The longest stderr line kept: stderr lines are logged, never parsed whole.
pub(crate) const MAX_STDERR_LINE_BYTES: usize = 64 * 1024;

/// Capacity the line buffer keeps between lines.
const KEEP_LINE_CAPACITY: usize = 64 * 1024;

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::BufReader;

    async fn read_all(input: &[u8], capacity: usize, max: usize) -> Vec<String> {
        let mut lines =
            PipeLines::with_max_line_bytes(BufReader::with_capacity(capacity, input), max);
        let mut out = Vec::new();
        while let Some(line) = lines.next_line().await.unwrap() {
            out.push(line);
        }
        out
    }

    /// The reader this replaces, for valid UTF-8.
    async fn lines_reference(input: &[u8]) -> Vec<String> {
        let mut lines = BufReader::new(input).lines();
        let mut out = Vec::new();
        while let Some(line) = lines.next_line().await.unwrap() {
            out.push(line);
        }
        out
    }

    #[tokio::test]
    async fn valid_utf8_reads_as_lines_did_at_every_buffer_size() {
        let inputs: [&[u8]; 9] = [
            b"",
            b"\n",
            b"one",
            b"one\ntwo\n",
            b"one\r\ntwo\r\n\r\n",
            b"a\r\rb\n\r",
            b"\n\n\nlast without newline",
            "\u{e9}t\u{e9}\n\u{1F600} wide \u{4E2D}\n".as_bytes(),
            b"{\"jsonrpc\":\"2.0\",\"id\":1}\n{\"method\":\"x\"}",
        ];
        for input in inputs {
            let expected = lines_reference(input).await;
            for capacity in [1, 2, 3, 7, 64, 8192] {
                assert_eq!(
                    read_all(input, capacity, usize::MAX).await,
                    expected,
                    "{input:?} at buffer {capacity}"
                );
            }
        }
    }

    #[tokio::test]
    async fn a_line_that_is_not_utf8_is_lossy_and_reading_goes_on() {
        let input = b"good\nbad \xff\xfe end\n\xc3\nafter\n";
        for capacity in [1, 2, 5, 8192] {
            assert_eq!(
                read_all(input, capacity, usize::MAX).await,
                ["good", "bad \u{FFFD}\u{FFFD} end", "\u{FFFD}", "after"],
                "at buffer {capacity}"
            );
        }
    }

    /// A `next_line` dropped mid-line (a `select!` branch that lost) loses no byte.
    #[tokio::test]
    async fn a_cancelled_read_keeps_the_partial_line() {
        let (mut write, read) = tokio::io::duplex(64);
        let mut lines = PipeLines::new(BufReader::new(read));
        tokio::io::AsyncWriteExt::write_all(&mut write, b"first half ").await.unwrap();
        let cancelled =
            tokio::time::timeout(std::time::Duration::from_millis(50), lines.next_line()).await;
        assert!(cancelled.is_err(), "no line yet");
        tokio::io::AsyncWriteExt::write_all(&mut write, b"second half\nnext\n").await.unwrap();
        drop(write);
        assert_eq!(lines.next_line().await.unwrap().as_deref(), Some("first half second half"));
        assert_eq!(lines.next_line().await.unwrap().as_deref(), Some("next"));
        assert_eq!(lines.next_line().await.unwrap(), None);
    }

    #[tokio::test]
    async fn a_long_line_is_cut_and_the_next_line_is_whole() {
        let mut input = vec![b'x'; 100_000];
        input.extend_from_slice(b"\nnext\n");
        for capacity in [7, 8192] {
            let lines = read_all(&input, capacity, 1000).await;
            assert_eq!(lines.len(), 2);
            assert_eq!(lines[0], "x".repeat(1000));
            assert_eq!(lines[1], "next");
        }
    }
}
