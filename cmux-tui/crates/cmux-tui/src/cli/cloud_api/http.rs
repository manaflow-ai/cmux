//! One request of `cmux cloud api`: the URL (path segments encoded, a base path kept), the
//! auth's headers, the deadline, and how a failure reads (the app's `CloudAPIError` cases).

use std::time::Duration;

use serde_json::{Map, Value, json};
use zeroize::Zeroizing;

use super::Request;

/// Which credentials and headers a call sends (module docs of `cloud_api`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub(in crate::cli) enum Auth {
    Stack,
    Owner,
    Worker,
}

/// Why a call failed: the app's `CloudAPIError` cases (no `not_signed_in`, which the app's own
/// token read decides).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::cli) enum Failure {
    /// No answer by the deadline: the path that timed out.
    TimedOut(String),
    Transport(String),
    /// A loopback backend that is not running.
    NoBackend,
    Http {
        status: u16,
        code: Option<String>,
        message: Option<String>,
        action: Option<String>,
        trace_id: Option<String>,
    },
    /// A refusal a paid plan lifts (`pro` or `max`).
    PlanRequired {
        message: Option<String>,
        upgrade_url: Option<String>,
        plan: String,
    },
    Decoding(String),
}

impl Failure {
    pub(super) fn http(status: u16, code: Option<String>, message: Option<String>) -> Self {
        Failure::Http { status, code, message, action: None, trace_id: None }
    }

    pub(super) fn json(&self) -> Value {
        match self {
            Failure::TimedOut(path) => json!({ "kind": "timed_out", "path": path }),
            Failure::Transport(message) => json!({ "kind": "transport", "message": message }),
            Failure::NoBackend => json!({ "kind": "no_backend" }),
            Failure::Http { status, code, message, action, trace_id } => json!({
                "kind": "http", "status": status, "code": code, "message": message,
                "action": action, "trace_id": trace_id,
            }),
            Failure::PlanRequired { message, upgrade_url, plan } => json!({
                "kind": "plan_required", "message": message, "upgrade_url": upgrade_url, "plan": plan,
            }),
            Failure::Decoding(message) => json!({ "kind": "decoding", "message": message }),
        }
    }
}

/// A request body.
pub(super) enum Body {
    Json(Value),
    /// Raw bytes and their content type (a keyed start's key line).
    /// Raw bytes (the keyed start's person key): the request's buffer is wiped when reqwest drops it.
    Bytes(Zeroizing<Vec<u8>>, &'static str),
}

/// What came back.
pub(super) struct Reply {
    pub(super) status: u16,
    /// `x-cmux-vm-error`, classic's code header.
    pub(super) header_code: Option<String>,
    pub(super) body: Vec<u8>,
}

impl Reply {
    pub(super) fn ok(&self) -> bool {
        (200..300).contains(&self.status)
    }

    pub(super) fn json(&self) -> Option<Value> {
        serde_json::from_slice(&self.body).ok()
    }
}

/// One call's session: the client, the base URL and the credentials.
pub(in crate::cli) struct Http {
    client: reqwest::Client,
    base: reqwest::Url,
    pub(super) auth: Auth,
    credential: String,
    refresh: String,
    pub(super) team: Option<String>,
    app_version: String,
    local_only: bool,
}

impl Http {
    pub(in crate::cli) fn new(request: &Request) -> Result<Self, Failure> {
        let base = base_url(&request.api).map_err(Failure::Transport)?;
        let _ = rustls::crypto::ring::default_provider().install_default();
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(concat!("cmux/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|e| Failure::Transport(e.to_string()))?;
        Ok(Http {
            client,
            base,
            auth: request.auth,
            credential: request.credential.clone(),
            refresh: request.refresh.clone().unwrap_or_default(),
            team: request.team.clone().filter(|t| !t.is_empty()),
            app_version: request.app_version.clone().unwrap_or_else(|| "cmux-next".into()),
            local_only: request.local_only,
        })
    }

    /// `base` and `segments` (each one percent-encoded, `/` included) with `query`.
    pub(super) fn url(&self, segments: &[&str], query: &[(&str, String)]) -> reqwest::Url {
        let mut url = self.base.clone();
        if let Ok(mut path) = url.path_segments_mut() {
            path.pop_if_empty().extend(segments);
        }
        if !query.is_empty() {
            let mut pairs = url.query_pairs_mut();
            for (name, value) in query {
                pairs.append_pair(name, value);
            }
        }
        url
    }

    /// Sends one request. `path` names it in a timeout (the app shows it).
    pub(super) async fn send(
        &self,
        method: reqwest::Method,
        url: reqwest::Url,
        body: Option<Body>,
        idempotency_key: Option<&str>,
        timeout: Duration,
        path: &str,
    ) -> Result<Reply, Failure> {
        let mut builder =
            self.client.request(method, url).bearer_auth(&self.credential).timeout(timeout);
        match self.auth {
            Auth::Stack => {
                builder = builder
                    .header("X-Cmux-Client", "cmux-mac")
                    .header("X-Cmux-App-Version", &self.app_version)
                    .header("X-Stack-Refresh-Token", &self.refresh);
                if let Some(team) = &self.team {
                    builder = builder.header("X-Cmux-Team-Id", team);
                }
            }
            // RULE (cx-kvmz, hq-84): Authorization, Content-Type, Content-Length and x-cmux-team
            // only. The Worker's invocation log records every other header and the URL, so no
            // other header, no query and no path part that could hold a key is ever added.
            Auth::Owner | Auth::Worker => {
                if let Some(team) = &self.team {
                    builder = builder.header(super::super::cloud_client_session::TEAM_HEADER, team);
                }
            }
        }
        if let Some(key) = idempotency_key {
            builder = builder.header("Idempotency-Key", key);
        }
        builder = match body {
            Some(Body::Json(value)) => builder.json(&value),
            Some(Body::Bytes(bytes, content_type)) => builder
                .header(reqwest::header::CONTENT_TYPE, content_type)
                .body(bytes::Bytes::from_owner(bytes)),
            None => builder,
        };
        let response = match tokio::time::timeout(timeout, builder.send()).await {
            Err(_) => return Err(Failure::TimedOut(path.to_owned())),
            Ok(Err(e)) if e.is_timeout() => return Err(Failure::TimedOut(path.to_owned())),
            Ok(Err(e)) if self.local_only && e.is_connect() => return Err(Failure::NoBackend),
            Ok(Err(e)) => return Err(Failure::Transport(transport_text(e))),
            Ok(Ok(response)) => response,
        };
        let status = response.status().as_u16();
        let header_code = response
            .headers()
            .get("x-cmux-vm-error")
            .and_then(|v| v.to_str().ok())
            .map(str::to_owned);
        let body = match tokio::time::timeout(timeout, response.bytes()).await {
            Err(_) => return Err(Failure::TimedOut(path.to_owned())),
            Ok(Err(e)) if e.is_timeout() => return Err(Failure::TimedOut(path.to_owned())),
            Ok(Err(e)) => return Err(Failure::Transport(transport_text(e))),
            Ok(Ok(bytes)) => bytes.to_vec(),
        };
        Ok(Reply { status, header_code, body })
    }

    /// A classic call (`/api/vm`, `/api/runs`): a 2xx body as JSON (`null` when it has none),
    /// a refusal read by [`vm_error`].
    pub(super) async fn classic(
        &self,
        method: reqwest::Method,
        segments: &[&str],
        query: &[(&str, String)],
        body: Option<Value>,
        idempotency_key: Option<&str>,
        timeout: Duration,
    ) -> Result<Value, Failure> {
        let path = path_text(segments);
        let url = self.url(segments, query);
        let reply =
            self.send(method, url, body.map(Body::Json), idempotency_key, timeout, &path).await?;
        if !reply.ok() {
            return Err(vm_error(reply.status, &reply.body, reply.header_code.as_deref()));
        }
        if reply.body.iter().all(u8::is_ascii_whitespace) {
            return Ok(Value::Null);
        }
        reply.json().ok_or_else(|| Failure::Decoding(format!("{path}: the answer is not JSON")))
    }
}

fn transport_text(error: reqwest::Error) -> String {
    format!("the Cloud API did not answer: {}", error.without_url())
}

/// `/a/b` for the segments, as a timeout or decoding error names the route.
pub(super) fn path_text(segments: &[&str]) -> String {
    segments.iter().fold(String::new(), |mut text, segment| {
        text.push('/');
        text.push_str(segment);
        text
    })
}

/// The base URL: absolute, no user, query or fragment; plain http only to a loopback host (a
/// credential never goes over plain http to another). A path prefix is kept.
pub(super) fn base_url(raw: &str) -> Result<reqwest::Url, String> {
    let url = reqwest::Url::parse(raw.trim_end_matches('/'))
        .map_err(|_| "the Cloud API is not a URL".to_owned())?;
    if url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err("the Cloud API URL must have no user, query or fragment".into());
    }
    let local = matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]" | "::1"));
    if url.scheme() != "https" && !(url.scheme() == "http" && local) {
        return Err("the Cloud API is not https: a credential never goes over plain http".into());
    }
    Ok(url)
}

/// Classic's refusal body (`web/services/vms/routeHelpers.ts` `vmErrorResponse`: `{error,
/// message, action, traceId, ui: {message, traceId}}`, or the Worker's nested `{ok: false,
/// error: {code, message}}`); a refusal a paid plan lifts is [`Failure::PlanRequired`].
pub(super) fn vm_error(status: u16, body: &[u8], header_code: Option<&str>) -> Failure {
    let object: Option<Map<String, Value>> =
        serde_json::from_slice::<Value>(body).ok().and_then(|v| v.as_object().cloned());
    let field = |value: Option<&Value>| {
        value.and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()).map(str::to_owned)
    };
    let get = |name: &str| object.as_ref().and_then(|o| o.get(name));
    let ui = get("ui").and_then(Value::as_object);
    let nested = get("error").and_then(Value::as_object);
    let code = header_code
        .map(str::to_owned)
        .or_else(|| field(get("error")))
        .or_else(|| field(nested.and_then(|n| n.get("code"))));
    let message = field(ui.and_then(|u| u.get("message")))
        .or_else(|| field(get("message")))
        .or_else(|| field(nested.and_then(|n| n.get("message"))));
    if let Some(object) = &object
        && let Some(plan) = lifting_plan(object, code.as_deref())
    {
        return Failure::PlanRequired { message, upgrade_url: upgrade_url(object), plan };
    }
    Failure::Http {
        status,
        code,
        message,
        action: field(get("action")),
        trace_id: field(get("traceId")).or_else(|| field(ui.and_then(|u| u.get("traceId")))),
    }
}

/// The plan an `upgradeRequired` refusal names (`upgradePlanId`, else `pro`); none for a plan
/// cmux does not sell here, or for a credits top-up (a purchase, not a plan).
fn lifting_plan(object: &Map<String, Value>, code: Option<&str>) -> Option<String> {
    if object.get("upgradeRequired") != Some(&Value::Bool(true))
        || code == Some("vm_create_credits_insufficient")
    {
        return None;
    }
    let plan = object.get("upgradePlanId").and_then(Value::as_str).unwrap_or("pro");
    matches!(plan, "pro" | "max").then(|| plan.to_owned())
}

/// The refusal's `upgradeUrl`, only an https cmux.com link.
fn upgrade_url(object: &Map<String, Value>) -> Option<String> {
    let text = object.get("upgradeUrl")?.as_str()?;
    let url = reqwest::Url::parse(text).ok()?;
    let host = url.host_str()?;
    (url.scheme() == "https" && (host == "cmux.com" || host.ends_with(".cmux.com")))
        .then(|| text.to_owned())
}

/// The Worker's refusal: `{error: {code, message}}`.
pub(super) fn worker_error(status: u16, body: Option<&Value>) -> Failure {
    let error = body.and_then(|b| b.get("error"));
    let text =
        |name: &str| error.and_then(|e| e.get(name)).and_then(Value::as_str).map(str::to_owned);
    Failure::http(status, text("code"), text("message"))
}
