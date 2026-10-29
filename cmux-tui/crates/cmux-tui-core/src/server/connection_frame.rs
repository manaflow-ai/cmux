//! One frame of a connection: authentication and pairing frames, a request's
//! dispatch with its cancellation, and the VT-state command reply. Moved out of
//! server.rs unchanged (cx-6so.3).
//!
//! The reader runs no handler. It reads a line's head once and
//! puts the line on its connection's control sequence
//! (connection_scheduler.rs) in arrival order: a `Command` parsed, any other
//! line (a v2 operation, a feature route, a remote-relay line, a line the
//! `Command` parse refused) as it is, with its head. The handler runs on the
//! sequence, so a slow one never delays reading the next line, and replies
//! leave in arrival order. Chrome's IO thread does the same: it reads and
//! validates a message and posts it to its receiver's sequence
//! (mojo/public/cpp/bindings/lib/multiplex_router.cc, `Accept`). Only
//! `client-hello` (client_hello.rs) and a CANCEL frame (frame_dispatch.rs)
//! are answered on the reader; `identify` is a `Command` and is sequenced
//! (the hello gate only notes it). A v2 `request.cancel` or `stream.cancel`
//! is sequenced: what it cancels was installed by an earlier item of the
//! same sequence, so answered before it, it would find nothing.

#[cfg(unix)]
pub(super) mod machine_catalog;

use super::*;
use crate::diagnostics::{JsonParseHandoff, LockCaller, LockCallerScope};
use crate::event_cause::{EventCause, RequestPriority};
use cmux_threads::work::{Lane, Priority, Shutdown};

/// The caller class the lock acquisitions of `writer`'s connection count
/// under until this drops (`debug-daemon-locks`): the verified app is the
/// frontend, every other connection automation. The origin gate keeps the
/// class on the writer, so this reads an atomic and takes no lock.
/// Scheduling only (lock telemetry, the frontend's reserved worker permits):
/// no permission reads it.
pub(super) fn lock_caller_scope(writer: &MessageWriter) -> LockCallerScope {
    LockCallerScope::enter(writer.lock_caller.get())
}

/// The threads that read a connection's lines and only route them: the
/// Unix reader (`mux-conn`), the WebSocket and remote-entry readers, and
/// (Unix) the mux-io loops that read the person's and every other connection.
#[cfg(unix)]
const READER_THREADS: [&str; 5] = [
    WatchKind::MuxConn.name(),
    "mux-ws-conn",
    "mux-remote-conn",
    mux_io::MUX_IO_THREAD,
    mux_io::MUX_IO_INPUT_THREAD,
];
#[cfg(not(unix))]
const READER_THREADS: [&str; 3] = [WatchKind::MuxConn.name(), "mux-ws-conn", "mux-remote-conn"];

/// Debug builds: no request handler runs on a thread that reads a
/// connection ([`READER_THREADS`]); a reader only reads, cuts and
/// sequences, and disallows blocking, which most handlers need.
#[track_caller]
pub(super) fn debug_assert_off_reader() {
    if cfg!(debug_assertions) {
        let thread = std::thread::current();
        let name = thread.name().unwrap_or_default();
        debug_assert!(
            !READER_THREADS.contains(&name),
            "a request handler ran on its connection's reader thread '{name}'"
        );
    }
}

/// The caller class of a `transport` connection whose writer is `writer`: a
/// remote entry is automation whatever its origin, a local connection the
/// class the origin gate keeps on its writer.
pub(super) fn connection_caller(transport: ClientTransport, writer: &MessageWriter) -> LockCaller {
    match transport {
        ClientTransport::Remote => LockCaller::Automation,
        ClientTransport::Unix | ClientTransport::WebSocket => writer.lock_caller.get(),
    }
}

/// [`handle_connection_frame_at`] for a line that arrives now (tests). A
/// line it sequences is answered before it returns, as the in-process
/// callers read the reply next, and it returns whether the connection is
/// still open after that answer.
#[cfg(test)]
pub(super) fn handle_connection_frame(
    mux: &Arc<Mux>,
    client: u64,
    transport: ClientTransport,
    message: &str,
    writer: &MessageWriter,
    scheduler: &Arc<ConnectionSurfaceScheduler>,
) -> bool {
    let keep_open = handle_connection_frame_at(
        mux,
        client,
        transport,
        message,
        writer,
        scheduler,
        Instant::now(),
    );
    // A line it sequenced has answered once the sequence ran it.
    scheduler.wait_for_lines();
    keep_open && !scheduler.is_closed()
}

/// One frame of a connection, read at `arrived` (the reader stamps it as
/// its read returns; a line already buffered behind an inline request is
/// stamped when the reader reaches it). `transport` is the connection's own
/// value (not a registry lookup), so a remote-entry connection always takes
/// the remote path, also after its registry record is gone.
pub(super) fn handle_connection_frame_at(
    mux: &Arc<Mux>,
    client: u64,
    transport: ClientTransport,
    message: &str,
    writer: &MessageWriter,
    scheduler: &Arc<ConnectionSurfaceScheduler>,
    arrived: Instant,
) -> bool {
    // The release hang watch: one scope per frame, at the deadline of the
    // request it reaches from then (server/request_hang_watch.rs). A line
    // the reader sequences opens its own scope where it runs.
    let _hang = request_hang_watch::RequestHang::frame();
    // The lock acquisitions the reader makes for this frame count under its
    // connection's caller class (`debug-daemon-locks`).
    let _lock_caller = LockCallerScope::enter(connection_caller(transport, writer));
    // Every frame is watched on this thread until it is sequenced: past
    // 250 ms it lands in server-stats `slow_requests` (request_watchdog.rs).
    // Its handler is watched again where it runs.
    let watched = mux.request_watchdog.begin(client, WatchedMethod::frame(FrameStage::Route));
    // Keep an idle shutdown requester connected until owner cleanup closes
    // the transport, so lifecycle clients receive authoritative completion.
    // A pipelined message after the acknowledgement must not reach parsing or
    // dispatch; returning false makes the connection loop close that client.
    if mux.daemon_shutdown_requested() || mux.daemon_handoff_committed() {
        return false;
    }
    // Every event this frame sets off, here or on a thread it hands work
    // to, carries the connection's cause (crate::event_cause).
    let (remote, cause) = mux.frame_client(client);
    // The frame runs at its cause's class (crate::request_qos), here or on
    // the request sequence, which enters it there.
    let request_qos = mux.request_qos();
    let enter_cause = || request_qos.enter(cause);
    // Every handler this frame reaches runs on a request path
    // (`crate::request_path`): its blocking work is counted at its caller.
    // A line handed to the request sequence enters its scope there.
    let request_path = || crate::request_path::RequestPathScope::enter(mux.request_path_stats());
    if matches!(transport, ClientTransport::Remote) || remote {
        // The relay reads the line itself, on the connection's sequence,
        // with the connection's cause.
        let _cause = crate::event_cause::EventCauseScope::enter(cause);
        let line = LineFrame {
            mux,
            client,
            message,
            writer,
            scheduler,
            arrival: RequestArrival::parsed_now(arrived),
            watched: watched.as_ref(),
        };
        line.stage(FrameStage::RemoteRelay);
        return sequence_line(&line, LineWork::Remote);
    }
    // Before the acknowledgement the handoff can still fail (for example
    // while `end_terminals` awaits every host) and this daemon keeps
    // serving. Closing here would drop the requester's pending
    // `shutdown-daemon` reply along with its connection, so a message that
    // arrives meanwhile (a subscriber's snapshot refresh) is refused
    // without being executed and the connection stays open.
    if mux.daemon_handoff_in_progress() {
        let _cause = enter_cause();
        return pending_handoff::reject_message_during_pending_handoff(message, writer);
    }
    // An older client's line, upgraded to this daemon's API revision before
    // any parse (server/api_revision_wire.rs); borrowed unchanged otherwise,
    // and always for a frame (frames exist only at this revision).
    let upgraded = writer.upgrade_request(message);
    let parses = crate::line_parses::LineParses::enter();
    let head = RequestHead::parse(&upgraded);
    // A `Command` line is parsed and queued here, at its cause's class and
    // on the request path. Any other line (a `cmux.protocol/2` line, a
    // feature route) is sequenced as it is with the connection's cause, and
    // its handler enters the class and the request path where it runs: it
    // may read and commit SQLite or files, which this reader (blocking
    // disallowed) may not.
    let command = head.is_command() && !head.is_resource();
    let _cause = command.then(enter_cause);
    let _line_cause = (!command).then(|| crate::event_cause::EventCauseScope::enter(cause));
    let _request_path = command.then(request_path);
    let line = LineFrame {
        mux,
        client,
        message: &upgraded,
        writer,
        scheduler,
        arrival: RequestArrival::parsed_now(arrived),
        watched: watched.as_ref(),
    };
    match dispatch_line(&line, head) {
        Dispatched::Answered(keep_open) => {
            cmux_trace::trace_instant!(
                daemon,
                "daemon.frame.json_parses",
                u64::from(parses.count())
            );
            keep_open
        }
        // The sequence reports its parses when it answers.
        Dispatched::Sequenced(keep_open) => keep_open,
    }
}

/// A local connection's request line on its way to its one handler.
#[derive(Clone, Copy)]
pub(super) struct LineFrame<'f> {
    pub(super) mux: &'f Arc<Mux>,
    pub(super) client: u64,
    pub(super) message: &'f str,
    pub(super) writer: &'f MessageWriter,
    pub(super) scheduler: &'f Arc<ConnectionSurfaceScheduler>,
    /// When the line arrived, and when the reader read its head.
    pub(super) arrival: RequestArrival,
    pub(super) watched: Option<&'f RequestScope<'f>>,
}

impl LineFrame<'_> {
    fn watch(&self, method: WatchedMethod) {
        if let Some(scope) = self.watched {
            scope.set_method(method);
        }
    }

    fn stage(&self, stage: FrameStage) {
        self.watch(WatchedMethod::frame(stage));
    }
}

/// Where the reader left a line.
pub(super) enum Dispatched {
    /// Answered or refused on the reader (a `Command` it sequenced is in
    /// here too: its parses all happened on the reader).
    Answered(bool),
    /// On the control sequence with its head; the sequence answers it.
    Sequenced(bool),
}

/// The reader's part of a line whose `head` it read: a `Command` line
/// is parsed and sequenced as its `Command`; every other line is sequenced
/// with its head, and [`answer_line`] answers it there.
pub(super) fn dispatch_line(line: &LineFrame<'_>, head: RequestHead<'_>) -> Dispatched {
    let LineFrame { mux, client, message, writer, scheduler, arrival, .. } = *line;
    if head.is_resource() || !head.is_command() {
        return Dispatched::Sequenced(sequence_line(line, LineWork::Line(head.into_owned())));
    }
    line.stage(FrameStage::Route);
    let request = match crate::line_parses::parse::<Request>(message) {
        Ok(request) => request,
        Err(error) => {
            let work = LineWork::BadRequest(head.into_owned(), error);
            return Dispatched::Sequenced(sequence_line(line, work));
        }
    };
    line.watch(WatchedMethod::command(&request.cmd));
    let arrival = RequestArrival::parsed_now(arrival.arrived);
    // The `Command` joins the same sequence; it never runs here.
    let mut pending = Some(request);
    let keep_open = scheduler
        .dispatch_at(mux.clone(), client, &mut pending, arrival, message.len(), writer.clone())
        .unwrap_or(true);
    Dispatched::Answered(keep_open)
}

/// What the sequence does with a line the reader left there.
pub(super) enum LineWork {
    /// A line [`answer_line`] answers: a v2 line, a feature route's, or one
    /// whose `cmd` names nothing.
    Line(RequestHead<'static>),
    /// A line whose `cmd` names a `Command` but whose parse failed: its
    /// error is the reply.
    BadRequest(RequestHead<'static>, serde_json::Error),
    /// A remote-relay connection's line (remote_relay.rs reads it).
    Remote,
}

/// A line on its connection's control sequence, with all the reader knew.
pub(super) struct PendingLine {
    /// The line (upgraded to this daemon's API revision), cleared once
    /// answered.
    message: String,
    work: LineWork,
    arrival: RequestArrival,
    /// The cause of the frame that queued it.
    cause: EventCause,
    /// The connection it came in on.
    client: u64,
    /// The writer it answers on: its REQUEST frame's, if it came in one.
    writer: MessageWriter,
    /// The `server-stats` `ipc` request its reader's scope counted: its
    /// parses on the sequence count toward it too.
    json_parses: JsonParseHandoff,
    /// Its parses on the reader (`daemon.frame.json_parses`).
    line_parses: u32,
    /// Tests: the request classes it enters are noted where the test that
    /// sent it reads them (crate::request_qos).
    #[cfg(test)]
    qos_recorder: crate::request_qos::tests::Recorder,
}

impl PendingLine {
    /// Its share of the connection's queued bytes: the line, as a queued
    /// `Command` counts its line.
    pub(super) fn retained_bytes(&self) -> usize {
        self.message.len()
    }

    /// The writer of the connection it came in on.
    pub(super) fn connection_writer(&self) -> MessageWriter {
        self.writer.connection_writer()
    }

    /// The cause of the frame that queued it: its work item's priority.
    pub(super) fn cause(&self) -> EventCause {
        self.cause
    }
}

impl Drop for PendingLine {
    fn drop(&mut self) {
        zeroize_string(&mut self.message);
    }
}

/// How a line the full sequence refused is answered.
enum Refusal {
    /// A v2 response naming its operation.
    Resource(String),
    /// A remote-relay line: a code only (remote_relay.rs), never local
    /// error text.
    Remote,
    /// A `loopback-*` line: its stream ends (loopback_forward.rs), and a
    /// line with an `id` also gets the error reply.
    Loopback,
    /// The v1 error reply with the line's `id`.
    Request,
}

/// Puts `line` on its connection's control sequence; whether the
/// connection stays open. A sequence that is full refuses the line here,
/// unexecuted, as it refuses a `Command`. A line is held to its
/// connection's caps only ([`ConnectionBudget`]): before
/// p05-ipc-086 it never met the daemon's surface-operation byte budget.
fn sequence_line(line: &LineFrame<'_>, work: LineWork) -> bool {
    let LineFrame { mux, client, message, writer, scheduler, arrival, .. } = *line;
    let refusal = match &work {
        LineWork::Remote => Refusal::Remote,
        LineWork::Line(head) | LineWork::BadRequest(head, _) if head.is_resource() => {
            Refusal::Resource(head.operation().unwrap_or("request").to_owned())
        }
        LineWork::Line(head) if head.cmd().is_some_and(loopback_forward::is_loopback_cmd) => {
            Refusal::Loopback
        }
        LineWork::Line(_) | LineWork::BadRequest(..) => Refusal::Request,
    };
    let owned = message.to_owned();
    let line_parses = crate::line_parses::current();
    let sequenced =
        scheduler.sequence::<ConnectionBudget>(mux, client, owned.len(), writer, |()| {
            SequencedItem::Line(PendingLine {
                message: owned,
                work,
                arrival,
                cause: EventCause::current(),
                client,
                writer: writer.clone(),
                json_parses: crate::diagnostics::JsonParseScope::handoff(),
                line_parses,
                #[cfg(test)]
                qos_recorder: crate::request_qos::tests::recorder(),
            })
        });
    let Err(not_sequenced) = sequenced else { return true };
    let Some(reason) = not_sequenced.refusal() else { return false };
    let id = || match crate::line_parses::parse::<Value>(message) {
        Ok(Value::Object(mut object)) => object.remove("id"),
        _ => None,
    };
    match refusal {
        Refusal::Resource(operation) => {
            let error = ResourceError::operation_failed(operation, reason, json!({}));
            let response = crate::resource_router::malformed_resource_response(message, error);
            writer.send_control(&response).is_ok()
        }
        Refusal::Remote => {
            writer.send_control(&remote_relay::refusal(message, remote_relay::REMOTE_ERROR)).is_ok()
        }
        Refusal::Loopback => {
            loopback_forward::end_refused_stream(mux, client, message);
            match id() {
                Some(id) => send_request_error(writer, Some(id), &reason),
                None => true,
            }
        }
        Refusal::Request => send_request_error(writer, id(), &reason),
    }
}

/// Runs a line the reader sequenced, on the connection's request sequence
/// (the control sequence took it in arrival order with the connection's
/// `Command`s), as the reader ran it before: the same cause, lock caller,
/// request path, hang watch, watchdog scope and parse counts; whether the
/// connection stays open.
pub(super) fn run_sequenced_line(
    scheduler: &Arc<ConnectionSurfaceScheduler>,
    mux: &Arc<Mux>,
    line: PendingLine,
) -> bool {
    // A test reads the classes its line entered on its own thread.
    #[cfg(test)]
    let recorder = line.qos_recorder.clone();
    let run = move || run_line(scheduler, mux, line);
    #[cfg(test)]
    return crate::request_qos::tests::follow_recorder(recorder, run);
    #[cfg(not(test))]
    run()
}

fn run_line(
    scheduler: &Arc<ConnectionSurfaceScheduler>,
    mux: &Arc<Mux>,
    line: PendingLine,
) -> bool {
    let (client, writer) = (line.client, &line.writer.clone());
    let _json_parses = crate::diagnostics::JsonParseScope::resume(line.json_parses.clone());
    let parses = crate::line_parses::LineParses::resume(line.line_parses);
    // This thread's hang-watch scope for the line, as the reader's frame.
    let _hang = request_hang_watch::RequestHang::frame();
    let _cause = mux.request_qos().enter(line.cause);
    let _request_path = crate::request_path::RequestPathScope::enter(mux.request_path_stats());
    let remote = matches!(line.work, LineWork::Remote);
    let _lock_caller = if remote {
        LockCallerScope::enter(LockCaller::Automation)
    } else {
        lock_caller_scope(writer)
    };
    let watched = mux.request_watchdog.begin(client, WatchedMethod::frame(FrameStage::Route));
    // The daemon may have begun to shut down since the line arrived: as on
    // the reader, a line after the acknowledgement is never dispatched.
    if mux.daemon_shutdown_requested() || mux.daemon_handoff_committed() {
        return false;
    }
    let message = line.message.as_str();
    let arrival = line.arrival;
    let frame =
        LineFrame { mux, client, message, writer, scheduler, arrival, watched: watched.as_ref() };
    let keep_open = match &line.work {
        LineWork::Remote => {
            debug_assert_off_reader();
            return remote_relay::handle_watched_frame(
                mux,
                client,
                message,
                writer,
                arrival.arrived,
                watched.as_ref(),
            );
        }
        _ if mux.daemon_handoff_in_progress() => {
            pending_handoff::reject_message_during_pending_handoff(message, writer)
        }
        LineWork::Line(head) => answer_line(&frame, head),
        LineWork::BadRequest(head, error) => {
            frame.stage(FrameStage::Route);
            let mut span = head.open(mux.request_stats(), arrival);
            span.reply(|| send_bad_request(writer, message, error))
        }
    };
    cmux_trace::trace_instant!(daemon, "daemon.frame.json_parses", u64::from(parses.count()));
    keep_open
}

/// Answers a sequenced line by its head: a v2 line to the page router or
/// the resource router, a feature route's `cmd` to its route
/// (server/routes.rs), anything else to the `Command` parse. The handler a
/// request reaches parses the line once more; an error reply may parse it
/// again for its `id`.
fn answer_line(line: &LineFrame<'_>, head: &RequestHead<'_>) -> bool {
    debug_assert_off_reader();
    let LineFrame { mux, client, message, writer, scheduler, arrival, watched } = *line;
    if head.is_resource()
        && let Some(keep_open) = resource_line(line, head)
    {
        return keep_open;
    }
    let stats = mux.request_stats();
    // A line whose `cmd` names no `Command` belongs to a feature route: its
    // span covers the route. A `Command` line opens its span at its handler.
    let mut routed = (!head.is_command()).then(|| head.open(stats, arrival));
    if let Some(route) = head.cmd().and_then(routes::find) {
        line.stage(route.stage);
        let route_line = routes::RouteLine { mux, client, message, writer, head };
        if let Some(keep_open) = request_hang_watch::route(head, || (route.entry)(&route_line)) {
            return match routed.as_mut() {
                Some(span) => span.answered(keep_open),
                None => keep_open,
            };
        }
    }
    line.stage(FrameStage::Route);
    let request = match crate::line_parses::parse::<Request>(message) {
        Ok(request) => request,
        Err(error) => {
            let mut span = routed.unwrap_or_else(|| head.open(stats, arrival));
            return span.reply(|| send_bad_request(writer, message, &error));
        }
    };
    // Only a `cmd` the table names parses as a `Command`
    // (command_names_tests), so no route span is open here; the line is
    // already on its sequence, so it runs here.
    drop(routed);
    if let Some(scope) = watched {
        scope.command(&request.cmd);
    }
    handle_request_with_cancellation(
        mux,
        client,
        request,
        RequestArrival::parsed_now(arrival.arrived),
        writer,
        Some(&scheduler.cancelled),
    )
}

/// A `cmux.protocol/2` line (its head has `protocol`). A routed namespace
/// operation (page-router-v1) is not in the operation catalog, so its line
/// goes to its operation route (server/routes.rs) without the catalog
/// parse; a line the route refuses gets the catalog parse's answer, as
/// every other v2 line.
/// `None` only when the resource router does not take the line.
fn resource_line(line: &LineFrame<'_>, head: &RequestHead<'_>) -> Option<bool> {
    let LineFrame { mux, client, message, writer, arrival, .. } = *line;
    let stats = mux.request_stats();
    let mut page_span = None;
    if let Some(route) = head.operation().and_then(routes::find_operation) {
        line.stage(route.stage);
        let mut span = head.open(stats, arrival);
        let route_line = routes::RouteLine { mux, client, message, writer, head };
        if let Some(keep_open) = request_hang_watch::route(head, || (route.entry)(&route_line)) {
            return Some(span.answered(keep_open));
        }
        page_span = Some(span);
    }
    let request = crate::resource_router::parse_resource_line(message)?;
    let _hang = match &request {
        Ok(envelope) => {
            line.watch(WatchedMethod::resource(envelope.operation));
            let class = RequestMethod::of_resource(envelope.operation).class;
            request_hang_watch::RequestHang::enter(class)
        }
        Err(_) => {
            line.stage(FrameStage::PageRouter);
            None
        }
    };
    // An envelope's `origin` claim may only narrow the cause, as it
    // only narrows the origin; the origin gate still checks the claim.
    // Its `priority` narrows the cause the same way and is never checked:
    // it cannot raise anything. The narrowed cause sets the class too: a
    // claimed or prioritized automation line runs at UTILITY here, as it
    // would on the dispatcher.
    let request_qos = mux.request_qos();
    let _narrowed = request.as_ref().ok().and_then(|envelope| {
        let claim = envelope.origin.as_ref().map(|claim| claim.claim.event_cause());
        let priority = envelope.priority.map(RequestPriority::event_cause);
        let narrowest = claim.into_iter().chain(priority).min()?;
        Some(request_qos.enter(EventCause::current().narrowed_by(narrowest)))
    });
    let mut span = match (page_span, &request) {
        (Some(span), _) => span,
        (None, Ok(envelope)) => RequestSpan::open_method(
            stats,
            RequestMethod::of_resource(envelope.operation),
            request_id_hash(Some(&envelope.id)),
            arrival,
        ),
        (None, Err(_)) => head.open(stats, arrival),
    };
    // Debug timing marks of a resource create, from the arrival of its
    // line to its reply (`CMUX_TUI_DEBUG_SPANS`; cx-b4sjc).
    let trace_label = request.as_ref().ok().and_then(|envelope| match envelope.operation {
        ResourceOperation::WorkspaceCreate => Some("resource:workspace.create"),
        ResourceOperation::TabCreateTerminal => Some("resource:tab.create_terminal"),
        ResourceOperation::PaneSplit => Some("resource:pane.split"),
        ResourceOperation::PaneCreate => Some("resource:pane.create"),
        ResourceOperation::WorkspaceEnsureHome => Some("resource:workspace.ensure_home"),
        _ => None,
    });
    let traced = trace_label
        .and_then(|label| crate::debug_spans::Trace::start(label, arrival.arrived))
        .is_some_and(|trace| {
            crate::debug_spans::install(Some(trace));
            true
        });
    let keep_open =
        origin_gate::handle_resource_line(mux, client, message, request, writer, &mut span);
    if traced {
        crate::debug_spans::mark("reply.sent");
        crate::debug_spans::finish(crate::debug_spans::take());
    }
    Some(span.answered(keep_open))
}

/// A request made in process (tests): it arrives as its handler starts.
#[cfg(test)]
pub(super) fn handle_request(
    mux: &Arc<Mux>,
    client: u64,
    request: Request,
    writer: &MessageWriter,
) -> bool {
    handle_request_with_cancellation(mux, client, request, RequestArrival::now(), writer, None)
}

pub(super) fn handle_request_with_cancellation(
    mux: &Arc<Mux>,
    client: u64,
    request: Request,
    arrival: RequestArrival,
    writer: &MessageWriter,
    cancellation: Option<&ConnectionCancellation>,
) -> bool {
    debug_assert_off_reader();
    let Request { id, cmd } = request;
    // Watched at its class deadline wherever it runs (a frame's scope, or
    // its own on a dispatcher or worker).
    let _hang = request_hang_watch::RequestHang::enter_command(&cmd);
    // A panic in the handler names its command (cmux-panic-log crash keys, this thread's own),
    // and so does a crash or abort: the process's crash-key page holds it until the handler returns.
    let method_key = cmux_panic_log::crash_keys::stable_key(cmd.wire_name());
    let _crash_key = cmux_panic_log::crash_keys::scoped_thread(
        cmux_panic_log::crash_keys::Key::ActionId,
        method_key,
    );
    let _crash_page_key = cmux_trace::crash_keys::request(method_key);
    let mut span = RequestSpan::open(mux.request_stats(), &cmd, id.as_ref(), arrival);
    if let Command::UrlOpen(terminal_io_wire::UrlOpenParams { terminal_id, url }) = cmd {
        return url_open::start(mux, client, id, terminal_id, url, span.start_async(), writer);
    }
    if let Command::ChiefInspect(params) = cmd {
        return chief_inspect::start(mux, client, id, params, span.start_async(), writer);
    }
    if sized_browser_attach(mux, &cmd) {
        return start_sized_browser_attach(mux, client, id, cmd, span.start_async(), writer);
    }
    // A remote client goes on to the relay gate, which refuses it.
    if matches!(cmd, Command::MachineListeningTcp) && !mux.is_remote_client(client) {
        return cmd_server::start_machine_listening_tcp(mux, id, span.start_async(), writer);
    }
    if cloud_conversations::is_network(&cmd) {
        return cloud_conversations::start(mux, client, id, cmd, span.start_async(), writer);
    }
    if let Some(target) = cloud_conversations::subscribe_target(mux, &cmd) {
        return cloud_conversations::subscribe_then_announce(
            mux, client, id, cmd, target, &mut span, writer,
        );
    }
    if matches!(&cmd, Command::ShutdownDaemon { .. } | Command::ReloadConfig)
        && !mux.server_lifecycle_ready()
    {
        return span.reply(|| send_request_error(writer, id, "server lifecycle is not ready"));
    }
    if let Command::VtState(terminal_io_wire::VtStateParams { surface }) = &cmd {
        let reply = vt_state_command_reply(mux, id.as_ref(), *surface, writer);
        return span.reply(|| {
            match reply.and_then(|text| Ok(writer.send_serialized_control(text)?)) {
                Ok(()) => true,
                Err(error) => send_request_error(writer, id, &error.to_string()),
            }
        });
    }

    if deferred_commands::handles(mux, client, &cmd) {
        return deferred_commands::start(mux, client, id, cmd, &mut span, writer);
    }

    let detach_self = match &cmd {
        Command::DetachClient { client: target, by, surface }
            if target.whole_client() == Some(client)
                && own_view_detach_target(mux, target, *surface).is_none() =>
        {
            Some(detach_actor(mux, client, by.clone()))
        }
        _ => None,
    };
    let shutdown_daemon = matches!(&cmd, Command::ShutdownDaemon { .. });
    let result = handle_command_with_cancellation(mux, client, cmd, writer, cancellation);
    let mut response_ok = false;
    let sent = span.reply(|| {
        let (ok, sent) = send_command_result(mux, client, id, result, writer);
        response_ok = ok;
        sent
    });
    // The reply is out; the request's registry commits (already in the WAL)
    // go to disk now, in one flush that none of them waited for.
    mux.request_registry_flush();
    // Flush the successful acknowledgement before making the owning loop
    // leave, so process teardown cannot race the response writer.
    if shutdown_daemon && response_ok {
        if sent {
            return complete_daemon_shutdown_after_ack(mux, client, writer);
        } else {
            mux.cancel_daemon_handoff(client);
        }
    }
    if let Some(by) = detach_self
        && response_ok
        && sent
    {
        kick_client(mux, client, by);
        return false;
    }
    sent
}

/// Whether `cmd` is an `attach-surface` with a size on a browser surface:
/// the browser host sizes the page before the attach answers.
fn sized_browser_attach(mux: &Mux, cmd: &Command) -> bool {
    matches!(
        cmd,
        Command::AttachSurface(terminal_io_wire::AttachSurfaceParams {
            surface: Some(surface),
            cols: Some(_),
            rows: Some(_),
            ..
        })
            if mux.surface(*surface).is_some_and(|surface| surface.kind() == SurfaceKind::Browser)
    )
}

/// A sized browser attach waits for the browser host's resize, another
/// process (up to `INITIAL_BROWSER_RESIZE_TIMEOUT`): a work item attaches
/// and answers, so this request thread answers the next line at once
/// (Chrome posts such a wait to a MayBlock task runner,
/// base/task/task_traits.h). Shutdown does not wait for it: the connection
/// closes anyway.
fn start_sized_browser_attach(
    mux: &Arc<Mux>,
    client: u64,
    id: Option<Value>,
    cmd: Command,
    reply: AsyncReply,
    writer: &MessageWriter,
) -> bool {
    let (worker_mux, worker_writer, worker_id) = (mux.clone(), writer.clone(), id.clone());
    let reply = reply.hand_to_worker();
    let posted = mux.work.post(
        Priority::UserBlocking,
        Lane::System,
        Shutdown::ContinueOnShutdown,
        move || {
            let reply = reply.start();
            let result =
                handle_command_with_cancellation(&worker_mux, client, cmd, &worker_writer, None);
            reply.reply(|| {
                send_command_result(&worker_mux, client, worker_id, result, &worker_writer).1
            });
        },
    );
    posted.is_ok() || send_request_error(writer, id, "the daemon is shutting down")
}

/// Answers request `id` with a command's `result`: whether it succeeded,
/// and whether the answer was queued.
fn send_command_result(
    mux: &Mux,
    client: u64,
    id: Option<Value>,
    result: anyhow::Result<Value>,
    writer: &MessageWriter,
) -> (bool, bool) {
    let (mut reason, mut retryable, mut details) = (None, None, None);
    let response = match result {
        Ok(data) => Response {
            id,
            ok: true,
            data: Some(data),
            error: None,
            error_code: None,
            error_delivery: None,
        },
        Err(error) => {
            reason = conversations::error_reason(&error)
                .or_else(|| cloud_conversations::error_reason(&error));
            retryable = cloud_conversations::error_retryable(&error);
            details = renderer_grant::error_details(&error)
                .or_else(|| conversations::error_details(&error));
            let error_code = response_error_code(&error);
            let error_delivery =
                error.downcast_ref::<DeliveryClassifiedError>().map(|error| error.delivery);
            Response {
                id,
                ok: false,
                data: None,
                error: Some(error.to_string()),
                error_code,
                error_delivery,
            }
        }
    };
    let (response, reason) = remote_relay::redact_response(mux, client, response, reason);
    let details = details.filter(|_| !mux.is_remote_client(client));
    let response_ok = response.ok;
    (
        response_ok,
        responses::send_response_with_details(writer, response, reason, retryable, details),
    )
}

/// The `vt-state` reply of `surface`, serialized and not yet queued.
fn vt_state_command_reply(
    mux: &Mux,
    id: Option<&Value>,
    surface: SurfaceId,
    writer: &MessageWriter,
) -> anyhow::Result<Arc<BudgetedText>> {
    // Reserve the entire wire-frame allowance before copying a replay or
    // starting its base64 encoder. The writer allocates only for actual
    // output and releases unused logical quota before the response is queued.
    let mut output = writer.render_service.reserved_control_writer()?;
    let surface = get_surface(mux, surface)?;
    require_pty(&surface)?;
    let (cols, rows, replay) = surface.try_with_terminal(|terminal| {
        terminal
            .vt_replay_bounded(crate::surface::VT_REPLAY_MAX_BYTES)
            .map(|replay| (terminal.cols(), terminal.rows(), replay))
    })??;

    write_vt_state_command_json(
        &mut output,
        id,
        cols,
        rows,
        &replay.self_contained_bytes(),
        &replay.kitty_image_aliases,
        replay.kitty_state,
    )?;
    Ok(output.finish())
}

pub(super) fn write_vt_state_command_json(
    output: &mut BudgetedJsonWriter,
    id: Option<&Value>,
    cols: u16,
    rows: u16,
    replay: &[u8],
    kitty_image_aliases: &[ghostty_vt::KittyImageAlias],
    kitty_state: KittyReplayState,
) -> std::io::Result<()> {
    output.write_all(b"{")?;
    if let Some(id) = id {
        output.write_all(b"\"id\":")?;
        serde_json::to_writer(&mut *output, id).map_err(json_error_to_io)?;
        output.write_all(b",")?;
    }
    write!(output, "\"ok\":true,\"data\":{{\"cols\":{cols},\"rows\":{rows},\"data\":\"")?;
    {
        let mut encoder = base64::write::EncoderWriter::new(
            &mut *output,
            &base64::engine::general_purpose::STANDARD,
        );
        encoder.write_all(replay)?;
        encoder.finish()?;
    }
    output.write_all(b"\",\"kitty_image_aliases\":")?;
    write_kitty_image_aliases_json(output, kitty_image_aliases)?;
    output.write_all(b",\"kitty_graphics_state\":")?;
    write_kitty_replay_state_json(output, kitty_state)?;
    output.write_all(b"}}")?;
    Ok(())
}

pub(super) fn auth_token(message: &str) -> Option<String> {
    let value: Value = crate::line_parses::parse(message).ok()?;
    let object = value.as_object()?;
    if object.len() != 1 {
        return None;
    }
    let auth = object.get("auth")?.as_object()?;
    if auth.len() != 1 {
        return None;
    }
    auth.get("token")?.as_str().map(str::to_string)
}

pub(super) fn pairing_request(message: &str) -> bool {
    let Ok(value) = crate::line_parses::parse::<Value>(message) else { return false };
    let Some(object) = value.as_object() else { return false };
    if object.len() != 1 {
        return false;
    }
    let Some(pair) = object.get("pair").and_then(Value::as_object) else { return false };
    pair.len() == 1 && pair.get("request").and_then(Value::as_bool) == Some(true)
}

pub(super) fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    let mut difference = a.len() ^ b.len();
    let length = a.len().max(b.len());
    for index in 0..length {
        difference |=
            usize::from(a.get(index).copied().unwrap_or(0) ^ b.get(index).copied().unwrap_or(0));
    }
    difference == 0
}

pub(super) fn zeroize_string(value: &mut str) {
    // NUL remains valid UTF-8, so decoded control frames can be cleared in
    // place immediately after dispatch.
    value.zeroize();
}

#[cfg(test)]
#[path = "event_cause_tests.rs"]
mod event_cause_tests;

#[cfg(test)]
#[path = "request_priority_tests.rs"]
mod request_priority_tests;

#[cfg(all(test, unix))]
mod dispatch_tests;

#[cfg(all(test, unix))]
mod dispatch_golden_tests;

#[cfg(test)]
pub(super) mod sequenced_lines_tests;

#[cfg(test)]
mod sequence_refusal_tests;
