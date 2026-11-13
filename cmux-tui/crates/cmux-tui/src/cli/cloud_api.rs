//! `cmux cloud api`: one Cloud API call (`cmux_cloud_api`'s calls: machines, tunnel, firewall,
//! domains, publications, sandboxed Runs, the person's hand-offs and acpmux routes, previews,
//! machine files and exec), sent as the daemon's `cmux.protocol/2` operation `cloud.<call>`
//! (cmux-tui-core `server/cloud_api.rs`), which runs it.
//!
//! Request: one JSON object on stdin (credentials never go in argv, which other processes can
//! read), `cmux_cloud_api::Request`'s fields:
//!
//! ```json
//! {"call": "vm.domains", "api": "https://cmux.com", "auth": "stack|owner|worker",
//!  "credential": "…", "refresh": "…", "team": "…", "app_version": "…", "local_only": false,
//!  "args": {…}}
//! ```
//!
//! `owner.acpmux_keyed_start` sends the person key after that object: the JSON, one `\n`, then
//! exactly `args.key_length` bytes.
//!
//! Answer: one JSON line on stdout, `{"ok": true, "body": B}` or `{"ok": false, "error": E}`
//! (`cmux_cloud_api::answer_line`). Exit 0 for `ok`, 1 for a refusal or a daemon that could not
//! be reached, 2 for a request that is not one.

use std::io::{BufReader, Read as _, Write as _};
use std::path::Path;
use std::time::Duration;

use base64::Engine as _;
use cmux_cloud_api::{Failure, Request, answer_line, parse, scrub};
use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Map, Value, json};
use zeroize::Zeroizing;

use super::GlobalArgs;

/// Added to the call's own longest time while waiting on the daemon.
const REPLY_MARGIN: Duration = Duration::from_secs(30);

/// `Some(exit code)` when `args` is `cloud api`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let [cloud, noun, rest @ ..] = command_args.as_slice() else { return None };
    if cloud != "cloud" || noun != "api" {
        return None;
    }
    let stdout = std::io::stdout();
    let mut stdout = stdout.lock();
    let refuse = |stdout: &mut dyn std::io::Write, message: &str| {
        let _ = writeln!(stdout, "{}", answer_line(&Err(Failure::Transport(message.into()))));
        Some(2)
    };
    if !rest.is_empty() {
        return refuse(&mut stdout, "cmux cloud api takes its request as JSON on stdin");
    }
    let mut input = Zeroizing::new(Vec::new());
    if std::io::stdin().read_to_end(&mut input).is_err() {
        return refuse(&mut stdout, "the request could not be read");
    }
    let (request, tail) = match parse(&input) {
        Ok(parsed) => parsed,
        Err(message) => return refuse(&mut stdout, &message),
    };
    drop(input);
    if !cmux_cloud_api::CALLS.contains(&request.call.as_str()) {
        return refuse(&mut stdout, &format!("no cloud api call {:?}", request.call));
    }
    let result = call(&global, &request, &tail);
    let line = scrub(answer_line(&result), &request);
    if writeln!(stdout, "{line}").and_then(|()| stdout.flush()).is_err() {
        return Some(1);
    }
    Some(if result.is_ok() { 0 } else { 1 })
}

/// The operation's params for `request`: the route, then the call's fields (module docs of
/// cmux-tui-core `server/cloud_api.rs`).
pub(super) fn params(request: &Request, key: &[u8], session: Option<&str>) -> Map<String, Value> {
    let mut params = Map::new();
    params.insert("machine".into(), json!("current"));
    params.insert("session".into(), json!(session.unwrap_or("current")));
    params.insert("api".into(), json!(request.api));
    params.insert("auth".into(), json!(request.auth));
    params.insert("access_token".into(), json!(request.credential));
    params.insert("local_only".into(), json!(request.local_only));
    params.insert("args".into(), Value::Object(request.args.clone()));
    for (name, value) in [
        ("refresh_token", &request.refresh),
        ("team", &request.team),
        ("app_version", &request.app_version),
    ] {
        if let Some(value) = value {
            params.insert(name.to_owned(), json!(value));
        }
    }
    if !key.is_empty() {
        let encoded = Zeroizing::new(base64::engine::general_purpose::STANDARD.encode(key));
        params.insert("key_base64".into(), json!(encoded.as_str()));
    }
    params
}

/// Sends `request` to the daemon of `global`'s session and reads its answer.
fn call(global: &GlobalArgs, request: &Request, key: &[u8]) -> Result<Value, Failure> {
    if global.machine.is_some() {
        return Err(Failure::Transport(
            "cmux cloud api runs on this Mac's daemon; drop --machine".into(),
        ));
    }
    let (socket, derived) = super::wire::resolve_socket_with_origin(global)
        .map_err(|e| Failure::Transport(super::wire::resolve_failure_message(&e)))?;
    call_socket(&socket, derived, global.session.as_deref(), request, key)
}

/// [`call`] on the daemon at `socket`, as the `cloud.<call>` operation.
pub(super) fn call_socket(
    socket: &Path,
    derived: bool,
    session: Option<&str>,
    request: &Request,
    key: &[u8],
) -> Result<Value, Failure> {
    let wire = format!("cloud.{}", request.call);
    let operation: ResourceOperation = serde_json::from_value(json!(wire))
        .map_err(|_| Failure::Transport(format!("no cloud api call {:?}", request.call)))?;
    let stream = cmux_tui_core::server::connect_session_socket(socket, derived)
        .map_err(|e| Failure::Transport(format!("the cmux daemon could not be reached: {e}")))?;
    let wait = cmux_cloud_api::longest(request).saturating_add(REPLY_MARGIN);
    let _ = stream.set_write_timeout(Some(Duration::from_secs(10)));
    let _ = stream.set_read_timeout(Some(wait));
    let mut reader = BufReader::new(stream);
    let credential = super::launch_credential::for_connection(&mut reader, socket);
    let idempotency_key = if operation.is_mutation() {
        Some(
            super::wire::random_idempotency_key()
                .map_err(|e| Failure::Transport(format!("cmux: {e}")))?,
        )
    } else {
        None
    };
    let answer = super::resolve::call_as(
        &mut reader,
        operation,
        params(request, key, session),
        idempotency_key.as_deref(),
        credential.as_deref(),
    );
    match answer {
        Ok(mut result) if operation.is_mutation() => {
            Ok(result.get_mut("value").map(Value::take).unwrap_or(Value::Null))
        }
        Ok(result) => Ok(result),
        Err(super::resolve::Failure::Resource(error)) => Err(from_error(&error)),
        Err(super::resolve::Failure::Transport(message)) => Err(Failure::Transport(message)),
        Err(super::resolve::Failure::Refused) => {
            Err(Failure::Transport("the cmux daemon refused the connection".into()))
        }
        Err(super::resolve::Failure::Local { error, .. }) => Err(from_error(&error)),
        Err(super::resolve::Failure::AppAction { action, .. }) => {
            Err(Failure::Transport(format!("cloud.{} is the app's ({action})", request.call)))
        }
    }
}

/// A daemon resource error as the call's failure: the library's own failure when the daemon
/// ran the call (`details.extra.failure`), else a transport failure with its message.
pub(super) fn from_error(error: &Value) -> Failure {
    error.pointer("/details/extra/failure").cloned().and_then(failure).unwrap_or_else(|| {
        Failure::Transport(
            error
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("the cmux daemon refused the call")
                .to_owned(),
        )
    })
}

/// A `Failure::json` object read back.
fn failure(value: Value) -> Option<Failure> {
    let text = |name: &str| value.get(name).and_then(Value::as_str).map(str::to_owned);
    Some(match value.get("kind")?.as_str()? {
        "timed_out" => Failure::TimedOut(text("path").unwrap_or_default()),
        "transport" => Failure::Transport(text("message").unwrap_or_default()),
        "no_backend" => Failure::NoBackend,
        "http" => Failure::Http {
            status: value
                .get("status")
                .and_then(Value::as_u64)
                .and_then(|s| u16::try_from(s).ok())?,
            code: text("code"),
            message: text("message"),
            action: text("action"),
            trace_id: text("trace_id"),
            retryable: value.get("retryable").and_then(Value::as_bool),
            retry_after_s: value.get("retry_after_s").and_then(Value::as_u64),
        },
        "plan_required" => Failure::PlanRequired {
            message: text("message"),
            upgrade_url: text("upgrade_url"),
            plan: text("plan")?,
        },
        "decoding" => Failure::Decoding(text("message").unwrap_or_default()),
        _ => return None,
    })
}

#[cfg(test)]
#[path = "cloud_api_tests.rs"]
mod tests;
