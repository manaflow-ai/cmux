//! REQUEST, REPLY, ERROR and CANCEL frames on the daemon
//! (plans/cmux-next/chrome-parity/p05-ipc.md, section 3.2; p05-ipc-071).
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
//! An INPUT frame (p05-ipc-078) is the raw bytes of a `send` on a stream:
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
//! `DispatchNonBlockingEvent`). An INPUT on a stream this connection has
//! not opened is a bad message.
//!
//! Only `Command` methods answer on frames yet. A feature route or a v2
//! operation replies on its own writer, so a frame naming one gets the ERROR
//! [`METHOD_NOT_FRAMED`] and the client sends that method as a line; the
//! routes move to the method table in p05-ipc-062/063/070.

use std::borrow::Cow;
use std::collections::HashMap;
use std::collections::hash_map::Entry;
use std::fmt;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use cmux_ipc::{
    Aux, BadMessage, CallAux, CallFlags, Frame, FrameHeader, FrameKind, MAX_FRAME_PAYLOAD,
    MethodAttrs, MethodId, MethodTables, Payload, PriorityHint,
};
use serde::{Deserialize, Deserializer, de::IgnoredAny};
use serde_json::{Value, json};

use crate::SurfaceId;
use crate::diagnostics::{IpcTransport, JsonParseScope, LockCallerScope};

use super::cmd_terminal_io::{self, InputFailure};
use super::line_connection::{
    ConnectionBadMessage, FrameConnection, FrameLane, IPC_FRAMES_CAPABILITY,
};
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
}

impl FrameCall {
    fn new(stream: u16, call: CallAux) -> Self {
        FrameCall {
            stream,
            call: CallAux { flags: CallFlags::empty(), ..call },
            answered: AtomicBool::new(false),
            cancellation: Arc::default(),
        }
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
    /// A call, or an INPUT frame, on a stream this connection has not opened.
    UnknownStream { stream: u16 },
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
            CallRefusal::UnknownStream { stream } => write!(f, "call on unopened stream {stream}"),
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

/// One item of a stream's sequence.
pub(super) type StreamItem = Box<dyn FnOnce() + Send>;

/// Why a stream did not take an item. It did not run and never will.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum StreamPostRefusal {
    /// The stream's sequence holds its cap of queued items.
    #[cfg_attr(
        not(test),
        expect(dead_code, reason = "the stream sequences of p05-ipc-073 are its first producer")
    )]
    Full,
    /// The stream or its connection is ending.
    Closed,
}

/// What an open stream views: its surface, and which open of the stream id
/// it is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct StreamView {
    pub(super) surface: SurfaceId,
    /// A new value each time `attach-surface {stream}` opens the id, so a
    /// stream reopened after its stream-end, on the same surface too, is a
    /// new view.
    pub(super) open: u64,
}

/// A connection's open streams, as its INPUT frames reach them. A stream is
/// the view `attach-surface {stream}` opens (attach-streams-v1,
/// p05-ipc-074), whose items run in order on a sequence of their own
/// (p05-ipc-073).
pub(super) trait InputStreams: Send + Sync {
    /// What stream `stream` views; `None` when no open stream of this
    /// connection has the id.
    fn view(&self, stream: u16) -> Option<StreamView>;

    /// Queues `item` on stream `stream`, after the items queued before it.
    fn post(&self, stream: u16, item: StreamItem) -> Result<(), StreamPostRefusal>;

    /// Sends `event` as stream `stream`'s next item, unchanged: the event
    /// carries its own `stream` tag.
    fn send_event(&self, stream: u16, event: &Value);
}

/// The streams of a connection on this daemon today: none opens yet
/// (attach-streams, p05-ipc-074), so every INPUT frame names an unopened
/// stream, as every call on a stream does.
struct NoOpenStreams;

impl InputStreams for NoOpenStreams {
    fn view(&self, _stream: u16) -> Option<StreamView> {
        None
    }

    fn post(&self, _stream: u16, _item: StreamItem) -> Result<(), StreamPostRefusal> {
        Err(StreamPostRefusal::Closed)
    }

    fn send_event(&self, _stream: u16, _event: &Value) {}
}

/// The open stream a stream id's INPUT writes, and whether its terminal
/// ended since a write last reached it: shared by the view's queued INPUT
/// items, so an ended terminal gives one `input-failed`, not one per frame.
struct InputTarget {
    view: StreamView,
    ended: Arc<AtomicBool>,
}

/// The production frame lane: the grant is the client's recorded
/// capability; REQUEST and CANCEL frames on stream 0 and INPUT frames on an
/// open stream are routed, every other kind is a bad message. Owned by the
/// connection's reader thread.
pub(super) struct RequestFrames {
    tables: &'static MethodTables,
    /// Requests by id, from arrival until a sweep after their reply.
    in_flight: HashMap<u32, Arc<FrameCall>>,
    sweep_at: usize,
    streams: Arc<dyn InputStreams>,
    /// The streams INPUT arrived on, by id, while they stay open.
    inputs: HashMap<u16, InputTarget>,
}

impl Default for RequestFrames {
    fn default() -> Self {
        Self::with_streams(Arc::new(NoOpenStreams))
    }
}

impl RequestFrames {
    /// The lane of a connection whose open streams are `streams`.
    pub(super) fn with_streams(streams: Arc<dyn InputStreams>) -> Self {
        RequestFrames {
            tables: MethodTables::schema(),
            in_flight: HashMap::new(),
            sweep_at: SWEEP_MIN,
            streams,
            inputs: HashMap::new(),
        }
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
            (FrameKind::Input, None) => {
                let flow = match header.aux() {
                    Aux::FlowId(flow) => flow,
                    Aux::Offset(_) | Aux::SharedBufferSize(_) | Aux::Call(_) => 0,
                };
                self.input(header.stream(), flow, frame, connection)
                    .map_err(ConnectionBadMessage::Call)
            }
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
        let method = self.method(header, call).map_err(ConnectionBadMessage::Call)?;
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
        self.admit(call.request_id).map_err(ConnectionBadMessage::Call)?;
        // An admitted REQUEST is one framed request of `server-stats` `ipc`:
        // the body parses below and on its line's path count toward it.
        let _parses = JsonParseScope::enter(connection.mux.ipc_stats(), IpcTransport::Frames);
        let frame_call = Arc::new(FrameCall::new(header.stream(), call));
        let writer = connection.writer.replying_to(frame_call.clone());
        if !self.served_on_frames(method) {
            return Ok(send_not_framed(&writer, method));
        }
        names_method(body, method).map_err(ConnectionBadMessage::Call)?;
        self.in_flight.insert(call.request_id, frame_call);
        Ok(handle_connection_frame_at(
            connection.mux,
            connection.client,
            connection.transport,
            body,
            &writer,
            connection.scheduler,
            connection.arrived,
        ))
    }

    fn cancel(
        &mut self,
        header: &FrameHeader,
        call: CallAux,
        empty: bool,
    ) -> Result<(), CallRefusal> {
        let method = self.method(header, call)?;
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

    /// Queues an INPUT frame's bytes on its stream. Nothing parses them and
    /// nothing answers them; a failure is the stream's `input-failed`.
    /// `Ok(false)` closes the connection, as a line's handler does after a
    /// shutdown or a committed handoff.
    fn input(
        &mut self,
        stream: u16,
        flow: u64,
        frame: Frame,
        connection: &FrameConnection<'_>,
    ) -> Result<bool, CallRefusal> {
        let mux = connection.mux;
        // The gates of `handle_connection_frame_at`, in its order: no input
        // runs after the shutdown acknowledgement.
        if mux.daemon_shutdown_requested() || mux.daemon_handoff_committed() {
            return Ok(false);
        }
        let (remote, cause) = mux.frame_client(connection.client);
        if matches!(connection.transport, ClientTransport::Remote) || remote {
            return Err(CallRefusal::RemoteInput { stream });
        }
        let Some(view) = self.streams.view(stream) else {
            self.inputs.remove(&stream);
            return Err(CallRefusal::UnknownStream { stream });
        };
        if frame.payload().is_empty() {
            return Ok(true);
        }
        let len = frame.payload().len();
        // Refused without being written, as a line is while the handoff
        // can still fail; the connection stays open.
        if mux.daemon_handoff_in_progress() {
            self.streams.send_event(stream, &InputFailure::DaemonHandoff.event(stream, len));
            return Ok(true);
        }
        let ended = self.input_target(stream, view);
        let mux = mux.clone();
        let client = connection.client;
        let surface = view.surface;
        let streams = self.streams.clone();
        // Its lock acquisitions count under the connection's caller class
        // (`debug-daemon-locks`) and the events it sets off carry the
        // connection's cause at its class, as a request's do.
        let lock_caller = connection.writer.lock_caller.clone();
        let request_qos = mux.request_qos();
        let item: StreamItem = Box::new(move || {
            let _request_path =
                crate::request_path::RequestPathScope::enter(mux.request_path_stats());
            let _lock_caller = LockCallerScope::enter(lock_caller.get());
            let _cause = request_qos.enter(cause);
            let failure =
                match cmd_terminal_io::write_input(&mux, client, surface, frame.payload(), flow) {
                    Ok(()) => {
                        ended.store(false, Ordering::Release);
                        return;
                    }
                    Err(failure) => failure,
                };
            if failure.is_final() && ended.swap(true, Ordering::AcqRel) {
                return;
            }
            streams.send_event(stream, &failure.event(stream, len));
        });
        match self.streams.post(stream, item) {
            Ok(()) | Err(StreamPostRefusal::Closed) => {}
            Err(StreamPostRefusal::Full) => {
                self.streams.send_event(stream, &InputFailure::StreamFull.event(stream, len));
            }
        }
        Ok(true)
    }

    /// The ended flag INPUT on `stream` for `view` shares; a stream id that
    /// now names another open of the stream starts a new one.
    fn input_target(&mut self, stream: u16, view: StreamView) -> Arc<AtomicBool> {
        let fresh = || InputTarget { view, ended: Arc::new(AtomicBool::new(false)) };
        let target = match self.inputs.entry(stream) {
            Entry::Occupied(mut entry) => {
                if entry.get().view != view {
                    entry.insert(fresh());
                }
                entry.into_mut()
            }
            Entry::Vacant(entry) => entry.insert(fresh()),
        };
        target.ended.clone()
    }

    /// The header's method, refusing an unopened stream or a priority hint
    /// that differs from the table.
    fn method(
        &self,
        header: &FrameHeader,
        call: CallAux,
    ) -> Result<&'static MethodAttrs, CallRefusal> {
        // No stream opens on this daemon yet (attach-streams, p05-ipc-074):
        // every call rides the connection's control sequence.
        if header.stream() != 0 {
            return Err(CallRefusal::UnknownStream { stream: header.stream() });
        }
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

    /// Whether the method's reply goes through the responder: a JSON v12
    /// `Command` (its handler replies through `responses`).
    fn served_on_frames(&self, method: &MethodAttrs) -> bool {
        self.tables.v12(method.id).is_some()
            && method.payload == Payload::Json
            && Command::method_of_wire(method.name).is_some()
    }
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
mod tests;

#[cfg(all(test, unix))]
#[path = "input_frames_tests.rs"]
mod input_frames_tests;
