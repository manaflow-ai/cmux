use std::io::{self, BufRead, BufReader, Read, Write};
#[cfg(unix)]
use std::net::Shutdown;
use std::path::Path;
use std::time::Duration;

use cmux_tui_core::platform::transport;
use cmux_tui_core::resource::{
    EnvelopeType, OperationClass, PROTOCOL, ResponseEnvelope, StreamEndEnvelope, StreamEndReason,
    StreamItemEnvelope,
};
use serde_json::{Value, json};

use super::command::{RequestPlan, WireOperation, random_prefixed};
use super::{GlobalArgs, OutputMode, UsageError};
use cmux_json::JsonSet as _;

const RESPONSE_LIMIT: usize = 16 * 1024 * 1024;
pub(super) const SERVER_PREFLIGHT_TIMEOUT: Duration = Duration::from_secs(2);
const SUPPORTED_SERVER_APP: &str = "cmux-tui";
/// The session-journal wire shape is compatible from its introduction through
/// the current protocol. Future protocol versions need an explicit review.
const SESSION_JOURNAL_PROTOCOL_MINIMUM: u64 =
    cmux_tui_core::server::SESSION_JOURNAL_PROTOCOL_VERSION as u64;
const SESSION_JOURNAL_PROTOCOL_MAXIMUM: u64 = cmux_tui_core::server::PROTOCOL_VERSION as u64;

/// Runs one request, healing a dropped connection: a request whose
/// connection failed is sent again on a new connection, with the same
/// idempotency key for a mutation, so the daemon replays it instead of running
/// it twice (plans/cmux-next/state-ownership.md, section 4). Streams are never
/// resent. `mutation.outcome_unknown` is printed only after the last try.
pub(super) fn run(global: GlobalArgs, mut plan: RequestPlan) -> i32 {
    if !plan.stream
        && plan.operation.class() == OperationClass::Mutation
        && plan.idempotency_key.is_none()
    {
        // One key for every try: a resend is the same mutation.
        match random_idempotency_key() {
            Ok(key) => plan.idempotency_key = Some(key),
            Err(error) => {
                eprintln!("cmux: {error}");
                return 2;
            }
        }
    }
    let mut tries = retry::Tries::new(&plan);
    loop {
        let code = run_once(&global, plan.clone(), &tries);
        if code != retry::AGAIN {
            return code;
        }
        tries.wait_before_next();
    }
}

fn run_once(global: &GlobalArgs, mut plan: RequestPlan, tries: &retry::Tries) -> i32 {
    if plan.stream && global.output == OutputMode::Json {
        return usage_failure(
            global.output,
            "cmux: streams require --jsonl, --quiet, or human output",
        );
    }
    if let Err(error) = super::resolve::apply_global_route(global, &mut plan) {
        return usage_failure(global.output, &format!("cmux: {error}"));
    }
    #[cfg(unix)]
    super::status::drop_caller_terminal_when_routed(global, &mut plan);
    if let Err(error) =
        super::command::git::localize_commit_paths(&plan.operation, &mut plan.params)
    {
        return usage_failure(global.output, &format!("cmux: {error}"));
    }
    let mut request = match request_value(&plan) {
        Ok(request) => request,
        Err(error) => return usage_failure(global.output, &format!("cmux: {error}")),
    };
    let mut encoded = match encode_request(&request) {
        Ok(encoded) => encoded,
        Err(code) => return code,
    };
    let request_id =
        request["id"].as_str().expect("locally built request IDs are strings").to_string();
    let key_report = KeyReport::new(request.get("idempotency_key").and_then(Value::as_str));

    let (socket, socket_is_derived) = match resolve_socket_or_report(global) {
        Ok(resolved) => resolved,
        Err(code) => return code,
    };
    let stream = match cmux_tui_core::server::connect_session_socket(&socket, socket_is_derived) {
        Ok(stream) => stream,
        Err(error) => {
            // An earlier try sent the request: its outcome is still unknown.
            if tries.sent_before() {
                eprintln!("transport closed before response");
                key_report.finish(global.output);
                return 3;
            }
            // Only this socket was tried; nothing falls back to another one.
            let error = json!({
                "code": "socket.unreachable",
                "message": connect_failure(&socket, &error),
                "details": {"socket": socket.display().to_string()},
                "retryable": false,
            });
            return print_local_error(&error, global.output, 3);
        }
    };
    let _ = stream.set_read_timeout(Some(SERVER_PREFLIGHT_TIMEOUT));
    let mut reader = BufReader::new(stream);
    if let Some(capability) = required_server_capability(&plan) {
        match require_server_capability(&mut reader, global, capability) {
            Ok(()) => {}
            Err(exit_code) => return exit_code,
        }
    }
    // Raw operation requests intentionally keep their private wire contract:
    // the first frame is the caller's request, so they cannot opt into the
    // public conversation-tab projection.
    if matches!(&plan.operation, WireOperation::Typed(_))
        && let Err(failure) = super::tab_capabilities::negotiate(&mut reader)
    {
        let reason = match &failure {
            super::resolve::Failure::Transport(message) => retry::Failure::from_read_error(message),
            super::resolve::Failure::Refused => retry::Failure::Dropped,
            _ => retry::Failure::Other,
        };
        if tries.may_retry_before_send(reason) {
            return retry::AGAIN;
        }
        let code = match failure {
            super::resolve::Failure::Resource(mut error) => {
                if matches!(global.output, OutputMode::Quiet | OutputMode::Human) {
                    localize_operation_error(&plan, &mut error);
                }
                print_operation_error(&error, global.output)
            }
            super::resolve::Failure::Refused => {
                transport_failure(global.output, "session.busy", hints::session_busy(), true)
            }
            failure => failure.report(global.output),
        };
        if tries.sent_before() {
            key_report.finish(global.output);
        }
        return code;
    }
    // The caller's terminal belongs to the session its environment names; an
    // explicit route targets that session's current workspace.
    let caller_route = global.socket.is_none() && global.session.is_none();
    // An agent's terminal with no place goes beside its chat (beside.rs).
    #[cfg(unix)]
    match super::beside::run_cli(
        global,
        &mut plan,
        &mut request,
        &mut reader,
        caller_route,
        &key_report,
    ) {
        Ok(Some(reencoded)) => encoded = reencoded,
        Ok(None) => {}
        Err(code) => return code,
    }
    if !plan.resolve.is_empty() {
        let route = super::resolve::SocketRoute::new(&socket, socket_is_derived, global);
        if let Err(failure) = super::resolve::apply(&mut reader, &mut plan, caller_route, &route) {
            // A browser tab's page zoom: the app hosts the page and owns it.
            #[cfg(unix)]
            if let super::resolve::Failure::AppAction { action, target } = &failure {
                let args = ["--target".to_owned(), target.clone()];
                return match super::app::run_action(action, &args, super::app::ActionName::Any) {
                    Ok(command) => super::app::run(global, command),
                    Err(error) => print_local_error(
                        &json!({"code":"usage.invalid","message":error.to_string(),"details":{},"retryable":false}),
                        global.output,
                        2,
                    ),
                };
            }
            return failure.report(global.output);
        }
        request.set("params", plan.params.clone());
        encoded = match encode_request(&request) {
            Ok(encoded) => encoded,
            Err(code) => return code,
        };
    }
    // A browser tab in a session a cmux app owns is the app's to render (after the lookups).
    #[cfg(unix)]
    if let Some(code) = super::frontend_browser::run_in_app(
        global,
        &plan,
        &request,
        &mut reader,
        &socket,
        caller_route,
        &key_report,
    ) {
        return code;
    }
    if notify_desktop::drop_unsupported(&mut reader, &socket, &mut request)
        | super::launch_credential::attach(&mut reader, &socket, &mut request)
        | list_order::apply(&mut plan, &mut request, &socket)
    {
        encoded = match encode_request(&request) {
            Ok(encoded) => encoded,
            Err(code) => return code,
        };
    }
    #[cfg(unix)]
    let interrupt_handled = !plan.stream || stream_interrupt(reader.get_ref().as_ref());
    #[cfg(not(unix))]
    let interrupt_handled = !plan.stream;
    let _ = reader.get_mut().set_read_timeout(response_read_timeout(&plan, interrupt_handled));
    if let Err(error) = reader.get_mut().write_all(&encoded).and_then(|_| {
        reader.get_mut().write_all(b"\n")?;
        reader.get_mut().flush()
    }) {
        if plan.stream && crate::shutdown_requested() {
            return 0;
        }
        if refused_at_connect(&mut reader, &error) {
            // A refused connection carried no request: nothing applied, so a
            // session that is busy for a moment gets the request again.
            if tries.may_retry(retry::Failure::Dropped) {
                return retry::AGAIN;
            }
            return transport_failure(global.output, "session.busy", hints::session_busy(), true);
        }
        if tries.may_retry(retry::Failure::Dropped) {
            return retry::AGAIN;
        }
        transport_failure(
            global.output,
            "transport.failed",
            &format!("transport error: {error}"),
            true,
        );
        // Part of the request may have reached the daemon.
        key_report.finish(global.output);
        return 3;
    }
    let code = run_response(&mut reader, global, &plan, &request_id, &key_report, tries, &socket);
    if code != 0 && code != retry::AGAIN {
        key_report.finish(global.output);
    }
    code
}

pub(super) fn encode_request(request: &Value) -> Result<Vec<u8>, i32> {
    super::resolve::encode_request_bytes(request).map_err(|error| {
        eprintln!("cmux: {error}");
        2
    })
}

/// Reports a mutation's idempotency key once when the command fails after
/// its request was sent, so `--idempotency-key` can retry it safely
/// (plans/cmux-next/state-ownership.md, section 4).
pub(super) struct KeyReport {
    key: Option<String>,
    done: std::cell::Cell<bool>,
}

impl KeyReport {
    pub(super) fn new(key: Option<&str>) -> Self {
        Self { key: key.map(str::to_owned), done: std::cell::Cell::new(false) }
    }

    /// Nothing to retry: the mutation succeeded, or the app never ran it.
    pub(super) fn succeeded(&self) {
        self.done.set(true);
    }

    /// Adds `details.idempotency_key` to an error the command prints in a
    /// JSON mode. Human modes print the note after the message instead.
    pub(super) fn annotate(&self, error: &mut Value, output: OutputMode) {
        let Some(key) = self.key.as_deref() else { return };
        if !matches!(output, OutputMode::Json | OutputMode::JsonLines) || !error.is_object() {
            return;
        }
        let details = &mut error["details"];
        if !details.is_object() {
            *details = json!({});
        }
        details
            .as_object_mut()
            .expect("details is an object")
            .entry("idempotency_key")
            .or_insert(Value::String(key.to_owned()));
        self.done.set(true);
    }

    /// Prints the key unless an annotated error or a success already did.
    pub(super) fn finish(&self, output: OutputMode) {
        let Some(key) = self.key.as_deref() else { return };
        if self.done.replace(true) {
            return;
        }
        let note =
            crate::localization::catalog().local_server.mutation_key_note.replace("{key}", key);
        match output {
            OutputMode::Json | OutputMode::JsonLines => {
                let error = json!({
                    "code": "mutation.outcome_unknown",
                    "message": note,
                    "details": {"idempotency_key": key},
                    "retryable": true,
                });
                let _ = serde_json::to_writer(io::stderr().lock(), &error);
                eprintln!();
            }
            OutputMode::Quiet | OutputMode::Human => eprintln!("{note}"),
        }
    }
}

/// Makes a stream end on SIGINT, SIGTERM or SIGHUP without a read timeout:
/// a watcher thread shuts the socket down, or, when that thread cannot
/// start, the signals get their default action back and end the process.
#[cfg(unix)]
fn stream_interrupt(stream: &dyn transport::Stream) -> bool {
    arm_signal_interrupt(stream) || crate::restore_default_termination_signals().is_ok()
}

#[cfg(unix)]
pub(super) fn arm_signal_interrupt(stream: &dyn transport::Stream) -> bool {
    let Ok(stream) = stream.try_clone_box() else { return false };
    std::thread::Builder::new()
        .name("cmux-cli-signal-interrupt".into())
        .spawn(move || {
            crate::wait_for_shutdown_signal();
            let _ = stream.shutdown(Shutdown::Both);
        })
        .is_ok()
}

fn required_server_capability(plan: &RequestPlan) -> Option<&'static str> {
    matches!(
        &plan.operation,
        WireOperation::Typed(
            cmux_tui_core::resource::ResourceOperation::SessionJournalSubscribe
                | cmux_tui_core::resource::ResourceOperation::SessionJournalProducerList
                | cmux_tui_core::resource::ResourceOperation::SessionJournalProducerPut
                | cmux_tui_core::resource::ResourceOperation::SessionJournalAppend
                | cmux_tui_core::resource::ResourceOperation::SessionJournalHookList
                | cmux_tui_core::resource::ResourceOperation::SessionJournalHookPut
                | cmux_tui_core::resource::ResourceOperation::SessionJournalCheckpointCreate
                | cmux_tui_core::resource::ResourceOperation::SessionJournalCheckpointList
                | cmux_tui_core::resource::ResourceOperation::SessionJournalRestorePreview
                | cmux_tui_core::resource::ResourceOperation::SessionJournalSegmentList
                | cmux_tui_core::resource::ResourceOperation::SessionJournalSegmentSeal
        )
    )
    .then_some(cmux_tui_core::server::SESSION_JOURNAL_CAPABILITY)
}

fn require_server_capability(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    global: &GlobalArgs,
    capability: &'static str,
) -> Result<(), i32> {
    let request_id = random_request_id().map_err(|error| {
        eprintln!("cmux: {error}");
        2
    })?;
    let request = json!({"id":request_id,"cmd":"identify"});
    let encoded = serde_json::to_vec(&request).map_err(|error| {
        eprintln!("cmux: cannot encode capability request: {error}");
        2
    })?;
    reader
        .get_mut()
        .write_all(&encoded)
        .and_then(|_| reader.get_mut().write_all(b"\n"))
        .and_then(|_| reader.get_mut().flush())
        .map_err(|error| {
            if refused_at_connect(reader, &error) {
                transport_failure(global.output, "session.busy", hints::session_busy(), true)
            } else {
                transport_failure(
                    global.output,
                    "transport.failed",
                    &format!("transport error while checking session capabilities: {error}"),
                    true,
                )
            }
        })?;
    let response = read_envelope(reader, false)
        .map_err(|error| {
            transport_failure(global.output, envelope_error_code(&error), &error, true)
        })?
        .ok_or_else(|| {
            transport_failure(
                global.output,
                "transport.closed",
                "transport closed before capability response",
                true,
            )
        })?;
    if response.get("type").and_then(Value::as_str) == Some("refused") {
        return Err(transport_failure(global.output, "session.busy", hints::session_busy(), true));
    }
    if response.get("id").and_then(Value::as_str) != Some(request_id.as_str())
        || response.get("ok").and_then(Value::as_bool) != Some(true)
    {
        return Err(protocol_failure(
            global.output,
            "protocol error: invalid identify response during capability negotiation",
        ));
    }
    let identity = response.get("data").unwrap_or(&Value::Null);
    if let Err(reason) = validate_capability_identity(identity) {
        return Err(protocol_failure(
            global.output,
            &format!(
                "protocol error: invalid identify response during capability negotiation: {reason}"
            ),
        ));
    }
    let supported = crate::session::parse_identity_capabilities(identity)
        .map(|capabilities| capabilities.contains(capability))
        .unwrap_or(false);
    if supported {
        return Ok(());
    }
    // The daemon's own CLI may serve it (another build): run that CLI
    // (cli/skew.rs), else name the exact fix.
    #[cfg(unix)]
    let fix = super::skew::reexec_at_dead_end(global).err().flatten();
    #[cfg(not(unix))]
    let fix: Option<String> = None;
    let mut message = crate::localization::catalog().skew.journal_unsupported.to_owned();
    if let Some(fix) = fix {
        message = format!("{message}\n{fix}");
    }
    let details = json!({
        "capability":capability,
        "action":"restart_session"
    });
    let error = json!({
        "code":"operation.unsupported",
        "message":message,
        "details":details,
        "retryable":false
    });
    Err(print_local_error(&error, global.output, 1))
}

fn validate_capability_identity(identity: &Value) -> Result<(), &'static str> {
    if identity.get("app").and_then(Value::as_str) != Some(SUPPORTED_SERVER_APP) {
        return Err("unexpected server app");
    }
    let Some(protocol) = identity.get("protocol").and_then(Value::as_u64) else {
        return Err("unsupported server protocol");
    };
    if !(SESSION_JOURNAL_PROTOCOL_MINIMUM..=SESSION_JOURNAL_PROTOCOL_MAXIMUM).contains(&protocol) {
        return Err("unsupported server protocol");
    }
    crate::session::parse_identity_capabilities(identity)?;
    Ok(())
}

/// `interrupt_handled` is false only for a stream on a platform with no
/// signal watcher (Windows): there a console interrupt only sets the
/// shutdown flag, so the read wakes every 250 ms to look at it.
pub(super) fn response_read_timeout(
    plan: &RequestPlan,
    interrupt_handled: bool,
) -> Option<Duration> {
    if plan.stream {
        return (!interrupt_handled).then_some(Duration::from_millis(250));
    }
    if matches!(
        &plan.operation,
        WireOperation::Typed(
            cmux_tui_core::resource::ResourceOperation::TerminalWait
                | cmux_tui_core::resource::ResourceOperation::TerminalWaitExit
        )
    ) {
        return plan
            .params
            .get("timeout_ms")
            .and_then(Value::as_str)
            .and_then(|value| value.parse::<u64>().ok())
            .map(Duration::from_millis)
            .and_then(|timeout| timeout.checked_add(Duration::from_secs(2)));
    }
    Some(Duration::from_secs(10))
}

pub(super) fn request_value(plan: &RequestPlan) -> Result<Value, UsageError> {
    let class = plan.operation.class();
    let mut request = json!({
        "protocol": PROTOCOL,
        "type": "request",
        "id": random_request_id()?,
        "operation": plan.operation.name()?,
        "params": plan.params,
    });
    match class {
        OperationClass::Mutation => {
            request.set(
                "idempotency_key",
                Value::String(
                    plan.idempotency_key.clone().map(Ok).unwrap_or_else(random_idempotency_key)?,
                ),
            );
        }
        _ if plan.idempotency_key.is_some() => {
            return Err(UsageError::new("only mutations may carry an idempotency key"));
        }
        _ => {}
    }
    Ok(request)
}

pub(super) fn random_request_id() -> Result<String, UsageError> {
    random_prefixed("request")
}

pub(super) fn random_idempotency_key() -> Result<String, UsageError> {
    random_prefixed("mutation")
}

fn run_response(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    global: &GlobalArgs,
    plan: &RequestPlan,
    request_id: &str,
    key_report: &KeyReport,
    tries: &retry::Tries,
    daemon_socket: &Path,
) -> i32 {
    #[cfg(not(unix))]
    let _ = daemon_socket;
    let mut accepted_stream = false;
    let expose_stream_lifecycle = matches!(
        &plan.operation,
        WireOperation::Typed(cmux_tui_core::resource::ResourceOperation::SessionJournalSubscribe)
    );
    let expected_stream_id = plan.params.get("stream_id").and_then(Value::as_str);
    loop {
        if plan.stream && crate::shutdown_requested() {
            return 0;
        }
        let value = match read_envelope(reader, plan.stream) {
            Ok(Some(value)) => value,
            Ok(None) if plan.stream && accepted_stream => return 0,
            Ok(None) => {
                if !accepted_stream && tries.may_retry(retry::Failure::Dropped) {
                    return retry::AGAIN;
                }
                return transport_failure(
                    global.output,
                    "transport.closed",
                    "transport closed before response",
                    true,
                );
            }
            Err(error) => {
                if plan.stream && crate::shutdown_requested() {
                    return 0;
                }
                if !accepted_stream && tries.may_retry(retry::Failure::from_read_error(&error)) {
                    return retry::AGAIN;
                }
                return transport_failure(global.output, envelope_error_code(&error), &error, true);
            }
        };
        match value.get("type").and_then(Value::as_str) {
            Some("response") => {
                let response: ResponseEnvelope = match serde_json::from_value(value.clone()) {
                    Ok(response) => response,
                    Err(error) => {
                        return protocol_failure(
                            global.output,
                            &format!("protocol error: invalid response envelope: {error}"),
                        );
                    }
                };
                if let Err(error) = response.validate() {
                    return protocol_failure(
                        global.output,
                        &format!("protocol error: {}", error.message),
                    );
                }
                if response.id.as_str() != request_id {
                    continue;
                }
                if !response.ok {
                    let mut error = serde_json::to_value(response.error.expect("validated error"))
                        .expect("resource errors serialize");
                    // A browser the cmux app draws: the app runs the verb.
                    #[cfg(unix)]
                    if let Some(routed) =
                        super::app_browser_route::run(global, plan, &error, daemon_socket)
                    {
                        return match routed {
                            Ok(result) => {
                                key_report.succeeded();
                                print_result(global, plan, result)
                            }
                            Err(mut error) => {
                                key_report.annotate(&mut error, global.output);
                                print_operation_error(&error, global.output)
                            }
                        };
                    }
                    if matches!(global.output, OutputMode::Quiet | OutputMode::Human) {
                        localize_operation_error(plan, &mut error);
                    }
                    key_report.annotate(&mut error, global.output);
                    if hints::settles_mutation(&error) {
                        key_report.succeeded();
                    }
                    return print_operation_error(&error, global.output);
                }
                let result = response.result.expect("validated result");
                key_report.succeeded();
                if !plan.stream {
                    // Focus in a session a cmux app owns is the app's (app_focus).
                    #[cfg(unix)]
                    let result = match &plan.operation {
                        WireOperation::Typed(operation) => {
                            match super::app_focus::after_daemon(global, *operation, result) {
                                Ok(result) => result,
                                Err(error) => return print_operation_error(&error, global.output),
                            }
                        }
                        WireOperation::Raw { .. } => result,
                    };
                    // The app's Cloud machines and the team's joined machines join the
                    // daemon's machine list.
                    #[cfg(unix)]
                    let result = match &plan.operation {
                        WireOperation::Typed(
                            cmux_tui_core::resource::ResourceOperation::MachineList,
                        ) => super::machine_join::merge(
                            global,
                            super::cloud_machines::merge(global, result),
                        ),
                        _ => result,
                    };
                    let result = agent_roster::with_terminals(reader, plan, result);
                    return super::agent_input_hint::print_result(global, plan, reader, result);
                }
                if result.get("stream_id").and_then(Value::as_str) != expected_stream_id {
                    return protocol_failure(
                        global.output,
                        "protocol error: stream response did not confirm the requested ID",
                    );
                }
                if expose_stream_lifecycle
                    && global.output == OutputMode::JsonLines
                    && let Err(error) = write_json_line(&value)
                {
                    eprintln!("stdout error: {error}");
                    return 3;
                }
                accepted_stream = true;
            }
            Some("stream_item") if plan.stream && accepted_stream => {
                let item: StreamItemEnvelope = match serde_json::from_value(value.clone()) {
                    Ok(item) => item,
                    Err(error) => {
                        return protocol_failure(
                            global.output,
                            &format!("protocol error: invalid stream item: {error}"),
                        );
                    }
                };
                if item.protocol != PROTOCOL
                    || item.envelope_type != EnvelopeType::StreamItem
                    || Some(item.stream_id.as_str()) != expected_stream_id
                {
                    return protocol_failure(
                        global.output,
                        "protocol error: stream item does not match the opened stream",
                    );
                }
                if let Err(error) = print_stream_item(&value, global.output) {
                    eprintln!("stdout error: {error}");
                    return 3;
                }
            }
            Some("stream_end") if plan.stream && accepted_stream => {
                let end: StreamEndEnvelope = match serde_json::from_value(value.clone()) {
                    Ok(end) => end,
                    Err(error) => {
                        return protocol_failure(
                            global.output,
                            &format!("protocol error: invalid stream end: {error}"),
                        );
                    }
                };
                if end.protocol != PROTOCOL
                    || end.envelope_type != EnvelopeType::StreamEnd
                    || Some(end.stream_id.as_str()) != expected_stream_id
                {
                    return protocol_failure(
                        global.output,
                        "protocol error: stream end does not match the opened stream",
                    );
                }
                if expose_stream_lifecycle
                    && global.output == OutputMode::JsonLines
                    && let Err(error) = write_json_line(&value)
                {
                    eprintln!("stdout error: {error}");
                    return 3;
                }
                if matches!(
                    end.reason,
                    StreamEndReason::Completed
                        | StreamEndReason::Canceled
                        | StreamEndReason::Closed
                ) {
                    return 0;
                }
                if let Some(error) = end.error {
                    let error = serde_json::to_value(error).expect("resource errors serialize");
                    return print_operation_error(&error, global.output);
                }
                let message = end.recovery.unwrap_or_else(|| "stream ended with an error".into());
                eprintln!("{}", sanitize_human_block(&message));
                return 1;
            }
            Some("refused") => {
                // Refused at the connection limit: the request never ran.
                if tries.may_retry(retry::Failure::Dropped) {
                    return retry::AGAIN;
                }
                return transport_failure(
                    global.output,
                    "session.busy",
                    hints::session_busy(),
                    true,
                );
            }
            // A cmux.protocol/2 envelope of a type this command does not
            // expect is not an older cmux: name the type.
            Some(other) if value.get("protocol").and_then(Value::as_str) == Some(PROTOCOL) => {
                return protocol_failure(
                    global.output,
                    &format!(
                        "protocol error: {}",
                        hints::unexpected_envelope(&sanitize_human_block(other))
                    ),
                );
            }
            _ => {
                return print_local_error(
                    &json!({
                        "code": "protocol.mismatch",
                        "message": format!("protocol error: {}", hints::wrong_protocol()),
                        "details": {},
                        "retryable": false,
                    }),
                    global.output,
                    3,
                );
            }
        }
    }
}

/// Whether a write that failed because the session closed the socket met
/// the refusal line a session at its connection limit sends before closing
/// (`type: "refused"`), so the error says "busy", not "broken pipe".
pub(super) fn refused_at_connect(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    error: &io::Error,
) -> bool {
    if !matches!(
        error.kind(),
        io::ErrorKind::BrokenPipe
            | io::ErrorKind::ConnectionReset
            | io::ErrorKind::ConnectionAborted
    ) {
        return false;
    }
    let _ = reader.get_mut().set_read_timeout(Some(Duration::from_millis(200)));
    let mut line = Vec::new();
    if reader.by_ref().take(4096).read_until(b'\n', &mut line).is_err() {
        return false;
    }
    serde_json::from_slice::<Value>(&line)
        .ok()
        .is_some_and(|value| value.get("type").and_then(Value::as_str) == Some("refused"))
}

pub(super) fn read_envelope(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    allow_timeout: bool,
) -> Result<Option<Value>, String> {
    loop {
        let mut bytes = Vec::new();
        match reader.by_ref().take((RESPONSE_LIMIT + 2) as u64).read_until(b'\n', &mut bytes) {
            Ok(0) => return Ok(None),
            Ok(_) => {}
            Err(error)
                if allow_timeout
                    && matches!(
                        error.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                    ) =>
            {
                if crate::shutdown_requested() {
                    return Ok(None);
                }
                continue;
            }
            Err(error) if hints::is_no_answer(&error) => return Err(hints::no_answer().into()),
            Err(error) => return Err(format!("transport error: {error}")),
        }
        if bytes.len() > RESPONSE_LIMIT {
            return Err("protocol error: response exceeds the 16 MiB limit".into());
        }
        if !bytes.ends_with(b"\n") {
            return Err("transport closed with a partial JSON line".into());
        }
        bytes.pop();
        if bytes.last() == Some(&b'\r') {
            bytes.pop();
        }
        return serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|error| format!("protocol error: invalid JSON response: {error}"));
    }
}

/// Prints a request's successful result as the command shows it; returns
/// the exit code.
pub(super) fn print_result(global: &GlobalArgs, plan: &RequestPlan, result: Value) -> i32 {
    let result = plan.view.project(result);
    let shown = match global.output {
        OutputMode::Human => human_view(plan, &result),
        output => agent_roster::machine_view(plan, &result, output),
    };
    let code = print_success(&shown, global.output);
    if code == 0 { success_exit_code(plan, &result) } else { code }
}

/// A printed result that exits 1: a `terminal <id> screen wait` timeout
/// (spec/commands.md) or an `agent message unsend` whose outcome is `failed`.
fn success_exit_code(plan: &RequestPlan, result: &Value) -> i32 {
    use cmux_tui_core::resource::ResourceOperation as Op;
    i32::from(match &plan.operation {
        WireOperation::Typed(Op::TerminalWait) => result["matched"] == false,
        WireOperation::Typed(Op::AgentMessageUnsend) => result["value"]["outcome"] == "failed",
        _ => false,
    })
}

/// What the human table shows for a result. `workspace list --order
/// personal` adds an ORDER column (the row's place in the returned order),
/// because INDEX stays the session order.
fn human_view<'a>(plan: &RequestPlan, result: &'a Value) -> std::borrow::Cow<'a, Value> {
    if let Some(roster) = agent_roster::human_view(plan, result) {
        return roster;
    }
    if matches!(
        &plan.operation,
        WireOperation::Typed(cmux_tui_core::resource::ResourceOperation::SettingsList)
    ) {
        return std::borrow::Cow::Owned(super::command::settings_human_rows(result));
    }
    let personal = matches!(
        &plan.operation,
        WireOperation::Typed(cmux_tui_core::resource::ResourceOperation::WorkspaceList)
    ) && plan.params.get("order").and_then(Value::as_str) == Some("personal");
    match result.as_array() {
        Some(rows) if personal => std::borrow::Cow::Owned(Value::Array(
            rows.iter()
                .enumerate()
                .map(|(order, row)| {
                    let mut row = row.clone();
                    if let Some(object) = row.as_object_mut() {
                        object.insert("order".into(), json!(order));
                    }
                    row
                })
                .collect(),
        )),
        Some(rows) if is_closed_list(plan) => std::borrow::Cow::Owned(closed_view::summarize(rows)),
        _ => std::borrow::Cow::Borrowed(result),
    }
}

fn is_closed_list(plan: &RequestPlan) -> bool {
    matches!(
        &plan.operation,
        WireOperation::Typed(cmux_tui_core::resource::ResourceOperation::ClosedList)
    )
}

pub(super) fn print_success(value: &Value, output: OutputMode) -> i32 {
    let result = match output {
        OutputMode::Quiet => Ok(()),
        OutputMode::Json => write_json_line(value),
        OutputMode::JsonLines => write_json_lines(value),
        OutputMode::Human => write_human(value),
    };
    match result {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("stdout error: {error}");
            3
        }
    }
}

pub(super) fn print_operation_error(error: &Value, output: OutputMode) -> i32 {
    print_local_error(error, output, 1)
}

fn localize_operation_error(plan: &RequestPlan, error: &mut Value) {
    localize_operation_error_with_catalog(plan, error, crate::localization::catalog());
}

fn localize_operation_error_with_catalog(
    plan: &RequestPlan,
    error: &mut Value,
    catalog: &crate::localization::Catalog,
) {
    if matches!(
        &plan.operation,
        WireOperation::Typed(
            cmux_tui_core::resource::ResourceOperation::TerminalInputWrite
                | cmux_tui_core::resource::ResourceOperation::TerminalInputKeys
                | cmux_tui_core::resource::ResourceOperation::TerminalInputMouse
                | cmux_tui_core::resource::ResourceOperation::TerminalInputFocus
        )
    ) && error["code"] == "operation.failed"
    {
        let message = match error["details"]["reason"].as_str() {
            Some("terminal_input_too_large") => Some(catalog.terminal_input.too_large),
            Some("terminal_input_unavailable") => Some(catalog.terminal_input.unavailable),
            Some("terminal_input_confirmation_unsupported") => {
                Some(catalog.terminal_input.confirmation_unsupported)
            }
            Some("terminal_input_delivery_failed") => Some(catalog.terminal_input.delivery_failed),
            _ => None,
        };
        if let Some(message) = message {
            error["message"] = Value::String(message.into());
        }
    }

    // A browser the cmux app draws, with no app method for the verb (or no
    // app owning the session): name the tab verbs that work.
    let extra = &error["details"]["extra"];
    if error["code"] == "operation.failed" && extra["code"] == "browser_rendered_by_app" {
        let tab = extra["tab_id"].as_str().unwrap_or("tab_…").to_owned();
        error["message"] = Value::String(catalog.browser.rendered_by_app.replace("{tab}", &tab));
    }

    let is_lifecycle_operation = matches!(
        &plan.operation,
        WireOperation::Typed(
            cmux_tui_core::resource::ResourceOperation::SessionShutdown
                | cmux_tui_core::resource::ResourceOperation::SessionReloadConfig
        )
    );
    if is_lifecycle_operation && error["code"] == "operation.failed" {
        let message = match error["details"]["reason"].as_str() {
            Some("lifecycle_not_ready") => Some(catalog.local_server.starting),
            Some("owner_stopped") => Some(catalog.local_server.reload_owner_stopped),
            _ => None,
        };
        if let Some(message) = message {
            error["message"] = Value::String(message.to_string());
        }
    }
}

/// A command this CLI cannot send as given: `usage.invalid`, exit code 2.
fn usage_failure(output: OutputMode, message: &str) -> i32 {
    print_local_error(
        &json!({"code": "usage.invalid", "message": message, "details": {}, "retryable": false}),
        output,
        2,
    )
}

/// A failure of the connection after the session was reached (it closed, did
/// not answer, refused or broke): one JSON error under `--json`, the message
/// alone for a person. Exit code 3, like every connection failure.
fn transport_failure(output: OutputMode, code: &str, message: &str, retryable: bool) -> i32 {
    print_local_error(
        &json!({"code": code, "message": message, "details": {}, "retryable": retryable}),
        output,
        3,
    )
}

/// A reply this command cannot read: `protocol.invalid`, not retryable.
fn protocol_failure(output: OutputMode, message: &str) -> i32 {
    print_local_error(
        &json!({"code": "protocol.invalid", "message": message, "details": {}, "retryable": false}),
        output,
        3,
    )
}

/// The error code of a [`read_envelope`] failure, from its message.
fn envelope_error_code(message: &str) -> &'static str {
    if message == hints::no_answer() {
        "session.no_answer"
    } else if message.starts_with("protocol error")
        || message.starts_with("transport closed with a partial")
    {
        "protocol.invalid"
    } else {
        "transport.failed"
    }
}

pub(super) fn print_local_error(error: &Value, output: OutputMode, exit_code: i32) -> i32 {
    match output {
        OutputMode::Json | OutputMode::JsonLines => {
            let _ = serde_json::to_writer(io::stderr().lock(), error);
            eprintln!();
        }
        OutputMode::Quiet | OutputMode::Human => {
            eprint!("{}", human_error_lines(error));
        }
    }
    exit_code
}

/// Render an operation error for human-readable stderr. The message and any
/// candidate names can carry remote-supplied text, so they get the same
/// visible sanitizing as human stdout.
fn human_error_lines(error: &Value) -> String {
    let message = error.get("message").and_then(Value::as_str).unwrap_or("operation failed");
    let mut text = sanitize_human_block(message);
    // cx-8mla8: an operation.failed message is only its reason ("internal");
    // the daemon's own words are in details.extra.message.
    let reason = error.pointer("/details/reason").and_then(Value::as_str);
    if reason == Some(message)
        && let Some(detail) = error
            .pointer("/details/extra/message")
            .and_then(Value::as_str)
            .filter(|d| !d.trim().is_empty())
    {
        text.push_str(": ");
        text.push_str(&sanitize_human_block(detail));
    }
    if let Some(id) = error.pointer("/details/extra/request_id").and_then(Value::as_str) {
        text.push_str(&format!(" (Request ID {})", sanitize_human_cell(id)));
    }
    text.push('\n');
    if let Some(candidates) =
        error.get("details").and_then(|details| details.get("candidates")).and_then(Value::as_array)
    {
        for candidate in candidates {
            if let Some(candidate) = candidate.as_str() {
                text.push_str("  ");
                text.push_str(&sanitize_human_cell(candidate));
                text.push('\n');
            }
        }
    }
    text
}

pub(super) fn print_local_success(value: &Value, output: OutputMode) -> i32 {
    print_success(value, output)
}

fn print_stream_item(value: &Value, output: OutputMode) -> io::Result<()> {
    match output {
        OutputMode::Quiet => Ok(()),
        OutputMode::Json | OutputMode::JsonLines => write_json_line(value),
        OutputMode::Human => write_human(value.get("item").unwrap_or(value)),
    }
}

fn write_json_line(value: &Value) -> io::Result<()> {
    let mut stdout = io::stdout().lock();
    serde_json::to_writer(&mut stdout, value).map_err(io::Error::other)?;
    stdout.write_all(b"\n")?;
    stdout.flush()
}

fn write_json_lines(value: &Value) -> io::Result<()> {
    if let Some(items) = value.as_array() {
        for item in items {
            write_json_line(item)?;
        }
        return Ok(());
    }
    if let Some(object) = value.as_object()
        && object.len() == 1
        && let Some(items) = object.values().next().and_then(Value::as_array)
    {
        for item in items {
            write_json_line(item)?;
        }
        return Ok(());
    }
    write_json_line(value)
}

mod agent_roster;
mod closed_view;
mod hints;
mod human;
mod list_order;
mod notify_desktop;
mod retry;
mod sanitize;
mod socket;
pub(super) use agent_roster::across as agent_roster_across;
pub(super) use hints::connect_failure;
#[cfg(test)]
use human::human_text;
use human::{append_table_row, human_cell, write_human};
use sanitize::{sanitize_human_block, sanitize_human_cell};

/// Remote-supplied error text made safe for a terminal (cx-8mla8: the chief
/// CLI shows a daemon's own words).
pub(in crate::cli) fn sanitize_remote_text(value: &str) -> String {
    sanitize_human_block(value)
}
#[cfg(unix)]
pub(super) use socket::resolve_failure_message;
#[cfg(test)]
pub(super) use socket::resolve_socket_with_env;
pub(super) use socket::resolve_socket_with_origin;
pub(super) use socket::{RESOLVE_FAILURE_EXIT, resolve_failure, resolve_socket_or_report};

#[cfg(test)]
mod tests;
