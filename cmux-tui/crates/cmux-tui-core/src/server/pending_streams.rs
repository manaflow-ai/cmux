//! Pending streams (plans/cmux-next/chrome-parity/p05-ipc.md,
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
//! A Pending stream that holds its cap and gets one more item overflows and
//! ends alone; the opener's answer ends it. Its handler may be building the
//! view already, so the view and the stream end in one step at the answer:
//! one `input-failed` reports the INPUT bytes it will never write,
//! `stream-end{overflow}` closes the view (its unwritten items are dropped,
//! nothing of it follows) and answers the requests sent on the stream (none
//! ran, their ids are free), then the opener gets the ERROR `stream_ended`
//! instead of its reply. A request sent on the stream after its end is
//! answered `stream_ended`. The connection and its other streams go on.
//! Only a frame naming a stream that was never announced is a bad message.
//!
//! The caps are a Pending stream's only: a bound stream's INPUT goes to its
//! PTY's writer as it comes (a bounded terminal input sink is p05-ipc-157).
//!
//! Chrome: an associated endpoint is usable as soon as it is sent, and the
//! router queues the messages of an endpoint that has no client bound yet,
//! then dispatches them in order when one attaches
//! (mojo/public/cpp/bindings/lib/multiplex_router.cc, `ProcessIncomingMessage`
//! returns false while `!endpoint->client()`, `AttachEndpointClient` then
//! `ProcessTasks`). A message for an interface id the router never saw is a
//! validation error that closes the pipe.

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock, Weak};

use bytes::Bytes;
use cmux_ipc::{Aux, Frame, MethodAttrs};
use cmux_threads::sync::Mutex;
use cmux_threads::work::{Lane, Priority, will_block};
use serde_json::{Value, json};

use super::cmd_terminal_io::{self, InputFailure};
use super::frame_dispatch::{CallRefusal, FrameCall};
use super::line_connection::{ConnectionBadMessage, FrameConnection};
use super::{
    CONNECTION_SURFACE_QUEUE_CAPACITY, ConnectionSurfaceScheduler, MessageWriter, OutboundStream,
    Request, RequestArrival, detach_committed_attach, handle_request_with_cancellation,
    lock_caller_scope, send_bad_request, send_request_error,
};
use crate::event_cause::EventCause;
use crate::mux::mux_work::Sequence;
use crate::panic_free::RecoverPoison;
use crate::{Mux, SurfaceId};

/// INPUT bytes a Pending stream holds.
pub(super) const STREAM_INPUT_CAPACITY: usize = 1 << 20;

/// Requests a Pending stream holds: the connection control sequence's cap.
pub(super) const STREAM_REQUEST_CAPACITY: usize = CONNECTION_SURFACE_QUEUE_CAPACITY;

/// The methods whose REQUEST on stream S announces S.
const STREAM_OPENERS: [&str; 1] = ["attach-surface"];

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

/// The ERROR of a request on a stream that ended, and of an opener whose
/// stream ended before its answer.
pub(super) fn stream_ended_reply() -> Value {
    json!({"ok": false, "error": "the stream has ended", "error_code": "stream_ended"})
}

/// Told what a connection's streams do, so a test orders the reader and
/// an opener's handler without timing.
#[cfg(test)]
pub(super) trait StreamProbe: Send + Sync {
    /// An opener's handler named its stream's surface ([`StreamEndpoint::target`]).
    fn targeted(&self);
    /// The reader queued or refused one item on a stream.
    fn posted(&self);
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
    /// An INPUT frame's bytes, its flow id (0: none) and the connection's
    /// cause, under which they are written.
    Input {
        bytes: Bytes,
        flow: u64,
        cause: EventCause,
    },
    Request(StreamRequest),
}

/// What a Pending stream holds, counted against its caps.
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
}

/// Answers every request in `items` by the coming `stream-end` and returns
/// the INPUT bytes among them.
fn refused(items: impl IntoIterator<Item = StreamItem>) -> usize {
    items.into_iter().fold(0, |input_bytes, item| match item {
        StreamItem::Input { bytes, .. } => input_bytes + bytes.len(),
        StreamItem::Request(request) => {
            request.call.abandon();
            input_bytes
        }
    })
}

enum EndpointState {
    /// Its opener has not been answered: items queue here.
    Pending { surface: Option<SurfaceId>, items: VecDeque<StreamItem>, held: Held },
    /// It overflowed while its opener was in flight; the opener's answer
    /// ends it. Later items are refused into the same end.
    Overflowed { surface: Option<SurfaceId>, input_bytes: usize },
    /// Its opener succeeded: items run in order on `sequence`.
    Bound { surface: SurfaceId, sequence: Arc<Sequence> },
    /// Its `stream-end` is queued, or its view detached. A request is
    /// answered `stream_ended` after the stream's earlier items: on
    /// `after`, the sequence of a stream that was bound.
    Ended { after: Option<Arc<Sequence>> },
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
    /// Lock carve-out: held to queue, count or hand over items, to change
    /// state and to queue the messages that change sends (a push onto the
    /// connection's outbound queue, which never waits), so no answer comes
    /// between them; never while an item runs, so the reader never waits
    /// behind a PTY write (the same rule as `mux_work::Sequence`'s queue
    /// lock).
    state: Mutex<EndpointState>,
    /// The outbound stream of the view its opener attached: once it closes
    /// (the view detached or overflowed) the stream ended and its id is
    /// free.
    view: OnceLock<OutboundStream>,
    /// Whether the stream's terminal ended since an INPUT write last reached
    /// it: an ended terminal gives one `input-failed`, not one per frame. An
    /// endpoint is one open of the stream id, so a reopened stream reports
    /// the end again.
    input_ended: AtomicBool,
    #[cfg(test)]
    probe: Option<Arc<dyn StreamProbe>>,
}

impl StreamEndpoint {
    fn new(stream: u16, connection: &FrameConnection<'_>) -> StreamEndpoint {
        StreamEndpoint {
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
            input_ended: AtomicBool::new(false),
            #[cfg(test)]
            probe: None,
        }
    }

    /// Whether the stream's id is in use: its opener is pending, or its view
    /// is still attached. Asked only for a new opener on the id.
    fn is_live(&self) -> bool {
        let surface = match &*self.state.lock().recover_poison() {
            EndpointState::Pending { .. } | EndpointState::Overflowed { .. } => return true,
            EndpointState::Bound { surface, .. } => *surface,
            EndpointState::Ended { .. } => return false,
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
    /// False when the stream already overflowed: the opener fails instead
    /// of attaching a view no stream carries.
    pub(super) fn target(&self, surface: SurfaceId) -> bool {
        let targeted = match &mut *self.state.lock().recover_poison() {
            EndpointState::Pending { surface: target, .. } => {
                *target = Some(surface);
                true
            }
            EndpointState::Bound { .. } => true,
            EndpointState::Overflowed { .. } | EndpointState::Ended { .. } => false,
        };
        #[cfg(test)]
        if let Some(probe) = &self.probe {
            probe.targeted();
        }
        targeted
    }

    /// The opener succeeded: `send` queues its reply and the stream binds
    /// in one step under the state lock, so the queued items run in order
    /// on the stream's sequence after the reply and later items follow
    /// them. `None` when the stream overflowed first: it ended with its
    /// view, and the opener is answered [`stream_ended_reply`] instead.
    pub(super) fn bind_with(
        self: &Arc<Self>,
        send: impl FnOnce() -> std::io::Result<()>,
    ) -> Option<std::io::Result<()>> {
        let mut state = self.state.lock().recover_poison();
        match std::mem::replace(&mut *state, EndpointState::Ended { after: None }) {
            EndpointState::Pending { surface: Some(surface), items, .. } => {
                let sent = send();
                if let (Ok(()), Some(mux)) = (&sent, self.mux.upgrade()) {
                    let sequence = Arc::new(Sequence::default());
                    *state = EndpointState::Bound { surface, sequence: sequence.clone() };
                    for item in items {
                        self.run_on(&mux, &sequence, surface, item);
                    }
                }
                Some(sent)
            }
            // An opener that succeeded without naming its surface (it
            // cannot happen for `attach-surface`): nothing to carry to.
            EndpointState::Pending { surface: None, items, .. } => {
                self.send_end(StreamEnd::AttachFailed, refused(items), None);
                None
            }
            EndpointState::Overflowed { surface, input_bytes } => {
                let view = self.view.get();
                self.send_end(StreamEnd::Overflow, input_bytes, view);
                drop(state);
                if let (Some(view), Some(surface), Some(mux)) = (view, surface, self.mux.upgrade())
                {
                    detach_committed_attach(&mux, self.client, surface, view.id);
                }
                None
            }
            // A call has one answer, so its stream is still Pending or
            // Overflowed here.
            answered @ (EndpointState::Bound { .. } | EndpointState::Ended { .. }) => {
                *state = answered;
                drop(state);
                Some(send())
            }
        }
    }

    /// The opener failed and rolled back its view; called before its error
    /// reply is queued, so `stream-end` comes first. A view it started is
    /// closed by the end too.
    pub(super) fn open_failed(&self) {
        let mut state = self.state.lock().recover_poison();
        let (end, input_bytes) =
            match std::mem::replace(&mut *state, EndpointState::Ended { after: None }) {
                EndpointState::Pending { items, .. } => (StreamEnd::AttachFailed, refused(items)),
                EndpointState::Overflowed { input_bytes, .. } => (StreamEnd::Overflow, input_bytes),
                answered @ (EndpointState::Bound { .. } | EndpointState::Ended { .. }) => {
                    *state = answered;
                    return;
                }
            };
        self.send_end(end, input_bytes, self.view.get());
    }

    fn post(self: &Arc<Self>, item: StreamItem) {
        self.queue(item);
        #[cfg(test)]
        if let Some(probe) = &self.probe {
            probe.posted();
        }
    }

    fn queue(self: &Arc<Self>, item: StreamItem) {
        let cost = Held::of(&item);
        let mut state = self.state.lock().recover_poison();
        match &mut *state {
            EndpointState::Pending { surface, items, held } => {
                if held.try_add(cost) {
                    items.push_back(item);
                    return;
                }
                let surface = *surface;
                let input_bytes = refused(std::mem::take(items).into_iter().chain([item]));
                *state = EndpointState::Overflowed { surface, input_bytes };
            }
            EndpointState::Overflowed { input_bytes, .. } => *input_bytes += refused([item]),
            EndpointState::Bound { sequence, .. } if self.view_closed() => {
                // The view detached: its `detached` was its last item.
                let after = Some(sequence.clone());
                *state = EndpointState::Ended { after: after.clone() };
                drop(state);
                self.refuse_ended(after, item);
            }
            EndpointState::Bound { surface, sequence } => {
                let (surface, sequence) = (*surface, sequence.clone());
                drop(state);
                if let Some(mux) = self.mux.upgrade() {
                    self.run_on(&mux, &sequence, surface, item);
                }
            }
            EndpointState::Ended { after } => {
                let after = after.clone();
                drop(state);
                self.refuse_ended(after, item);
            }
        }
    }

    /// An item for a stream whose end the client has or will read before
    /// this answer: INPUT is dropped, a request answered after the items
    /// sent on the stream before it (on `after`, its sequence).
    fn refuse_ended(self: &Arc<Self>, after: Option<Arc<Sequence>>, item: StreamItem) {
        let StreamItem::Request(request) = item else { return };
        let (Some(sequence), Some(mux)) = (after, self.mux.upgrade()) else {
            self.refuse(request);
            return;
        };
        let endpoint = self.clone();
        // Refused only when the daemon shuts down, which closes the
        // connection: nobody reads an answer then.
        let _ = mux.post_mux_work_sequenced(
            &sequence,
            Priority::UserBlocking,
            Lane::System,
            move |_| endpoint.refuse(request),
        );
    }

    /// Reports the refused INPUT bytes in one `input-failed`, then queues
    /// `stream-end`, which answers every refused request: none ran, and
    /// their ids are free again. One message, not one reply per request, so
    /// ending a full stream never floods the control queue (Mojo drops the
    /// pending responders of a closed endpoint the same way). With the
    /// stream's `view`, `stream-end` closes it and drops its unwritten
    /// items: nothing of the view follows the end.
    fn send_end(&self, end: StreamEnd, input_bytes: usize, view: Option<&OutboundStream>) {
        if input_bytes > 0 {
            let _ = self.writer.send_control(&input_failed_json(
                self.stream,
                end.as_str(),
                input_bytes,
            ));
        }
        let stream_end = stream_end_json(self.stream, end);
        let _ = match view {
            Some(view) => self.writer.send_stream_end(&stream_end, view),
            None => self.writer.send_control(&stream_end),
        };
    }

    fn refuse(&self, request: StreamRequest) {
        let _ = self.writer.replying_to(request.call).send_reply(&stream_ended_reply());
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
        if !self.writer.is_open() {
            return;
        }
        match item {
            StreamItem::Input { bytes, flow, cause } => {
                self.write_input(mux, surface, &bytes, flow, cause);
            }
            StreamItem::Request(request) => {
                if let Some(mux) = mux.upgrade() {
                    self.run_request(&mux, request);
                }
            }
        }
    }

    /// Writes an INPUT frame's bytes as `send` writes them,
    /// under the connection's cause, caller class and request path, as a
    /// request runs. A failure is the stream's `input-failed`, once per end
    /// of its terminal.
    fn write_input(
        &self,
        mux: &Weak<Mux>,
        surface: SurfaceId,
        bytes: &[u8],
        flow: u64,
        cause: EventCause,
    ) {
        let Some((stats, qos)) =
            mux.upgrade().map(|mux| (mux.request_path_stats().clone(), mux.request_qos()))
        else {
            return;
        };
        let _request_path = crate::request_path::RequestPathScope::enter(&stats);
        let _lock_caller = lock_caller_scope(&self.writer);
        let _cause = qos.enter(cause);
        let written =
            will_block(|| cmd_terminal_io::write_input(mux, self.client, surface, bytes, flow));
        match written {
            Ok(()) => self.input_ended.store(false, Ordering::Release),
            Err(failure) => {
                if failure.is_final() && self.input_ended.swap(true, Ordering::AcqRel) {
                    return;
                }
                self.input_failed(failure, bytes.len());
            }
        }
    }

    /// Reports `bytes` bytes of INPUT on this stream that did not reach its
    /// terminal.
    fn input_failed(&self, failure: InputFailure, bytes: usize) {
        let _ = self.writer.send_control(&failure.event(self.stream, bytes));
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
    /// Told when an opener targets a stream and when an item is posted.
    #[cfg(test)]
    pub(super) probe: Option<Arc<dyn StreamProbe>>,
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
        #[cfg(test)]
        let endpoint = StreamEndpoint { probe: self.probe.clone(), ..endpoint };
        let endpoint = Arc::new(endpoint);
        self.endpoints.insert(stream, endpoint.clone());
        endpoint
    }

    /// Queues an INPUT frame on its stream, written under `cause`; with
    /// `refused`, its bytes are reported not written instead.
    pub(super) fn input(
        &self,
        frame: Frame,
        cause: EventCause,
        refused: Option<InputFailure>,
    ) -> Result<(), ConnectionBadMessage> {
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
        if bytes.is_empty() {
            return Ok(());
        }
        match refused {
            Some(failure) => endpoint.input_failed(failure, bytes.len()),
            None => endpoint.post(StreamItem::Input { bytes, flow, cause }),
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
