//! `cmux cloud api`: one Cloud API call (`cmux_cloud_api`'s calls: machines, tunnel, firewall,
//! domains, publications, sandboxed Runs, the person's hand-offs and acpmux routes, previews,
//! machine files and exec), sent to the daemon's `cloud.<call>` op (cmux-tui-core
//! `server/cloud_api.rs`), which runs it.
//!
//! Request: one JSON object on stdin (credentials never go in argv, which other processes can
//! read), `cmux_cloud_api::Request`'s fields:
//!
//! ```json
//! {"call": "vm.resize", "api": "https://cmux.com", "auth": "stack|owner|worker",
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

use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::path::Path;
use std::time::Duration;

use base64::Engine as _;
use cmux_cloud_api::{Failure, Request, answer_line, parse, scrub};
use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::GlobalArgs;

/// The largest reply read (the daemon's own reply limit, and room for its frame).
const MAX_REPLY: u64 = 33 * 1024 * 1024;
/// Added to the call's own longest time while waiting on the daemon.
const REPLY_MARGIN: Duration = Duration::from_secs(30);
const REQUEST_ID: &str = "cloud-api";

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

/// The daemon frame for `request` (module docs of cmux-tui-core `server/cloud_api.rs`).
pub(super) fn frame(request: &Request, key: &[u8]) -> Zeroizing<Vec<u8>> {
    let mut frame = serde_json::Map::new();
    let fields = json!({
        "id": REQUEST_ID,
        "cmd": format!("cloud.{}", request.call),
        "api": request.api,
        "auth": request.auth,
        "access_token": request.credential,
        "local_only": request.local_only,
        "args": request.args,
    });
    if let Value::Object(fields) = fields {
        frame = fields;
    }
    for (name, value) in [
        ("refresh_token", &request.refresh),
        ("team", &request.team),
        ("app_version", &request.app_version),
    ] {
        if let Some(value) = value {
            frame.insert(name.to_owned(), json!(value));
        }
    }
    let mut bytes = Zeroizing::new(serde_json::to_vec(&frame).unwrap_or_default());
    if !key.is_empty() && bytes.pop() == Some(b'}') {
        // Spliced in, so the key's text is only ever in buffers that are wiped.
        let encoded = Zeroizing::new(base64::engine::general_purpose::STANDARD.encode(key));
        bytes.extend_from_slice(b",\"key_base64\":\"");
        bytes.extend_from_slice(encoded.as_bytes());
        bytes.extend_from_slice(b"\"}");
    }
    bytes.push(b'\n');
    bytes
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
    call_socket(&socket, derived, request, key)
}

/// [`call`] on the daemon at `socket`.
pub(super) fn call_socket(
    socket: &Path,
    derived: bool,
    request: &Request,
    key: &[u8],
) -> Result<Value, Failure> {
    let unreachable = |e: std::io::Error| {
        Failure::Transport(format!("the cmux daemon could not be reached: {e}"))
    };
    let stream =
        cmux_tui_core::server::connect_session_socket(socket, derived).map_err(unreachable)?;
    let wait = cmux_cloud_api::longest(request).saturating_add(REPLY_MARGIN);
    let _ = stream.set_write_timeout(Some(Duration::from_secs(10)));
    let _ = stream.set_read_timeout(Some(wait));
    let mut reader = BufReader::new(stream);
    let mut launch = Value::Object(serde_json::Map::new());
    super::launch_credential::attach(&mut reader, socket, &mut launch);
    let mut bytes = frame(request, key);
    if let Some(credential) = launch.get("credential").and_then(Value::as_str) {
        // `{"credential": …,` before the frame's other fields.
        let mut with =
            Zeroizing::new(format!("{{\"credential\":{},", json!(credential)).into_bytes());
        with.extend(bytes.iter().skip(1));
        bytes = with;
    }
    reader.get_mut().write_all(&bytes).map_err(unreachable)?;
    drop(bytes);
    let mut line = String::new();
    reader.take(MAX_REPLY).read_line(&mut line).map_err(|e| {
        // The call may have run (a create); the answer is what is lost.
        Failure::TimedOut(format!("cloud.{} ({e})", request.call))
    })?;
    read_reply(&line)
}

/// The daemon's reply as the call's answer.
pub(super) fn read_reply(line: &str) -> Result<Value, Failure> {
    let lost = || Failure::Transport("the cmux daemon's answer could not be read".into());
    if !line.ends_with('\n') {
        return Err(lost());
    }
    let mut reply: Value = serde_json::from_str(line).map_err(|_| lost())?;
    if reply.get("id").and_then(Value::as_str) != Some(REQUEST_ID) {
        return Err(lost());
    }
    if reply.get("ok") == Some(&Value::Bool(true)) {
        return Ok(reply.get_mut("data").map(Value::take).unwrap_or(Value::Null));
    }
    match reply.get("failure").cloned().map(failure) {
        Some(Some(failure)) => Err(failure),
        _ => Err(Failure::Transport(
            reply
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("the cmux daemon refused the call")
                .to_owned(),
        )),
    }
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
