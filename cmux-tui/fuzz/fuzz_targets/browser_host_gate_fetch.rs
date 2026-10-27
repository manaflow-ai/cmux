//! cmux-browser-host `net.fetch` through the session's policy gate
//! (`gate/fetch.rs`): the agent's fetch parameters and every engine reply of
//! its redirect chain (final responses, `redirect {status, location}`,
//! `remoteIPAddress`, `corsRelaxed`, bodies, errors, malformed replies) come
//! from the input. The engine is a fake that applies the gate's request
//! filter to each hop, as headless Chromium's Fetch domain does.
//!
//! Invariants past "no panic":
//! - a fetch makes at most `MAX_REDIRECTS + 1` engine requests, each with
//!   `redirect: "manual"`, no `cell` and the same `fetchId`, and ends with
//!   one `net.fetch.done` for that id;
//! - no engine request carries a header agent code may not set, and a hop
//!   to another origin never carries `Authorization` (Fetch spec);
//! - every URL the engine is asked for passes the session's domain policy;
//! - the loaded secret never comes back, in a value or in an error.
#![no_main]

use std::collections::VecDeque;
use std::net::{IpAddr, Ipv4Addr};
use std::sync::{Arc, Mutex, PoisonError};

use arbitrary::Arbitrary;
use cmux_browser_host::driver::{Driver, RequestFilter, RequestInfo, RequestKind};
use cmux_browser_host::gate::{Gate, Grants};
use cmux_browser_host::protocol::{DriverError, ErrorCode};
use cmux_browser_host::vm::VmHost;
use libfuzzer_sys::fuzz_target;
use serde_json::{Value, json};

/// gate/redirects.rs `MAX_REDIRECTS`: hops after the first request.
const MAX_REDIRECTS: usize = 5;
/// The secret the session holds; masking must keep it out of every answer.
const SECRET: &str = "cmux-fuzz-secret-9f2c";
/// A domain the session's policy prohibits.
const PROHIBITED: &str = "blocked.test";
/// The most fetches one input runs.
const MAX_FETCHES: usize = 4;

#[derive(Arbitrary, Debug)]
enum Credentials {
    Omit,
    SameOrigin,
    Include,
    Other(String),
}

#[derive(Arbitrary, Debug)]
struct Fetch {
    url: String,
    method: Option<String>,
    headers: Vec<(String, String)>,
    body_base64: Option<String>,
    credentials: Option<Credentials>,
    origin: Option<String>,
    /// Absent: no total limit (the fake engine never waits).
    timeout_ms: Option<u16>,
    target_id: Option<String>,
    cell: u64,
}

#[derive(Arbitrary, Debug)]
enum EngineReply {
    Response {
        status: u16,
        body: Vec<u8>,
        /// Puts the session's secret in the body.
        leak_secret: bool,
        remote_ip: Option<[u8; 4]>,
        cors_relaxed: Vec<(String, String)>,
        headers: Vec<(String, String)>,
    },
    Redirect {
        status: u64,
        location: Option<String>,
        remote_ip: Option<[u8; 4]>,
    },
    Error {
        code: u8,
        message: String,
    },
    /// Any JSON value the engine might send as its answer.
    Raw(String),
}

#[derive(Arbitrary, Debug)]
struct Input {
    remote: bool,
    signed_in_profile: bool,
    /// Prohibit `PROHIBITED` and its subdomains.
    prohibit: bool,
    allowed: Option<Vec<String>>,
    block_ips: bool,
    /// What the session's name resolver answers.
    resolved: Vec<[u8; 4]>,
    fetches: Vec<Fetch>,
    replies: Vec<EngineReply>,
}

/// An engine that answers `net.fetch` from the input, after the request
/// filter the gate installed allowed the hop.
struct Engine {
    replies: Mutex<VecDeque<EngineReply>>,
    calls: Mutex<Vec<(String, Value)>>,
    filter: Mutex<Option<RequestFilter>>,
}

fn base64(bytes: &[u8]) -> String {
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn unbase64(text: &str) -> Option<Vec<u8>> {
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD.decode(text).ok()
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

impl Engine {
    fn fetch(&self, params: &Value) -> Result<Value, DriverError> {
        let url = params["url"].as_str().unwrap_or("");
        let filter = lock(&self.filter).clone();
        if let Some(filter) = filter {
            let request = RequestInfo {
                target: params["targetId"].as_str().unwrap_or(""),
                url,
                kind: RequestKind::Subresource,
            };
            if let Some(reason) = filter(&request) {
                return Err(DriverError::new(ErrorCode::Forbidden, reason));
            }
        }
        let Some(reply) = lock(&self.replies).pop_front() else {
            return Err(DriverError::closed("the engine has no more answers"));
        };
        let ip = |ip: Option<[u8; 4]>| ip.map(|octets| Ipv4Addr::from(octets).to_string());
        match reply {
            EngineReply::Response {
                status,
                body,
                leak_secret,
                remote_ip,
                cors_relaxed,
                headers,
            } => {
                let mut body = body;
                if leak_secret {
                    body.extend_from_slice(SECRET.as_bytes());
                }
                let mut value = json!({
                    "status": status,
                    "statusText": "OK",
                    "headers": headers.iter().map(|(n, v)| [n, v]).collect::<Vec<_>>(),
                    "bodyBase64": base64(&body),
                    "corsRelaxed": cors_relaxed
                        .iter()
                        .map(|(url, what)| json!({"url": url, "what": what}))
                        .collect::<Vec<_>>(),
                });
                if let Some(ip) = ip(remote_ip) {
                    value["remoteIPAddress"] = json!(ip);
                }
                Ok(value)
            }
            EngineReply::Redirect { status, location, remote_ip } => {
                let mut value = json!({"status": status, "redirect": {"status": status}});
                if let Some(location) = location {
                    value["redirect"]["location"] = json!(location);
                }
                if let Some(ip) = ip(remote_ip) {
                    value["remoteIPAddress"] = json!(ip);
                }
                Ok(value)
            }
            EngineReply::Error { code, message } => {
                let code = match code % 4 {
                    0 => ErrorCode::Closed,
                    1 => ErrorCode::Timeout,
                    2 => ErrorCode::Invalid,
                    _ => ErrorCode::Cancelled,
                };
                Err(DriverError::new(code, message))
            }
            EngineReply::Raw(text) => serde_json::from_str(&text)
                .map_err(|e| DriverError::invalid(format!("the engine sent no JSON: {e}"))),
        }
    }
}

impl Driver for Engine {
    fn call(&self, method: &str, params: &Value) -> Result<Value, DriverError> {
        lock(&self.calls).push((method.to_owned(), params.clone()));
        match method {
            "net.fetch" => self.fetch(params),
            "net.fetch.done" | "net.fetch.cancel" => Ok(json!({})),
            _ => Err(DriverError::unsupported_method(method)),
        }
    }

    fn capabilities(&self) -> Vec<&'static str> {
        Vec::new()
    }

    fn set_request_filter(&self, filter: Option<RequestFilter>) -> bool {
        *lock(&self.filter) = filter;
        true
    }
}

fn params_of(fetch: &Fetch) -> Value {
    let mut params = json!({
        "url": fetch.url,
        "headers": fetch.headers.iter().map(|(n, v)| [n, v]).collect::<Vec<_>>(),
        "cell": fetch.cell,
    });
    if let Some(method) = &fetch.method {
        params["method"] = json!(method);
    }
    if let Some(body) = &fetch.body_base64 {
        params["bodyBase64"] = json!(body);
    }
    if let Some(credentials) = &fetch.credentials {
        params["credentials"] = match credentials {
            Credentials::Omit => json!("omit"),
            Credentials::SameOrigin => json!("same-origin"),
            Credentials::Include => json!("include"),
            Credentials::Other(other) => json!(other),
        };
    }
    if let Some(origin) = &fetch.origin {
        params["origin"] = json!(origin);
    }
    if let Some(timeout) = fetch.timeout_ms {
        params["timeoutMs"] = json!(timeout);
    }
    if let Some(target) = &fetch.target_id {
        params["targetId"] = json!(target);
    }
    params
}

/// gate/fetch.rs `forbidden_header`.
fn forbidden_header(name: &str) -> bool {
    let name = name.to_ascii_lowercase();
    matches!(name.as_str(), "host" | "content-length" | "cookie2")
        || name.starts_with("sec-")
        || name.starts_with("proxy-")
}

fn origin_of(url: &str) -> Option<String> {
    url::Url::parse(url).ok().map(|url| url.origin().ascii_serialization())
}

/// Checks the engine requests one fetch made.
fn check_hops(gate: &Gate, calls: &[(String, Value)]) {
    let hops: Vec<&Value> =
        calls.iter().filter(|(m, _)| m == "net.fetch").map(|(_, params)| params).collect();
    assert!(hops.len() <= MAX_REDIRECTS + 1, "{} engine requests for one fetch", hops.len());
    let done: Vec<&Value> =
        calls.iter().filter(|(m, _)| m == "net.fetch.done").map(|(_, params)| params).collect();
    let Some(first) = hops.first() else { return };
    let id = &first["fetchId"];
    assert!(id.is_string(), "a hop without a fetchId: {first}");
    assert_eq!(done.len(), 1, "one net.fetch.done per fetch: {calls:?}");
    assert_eq!(&done[0]["fetchId"], id, "net.fetch.done names another fetch");
    let mut previous: Option<String> = None;
    for hop in &hops {
        assert_eq!(&hop["fetchId"], id, "hops of one fetch with two ids");
        assert_eq!(hop["redirect"], "manual", "the engine followed a redirect itself: {hop}");
        assert!(hop.get("cell").is_none(), "the VM's cell reached the engine: {hop}");
        let url = hop["url"].as_str().unwrap_or("");
        let refusal = gate
            .native("policy", json!({"op": "check", "args": {"url": url}}))
            .expect("policy check answers");
        assert!(
            refusal.is_null(),
            "the engine was asked for {url}, which the policy refuses: {refusal}"
        );
        let origin = origin_of(url);
        for pair in hop["headers"].as_array().into_iter().flatten() {
            let name = pair[0].as_str().unwrap_or("");
            assert!(!forbidden_header(name), "a forbidden header reached the engine: {name}");
            if let Some(previous) = &previous
                && origin.as_ref() != Some(previous)
            {
                assert!(
                    !name.eq_ignore_ascii_case("authorization"),
                    "Authorization went to another origin: {previous} -> {url}"
                );
            }
        }
        previous = origin;
    }
}

fuzz_target!(|input: Input| {
    let engine = Arc::new(Engine {
        replies: Mutex::new(input.replies.into()),
        calls: Mutex::new(Vec::new()),
        filter: Mutex::new(None),
    });
    let grants = Grants {
        remote: input.remote,
        signed_in_profile: input.signed_in_profile,
        ..Grants::default()
    };
    let resolved: Vec<IpAddr> = input.resolved.iter().map(|octets| IpAddr::from(*octets)).collect();
    let gate = Gate::new(engine.clone(), grants)
        .with_resolver(Arc::new(move |_host: &str, _port: u16| resolved.clone()));
    gate.native(
        "secrets",
        json!({"op": "set", "args": {"name": "pw", "value": SECRET, "domains": ["a.test"]}}),
    )
    .expect("the secret loads");
    let mut policy = json!({"blockIPs": input.block_ips});
    if input.prohibit {
        policy["prohibited"] = json!([PROHIBITED, format!("*.{PROHIBITED}")]);
    }
    if let Some(allowed) = &input.allowed {
        policy["allowed"] = json!(allowed);
    }
    // A pattern the parser refuses leaves the policy as it was.
    let _ = gate.native("policy", json!({"op": "set", "args": policy}));

    for fetch in input.fetches.iter().take(MAX_FETCHES) {
        let mark = lock(&engine.calls).len();
        let answer = gate.driver_call("net.fetch", params_of(fetch));
        let calls = lock(&engine.calls)[mark..].to_vec();
        check_hops(&gate, &calls);
        match answer {
            Ok(value) => {
                assert!(!value.to_string().contains(SECRET), "the secret came back: {value}");
                if let Some(body) = value["bodyBase64"].as_str().and_then(unbase64) {
                    assert!(
                        !body.windows(SECRET.len()).any(|w| w == SECRET.as_bytes()),
                        "the secret came back in the body"
                    );
                }
                assert!(value["url"].is_string(), "a fetch answer without its final url: {value}");
                let hops = calls.iter().filter(|(m, _)| m == "net.fetch").count();
                assert_eq!(
                    value["redirected"],
                    json!(hops > 1),
                    "redirected disagrees with {hops} hops"
                );
            }
            Err(error) => {
                assert!(
                    !error.message.contains(SECRET),
                    "the secret came back in {}",
                    error.message
                );
            }
        }
    }
    gate.end_session();
});
