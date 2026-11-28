//! `cmux cloud install-post`: one JSON POST to the cmux API for the Mac app's install-auth and owner
//! calls (its `InstallHTTPTransport`: the install key exchange, `v1/read` and `v1/ops` as the person,
//! the credential relay, the Cloud pre-approval, a hub approval answer). The app has no Cloud HTTP of
//! its own; it runs this with the request on stdin (the bearer never goes in argv) and reads one line:
//! `{ok: true, status, body}` (any HTTP status, the body as text) or `{ok: false, error: {kind, message}}`
//! when no answer came (`kind`: `invalid`, `timeout`, `connect`, `transport`).
//!
//! ```json
//! {"api": "https://…", "path": "v1/ops", "body": "{…}", "bearer": "…"|null, "headers": {"x-cmux-team": "…"}}
//! ```
//!
//! Redirects are refused and nothing is cached (`cmux_cloud_client::http`, which also carries this
//! process's build space). Some networks black-hole one connection's 5-tuple while a new socket
//! connects at once (measured 2026-11-17), so a read (`v1/read`, `v1/auth/challenge`) is hedged on
//! fresh clients and a keyed mutation (a body with an `idempotency_key`) is sent once more after a
//! connection failure, with the same key ([`replay`]).

use std::collections::BTreeMap;
use std::future::Future;
use std::io::{Read as _, Write as _};
use std::time::Duration;

use serde_json::{Value, json};

// timeout: one attempt's bound (connect included), as the app's old per-request timeout.
const TIMEOUT: Duration = Duration::from_secs(15);
// short-gate: a hedge, not a give-up; each attempt keeps its own TIMEOUT.
const STAGGER: Duration = Duration::from_secs(1);
const MAX_ATTEMPTS: usize = 3;

/// `Some(exit code)` when `args` is `cloud install-post`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (_global, command_args) = super::parse_globals(args).ok()?;
    let [cloud, noun, rest @ ..] = command_args.as_slice() else { return None };
    if cloud != "cloud" || noun != "install-post" {
        return None;
    }
    let answer = if rest.is_empty() {
        let mut input = Vec::new();
        match std::io::stdin().read_to_end(&mut input) {
            Ok(_) => post_blocking(&input),
            Err(_) => failure("invalid", "the request could not be read"),
        }
    } else {
        failure("invalid", "cmux cloud install-post takes its request as JSON on stdin")
    };
    let mut stdout = std::io::stdout().lock();
    let written = writeln!(stdout, "{answer}").and_then(|()| stdout.flush());
    Some(if written.is_ok() && answer.get("ok") == Some(&Value::Bool(true)) { 0 } else { 1 })
}

fn post_blocking(input: &[u8]) -> Value {
    let _ = rustls::crypto::ring::default_provider().install_default();
    match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime.block_on(post(input)),
        Err(error) => failure("transport", &error.to_string()),
    }
}

fn failure(kind: &str, message: &str) -> Value {
    json!({"ok": false, "error": {"kind": kind, "message": message}})
}

/// How a request may be sent again.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Replay {
    /// Racing copies cost nothing but a read.
    Hedge,
    /// Sent again after a connection failure, with the same idempotency key.
    RetryOnce,
    /// Sent once.
    Never,
}

/// The replay a POST to `path` with `body` allows.
pub(super) fn replay(path: &str, body: &str) -> Replay {
    let path = path.trim_end_matches('/');
    if path.ends_with("v1/read") || path.ends_with("v1/auth/challenge") {
        return Replay::Hedge;
    }
    let keyed = serde_json::from_str::<Value>(body).ok().is_some_and(|object| {
        object.get("idempotency_key").and_then(Value::as_str).is_some_and(|key| !key.is_empty())
    });
    if keyed { Replay::RetryOnce } else { Replay::Never }
}

/// `base` joined with `path` (`/` between them), or why `base` may not carry a bearer.
pub(super) fn target(base: &str, path: &str) -> Result<String, String> {
    let url =
        reqwest::Url::parse(base.trim()).map_err(|_| "the cmux API is not a URL".to_owned())?;
    let local = matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"));
    if url.host_str().is_none() || !url.username().is_empty() || url.password().is_some() {
        return Err("the cmux API URL must not name a user".into());
    }
    if url.scheme() != "https" && !(url.scheme() == "http" && local) {
        return Err("the cmux API is not https: a credential never goes over plain http".into());
    }
    if path.contains(['?', '#']) || path.split('/').any(|part| part == "..") {
        return Err("the path must be a plain API path".into());
    }
    Ok(format!("{}/{}", base.trim().trim_end_matches('/'), path.trim_start_matches('/')))
}

struct Request {
    url: String,
    path: String,
    body: String,
    bearer: Option<String>,
    headers: BTreeMap<String, String>,
}

fn request(input: &[u8]) -> Result<Request, String> {
    let envelope = serde_json::from_slice::<Value>(input)
        .ok()
        .filter(Value::is_object)
        .ok_or("the request is not a JSON object")?;
    let api = envelope.get("api").and_then(Value::as_str).ok_or("no cmux API origin")?;
    let path = envelope.get("path").and_then(Value::as_str).ok_or("no path")?;
    let body = envelope.get("body").and_then(Value::as_str).unwrap_or("").to_owned();
    let bearer = envelope
        .get("bearer")
        .and_then(Value::as_str)
        .filter(|bearer| !bearer.is_empty())
        .map(str::to_owned);
    let mut headers = BTreeMap::new();
    if let Some(given) = envelope.get("headers").and_then(Value::as_object) {
        for (name, value) in given {
            let value = value.as_str().ok_or("a header value is not a string")?;
            headers.insert(name.clone(), value.to_owned());
        }
    }
    Ok(Request { url: target(api, path)?, path: path.to_owned(), body, bearer, headers })
}

/// Why an attempt got no answer.
#[derive(Debug)]
pub(super) struct Failed {
    kind: &'static str,
    message: String,
}

impl Failed {
    fn connection(&self) -> bool {
        matches!(self.kind, "connect" | "timeout")
    }
}

/// One attempt on a fresh client (its own pool, so a new socket).
async fn attempt(request: &Request) -> Result<(u16, String), Failed> {
    let user_agent = concat!("cmux/", env!("CARGO_PKG_VERSION"));
    let (_base, http) =
        cmux_cloud_client::http(&request.url, request.bearer.as_deref(), None, user_agent, TIMEOUT)
            .map_err(|error| Failed { kind: "invalid", message: error.to_string() })?;
    let mut builder = http
        .post(&request.url)
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .body(request.body.clone());
    for (name, value) in &request.headers {
        let name = reqwest::header::HeaderName::try_from(name.as_str());
        let value = reqwest::header::HeaderValue::try_from(value.as_str());
        let (Ok(name), Ok(value)) = (name, value) else {
            return Err(Failed { kind: "invalid", message: "a header is not valid HTTP".into() });
        };
        builder = builder.header(name, value);
    }
    let sent = |error: reqwest::Error| {
        let kind = if error.is_timeout() {
            "timeout"
        } else if error.is_connect() {
            "connect"
        } else {
            "transport"
        };
        Failed { kind, message: error.without_url().to_string() }
    };
    let response = builder.send().await.map_err(sent)?;
    let status = response.status().as_u16();
    let body = response.bytes().await.map_err(sent)?;
    Ok((status, String::from_utf8_lossy(&body).into_owned()))
}

/// Runs `attempt` as `replay` allows: once; once more after a connection failure (`RetryOnce`); or
/// raced (`Hedge`): another every `stagger` (at once when every running one failed) up to
/// `max_attempts`, the first answer wins and the rest are dropped.
pub(super) async fn send<T, F, Fut>(
    replay: Replay,
    stagger: Duration,
    max_attempts: usize,
    attempt: F,
) -> Result<T, Failed>
where
    F: Fn() -> Fut,
    Fut: Future<Output = Result<T, Failed>>,
{
    match replay {
        Replay::Never => attempt().await,
        Replay::RetryOnce => match attempt().await {
            Err(failed) if failed.connection() => attempt().await,
            done => done,
        },
        Replay::Hedge => {
            let mut running = futures_util::stream::FuturesUnordered::new();
            running.push(attempt());
            let mut launched = 1;
            let mut last = None;
            loop {
                use futures_util::StreamExt as _;
                let more = launched < max_attempts.max(1);
                tokio::select! {
                    next = running.next() => match next {
                        Some(Ok(value)) => return Ok(value),
                        Some(Err(failed)) => {
                            last = Some(failed);
                            if running.is_empty() {
                                if !more { break; }
                                running.push(attempt());
                                launched += 1;
                            }
                        }
                        None => break,
                    },
                    () = tokio::time::sleep(stagger), if more => {
                        running.push(attempt());
                        launched += 1;
                    }
                }
            }
            Err(last.unwrap_or(Failed { kind: "transport", message: "no attempt ran".into() }))
        }
    }
}

/// Sends one stdin request.
pub(super) async fn post(input: &[u8]) -> Value {
    let request = match request(input) {
        Ok(request) => request,
        Err(message) => return failure("invalid", &message),
    };
    let replay = replay(&request.path, &request.body);
    match send(replay, STAGGER, MAX_ATTEMPTS, || attempt(&request)).await {
        Ok((status, body)) => json!({"ok": true, "status": status, "body": body}),
        Err(failed) => failure(failed.kind, &failed.message),
    }
}

#[cfg(test)]
#[path = "cloud_install_post_tests.rs"]
mod tests;
