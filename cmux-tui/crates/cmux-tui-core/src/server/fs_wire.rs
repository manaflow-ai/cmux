//! Wire adapter for `fs-v1` (request file `daemon-fs-for-cloud.md`).
//!
//! Line ops: `{id, cmd: "fs.<op>", ...flat params}` answered in the v12
//! envelope (`{id, ok, data}` or `{id, ok:false, error, error_code,
//! error_details?}`). Only two transports may use them: the trusted local
//! socket (same user) and the link's remote entry, where the stamped peer
//! already passed the link's own authorization and the remote gate
//! ([`FsGate`]) admitted the frame. WebSocket clients are refused. A daemon
//! without an installed owner (every host that is not a cmux Cloud host)
//! answers `fs.unavailable` to every op.
//!
//! Byte streams (`"stream": true`) need a connection of their own: the
//! remote entry routes a dial whose FIRST line asks for one to
//! [`route_first_line`], which serves it raw and closes the dial.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::time::Duration;

use serde_json::Value;

use super::remote_entry::{RemoteGate, RemotePeer};
use super::{
    BoundedOutbound, ClientTransport, MAX_JSON_LINE_BYTES, MessageWriter, QueuedSink, RenderService,
    SinkControl, transport,
};
use crate::fs_ops::stream::{self, StreamRequest};
use crate::fs_ops::{FsError, FsService, frame_command};
use crate::mux::Mux;

/// A stream that sends nothing for this long is cancelled.
const STREAM_IDLE_TIMEOUT: Duration = Duration::from_secs(60);

/// The remote gate of the link entry: it admits a frame only when its `cmd`
/// is one of the seven `fs-v1` ops, exactly; every other frame is denied
/// as before (`remote_denied`, no detail). Whether the op is served is
/// decided after admission: a daemon that is not a Cloud host answers
/// `fs.unavailable`.
pub struct FsGate;

impl RemoteGate for FsGate {
    fn admit(&self, _peer: &RemotePeer, frame: &str) -> bool {
        frame_command(frame).is_some()
    }
}

/// Handles an `fs.*` line; `None` when the message is not one.
pub(super) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    if !message.contains("\"fs.") {
        return None;
    }
    frame_command(message)?;
    let allowed = transport_allows_fs(mux, client);
    let owner = mux.conversation_principal(client);
    let reply = answer_line(crate::fs_ops::installed(), allowed, &owner, message);
    Some(writer.send_control(&reply).is_ok())
}

fn transport_allows_fs(mux: &Mux, client: u64) -> bool {
    let state = mux.control_clients.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    state.clients.get(&client).is_some_and(|record| {
        matches!(record.transport, ClientTransport::Unix | ClientTransport::Remote)
    })
}

/// The answer to one `fs.*` request line. `owner` keys the caller's
/// listing snapshots (the connection's principal, so a later dial of the
/// same peer can page a listing).
pub(super) fn answer_line(
    service: Option<&FsService>,
    transport_allowed: bool,
    owner: &str,
    line: &str,
) -> Value {
    let Ok(Value::Object(request)) = serde_json::from_str::<Value>(line) else {
        return stream::answer(
            &Value::Null,
            Err(FsError::ParamsInvalid("not a JSON object".into())),
        );
    };
    let id = request.get("id").cloned().unwrap_or(Value::Null);
    let Some(cmd) = frame_command(line) else {
        return stream::answer(&id, Err(FsError::ParamsInvalid("unknown fs op".into())));
    };
    if !transport_allowed {
        return stream::answer(&id, Err(FsError::PermissionDenied));
    }
    let Some(service) = service else {
        return stream::answer(&id, Err(FsError::Unavailable));
    };
    if request.get("stream").and_then(Value::as_bool) == Some(true) {
        return stream::answer(
            &id,
            Err(FsError::ParamsInvalid("a byte stream needs a link dial of its own".into())),
        );
    }
    stream::answer(&id, service.call(owner, cmd, Value::Object(request)))
}

/// How long a remote dial may take to send its whole first line.
pub const FIRST_LINE_DEADLINE: Duration = Duration::from_secs(10);

/// What the remote entry needs for `fs-v1` dials: the owner (none on a host
/// that is not a Cloud host) and the first-line deadline.
#[derive(Clone, Copy)]
pub struct EntryFs {
    pub service: Option<&'static FsService>,
    pub first_line_deadline: Duration,
}

impl EntryFs {
    /// The daemon's own owner and the standard deadline.
    #[must_use]
    pub fn installed() -> Self {
        Self { service: crate::fs_ops::installed(), first_line_deadline: FIRST_LINE_DEADLINE }
    }
}

/// Reads the first line of a remote dial within `entry.first_line_deadline`
/// (a dial that is silent or too slow is closed: `None`). A dial whose first
/// line is an admitted `fs.*` stream request is registered as a remote
/// client, served here, and `None` is returned; any other dial comes back
/// unchanged (that line first) for the line connection.
pub(super) fn route_first_line(
    mux: &Arc<Mux>,
    stream: UnixStream,
    gate: &dyn RemoteGate,
    peer: &RemotePeer,
    entry: EntryFs,
) -> Option<Box<dyn transport::Stream>> {
    let (first, rest) = read_first_line(&stream, entry.first_line_deadline)?;
    let request = std::str::from_utf8(&first)
        .ok()
        .filter(|line| gate.admit(peer, line))
        .and_then(StreamRequest::parse);
    let Some(request) = request else {
        let mut prefix = first;
        prefix.extend_from_slice(&rest);
        return Some(Box::new(Prefixed { prefix, at: 0, inner: stream }));
    };
    serve_stream(mux, peer, entry.service, request, rest, stream);
    None
}

/// The first line (with its newline, or everything up to EOF or the size
/// limit) and the bytes read after it. `None` when the dial sends nothing,
/// fails, or misses the deadline.
fn read_first_line(stream: &UnixStream, deadline: Duration) -> Option<(Vec<u8>, Vec<u8>)> {
    let end = std::time::Instant::now() + deadline;
    let mut buffer = Vec::new();
    let mut chunk = vec![0u8; 64 * 1024];
    loop {
        if let Some(at) = buffer.iter().position(|byte| *byte == b'\n') {
            let rest = buffer.split_off(at + 1);
            stream.set_read_timeout(None).ok()?;
            return Some((buffer, rest));
        }
        if buffer.len() > MAX_JSON_LINE_BYTES + 1 {
            // Oversized: the line connection refuses it as before.
            stream.set_read_timeout(None).ok()?;
            return Some((buffer, Vec::new()));
        }
        let remaining = end.checked_duration_since(std::time::Instant::now())?;
        stream.set_read_timeout(Some(remaining.max(Duration::from_millis(1)))).ok()?;
        match (&mut &*stream).read(&mut chunk) {
            Ok(0) if buffer.is_empty() => return None,
            Ok(0) => {
                stream.set_read_timeout(None).ok()?;
                return Some((buffer, Vec::new()));
            }
            Ok(read) => buffer.extend_from_slice(&chunk[..read]),
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => return None,
        }
    }
}

/// Serves one byte stream as a registered remote client, so that closing
/// it (a kick, a handoff, the entry's shutdown) shuts its socket down and
/// ends the transfer at once.
fn serve_stream(
    mux: &Arc<Mux>,
    peer: &RemotePeer,
    service: Option<&FsService>,
    request: Result<StreamRequest, (Value, FsError)>,
    leftover: Vec<u8>,
    stream: UnixStream,
) {
    let (Ok(control), Ok(closer)) = (stream.try_clone(), stream.try_clone()) else { return };
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new_with_render_service(
        QueuedSink {
            outbound: outbound.clone(),
            control: Some(SinkControl::Unix(Box::new(control))),
        },
        Arc::new(RenderService::new()),
    );
    // Closing the client (a kick, a handoff, the entry's shutdown, or the
    // end of the stream) closes its queue; this thread then shuts the
    // socket down, which ends a blocked read or write of the stream at once.
    let watcher = std::thread::Builder::new().name("mux-fs-stream-close".into()).spawn(move || {
        while outbound.recv().is_some() {}
        let _ = closer.shutdown(std::net::Shutdown::Both);
    });
    if watcher.is_err() {
        return;
    }
    let client = mux.control_clients.register(ClientTransport::Remote, writer.clone());
    mux.bind_conversation_principal(client, super::remote_entry::remote_principal(peer));
    if writer.is_open() {
        let _ = stream.set_read_timeout(Some(STREAM_IDLE_TIMEOUT));
        let _ = stream.set_write_timeout(Some(STREAM_IDLE_TIMEOUT));
        if let Ok(mut out) = stream.try_clone() {
            let mut reader = std::io::Cursor::new(leftover).chain(&stream);
            let _ = match request {
                Ok(request) => stream::serve(service, request, &mut reader, &mut out),
                Err((id, error)) => {
                    let line = stream::answer(&id, Err(error));
                    serde_json::to_vec(&line).map_err(std::io::Error::other).and_then(
                        |mut bytes| {
                            bytes.push(b'\n');
                            out.write_all(&bytes)
                        },
                    )
                }
            };
        }
    }
    super::disconnect_client(mux, client, false);
    let _ = stream.shutdown(std::net::Shutdown::Both);
}

/// Closes every remote client (line dials and byte streams): the entry is
/// shutting down, so their sockets are shut down and their transfers end.
pub(super) fn close_remote_clients(mux: &Arc<Mux>) {
    let remote: Vec<u64> = {
        let state =
            mux.control_clients.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        state
            .clients
            .iter()
            .filter(|(_, record)| matches!(record.transport, ClientTransport::Remote))
            .map(|(client, _)| *client)
            .collect()
    };
    for client in remote {
        super::disconnect_client(mux, client, false);
    }
}

/// A stream whose first bytes were already read: they are replayed before
/// the socket. Its clones (the line connection's write half) never read.
struct Prefixed {
    prefix: Vec<u8>,
    at: usize,
    inner: UnixStream,
}

impl Read for Prefixed {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        if self.at < self.prefix.len() {
            let count = buffer.len().min(self.prefix.len() - self.at);
            buffer[..count].copy_from_slice(&self.prefix[self.at..self.at + count]);
            self.at += count;
            return Ok(count);
        }
        self.inner.read(buffer)
    }
}

impl Write for Prefixed {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.inner.write(bytes)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}

impl transport::Stream for Prefixed {
    fn try_clone_box(&self) -> std::io::Result<Box<dyn transport::Stream>> {
        Ok(Box::new(self.inner.try_clone()?))
    }

    fn set_read_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.inner.set_read_timeout(timeout)
    }

    fn set_write_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.inner.set_write_timeout(timeout)
    }

    fn shutdown(&self, how: std::net::Shutdown) -> std::io::Result<()> {
        self.inner.shutdown(how)
    }
}

#[cfg(test)]
#[path = "fs_wire_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "fs_stream_tests.rs"]
mod stream_tests;
