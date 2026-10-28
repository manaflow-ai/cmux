//! REQUEST, REPLY, ERROR and CANCEL frames on the daemon
//! (plans/cmux-next/chrome-parity/p05-ipc.md, section 3.2).
//!
//! A REQUEST frame carries the JSON body its line would carry; its header
//! names the method (`family << 8 | ordinal`, cmux-ipc `MethodTables`) and a
//! request id. The header alone routes it: the method must be in this
//! daemon's table, the priority hint must equal the table's, the flags must
//! fit the method. Anything else is a bad message that closes the connection,
//! as a Mojo message that fails validation is never dispatched and raises a
//! connection error (chromium mojo/public/cpp/bindings/lib/
//! interface_endpoint_client.cc, `HandleValidatedMessage`).
//!
//! The body then takes its line's path, so it runs the same handler and its
//! reply is the same JSON. The writer it runs with answers the frame
//! (`MessageWriter::replying_to`, Mojo's responder): the reply leaves as one
//! REPLY frame, or ERROR when `ok` is false, with the request's call fields,
//! in the control FIFO behind every event the request emitted. A request id
//! is in flight until that frame; reusing it before then is a bad message.
//!
//! A CANCEL frame fires the request's cancellation: a waiting handler
//! (`wait-for`) ends with an ERROR reply, and a request still queued is
//! answered without running. A CANCEL for an id that is not in flight lost a
//! race with its reply and is dropped.
//!
//! A REQUEST or INPUT frame on stream S != 0 goes to the stream an opener
//! REQUEST on S announced (`attach-surface`), queued until the opener's
//! reply (server/pending_streams.rs); a frame naming a stream
//! that was never announced is a bad message.
//!
//! Frames are granted only at this daemon's API revision (capabilities.rs,
//! `still_allowed`, checked again before every frame), so a body is never
//! upgraded from another revision (`MessageWriter::upgrade_request`). While a
//! daemon handoff is pending, a REQUEST gets its line's refusal as its ERROR
//! frame (server/pending_handoff.rs).
//!
//! An INPUT frame is the raw bytes of a `send` on a stream:
//! its header names the stream and the key press's flow id, its payload is
//! the bytes. It is never parsed and never answered. It runs on the stream's
//! sequence, after the stream's earlier items, and writes its surface's
//! terminal the way `send` does, under the connection's cause. A failure is
//! the stream's event `input-failed{stream, reason, bytes}`; while the
//! terminal stays ended, later INPUT on the same open of the stream fails
//! with no second event, and a write that reaches a terminal again (a
//! respawned one) or a new open of the stream reports the next end again.
//! INPUT obeys a line's gates: after a shutdown or a committed handoff it
//! closes the connection, during a pending handoff it is refused with
//! `daemon_handoff`, and from a remote-relay client it is a bad message
//! (the relay denies by default). This is Chrome's
//! `WidgetInputHandler`: input is a one-way message on the widget's own
//! associated pipe, ordered with the widget's other messages, with no reply
//! (chromium third_party/blink/public/mojom/input/input_handler.mojom,
//! `DispatchNonBlockingEvent`).
//!
//! Only `Command` methods answer on frames yet. A feature route or a v2
//! operation replies on its own writer, so a frame naming one gets the ERROR
//! [`METHOD_NOT_FRAMED`]; the routes move to the method table in
//! A client does not find these by trial, which would
//! run a refused request after the ones written behind it: `identify
//! {revisions}` lists [`framed_method_ids`] and the [`sdk_schema_digest`]
//! their ids and priorities come from, and a client frames only those
//! methods, and only when its own table came from the same schema. Mojo
//! dispatches by ordinal only between ends built from one interface
//! definition (mojo/public/tools/bindings/README.md, "Versioning").

use std::borrow::Cow;
use std::collections::HashMap;
use std::fmt;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LazyLock};

use cmux_ipc::{
    Aux, BadMessage, CallAux, CallFlags, Frame, FrameHeader, FrameKind, MAX_FRAME_PAYLOAD,
    MethodAttrs, MethodId, MethodTables, Payload, PriorityHint,
};
use serde::{Deserialize, Deserializer, de::IgnoredAny};
use serde_json::json;

use crate::diagnostics::{IpcTransport, JsonParseScope};

use super::cmd_terminal_io::InputFailure;
use super::line_connection::{
    ConnectionBadMessage, FrameConnection, FrameLane, IPC_FRAMES_CAPABILITY,
};
use super::pending_streams::{ClientStreams, RequestLane, StreamEndpoint, post_request};
use super::{
    ClientTransport, Command, ConnectionCancellation, MessageWriter, Mux,
    handle_connection_frame_at,
};

/// The `error_code` of the ERROR reply to a method that answers only lines.
pub(super) const METHOD_NOT_FRAMED: &str = "method_not_framed";

/// The in-flight table is swept of answered requests when it reaches this
/// size, then at twice what the sweep left.
const SWEEP_MIN: usize = 64;

/// One REQUEST frame from its arrival to its reply.
pub(super) struct FrameCall {
    stream: u16,
    /// The request's call fields, echoed by its reply (flags cleared).
    call: CallAux,
    answered: AtomicBool,
    cancellation: Arc<ConnectionCancellation>,
    /// The stream this request opens (an opener on stream S): its reply
    /// binds or ends it.
    opens: Option<Arc<StreamEndpoint>>,
}

impl FrameCall {
    /// A request that opens no stream.
    pub(super) fn new(stream: u16, call: CallAux) -> Self {
        Self::opening(stream, call, None)
    }

    /// A request that opens `opens` when it is an opener.
    fn opening(stream: u16, call: CallAux, opens: Option<Arc<StreamEndpoint>>) -> Self {
        FrameCall {
            stream,
            call: CallAux { flags: CallFlags::empty(), ..call },
            answered: AtomicBool::new(false),
            cancellation: Arc::default(),
            opens,
        }
    }

    /// Answered by its stream's `stream-end` (it never ran): no reply
    /// frame, and its id is free again.
    pub(super) fn abandon(&self) {
        self.answered.store(true, Ordering::Release);
    }

    /// The stream this request opens, for its handler to name the surface.
    pub(super) fn opens(&self) -> Option<&Arc<StreamEndpoint>> {
        self.opens.as_ref()
    }

    /// Queues its reply with `send`. An opener that failed ends its stream
    /// first, so `stream-end` precedes the error; one that succeeded binds
    /// its stream with the reply, so the items queued on it follow the
    /// reply. An opener whose stream ended before its answer sends
    /// `refuse` instead (server/pending_streams.rs).
    pub(super) fn send_reply_with(
        &self,
        ok: bool,
        send: impl FnOnce() -> std::io::Result<()>,
        refuse: impl FnOnce() -> std::io::Result<()>,
    ) -> std::io::Result<()> {
        let Some(stream) = &self.opens else { return send() };
        if !ok {
            stream.open_failed();
            return send();
        }
        stream.bind_with(send).unwrap_or_else(refuse)
    }

    /// Whether its reply was sent (its id is free again).
    pub(super) fn is_answered(&self) -> bool {
        self.answered.load(Ordering::Acquire)
    }

    /// True once: for the reply that answers it.
    pub(super) fn claim_reply(&self) -> bool {
        !self.answered.swap(true, Ordering::AcqRel)
    }

    /// Fired by its CANCEL frame.
    pub(super) fn cancellation(&self) -> &Arc<ConnectionCancellation> {
        &self.cancellation
    }

    /// The header of its reply: REPLY, or ERROR when `ok` is false.
    pub(super) fn reply_header(&self, ok: bool, len: usize) -> Result<FrameHeader, BadMessage> {
        let kind = if ok { FrameKind::Reply } else { FrameKind::Error };
        let len = u32::try_from(len)
            .map_err(|_| BadMessage::Oversize { len: u32::MAX, max: MAX_FRAME_PAYLOAD })?;
        FrameHeader::new(kind, self.stream, len, Aux::Call(self.call))
    }
}

/// Why a REQUEST or CANCEL frame closed its connection.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum CallRefusal {
    /// A call on a stream this connection never announced.
    UnknownStream { stream: u16 },
    /// A control method on a stream: only stream-scoped methods and
    /// openers name one.
    NotStreamScoped { stream: u16, method_id: u16 },
    /// A method id this daemon's table does not have.
    UnknownMethod { method_id: u16 },
    /// A priority hint that differs from the method's table priority.
    PriorityMismatch { method_id: u16, hint: PriorityHint, table: PriorityHint },
    /// Flags the method does not take (descriptors, a chunked request, a
    /// payload kind or urgency the table does not give it).
    FlagsRefused { method_id: u16, flags: u8 },
    /// A body larger than the method's `max_bytes`.
    Oversize { method_id: u16, len: usize, max: u32 },
    /// A body that does not name the header's method.
    MethodMismatch { method_id: u16 },
    /// A request id still in flight.
    DuplicateRequest { request_id: u32 },
    /// A CANCEL whose method is not its in-flight request's.
    CancelMismatch { request_id: u32, method_id: u16 },
    /// A CANCEL with a payload.
    CancelPayload { request_id: u32 },
    /// An INPUT frame from a remote-relay client, which writes no terminal.
    RemoteInput { stream: u16 },
}

impl CallRefusal {
    /// The `bad_message` reason, stable for logs and counters.
    pub(super) fn reason(&self) -> &'static str {
        match self {
            CallRefusal::UnknownStream { .. } => "unknown_stream",
            CallRefusal::NotStreamScoped { .. } => "not_stream_scoped",
            CallRefusal::UnknownMethod { .. } => "unknown_method",
            CallRefusal::PriorityMismatch { .. } => "priority_mismatch",
            CallRefusal::FlagsRefused { .. } => "flags_refused",
            CallRefusal::Oversize { .. } => "oversize_request",
            CallRefusal::MethodMismatch { .. } => "method_mismatch",
            CallRefusal::DuplicateRequest { .. } => "duplicate_request",
            CallRefusal::CancelMismatch { .. } => "cancel_mismatch",
            CallRefusal::CancelPayload { .. } => "cancel_payload",
            CallRefusal::RemoteInput { .. } => "remote_input",
        }
    }
}

impl fmt::Display for CallRefusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CallRefusal::UnknownStream { stream } => {
                write!(f, "call on never-announced stream {stream}")
            }
            CallRefusal::NotStreamScoped { stream, method_id } => {
                write!(f, "method {method_id:#06x} is not stream-scoped; it named stream {stream}")
            }
            CallRefusal::UnknownMethod { method_id } => {
                write!(f, "unknown method {method_id:#06x}")
            }
            CallRefusal::PriorityMismatch { method_id, hint, table } => write!(
                f,
                "method {method_id:#06x} hints priority {}, its table says {}",
                hint.schema_name(),
                table.schema_name()
            ),
            CallRefusal::FlagsRefused { method_id, flags } => {
                write!(f, "method {method_id:#06x} does not take flags {flags:#010b}")
            }
            CallRefusal::Oversize { method_id, len, max } => {
                write!(f, "method {method_id:#06x} body of {len} bytes exceeds {max}")
            }
            CallRefusal::MethodMismatch { method_id } => {
                write!(f, "body does not name method {method_id:#06x}")
            }
            CallRefusal::DuplicateRequest { request_id } => {
                write!(f, "request id {request_id} is already in flight")
            }
            CallRefusal::CancelMismatch { request_id, method_id } => write!(
                f,
                "cancel of request {request_id} names method {method_id:#06x}, not its own"
            ),
            CallRefusal::CancelPayload { request_id } => {
                write!(f, "cancel of request {request_id} has a payload")
            }
            CallRefusal::RemoteInput { stream } => {
                write!(f, "INPUT on stream {stream} from a remote-relay client")
            }
        }
    }
}

/// The production frame lane: the grant is the client's recorded
/// capability; REQUEST and CANCEL frames are routed, and INPUT frames on a
/// stream; every other kind is a bad message. Owned by the connection's
/// reader thread.
pub(super) struct RequestFrames {
    tables: &'static MethodTables,
    /// Requests by id, from arrival until a sweep after their reply.
    in_flight: HashMap<u32, Arc<FrameCall>>,
    sweep_at: usize,
    /// The streams the client announced.
    streams: ClientStreams,
}

impl Default for RequestFrames {
    fn default() -> Self {
        RequestFrames {
            tables: MethodTables::schema(),
            in_flight: HashMap::new(),
            sweep_at: SWEEP_MIN,
            streams: ClientStreams::default(),
        }
    }
}

#[cfg(test)]
impl RequestFrames {
    /// A lane whose streams tell `probe` when an opener targets one and
    /// when an item is posted.
    pub(super) fn with_stream_probe(probe: Arc<dyn super::pending_streams::StreamProbe>) -> Self {
        let mut frames = RequestFrames::default();
        frames.streams.probe = Some(probe);
        frames
    }
}

impl FrameLane for RequestFrames {
    fn granted(&self, mux: &Mux, client: u64) -> bool {
        mux.control_clients.supports_capability(client, IPC_FRAMES_CAPABILITY)
    }

    fn route(
        &mut self,
        frame: Frame,
        connection: &FrameConnection<'_>,
    ) -> Result<bool, ConnectionBadMessage> {
        let header = *frame.header();
        match (header.kind(), header.call()) {
            (FrameKind::Request, Some(call)) => {
                self.request(&header, call, frame.payload(), connection)
            }
            (FrameKind::Cancel, Some(call)) => self
                .cancel(&header, call, frame.payload().is_empty())
                .map(|()| true)
                .map_err(ConnectionBadMessage::Call),
            (FrameKind::Input, None) if header.stream() != 0 => self.input(frame, connection),
            (kind, _) => Err(ConnectionBadMessage::UnroutedKind { kind }),
        }
    }
}

impl RequestFrames {
    fn request(
        &mut self,
        header: &FrameHeader,
        call: CallAux,
        payload: &[u8],
        connection: &FrameConnection<'_>,
    ) -> Result<bool, ConnectionBadMessage> {
        let method = self.method(call).map_err(ConnectionBadMessage::Call)?;
        request_flags(method, call.flags).map_err(ConnectionBadMessage::Call)?;
        if let Some(max) = method.max_bytes
            && payload.len() > usize::try_from(max).unwrap_or(usize::MAX)
        {
            let len = payload.len();
            return Err(ConnectionBadMessage::Call(CallRefusal::Oversize {
                method_id: call.method_id,
                len,
                max,
            }));
        }
        let body = std::str::from_utf8(payload).map_err(|error| {
            ConnectionBadMessage::Wire(BadMessage::InvalidUtf8 { valid_up_to: error.valid_up_to() })
        })?;
        let stream = header.stream();
        let lane = self.streams.request_lane(stream, method).map_err(ConnectionBadMessage::Call)?;
        self.admit(call.request_id).map_err(ConnectionBadMessage::Call)?;
        // An admitted REQUEST is one framed request of `server-stats` `ipc`:
        // the body parses below and on its line's path count toward it.
        let _parses = JsonParseScope::enter(connection.mux.ipc_stats(), IpcTransport::Frames);
        if !served_on_frames(self.tables, method) {
            let call = Arc::new(FrameCall::new(stream, call));
            return Ok(send_not_framed(&connection.writer.replying_to(call), method));
        }
        names_method(body, method).map_err(ConnectionBadMessage::Call)?;
        let opens =
            matches!(lane, RequestLane::Open).then(|| self.streams.announce(stream, connection));
        let frame_call = Arc::new(FrameCall::opening(stream, call, opens));
        let writer = connection.writer.replying_to(frame_call.clone());
        self.in_flight.insert(call.request_id, frame_call.clone());
        match lane {
            RequestLane::InUse => Ok(send_stream_in_use(&writer, stream)),
            RequestLane::Stream(endpoint) => {
                post_request(&endpoint, body, frame_call, connection);
                Ok(true)
            }
            RequestLane::Control | RequestLane::Open => Ok(handle_connection_frame_at(
                connection.mux,
                connection.client,
                connection.transport,
                body,
                &writer,
                connection.scheduler,
                connection.arrived,
            )),
        }
    }

    /// Queues an INPUT frame's bytes on its stream, behind the line's gates.
    /// Nothing parses them and nothing answers them; a failure is the
    /// stream's `input-failed`. `Ok(false)` closes the connection, as a
    /// line's handler does after a shutdown or a committed handoff.
    fn input(
        &mut self,
        frame: Frame,
        connection: &FrameConnection<'_>,
    ) -> Result<bool, ConnectionBadMessage> {
        let mux = connection.mux;
        // The gates of `handle_connection_frame_at`, in its order: no input
        // runs after the shutdown acknowledgement.
        if mux.daemon_shutdown_requested() || mux.daemon_handoff_committed() {
            return Ok(false);
        }
        let stream = frame.header().stream();
        let (remote, cause) = mux.frame_client(connection.client);
        if matches!(connection.transport, ClientTransport::Remote) || remote {
            return Err(ConnectionBadMessage::Call(CallRefusal::RemoteInput { stream }));
        }
        // Refused without being written, as a line is while the handoff can
        // still fail; the connection stays open.
        let refused = mux.daemon_handoff_in_progress().then_some(InputFailure::DaemonHandoff);
        self.streams.input(frame, cause, refused).map(|()| true)
    }

    fn cancel(
        &mut self,
        header: &FrameHeader,
        call: CallAux,
        empty: bool,
    ) -> Result<(), CallRefusal> {
        let method = self.method(call)?;
        self.streams.check_cancel(header.stream())?;
        let request_id = call.request_id;
        if !empty {
            return Err(CallRefusal::CancelPayload { request_id });
        }
        if call.flags.bits() & !CallFlags::FLOW.bits() != 0 {
            return Err(CallRefusal::FlagsRefused {
                method_id: call.method_id,
                flags: call.flags.bits(),
            });
        }
        let Some(target) = self.in_flight.get(&request_id).filter(|target| !target.is_answered())
        else {
            return Ok(());
        };
        if target.call.method_id != method.id.raw() {
            return Err(CallRefusal::CancelMismatch { request_id, method_id: call.method_id });
        }
        target.cancellation.cancel();
        Ok(())
    }

    /// The call's method, refusing a priority hint that differs from the
    /// table.
    fn method(&self, call: CallAux) -> Result<&'static MethodAttrs, CallRefusal> {
        let method_id = call.method_id;
        let method = self
            .tables
            .method(MethodId::new(method_id))
            .ok_or(CallRefusal::UnknownMethod { method_id })?;
        if call.priority != method.priority {
            return Err(CallRefusal::PriorityMismatch {
                method_id,
                hint: call.priority,
                table: method.priority,
            });
        }
        Ok(method)
    }

    /// Refuses an id still in flight; sweeps answered requests in batches,
    /// so the table stays proportional to what is in flight.
    fn admit(&mut self, request_id: u32) -> Result<(), CallRefusal> {
        if self.in_flight.get(&request_id).is_some_and(|call| !call.is_answered()) {
            return Err(CallRefusal::DuplicateRequest { request_id });
        }
        if self.in_flight.len() >= self.sweep_at {
            self.in_flight.retain(|_, call| !call.is_answered());
            self.sweep_at = SWEEP_MIN.max(self.in_flight.len().saturating_mul(2));
        }
        Ok(())
    }
}

/// Whether the method's reply goes through the responder: a JSON v12
/// `Command` (its handler replies through `responses`).
fn served_on_frames(tables: &MethodTables, method: &MethodAttrs) -> bool {
    tables.v12(method.id).is_some()
        && method.payload == Payload::Json
        && Command::method_of_wire(method.name).is_some()
}

/// The v12 method ids this daemon answers on REQUEST frames, in id order
/// (`identify {revisions}` `framed_methods`).
pub(super) fn framed_method_ids() -> &'static [u16] {
    static IDS: LazyLock<Vec<u16>> = LazyLock::new(|| {
        let tables = MethodTables::schema();
        tables
            .v12_families()
            .flat_map(|family| family.iter())
            .filter(|method| served_on_frames(tables, method))
            .map(|method| method.id.raw())
            .collect()
    });
    &IDS
}

/// The digest of the schema this daemon's method tables came from, as 16
/// lowercase hex digits (`identify {revisions}` `sdk_schema_digest`; the
/// app's `WireSchemaIdentity.sdkSchemaDigest`).
pub(super) fn sdk_schema_digest() -> String {
    format!("{:016x}", cmux_ipc::SCHEMA_IDENTITY.sdk_schema_digest)
}

/// The flags a REQUEST of `method` may carry.
fn request_flags(method: &MethodAttrs, flags: CallFlags) -> Result<(), CallRefusal> {
    let binary = matches!(method.payload, Payload::Binary { .. });
    let refused = flags.contains(CallFlags::FDS)
        || flags.contains(CallFlags::MORE)
        || flags.contains(CallFlags::BINARY) != binary
        || (flags.contains(CallFlags::URGENT) && !method.urgent);
    if refused {
        return Err(CallRefusal::FlagsRefused { method_id: method.id.raw(), flags: flags.bits() });
    }
    Ok(())
}

/// The members of a body that name its method.
#[derive(Deserialize)]
struct BodyHead<'a> {
    #[serde(default, borrow)]
    cmd: Option<Cow<'a, str>>,
    /// Present (even `null`): the line path would read it as a v2 envelope.
    #[serde(default, deserialize_with = "member_present")]
    protocol: bool,
}

fn member_present<'de, D: Deserializer<'de>>(deserializer: D) -> Result<bool, D::Error> {
    IgnoredAny::deserialize(deserializer).map(|_| true)
}

/// The body must be the v12 line of the header's method, so the handler that
/// runs is the one the header was checked for.
fn names_method(body: &str, method: &MethodAttrs) -> Result<(), CallRefusal> {
    match crate::line_parses::parse::<BodyHead<'_>>(body) {
        Ok(BodyHead { cmd: Some(cmd), protocol: false }) if cmd == method.name => Ok(()),
        _ => Err(CallRefusal::MethodMismatch { method_id: method.id.raw() }),
    }
}

/// An opener naming a stream that is still live: the client reused its id
/// before the stream's `stream-end`.
fn send_stream_in_use(writer: &MessageWriter, stream: u16) -> bool {
    let reply = json!({
        "ok": false,
        "error": format!("stream {stream} is open"),
        "error_code": "stream_in_use",
    });
    writer.send_reply(&reply).is_ok()
}

fn send_not_framed(writer: &MessageWriter, method: &MethodAttrs) -> bool {
    let reply = json!({
        "ok": false,
        "error": format!("{} is not served on frames yet; send it as a line", method.name),
        "error_code": METHOD_NOT_FRAMED,
    });
    writer.send_reply(&reply).is_ok()
}

#[cfg(all(test, unix))]
#[path = "frame_dispatch_tests.rs"]
pub(super) mod tests;

#[cfg(all(test, unix))]
#[path = "input_frames_tests.rs"]
mod input_frames_tests;
