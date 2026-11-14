//! The lines of a harness's stdout or stderr as text, whatever bytes they hold.
//!
//! tokio's `Lines` returns an error for a line that is not UTF-8, and every reader of a
//! harness pipe took an error for the pipe's end: one stray byte (a tool's binary output, a
//! log line in another encoding) made the agent host, or the daemon's direct child, stop
//! reading that pipe while the harness still ran. The turn then hung, or the harness died on
//! EPIPE at its next write. Here such a line comes through with U+FFFD for each invalid
//! sequence, and only the pipe's end (or a read error) ends the lines.

use tokio::io::{AsyncBufRead, AsyncBufReadExt};

/// Lines of `R` as tokio's `Lines` reads them (each without its `\n` or `\r\n`; a last line
/// with no `\n` too), but never an error for bytes that are not UTF-8.
pub struct LossyLines<R> {
    reader: R,
    /// The line read so far: kept when a `next_line` is cancelled (a `select!` branch that
    /// lost), so the next call goes on with it, as `Lines::next_line` does.
    buf: Vec<u8>,
}

impl<R: AsyncBufRead + Unpin> LossyLines<R> {
    pub fn new(reader: R) -> Self {
        Self { reader, buf: Vec::new() }
    }

    /// The next line; `Ok(None)` at the end of the pipe. Cancel safe.
    pub async fn next_line(&mut self) -> std::io::Result<Option<String>> {
        let read = self.reader.read_until(b'\n', &mut self.buf).await?;
        if read == 0 && self.buf.is_empty() {
            return Ok(None);
        }
        let mut line = std::mem::take(&mut self.buf);
        if line.last() == Some(&b'\n') {
            line.pop();
            if line.last() == Some(&b'\r') {
                line.pop();
            }
        }
        Ok(Some(match String::from_utf8(line) {
            Ok(text) => text,
            Err(e) => String::from_utf8_lossy(e.as_bytes()).into_owned(),
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::pin::Pin;
    use std::task::{Context, Poll};
    use tokio::io::{AsyncRead, ReadBuf};

    /// A pipe that hands out its bytes in the given chunks, one per read.
    struct Chunks(std::collections::VecDeque<Vec<u8>>);

    impl AsyncRead for Chunks {
        fn poll_read(
            mut self: Pin<&mut Self>,
            _: &mut Context<'_>,
            out: &mut ReadBuf<'_>,
        ) -> Poll<std::io::Result<()>> {
            if let Some(mut chunk) = self.0.pop_front() {
                let n = chunk.len().min(out.remaining());
                out.put_slice(&chunk[..n]);
                if n < chunk.len() {
                    self.0.push_front(chunk.split_off(n));
                }
            }
            Poll::Ready(Ok(()))
        }
    }

    fn pipe(chunks: &[&[u8]]) -> tokio::io::BufReader<Chunks> {
        tokio::io::BufReader::with_capacity(
            7, // A read of no bytes is the end of a pipe: an empty chunk is no read at all.
            Chunks(chunks.iter().filter(|c| !c.is_empty()).map(|c| c.to_vec()).collect()),
        )
    }

    async fn lossy(chunks: &[&[u8]]) -> Vec<String> {
        let mut lines = LossyLines::new(pipe(chunks));
        let mut out = Vec::new();
        while let Some(line) = lines.next_line().await.unwrap() {
            out.push(line);
        }
        out
    }

    /// The reader every harness pipe used before (`tokio::io::Lines`), up to its first error.
    async fn lines_reference(chunks: &[&[u8]]) -> (Vec<String>, bool) {
        let mut lines = pipe(chunks).lines();
        let mut out = Vec::new();
        loop {
            match lines.next_line().await {
                Ok(Some(line)) => out.push(line),
                Ok(None) => return (out, false),
                Err(_) => return (out, true),
            }
        }
    }

    /// Text the old reader read whole reads the same here, split at every position, so only a
    /// pipe it gave up on reads differently.
    #[tokio::test]
    async fn utf8_text_reads_as_the_old_reader_read_it_at_every_split() {
        let texts: [&[u8]; 9] = [
            b"",
            b"\n",
            b"one",
            b"one\ntwo\n",
            b"one\r\ntwo\r\n\r\n",
            b"a\rb\n\r\n\n\nlast with no newline",
            "h\u{e9}llo \u{1f600}\nw\u{f6}rld\n".as_bytes(),
            b"{\"jsonrpc\":\"2.0\",\"method\":\"x\"}\n{\"id\":1}\n",
            &[b'x'; 40],
        ];
        for text in texts {
            for at in 0..=text.len() {
                let chunks = [&text[..at], &text[at..]];
                let (old, failed) = lines_reference(&chunks).await;
                assert!(!failed, "{text:?}");
                assert_eq!(lossy(&chunks).await, old, "{text:?} split at {at}");
            }
            let bytes: Vec<&[u8]> = text.chunks(1).collect();
            assert_eq!(lossy(&bytes).await, lines_reference(&bytes).await.0, "{text:?} bytewise");
        }
    }

    /// A line that is not UTF-8 comes through with U+FFFD in place of its bad bytes, and the
    /// lines after it come too, at every split (a multi-byte character cut by a read as well).
    #[tokio::test]
    async fn a_line_that_is_not_utf8_never_ends_the_pipe() {
        let text: &[u8] = b"before\n\xff\xfe binary \xc3\n{\"after\":\"\xc3\xa9\"}\nend";
        let want = ["before", "\u{fffd}\u{fffd} binary \u{fffd}", "{\"after\":\"\u{e9}\"}", "end"];
        for at in 0..=text.len() {
            assert_eq!(lossy(&[&text[..at], &text[at..]]).await, want, "split at {at}");
        }
        let (old, failed) = lines_reference(&[text]).await;
        assert!(failed && old == ["before"], "the old reader went on: {old:?}");
    }

    /// A `next_line` cancelled mid-line (a `select!` branch that lost) loses no byte: the next
    /// call returns the whole line.
    #[tokio::test]
    async fn a_cancelled_read_keeps_the_part_of_the_line_it_read() {
        let (mut tx, rx) = tokio::io::duplex(64);
        let mut lines = LossyLines::new(tokio::io::BufReader::new(rx));
        use tokio::io::AsyncWriteExt;
        tx.write_all(b"half of ").await.unwrap();
        let cut =
            tokio::time::timeout(std::time::Duration::from_millis(50), lines.next_line()).await;
        assert!(cut.is_err(), "a line with no newline yet was returned: {cut:?}");
        tx.write_all(b"a line\n").await.unwrap();
        assert_eq!(lines.next_line().await.unwrap().as_deref(), Some("half of a line"));
        drop(tx);
        assert_eq!(lines.next_line().await.unwrap(), None);
    }
}
