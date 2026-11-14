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
mod tests;
