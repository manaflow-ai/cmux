//! `cmux cloud machine-io`: one file operation or command on a Cloud machine,
//! straight to its provider with a short-lived client session when it can, else
//! through the cmux API. The macOS app runs it for its Cloud machine file browse,
//! read, write and exec (CloudAPIClient+MachineRoutes.swift), so the logic lives
//! here and the Swift side only forwards.
//!
//! Request: one JSON object on stdin (never in argv, which other processes can read):
//!
//! ```json
//! {"api": "https://cloud-api.cmux.dev", "credential": "…", "team": "…", "machine": "vm_…",
//!  "op": "dir|read|stat|write|mkdir|remove|exec", "path": "/…", "data_base64": "…",
//!  "mode": 420, "command": "…", "timeout_ms": 30000, "cache_dir": "/…",
//!  "route": "auto|proxy", "app_version": "…"}
//! ```
//!
//! Answer: one JSON line on stdout, `{"route": "direct"|"proxy"|"none", "status": N, "code": C|null,
//! "body": B}`, where `status`, `code` (the `x-cmux-vm-error` header) and `body` are what the
//! cmux API's own route (`/v1/cloud/machines/{machine}/{exec,fs/…}`) answers for the same
//! request, so the app decodes either route the same way. `status` 0 is no answer at all.
//! Exit 0 for a 2xx answer, 1 for any other, 2 for a request that is not one (route `none`:
//! nothing ran, and the app sends the request to the cmux API itself).
//!
//! The direct route (cmux-platform `src/server/cloud/ClientSession.ts`; freestyle.sh/docs/vms/
//! client-sessions): mint `POST /v1/cloud/machines/{machine}/client-session`, cache it
//! ([`session`]), and run the operation with Freestyle's `exec-await` ([`direct`]). The proxy
//! ([`proxy`]) is taken when the request asks for it, the machine is not a Worker machine
//! (`vm_` and 20 characters), the mint is refused (a teammate's machine, a provider without client
//! sessions, the rate limit; remembered a while), Freestyle refuses a freshly minted token, or the
//! operation needs root (a path the work user may not touch).

mod direct;
mod proxy;
mod session;

use std::io::{Read as _, Write as _};
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::{Value, json};

use super::cloud_client_session::{mint_session, redact, secure_origin, valid_machine};
use direct::{Direct, Grant};
use session::{Cache, Entry, Use};

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum Op {
    Dir,
    Read,
    Stat,
    Write,
    Mkdir,
    Remove,
    Exec,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum RouteChoice {
    #[default]
    Auto,
    Proxy,
}

#[derive(Debug, Clone, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Request {
    pub(super) api: String,
    pub(super) credential: String,
    #[serde(default)]
    pub(super) team: Option<String>,
    pub(super) machine: String,
    pub(super) op: Op,
    #[serde(default)]
    pub(super) path: Option<String>,
    #[serde(default)]
    pub(super) data_base64: Option<String>,
    #[serde(default)]
    pub(super) mode: Option<u32>,
    #[serde(default)]
    pub(super) command: Option<String>,
    #[serde(default)]
    pub(super) timeout_ms: Option<u64>,
    #[serde(default)]
    pub(super) cache_dir: Option<PathBuf>,
    #[serde(default)]
    pub(super) route: RouteChoice,
    #[serde(default)]
    pub(super) app_version: Option<String>,
}

impl Request {
    /// The written bytes: strict standard base64, else none.
    pub(super) fn data(&self) -> Option<Vec<u8>> {
        BASE64.decode(self.data_base64.as_deref()?).ok()
    }

    /// The exec's deadline as the cmux API sets it: 30 s when absent or not positive, at most five minutes.
    pub(super) fn exec_timeout_ms(&self) -> u64 {
        match self.timeout_ms {
            Some(ms) if ms > 0 => ms.min(direct::EXEC_MAX_MS),
            _ => direct::EXEC_DEFAULT_MS,
        }
    }

    /// Whether the direct route can run it as given. Anything else goes to the proxy, which
    /// answers it (its own 400 or 413) exactly as before.
    pub(super) fn direct_ready(&self) -> bool {
        if !valid_machine(&self.machine) {
            return false;
        }
        if self.op == Op::Exec {
            let command = self.command.as_deref().unwrap_or_default();
            return !command.trim().is_empty() && command.len() <= direct::COMMAND_MAX_BYTES;
        }
        let Some(path) = self.path.as_deref() else { return false };
        let path_ok = path.trim() == path
            && path.starts_with('/')
            && !path.contains('\0')
            && !path.split('/').any(|s| s == "..")
            && path.len() <= 4096;
        let not_root = self.op != Op::Remove || !path.split('/').all(|s| s.is_empty() || s == ".");
        let body_ok = self.op != Op::Write
            || (self.data().is_some() && self.mode.is_none_or(|m| m <= 0o7777));
        path_ok && not_root && body_ok
    }
}

/// One route's answer, as the cmux API's route would give it.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Answer {
    pub(super) status: u16,
    pub(super) body: Value,
    pub(super) code: Option<String>,
}

impl Answer {
    pub(super) fn ok(body: Value) -> Self {
        Answer { status: 200, body, code: None }
    }

    /// A refusal in the cmux API's shape: `{ok: false, error: {code, message}}` with the code in the header.
    pub(super) fn error(status: u16, code: &str, message: &str) -> Self {
        let body = json!({ "ok": false, "error": { "code": code, "message": message } });
        Answer { status, body, code: Some(code.to_owned()) }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Route {
    Direct,
    Proxy,
    /// Neither ran: the request is not one (the app takes its own HTTP route).
    None,
}

/// `Some(exit code)` when `args` is `cloud machine-io`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (_global, command_args) = super::parse_globals(args).ok()?;
    let [cloud, noun, rest @ ..] = command_args.as_slice() else { return None };
    if cloud != "cloud" || noun != "machine-io" {
        return None;
    }
    let stdout = &mut std::io::stdout();
    if !rest.is_empty() {
        let _ = writeln!(
            stdout,
            "{}",
            line(Route::None, &usage("cmux cloud machine-io takes its request as JSON on stdin"))
        );
        return Some(2);
    }
    let mut input = Vec::new();
    if std::io::stdin().read_to_end(&mut input).is_err() {
        let _ = writeln!(stdout, "{}", line(Route::None, &usage("the request could not be read")));
        return Some(2);
    }
    let mut request: Request = match serde_json::from_slice(&input) {
        Ok(request) => request,
        Err(_) => {
            let _ = writeln!(
                stdout,
                "{}",
                line(Route::None, &usage("the request is not a machine-io request"))
            );
            return Some(2);
        }
    };
    drop(input);
    match secure_origin(request.api.trim()) {
        Ok(origin) => request.api = origin,
        Err(message) => {
            let _ = writeln!(stdout, "{}", line(Route::None, &usage(&message)));
            return Some(2);
        }
    }
    request.credential = request.credential.trim().to_owned();
    let (route, answer) = match runtime_and_client() {
        Ok((runtime, client)) => runtime.block_on(perform(&client, &request, now_ms)),
        Err(message) => (Route::Proxy, Answer::error(0, "transport", &message)),
    };
    let answer = scrub(answer, &request.credential);
    let _ = writeln!(stdout, "{}", line(route, &answer));
    Some(if (200..300).contains(&answer.status) { 0 } else { 1 })
}

fn usage(message: &str) -> Answer {
    Answer::error(400, "validation.invalid", message)
}

fn line(route: Route, answer: &Answer) -> Value {
    let route = match route {
        Route::Direct => "direct",
        Route::Proxy => "proxy",
        Route::None => "none",
    };
    json!({ "route": route, "status": answer.status, "code": answer.code, "body": answer.body })
}

/// A refusal never carries the caller's credential back (a proxy or server that echoed it).
fn scrub(mut answer: Answer, credential: &str) -> Answer {
    if !(200..300).contains(&answer.status) && !credential.is_empty() {
        let text = answer.body.to_string();
        if text.contains(credential) {
            answer.body =
                serde_json::from_str(&redact(&text, "", credential)).unwrap_or(Value::Null);
        }
    }
    answer
}

fn runtime_and_client() -> Result<(tokio::runtime::Runtime, reqwest::Client), String> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| e.to_string())?;
    Ok((runtime, http_client()?))
}

/// The one HTTP client of a call (tests use it too). reqwest is built without a default rustls crypto
/// provider, so this installs ring first: a process that builds a client before any install panics.
fn http_client() -> Result<reqwest::Client, String> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .user_agent(concat!("cmux/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|e| e.to_string())
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
}

/// Runs `request` on the direct route when it can, else (or when that route hands it back) on the proxy.
pub(super) async fn perform(
    client: &reqwest::Client,
    request: &Request,
    now: impl Fn() -> u64,
) -> (Route, Answer) {
    if request.route == RouteChoice::Proxy || !request.direct_ready() {
        return (Route::Proxy, proxy::run(client, request).await);
    }
    let cache = Cache::new(
        request.cache_dir.as_deref(),
        &request.api,
        request.team.as_deref(),
        &request.machine,
        &request.credential,
    );
    let mut fresh = false;
    let grant = match session::decide(cache.load().as_ref(), now()) {
        Use::Direct(grant) => grant,
        Use::Proxy => return (Route::Proxy, proxy::run(client, request).await),
        Use::Mint => match mint(client, request, &cache, &now).await {
            Some(grant) => {
                fresh = true;
                grant
            }
            None => return (Route::Proxy, proxy::run(client, request).await),
        },
    };
    match direct::run(client, &grant, request).await {
        Direct::Done(answer) => return (Route::Direct, answer),
        Direct::Fallback => {}
        Direct::Auth => {
            cache.clear();
            // A cached token the provider no longer takes (revoked, or a clock that kept it too
            // long): mint once more. A fresh one refused means this machine's sessions do not
            // work now; take the proxy for a while.
            let retry = if fresh { None } else { mint(client, request, &cache, &now).await };
            match retry {
                Some(grant) => match direct::run(client, &grant, request).await {
                    Direct::Done(answer) => return (Route::Direct, answer),
                    Direct::Fallback => {}
                    Direct::Auth => hold(&cache, &now, 503),
                },
                None if fresh => hold(&cache, &now, 503),
                None => {}
            }
        }
    }
    (Route::Proxy, proxy::run(client, request).await)
}

fn hold(cache: &Cache, now: &impl Fn() -> u64, status: u16) {
    let ms = session::hold_ms(status);
    if ms > 0 {
        cache.store(&Entry::ProxyUntil { until_ms: now() + ms });
    }
}

async fn mint(
    client: &reqwest::Client,
    request: &Request,
    cache: &Cache,
    now: &impl Fn() -> u64,
) -> Option<Grant> {
    let minted = mint_session(
        client,
        &request.api,
        &request.credential,
        request.team.as_deref(),
        &request.machine,
        Some(session::TTL_SECONDS),
    )
    .await;
    match minted {
        Ok(s) => {
            let grant = Grant {
                vm_id: s.vm_id,
                linux_user: s.linux_user,
                token: s.token,
                api_base_url: s.api_base_url,
            };
            let use_until_ms = session::use_until(s.expires_at, now());
            cache.store(&Entry::Session { grant: grant.clone(), use_until_ms });
            Some(grant)
        }
        Err(refusal) => {
            hold(cache, now, refusal.status);
            None
        }
    }
}

#[cfg(test)]
mod tests;
