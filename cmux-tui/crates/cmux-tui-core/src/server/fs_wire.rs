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

use serde::Deserialize;
use serde_json::{Map, Value, json};

use super::remote_entry::{RemoteGate, RemotePeer};
use super::routes::{Route, RouteLine, RouteName};
#[cfg(test)]
use super::transport;
use super::{
    BoundedOutbound, ClientTransport, FrameStage, MAX_JSON_LINE_BYTES, MessageWriter, QueuedSink,
    RenderService, SinkControl,
};
use crate::fs_ops::stream::{self, StreamRequest};
use crate::fs_ops::{FsError, FsService, frame_command, object_command};
use crate::mux::Mux;
use crate::supervised::{self, Fatal, ShutdownBehavior};

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

/// The `cmd` names this module answers (server/routes.rs).
pub(in crate::server) const ROUTES: &[Route] = &[Route {
    names: &[RouteName::OneOf(&crate::fs_ops::FS_COMMANDS)],
    stage: FrameStage::Fs,
    entry: handle,
}];

/// True when `cmd` names one of the seven `fs-v1` ops: the lines
/// [`handle`] answers. The remote relay finds its fs lines by it, as the
/// connection's dispatch finds them by [`ROUTES`].
pub(super) fn is_fs_op(cmd: &str) -> bool {
    crate::fs_ops::FS_COMMANDS.contains(&cmd)
}

/// Answers a line whose `cmd` is an `fs-v1` op (found by name: the route,
/// or the remote relay through [`is_fs_op`]). The line's one decode is its
/// `Value`. `None` for a line with no `Value` (a number past `f64`, a lone
/// surrogate) or one with a `protocol` member (not an fs frame,
/// [`object_command`]); the caller's next handler answers it.
pub(super) fn handle(line: &RouteLine<'_>) -> Option<bool> {
    let RouteLine { mux, client, message, writer, .. } = *line;
    let Ok(Value::Object(request)) = crate::line_parses::parse::<Value>(message) else {
        return None;
    };
    object_command(&request)?;
    // The transport first, then the principal of this frame: a remote client
    // needs a bound peer whose install may keep its streams (a revoke or the
    // 72 h limit refuses it before its stream closes). Either one missing:
    // permission denied.
    let owner = transport_allows_fs(mux, client)
        .then(|| mux.frame_principal(client))
        .flatten()
        .map(super::remote_relay::Principal::participant);
    let reply = answer_request(
        crate::fs_ops::installed(),
        owner.is_some(),
        owner.as_deref().unwrap_or(super::remote_relay::NO_PRINCIPAL),
        request,
    );
    Some(writer.send_control(&reply).is_ok())
}

/// True for a trusted local or a remote-entry connection. A poisoned
/// registry lock refuses (fail closed).
fn transport_allows_fs(mux: &Mux, client: u64) -> bool {
    mux.control_clients.transport_of(client).is_some_and(|transport| {
        matches!(transport, ClientTransport::Unix | ClientTransport::Remote)
    })
}

/// The answer to one `fs.*` request line. `owner` keys the caller's
/// listing snapshots (the connection's principal, so a later dial of the
/// same peer can page a listing).
#[cfg(test)]
pub(super) fn answer_line(
    service: Option<&FsService>,
    transport_allowed: bool,
    owner: &str,
    line: &str,
) -> Value {
    let Ok(Value::Object(request)) = crate::line_parses::parse::<Value>(line) else {
        return stream::answer(
            &Value::Null,
            Err(FsError::ParamsInvalid("not a JSON object".into())),
        );
    };
    if object_command(&request).is_none() {
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        return stream::answer(&id, Err(FsError::ParamsInvalid("unknown fs op".into())));
    }
    answer_request(service, transport_allowed, owner, request)
}

/// The answer to a decoded `fs.*` request (its op is named by `cmd`).
fn answer_request(
    service: Option<&FsService>,
    transport_allowed: bool,
    owner: &str,
    request: Map<String, Value>,
) -> Value {
    let id = request.get("id").cloned().unwrap_or(Value::Null);
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
    stream::answer(&id, answer_fs_request(service, owner, Value::Object(request)))
}

/// Runs one `fs-v1` line op on `service`: `request` is the whole frame
/// (`{id?, cmd: "fs.<op>", ...flat params}`), decoded by its `cmd`. `owner`
/// keys the caller's listing snapshots. `answer_request` calls it after its
/// transport and stream checks; a test that serves a real [`FsService`] on
/// a socket of its own calls it the same way.
pub fn answer_fs_request(
    service: &FsService,
    owner: &str,
    request: Value,
) -> Result<Value, FsError> {
    serde_json::from_value::<Command>(request)
        .map_err(|error| FsError::ParamsInvalid(error.to_string()))?
        .run(service, owner)
}

/// The seven `fs-v1` line ops, decoded by their `cmd` into the params of
/// `fs_ops`. Fields an op does not read (`id`, `stream`) are ignored.
/// spec/sdk-schema.json types each op (check-sdk-schema.py compares the
/// fields).
#[derive(Deserialize)]
#[serde(tag = "cmd")]
enum Command {
    #[serde(rename = "fs.stat")]
    Stat(crate::fs_ops::ops::PathParams),
    #[serde(rename = "fs.list")]
    List(crate::fs_ops::ops::ListParams),
    #[serde(rename = "fs.read")]
    Read(crate::fs_ops::ops::ReadParams),
    #[serde(rename = "fs.write")]
    Write(crate::fs_ops::ops::WriteParams),
    #[serde(rename = "fs.mkdir")]
    Mkdir(crate::fs_ops::ops::NameParams),
    #[serde(rename = "fs.rename")]
    Rename(crate::fs_ops::ops::NameParams),
    #[serde(rename = "fs.delete")]
    Delete(crate::fs_ops::ops::DeleteParams),
}

impl Command {
    /// Runs the op; `owner` keys the caller's listing snapshots.
    fn run(self, service: &FsService, owner: &str) -> Result<Value, FsError> {
        match self {
            Self::Stat(params) => crate::fs_ops::ops::to_value(&service.stat(&params.path)?),
            Self::List(params) => service.list(owner, params),
            Self::Read(params) => service.read(params),
            Self::Write(params) => service.write(params),
            Self::Mkdir(params) => {
                Ok(json!({ "entry": service.mkdir(&params.path, &params.name)? }))
            }
            Self::Rename(params) => {
                Ok(json!({ "entry": service.rename(&params.path, &params.name)? }))
            }
            Self::Delete(params) => service.delete(params),
        }
    }
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
) -> Option<LineDial> {
    let (first, rest) = read_first_line(&stream, entry.first_line_deadline)?;
    let request = std::str::from_utf8(&first)
        .ok()
        .filter(|line| gate.admit(peer, line))
        .and_then(StreamRequest::parse);
    let Some(request) = request else {
        let mut prefix = first;
        prefix.extend_from_slice(&rest);
        return Some(LineDial { stream, prefix });
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
            Ok(read) => buffer.extend_from_slice(chunk.get(..read)?),
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
    let watcher = supervised::spawn_raisable(
        "mux-fs-stream-close",
        crate::thread_qos::ThreadType::Utility.qos(),
        Fatal,
        ShutdownBehavior::Continue,
        move || {
            // mq14-allow: the close watcher waits for its own queue (a checked wait).
            while outbound.recv().is_some() {}
            let _ = closer.shutdown(std::net::Shutdown::Both);
        },
    );
    if watcher.is_err() {
        return;
    }
    let client = mux.control_clients.register(ClientTransport::Remote, writer.clone());
    // The stamped peer, as for a line dial: a revoked install (or one past
    // its offline limit) gets no stream, and a revocation closes this one.
    let bound = writer.is_open() && mux.bind_remote_peer(client, peer).is_ok();
    if bound {
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
    // A refused registration has no record to disconnect: drop the peer
    // binding (and stop the watcher) here too.
    mux.unbind_conversation_principal(client);
    writer.close();
    let _ = stream.shutdown(std::net::Shutdown::Both);
}

/// Closes every remote client (line dials and byte streams): the entry is
/// shutting down, so their sockets are shut down and their transfers end.
pub(super) fn close_remote_clients(mux: &Arc<Mux>) {
    let remote: Vec<u64> = {
        // Poison recovery: this list only closes streams; a stale id closes nothing.
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
/// A dial for the line connection: its socket, and the bytes already read
/// from it (its first line and what came behind it), which come first.
pub(super) struct LineDial {
    pub(super) stream: UnixStream,
    pub(super) prefix: Vec<u8>,
}

impl LineDial {
    /// The dial as one stream that reads the prefix, then the socket.
    #[cfg(test)]
    pub(super) fn into_stream(self) -> Box<dyn transport::Stream> {
        Box::new(Prefixed { prefix: self.prefix, at: 0, inner: self.stream })
    }
}

#[cfg(test)]
struct Prefixed {
    prefix: Vec<u8>,
    at: usize,
    inner: UnixStream,
}

#[cfg(test)]
impl Read for Prefixed {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        if let Some(rest) = self.prefix.get(self.at..).filter(|rest| !rest.is_empty()) {
            let count = buffer.len().min(rest.len());
            for (slot, byte) in buffer.iter_mut().zip(rest) {
                *slot = *byte;
            }
            self.at += count;
            return Ok(count);
        }
        self.inner.read(buffer)
    }
}

#[cfg(test)]
impl Write for Prefixed {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.inner.write(bytes)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}

#[cfg(test)]
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
