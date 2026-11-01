//! `cmux run --sandboxed <task>`: one task on a throwaway cmux Cloud VM (hq#3367).
//!
//! The cmux app holds the Stack session, so, like `cmux billing`, each step is one
//! app method: `runs.sandbox.create` submits the Run, then `runs.wait` long-polls
//! the server's bounded wait (at most 10 s a call) until the Run is terminal or the
//! task's own timeout plus the teardown margin has passed. The loop always ends:
//! at the receipt, at that deadline, or at the first error. `cmux run <script.ts>`
//! (code mode) is untouched: only `--sandboxed` routes here.

use std::io::Write;
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Mutex, mpsc};
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

use super::{GlobalArgs, OutputMode, UsageError};
use crate::localization::SandboxRunMessages;

/// The server's default and bounds for `timeoutMs` (web/services/runs/model.ts).
const DEFAULT_TIMEOUT_SECS: u64 = 600;
const MIN_TIMEOUT_SECS: u64 = 30;
const MAX_TIMEOUT_SECS: u64 = 720;
/// Boot, the agent's last output and the VM destroy happen around the task's own timeout.
const TEARDOWN_MARGIN: Duration = Duration::from_secs(180);
/// The app answers a create in its 25 s deadline; a wait in the server's 10 s plus transit.
const CREATE_TIMEOUT: Duration = Duration::from_secs(30);
const WAIT_TIMEOUT: Duration = Duration::from_secs(30);
/// The app's own work around the server's long-poll (auth, the HTTP round trip).
const WAIT_TRANSIT: Duration = Duration::from_secs(15);
const WAIT_SLICE_MS: u64 = 10_000;
/** The server's limit on a sandbox task (web/services/runs/model.ts SANDBOX_TASK_MAX_CHARS). */
const TASK_MAX_CHARS: usize = 16_000;
/** The app's `runs.cancel` deadline is 65 s: it destroys the VM before it answers. */
const CANCEL_TIMEOUT: Duration = Duration::from_secs(70);
/** The agents a sandboxed run can use (the server's CLOUD_VM_AGENTS). */
const AGENTS: [&str; 4] = ["claude", "codex", "opencode", "pi"];
/** What an app call may take past its budget and probe (connecting, the thread handoff). */
const CALL_MARGIN: Duration = Duration::from_secs(1);
/** The pause after a wait that got no answer, doubling to `RETRY_PAUSE_MAX`, never past the deadline. */
const RETRY_PAUSE_MIN: Duration = Duration::from_millis(500);
const RETRY_PAUSE_MAX: Duration = Duration::from_secs(8);

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Invocation {
    Help,
    Run(Request),
}

#[derive(Debug, PartialEq, Eq)]
pub(super) struct Request {
    pub task: String,
    pub agent: Option<String>,
    pub image: Option<String>,
    pub timeout_secs: u64,
}

/// `cmux run --sandboxed …`. `None` for any other command, `cmux run <script.ts>` included.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let rest = split(&command_args)?;
    Some(match parse(rest) {
        Ok(invocation) => run(&global, invocation),
        Err(error) => {
            super::app::failure("usage.invalid", &format!("cmux: {error}"), global.output, 2)
        }
    })
}

/// `Some(args after "run")` when the command is `run` and names `--sandboxed`
/// before any `--`.
pub(super) fn split(command_args: &[String]) -> Option<&[String]> {
    let (first, rest) = command_args.split_first()?;
    let sandboxed = rest.iter().take_while(|arg| *arg != "--").any(|arg| arg == "--sandboxed");
    (first == "run" && sandboxed).then_some(rest)
}

pub(super) fn parse(rest: &[String]) -> Result<Invocation, UsageError> {
    let messages = &crate::localization::catalog().sandbox_run;
    let app = &crate::localization::catalog().app_control;
    let mut request = Request {
        task: String::new(),
        agent: None,
        image: None,
        timeout_secs: DEFAULT_TIMEOUT_SECS,
    };
    let mut words: Vec<&str> = Vec::new();
    let mut index = 0;
    while let Some(arg) = rest.get(index) {
        let arg = arg.as_str();
        index += 1;
        if arg == "--" {
            words.extend(rest.get(index..).unwrap_or_default().iter().map(String::as_str));
            break;
        }
        match arg {
            "--help" | "-h" => return Ok(Invocation::Help),
            "--sandboxed" => continue,
            _ => {}
        }
        let Some(flag) = arg.strip_prefix("--") else {
            words.push(arg);
            continue;
        };
        let (name, inline) = match flag.split_once('=') {
            Some((name, value)) => (name, Some(value.to_owned())),
            None => (flag, None),
        };
        if !matches!(name, "agent" | "image" | "timeout") {
            return Err(UsageError::new(app.unexpected_argument.replace("{value}", arg)));
        }
        let value = match inline {
            Some(value) => value,
            None => {
                let value = rest
                    .get(index)
                    .ok_or_else(|| UsageError::new(app.missing_value.replace("{flag}", arg)))?;
                index += 1;
                value.clone()
            }
        };
        let value = value.trim().to_owned();
        match name {
            "agent" => {
                // The agents a sandbox runs (web/services/vms CLOUD_VM_AGENTS); checked here so a
                // typo is a usage error before anything is sent.
                if !AGENTS.contains(&value.as_str()) {
                    return Err(UsageError::new(messages.bad_agent.replace("{value}", &value)));
                }
                request.agent = Some(value);
            }
            "image" => request.image = Some(value).filter(|image| !image.is_empty()),
            _ => {
                request.timeout_secs = value
                    .parse::<u64>()
                    .ok()
                    .filter(|secs| (MIN_TIMEOUT_SECS..=MAX_TIMEOUT_SECS).contains(secs))
                    .ok_or_else(|| {
                        UsageError::new(messages.bad_timeout.replace("{value}", &value))
                    })?;
            }
        }
    }
    request.task = words.join(" ").trim().to_owned();
    if request.task.is_empty() {
        return Err(UsageError::new(messages.task_required));
    }
    // The server counts UTF-16 code units (JavaScript `length`), so this does too.
    if request.task.encode_utf16().count() > TASK_MAX_CHARS {
        return Err(UsageError::new(
            messages.task_too_long.replace("{max}", &TASK_MAX_CHARS.to_string()),
        ));
    }
    Ok(Invocation::Run(request))
}

/// The `runs.sandbox.create` params. The key makes a retry return the same Run.
pub(super) fn create_params(request: &Request, idempotency_key: &str) -> Map<String, Value> {
    let mut params = Map::new();
    params.insert("task".into(), json!(request.task));
    params.insert("timeoutMs".into(), json!(request.timeout_secs * 1000));
    params.insert("idempotencyKey".into(), json!(idempotency_key));
    if let Some(agent) = &request.agent {
        params.insert("agent".into(), json!(agent));
    }
    if let Some(image) = &request.image {
        params.insert("image".into(), json!(image));
    }
    params
}

fn print_help(messages: &SandboxRunMessages) -> i32 {
    let mut stdout = std::io::stdout().lock();
    let _ = stdout.write_all(messages.usage.as_bytes());
    let _ = stdout.flush();
    0
}

/// A failed app call: the error to print and the exit code it maps to.
pub(super) struct CallError {
    error: Value,
    exit_code: i32,
}

/// One app call on a fresh connection, answered within one absolute bound: `timeout`, plus
/// `--socket`'s probe, plus a second for the connection. The socket's own timeouts are per read,
/// so a reached app that trickles its answer could hold a read past them; the call runs on its
/// own thread and is abandoned at the bound (its socket shut down, so the thread's read ends
/// there; one still connecting ends at its own read timeout or with the process).
fn call(
    global: &GlobalArgs,
    method: &str,
    params: Map<String, Value>,
    timeout: Duration,
) -> Result<Value, CallError> {
    let probe = if global.socket.is_some() && global.app_socket.is_none() {
        super::app::READ_TIMEOUT
    } else {
        Duration::ZERO
    };
    let bound = timeout + probe + CALL_MARGIN;
    let connected: Arc<Mutex<Option<UnixStream>>> = Arc::default();
    let (answer, answered) = mpsc::channel();
    let (thread_global, thread_method, thread_connected) =
        (global.clone(), method.to_owned(), Arc::clone(&connected));
    std::thread::spawn(move || {
        let result =
            call_on_connection(&thread_global, &thread_method, params, timeout, &thread_connected);
        let _ = answer.send(result);
    });
    answered.recv_timeout(bound).unwrap_or_else(|_| {
        if let Some(stream) = connected.lock().ok().and_then(|mut slot| slot.take()) {
            let _ = stream.shutdown(Shutdown::Both);
        }
        let messages = &crate::localization::catalog().sandbox_run;
        Err(CallError {
            error: json!({
                "code": "timeout",
                "message": messages.app_no_answer.replace("{seconds}", &bound.as_secs().to_string()),
                "details": {},
                "retryable": true,
            }),
            exit_code: 1,
        })
    })
}

fn call_on_connection(
    global: &GlobalArgs,
    method: &str,
    params: Map<String, Value>,
    timeout: Duration,
    connected: &Mutex<Option<UnixStream>>,
) -> Result<Value, CallError> {
    // No app to ask (not running, a socket that refuses): exit 3, like `cmux billing`; the
    // person starts the app first. A lost answer from one that was reached is exit 1.
    let mut stream =
        super::app::connect_command(global).map_err(|error| CallError { error, exit_code: 3 })?;
    if let (Ok(mut slot), Ok(clone)) = (connected.lock(), stream.try_clone()) {
        *slot = Some(clone);
    }
    match super::app::request(&mut stream, method, Value::Object(params), timeout) {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(error)) => {
            let exit_code = if is_gate_refusal(&error) {
                3
            } else if is_input_refusal(&error) {
                2
            } else if error.get("code").and_then(Value::as_str) == Some("method_not_found") {
                5
            } else {
                1
            };
            Err(CallError { error, exit_code })
        }
        Err(message) => Err(CallError {
            error: json!({ "code": "app.transport", "message": message, "details": {}, "retryable": true }),
            exit_code: 1,
        }),
    }
}

/// The rate limiter answered: a definite refusal, though a wait may ask again later.
pub(super) fn is_rate_limit(error: &Value) -> bool {
    error.get("code").and_then(Value::as_str) == Some("rate_limited")
}

/// The server refused the request itself (the task, agent, image or timeout): a usage error, exit 2.
pub(super) fn is_input_refusal(error: &Value) -> bool {
    matches!(
        error.get("code").and_then(Value::as_str),
        Some(
            "run_task_required" | "run_agent_invalid" | "run_image_invalid" | "run_timeout_invalid"
        )
    )
}

/// Signed out, or Cloud is off: an administrator's policy (`feature.disabled`), the server's
/// allowlist, Cloud not callable here (`cloud_disabled`: a managed team missing or a local-only
/// backend), or an older app's Labs flag (`labs_off`); or the app has no Cloud backend
/// (`no_backend`). Exit 3: nothing to wait for, act first.
pub(super) fn is_gate_refusal(error: &Value) -> bool {
    matches!(
        error.get("code").and_then(Value::as_str),
        Some(
            "not_signed_in"
                | "labs_off"
                | "cloud_disabled"
                | "feature.disabled"
                | "run_sandbox_unavailable"
                | "no_backend"
        )
    )
}

/// What the deadline's `runs.cancel` answered.
#[derive(Debug, PartialEq, Clone, Copy)]
pub(super) enum DeadlineCancel<'a> {
    /// The run's receipt: it ended (cancelled, or on its own in the race).
    Receipt(&'a Value),
    /// The cancel was taken; the run hasn't ended yet (its VM is being destroyed).
    Pending,
    /// A definite answer that isn't a receipt: the app refused the cancel (signed out, policy
    /// off: exit 3) or the server failed it (`run_not_found`, another 4xx: exit 1), with its reason.
    Refused,
    /// No answer (a timeout, a lost or unreachable app, a server failure): exit 4.
    Unanswered,
}

pub(super) fn deadline_cancel<'a>(
    cancelled: &'a Result<Value, CallError>,
    id: &str,
) -> DeadlineCancel<'a> {
    match cancelled {
        Ok(snapshot) => {
            if let Some(receipt) = run_receipt(snapshot, id) {
                return DeadlineCancel::Receipt(receipt);
            }
            // Pending only when the answer is this Run's snapshot and says it is cancelling:
            // anything else (`{}`, another run, one still queued or running, a terminal run with
            // no receipt) confirms nothing.
            let run = snapshot.get("run");
            let same = run.and_then(|run| run.get("id")).and_then(Value::as_str) == Some(id);
            let ending =
                run.and_then(|run| run.get("status")).and_then(Value::as_str) == Some("cancelling");
            if same && ending { DeadlineCancel::Pending } else { DeadlineCancel::Unanswered }
        }
        // A rate limit answered the cancel: a definite refusal with its own code, not "no answer".
        Err(failed) if is_wait_transient(&failed.error) && !is_rate_limit(&failed.error) => {
            DeadlineCancel::Unanswered
        }
        // No app to ask (discovery found none this time): nothing answered the cancel either.
        Err(failed)
            if matches!(
                failed.error.get("code").and_then(Value::as_str),
                Some("app.not_found" | "socket.no_app")
            ) =>
        {
            DeadlineCancel::Unanswered
        }
        Err(_) => DeadlineCancel::Refused,
    }
}

fn print_error(global: &GlobalArgs, failed: &CallError) -> i32 {
    super::wire::print_local_error(&failed.error, global.output, failed.exit_code)
}

/// The same command with the key that makes the server answer the run it already started
/// instead of starting a second one, shell-quoted so it can be pasted as is. It reaches the same
/// app: the routing flags given, and the app socket this command used (`app_socket`, the one it
/// named or discovered), since a retry from another shell could otherwise reach another app and
/// account, where the same key would start a second run.
pub(super) fn retry_command(
    request: &Request,
    key: &str,
    global: &GlobalArgs,
    app_socket: Option<&std::path::Path>,
) -> String {
    let quote = |word: &str| {
        if !word.is_empty()
            && word.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_./:=@%+,".contains(&b))
        {
            word.to_owned()
        } else {
            format!("'{}'", word.replace('\'', "'\\''"))
        }
    };
    let mut words = vec!["cmux".to_owned()];
    // `--flag=value`, one word, so a value that starts with `--` is never read as a flag.
    let pair = |flag: &str, value: &str| quote(&format!("{flag}={value}"));
    // A socket path is pinned absolute: a retry pasted in another directory reaches this app.
    let pinned =
        |path: &std::path::Path| std::path::absolute(path).unwrap_or_else(|_| path.to_path_buf());
    if let Some(socket) = &global.socket {
        words.push(pair("--socket", &pinned(socket).to_string_lossy()));
    }
    if let Some(session) = &global.session {
        words.push(pair("--session", session));
    }
    if let Some(machine) = &global.machine {
        words.push(pair("--machine", machine));
    }
    if let Some(socket) = global.app_socket.as_deref().or(app_socket) {
        words.push(pair("--app-socket", &pinned(socket).to_string_lossy()));
    }
    words.extend(["run".to_owned(), "--sandboxed".to_owned(), pair("--idempotency-key", key)]);
    if let Some(agent) = &request.agent {
        words.extend(["--agent".to_owned(), quote(agent.as_str())]);
    }
    if let Some(image) = &request.image {
        words.extend(["--image".to_owned(), quote(image.as_str())]);
    }
    if request.timeout_secs != DEFAULT_TIMEOUT_SECS {
        words.extend(["--timeout".to_owned(), request.timeout_secs.to_string()]);
    }
    words.extend(["--".to_owned(), quote(request.task.as_str())]);
    words.join(" ")
}

/// Every failure after the create was sent: the run may exist, so the error carries what
/// recovers it (`details.idempotencyKey`, `details.runId` when known, `details.retry`) in JSON,
/// and the retry command in text.
fn print_submitted_error(
    global: &GlobalArgs,
    mut failed: CallError,
    retry: &str,
    key: &str,
    run_id: Option<&str>,
    messages: &SandboxRunMessages,
) -> i32 {
    if let Some(error) = failed.error.as_object_mut() {
        let message = error.get("message").and_then(Value::as_str).unwrap_or_default().to_owned();
        error.insert(
            "message".into(),
            json!(messages.retry_with_key.replace("{message}", &message).replace("{retry}", retry)),
        );
        let details = error.entry("details").or_insert_with(|| json!({}));
        if let Some(details) = details.as_object_mut() {
            details.insert("idempotencyKey".into(), json!(key));
            details.insert("retry".into(), json!(retry));
            if let Some(run_id) = run_id {
                details.insert("runId".into(), json!(run_id));
            }
        }
    }
    print_error(global, &failed)
}

/// One `runs.wait` call that fits before `deadline`: the server's wait and the socket budget
/// around it, together never past the deadline. `None` once it has passed.
///
/// `probe` is what the connection may spend before the request (`--socket` asks `system.ping`
/// first, up to its read timeout), kept out of the slice so the call still ends by the deadline.
pub(super) fn wait_slice(
    now: Instant,
    deadline: Instant,
    probe: Duration,
) -> Option<(Duration, Duration)> {
    // The call's own bound is its budget plus the probe plus `CALL_MARGIN`: all of it ends by the deadline.
    let remaining = deadline
        .checked_duration_since(now)
        .map(|left| left.saturating_sub(probe + CALL_MARGIN))
        .filter(|left| !left.is_zero())?;
    let budget = remaining.min(WAIT_TIMEOUT);
    let server = budget
        .saturating_sub(WAIT_TRANSIT)
        .max(budget / 2)
        .min(Duration::from_millis(WAIT_SLICE_MS));
    Some((server, budget))
}

pub(super) fn run(global: &GlobalArgs, invocation: Invocation) -> i32 {
    let messages = &crate::localization::catalog().sandbox_run;
    let request = match invocation {
        Invocation::Help => return print_help(messages),
        Invocation::Run(request) => request,
    };
    let key = global.idempotency_key.clone().unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    // The app this command reaches, pinned in the retry (`--socket` names it with its own check).
    let app_socket = if global.app_socket.is_none() && global.socket.is_none() {
        super::app::socket_path(global).ok()
    } else {
        None
    };
    let retry = retry_command(&request, &key, global, app_socket.as_deref());
    let created =
        match call(global, "runs.sandbox.create", create_params(&request, &key), CREATE_TIMEOUT) {
            Ok(value) => value,
            // A definite refusal: nothing started, so say only why.
            Err(failed) if !create_may_have_committed(&failed.error) => {
                return print_error(global, &failed);
            }
            Err(failed) => {
                return print_submitted_error(global, failed, &retry, &key, None, messages);
            }
        };
    let Some(id) = created.get("id").and_then(Value::as_str).map(str::to_owned) else {
        let failed = CallError {
            error: json!({ "code": "bad_response", "message": messages.bad_response, "details": {} }),
            exit_code: 1,
        };
        return print_submitted_error(global, failed, &retry, &key, None, messages);
    };
    if global.output == OutputMode::Human {
        eprintln!("{}", messages.waiting.replace("{id}", &id));
    }
    // The loop's stop conditions: the receipt, the deadline (checked before every call, and each
    // call's server wait plus socket budget never runs past it), or the first error.
    let deadline = Instant::now() + Duration::from_secs(request.timeout_secs) + TEARDOWN_MARGIN;
    let probe = if global.socket.is_some() && global.app_socket.is_none() {
        super::app::READ_TIMEOUT
    } else {
        Duration::ZERO
    };
    let mut pause = RETRY_PAUSE_MIN;
    loop {
        let Some((server, budget)) = wait_slice(Instant::now(), deadline, probe) else {
            // Past the deadline the run is not worth more VM time: cancel it, which destroys its
            // VM before it answers (bounded; the server's reaper covers a cancel that fails).
            let mut params = Map::new();
            params.insert("id".into(), json!(id));
            let cancelled = call(global, "runs.cancel", params, CANCEL_TIMEOUT);
            // The cancel answers the Run's snapshot: its receipt (it may have finished in the
            // race, and it says whether the VM is destroyed or still pending) is the answer.
            let outcome = deadline_cancel(&cancelled, &id);
            if let DeadlineCancel::Receipt(receipt) = outcome {
                // Say "cancelled" only when the receipt says so: the run may have ended on its own
                // in the race. The exit code is the receipt's, as on the normal path.
                let status = receipt.get("status").and_then(Value::as_str);
                if global.output == OutputMode::Human && status == Some("cancelled") {
                    eprintln!("{}", messages.cancelled_at_deadline.replace("{id}", &id));
                }
                let code = exit_code(receipt);
                let printed = print_receipt(global, receipt, messages);
                return if printed == 0 { code } else { printed };
            }
            // The cancel was taken but the run hasn't ended yet (its VM is being destroyed), it got
            // a definite refusal (with its own code and exit), or it got no answer: say which.
            let pending = outcome == DeadlineCancel::Pending;
            let definite = outcome == DeadlineCancel::Refused;
            let failed = match cancelled {
                Err(mut refused) if definite => {
                    let reason =
                        refused.error.get("message").and_then(Value::as_str).unwrap_or_default();
                    // Only a signed-out app or a policy that is off leaves the server to end the
                    // run; any other refusal (`run_not_found`, a rate limit) says only what it was.
                    let template = if is_gate_refusal(&refused.error) {
                        messages.cancel_refused
                    } else {
                        messages.cancel_failed
                    };
                    let message = template.replace("{id}", &id).replace("{message}", reason);
                    if let Some(error) = refused.error.as_object_mut() {
                        error.insert("message".into(), json!(message));
                        let details = error.entry("details").or_insert_with(|| json!({}));
                        if let Some(details) = details.as_object_mut() {
                            details.insert("cancelRequested".into(), json!(false));
                        }
                    }
                    refused
                }
                _ => CallError {
                    error: json!({
                        "code": "run.still_running",
                        "message": if pending {
                            messages.cancel_pending.replace("{id}", &id)
                        } else {
                            messages.still_running.replace("{id}", &id)
                        },
                        "details": { "cancelRequested": pending },
                    }),
                    exit_code: 4,
                },
            };
            return print_submitted_error(
                global,
                failed,
                &retry,
                &key,
                Some(id.as_str()),
                messages,
            );
        };
        let mut params = Map::new();
        params.insert("id".into(), json!(id));
        params.insert(
            "timeoutMs".into(),
            json!(u64::try_from(server.as_millis()).unwrap_or(WAIT_SLICE_MS)),
        );
        let snapshot = match call(global, "runs.wait", params, budget) {
            Ok(value) => value,
            // A wait that ran into the deadline is the deadline: the loop's next turn says so.
            Err(_) if Instant::now() >= deadline => continue,
            // A wait that timed out or lost its transport is no answer: wait again until the
            // deadline, where the loop cancels the run. Only a definite refusal ends it here.
            // An outage answers at once: pause before asking again (backing off, inside the deadline).
            Err(failed) if is_wait_transient(&failed.error) => {
                std::thread::sleep(pause.min(deadline.saturating_duration_since(Instant::now())));
                pause = (pause * 2).min(RETRY_PAUSE_MAX);
                continue;
            }
            // Signed out or Cloud turned off after the run started: the run goes on to its own
            // timeout, where the server destroys its VM. Exit 3 with that said.
            Err(mut refused) if is_gate_refusal(&refused.error) => {
                let reason =
                    refused.error.get("message").and_then(Value::as_str).unwrap_or_default();
                let message = messages
                    .refused_while_running
                    .replace("{id}", &id)
                    .replace("{message}", reason);
                if let Some(error) = refused.error.as_object_mut() {
                    error.insert("message".into(), json!(message));
                }
                return print_submitted_error(
                    global,
                    refused,
                    &retry,
                    &key,
                    Some(id.as_str()),
                    messages,
                );
            }
            Err(failed) => {
                return print_submitted_error(
                    global,
                    failed,
                    &retry,
                    &key,
                    Some(id.as_str()),
                    messages,
                );
            }
        };
        if let Some(receipt) = run_receipt(&snapshot, &id) {
            let code = exit_code(receipt);
            let printed = print_receipt(global, receipt, messages);
            return if printed == 0 { code } else { printed };
        }
        // A finished run whose answer holds no valid receipt will never get one: the answer is lost.
        if run_finished(&snapshot) {
            let failed = CallError {
                error: json!({ "code": "bad_response", "message": messages.bad_response, "details": {} }),
                exit_code: 1,
            };
            // The run exists: the error carries its key and the retry that reads it again.
            return print_submitted_error(
                global,
                failed,
                &retry,
                &key,
                Some(id.as_str()),
                messages,
            );
        }
    }
}

/// The snapshot says its run has finished (succeeded, failed or cancelled).
pub(super) fn run_finished(snapshot: &Value) -> bool {
    matches!(
        snapshot.get("run").and_then(|run| run.get("status")).and_then(Value::as_str),
        Some("succeeded" | "failed" | "cancelled")
    )
}

fn print_receipt(global: &GlobalArgs, receipt: &Value, messages: &SandboxRunMessages) -> i32 {
    let shown = match global.output {
        OutputMode::Human => json!(receipt_text(receipt, messages)),
        _ => receipt.clone(),
    };
    super::wire::print_local_success(&shown, global.output)
}

/// A wait error that says nothing about the run: a timeout, a lost connection to the app, an
/// app that went away (restarting), a server failure, a rate limit or an answer the app couldn't
/// read: wait again until the deadline, where the run is cancelled.
pub(super) fn is_transient(error: &Value) -> bool {
    matches!(
        error.get("code").and_then(Value::as_str),
        Some(
            "timeout"
                | "app.transport"
                | "unavailable"
                | "app.unreachable"
                | "socket.unreachable"
                | "bad_response"
                | "rate_limited"
        )
    )
}

/// A wait or cancel error that says nothing about the run: a transient one, or `--socket`'s
/// probe not answering as the app. That route answered as the app when the run was created, so
/// a probe that fails now is a stall, not another kind of socket.
pub(super) fn is_wait_transient(error: &Value) -> bool {
    is_transient(error) || error.get("code").and_then(Value::as_str) == Some("socket.wrong_kind")
}

/// A create error after which the run may exist: no answer, or a server failure. Anything else
/// (signed out, an older app's Labs flag, a refused image, agent or task, no app to ask) proves nothing started.
pub(super) fn create_may_have_committed(error: &Value) -> bool {
    matches!(
        error.get("code").and_then(Value::as_str),
        Some("timeout" | "app.transport" | "unavailable" | "bad_response")
    )
}

/// The snapshot's receipt when it is this Run's finished sandbox receipt: the v1 schema, this
/// Run's id, the sandboxed environment, a terminal status and a cleanup state. Anything else
/// (`{}`, another run's, a status still running, a skeleton without cleanup) is no receipt.
pub(super) fn run_receipt<'a>(snapshot: &'a Value, id: &str) -> Option<&'a Value> {
    let receipt = snapshot.get("receipt")?;
    let field = |key: &str| receipt.get(key).and_then(Value::as_str);
    (field("schema") == Some("cmux.run.receipt/v1")
        && field("runId") == Some(id)
        && field("environment") == Some("sandboxed")
        && matches!(field("status"), Some("succeeded" | "failed" | "cancelled"))
        && matches!(field("cleanup"), Some("destroyed" | "pending")))
    .then_some(receipt)
}

/// 0 when the task succeeded, 1 when it failed or was cancelled.
pub(super) fn exit_code(receipt: &Value) -> i32 {
    i32::from(receipt.get("status").and_then(Value::as_str) != Some("succeeded"))
}

fn seconds(ms: Option<f64>) -> String {
    ms.map_or_else(|| "-".to_owned(), |ms| format!("{:.1} s", ms / 1000.0))
}

/// The receipt as lines a person reads: the reply first, then how it ended and what it cost.
pub(super) fn receipt_text(receipt: &Value, messages: &SandboxRunMessages) -> String {
    let field = |path: &[&str]| path.iter().try_fold(receipt, |value, key| value.get(*key));
    let mut lines: Vec<String> = Vec::new();
    if let Some(reply) = field(&["reply"]).and_then(Value::as_str).filter(|reply| !reply.is_empty())
    {
        lines.push(reply.to_owned());
        lines.push(String::new());
    }
    let status = match field(&["status"]).and_then(Value::as_str) {
        Some("succeeded") => messages.status_succeeded,
        Some("failed") => messages.status_failed,
        Some("cancelled") => messages.status_cancelled,
        Some(other) => other,
        None => "-",
    };
    let exit = match (
        field(&["exitCode"]).and_then(Value::as_i64),
        field(&["timedOut"]).and_then(Value::as_bool),
    ) {
        (_, Some(true)) => messages.timed_out.to_owned(),
        (Some(code), _) => messages.exit.replace("{code}", &code.to_string()),
        _ => String::new(),
    };
    lines.push(messages.status.replace("{status}", status).replace("{exit}", &exit));
    if let Some(error) = field(&["error"]).and_then(Value::as_str) {
        lines.push(error.to_owned());
    }
    lines.push(
        messages
            .timings
            .replace("{total}", &seconds(field(&["timings", "totalMs"]).and_then(Value::as_f64)))
            .replace("{boot}", &seconds(field(&["timings", "bootMs"]).and_then(Value::as_f64))),
    );
    if let (Some(usd), Some(secs)) = (
        field(&["cost", "estimateUsd"]).and_then(Value::as_f64),
        field(&["cost", "vmSeconds"]).and_then(Value::as_f64),
    ) {
        lines.push(
            messages
                .cost
                .replace("{usd}", &format!("{usd:.4}"))
                .replace("{seconds}", &format!("{secs:.0}")),
        );
    }
    if let Some(artifacts) =
        field(&["artifacts"]).and_then(Value::as_array).filter(|artifacts| !artifacts.is_empty())
    {
        lines.push(messages.artifacts.to_owned());
        for artifact in artifacts {
            let name = artifact.get("name").and_then(Value::as_str).unwrap_or("?");
            let size = artifact.get("sizeBytes").and_then(Value::as_u64).unwrap_or(0);
            lines.push(format!("  {name} ({size} B)"));
        }
    }
    lines.push(match field(&["cleanup"]).and_then(Value::as_str) {
        Some("destroyed") => messages.cleanup_destroyed.to_owned(),
        _ => messages.cleanup_pending.to_owned(),
    });
    lines.join("\n")
}

#[cfg(test)]
mod tests;
