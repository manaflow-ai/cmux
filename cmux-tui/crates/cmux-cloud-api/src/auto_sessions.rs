//! Auto mode's Cloud store as the signed-in person calls it: every `/v1/auto-sessions` route of
//! the cmux API Worker (`backend/apps/api/src/auto-sessions/routes.ts`), implementing
//! `cmux_auto_session::AutoCloud` for a laptop's daemon
//! (`plans/cmux-next/auto-mode/DESIGN.md`, "Cloud API").
//!
//! - The sign-in comes from the caller with every call ([`OwnerSignIn`]): the API it is for,
//!   the bearer and the team. It is never kept past the client it built, logged or put in a
//!   URL. A call with no sign-in fails as a call the Cloud did not answer, so a chat the
//!   laptop cannot renew stops as it does with no network.
//! - Nothing is retried here. A refusal reads as the store wrote it
//!   (`AutoCloudError::from_response`: `{error: {code, message}, session?, lastSeq?, missing?}`).
//! - One HTTP client is kept while the sign-in stays the same, so a renewal every ten seconds
//!   reuses its connection.

mod routes;

use std::future::Future;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cmux_auto_session::cloud::{AutoCloudError, CloudResult};
use reqwest::Method;
use serde::de::DeserializeOwned;
use serde_json::{Map, Value};

use crate::http::{Body, Http, path_text};
use crate::{Auth, Failure, Request};

/// The deadline of a call the store answers at once. A renewal is given up sooner by the
/// holder loop (`RENEW_MS`); this bounds every other call.
const CALL_TIMEOUT: Duration = Duration::from_secs(15);
/// A chunk is up to 1 MiB each way.
const CHUNK_TIMEOUT: Duration = Duration::from_secs(60);
/// Past the time the store holds a `wait`, how long its answer may take to arrive.
const HELD_MARGIN: Duration = Duration::from_secs(15);

/// The person's sign-in for one call.
#[derive(Clone, PartialEq, Eq)]
pub struct SignedIn {
    /// The cmux API the sign-in is for (its issuer), as a base URL.
    pub api: String,
    /// The bearer.
    pub credential: String,
    /// The team it acts for (`x-cmux-team`).
    pub team: Option<String>,
}

/// Never the bearer.
impl std::fmt::Debug for SignedIn {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SignedIn")
            .field("api", &self.api)
            .field("team", &self.team)
            .finish_non_exhaustive()
    }
}

/// Where the owner's sign-in comes from. The laptop's daemon asks the cmux app for a short
/// access token; a test names a local store.
pub trait OwnerSignIn: Send + Sync {
    /// The sign-in to send the next call with, or why there is none (not signed in, no app to
    /// ask). The implementation keeps a token while it is good: this is asked before every call.
    fn sign_in(&self) -> impl Future<Output = Result<SignedIn, String>> + Send;

    /// The store answered 401 to `credential`: it is not answered again.
    fn refused(&self, credential: &str) {
        let _ = credential;
    }
}

/// A sign-in that never changes (a test's, or a caller that holds a long-lived credential).
impl OwnerSignIn for SignedIn {
    async fn sign_in(&self) -> Result<SignedIn, String> {
        Ok(self.clone())
    }
}

/// The HTTP client built for one sign-in.
struct Held {
    signed_in: SignedIn,
    http: Http,
}

/// The owner's client for the Auto mode store.
pub struct OwnerAutoCloud<S> {
    sign_in: S,
    held: Mutex<Option<Arc<Held>>>,
}

impl<S: OwnerSignIn> OwnerAutoCloud<S> {
    pub fn new(sign_in: S) -> OwnerAutoCloud<S> {
        OwnerAutoCloud { sign_in, held: Mutex::new(None) }
    }

    /// The client for the sign-in as it is now.
    async fn held(&self) -> CloudResult<Arc<Held>> {
        let signed_in = self.sign_in.sign_in().await.map_err(AutoCloudError::transport)?;
        let mut held = self.held.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(current) = held.as_ref().filter(|h| h.signed_in == signed_in) {
            return Ok(Arc::clone(current));
        }
        let request = Request {
            call: "owner.auto_sessions".to_owned(),
            api: signed_in.api.trim().to_owned(),
            auth: Auth::Owner,
            credential: signed_in.credential.trim().to_owned(),
            refresh: None,
            team: signed_in.team.clone(),
            app_version: None,
            local_only: false,
            args: Map::new(),
        };
        let http = Http::new(&request).map_err(|failure| failed(&failure))?;
        let built = Arc::new(Held { signed_in, http });
        *held = Some(Arc::clone(&built));
        Ok(built)
    }

    /// One request and its 2xx body. `after` are the path parts after `/v1/auto-sessions`.
    async fn send(&self, call: Call<'_>) -> CloudResult<Vec<u8>> {
        let held = self.held().await?;
        let mut segments = vec!["v1", "auto-sessions"];
        segments.extend_from_slice(call.after);
        let path = path_text(&segments);
        let url = held.http.url(&segments, call.query);
        let reply = held
            .http
            .send_named(call.method, url, call.body, (None, call.headers), call.timeout, &path)
            .await
            .map_err(|failure| failed(&failure))?;
        if reply.ok() {
            return Ok(reply.body);
        }
        if reply.status == 401 {
            self.sign_in.refused(&held.signed_in.credential);
        }
        Err(AutoCloudError::from_response(reply.status, &reply.body))
    }

    /// One request whose answer is JSON of type `T`.
    async fn json<T: DeserializeOwned>(&self, call: Call<'_>) -> CloudResult<T> {
        let path = call.after.join("/");
        let body = self.send(call).await?;
        serde_json::from_slice(&body)
            .map_err(|error| AutoCloudError::decoding(format!("/v1/auto-sessions/{path}: {error}")))
    }
}

/// One request to the store.
struct Call<'a> {
    method: Method,
    after: &'a [&'a str],
    query: &'a [(&'a str, String)],
    body: Option<Body>,
    headers: &'a [(&'static str, String)],
    timeout: Duration,
}

impl<'a> Call<'a> {
    fn get(after: &'a [&'a str]) -> Call<'a> {
        Call {
            method: Method::GET,
            after,
            query: &[],
            body: None,
            headers: &[],
            timeout: CALL_TIMEOUT,
        }
    }

    /// `method` with `body` as its JSON.
    fn with<B: serde::Serialize>(
        method: Method,
        after: &'a [&'a str],
        body: &B,
    ) -> CloudResult<Call<'a>> {
        let value: Value = serde_json::to_value(body)
            .map_err(|error| AutoCloudError::decoding(format!("the request: {error}")))?;
        Ok(Call { method, body: Some(Body::Json(value)), ..Call::get(after) })
    }

    fn post<B: serde::Serialize>(after: &'a [&'a str], body: &B) -> CloudResult<Call<'a>> {
        Call::with(Method::POST, after, body)
    }

    fn query(mut self, query: &'a [(&'a str, String)]) -> Call<'a> {
        self.query = query;
        self
    }

    fn timeout(mut self, timeout: Duration) -> Call<'a> {
        self.timeout = timeout;
        self
    }
}

/// A call that got no answer from the store, or one that could not be read.
fn failed(failure: &Failure) -> AutoCloudError {
    match failure {
        Failure::Decoding(message) => AutoCloudError::decoding(message.clone()),
        Failure::Http { status, code, message, .. } => AutoCloudError::http(
            *status,
            code.as_deref().unwrap_or_default(),
            message.clone().unwrap_or_default(),
        ),
        Failure::TimedOut(_)
        | Failure::Transport(_)
        | Failure::NoBackend
        | Failure::PlanRequired { .. } => AutoCloudError::transport(failure.to_string()),
    }
}

/// `id` as a path part, or the refusal the store would give: a chat id is
/// `[A-Za-z0-9_.:-]{1,128}`, and nothing else is put in a URL.
fn chat(id: &str) -> CloudResult<&str> {
    if crate::owner::is_session_id(id) && id != "machine" && id != "assignments" {
        Ok(id)
    } else {
        Err(AutoCloudError::http(400, "invalid_request", "not a chat id"))
    }
}
