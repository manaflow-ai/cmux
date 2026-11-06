//! `cmux cloud api`: the macOS app's Cloud API calls (machines, tunnel, firewall, domains,
//! publications, sandboxed Runs, the person's hand-offs and acpmux routes, previews). The app
//! used to send these from Swift (`CloudAPIClient`, `CloudOwnerAPIClient`); the requests, their
//! deadlines, the retry of a lost Run create, the long-poll to a Run's receipt, the hand-off
//! paging and every refusal's reading live here now, and the app only forwards (its
//! `BundledCmux` runner, `Sources/CmuxNextCloud/API/BundledCmux.swift`).
//!
//! Request: one JSON object on stdin (credentials never go in argv, which other processes can read):
//!
//! ```json
//! {"call": "vm.resize", "api": "https://cmux.com", "auth": "stack|owner|worker",
//!  "credential": "…", "refresh": "…", "team": "…", "app_version": "…", "local_only": false,
//!  "args": {…}}
//! ```
//!
//! `machine.io` is a machine's exec or file operation (its `args` are `cmux cloud machine-io`'s
//! request fields: `op`, `machine`, `path`, …): a Worker machine's runs machine-io's logic, a classic
//! one `/api/vm/{id}/exec` and `/fs/*`.
//!
//! `owner.acpmux_keyed_start` sends the person key after that object: the JSON, one `\n`, then
//! exactly `args.key_length` bytes, so the key is never part of a JSON value.
//!
//! Answer: one JSON line on stdout, `{"ok": true, "body": B}` or `{"ok": false, "error": E}`,
//! where `E.kind` is `timed_out` (with `path`), `transport` (`message`), `no_backend`, `http`
//! (`status`, `code`, `message`, `action`, `trace_id`), `plan_required` (`message`, `upgrade_url`,
//! `plan`) or `decoding` (`message`): the app's `CloudAPIError` cases one for one. Exit 0 for
//! `ok`, 1 for a refusal, 2 for a request that is not one.
//!
//! Auth: `stack` is classic cmux.com's (`/api/vm`, `/api/runs`): the Stack access token as the
//! bearer, the refresh token in `X-Stack-Refresh-Token`, the team in `X-Cmux-Team-Id`. `owner` is
//! the cmux API Worker's person routes: `Authorization` and `x-cmux-team` only (the Worker's
//! invocation log records every other header and the URL, so nothing else may carry a key).
//! `worker` is the platform's machine routes through the generated client. No redirect is
//! followed and nothing is cached.

mod classic;
mod http;
mod machine;
mod owner;
mod previews;
mod runs;

use std::io::{Read as _, Write as _};

use serde_json::{Map, Value, json};
use zeroize::Zeroizing;

use super::cloud_client_session::redact;
pub(super) use http::{Auth, Failure, Http};

/// One call as the app sends it.
#[derive(Debug, Clone, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Request {
    pub(super) call: String,
    pub(super) api: String,
    pub(super) auth: Auth,
    pub(super) credential: String,
    #[serde(default)]
    pub(super) refresh: Option<String>,
    #[serde(default)]
    pub(super) team: Option<String>,
    #[serde(default)]
    pub(super) app_version: Option<String>,
    /// The build points at a loopback backend: a refused connection is `no_backend`.
    #[serde(default)]
    pub(super) local_only: bool,
    #[serde(default)]
    pub(super) args: Map<String, Value>,
}

/// `Some(exit code)` when `args` is `cloud api`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (_global, command_args) = super::parse_globals(args).ok()?;
    let [cloud, noun, rest @ ..] = command_args.as_slice() else { return None };
    if cloud != "cloud" || noun != "api" {
        return None;
    }
    let stdout = std::io::stdout();
    let mut stdout = stdout.lock();
    if !rest.is_empty() {
        let line = answer_line(&Err(Failure::Transport(
            "cmux cloud api takes its request as JSON on stdin".into(),
        )));
        let _ = writeln!(stdout, "{line}");
        return Some(2);
    }
    let mut input = Zeroizing::new(Vec::new());
    if std::io::stdin().read_to_end(&mut input).is_err() {
        let _ = writeln!(
            stdout,
            "{}",
            answer_line(&Err(Failure::Transport("the request could not be read".into())))
        );
        return Some(2);
    }
    let (request, tail) = match parse(&input) {
        Ok(parsed) => parsed,
        Err(message) => {
            let _ = writeln!(stdout, "{}", answer_line(&Err(Failure::Transport(message))));
            return Some(2);
        }
    };
    let result = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime.block_on(perform(&request, tail)),
        Err(e) => Err(Failure::Transport(e.to_string())),
    };
    drop(input);
    let line = scrub(answer_line(&result), &request);
    if writeln!(stdout, "{line}").and_then(|()| stdout.flush()).is_err() {
        return Some(1);
    }
    Some(if result.is_ok() { 0 } else { 1 })
}

/// The request object and, after its line, the raw bytes a keyed start sends.
pub(super) fn parse(input: &[u8]) -> Result<(Request, Zeroizing<Vec<u8>>), String> {
    let mut parts = input.splitn(2, |&b| b == b'\n');
    let (head, tail) = (parts.next().unwrap_or_default(), parts.next().unwrap_or_default());
    let mut request: Request = serde_json::from_slice(head)
        .map_err(|_| "the request is not a cloud api request".to_owned())?;
    request.credential = request.credential.trim().to_owned();
    request.api = request.api.trim().to_owned();
    Ok((request, Zeroizing::new(tail.to_vec())))
}

/// Runs one call.
pub(super) async fn perform(request: &Request, tail: Zeroizing<Vec<u8>>) -> Result<Value, Failure> {
    // The GitHub App status sends Authorization alone: its team is in the query.
    let http = if request.call == "owner.github_app" {
        Http::new(&Request { team: None, ..request.clone() })?
    } else {
        Http::new(request)?
    };
    let args = &request.args;
    match request.call.as_str() {
        "machine.io" if request.auth == Auth::Stack => machine::classic(&http, args).await,
        "machine.io" => machine::worker(request).await,
        call if call.starts_with("vm.") => classic::run(&http, call, args).await,
        "runs.create" => runs::create(&http, args).await,
        "runs.start" => runs::start(&http, args).await,
        "runs.wait" => runs::wait(&http, args).await,
        "runs.cancel" => runs::cancel(&http, args).await,
        "runs.sandbox" => runs::sandbox(&http, args).await,
        "owner.acpmux_keyed_start" => owner::keyed_start(&http, args, tail).await,
        call if call.starts_with("owner.") => owner::run(&http, call, args).await,
        call if call.starts_with("previews.") => previews::run(request, call, args).await,
        other => Err(Failure::Transport(format!("no cloud api call {other:?}"))),
    }
}

/// The answer line.
pub(super) fn answer_line(result: &Result<Value, Failure>) -> String {
    match result {
        Ok(body) => json!({ "ok": true, "body": body }).to_string(),
        Err(failure) => json!({ "ok": false, "error": failure.json() }).to_string(),
    }
}

/// A refusal never carries the caller's credentials back (a server or proxy that echoed one).
fn scrub(line: String, request: &Request) -> String {
    if line.starts_with(r#"{"ok":true"#) {
        return line;
    }
    let refresh = request.refresh.as_deref().unwrap_or_default();
    redact(&line, refresh, &request.credential)
}

// MARK: argument readers

pub(super) fn text<'a>(args: &'a Map<String, Value>, name: &str) -> Result<&'a str, Failure> {
    args.get(name)
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::Transport(format!("the call needs {name}")))
}

pub(super) fn optional_text<'a>(args: &'a Map<String, Value>, name: &str) -> Option<&'a str> {
    args.get(name).and_then(Value::as_str)
}

pub(super) fn optional_int(args: &Map<String, Value>, name: &str) -> Option<i64> {
    args.get(name).and_then(Value::as_i64)
}

/// The listed fields of `args` that are present, as a JSON object.
pub(super) fn pick(args: &Map<String, Value>, names: &[&str]) -> Value {
    let mut body = Map::new();
    for name in names {
        if let Some(value) = args.get(*name).filter(|v| !v.is_null()) {
            body.insert((*name).to_owned(), value.clone());
        }
    }
    Value::Object(body)
}

#[cfg(test)]
mod tests;
