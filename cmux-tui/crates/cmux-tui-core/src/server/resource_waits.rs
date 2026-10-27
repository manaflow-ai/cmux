//! Resource-protocol waits: `terminal.wait` (an output pattern) and
//! `terminal.wait_exit`, their admission guard, timeout and cancellation.
//!
//! A wait holds no thread (p05-ipc-147). It is a drain on the mux's work
//! lanes (subscription_pump.rs) that checks the terminal once per wake: a
//! one-shot [`ResourceWaitWake`] that the terminal's output, its exit, the
//! wait's cancel and the connection's close notify, and the wait's deadline.
//! Each wake posts one turn; a turn that finds no answer re-arms and
//! returns. Chrome watches a condition with an observer that posts a task
//! (base/observer_list_threadsafe.h), not a thread blocked on it. It runs on
//! the Files lane: an exit wait reads the registry's terminal state.

use super::MessageWriter;
use super::ResourceWaitCancellation;
use super::ResourceWorkerPermit;
use super::resource_terminal_surface;
use super::resource_wait_install_error;
use super::send_resource_response;
use super::subscription_pump::{PumpWaker, SubscriptionDrain, SubscriptionPump};
use crate::Mux;
use crate::Surface;
use crate::mux::ResourceWaitWake;
use crate::panic_free::JsonFields;
use crate::resource::RequestId as ResourceRequestId;
use crate::resource::ResourceError;
use crate::resource::ResourceOperation;
use crate::resource::TerminalPublicId;
use crate::resource::WireDecimal;
use crate::resource_router::ParsedResourceRequest;
use crate::server::attach_lifecycle::attach_pump::Turn;
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
    request: &ParsedResourceRequest,
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

/// What a wait watches.
enum WaitTarget {
    /// `terminal.wait`: `regex` in the terminal's viewport.
    Output { surface: Arc<Surface>, regex: Regex },
    /// `terminal.wait_exit`.
    Exit { terminal_id: TerminalPublicId },
}

impl WaitTarget {
    fn resolve(
        mux: &Mux,
        request: &ParsedResourceRequest,
    ) -> Result<(Self, Option<Duration>), ResourceError> {
        match request.envelope.operation {
            ResourceOperation::TerminalWait => {
                let (_, surface) = resource_terminal_surface(mux, &request.selectors)?;
                let pattern = crate::resource_router::required_string(&request.fields, "pattern")?;
                let regex = Regex::new(pattern).map_err(|_| {
                    ResourceError::validation_invalid(
                        None,
                        "terminal wait pattern is not a valid regular expression",
                    )
                })?;
                Ok((Self::Output { surface, regex }, resource_wait_timeout(request)?))
            }
            ResourceOperation::TerminalWaitExit => {
                let terminal_id =
                    crate::resource_router::resolve_terminal_wait_exit_id(mux, &request.selectors)?;
                Ok((Self::Exit { terminal_id }, resource_wait_timeout(request)?))
            }
            operation => Err(super::wire_values::unrouted_operation("terminal wait", operation)),
        }
    }
}

/// The source a wake is registered on; dropped, it unregisters.
enum WakeSource {
    Output { surface: Arc<Surface>, waiter: u64 },
    Exit { mux: Arc<Mux>, terminal_id: TerminalPublicId, waiter: u64 },
}

impl Drop for WakeSource {
    fn drop(&mut self) {
        match self {
            Self::Output { surface, waiter } => surface.unwatch_terminal_stream_change(*waiter),
            Self::Exit { mux, terminal_id, waiter } => {
                mux.unwatch_terminal_exit(terminal_id, *waiter);
            }
        }
    }
}

/// One armed wake: its source, the wait's cancel and the connection's close
/// notify it once, and its notify posts the wait's next turn.
struct Armed {
    wake: Arc<ResourceWaitWake>,
    _source: WakeSource,
}

/// What the next turn of a wait found.
enum WaitStep {
    /// Nothing yet: a wake or the deadline runs the next turn.
    Pending,
    /// Canceled, or its connection closed: no answer.
    Stopped,
    Answer(Result<Value, ResourceError>),
}

/// One `terminal.wait` or `terminal.wait_exit` on its pump's sequence.
/// Dropped, it ends its registration and lets a cancel that waits for it
/// answer. Fields drop in order: the wake's registration ends before the
/// worker permit and the wait's registration do.
struct WaitDrain {
    armed: Option<Armed>,
    mux: Arc<Mux>,
    writer: MessageWriter,
    id: ResourceRequestId,
    operation: ResourceOperation,
    canceled: Arc<ResourceWaitCancellation>,
    registration: ResourceWaitWorkerGuard,
    _worker_permit: ResourceWorkerPermit,
    waker: PumpWaker,
    /// The request until the first turn resolves it.
    request: Option<ParsedResourceRequest>,
    target: Option<WaitTarget>,
    timeout: Option<Duration>,
    deadline: Option<Instant>,
}

impl SubscriptionDrain for WaitDrain {
    fn turn(&mut self) -> Turn {
        if resource_wait_stopped(&self.canceled, &self.writer) {
            return Turn::Done;
        }
        match self.step() {
            WaitStep::Pending => Turn::Idle,
            WaitStep::Stopped => Turn::Done,
            WaitStep::Answer(result) => {
                if self.registration.claim_completion() {
                    let _ = send_resource_response(
                        &self.writer,
                        self.id.clone(),
                        self.operation,
                        result,
                    );
                    self.registration.finish_response_attempt();
                }
                Turn::Done
            }
        }
    }
}

impl WaitDrain {
    fn step(&mut self) -> WaitStep {
        if let Some(request) = self.request.take() {
            match self.resolve(&request) {
                Ok(()) => {}
                Err(error) => return WaitStep::Answer(Err(error)),
            }
        }
        let expired = self.deadline.is_some_and(|deadline| Instant::now() >= deadline);
        let woken = self.armed.as_ref().is_none_or(|armed| armed.wake.is_notified());
        if !woken && !expired {
            return WaitStep::Pending;
        }
        match &self.target {
            Some(WaitTarget::Output { .. }) => self.output(expired),
            Some(WaitTarget::Exit { .. }) => self.exit(),
            None => WaitStep::Stopped,
        }
    }

    /// Resolves the request's terminal and starts the deadline.
    fn resolve(&mut self, request: &ParsedResourceRequest) -> Result<(), ResourceError> {
        let (target, timeout) = WaitTarget::resolve(&self.mux, request)?;
        if let Some(timeout) = timeout {
            let deadline = Instant::now().checked_add(timeout).ok_or_else(|| {
                ResourceError::validation_invalid(
                    Some("timeout_ms"),
                    "terminal wait timeout exceeds the platform deadline range",
                )
            })?;
            if !timeout.is_zero() {
                self.waker.wake_after(timeout);
            }
            self.deadline = Some(deadline);
        }
        self.target = Some(target);
        self.timeout = timeout;
        Ok(())
    }

    /// A wake registered on `source` and on every close of the wait. False
    /// when the wait stopped meanwhile.
    fn arm(&mut self, register: impl FnOnce(&Arc<ResourceWaitWake>) -> Option<WakeSource>) -> bool {
        // The previous wake's registration ends before the next one starts.
        self.armed = None;
        let waker = self.waker.clone();
        let wake = Arc::new(ResourceWaitWake::with_hook(move || waker.wake()));
        let Some(source) = register(&wake) else { return false };
        self.canceled.register(&wake);
        self.writer.register_wait_wakeup(&wake);
        self.armed = Some(Armed { wake, _source: source });
        !resource_wait_stopped(&self.canceled, &self.writer)
    }

    /// Registers before reading the viewport: output, cancellation and the
    /// connection's close share one wake with no read/wait gap.
    fn output(&mut self, expired: bool) -> WaitStep {
        let Some(WaitTarget::Output { surface, regex }) = &self.target else {
            return WaitStep::Stopped;
        };
        let (surface, regex) = (surface.clone(), regex.clone());
        if !expired {
            let mut registered = Ok(());
            let armed = self.arm(|wake| match surface.watch_terminal_stream_change(wake) {
                Ok(waiter) => Some(WakeSource::Output { surface: surface.clone(), waiter }),
                Err(error) => {
                    registered = Err(error);
                    None
                }
            });
            if let Err(error) = registered {
                return WaitStep::Answer(Err(resource_wait_runtime_error(error)));
            }
            if !armed {
                return WaitStep::Stopped;
            }
        }
        let text = match surface.try_with_terminal(|terminal| terminal.viewport_text()) {
            Ok(Ok(text)) => text,
            Ok(Err(error)) => return WaitStep::Answer(Err(resource_wait_runtime_error(error))),
            Err(error) => return WaitStep::Answer(Err(resource_wait_runtime_error(error))),
        };
        let matched = regex.is_match(&text);
        // The deadline's turn is the one final authoritative read.
        if matched || expired || self.timeout == Some(Duration::ZERO) {
            return WaitStep::Answer(Ok(json!({"matched":matched,"text":text})));
        }
        WaitStep::Pending
    }

    /// The first turn registers before the initial query, so a concurrent
    /// exit cannot strand it; the next wake (the exit, a close or the
    /// deadline) answers with the terminal's state.
    fn exit(&mut self) -> WaitStep {
        let Some(WaitTarget::Exit { terminal_id }) = &self.target else {
            return WaitStep::Stopped;
        };
        let terminal_id = terminal_id.clone();
        let first = self.armed.is_none();
        if first {
            let mux = self.mux.clone();
            let armed = self.arm(|wake| {
                let waiter = mux.watch_terminal_exit(&terminal_id, wake);
                Some(WakeSource::Exit {
                    mux: mux.clone(),
                    terminal_id: terminal_id.clone(),
                    waiter,
                })
            });
            if !armed {
                return WaitStep::Stopped;
            }
        }
        let state = match self.mux.terminal_exit_state(&terminal_id) {
            Ok(state) => state,
            Err(error) => return WaitStep::Answer(Err(resource_wait_runtime_error(error))),
        };
        if !first || state.field("state") == "exited" || self.timeout == Some(Duration::ZERO) {
            return WaitStep::Answer(Ok(state));
        }
        WaitStep::Pending
    }
}

pub(super) fn start_resource_wait(
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
    request: ParsedResourceRequest,
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
    let pump = SubscriptionPump::new(&mux);
    let drain = WaitDrain {
        armed: None,
        mux: mux.clone(),
        writer: writer.clone(),
        id: id.clone(),
        operation,
        canceled: canceled.clone(),
        registration: ResourceWaitWorkerGuard {
            mux: mux.clone(),
            client,
            request_id: id.clone(),
            canceled: canceled.clone(),
        },
        _worker_permit: worker_permit,
        waker: pump.waker(),
        request: Some(request),
        target: None,
        timeout: None,
        deadline: None,
    };
    match pump.start(Box::new(drain)) {
        Ok(()) => true,
        Err(_) => {
            mux.control_clients.finish_resource_wait(client, &id, &canceled);
            send_resource_response(
                &writer,
                id,
                operation,
                Err(ResourceError::operation_failed(
                    name,
                    "the daemon is shutting down",
                    json!({}),
                )),
            )
        }
    }
}
