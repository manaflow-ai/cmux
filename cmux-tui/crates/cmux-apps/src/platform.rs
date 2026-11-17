//! The platform's apps routes (RFD 0003, "Platform contract (first slice)"), called as this
//! machine's bound VM install: `vm-self` may only name its own machine as a version's target.

use std::cell::RefCell;

use serde::Serialize;
use serde_json::{Value, json};

use crate::io::{Answered, AppsTransport};

/// The platform's apps routes; the agent sends nothing else.
pub const APPS: &str = "/v1/cloud/apps";

/// A refusal or a transport failure, with the platform's `cloud.app.*` code when it sent one.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct ApiError {
    /// 0 when no answer came (transport, or no credential).
    pub status: u16,
    pub code: String,
    pub message: String,
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if self.status == 0 {
            write!(f, "{}: {}", self.code, self.message)
        } else {
            write!(f, "{} (HTTP {}): {}", self.code, self.status, self.message)
        }
    }
}

/// The body of `POST /v1/cloud/apps/{slug}/versions`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Promote {
    pub commit: String,
    pub command: String,
    pub machine: String,
    pub port: u16,
}

/// `{app, version, url}` from a promote, `{app, url}` from a rollback (`version` is `Null`).
#[derive(Clone, Debug, PartialEq)]
pub struct Moved {
    pub app: Value,
    pub version: Value,
    pub url: String,
}

/// What a publish and a rollback need from the platform.
pub trait PlatformApi {
    /// The machine the platform knows this VM as (a version's `machine`).
    fn machine(&self) -> Result<String, ApiError>;
    /// Fails before any staging when the platform can't be reached as this machine.
    fn ready(&self) -> Result<(), ApiError>;
    /// `POST /v1/cloud/apps`: the app, made or the existing one of this creator.
    fn ensure_app(&self, name: &str, slug: &str) -> Result<Value, ApiError>;
    /// `attempt` names this publish attempt: a retry after a lost answer sends the same
    /// `Idempotency-Key`, so the platform makes one version of it.
    fn promote(&self, slug: &str, body: &Promote, attempt: &str) -> Result<Moved, ApiError>;
    fn rollback(&self, slug: &str, to: Option<u32>) -> Result<Moved, ApiError>;
    /// `PUT /v1/cloud/apps/{slug}/grants` `{kind: "team", id}`.
    fn share_team(&self, slug: &str, team: &str) -> Result<(), ApiError>;
}

/// [`PlatformApi`] through this machine's agent (`apps.call`), which holds the `vm-self`
/// credential and sends only the apps routes.
pub struct PlatformClient<'a> {
    pub transport: &'a dyn AppsTransport,
    /// The machine the agent's last answer spoke for.
    machine: RefCell<Option<String>>,
}

/// A promote whose answer is lost is sent again this many times in all, with the same key.
pub const PROMOTE_TRIES: u32 = 3;

/// `<slug>:<commit>:<attempt id>`, the promote's `Idempotency-Key`.
pub fn idempotency_key(slug: &str, commit: &str, attempt: &str) -> String {
    format!("{slug}:{commit}:{attempt}")
}

fn local(code: &str, message: impl Into<String>) -> ApiError {
    ApiError { status: 0, code: code.to_owned(), message: message.into() }
}

impl<'a> PlatformClient<'a> {
    pub fn new(transport: &'a dyn AppsTransport) -> PlatformClient<'a> {
        PlatformClient { transport, machine: RefCell::new(None) }
    }

    /// One request, sent again while its answer is lost (`tries` in all, the same
    /// `idempotency_key` every time, so a retry is the same request).
    fn send(
        &self,
        method: &str,
        path: &str,
        body: Option<&Value>,
        idempotency_key: Option<&str>,
        tries: u32,
    ) -> Result<Answered, ApiError> {
        let mut sent = self.transport.call(method, path, body, idempotency_key);
        for _ in 1..tries {
            match &sent {
                Err(e) if e.lost() => {
                    sent = self.transport.call(method, path, body, idempotency_key)
                }
                _ => break,
            }
        }
        let answered = sent.map_err(|e| local(&e.code, e.message))?;
        if !answered.machine.is_empty() {
            *self.machine.borrow_mut() = Some(answered.machine.clone());
        }
        Ok(answered)
    }

    fn call(
        &self,
        method: &str,
        path: &str,
        body: Option<&Value>,
        idempotency_key: Option<&str>,
        tries: u32,
    ) -> Result<Value, ApiError> {
        let Answered { status, body: answer, .. } =
            self.send(method, path, body, idempotency_key, tries)?;
        if (200..300).contains(&status) {
            return Ok(answer);
        }
        let error = answer.get("error").unwrap_or(&answer);
        let text = |key: &str| error.get(key).and_then(Value::as_str).map(str::to_owned);
        Err(ApiError {
            status,
            code: text("code").unwrap_or_else(|| "cloud.app.refused".to_owned()),
            message: text("message")
                .unwrap_or_else(|| format!("{method} {path} answered {status}")),
        })
    }
}

fn moved(answer: Value) -> Moved {
    let url = answer.get("url").and_then(Value::as_str).unwrap_or_default().to_owned();
    Moved {
        app: answer.get("app").cloned().unwrap_or(Value::Null),
        version: answer.get("version").cloned().unwrap_or(Value::Null),
        url,
    }
}

impl PlatformApi for PlatformClient<'_> {
    fn machine(&self) -> Result<String, ApiError> {
        if self.machine.borrow().is_none() {
            self.ready()?;
        }
        self.machine.borrow().clone().ok_or_else(|| {
            local("app.platform", "this machine's agent did not say which machine it is")
        })
    }

    /// `GET /v1/cloud/apps`: any platform answer means the agent is bound and reached it.
    fn ready(&self) -> Result<(), ApiError> {
        self.send("GET", APPS, None, None, 1).map(|_| ())
    }

    fn ensure_app(&self, name: &str, slug: &str) -> Result<Value, ApiError> {
        let body = json!({"name": name, "slug": slug});
        let answer = self.call("POST", APPS, Some(&body), None, 1)?;
        Ok(answer.get("app").cloned().unwrap_or(Value::Null))
    }

    fn promote(&self, slug: &str, body: &Promote, attempt: &str) -> Result<Moved, ApiError> {
        let key = idempotency_key(slug, &body.commit, attempt);
        let body = serde_json::to_value(body).map_err(|e| local("app.encode", e.to_string()))?;
        let path = format!("{APPS}/{slug}/versions");
        self.call("POST", &path, Some(&body), Some(&key), PROMOTE_TRIES).map(moved)
    }

    fn rollback(&self, slug: &str, to: Option<u32>) -> Result<Moved, ApiError> {
        let body = match to {
            Some(n) => json!({"to": n}),
            None => json!({}),
        };
        self.call("POST", &format!("{APPS}/{slug}/rollback"), Some(&body), None, 1).map(moved)
    }

    fn share_team(&self, slug: &str, team: &str) -> Result<(), ApiError> {
        let body = json!({"kind": "team", "id": team});
        self.call("PUT", &format!("{APPS}/{slug}/grants"), Some(&body), None, 1).map(|_| ())
    }
}
