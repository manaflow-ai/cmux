//! The remote connection's message transport: the reader, writer and abort traits, the split
//! `RemoteTransport` halves, and JSON-line framing with its size bound and progress detection.

use super::*;

/// Receive complete JSON protocol messages from one transport.
///
/// Message framing belongs to the transport adapter: Unix sockets and SSH
/// relays use JSON lines, while WebSocket and future Iroh adapters can use
/// their native message boundaries.
pub trait RemoteMessageReader: Send {
    fn receive(&mut self) -> io::Result<Option<String>>;

    fn receive_with_progress(
        &mut self,
        on_progress: &mut dyn FnMut(&[u8]),
    ) -> io::Result<Option<String>> {
        let message = self.receive()?;
        if let Some(message) = message.as_deref() {
            on_progress(message.as_bytes());
        }
        Ok(message)
    }
}

fn decimal_after_prefix(bytes: &[u8], prefix: &[u8]) -> Option<u64> {
    let tail = bytes.strip_prefix(prefix)?;
    let digits = tail.iter().take_while(|byte| byte.is_ascii_digit()).count();
    if digits == 0 || !matches!(tail.get(digits), Some(b',') | Some(b'}')) {
        return None;
    }
    std::str::from_utf8(&tail[..digits]).ok()?.parse().ok()
}

pub(super) fn remote_progress_target(partial: &[u8]) -> Option<RemoteProgressTarget> {
    decimal_after_prefix(partial, br#"{"id":"#).map(RemoteProgressTarget::Request).or_else(|| {
        [
            br#"{"event":"vt-state","surface":"#.as_slice(),
            br#"{"event":"browser-state","surface":"#.as_slice(),
        ]
        .into_iter()
        .find_map(|prefix| decimal_after_prefix(partial, prefix))
        .map(RemoteProgressTarget::AttachSurface)
    })
}

/// Send complete JSON protocol messages over one transport.
pub trait RemoteMessageWriter: Send {
    fn send(&mut self, message: &str) -> io::Result<()>;
    fn close(&mut self) -> io::Result<()>;
}

/// Independently owned cancellation for a transport whose writer may be
/// blocked. Implementations must be safe to call from a different thread than
/// `RemoteMessageWriter::send`.
pub trait RemoteTransportAbort: Send + Sync {
    fn abort(&self) -> io::Result<()>;
}

/// The independently-owned read and write halves of a remote connection.
/// Split halves support process stdio and async transport pumps without
/// requiring the underlying stream to be cloneable.
pub struct RemoteTransport {
    pub(super) reader: Box<dyn RemoteMessageReader>,
    pub(super) writer: Box<dyn RemoteMessageWriter>,
    pub(super) abort: Arc<dyn RemoteTransportAbort>,
}

impl RemoteTransport {
    pub fn new(
        reader: Box<dyn RemoteMessageReader>,
        writer: Box<dyn RemoteMessageWriter>,
        abort: Arc<dyn RemoteTransportAbort>,
    ) -> Self {
        Self { reader, writer, abort }
    }

    pub fn json_lines(stream: Box<dyn transport::Stream>) -> io::Result<Self> {
        stream.set_write_timeout(Some(remote_write_timeout()))?;
        let read_half = stream.try_clone_box()?;
        let abort_stream = stream.try_clone_box()?;
        Ok(Self {
            reader: Box::new(JsonLineReader { inner: BufReader::new(read_half) }),
            writer: Box::new(JsonLineWriter { inner: stream }),
            abort: Arc::new(StreamTransportAbort { inner: abort_stream }),
        })
    }
}

struct StreamTransportAbort {
    inner: Box<dyn transport::Stream>,
}

impl RemoteTransportAbort for StreamTransportAbort {
    fn abort(&self) -> io::Result<()> {
        self.inner.shutdown(Shutdown::Both)
    }
}

pub(super) struct JsonLineReader {
    pub(super) inner: BufReader<Box<dyn transport::Stream>>,
}

pub(crate) fn read_json_line_with_progress<R: BufRead>(
    reader: &mut R,
    on_progress: &mut dyn FnMut(&[u8]),
) -> io::Result<Option<String>> {
    read_json_line_with_progress_bounded(reader, on_progress, REMOTE_SESSION_MESSAGE_MAX_BYTES)
}

pub(super) fn read_json_line_with_progress_bounded<R: BufRead>(
    reader: &mut R,
    on_progress: &mut dyn FnMut(&[u8]),
    max_message_bytes: usize,
) -> io::Result<Option<String>> {
    let mut bytes = Zeroizing::new(Vec::new());
    let mut complete_line = false;
    loop {
        let (consumed, complete) = {
            let available = reader.fill_buf()?;
            if available.is_empty() {
                break;
            }
            let complete_at = available.iter().position(|byte| *byte == b'\n');
            let payload_bytes = complete_at.unwrap_or(available.len());
            if payload_bytes > max_message_bytes.saturating_sub(bytes.len()) {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("remote session message exceeds the {max_message_bytes}-byte limit"),
                ));
            }
            let consumed = complete_at.map_or(available.len(), |index| index + 1);
            bytes.extend_from_slice(&available[..payload_bytes]);
            (consumed, complete_at.is_some())
        };
        reader.consume(consumed);
        on_progress(bytes.as_slice());
        if complete {
            complete_line = true;
            break;
        }
    }

    if bytes.is_empty() && !complete_line {
        return Ok(None);
    }
    if complete_line && bytes.last() == Some(&b'\r') {
        bytes.pop();
    }
    decode_json_line(bytes).map(Some)
}

pub(super) fn remote_reader_end_reason(result: &io::Result<Option<String>>) -> Option<String> {
    match result {
        Ok(Some(_)) => None,
        Ok(None) => Some("the daemon closed the connection".to_string()),
        Err(error) => Some(error.to_string()),
    }
}

pub(super) fn remote_reader_message_too_large(message: &mut str) -> String {
    let reason = format!(
        "remote session message exceeds the \
         {REMOTE_SESSION_MESSAGE_MAX_BYTES}-byte limit"
    );
    zeroize_string(message);
    reason
}

impl RemoteMessageReader for JsonLineReader {
    fn receive(&mut self) -> io::Result<Option<String>> {
        self.receive_with_progress(&mut |_| {})
    }

    fn receive_with_progress(
        &mut self,
        on_progress: &mut dyn FnMut(&[u8]),
    ) -> io::Result<Option<String>> {
        read_json_line_with_progress(&mut self.inner, on_progress)
    }
}

#[cfg(test)]
pub(crate) fn read_bounded_json_line(
    reader: &mut impl BufRead,
    limit: usize,
) -> io::Result<Option<String>> {
    let mut frame = Zeroizing::new(Vec::new());
    loop {
        let available = reader.fill_buf()?;
        if available.is_empty() {
            return if frame.is_empty() { Ok(None) } else { decode_json_line(frame).map(Some) };
        }
        if let Some(newline) = available.iter().position(|byte| *byte == b'\n') {
            if frame.len().saturating_add(newline) > limit {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("remote JSON line exceeds the {limit}-byte limit"),
                ));
            }
            frame.extend_from_slice(&available[..newline]);
            reader.consume(newline + 1);
            if frame.last() == Some(&b'\r') {
                frame.pop();
            }
            return decode_json_line(frame).map(Some);
        }
        if frame.len().saturating_add(available.len()) > limit {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("remote JSON line exceeds the {limit}-byte limit"),
            ));
        }
        let consumed = available.len();
        frame.extend_from_slice(available);
        reader.consume(consumed);
    }
}

fn decode_json_line(mut frame: Zeroizing<Vec<u8>>) -> io::Result<String> {
    if std::str::from_utf8(&frame).is_err() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "remote JSON line is not valid UTF-8",
        ));
    }
    let bytes = std::mem::take(&mut *frame);
    // SAFETY: the complete frame was validated as UTF-8 immediately above.
    Ok(unsafe { String::from_utf8_unchecked(bytes) })
}

pub(super) struct JsonLineWriter {
    pub(super) inner: Box<dyn transport::Stream>,
}

impl RemoteMessageWriter for JsonLineWriter {
    fn send(&mut self, message: &str) -> io::Result<()> {
        self.inner.write_all(message.as_bytes())?;
        self.inner.write_all(b"\n")
    }

    fn close(&mut self) -> io::Result<()> {
        self.inner.shutdown(Shutdown::Both)
    }
}
