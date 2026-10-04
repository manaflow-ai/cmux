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

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::time::Duration;

use serde_json::Value;

use super::remote_entry::{RemoteGate, RemotePeer};
use super::{ClientTransport, MAX_JSON_LINE_BYTES, MessageWriter, transport};
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
        // RED: the gate is not wired yet.
        let _ = frame;
        false
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

/// Reads the first line of a remote dial. A dial whose first line is an
/// admitted `fs.*` stream request is served here and `None` is returned;
/// any other dial comes back unchanged (that line first) for the line
/// connection.
pub(super) fn route_first_line(
    stream: UnixStream,
    gate: &dyn RemoteGate,
    peer: &RemotePeer,
    service: Option<&FsService>,
) -> Option<Box<dyn transport::Stream>> {
    let mut reader = BufReader::new(stream);
    let mut first = Vec::new();
    let limit = (MAX_JSON_LINE_BYTES + 2) as u64;
    if (&mut reader).take(limit).read_until(b'\n', &mut first).is_err() {
        return None;
    }
    let request = std::str::from_utf8(&first)
        .ok()
        .filter(|line| gate.admit(peer, line))
        .and_then(StreamRequest::parse);
    let mut prefix = first;
    prefix.extend_from_slice(reader.buffer());
    let stream = reader.into_inner();
    let Some(request) = request else {
        return Some(Box::new(Prefixed { prefix, at: 0, inner: stream }));
    };
    serve_stream(service, request, prefix_after_line(prefix), stream);
    None
}

/// The bytes after the first line (the start of a write stream's payload).
fn prefix_after_line(mut prefix: Vec<u8>) -> Vec<u8> {
    let end = prefix.iter().position(|byte| *byte == b'\n').map_or(prefix.len(), |at| at + 1);
    prefix.drain(..end);
    prefix
}

fn serve_stream(
    service: Option<&FsService>,
    request: Result<StreamRequest, (Value, FsError)>,
    leftover: Vec<u8>,
    stream: UnixStream,
) {
    let _ = stream.set_read_timeout(Some(STREAM_IDLE_TIMEOUT));
    let _ = stream.set_write_timeout(Some(STREAM_IDLE_TIMEOUT));
    let Ok(mut writer) = stream.try_clone() else { return };
    let mut reader = std::io::Cursor::new(leftover).chain(&stream);
    let _ = match request {
        Ok(request) => stream::serve(service, request, &mut reader, &mut writer),
        Err((id, error)) => {
            let line = stream::answer(&id, Err(error));
            serde_json::to_vec(&line).map_err(std::io::Error::other).and_then(|mut bytes| {
                bytes.push(b'\n');
                writer.write_all(&bytes)
            })
        }
    };
    let _ = stream.shutdown(std::net::Shutdown::Both);
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
