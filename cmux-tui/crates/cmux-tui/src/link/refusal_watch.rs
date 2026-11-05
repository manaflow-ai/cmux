//! A machine's link that refuses a stream sends one line before it closes,
//! in the daemon protocol's refusal shape:
//! `{"type":"refused","code":"link.refused","reason":"Token","check":"issuer",...}`.
//! The dialing side watches the far end's first bytes for that line and names
//! the reason in its own log (link.log), while passing every byte on
//! unchanged, so the app's error text carries it instead of a bare EOF. A
//! machine without the line sends nothing; a served stream starts with its
//! service's own bytes, which this never holds back.

use std::io;
use std::pin::Pin;
use std::task::{Context, Poll};

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

/// The `code` of a link refusal line.
pub(super) const REFUSED_CODE: &str = "link.refused";

/// The most of the far end's first bytes kept to find its first line.
const MAX_FIRST_LINE: usize = 2048;

/// A far end's link refusal, from the first line it sent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct LinkRefusal {
    pub reason: String,
    pub check: Option<String>,
    pub detail: Option<String>,
}

impl std::fmt::Display for LinkRefusal {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{}", self.reason)?;
        if let Some(check) = &self.check {
            write!(formatter, " ({check}")?;
            if let Some(detail) = &self.detail {
                write!(formatter, ": {detail}")?;
            }
            write!(formatter, ")")?;
        }
        Ok(())
    }
}

/// The refusal a first line states, or `None` for any other line.
pub(super) fn parse_refusal(line: &[u8]) -> Option<LinkRefusal> {
    #[derive(serde::Deserialize)]
    struct Line {
        r#type: String,
        code: String,
        reason: Option<String>,
        check: Option<String>,
        detail: Option<String>,
    }
    let line: Line = serde_json::from_slice(line).ok()?;
    (line.r#type == "refused" && line.code == REFUSED_CODE).then(|| LinkRefusal {
        reason: line.reason.unwrap_or_else(|| "refused".into()),
        check: line.check,
        detail: line.detail,
    })
}

/// Wraps the stream to a machine: reads pass through untouched, and the
/// first line read is checked once for a refusal, reported to `report`.
pub(super) struct RefusalWatch<S, F: FnMut(LinkRefusal)> {
    inner: S,
    first: Option<Vec<u8>>,
    report: F,
}

impl<S, F: FnMut(LinkRefusal)> RefusalWatch<S, F> {
    pub(super) fn new(inner: S, report: F) -> Self {
        Self { inner, first: Some(Vec::new()), report }
    }

    fn observe(&mut self, bytes: &[u8]) {
        let Some(first) = self.first.as_mut() else { return };
        // A refusal line opens with `{`; any other first byte is service data.
        if first.is_empty() && bytes.first().is_some_and(|byte| *byte != b'{') {
            self.first = None;
            return;
        }
        let room = MAX_FIRST_LINE.saturating_sub(first.len());
        first.extend_from_slice(&bytes[..bytes.len().min(room)]);
        if let Some(end) = first.iter().position(|byte| *byte == b'\n') {
            let refusal = parse_refusal(&first[..end]);
            self.first = None;
            if let Some(refusal) = refusal {
                (self.report)(refusal);
            }
        } else if first.len() >= MAX_FIRST_LINE {
            self.first = None;
        }
    }
}

impl<S: AsyncRead + Unpin, F: FnMut(LinkRefusal) + Unpin> AsyncRead for RefusalWatch<S, F> {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let this = self.get_mut();
        let before = buf.filled().len();
        let polled = Pin::new(&mut this.inner).poll_read(cx, buf);
        if let Poll::Ready(Ok(())) = polled {
            let filled = &buf.filled()[before..];
            if filled.is_empty() {
                this.first = None;
            } else {
                let read = filled.to_vec();
                this.observe(&read);
            }
        }
        polled
    }
}

impl<S: AsyncWrite + Unpin, F: FnMut(LinkRefusal) + Unpin> AsyncWrite for RefusalWatch<S, F> {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.get_mut().inner).poll_write(cx, buf)
    }

    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_flush(cx)
    }

    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().inner).poll_shutdown(cx)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};

    use super::*;

    const LINE: &[u8] = b"{\"type\":\"refused\",\"code\":\"link.refused\",\"reason\":\"Token\",\
        \"check\":\"issuer\",\"detail\":\"expected \\\"cmux:cloud:production\\\", received \
        \\\"cmux:cloud:prod\\\"\"}\n";

    async fn through(chunks: &[&[u8]]) -> (Vec<u8>, Vec<LinkRefusal>) {
        let (mut far, near) = tokio::io::duplex(64 * 1024);
        for chunk in chunks {
            far.write_all(chunk).await.unwrap();
        }
        drop(far);
        let seen = Arc::new(Mutex::new(Vec::new()));
        let sink = seen.clone();
        let mut watch = RefusalWatch::new(near, move |r| sink.lock().unwrap().push(r));
        let mut out = Vec::new();
        watch.read_to_end(&mut out).await.unwrap();
        let seen = seen.lock().unwrap().clone();
        (out, seen)
    }

    #[tokio::test]
    async fn a_refusal_line_is_reported_and_still_passed_on() {
        let (out, seen) = through(&[&LINE[..20], &LINE[20..]]).await;
        assert_eq!(out, LINE, "every byte reaches the caller unchanged");
        assert_eq!(seen.len(), 1);
        assert_eq!(seen[0].reason, "Token");
        assert_eq!(seen[0].check.as_deref(), Some("issuer"));
        let text = seen[0].to_string();
        assert!(
            text.contains("cmux:cloud:prod") && text.contains("cmux:cloud:production"),
            "{text}"
        );
    }

    #[tokio::test]
    async fn service_bytes_and_other_lines_are_never_a_refusal() {
        let (out, seen) = through(&[b"SSH-2.0-OpenSSH\r\n"]).await;
        assert_eq!(out, b"SSH-2.0-OpenSSH\r\n");
        assert!(seen.is_empty());
        let banner = b"{\"type\":\"hello\",\"code\":\"link.refused\"}\n{\"type\":\"refused\"}\n";
        let (_, seen) = through(&[banner, LINE]).await;
        assert!(seen.is_empty(), "only the first line can be a refusal");
        let (_, seen) = through(&[]).await;
        assert!(seen.is_empty(), "an old machine's bare EOF stays a bare EOF");
    }
}
