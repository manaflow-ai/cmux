//! Pending streams (p05-ipc-087; plans/cmux-next/chrome-parity/p05-ipc.md,
//! sections 1.2 and 3.2): a client may send a stream's INPUT and requests
//! right behind the request that opens it, without waiting for its reply.
//!
//! The reader marks stream S announced when it routes an opener REQUEST
//! (`attach-surface`) whose header names S; it reads no payload for that.
//! Until the opener's reply the stream is Pending: its INPUT frames and its
//! stream-scoped requests queue on it, at most [`STREAM_INPUT_CAPACITY`]
//! bytes of INPUT and [`STREAM_REQUEST_CAPACITY`] requests. A successful
//! reply binds the stream to the attached surface after the reply is
//! queued, and the queued items run in arrival order on the stream's own
//! sequence; later items follow them there. A failed reply ends the stream
//! first: `stream-end{attach_failed}`, then the opener's error reply.
//!
//! A stream that holds its cap and gets one more item ends alone: one
//! `input-failed` reports the INPUT bytes it will never write, and
//! `stream-end{overflow}` is its last item; it also answers the requests
//! queued on the stream (none ran, their ids are free). A request sent on
//! the stream after its end is answered `stream_ended`. The connection and its other streams go on. Only a frame
//! naming a stream that was never announced is a bad message.
//!
//! Chrome: an associated endpoint is usable as soon as it is sent, and the
//! router queues the messages of an endpoint that has no client bound yet,
//! then dispatches them in order when one attaches
//! (mojo/public/cpp/bindings/lib/multiplex_router.cc, `ProcessIncomingMessage`
//! returns false while `!endpoint->client()`, `AttachEndpointClient` then
//! `ProcessTasks`). A message for an interface id the router never saw is a
//! validation error that closes the pipe.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, OnceLock, Weak};

use bytes::Bytes;
use cmux_ipc::{Aux, Frame, MethodAttrs};
use cmux_threads::sync::Mutex;
use cmux_threads::work::{Lane, Priority, will_block};
use serde_json::{Value, json};

use super::frame_dispatch::{CallRefusal, FrameCall};
use super::line_connection::{ConnectionBadMessage, FrameConnection};
use super::{
    CONNECTION_SURFACE_QUEUE_CAPACITY, ConnectionSurfaceScheduler, MessageWriter, OutboundStream,
    Request, RequestArrival, get_surface, handle_request_with_cancellation, lock_caller_scope,
    send_bad_request, send_request_error,
};
use crate::event_cause::EventCause;
use crate::mux::mux_work::Sequence;
use crate::panic_free::RecoverPoison;
use crate::{Mux, SurfaceId};

/// INPUT bytes a stream holds that have not reached its PTY.
pub(super) const STREAM_INPUT_CAPACITY: usize = 1 << 20;

/// Requests a stream holds that have not run: the connection control
/// sequence's cap.
pub(super) const STREAM_REQUEST_CAPACITY: usize = CONNECTION_SURFACE_QUEUE_CAPACITY;

/// The methods whose REQUEST on stream S announces S.
const STREAM_OPENERS: [&str; 1] = ["attach-surface"];

/// The `input-failed` reason of INPUT that reached a bound stream and could
/// not be written (the surface closed, or is not a terminal).
const INPUT_WRITE_FAILED: &str = "write_failed";

/// Why a stream ended before it carried its items (`stream-end.reason`, the
/// strings of spec/events.md "stream-end").
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum StreamEnd {
    /// The stream held its cap and got one more item.
    Overflow,
    /// Its opener failed; the opener's error reply follows.
    AttachFailed,
}

impl StreamEnd {
    fn as_str(self) -> &'static str {
        match self {
            StreamEnd::Overflow => "overflow",
            StreamEnd::AttachFailed => "attach_failed",
        }
    }
}

fn stream_end_json(stream: u16, end: StreamEnd) -> Value {
    json!({"event": "stream-end", "stream": stream, "reason": end.as_str()})
}

fn input_failed_json(stream: u16, reason: &str, bytes: usize) -> Value {
    json!({"event": "input-failed", "stream": stream, "reason": reason, "bytes": bytes})
}

/// A request on a stream: its body (checked to name its header's method),
/// the frame it answers, and where its span and events start.
struct StreamRequest {
    body: String,
    call: Arc<FrameCall>,
    arrival: RequestArrival,
    cause: EventCause,
}

enum StreamItem {
    Input { bytes: Bytes, flow: u64 },
    Request(StreamRequest),
}

/// What a stream holds that has not run, counted against its caps.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct Held {
    input_bytes: usize,
    requests: usize,
}

impl Held {
    fn of(item: &StreamItem) -> Held {
        match item {
            StreamItem::Input { bytes, .. } => Held { input_bytes: bytes.len(), requests: 0 },
            StreamItem::Request(_) => Held { input_bytes: 0, requests: 1 },
        }
    }

    /// Adds `cost` if both caps still hold after it.
    fn try_add(&mut self, cost: Held) -> bool {
        let input_bytes = self.input_bytes.saturating_add(cost.input_bytes);
        let requests = self.requests.saturating_add(cost.requests);
        if input_bytes > STREAM_INPUT_CAPACITY || requests > STREAM_REQUEST_CAPACITY {
            return false;
        }
        *self = Held { input_bytes, requests };
        true
    }

    fn remove(&mut self, cost: Held) {
        self.input_bytes = self.input_bytes.saturating_sub(cost.input_bytes);
        self.requests = self.requests.saturating_sub(cost.requests);
    }
}

enum EndpointState {
    /// Its opener has not been answered: items queue here.
    Pending { surface: Option<SurfaceId>, items: VecDeque<StreamItem>, held: Held },
    /// Its opener succeeded: items run in order on `sequence`.
    Bound { surface: SurfaceId, sequence: Arc<Sequence>, held: Held },
    /// It overflowed or its opener failed; its `stream-end` is queued or
    /// will be the last thing its sequence runs.
    Ended,
}

/// One client-minted stream of a connection, from its opener on.
pub(super) struct StreamEndpoint {
    stream: u16,
    client: u64,
    mux: Weak<Mux>,
    /// The connection's writer: `stream-end`, `input-failed`, and the
    /// replies of the stream's requests (each through its own frame call).
    writer: MessageWriter,
    /// Its requests end with the connection's cancellation.
    scheduler: Arc<ConnectionSurfaceScheduler>,
    /// Lock carve-out: held only to queue, count or hand over one item and
    /// to change state, never while an item runs or a message is sent, so
    /// the reader never waits behind a PTY write (the same rule as
    /// `mux_work::Sequence`'s queue lock).
    state: Mutex<EndpointState>,
    /// The outbound stream of the view its opener attached: once it closes
    /// (the view detached or overflowed) the stream ended and its id is
    /// free.
    view: OnceLock<OutboundStream>,
}

impl StreamEndpoint {
    fn new(stream: u16, connection: &FrameConnection<'_>) -> Arc<StreamEndpoint> {
        Arc::new(StreamEndpoint {
            stream,
            client: connection.client,
            mux: Arc::downgrade(connection.mux),
            writer: connection.writer.connection_writer(),
            scheduler: connection.scheduler.clone(),
            state: Mutex::new(EndpointState::Pending {
                surface: None,
                items: VecDeque::new(),
                held: Held::default(),
            }),
            view: OnceLock::new(),
        })
    }

    /// Whether the stream's id is in use: its opener is pending, or its view
    /// is still attached. Asked only for a new opener on the id.
    fn is_live(&self) -> bool {
        let surface = match &*self.state.lock().recover_poison() {
            EndpointState::Pending { .. } => return true,
            EndpointState::Bound { surface, .. } => *surface,
            EndpointState::Ended => return false,
        };
        let (Some(view), Some(mux)) = (self.view.get(), self.mux.upgrade()) else { return false };
        view.is_open()
            && mux
                .control_clients
                .surface_view_streams(self.client, surface)
                .is_some_and(|(_, views)| views.iter().any(|(id, _)| *id == view.id))
    }

    fn view_closed(&self) -> bool {
        self.view.get().is_some_and(|view| !view.is_open())
    }

    /// The opener's handler started the outbound stream of its view
    /// (`MessageWriter::start_stream_on`); the first one is the stream's.
    pub(super) fn carries(&self, view: &OutboundStream) {
        let _ = self.view.set(view.clone());
    }

    /// The opener's handler found the surface the stream carries items to.
    /// False when the stream already ended (it overflowed while its opener
    /// waited): the opener fails instead of attaching a view no stream
    /// carries.
    pub(super) fn target(&self, surface: SurfaceId) -> bool {
        match &mut *self.state.lock().recover_poison() {
            EndpointState::Pending { surface: target, .. } => {
                *target = Some(surface);
                true
            }
            EndpointState::Bound { .. } => true,
            EndpointState::Ended => false,
        }
    }

    /// The opener's reply is queued and it succeeded: the queued items run
    /// in order on the stream's sequence, and later items follow them.
    pub(super) fn opened(self: &Arc<Self>) {
        let Some(mux) = self.mux.upgrade() else { return };
        let mut state = self.state.lock().recover_poison();
        let EndpointState::Pending { surface, items, held } = &mut *state else { return };
        let (target, items, held) = (*surface, std::mem::take(items), *held);
        let Some(surface) = target else {
            // An opener that succeeded without naming its surface (it
            // cannot happen for `attach-surface`): nothing to carry to.
            *state = EndpointState::Ended;
            drop(state);
            self.end(StreamEnd::AttachFailed, items);
            return;
        };
        let sequence = Arc::new(Sequence::default());
        *state = EndpointState::Bound { surface, sequence: sequence.clone(), held };
        // Handed over before the lock is released: an item the reader posts
        // once it sees Bound runs after these.
        for item in items {
            self.run_on(&mux, &sequence, surface, item);
        }
    }

    /// The opener failed; called before its error reply is queued, so
    /// `stream-end{attach_failed}` comes first.
    pub(super) fn open_failed(&self) {
        let mut state = self.state.lock().recover_poison();
        let EndpointState::Pending { items, .. } = &mut *state else { return };
        let items = std::mem::take(items);
        *state = EndpointState::Ended;
        drop(state);
        self.end(StreamEnd::AttachFailed, items);
    }

    fn post(self: &Arc<Self>, item: StreamItem) {
        let cost = Held::of(&item);
        let mut state = self.state.lock().recover_poison();
        match &mut *state {
            EndpointState::Pending { items, held, .. } => {
                if held.try_add(cost) {
                    items.push_back(item);
                    return;
                }
                let queued = std::mem::take(items);
                *state = EndpointState::Ended;
                drop(state);
                self.end(StreamEnd::Overflow, queued.into_iter().chain([item]));
            }
            EndpointState::Bound { .. } if self.view_closed() => {
                // The view detached: its `detached` was its last item.
                *state = EndpointState::Ended;
                drop(state);
                self.refuse_ended(item);
            }
            EndpointState::Bound { surface, sequence, held } => {
                let (surface, sequence) = (*surface, sequence.clone());
                let admitted = held.try_add(cost);
                if !admitted {
                    *state = EndpointState::Ended;
                }
                drop(state);
                let Some(mux) = self.mux.upgrade() else { return };
                if admitted {
                    self.run_on(&mux, &sequence, surface, item);
                } else {
                    // Items admitted before it still run; the end runs after
                    // them, so `stream-end` is the stream's last item.
                    let endpoint = self.clone();
                    let _ = mux.post_mux_work_sequenced(
                        &sequence,
                        Priority::UserBlocking,
                        Lane::System,
                        move |_| endpoint.end(StreamEnd::Overflow, [item]),
                    );
                }
            }
            EndpointState::Ended => {
                drop(state);
                self.refuse_ended(item);
            }
        }
    }

    /// An item for a stream whose end the client has or will read before
    /// this answer: INPUT is dropped, a request answered.
    fn refuse_ended(&self, item: StreamItem) {
        if let StreamItem::Request(request) = item {
            self.refuse(request, "stream_ended", "the stream has ended");
        }
    }

    /// Reports the refused INPUT bytes in one `input-failed`, then queues
    /// `stream-end`, which answers every refused request: none ran, and
    /// their ids are free again. One message, not one reply per request, so
    /// ending a full stream never floods the control queue (Mojo drops the
    /// pending responders of a closed endpoint the same way).
    fn end(&self, end: StreamEnd, refused: impl IntoIterator<Item = StreamItem>) {
        let mut input_bytes = 0usize;
        for item in refused {
            match item {
                StreamItem::Input { bytes, .. } => input_bytes += bytes.len(),
                StreamItem::Request(request) => request.call.abandon(),
            }
        }
        if input_bytes > 0 {
            let _ = self.writer.send_control(&input_failed_json(
                self.stream,
                end.as_str(),
                input_bytes,
            ));
        }
        let _ = self.writer.send_control(&stream_end_json(self.stream, end));
    }

    fn refuse(&self, request: StreamRequest, code: &str, error: &str) {
        let writer = self.writer.replying_to(request.call);
        let _ = writer.send_reply(&json!({"ok": false, "error": error, "error_code": code}));
    }

    fn run_on(
        self: &Arc<Self>,
        mux: &Mux,
        sequence: &Arc<Sequence>,
        surface: SurfaceId,
        item: StreamItem,
    ) {
        let endpoint = self.clone();
        // Refused only when the daemon shuts down, which closes the
        // connection: nobody reads an answer then.
        let _ = mux.post_mux_work_sequenced(
            sequence,
            Priority::UserBlocking,
            Lane::System,
            move |mux| endpoint.run(mux, surface, item),
        );
    }

    fn run(&self, mux: &Weak<Mux>, surface: SurfaceId, item: StreamItem) {
        let cost = Held::of(&item);
        if self.writer.is_open() {
            match item {
                StreamItem::Input { bytes, flow } => self.write_input(mux, surface, &bytes, flow),
                StreamItem::Request(request) => {
                    if let Some(mux) = mux.upgrade() {
                        self.run_request(&mux, request);
                    }
                }
            }
        }
        if let EndpointState::Bound { held, .. } = &mut *self.state.lock().recover_poison() {
            held.remove(cost);
        }
    }

    fn write_input(&self, mux: &Weak<Mux>, surface: SurfaceId, bytes: &[u8], flow: u64) {
        // The mux is held only to find the surface, not across the write,
        // which waits while the program does not read.
        let target = mux.upgrade().and_then(|mux| get_surface(&mux, surface).ok());
        let written = target
            .is_some_and(|target| will_block(|| target.write_bytes_flow(bytes, flow)).is_ok());
        if !written {
            let _ = self.writer.send_control(&input_failed_json(
                self.stream,
                INPUT_WRITE_FAILED,
                bytes.len(),
            ));
        } else if let Some(mux) = mux.upgrade() {
            mux.note_terminal_input(surface, self.client);
        }
    }

    /// Runs a stream request on the stream's sequence, as the dispatcher
    /// runs a control request (`run_pending_request`).
    fn run_request(&self, mux: &Arc<Mux>, request: StreamRequest) {
        let StreamRequest { body, call, arrival, cause } = request;
        let writer = self.writer.replying_to(call.clone());
        let cancellation = call.cancellation();
        let _follows_connection = cancellation.follow(&self.scheduler.cancelled);
        if cancellation.is_cancelled() {
            // Cancelled while queued: answered, never run.
            send_request_error(&writer, None, "request cancelled");
            return;
        }
        let _cause = mux.request_qos().enter(cause);
        let _request_path = crate::request_path::RequestPathScope::enter(mux.request_path_stats());
        let _lock_caller = lock_caller_scope(&writer);
        let request = match crate::line_parses::parse::<Request>(&body) {
            Ok(request) => request,
            Err(error) => {
                send_bad_request(&writer, &body, &error);
                return;
            }
        };
        let _watched = mux.request_watchdog.begin_command(self.client, &request.cmd);
        // A stream request may wait (`wait-for`, a PTY write the program
        // does not read): it does not hold a slot of the work lane meanwhile.
        will_block(|| {
            handle_request_with_cancellation(
                mux,
                self.client,
                request,
                arrival,
                &writer,
                Some(cancellation),
            )
        });
    }
}

/// Where a REQUEST frame goes, by its header's stream.
pub(super) enum RequestLane {
    /// Stream 0: the connection's control sequence.
    Control,
    /// An opener naming a free id: it announces the stream and runs on the
    /// control sequence.
    Open,
    /// An opener naming an id whose stream is still live: answered
    /// `stream_in_use`, not run.
    InUse,
    /// A stream-scoped request on an announced stream.
    Stream(Arc<StreamEndpoint>),
}

/// The streams a connection's client announced, owned by its reader.
#[derive(Default)]
pub(super) struct ClientStreams {
    endpoints: HashMap<u16, Arc<StreamEndpoint>>,
}

impl ClientStreams {
    /// Where a REQUEST of `method` on `stream` goes; a request on a stream
    /// that was never announced, or a control method on a stream, is a bad
    /// message.
    pub(super) fn request_lane(
        &self,
        stream: u16,
        method: &MethodAttrs,
    ) -> Result<RequestLane, CallRefusal> {
        if stream == 0 {
            return Ok(RequestLane::Control);
        }
        if STREAM_OPENERS.contains(&method.name) {
            let live = self.endpoints.get(&stream).is_some_and(|endpoint| endpoint.is_live());
            return Ok(if live { RequestLane::InUse } else { RequestLane::Open });
        }
        if !method.stream_scoped {
            return Err(CallRefusal::NotStreamScoped { stream, method_id: method.id.raw() });
        }
        self.endpoints
            .get(&stream)
            .cloned()
            .map(RequestLane::Stream)
            .ok_or(CallRefusal::UnknownStream { stream })
    }

    /// A CANCEL names a request by id; its stream must still be one this
    /// connection announced.
    pub(super) fn check_cancel(&self, stream: u16) -> Result<(), CallRefusal> {
        if stream == 0 || self.endpoints.contains_key(&stream) {
            Ok(())
        } else {
            Err(CallRefusal::UnknownStream { stream })
        }
    }

    /// Announces `stream` for an opener; an ended stream of the id is
    /// replaced.
    pub(super) fn announce(
        &mut self,
        stream: u16,
        connection: &FrameConnection<'_>,
    ) -> Arc<StreamEndpoint> {
        let endpoint = StreamEndpoint::new(stream, connection);
        self.endpoints.insert(stream, endpoint.clone());
        endpoint
    }

    /// Queues an INPUT frame on its stream.
    pub(super) fn input(&self, frame: Frame) -> Result<(), ConnectionBadMessage> {
        let header = *frame.header();
        let stream = header.stream();
        let endpoint = self
            .endpoints
            .get(&stream)
            .ok_or(ConnectionBadMessage::UnknownStream { kind: header.kind(), stream })?;
        let flow = match header.aux() {
            Aux::FlowId(flow) => flow,
            Aux::Offset(_) | Aux::SharedBufferSize(_) | Aux::Call(_) => 0,
        };
        let bytes = frame.into_payload();
        if !bytes.is_empty() {
            endpoint.post(StreamItem::Input { bytes, flow });
        }
        Ok(())
    }
}

/// Queues the stream request `body`, answered through `call`.
pub(super) fn post_request(
    endpoint: &Arc<StreamEndpoint>,
    body: &str,
    call: Arc<FrameCall>,
    connection: &FrameConnection<'_>,
) {
    endpoint.post(StreamItem::Request(StreamRequest {
        body: body.to_owned(),
        call,
        arrival: RequestArrival::parsed_now(connection.arrived),
        cause: EventCause::current(),
    }));
}

#[cfg(all(test, unix))]
#[path = "pending_streams_tests.rs"]
mod tests;
