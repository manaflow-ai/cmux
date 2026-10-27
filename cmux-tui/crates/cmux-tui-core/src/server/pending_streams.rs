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
//! A terminal create (`split`, `new-tab`, `new-pane`, `new-pane-right`)
//! opens a stream too (p05-ipc-153, server/creating_input.rs): when the
//! daemon takes the create, its stream binds to the terminal id the client
//! minted for it, before the host starts and before the reply, so the keys
//! typed into the new pane go as INPUT at once and wait in that terminal's
//! creating queue. The view's `attach-surface` on the same id takes the
//! stream over; its items run on the same sequence, so no key passes
//! another.
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

use super::creating_input::{CREATING_STREAM_OPENERS, write_stream_input};
use super::frame_dispatch::{CallRefusal, FrameCall};
use super::line_connection::{ConnectionBadMessage, FrameConnection};
use super::{
    CONNECTION_SURFACE_QUEUE_CAPACITY, ConnectionSurfaceScheduler, MessageWriter, OutboundStream,
    Request, RequestArrival, detach_committed_attach, get_surface,
    handle_request_with_cancellation, lock_caller_scope, send_bad_request, send_request_error,
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
    Input { bytes: Bytes, flow: u64 },
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
    /// Its opener is a terminal create the daemon took: items run in order
    /// on `sequence`, INPUT for the terminal `terminal_id` names (queued
    /// while it is creating, written once it is live).
    Creating { terminal_id: Arc<str>, sequence: Arc<Sequence> },
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
    /// Its opener is a terminal create: the create's reply is sent even
    /// when the stream ended first, since the terminal exists.
    creates: bool,
    /// The terminal-create stream this `attach-surface` took over: its
    /// terminal, and the sequence its items run on, which this stream's
    /// items join.
    takes_over: Option<CreatingHandoff>,
    /// The outbound stream of the view its opener attached: once it closes
    /// (the view detached or overflowed) the stream ended and its id is
    /// free.
    view: OnceLock<OutboundStream>,
    #[cfg(test)]
    probe: Option<Arc<dyn StreamProbe>>,
}

impl StreamEndpoint {
    fn new(
        stream: u16,
        creates: bool,
        takes_over: Option<CreatingHandoff>,
        connection: &FrameConnection<'_>,
    ) -> StreamEndpoint {
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
            creates,
            takes_over,
            view: OnceLock::new(),
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
            EndpointState::Creating { terminal_id, .. } => {
                return self
                    .mux
                    .upgrade()
                    .is_some_and(|mux| mux.knows_terminal_input_target(terminal_id));
            }
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

    /// What an `attach-surface` on this stream takes over: set while its
    /// terminal create is bound and its terminal is creating or live.
    fn creating_handoff(&self) -> Option<CreatingHandoff> {
        let handoff = match &*self.state.lock().recover_poison() {
            EndpointState::Creating { terminal_id, sequence } => {
                CreatingHandoff { terminal_id: terminal_id.clone(), sequence: sequence.clone() }
            }
            _ => return None,
        };
        self.is_live().then_some(handoff)
    }

    /// The client-minted stream id.
    pub(super) fn id(&self) -> u16 {
        self.stream
    }

    /// The terminal id of the create stream this `attach-surface` takes
    /// over: the surface it attaches must be that terminal's.
    pub(super) fn took_over_terminal(&self) -> Option<&str> {
        self.takes_over.as_ref().map(|handoff| &*handoff.terminal_id)
    }

    /// The terminal create that opened this stream was taken and names the
    /// terminal id `terminal_id`: the stream binds to it now, before the
    /// create's reply, so its INPUT reaches the terminal's creating queue
    /// while the host starts. The items it queued run first, in order. A
    /// stream that overflowed meanwhile stays so; the reply ends it.
    pub(super) fn bind_creating(self: &Arc<Self>, terminal_id: Arc<str>) {
        let Some(mux) = self.mux.upgrade() else { return };
        let mut state = self.state.lock().recover_poison();
        let EndpointState::Pending { items, .. } = &mut *state else { return };
        let items = std::mem::take(items);
        let sequence = Arc::new(Sequence::default());
        *state = EndpointState::Creating {
            terminal_id: terminal_id.clone(),
            sequence: sequence.clone(),
        };
        let target = StreamTarget::Terminal(terminal_id);
        for item in items {
            self.run_on(&mux, &sequence, target.clone(), item);
        }
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
            // A create's stream carries to its terminal, never to a surface
            // its opener names.
            EndpointState::Overflowed { .. }
            | EndpointState::Creating { .. }
            | EndpointState::Ended { .. } => false,
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
                    // A take-over runs after every item of the create's
                    // stream: they share one sequence.
                    let sequence = match &self.takes_over {
                        Some(handoff) => handoff.sequence.clone(),
                        None => Arc::new(Sequence::default()),
                    };
                    *state = EndpointState::Bound { surface, sequence: sequence.clone() };
                    for item in items {
                        self.run_on(&mux, &sequence, StreamTarget::Surface(surface), item);
                    }
                }
                Some(sent)
            }
            // A create that named no terminal id: nothing to bind the stream
            // to. It ends; the create's reply follows.
            EndpointState::Pending { items, .. } if self.creates => {
                self.send_end(StreamEnd::AttachFailed, refused(items), None);
                drop(state);
                Some(send())
            }
            // An opener that succeeded without naming its surface (it
            // cannot happen for `attach-surface`): nothing to carry to.
            EndpointState::Pending { surface: None, items, .. } => {
                self.send_end(StreamEnd::AttachFailed, refused(items), None);
                None
            }
            // The create made its terminal: its reply is sent after the
            // stream's end.
            EndpointState::Overflowed { input_bytes, .. } if self.creates => {
                self.send_end(StreamEnd::Overflow, input_bytes, None);
                drop(state);
                Some(send())
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
            // A bound create's stream stays bound to its terminal. Any other
            // call has one answer, so its stream is still Pending or
            // Overflowed here.
            answered @ (EndpointState::Bound { .. }
            | EndpointState::Creating { .. }
            | EndpointState::Ended { .. }) => {
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
                // The create failed: its creating queue gives back what it
                // took (`terminal-input-unclaimed`), and an item its
                // sequence still runs fails with `input-failed`.
                EndpointState::Creating { sequence, .. } => {
                    *state = EndpointState::Ended { after: Some(sequence) };
                    (StreamEnd::AttachFailed, 0)
                }
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
                let (target, sequence) = (StreamTarget::Surface(*surface), sequence.clone());
                drop(state);
                if let Some(mux) = self.mux.upgrade() {
                    self.run_on(&mux, &sequence, target, item);
                }
            }
            EndpointState::Creating { terminal_id, sequence } => {
                let (target, sequence) =
                    (StreamTarget::Terminal(terminal_id.clone()), sequence.clone());
                drop(state);
                if let Some(mux) = self.mux.upgrade() {
                    self.run_on(&mux, &sequence, target, item);
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
        target: StreamTarget,
        item: StreamItem,
    ) {
        let endpoint = self.clone();
        // Refused only when the daemon shuts down, which closes the
        // connection: nobody reads an answer then.
        let _ = mux.post_mux_work_sequenced(
            sequence,
            Priority::UserBlocking,
            Lane::System,
            move |mux| endpoint.run(mux, target, item),
        );
    }

    fn run(&self, mux: &Weak<Mux>, target: StreamTarget, item: StreamItem) {
        if !self.writer.is_open() {
            return;
        }
        match (item, target) {
            (StreamItem::Input { bytes, flow }, StreamTarget::Surface(surface)) => {
                self.write_input(mux, surface, &bytes, flow);
            }
            (StreamItem::Input { bytes, .. }, StreamTarget::Terminal(terminal_id)) => {
                let Some(mux) = mux.upgrade() else { return };
                let written = will_block(|| {
                    write_stream_input(&mux, self.client, &self.writer, &terminal_id, &bytes)
                });
                if let Err(reason) = written {
                    let _ = self.writer.send_control(&input_failed_json(
                        self.stream,
                        reason,
                        bytes.len(),
                    ));
                }
            }
            (StreamItem::Request(request), _) => {
                if let Some(mux) = mux.upgrade() {
                    self.run_request(&mux, request);
                }
            }
        }
    }

    fn write_input(&self, mux: &Weak<Mux>, surface: SurfaceId, bytes: &[u8], flow: u64) {
        // The mux is held only to find the surface, not across the write,
        // which waits while the program does not read. Keys queued for the
        // terminal while it was creating are written first (a no-op when
        // no terminal is creating).
        let target = mux.upgrade().and_then(|mux| {
            let target = get_surface(&mux, surface).ok()?;
            will_block(|| mux.wait_for_creating_input_flush(&target));
            Some(target)
        });
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

/// Where a stream's INPUT goes.
#[derive(Clone)]
enum StreamTarget {
    /// The surface its `attach-surface` attached.
    Surface(SurfaceId),
    /// The terminal its create minted the id of.
    Terminal(Arc<str>),
}

/// A terminal create's stream, as the `attach-surface` that takes it over
/// finds it.
struct CreatingHandoff {
    terminal_id: Arc<str>,
    sequence: Arc<Sequence>,
}

/// Where a REQUEST frame goes, by its header's stream.
pub(super) enum RequestLane {
    /// Stream 0: the connection's control sequence.
    Control,
    /// An opener naming a free id, or an `attach-surface` naming a terminal
    /// create's stream: it announces the stream and runs on the control
    /// sequence.
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
        let attach = STREAM_OPENERS.contains(&method.name);
        if attach || CREATING_STREAM_OPENERS.contains(&method.name) {
            let in_use = self.endpoints.get(&stream).is_some_and(|endpoint| {
                endpoint.is_live() && !(attach && endpoint.creating_handoff().is_some())
            });
            return Ok(if in_use { RequestLane::InUse } else { RequestLane::Open });
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

    /// Announces `stream` for an opener of `method`; an ended stream of the
    /// id is replaced, and an `attach-surface` takes over the terminal
    /// create's stream it names.
    pub(super) fn announce(
        &mut self,
        stream: u16,
        method: &MethodAttrs,
        connection: &FrameConnection<'_>,
    ) -> Arc<StreamEndpoint> {
        let creates = CREATING_STREAM_OPENERS.contains(&method.name);
        let takes_over = match creates {
            true => None,
            false => self.endpoints.get(&stream).and_then(|previous| previous.creating_handoff()),
        };
        let endpoint = StreamEndpoint::new(stream, creates, takes_over, connection);
        #[cfg(test)]
        let endpoint = StreamEndpoint { probe: self.probe.clone(), ..endpoint };
        let endpoint = Arc::new(endpoint);
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
