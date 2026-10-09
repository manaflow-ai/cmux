//! Resource-protocol waits: the bounded wait workers behind `terminal.wait`
//! (output pattern or exit) and the generic resource wait, their admission
//! guard, timeout and cancellation.

use super::MessageWriter;
use super::ResourceWaitCancellation;
use super::resource_terminal_surface;
use super::resource_wait_install_error;
use super::send_resource_response;
use crate::Mux;
use crate::resource::RequestId as ResourceRequestId;
use crate::resource::ResourceError;
use crate::resource::ResourceOperation;
use crate::resource::WireDecimal;
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
) -> Option<Duration> {
    request.fields.get("timeout_ms").map(|value| {
        Duration::from_millis(
            serde_json::from_value::<WireDecimal>(value.clone())
                .expect("catalog validates terminal wait timeout")
                .get(),
        )
    })
}

fn resource_wait_stopped(canceled: &ResourceWaitCancellation, writer: &MessageWriter) -> bool {
    canceled.is_canceled() || !writer.is_open()
}

fn run_terminal_resource_wait(
    mux: &Arc<Mux>,
    writer: &MessageWriter,
    request: &crate::resource_router::ParsedResourceRequest,
    canceled: &ResourceWaitCancellation,
) -> Result<Option<Value>, ResourceError> {
    let (_, surface) = resource_terminal_surface(mux, &request.selectors)?;
    let pattern = request.fields["pattern"].as_str().expect("catalog validates wait pattern");
    let regex = Regex::new(pattern).map_err(|_| {
        ResourceError::validation_invalid(
            None,
            "terminal wait pattern is not a valid regular expression",
        )
    })?;
    let timeout = resource_wait_timeout(request);
    let deadline = timeout
        .map(|timeout| {
            Instant::now().checked_add(timeout).ok_or_else(|| {
                ResourceError::validation_invalid(
                    Some("timeout_ms"),
                    "terminal wait timeout exceeds the platform deadline range",
                )
            })
        })
        .transpose()?;
    let check = || -> Result<String, ResourceError> {
        surface
            .try_with_terminal(|terminal| terminal.viewport_text())
            .map_err(resource_wait_runtime_error)?
            .map_err(resource_wait_runtime_error)
    };
    loop {
        if resource_wait_stopped(canceled, writer) {
            return Ok(None);
        }
        // Register every wake source before reading terminal state. Output,
        // cancellation, and connection close therefore share one blocking
        // primitive without a read/wait gap or an idle polling deadline.
        let subscription =
            surface.subscribe_terminal_stream_change().map_err(resource_wait_runtime_error)?;
        let wake = subscription.wake();
        canceled.register(&wake);
        writer.register_wait_wakeup(&wake);
        if resource_wait_stopped(canceled, writer) {
            return Ok(None);
        }
        let text = check()?;
        if regex.is_match(&text) {
            return Ok(Some(json!({"matched":true,"text":text})));
        }
        if timeout == Some(Duration::ZERO) {
            return Ok(Some(json!({"matched":false,"text":text})));
        }

        if !subscription.wait_until(deadline) {
            // Close the output/deadline race with one final authoritative
            // snapshot after the one deadline wake.
            let text = check()?;
            return Ok(Some(json!({
                "matched":regex.is_match(&text),
                "text":text,
            })));
        }
    }
}

fn run_terminal_resource_wait_exit(
    mux: &Arc<Mux>,
    writer: &MessageWriter,
    request: &crate::resource_router::ParsedResourceRequest,
    canceled: &ResourceWaitCancellation,
) -> Result<Option<Value>, ResourceError> {
    let terminal_id =
        crate::resource_router::resolve_terminal_wait_exit_id(mux, &request.selectors)?;
    let timeout = resource_wait_timeout(request);
    let deadline = timeout
        .map(|timeout| {
            Instant::now().checked_add(timeout).ok_or_else(|| {
                resource_wait_runtime_error(anyhow::anyhow!(
                    "terminal exit timeout exceeds deadline range"
                ))
            })
        })
        .transpose()?;
    if resource_wait_stopped(canceled, writer) {
        return Ok(None);
    }
    // Register every wake source before the initial query. A concurrent exit,
    // connection close, or client cleanup therefore cannot strand this wait.
    let subscription = mux.subscribe_terminal_exit(&terminal_id);
    let wake = subscription.wake();
    canceled.register(&wake);
    writer.register_wait_wakeup(&wake);
    if resource_wait_stopped(canceled, writer) {
        return Ok(None);
    }
    let state = mux.terminal_exit_state(&terminal_id).map_err(resource_wait_runtime_error)?;
    if state["state"] == "exited" || timeout == Some(Duration::ZERO) {
        return Ok(Some(state));
    }

    let _explicit_wake = subscription.wait_until(deadline);
    if resource_wait_stopped(canceled, writer) {
        return Ok(None);
    }
    mux.terminal_exit_state(&terminal_id).map(Some).map_err(resource_wait_runtime_error)
}

fn run_resource_wait(
    mux: &Arc<Mux>,
    writer: &MessageWriter,
    request: crate::resource_router::ParsedResourceRequest,
    canceled: &ResourceWaitCancellation,
) -> Option<Result<Value, ResourceError>> {
    if canceled.is_canceled() || !writer.is_open() {
        return None;
    }
    let result = match request.envelope.operation {
        ResourceOperation::TerminalWait => {
            run_terminal_resource_wait(mux, writer, &request, canceled)
        }
        ResourceOperation::TerminalWaitExit => {
            run_terminal_resource_wait_exit(mux, writer, &request, canceled)
        }
        _ => unreachable!("only terminal waits use the detached request path"),
    };
    match result {
        Ok(result) => result.map(Ok),
        Err(error) => Some(Err(error)),
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
        _ => unreachable!("only terminal waits use the detached request path"),
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
    let worker_writer = writer.clone();
    let worker_mux = mux.clone();
    let worker_canceled = canceled.clone();
    let worker_id = id.clone();
    let spawn =
        std::thread::Builder::new().name("mux-resource-terminal-wait".into()).spawn(move || {
            let _registration = ResourceWaitWorkerGuard {
                mux: worker_mux.clone(),
                client,
                request_id: worker_id.clone(),
                canceled: worker_canceled.clone(),
            };
            let _worker_permit = worker_permit;
            if let Some(result) =
                run_resource_wait(&worker_mux, &worker_writer, request, &worker_canceled)
                && _registration.claim_completion()
            {
                let _ = send_resource_response(&worker_writer, worker_id, operation, result);
                _registration.finish_response_attempt();
            }
        });
    match spawn {
        Ok(_) => true,
        Err(error) => {
            mux.control_clients.finish_resource_wait(client, &id, &canceled);
            send_resource_response(
                &writer,
                id,
                operation,
                Err(ResourceError::operation_failed(name, error.to_string(), json!({}))),
            )
        }
    }
}
