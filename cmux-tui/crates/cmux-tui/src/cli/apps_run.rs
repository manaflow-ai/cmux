//! `cmux apps run <app> <op> [--args JSON] [--idempotency-key KEY]`: one
//! catalog op of an installed app, through the session daemon's `apps-run`
//! (cmux-tui-core apps/runs.rs), with Ctrl-C cancel
//! (plans/cmux-next/app-op-routing.md "Op cancel").
//!
//! The first Ctrl-C cancels the run. When the daemon advertises
//! [`CANCEL_REQUEST_CAPABILITY`] in `identify`, the CLI sends the generic
//! caller cancel `{"id":<new>,"cmd":"cancel-request","target":<the apps-run
//! id>}` on the same connection and waits at most [`CANCEL_WAIT`] for the
//! run's `cmux.op.cancelled` answer ("cancelled", exit 130). Otherwise it
//! closes the connection, which makes the supervisor cancel the op, and
//! prints "cancelled (no confirmation)" (exit 130). A second Ctrl-C exits 130
//! at once. A run that answered normally before the cancel took effect is
//! printed as usual. The CLI never sends an `origin`: it runs as `cli`.

mod messages;

#[cfg(test)]
mod tests;

use std::future::Future;
use std::time::Duration;

use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};

use self::messages::messages;
use super::{GlobalArgs, OutputMode};

/// The verb (pending the app platform owner's OK on the name: rename here).
pub(super) const VERB: [&str; 2] = ["apps", "run"];

/// How long a cancelled run may take to confirm.
pub(super) const CANCEL_WAIT: Duration = Duration::from_secs(3);

/// The exit code of a run the user cancelled (128 + SIGINT).
pub(super) const EXIT_CANCELLED: i32 = 130;

/// The error code a cancelled run answers with.
pub(super) const CANCELLED_CODE: &str = "cmux.op.cancelled";

/// The `identify` capability of a daemon that serves `cancel-request`.
pub(super) const CANCEL_REQUEST_CAPABILITY: &str = "cancel-request-v1";

const IDENTIFY_ID: &str = "identify-1";
const RUN_ID: &str = "apps-run-1";
const CANCEL_ID: &str = "cancel-request-1";

/// Ctrl-C presses, one per `next()`.
pub(super) trait Interrupts {
    fn next(&mut self) -> impl Future<Output = ()>;
}

/// How a run ended.
#[derive(Debug, Clone, PartialEq)]
pub(super) enum Outcome {
    /// The run's own answer (`ok` true or false).
    Answer(Value),
    /// The user cancelled; `confirmed` when the run answered cmux.op.cancelled.
    Cancelled { confirmed: bool },
    /// A second Ctrl-C ended the wait.
    Interrupted,
    /// The daemon closed the connection before the run answered.
    Closed,
}

/// One op to run.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct AppOp {
    pub app: String,
    pub op: String,
    pub args: Value,
    pub idempotency_key: Option<String>,
}

/// Send `apps-run` for `request` on `stream` and wait for its answer; on an
/// interrupt send `cancel-request` and wait at most `cancel_wait`
/// ([`CANCEL_WAIT`] in the CLI; tests inject a short bound).
pub(super) async fn run_app_op<S, I>(
    stream: S,
    request: &AppOp,
    mut interrupts: I,
    cancel_wait: Duration,
) -> Outcome
where
    S: AsyncRead + AsyncWrite + Unpin,
    I: Interrupts,
{
    let (reader, mut writer) = tokio::io::split(stream);
    let mut lines = BufReader::new(reader).lines();
    // Does the daemon take a cancel-request frame? (Else closing cancels.)
    let identify = json!({"id": IDENTIFY_ID, "cmd": "identify"});
    if send(&mut writer, &identify).await.is_err() {
        return Outcome::Closed;
    }
    let cancel_frame = match answer_to(&mut lines, IDENTIFY_ID).await {
        Some(identity) => identity["data"]["capabilities"]
            .as_array()
            .is_some_and(|names| names.iter().any(|name| name == CANCEL_REQUEST_CAPABILITY)),
        None => return Outcome::Closed,
    };
    let mut run = json!({
        "id": RUN_ID, "cmd": "apps-run", "app": request.app, "op": request.op,
        "args": request.args,
    });
    if let Some(key) = &request.idempotency_key {
        run["idempotency_key"] = json!(key);
    }
    if send(&mut writer, &run).await.is_err() {
        return Outcome::Closed;
    }
    // Until the first Ctrl-C: the run's answer or an interrupt.
    tokio::select! {
        answer = answer_to(&mut lines, RUN_ID) => {
            return answer.map_or(Outcome::Closed, Outcome::Answer);
        }
        () = interrupts.next() => {}
    }
    // RED stub: Ctrl-C ends the run at once on both paths.
    let _ = (cancel_frame, CANCEL_ID, cancel_wait, CANCELLED_CODE);
    Outcome::Interrupted
}

/// The next line that answers request `id` (other lines, such as the
/// cancel-request reply or events, are skipped). None when the stream ends.
async fn answer_to<R: tokio::io::AsyncBufRead + Unpin>(
    lines: &mut tokio::io::Lines<R>,
    id: &str,
) -> Option<Value> {
    while let Ok(Some(line)) = lines.next_line().await {
        let Ok(value) = serde_json::from_str::<Value>(&line) else { continue };
        if value["id"] == id {
            return Some(value);
        }
    }
    None
}

async fn send<W: AsyncWrite + Unpin>(writer: &mut W, value: &Value) -> std::io::Result<()> {
    let mut line = value.to_string();
    line.push('\n');
    writer.write_all(line.as_bytes()).await?;
    writer.flush().await
}

/// `<app> <op> [--args JSON]`; the idempotency key is the global
/// `--idempotency-key`.
pub(super) fn parse(args: &[String], idempotency_key: Option<String>) -> Result<AppOp, String> {
    let usage = || messages().usage.to_string();
    let (app, op, rest) = match args {
        [app, op, rest @ ..] if !app.starts_with('-') && !op.starts_with('-') => (app, op, rest),
        _ => return Err(usage()),
    };
    let args = match rest {
        [] => json!({}),
        [flag, value] if flag == "--args" => {
            let value: Value = serde_json::from_str(value)
                .map_err(|error| messages().bad_args.replace("{error}", &error.to_string()))?;
            if !value.is_object() {
                return Err(messages().bad_args.replace("{error}", "not an object"));
            }
            value
        }
        _ => return Err(usage()),
    };
    Ok(AppOp { app: app.clone(), op: op.clone(), args, idempotency_key })
}

/// What to print and the exit code for an outcome.
pub(super) fn report(outcome: &Outcome, output: OutputMode) -> (Option<String>, Option<String>, i32) {
    match outcome {
        Outcome::Answer(answer) if answer["ok"] == true => {
            let data = answer.get("data").cloned().unwrap_or(json!({}));
            let text = match output {
                OutputMode::Quiet => None,
                _ => Some(data.to_string()),
            };
            (text, None, 0)
        }
        Outcome::Answer(answer) => {
            let code = answer["error_code"].as_str().unwrap_or("error");
            let message = answer["error"].as_str().unwrap_or("");
            let mut text = format!("cmux: {code}: {message}");
            if let Some(hint) = error_hint(code) {
                text.push_str("\n");
                text.push_str(hint);
            }
            if let Some(details) = answer.get("error_details").filter(|details| !details.is_null()) {
                text.push_str(&format!("\n{details}"));
            }
            (None, Some(text), 1)
        }
        Outcome::Cancelled { confirmed: true } | Outcome::Interrupted => {
            (None, Some(messages().cancelled.to_string()), EXIT_CANCELLED)
        }
        Outcome::Cancelled { confirmed: false } => {
            (None, Some(messages().cancel_unconfirmed.to_string()), EXIT_CANCELLED)
        }
        Outcome::Closed => (None, Some(format!("cmux: {}", messages().closed)), 3),
    }
}

/// What the user can do about an error the CLI meets by design.
fn error_hint(code: &str) -> Option<&'static str> {
    match code {
        "apps.gesture_required" => Some(messages().gesture_required),
        "apps.scope_missing" => Some(messages().scope_missing),
        _ => None,
    }
}

/// `cmux [global options] apps run ...` when `args` names it.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let rest = command_args.strip_prefix(&VERB.map(str::to_string)[..])?;
    Some(run(&global, rest))
}

/// Ctrl-C from the process's SIGINT.
struct SigInt(tokio::signal::unix::Signal);

impl Interrupts for SigInt {
    async fn next(&mut self) {
        if self.0.recv().await.is_none() {
            std::future::pending::<()>().await;
        }
    }
}

fn run(global: &GlobalArgs, args: &[String]) -> i32 {
    if matches!(args, [flag] if matches!(flag.as_str(), "-h" | "--help" | "help")) {
        println!("{}", messages().usage);
        return 0;
    }
    let request = match parse(args, global.idempotency_key.clone()) {
        Ok(request) => request,
        Err(message) => {
            eprintln!("cmux: {message}");
            return 2;
        }
    };
    let Ok((socket, _)) = super::wire::resolve_socket_with_origin(global) else {
        eprintln!("cmux: {}", crate::localization::catalog().startup.invalid_session_name);
        return 2;
    };
    let Ok(runtime) = tokio::runtime::Builder::new_current_thread().enable_all().build() else {
        return 3;
    };
    let outcome = runtime.block_on(async {
        let connect_failed = |error: String| {
            messages()
                .connect_failed
                .replace("{path}", &socket.display().to_string())
                .replace("{error}", &error)
        };
        let stream = tokio::net::UnixStream::connect(&socket)
            .await
            .map_err(|error| connect_failed(error.to_string()))?;
        // Only this user's daemon (as every CLI connection checks).
        // SAFETY: geteuid has no preconditions.
        let own = unsafe { libc::geteuid() };
        let peer = stream.peer_cred().map_err(|error| connect_failed(error.to_string()))?;
        if peer.uid() != own && peer.uid() != 0 {
            return Err(connect_failed(format!("the socket belongs to uid {}", peer.uid())));
        }
        let interrupts = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())
            .map_err(|error| error.to_string())?;
        Ok::<_, String>(run_app_op(stream, &request, SigInt(interrupts), CANCEL_WAIT).await)
    });
    let outcome = match outcome {
        Ok(outcome) => outcome,
        Err(message) => {
            eprintln!("cmux: {message}");
            return 3;
        }
    };
    let (stdout, stderr, code) = report(&outcome, global.output);
    if let Some(text) = stdout {
        println!("{text}");
    }
    if let Some(text) = stderr {
        eprintln!("{text}");
    }
    code
}
