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

use super::command::{RequestPlan, ResponseView, WireOperation, random_prefixed};
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
<<<<<<< ours
    // `--machine <Cloud VM>`: the whole request goes to the VM's daemon over the app's link
    // (cloud_route.rs); the local daemon has no such machine.
    #[cfg(unix)]
    let global = match super::cloud_route::route(&global, &plan) {
        Some(super::cloud_route::Route::Link { socket, .. }) => {
            super::cloud_route::routed(&global, &socket)
        }
        Some(super::cloud_route::Route::Refused(error)) => {
            return print_local_error(&error, global.output, 1);
        }
        Some(super::cloud_route::Route::Local) | None => global,
=======
    if plan.stream && global.output == OutputMode::Json {
        eprintln!(
            "{}: streams require --jsonl, --quiet, or human output",
            crate::cli::program_name()
        );
        return 2;
    }
    let Some(params) = plan.params.as_object_mut() else {
        eprintln!("{}: request params are not an object", crate::cli::program_name());
        return 2;
>>>>>>> theirs
    };
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
    if plan.stream
        && let Some(code) = super::stream_output::refuse_json(global.output)
    {
        return code;
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
<<<<<<< ours
        Err(error) => return usage_failure(global.output, &format!("cmux: {error}")),
=======
        Err(error) => {
            eprintln!("{}: {error}", crate::cli::program_name());
            return 2;
        }
>>>>>>> theirs
    };
<<<<<<< ours
    let mut encoded = match encode_request(&request) {
        Ok(encoded) => encoded,
        Err(code) => return code,
=======
    let encoded = match serde_json::to_vec(&request) {
        Ok(encoded) if encoded.len() <= MAX_MESSAGE_BYTES => encoded,
        Ok(_) => {
            eprintln!("{}: request exceeds the 4 MiB protocol limit", crate::cli::program_name());
            return 2;
        }
        Err(error) => {
            eprintln!("{}: cannot encode request: {error}", crate::cli::program_name());
            return 2;
        }
>>>>>>> theirs
    };
    let request_id =
        request["id"].as_str().expect("locally built request IDs are strings").to_string();
    let key_report = KeyReport::new(request.get("idempotency_key").and_then(Value::as_str));

    let (socket, socket_is_derived) = match resolve_socket_or_report(global) {
        Ok(resolved) => resolved,
<<<<<<< ours
        Err(code) => return code,
=======
        Err(_) => {
            eprintln!(
                "{}: {}",
                crate::cli::program_name(),
                crate::localization::catalog().startup.invalid_session_name
            );
            return 2;
        }
>>>>>>> theirs
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
            return report_connect_failure(&socket, &error, global.output);
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
    let caller_route = routes_to_caller_session(global);
    // An agent's terminal with no place goes beside its chat (beside.rs).
    #[cfg(unix)]
    match super::beside::run_cli(
        global,
        &mut plan,
        &mut request,
        &mut reader,
        &socket,
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
        | created_by_stamp::stamp(&mut request)
        | created_by_stamp::drop_unsupported(&mut reader, &socket, &mut request)
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

/// Send one non-stream request and return its result, or the error as JSON
/// (`{code, message}`; a daemon error as the daemon wrote it), for a client
/// command that reads or chains requests instead of printing one result
/// (`cli/attention.rs`). Routing and session injection match [`run`].
pub(super) fn fetch(global: &GlobalArgs, mut plan: RequestPlan) -> Result<Value, Value> {
    let local = |code: &str, message: String| json!({"code": code, "message": message});
    if let Some(params) = plan.params.as_object_mut() {
        if let Some(machine) = &global.machine
            && params.get("machine").is_none_or(|value| value.as_str() == Some("current"))
        {
            params.insert("machine".into(), Value::String(machine.clone()));
        }
        if let Some(session) = &global.session
            && params.get("session").is_none_or(|value| value.as_str() == Some("current"))
        {
            params.insert("session".into(), Value::String(session.clone()));
        }
    }
    let request = request_value(&plan).map_err(|error| local("usage.invalid", error.0))?;
    let request_id = request
        .get("id")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| local("internal", "request has no id".into()))?;
    let encoded = serde_json::to_vec(&request)
        .map_err(|error| local("internal", format!("cannot encode request: {error}")))?;
    let (socket, socket_is_derived) = resolve_socket_with_origin(global).map_err(|_| {
        local(
            "usage.invalid",
            crate::localization::catalog().startup.invalid_session_name.to_string(),
        )
    })?;
    let stream = cmux_tui_core::server::connect_session_socket(&socket, socket_is_derived)
        .map_err(|error| {
            local(
                "transport.unavailable",
                format!("cannot connect to session socket {}: {error}", socket.display()),
            )
        })?;
    let mut reader = BufReader::new(stream);
    let _ = reader.get_mut().set_read_timeout(response_read_timeout(&plan, false));
    reader
        .get_mut()
        .write_all(&encoded)
        .and_then(|()| reader.get_mut().write_all(b"\n"))
        .and_then(|()| reader.get_mut().flush())
        .map_err(|error| local("transport.failed", format!("transport error: {error}")))?;
    loop {
        let value = read_envelope(&mut reader, false)
            .map_err(|error| local("transport.failed", error))?
            .ok_or_else(|| local("transport.failed", "transport closed before response".into()))?;
        if value.get("type").and_then(Value::as_str) != Some("response") {
            continue;
        }
        let response: ResponseEnvelope = serde_json::from_value(value).map_err(|error| {
            local("protocol.invalid", format!("invalid response envelope: {error}"))
        })?;
        response.validate().map_err(|error| local("protocol.invalid", error.message))?;
        if response.id.as_str() != request_id {
            continue;
        }
        return match (response.ok, response.result, response.error) {
            (true, Some(result), _) => Ok(result),
            (_, _, Some(error)) => Err(serde_json::to_value(error)
                .unwrap_or_else(|_| local("internal", "unreadable error".into()))),
            _ => Err(local("protocol.invalid", "response has no result".into())),
        };
    }
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
        eprintln!("{}: {error}", crate::cli::program_name());
        2
    })?;
    let request = json!({"id":request_id,"cmd":"identify"});
    let encoded = serde_json::to_vec(&request).map_err(|error| {
        eprintln!("{}: cannot encode capability request: {error}", crate::cli::program_name());
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
    // The user's git actions run under a 120 s deadline, and a worktree
    // removal runs its project's teardown (at most a minute) first.
    if matches!(
        &plan.operation,
        WireOperation::Typed(
            cmux_tui_core::resource::ResourceOperation::GitCommit
                | cmux_tui_core::resource::ResourceOperation::GitPush
                | cmux_tui_core::resource::ResourceOperation::GitWorktreeCreate
                | cmux_tui_core::resource::ResourceOperation::GitWorktreeApply
                | cmux_tui_core::resource::ResourceOperation::GitWorktreeRemove
                | cmux_tui_core::resource::ResourceOperation::GitReviewStart
                | cmux_tui_core::resource::ResourceOperation::GitReviewComment
        )
    ) {
        return Some(Duration::from_secs(200));
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
                    // `--machine <Cloud machine> workspace list`: the app lists its workspaces.
                    #[cfg(unix)]
                    if let Some(listed) = super::cloud_workspaces::for_machine(global, plan, &error)
                    {
                        let listed = listed.and_then(|rows| list_filter::apply_listed(plan, rows));
                        return match listed {
                            Ok(result) => {
                                key_report.succeeded();
                                print_result(global, plan, result)
                            }
                            Err(error) => print_operation_error(&error, global.output),
                        };
                    }
                    // An older daemon refuses an operation it does not know
                    // as a bare envelope error: name it and the upgrade.
                    if let WireOperation::Typed(operation) = &plan.operation
                        && let Some(outdated) = super::older_daemon::replace(
                            reader,
                            &error,
                            operation.wire_name(),
                            Some(daemon_socket),
                        )
                    {
                        error = outdated;
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
<<<<<<< ours
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
                    // The app's Cloud machines, the team's joined machines and the machines
                    // acpmux reaches itself join the daemon's machine list: each is a
                    // `cmux chat --on` target.
                    #[cfg(unix)]
                    let result = match &plan.operation {
                        WireOperation::Typed(
                            cmux_tui_core::resource::ResourceOperation::MachineList,
                        ) => super::machine_join::merge_peers(
                            global,
                            super::machine_join::merge(
                                global,
                                super::cloud_machines::merge(global, result),
                            ),
                        ),
                        // The app's Cloud machines' workspaces join the daemon's list.
                        WireOperation::Typed(
                            cmux_tui_core::resource::ResourceOperation::WorkspaceList,
                        ) => super::cloud_workspaces::merge(global, result),
                        _ => result,
                    };
                    let result = match list_filter::apply(reader, plan, result) {
                        Ok(result) => result,
                        Err(error) => return print_operation_error(&error, global.output),
                    };
                    let result = agent_roster::with_terminals(reader, plan, result);
                    // The agent status words come from terminal_talk, which is unix
                    // only; elsewhere the program's own records stay as they are.
                    #[cfg(unix)]
                    let result = program_status_view::with_agent_status(reader, plan, result);
                    return super::agent_input_hint::print_result(global, plan, reader, result);
=======
                    if global.output == OutputMode::Human
                        && plan.view == ResponseView::ScreenText
                        && let Some(text) = result.get("text").and_then(Value::as_str)
                    {
                        return print_screen_text(text);
                    }
                    let code = print_success(&result, global.output);
                    return if code == 0 { success_exit_code(plan, &result) } else { code };
>>>>>>> theirs
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
    // A read timeout may come in the middle of a line: the bytes read
    // before it stay here and the next read finishes the line.
    let mut bytes = Vec::new();
    loop {
        let limit = (RESPONSE_LIMIT + 2).saturating_sub(bytes.len()) as u64;
        match reader.by_ref().take(limit).read_until(b'\n', &mut bytes) {
            Ok(0) if bytes.is_empty() => return Ok(None),
            Ok(0) => return Err("transport closed with a partial JSON line".into()),
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
    // `terminal status` prints its program status records; for a person it
    // also names the last command the shell finished (`--json` keeps the
    // record list; `terminal show --json` has it as `extra.last_command`).
    let last_command = (global.output == OutputMode::Human
        && plan.view == super::command::ResponseView::TerminalProgramStatus)
        .then(|| result.pointer("/extra/last_command").cloned())
        .flatten();
    let mut result = plan.view.project(result);
    wait_timeout::mark(plan, &mut result);
    #[cfg(unix)]
    if global.output == OutputMode::Human
        && plan.view == super::command::ResponseView::TerminalProgramStatus
    {
        result = program_status_view::human_records(result);
    }
    if global.output == OutputMode::Human {
        created_by_stamp::human_rows(plan, &mut result);
    }
    if global.output == OutputMode::Human
        && plan.view == super::command::ResponseView::ScreenText
        && let Some(text) = result.get("text").and_then(Value::as_str)
    {
        return print_screen_text(text);
    }
    let shown = match global.output {
        OutputMode::Human => human_view(plan, &result),
        output => agent_roster::machine_view(plan, &result, output),
    };
    let code = print_success(&shown, global.output);
    if let Some(last) = last_command {
        println!("{}", last_command_line(&last));
    }
    if code == 0 { success_exit_code(plan, &result) } else { code }
}

/// `terminal status`'s line for the last command the shell finished
/// (OSC 133 `D`): its exit status, or that the shell reported none.
fn last_command_line(last: &Value) -> String {
    match last.get("exit_code").and_then(Value::as_i64) {
        Some(code) => format!("LAST COMMAND exit {code}"),
        None => "LAST COMMAND exit status unknown".to_owned(),
    }
}

/// `terminal <t> screen read` as plain text: the screen's rows as they show,
/// without trailing blank rows, then one newline.
fn print_screen_text(text: &str) -> i32 {
    let mut stdout = io::stdout().lock();
    let shown = text.trim_end_matches(['\n', ' ']);
    match writeln!(stdout, "{shown}").and_then(|()| stdout.flush()) {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("stdout error: {error}");
            3
        }
    }
}

/// A printed result that does not exit 0: a `screen wait` or `process wait`
/// whose time ran out exits 124 (wire/wait_timeout.rs), an `agent message
/// unsend` whose outcome is `failed` exits 1.
fn success_exit_code(plan: &RequestPlan, result: &Value) -> i32 {
    use cmux_tui_core::resource::ResourceOperation as Op;
    if let Some(code) = wait_timeout::exit_code(plan, result) {
        return code;
    }
    i32::from(match &plan.operation {
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
    let workspaces = matches!(
        &plan.operation,
        WireOperation::Typed(cmux_tui_core::resource::ResourceOperation::WorkspaceList)
    );
    if workspaces
        && plan.filter.tree
        && let Some(rows) = result.as_array()
    {
        return std::borrow::Cow::Owned(list_filter::tree_human_rows(rows));
    }
    let personal =
        workspaces && plan.params.get("order").and_then(Value::as_str) == Some("personal");
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
        // A screen's `layout` is its whole split tree as JSON: one cell of it
        // made every row wider than the terminal (W5-P). `--json` keeps it,
        // and `screen <s> layout export` prints it.
        Some(rows) if is_screen_list(plan) => std::borrow::Cow::Owned(Value::Array(
            rows.iter()
                .map(|row| {
                    let mut row = row.clone();
                    if let Some(object) = row.as_object_mut() {
                        object.remove("layout");
                    }
                    row
                })
                .collect(),
        )),
        _ => std::borrow::Cow::Borrowed(result),
    }
}

fn is_screen_list(plan: &RequestPlan) -> bool {
    matches!(
        &plan.operation,
        WireOperation::Typed(cmux_tui_core::resource::ResourceOperation::ScreenList)
    )
}

fn is_closed_list(plan: &RequestPlan) -> bool {
    matches!(
        &plan.operation,
        WireOperation::Typed(cmux_tui_core::resource::ResourceOperation::ClosedList)
    )
}

<<<<<<< ours
pub(super) fn print_success(value: &Value, output: OutputMode) -> i32 {
=======
/// `terminal <t> screen read` as plain text: the screen's rows as they show,
/// without trailing blank rows, then one newline.
fn print_screen_text(text: &str) -> i32 {
    let mut stdout = io::stdout().lock();
    let shown = text.trim_end_matches(['\n', ' ']);
    match writeln!(stdout, "{shown}").and_then(|()| stdout.flush()) {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("stdout error: {error}");
            3
        }
    }
}

fn print_success(value: &Value, output: OutputMode) -> i32 {
>>>>>>> theirs
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

/// The session socket did not take the connection: `socket.unreachable`
/// in the one error shape (the `--json` envelope, or the message alone),
/// exit 3. Every command that dials the session reports it this way.
pub(super) fn report_connect_failure(socket: &Path, error: &io::Error, output: OutputMode) -> i32 {
    let error = json!({
        "code": "socket.unreachable",
        "message": connect_failure(socket, error),
        "details": {"socket": socket.display().to_string()},
        "retryable": false,
    });
    print_local_error(&error, output, 3)
}

pub(super) fn print_local_error(error: &Value, output: OutputMode, exit_code: i32) -> i32 {
    // A VM command's error says `vm:ID` and `cmux vm ls`, never the app's words (vm_words.rs).
    let respelled;
    let error = if super::vm_words::active() {
        respelled = super::vm_words::respell_value(error);
        &respelled
    } else {
        error
    };
    match output {
        OutputMode::Json | OutputMode::JsonLines => {
            let error = json_error_envelope(error);
            let _ = serde_json::to_writer(io::stderr().lock(), &error);
            eprintln!();
        }
        OutputMode::Quiet | OutputMode::Human => {
            let text = human_error_lines(error);
            eprint!("{}", super::with_program_name(&text, &super::program_name()));
        }
    }
    exit_code
}

/// The one `--json` error shape (docs/cli-conventions in cmuxterm-hq):
/// `{"code", "message", "details", "retryable"}`, every key present. The
/// human form prefixes its message with `cmux: ` for a person's terminal;
/// that prefix is not part of a JSON message, so a caller that built the
/// message for both forms does not leak it into the envelope.
pub(super) fn json_error_envelope(error: &Value) -> Value {
    let mut error = error.clone();
    if let Some(object) = error.as_object_mut() {
        if let Some(Value::String(message)) = object.get_mut("message")
            && let Some(rest) = message.strip_prefix("cmux: ")
        {
            *message = rest.to_owned();
        }
        object.entry("details").or_insert_with(|| json!({}));
        object.entry("retryable").or_insert(Value::Bool(false));
    }
    error
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
    if super::vm_words::active() {
        return print_success(&super::vm_words::respell_value(value), output);
    }
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

<<<<<<< ours
mod agent_roster;
mod closed_view;
mod created_by_stamp;
mod hints;
mod human;
mod list_filter;
mod list_order;
mod notify_desktop;
#[cfg(unix)]
mod program_status_view;
mod retry;
mod sanitize;
mod socket;
pub(super) mod wait_timeout;
pub(super) use agent_roster::across as agent_roster_across;
pub(super) use agent_roster::{NOTIFICATION_LIMIT, daemon_state_for_status};
// terminal_talk (unix-only) reads unread notifications the same way.
#[cfg(unix)]
pub(super) use agent_roster::unseen_terminals;
pub(super) use created_by_stamp::{
    drop_unsupported as drop_unsupported_created_by, stamp as stamp_created_by,
};
pub(super) use hints::connect_failure;
#[cfg(test)]
use human::human_text;
use human::{append_table_row, human_cell, write_human};
use sanitize::{sanitize_human_block, sanitize_human_cell};

/// Remote-supplied error text made safe for a terminal (cx-8mla8: the chief
/// CLI shows a daemon's own words).
pub(in crate::cli) fn sanitize_remote_text(value: &str) -> String {
    sanitize_human_block(value)
=======
fn write_human(value: &Value) -> io::Result<()> {
    let mut stdout = io::stdout().lock();
    stdout.write_all(human_text(value).as_bytes())?;
    stdout.flush()
}

fn human_text(value: &Value) -> String {
    let mut output = String::new();
    append_human(value, &mut output);
    output
}

fn append_human(value: &Value, output: &mut String) {
    match value {
        Value::Null => {}
        Value::String(value) => {
            let value = sanitize_human_block(value);
            output.push_str(&value);
            if !value.ends_with('\n') {
                output.push('\n');
            }
        }
        Value::Array(values) if values.iter().all(Value::is_object) => {
            append_record_table(values, output);
        }
        Value::Array(values) => {
            for value in values {
                output.push_str(&human_cell(value));
                output.push('\n');
            }
        }
        Value::Object(object) => {
            if object.len() == 1
                && let Some(values) = object.values().next()
                && values.is_array()
            {
                append_human(values, output);
                return;
            }
            let mut rows = Vec::new();
            flatten_human_object(None, object, &mut rows);
            let width =
                rows.iter().map(|(key, _)| usize::from(key.cell_width())).max().unwrap_or(0);
            for (key, value) in rows {
                output.push_str(&key);
                output.push_str(&" ".repeat(width.saturating_sub(usize::from(key.cell_width()))));
                output.push_str("  ");
                output.push_str(&value);
                output.push('\n');
            }
        }
        value => {
            output.push_str(&human_cell(value));
            output.push('\n');
        }
    }
}

fn append_record_table(values: &[Value], output: &mut String) {
    if values.is_empty() {
        return;
    }
    let mut columns = values
        .iter()
        .filter_map(Value::as_object)
        .flat_map(|object| object.keys().cloned())
        .collect::<Vec<_>>();
    columns.sort_by(|left, right| {
        human_key_rank(left).cmp(&human_key_rank(right)).then_with(|| left.cmp(right))
    });
    columns.dedup();

    let rows = values
        .iter()
        .filter_map(Value::as_object)
        .map(|object| {
            columns
                .iter()
                .map(|column| object.get(column).map_or_else(|| "-".to_string(), human_cell))
                .collect::<Vec<_>>()
        })
        .collect::<Vec<_>>();
    let widths = columns
        .iter()
        .enumerate()
        .map(|(index, column)| {
            rows.iter()
                .map(|row| usize::from(row[index].cell_width()))
                .max()
                .unwrap_or(0)
                .max(usize::from(human_header(column).cell_width()))
        })
        .collect::<Vec<_>>();

    append_table_row(
        &columns.iter().map(|column| human_header(column)).collect::<Vec<_>>(),
        &widths,
        output,
    );
    for row in rows {
        append_table_row(&row, &widths, output);
    }
}

fn append_table_row(cells: &[String], widths: &[usize], output: &mut String) {
    for (index, cell) in cells.iter().enumerate() {
        if index != 0 {
            output.push_str("  ");
        }
        output.push_str(cell);
        if index + 1 != cells.len() {
            output.push_str(
                &" ".repeat(widths[index].saturating_sub(usize::from(cell.cell_width()))),
            );
        }
    }
    output.push('\n');
}

fn flatten_human_object(
    prefix: Option<&str>,
    object: &serde_json::Map<String, Value>,
    rows: &mut Vec<(String, String)>,
) {
    let mut fields = object.iter().collect::<Vec<_>>();
    fields.sort_by(|(left, _), (right, _)| {
        human_key_rank(left).cmp(&human_key_rank(right)).then_with(|| left.cmp(right))
    });
    for (key, value) in fields {
        let path = prefix.map_or_else(|| key.clone(), |prefix| format!("{prefix}.{key}"));
        if let Value::Object(nested) = value {
            flatten_human_object(Some(&path), nested, rows);
        } else {
            rows.push((sanitize_human_cell(&path), human_cell(value)));
        }
    }
}

/// Visible placeholder for characters a terminal could interpret as part of
/// a control or escape sequence. Remote-supplied strings (browser titles,
/// terminal titles set by programs, workspace and notification names) flow
/// into human output and must render as inert text.
const CONTROL_PLACEHOLDER: char = '\u{fffd}';

/// C0 controls, DEL, C1 controls, and the Unicode line and paragraph
/// separators. Written raw, any of these can alter terminal state or break
/// the line structure of human output. Callers decide which whitespace
/// controls keep a meaning before falling through to this check.
fn is_terminal_control(ch: char) -> bool {
    matches!(ch, '\u{0}'..='\u{1f}' | '\u{7f}'..='\u{9f}' | '\u{2028}' | '\u{2029}')
}

/// Sanitize a single-line human cell. CR and LF keep the visible `\n` escape
/// so multi-line values stay on one table row; every other control character,
/// including TAB, becomes a placeholder so the cell-width padding stays
/// correct. Width math must always use the sanitized string.
pub(super) fn sanitize_human_cell(value: &str) -> String {
    let mut sanitized = String::with_capacity(value.len());
    for ch in value.chars() {
        match ch {
            '\r' | '\n' => sanitized.push_str("\\n"),
            ch if is_terminal_control(ch) => sanitized.push(CONTROL_PLACEHOLDER),
            ch => sanitized.push(ch),
        }
    }
    sanitized
}

/// Sanitize multi-line human text (top-level strings, error messages). LF and
/// TAB keep their meaning, CRLF collapses to LF, and a lone CR becomes a
/// placeholder because it can rewrite the current line.
fn sanitize_human_block(value: &str) -> String {
    let mut sanitized = String::with_capacity(value.len());
    let mut chars = value.chars().peekable();
    while let Some(ch) = chars.next() {
        match ch {
            '\n' | '\t' => sanitized.push(ch),
            '\r' if chars.peek() == Some(&'\n') => {}
            ch if is_terminal_control(ch) => sanitized.push(CONTROL_PLACEHOLDER),
            ch => sanitized.push(ch),
        }
    }
    sanitized
}

fn human_cell(value: &Value) -> String {
    match value {
        Value::Null => "-".to_string(),
        Value::String(value) => sanitize_human_cell(value),
        Value::Bool(value) => value.to_string(),
        Value::Number(value) => value.to_string(),
        // serde_json escapes C0 controls but writes C1 controls and the
        // Unicode separators raw, so the serialized form needs the same pass.
        value => sanitize_human_cell(
            &serde_json::to_string(value).expect("JSON value serialization cannot fail"),
        ),
    }
}

fn human_header(key: &str) -> String {
    sanitize_human_cell(&key.replace('_', " ").to_uppercase())
}

fn human_key_rank(key: &str) -> usize {
    match key {
        "id" => 0,
        "name" => 1,
        "title" => 2,
        "kind" => 3,
        "state" => 4,
        "lifecycle" => 5,
        "index" => 6,
        "focused" => 7,
        "running" => 8,
        _ => 9,
    }
>>>>>>> theirs
}

/// A remote-supplied string for one line or table cell of human output: controls become inert and
/// line breaks a visible `\n`.
pub(in crate::cli) fn sanitize_remote_cell(value: &str) -> String {
    sanitize_human_cell(value)
}
#[cfg(unix)]
pub(super) use socket::resolve_failure_message;
#[cfg(test)]
<<<<<<< ours
pub(super) use socket::resolve_socket_with_env;
pub(super) use socket::resolve_socket_with_origin;
pub(super) use socket::routes_to_caller_session;
#[cfg(test)]
pub(super) use socket::routes_to_caller_session_with;
pub(super) use socket::{RESOLVE_FAILURE_EXIT, resolve_failure, resolve_socket_or_report};
=======
mod tests {
    use super::*;
    use cmux_tui_core::resource::ResourceOperation;

    fn plan(operation: ResourceOperation) -> RequestPlan {
        RequestPlan {
            operation: WireOperation::Typed(operation),
            params: json!({}),
            idempotency_key: None,
            stream: false,
            view: ResponseView::Full,
        }
    }

    #[test]
    fn screen_wait_timeout_exits_one_and_a_match_exits_zero() {
        let wait = plan(ResourceOperation::TerminalWait);
        assert_eq!(success_exit_code(&wait, &json!({"matched": false, "text": ""})), 1);
        assert_eq!(success_exit_code(&wait, &json!({"matched": true, "text": "ready"})), 0);
        let read = plan(ResourceOperation::TerminalScreenRead);
        assert_eq!(success_exit_code(&read, &json!({"matched": false})), 0);
    }

    #[test]
    fn capability_preflight_rejects_wrong_app_even_when_capability_is_present() {
        let identity = json!({"app":"other", "protocol":12, "capabilities":[cmux_tui_core::server::SESSION_JOURNAL_CAPABILITY]});
        assert!(validate_capability_identity(&identity).is_err());
    }

    #[test]
    fn capability_preflight_rejects_pre_capability_protocol_even_when_capability_is_present() {
        let identity = json!({"app":"cmux-tui", "protocol":cmux_tui_core::server::SESSION_JOURNAL_PROTOCOL_VERSION - 1, "capabilities":[cmux_tui_core::server::SESSION_JOURNAL_CAPABILITY]});
        assert!(validate_capability_identity(&identity).is_err());
    }

    #[test]
    fn capability_preflight_accepts_capability_introduction_protocol() {
        let identity = json!({"app":"cmux-tui", "protocol":cmux_tui_core::server::SESSION_JOURNAL_PROTOCOL_VERSION, "capabilities":[cmux_tui_core::server::SESSION_JOURNAL_CAPABILITY]});
        assert!(validate_capability_identity(&identity).is_ok());
    }

    #[test]
    fn capability_preflight_accepts_current_protocol() {
        let identity = json!({"app":"cmux-tui", "protocol":cmux_tui_core::server::PROTOCOL_VERSION, "capabilities":[cmux_tui_core::server::SESSION_JOURNAL_CAPABILITY]});
        assert_eq!(validate_capability_identity(&identity), Ok(()));
    }

    #[test]
    fn capability_preflight_rejects_future_protocol() {
        let identity = json!({"app":"cmux-tui", "protocol":cmux_tui_core::server::PROTOCOL_VERSION + 1, "capabilities":[cmux_tui_core::server::SESSION_JOURNAL_CAPABILITY]});
        assert_eq!(validate_capability_identity(&identity), Err("unsupported server protocol"));
    }

    #[test]
    fn capability_preflight_rejects_max_protocol() {
        let identity = json!({"app":"cmux-tui", "protocol":u64::MAX, "capabilities":[cmux_tui_core::server::SESSION_JOURNAL_CAPABILITY]});
        assert_eq!(validate_capability_identity(&identity), Err("unsupported server protocol"));
    }

    #[test]
    fn capability_preflight_rejects_malformed_capabilities() {
        for capabilities in [json!(null), json!("journal-v1"), json!(["journal-v1", false])] {
            assert!(
                validate_capability_identity(&json!({
                    "app": "cmux-tui", "protocol": 12, "capabilities": capabilities,
                }))
                .is_err()
            );
        }
    }

    #[test]
    fn mutation_request_has_a_key_and_read_does_not() {
        let mutation = RequestPlan {
            operation: WireOperation::Typed(ResourceOperation::WorkspaceCreate),
            params: json!({"initial_content":"empty"}),
            idempotency_key: None,
            stream: false,
            view: ResponseView::Full,
        };
        assert!(request_value(&mutation).unwrap().get("idempotency_key").is_some());

        let read = RequestPlan {
            operation: WireOperation::Typed(ResourceOperation::WorkspaceList),
            params: json!({}),
            idempotency_key: None,
            stream: false,
            view: ResponseView::Full,
        };
        assert!(request_value(&read).unwrap().get("idempotency_key").is_none());
    }

    #[test]
    fn human_lists_are_readable_tables_instead_of_json_lines() {
        let output = human_text(&json!([
            {"id":"ws_a","name":"build","focused":true},
            {"id":"ws_b","name":"docs","focused":false}
        ]));
        assert_eq!(output, "ID    NAME   FOCUSED\nws_a  build  true\nws_b  docs   false\n");
        assert!(!output.contains(['{', '}', '"']));
    }

    #[test]
    fn human_tables_pad_wide_cells_by_terminal_width() {
        let output = human_text(&json!([
            {"name":"界","value":"a"},
            {"name":"x","value":"界"}
        ]));
        assert_eq!(output, "NAME  VALUE\n界    a\nx     界\n");
    }

    #[test]
    #[allow(clippy::unicode_not_nfc)]
    fn human_tables_pad_halfwidth_dakuten_by_terminal_width() {
        let output = human_text(&json!([
            {"name":"ｶﾞ","value":"a"},
            {"name":"x","value":"ｶﾞ"}
        ]));
        assert_eq!(output, "NAME  VALUE\nｶﾞ    a\nx     ｶﾞ\n");
    }

    #[test]
    fn human_single_array_wrappers_use_the_same_table() {
        let output = human_text(&json!({
            "workspaces": [
                {"id":"ws_a","name":"build"},
                {"id":"ws_b","name":"docs"}
            ]
        }));
        assert_eq!(output, "ID    NAME\nws_a  build\nws_b  docs\n");
    }

    #[test]
    fn human_records_flatten_nested_results_without_losing_fields() {
        let output = human_text(&json!({
            "generation": "generation-1",
            "revision": "7",
            "replayed": false,
            "value": {"kind": "workspace", "workspace_id": "ws_a"}
        }));
        for expected in [
            "generation",
            "generation-1",
            "revision",
            "7",
            "replayed",
            "false",
            "value.kind",
            "workspace",
            "value.workspace_id",
            "ws_a",
        ] {
            assert!(output.contains(expected), "missing {expected:?} in {output:?}");
        }
        assert!(!output.contains(['{', '}', '"']));
    }

    #[test]
    fn human_cells_disarm_escape_sequences_in_remote_titles() {
        // A remote-supplied title (browser page, terminal program) must not
        // reach the invoking terminal as a live escape sequence. Here the
        // payload is an OSC title change.
        let output = human_text(&json!([
            {"id":"b_1","title":"page\u{1b}]0;owned\u{7}title"}
        ]));
        assert!(!output.contains('\u{1b}'), "raw ESC in {output:?}");
        assert!(!output.contains('\u{7}'), "raw BEL in {output:?}");
        assert_eq!(output, "ID   TITLE\nb_1  page\u{fffd}]0;owned\u{fffd}title\n");
    }

    #[test]
    fn human_cells_disarm_osc52_clipboard_payloads() {
        // OSC 52 writes the clipboard on supporting terminals; the sequence
        // must render as inert text.
        let output = human_text(&json!([
            {"id":"b_1","title":"\u{1b}]52;c;aGVsbG8=\u{7}"}
        ]));
        assert!(!output.contains("\u{1b}]52"), "live OSC 52 in {output:?}");
        assert_eq!(output, "ID   TITLE\nb_1  \u{fffd}]52;c;aGVsbG8=\u{fffd}\n");
    }

    #[test]
    fn human_rows_replace_c1_and_del_controls_with_placeholders() {
        // C1 controls (CSI, DCS, OSC) and DEL are control bytes even without
        // a leading ESC on terminals that accept 8-bit controls.
        let output = human_text(&json!({"title":"a\u{9b}31mb\u{90}c\u{9d}d\u{7f}e"}));
        assert_eq!(output, "title  a\u{fffd}31mb\u{fffd}c\u{fffd}d\u{fffd}e\n");
    }

    #[test]
    fn human_cells_replace_unicode_line_separators() {
        let output = human_text(&json!([{"id":"w","name":"x\u{2028}y\u{2029}z"}]));
        assert_eq!(output, "ID  NAME\nw   x\u{fffd}y\u{fffd}z\n");
    }

    #[test]
    fn human_cells_keep_the_visible_newline_escape_for_cr_and_lf() {
        let output = human_text(&json!([{"id":"s_1","title":"line1\r\nline2"}]));
        assert_eq!(output, "ID   TITLE\ns_1  line1\\n\\nline2\n");
    }

    #[test]
    fn human_cells_replace_tabs_so_column_math_stays_aligned() {
        let output = human_text(&json!([{"id":"x","title":"a\tb"}]));
        assert_eq!(output, "ID  TITLE\nx   a\u{fffd}b\n");
    }

    #[test]
    fn human_headers_and_keys_cannot_carry_control_sequences() {
        let table = human_text(&json!([{"id":"x","bad\u{1b}key":"v"}]));
        assert_eq!(table, "ID  BAD\u{fffd}KEY\nx   v\n");
        let object = human_text(&json!({"k\u{1b}ey":"v"}));
        assert_eq!(object, "k\u{fffd}ey  v\n");
    }

    #[test]
    fn human_nested_values_disarm_c1_controls_after_json_serialization() {
        // serde_json escapes C0 controls but writes C1 controls raw, so the
        // serialized fallback cell needs the same sanitizing as plain strings.
        let output = human_text(&json!([{"id":"x","tags":["a\u{85}b"]}]));
        assert!(!output.contains('\u{85}'), "raw C1 NEL in {output:?}");
        assert_eq!(output, "ID  TAGS\nx   [\"a\u{fffd}b\"]\n");
    }

    #[test]
    fn human_top_level_strings_keep_newlines_but_disarm_controls() {
        assert_eq!(
            human_text(&json!("line1\nline2\u{1b}[2Jline3")),
            "line1\nline2\u{fffd}[2Jline3\n"
        );
        assert_eq!(human_text(&json!("crlf\r\nkept")), "crlf\nkept\n");
        assert_eq!(human_text(&json!("overwrite\rspoof")), "overwrite\u{fffd}spoof\n");
        assert_eq!(human_text(&json!("tab\tkept")), "tab\tkept\n");
    }

    #[test]
    fn human_string_lists_disarm_controls_per_line() {
        let output = human_text(&json!(["a\u{1b}b", "plain"]));
        assert_eq!(output, "a\u{fffd}b\nplain\n");
    }

    #[test]
    fn human_output_keeps_plain_unicode_text_unchanged() {
        let output = human_text(&json!({"title":"日本語 🚀 ｶﾞ title"}));
        assert_eq!(output, "title  日本語 🚀 ｶﾞ title\n");
    }

    #[test]
    fn human_error_text_disarms_control_sequences() {
        let error = json!({
            "code": "operation.failed",
            "message": "no workspace named b\u{1b}]0;owned\u{7}ad",
            "details": {"candidates": ["work\u{9b}space", "plain"]},
            "retryable": false
        });
        let text = human_error_lines(&error);
        assert!(!text.contains('\u{1b}'), "raw ESC in {text:?}");
        assert!(!text.contains('\u{9b}'), "raw C1 CSI in {text:?}");
        assert_eq!(
            text,
            "no workspace named b\u{fffd}]0;owned\u{fffd}ad\n  work\u{fffd}space\n  plain\n"
        );
    }

    #[test]
    fn sanitizers_cover_every_control_range() {
        let controls =
            ('\u{0}'..='\u{1f}').chain('\u{7f}'..='\u{9f}').chain(['\u{2028}', '\u{2029}']);
        for ch in controls {
            let cell = sanitize_human_cell(&format!("a{ch}b"));
            assert!(!cell.contains(ch), "cell kept {ch:?}: {cell:?}");
            let block = sanitize_human_block(&format!("a{ch}b"));
            if matches!(ch, '\n' | '\t') {
                assert_eq!(block, format!("a{ch}b"));
            } else {
                assert!(!block.contains(ch), "block kept {ch:?}: {block:?}");
            }
        }
        assert_eq!(sanitize_human_cell("plain ascii"), "plain ascii");
        assert_eq!(sanitize_human_block("plain ascii"), "plain ascii");
    }

    #[test]
    fn json_output_keeps_remote_title_bytes_intact() {
        // JSON modes rely on JSON escaping, not visible sanitizing: C0
        // controls are escaped, C1 controls and separator characters stay in
        // the encoded text, and the exact title survives a round-trip for
        // machine consumers.
        let title = "a\u{1b}]52;c;aGk=\u{7}b\u{9b}c\u{2028}d";
        let encoded = serde_json::to_string(&json!({"title": title})).expect("titles encode");
        assert!(!encoded.contains('\u{1b}'));
        assert!(!encoded.contains('\u{7}'));
        assert!(encoded.contains('\u{9b}'));
        assert!(encoded.contains('\u{2028}'));
        let decoded: Value = serde_json::from_str(&encoded).expect("titles decode");
        assert_eq!(decoded["title"].as_str(), Some(title));
    }

    #[test]
    fn terminal_wait_transport_timeout_follows_the_operation_timeout() {
        for operation in [ResourceOperation::TerminalWait, ResourceOperation::TerminalWaitExit] {
            let bounded = RequestPlan {
                operation: WireOperation::Typed(operation),
                params: json!({"timeout_ms":"5000"}),
                idempotency_key: None,
                stream: false,
                view: ResponseView::Full,
            };
            assert_eq!(response_read_timeout(&bounded, false), Some(Duration::from_secs(7)));

            let unbounded = RequestPlan { params: json!({}), ..bounded };
            assert_eq!(response_read_timeout(&unbounded, false), None);
        }
    }

    #[test]
    fn stream_timeout_polling_is_only_a_signal_watcher_fallback() {
        let stream = RequestPlan {
            operation: WireOperation::Typed(ResourceOperation::SessionJournalSubscribe),
            params: json!({}),
            idempotency_key: None,
            stream: true,
            view: ResponseView::Full,
        };
        assert_eq!(response_read_timeout(&stream, false), Some(Duration::from_millis(250)));
        assert_eq!(response_read_timeout(&stream, true), None);
    }

    #[test]
    fn terminal_input_errors_use_localized_copy_and_keep_wire_reasons() {
        for operation in [
            ResourceOperation::TerminalInputWrite,
            ResourceOperation::TerminalInputKeys,
            ResourceOperation::TerminalInputMouse,
            ResourceOperation::TerminalInputFocus,
        ] {
            for locale in ["en", "ja"] {
                let catalog = crate::localization::catalog_for_locale(locale);
                let plan = RequestPlan {
                    operation: WireOperation::Typed(operation),
                    params: json!({}),
                    idempotency_key: Some("input-error".into()),
                    stream: false,
                    view: ResponseView::Full,
                };
                for (reason, expected) in [
                    ("terminal_input_too_large", catalog.terminal_input.too_large),
                    ("terminal_input_unavailable", catalog.terminal_input.unavailable),
                    (
                        "terminal_input_confirmation_unsupported",
                        catalog.terminal_input.confirmation_unsupported,
                    ),
                    ("terminal_input_delivery_failed", catalog.terminal_input.delivery_failed),
                ] {
                    let wire = json!({"code":"operation.failed", "message":reason,
                        "details":{"reason":reason}, "retryable":false});
                    let mut human = wire.clone();
                    localize_operation_error_with_catalog(&plan, &mut human, catalog);
                    assert_eq!(human["message"], expected);
                    assert_ne!(human["message"], reason);
                    assert_eq!(human["details"], wire["details"]);
                    assert_eq!(wire["message"], reason);
                    assert_eq!(human["retryable"], false);
                }
            }
        }
        assert_ne!(
            crate::localization::catalog_for_locale("en").terminal_input,
            crate::localization::catalog_for_locale("ja").terminal_input
        );
    }

    #[test]
    fn stopped_owner_reload_error_is_localized_for_human_output() {
        const PROBE_LOCALE: &str = "CMUX_TEST_STOPPED_OWNER_RELOAD_LOCALE";
        if let Ok(locale) = std::env::var(PROBE_LOCALE) {
            let plan = RequestPlan {
                operation: WireOperation::Typed(ResourceOperation::SessionReloadConfig),
                params: json!({}),
                idempotency_key: Some("reload-owner-stopped".into()),
                stream: false,
                view: ResponseView::Full,
            };
            let mut error = json!({
                "code":"operation.failed",
                "message":"owner_stopped",
                "details":{"operation":"session.reload_config","reason":"owner_stopped"},
                "retryable":false,
            });

            localize_operation_error(&plan, &mut error);

            let expected = match locale.as_str() {
                "en_US.UTF-8" => {
                    "the local server stopped before it applied the configuration reload; start the session and retry"
                }
                "ja_JP.UTF-8" => {
                    "ローカルサーバーが設定の再読み込みを適用する前に停止しました。セッションを起動して再試行してください"
                }
                _ => panic!("unexpected probe locale {locale}"),
            };
            assert_eq!(error["message"], expected);
            return;
        }
>>>>>>> theirs

#[cfg(test)]
mod tests;
