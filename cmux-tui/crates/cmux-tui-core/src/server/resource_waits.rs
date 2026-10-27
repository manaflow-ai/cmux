//! Resource-protocol waits: the bounded wait observers behind
//! `terminal.wait` (output pattern or exit) and the generic resource wait,
//! their admission guard, timeout and cancellation. Each is a drain on the
//! sequenced pool, not a thread.

use super::MessageWriter;
use super::ResourceWaitCancellation;
use super::ResourceWorkerPermit;
use super::attach_lifecycle::attach_pump::{AttachDrain, AttachPump, PumpTimer, Turn};
use super::resource_pump::{ReadyWake, watched_priority};
use super::resource_terminal_surface;
use super::resource_wait_install_error;
use super::send_resource_response;
use crate::Mux;
use crate::mux::{ResourceWaitWake, TerminalExitWatch};
use crate::panic_free::JsonFields;
use crate::resource::RequestId as ResourceRequestId;
use crate::resource::ResourceError;
use crate::resource::ResourceOperation;
use crate::resource::TerminalPublicId;
use crate::resource::WireDecimal;
use crate::surface::TerminalStreamWatch;
use regex::Regex;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;
use std::time::Duration;
use std::time::Instant;

struct ResourceWaitWorkerGuard {
    mux: Arc<Mux>,
    client: u64,
    request_id: ResourceRequestId,
    canceled: Arc<ResourceWaitCancellation>,
}

impl ResourceWaitWorkerGuard {
    fn claim_completion(&self) -> bool {
        self.mux.control_clients.begin_resource_wait_completion(
            self.client,
            &self.request_id,
            &self.canceled,
        )
    }

    fn finish_response_attempt(&self) {
        self.canceled.mark_response_attempted();
        let _ = self.mux.control_clients.finish_resource_wait(
            self.client,
            &self.request_id,
            &self.canceled,
        );
    }
}

impl Drop for ResourceWaitWorkerGuard {
    fn drop(&mut self) {
        let _ = self.mux.control_clients.finish_resource_wait(
            self.client,
            &self.request_id,
            &self.canceled,
        );
        self.canceled.mark_worker_finished();
    }
}

fn resource_wait_runtime_error(error: impl Into<anyhow::Error>) -> ResourceError {
    crate::resource_router::resource_operation_error(error.into())
}

fn resource_wait_timeout(
    request: &crate::resource_router::ParsedResourceRequest,
) -> Result<Option<Duration>, ResourceError> {
    request
        .fields
        .get("timeout_ms")
        .map(|value| {
            serde_json::from_value::<WireDecimal>(value.clone())
                .map(|millis| Duration::from_millis(millis.get()))
                .map_err(|_| {
                    ResourceError::validation_invalid(
                        Some("timeout_ms"),
                        "terminal wait timeout must be a decimal millisecond count",
                    )
                })
        })
        .transpose()
}

fn resource_wait_stopped(canceled: &ResourceWaitCancellation, writer: &MessageWriter) -> bool {
    canceled.is_canceled() || !writer.is_open()
}

/// What a wait's turn found.
enum WaitPoll {
    /// Nothing decided: a wake source or the deadline posts the next turn.
    Pending,
    /// The wait ended: its result, or `None` when it was canceled or its
    /// connection closed (no response).
    Done(Option<Result<Value, ResourceError>>),
}

impl WaitPoll {
    fn of(result: Result<Option<Value>, ResourceError>) -> Self {
        Self::Done(result.transpose())
    }
}

/// What every turn of a wait needs to arm its wakes.
struct WaitContext<'a> {
    writer: &'a MessageWriter,
    canceled: &'a ResourceWaitCancellation,
    hook: &'a ReadyWake,
    timer: &'a PumpTimer<'a>,
}

impl WaitContext<'_> {
    fn stopped(&self) -> bool {
        resource_wait_stopped(self.canceled, self.writer)
    }

    /// A one-shot wake that posts the wait's next turn, notified by
    /// cancellation and by the connection's close as well; every source
    /// holds it weakly, so the wait keeps it in its watch.
    fn wake(&self) -> Arc<ResourceWaitWake> {
        let wake = Arc::new(ResourceWaitWake::default());
        let hook = self.hook.clone();
        wake.on_notify(move || hook());
        self.canceled.register(&wake);
        self.writer.register_wait_wakeup(&wake);
        wake
    }

    /// A turn at `deadline`, armed once: the only timed wake of a wait.
    fn arm(&self, deadline: Option<Instant>, armed: &mut bool) {
        if *armed {
            return;
        }
        *armed = true;
        if let Some(deadline) = deadline {
            self.timer.wake_after(deadline.saturating_duration_since(Instant::now()));
        }
    }
}

fn wait_deadline(
    timeout: Option<Duration>,
    out_of_range: impl FnOnce() -> ResourceError,
) -> Result<Option<Instant>, ResourceError> {
    timeout.map(|timeout| Instant::now().checked_add(timeout).ok_or_else(out_of_range)).transpose()
}

/// `terminal.wait`: the viewport matching a pattern.
struct OutputWait {
    surface: Arc<crate::Surface>,
    regex: Regex,
    timeout: Option<Duration>,
    deadline: Option<Instant>,
    armed: bool,
    /// The stream-change registration of the last read, replaced each turn.
    watch: Option<TerminalStreamWatch>,
}

impl OutputWait {
    fn new(
        mux: &Mux,
        request: &crate::resource_router::ParsedResourceRequest,
    ) -> Result<Self, ResourceError> {
        let (_, surface) = resource_terminal_surface(mux, &request.selectors)?;
        let pattern = crate::resource_router::required_string(&request.fields, "pattern")?;
        let regex = Regex::new(pattern).map_err(|_| {
            ResourceError::validation_invalid(
                None,
                "terminal wait pattern is not a valid regular expression",
            )
        })?;
        let timeout = resource_wait_timeout(request)?;
        let deadline = wait_deadline(timeout, || {
            ResourceError::validation_invalid(
                Some("timeout_ms"),
                "terminal wait timeout exceeds the platform deadline range",
            )
        })?;
        Ok(Self { surface, regex, timeout, deadline, armed: false, watch: None })
    }

    fn poll(&mut self, context: &WaitContext<'_>) -> WaitPoll {
        // Register every wake source before reading terminal state. Output,
        // cancellation and connection close therefore share one wake without
        // a read/wait gap or an idle polling deadline.
        let wake = context.wake();
        let watch = match self.surface.watch_terminal_stream_change(wake) {
            Ok(watch) => watch,
            Err(error) => return WaitPoll::of(Err(resource_wait_runtime_error(error))),
        };
        if context.stopped() {
            return WaitPoll::Done(None);
        }
        let text = match self
            .surface
            .try_with_terminal(|terminal| terminal.viewport_text())
            .map_err(resource_wait_runtime_error)
            .and_then(|text| text.map_err(resource_wait_runtime_error))
        {
            Ok(text) => text,
            Err(error) => return WaitPoll::of(Err(error)),
        };
        let matched = self.regex.is_match(&text);
        // A read at or after the deadline is the final one.
        if matched
            || self.timeout == Some(Duration::ZERO)
            || self.deadline.is_some_and(|deadline| Instant::now() >= deadline)
        {
            return WaitPoll::of(Ok(Some(json!({"matched":matched,"text":text}))));
        }
        self.watch = Some(watch);
        context.arm(self.deadline, &mut self.armed);
        WaitPoll::Pending
    }
}

/// `terminal.wait_exit`: the terminal's exit.
struct ExitWait {
    terminal_id: TerminalPublicId,
    timeout: Option<Duration>,
    deadline: Option<Instant>,
    armed: bool,
    /// Set by the first turn: a later turn is the one wake it waits for.
    watch: Option<TerminalExitWatch>,
}

impl ExitWait {
    fn new(
        mux: &Mux,
        request: &crate::resource_router::ParsedResourceRequest,
    ) -> Result<Self, ResourceError> {
        let terminal_id =
            crate::resource_router::resolve_terminal_wait_exit_id(mux, &request.selectors)?;
        let timeout = resource_wait_timeout(request)?;
        let deadline = wait_deadline(timeout, || {
            resource_wait_runtime_error(anyhow::anyhow!(
                "terminal exit timeout exceeds deadline range"
            ))
        })?;
        Ok(Self { terminal_id, timeout, deadline, armed: false, watch: None })
    }

    fn poll(&mut self, mux: &Arc<Mux>, context: &WaitContext<'_>) -> WaitPoll {
        if self.watch.is_some() {
            // An exit, a cancel, a close or the deadline woke it: one
            // targeted read closes the notification or deadline race.
            return WaitPoll::of(
                mux.terminal_exit_state(&self.terminal_id)
                    .map(Some)
                    .map_err(resource_wait_runtime_error),
            );
        }
        // Register every wake source before the initial query. A concurrent
        // exit, connection close or client cleanup cannot strand this wait.
        let wake = context.wake();
        let watch = mux.watch_terminal_exit(&self.terminal_id, wake);
        if context.stopped() {
            return WaitPoll::Done(None);
        }
        let state = match mux.terminal_exit_state(&self.terminal_id) {
            Ok(state) => state,
            Err(error) => return WaitPoll::of(Err(resource_wait_runtime_error(error))),
        };
        if state.field("state") == "exited" || self.timeout == Some(Duration::ZERO) {
            return WaitPoll::of(Ok(Some(state)));
        }
        self.watch = Some(watch);
        context.arm(self.deadline, &mut self.armed);
        WaitPoll::Pending
    }
}

enum WaitState {
    /// Not validated yet: its first turn does, on the pool.
    Start(Box<crate::resource_router::ParsedResourceRequest>),
    Output(OutputWait),
    Exit(ExitWait),
}

/// A detached terminal wait as an observer on the sequenced pool
/// (p01-process-204), not a `mux-resource-terminal-wait` thread blocked for
/// as long as the wait lasts: each turn registers its wakes, reads the
/// terminal and returns; output, the exit, cancellation, the connection's
/// close and the one deadline post the next turn.
///
/// Fields drop in declaration order: the wait's watches and its worker
/// permit go before `registration`, whose drop reports the wait finished.
struct TerminalWaitDrain {
    state: WaitState,
    _worker_permit: ResourceWorkerPermit,
    hook: ReadyWake,
    writer: MessageWriter,
    operation: ResourceOperation,
    registration: ResourceWaitWorkerGuard,
}

impl TerminalWaitDrain {
    fn poll(&mut self, timer: &PumpTimer<'_>) -> WaitPoll {
        let mux = self.registration.mux.clone();
        let context = WaitContext {
            writer: &self.writer,
            canceled: &self.registration.canceled,
            hook: &self.hook,
            timer,
        };
        if context.stopped() {
            return WaitPoll::Done(None);
        }
        if let WaitState::Start(request) = &self.state {
            let state = match self.operation {
                ResourceOperation::TerminalWait => {
                    OutputWait::new(&mux, request).map(WaitState::Output)
                }
                ResourceOperation::TerminalWaitExit => {
                    ExitWait::new(&mux, request).map(WaitState::Exit)
                }
                operation => {
                    Err(super::wire_values::unrouted_operation("terminal wait", operation))
                }
            };
            match state {
                Ok(state) => self.state = state,
                Err(error) => return WaitPoll::Done(Some(Err(error))),
            }
        }
        match &mut self.state {
            WaitState::Start(_) => WaitPoll::Done(None),
            WaitState::Output(wait) => wait.poll(&context),
            WaitState::Exit(wait) => wait.poll(&mux, &context),
        }
    }
}

impl AttachDrain for TerminalWaitDrain {
    fn turn(&mut self, timer: &PumpTimer<'_>) -> Turn {
        let WaitPoll::Done(result) = self.poll(timer) else { return Turn::Idle };
        if let Some(result) = result
            && self.registration.claim_completion()
        {
            let id = self.registration.request_id.clone();
            let _ = send_resource_response(&self.writer, id, self.operation, result);
            self.registration.finish_response_attempt();
        }
        Turn::Done
    }
}

pub(super) fn start_resource_wait(
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
    request: crate::resource_router::ParsedResourceRequest,
    id: crate::resource::RequestId,
) -> bool {
    let operation = request.envelope.operation;
    let name = match operation {
        ResourceOperation::TerminalWait => "terminal.wait",
        ResourceOperation::TerminalWaitExit => "terminal.wait_exit",
        operation => {
            return send_resource_response(
                &writer,
                id,
                operation,
                Err(super::wire_values::unrouted_operation("terminal wait", operation)),
            );
        }
    };
    let (canceled, worker_permit) = match mux.control_clients.install_resource_wait(client, &id) {
        Ok(installed) => installed,
        Err(error) => {
            return send_resource_response(
                &writer,
                id,
                operation,
                Err(resource_wait_install_error(name, error)),
            );
        }
    };
    // Off the echo path and off the control workers a `request.cancel` may
    // wait on while this wait ends; a person's wait at the request class,
    // as its helper thread ran.
    let response_id = id.clone();
    let pump = AttachPump::new(&mux.sequenced_pool, watched_priority(&mux));
    pump.install(Box::new(TerminalWaitDrain {
        state: WaitState::Start(Box::new(request)),
        _worker_permit: worker_permit,
        hook: Arc::new(pump.hook()),
        writer: writer.clone(),
        operation,
        registration: ResourceWaitWorkerGuard { mux, client, request_id: id, canceled },
    }));
    // A refused start drops the drain, whose registration releases the wait.
    match pump.start() {
        Ok(()) => true,
        Err(error) => send_resource_response(
            &writer,
            response_id,
            operation,
            Err(ResourceError::operation_failed(name, error.to_string(), json!({}))),
        ),
    }
}
