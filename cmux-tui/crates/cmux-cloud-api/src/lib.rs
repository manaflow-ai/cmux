//! NEXT Cloud's API calls, one library for the cmux daemon's `cloud.*` ops (cmux-tui-core
//! `server/cloud_api.rs`) and the cmux CLI (`cmux cloud api`, which sends its request to the
//! daemon): a machine's SCP route, domains, publications, sandboxed Runs, the person's hand-offs
//! and acpmux routes, previews and a machine's files and exec. The macOS app sent these
//! from Swift (`CloudAPIClient`, `CloudOwnerAPIClient`); the requests, their deadlines, the retry
//! of a lost Run create, the long-poll to a Run's receipt, the hand-off paging and every refusal's
//! reading live here.
//!
//! A call is a [`Request`]: its name (`call`, one of [`CALLS`]), the API's base URL, the auth
//! (`stack|owner|worker`), the caller's `credential` (and classic's `refresh`), the `team`, the
//! `app_version`, `local_only` and the call's `args`. Credentials come with each call and are
//! never kept, logged or put in a URL.
//!
//! `machine.io` is a machine's exec or file operation (its `args` are [`machine_io::Request`]'s
//! fields: `op`, `machine`, `path`, …): a Worker machine's runs [`machine_io`]'s logic; a `stack`
//! one is refused before any request. `vm.scp_endpoint` is cmux-platform's
//! `/v1/cloud/machines/{id}/ssh-endpoint` (a `stack` call is refused before any request).
//!
//! Classic cmux.com's `/api/vm` is gone from NEXT: the tunnel and firewall calls
//! ([`NOT_ON_THIS_CLOUD`]) have no cmux-platform route yet, so each answers a 501
//! `cloud.not_available` at once and sends nothing.
//!
//! `owner.acpmux_keyed_start` takes the person key as raw bytes beside the request (exactly
//! `args.key_length` of them), so the key is never part of a JSON value here.
//!
//! `owner.turn_checkpoint`, `owner.turn_rewind` and `owner.turns` are a Cloud chat's "back to
//! before this turn": whole-machine turn checkpoints on cmux-platform (`turns.rs`).
//!
//! An answer is `Ok(body)` or a [`Failure`]; [`answer_line`] writes `{"ok": true, "body": B}` or
//! `{"ok": false, "error": E}`, where `E.kind` is `timed_out` (with `path`), `transport`
//! (`message`), `no_backend`, `http` (`status`, `code`, `message`, `action`, `trace_id`),
//! `plan_required` (`message`, `upgrade_url`, `plan`) or `decoding` (`message`): the app's
//! `CloudAPIError` cases one for one.
//!
//! Auth: `stack` is classic cmux.com's sandboxed Runs (`/api/runs`): the Stack access token as the
//! bearer, the refresh token in `X-Stack-Refresh-Token`, the team in `X-Cmux-Team-Id`. `owner` is
//! the cmux API Worker's person routes: `Authorization` and `x-cmux-team` only (the Worker's
//! invocation log records every other header and the URL, so nothing else may carry a key).
//! `worker` is the platform's machine routes through the generated client, `previews.*` and the
//! publication calls (`vm.domains`, `vm.publications`, `vm.provision_api`,
//! `vm.publication_api_keys`, `vm.revoke_publication_api_key`) among them. No redirect is followed
//! and nothing is cached.

#![cfg(unix)]

mod http;
mod machine;
pub mod machine_io;
mod network;
mod owner;
mod previews;
mod runs;
pub mod session;
mod turns;

use serde_json::{Map, Value, json};
use zeroize::Zeroizing;

use http::Http;
pub use http::{Auth, Failure};

/// The largest answer body read from any service (a 2xx or a refusal), and the largest answer a
/// call gives. Larger is a transport failure, refused while reading, so a service that streams
/// a huge body costs at most this much memory.
pub const MAX_ANSWER_BYTES: usize = 16 * 1024 * 1024;
use session::redact;

/// One call as the app sends it.
#[derive(Debug, Clone, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub call: String,
    pub api: String,
    pub auth: Auth,
    pub credential: String,
    #[serde(default)]
    pub refresh: Option<String>,
    #[serde(default)]
    pub team: Option<String>,
    #[serde(default)]
    pub app_version: Option<String>,
    /// The build points at a loopback backend: a refused connection is `no_backend`.
    #[serde(default)]
    pub local_only: bool,
    #[serde(default)]
    pub args: Map<String, Value>,
}

/// The request object and, after its line, the raw bytes a keyed start sends.
pub fn parse(input: &[u8]) -> Result<(Request, Zeroizing<Vec<u8>>), String> {
    let mut parts = input.splitn(2, |&b| b == b'\n');
    let (head, tail) = (parts.next().unwrap_or_default(), parts.next().unwrap_or_default());
    let mut request: Request = serde_json::from_slice(head)
        .map_err(|_| "the request is not a cloud api request".to_owned())?;
    request.credential = request.credential.trim().to_owned();
    request.api = request.api.trim().to_owned();
    Ok((request, Zeroizing::new(tail.to_vec())))
}

/// Runs one call.
pub async fn perform(request: &Request, tail: Zeroizing<Vec<u8>>) -> Result<Value, Failure> {
    // The GitHub App status sends Authorization alone: its team is in the query.
    let http = if request.call == "owner.github_app" {
        Http::new(&Request { team: None, ..request.clone() })?
    } else {
        Http::new(request)?
    };
    let args = &request.args;
    match request.call.as_str() {
        "machine.io" if request.auth == Auth::Stack => Err(not_on_this_cloud("machine.io")),
        "machine.io" => machine::worker(request).await,
        "vm.networks" => network::networks(&http, request.auth).await,
        "vm.scp_endpoint" => machine::scp_endpoint(&http, args).await,
        call if previews::PUBLICATION_CALLS.contains(&call) => {
            previews::publications(request, call, args).await
        }
        call if NOT_ON_THIS_CLOUD.contains(&call) => Err(not_on_this_cloud(call)),
        "runs.create" => runs::create(&http, args).await,
        "runs.start" => runs::start(&http, args).await,
        "runs.wait" => runs::wait(&http, args).await,
        "runs.cancel" => runs::cancel(&http, args).await,
        "runs.sandbox" => runs::sandbox(&http, args).await,
        "owner.acpmux_keyed_start" => owner::keyed_start(&http, args, tail).await,
        "owner.turn_checkpoint" | "owner.turn_rewind" | "owner.turns" => {
            turns::run(&http, request.call.as_str(), args).await
        }
        call if call.starts_with("owner.") => owner::run(&http, call, args).await,
        call if call.starts_with("previews.") => previews::run(request, call, args).await,
        other => Err(Failure::Transport(format!("no cloud api call {other:?}"))),
    }
}

/// The calls classic cmux.com's `/api/vm` served that cmux-platform does not yet: each answers
/// [`not_on_this_cloud`] before any request.
pub const NOT_ON_THIS_CLOUD: [&str; 9] = [
    "vm.tunnel_enroll",
    "vm.tunnel_revoke",
    "vm.tunnel_attach",
    "vm.tunnel_detach",
    "vm.tunnel_rotate_key",
    "vm.firewall_list",
    "vm.firewall_get",
    "vm.firewall_create",
    "vm.firewall_delete",
];

/// The refusal of a call this Cloud does not serve: a 501 the caller shows at once.
fn not_on_this_cloud(call: &str) -> Failure {
    Failure::http(
        501,
        Some("cloud.not_available".to_owned()),
        Some(format!("{call} is not available on this Cloud yet")),
    )
}

/// The answer line.
pub fn answer_line(result: &Result<Value, Failure>) -> String {
    match result {
        Ok(body) => json!({ "ok": true, "body": body }).to_string(),
        Err(failure) => json!({ "ok": false, "error": failure.json() }).to_string(),
    }
}

/// Every call [`perform`] answers.
pub const CALLS: [&str; 37] = [
    "vm.scp_endpoint",
    "vm.tunnel_enroll",
    "vm.tunnel_revoke",
    "vm.tunnel_attach",
    "vm.tunnel_detach",
    "vm.tunnel_rotate_key",
    "vm.firewall_list",
    "vm.firewall_get",
    "vm.firewall_create",
    "vm.firewall_delete",
    "vm.networks",
    "vm.domains",
    "vm.publications",
    "vm.provision_api",
    "vm.publication_api_keys",
    "vm.revoke_publication_api_key",
    "runs.create",
    "runs.start",
    "runs.wait",
    "runs.cancel",
    "runs.sandbox",
    "owner.acpmux_person_holds",
    "owner.acpmux_keyed_start",
    "owner.fork_run",
    "owner.handoff_wait",
    "owner.handoffs",
    "owner.handoff_open",
    "owner.handoff_begin_turn",
    "owner.harness_login_copy",
    "owner.github_app",
    "owner.turn_checkpoint",
    "owner.turn_rewind",
    "owner.turns",
    "previews.refresh",
    "previews.create_link",
    "previews.revoke_link",
    "machine.io",
];

/// A bound past every fixed deadline of a call (the longest, a staged machine read's, is about
/// 330 s; this was classic's snapshot delete, 960 s, and stays as the margin a waiting caller has).
const LONGEST_FIXED_MS: u64 = 960_000;

/// The longest `request` can take before its own deadlines answer it: the bound for a caller that
/// waits on its answer (the CLI on the daemon's reply), which adds its own margin.
pub fn longest(request: &Request) -> std::time::Duration {
    let ms = |name: &str, default: i64| {
        u64::try_from(optional_int(&request.args, name).unwrap_or(default)).unwrap_or(0)
    };
    let call_ms = match request.call.as_str() {
        "runs.sandbox" => ms("timeoutMs", runs::DEFAULT_TIMEOUT_MS)
            .saturating_add(ms("teardownMs", runs::DEFAULT_TEARDOWN_MS))
            .saturating_add(ms("callsMarginMs", runs::DEFAULT_CALLS_MARGIN_MS)),
        "machine.io" => ms("timeout_ms", 0).saturating_add(5_000),
        _ => 0,
    };
    std::time::Duration::from_millis(call_ms.max(LONGEST_FIXED_MS))
}

/// A refusal never carries the caller's credentials back (a server or proxy that echoed one).
pub fn scrub(line: String, request: &Request) -> String {
    let ok = serde_json::from_str::<Value>(&line)
        .is_ok_and(|answer| answer.get("ok") == Some(&Value::Bool(true)));
    if ok {
        return line;
    }
    let refresh = request.refresh.as_deref().unwrap_or_default();
    redact(&line, refresh, &request.credential)
}

// MARK: argument readers

/// `value[name]`, or a decoding failure naming `path`.
pub(crate) fn field(mut value: Value, name: &str, path: &str) -> Result<Value, Failure> {
    value
        .get_mut(name)
        .map(Value::take)
        .filter(|v| !v.is_null())
        .ok_or_else(|| Failure::Decoding(format!("{path}: no {name}")))
}

pub(crate) fn text<'a>(args: &'a Map<String, Value>, name: &str) -> Result<&'a str, Failure> {
    args.get(name)
        .and_then(Value::as_str)
        .ok_or_else(|| Failure::Transport(format!("the call needs {name}")))
}

pub(crate) fn optional_text<'a>(args: &'a Map<String, Value>, name: &str) -> Option<&'a str> {
    args.get(name).and_then(Value::as_str)
}

pub(crate) fn optional_int(args: &Map<String, Value>, name: &str) -> Option<i64> {
    args.get(name).and_then(Value::as_i64)
}

#[cfg(test)]
mod tests;
