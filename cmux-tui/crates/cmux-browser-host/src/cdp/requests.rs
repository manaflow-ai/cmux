//! Request interception: the host's domain policy applied to every request
//! a page makes (script navigation, links, popups, redirects, fetch, every
//! subresource), before it is sent, through CDP `Fetch`.

use super::connection::{CdpConnection, CdpEvent};
use super::cors::{Cors, RequestAction};
use super::driver::{INTERNAL_TIMEOUT, Inner};
use crate::driver::RequestFilter;
use crate::protocol::DriverError;
use serde_json::{Value, json};
use std::sync::{Arc, Mutex, PoisonError, mpsc};

/// A paused request: its CDP session, id, owning tab ("" for none), URL,
/// and what HOST-FETCH-CORS needs (method, headers, network id; at the
/// response stage, the response headers).
pub(super) struct PausedRequest {
    session: String,
    request_id: String,
    target: String,
    url: String,
    method: String,
    headers: Value,
    network_id: String,
    response_headers: Option<Vec<Value>>,
    /// The response's status (with new headers CDP needs it too).
    response_status: Value,
}

/// Every request at the request stage; while a host fetch runs, every
/// response too (HOST-FETCH-CORS adds headers to its token requests).
fn patterns(responses: bool) -> Value {
    let mut patterns = vec![json!({"urlPattern": "*", "requestStage": "Request"})];
    if responses {
        patterns.push(json!({"urlPattern": "*", "requestStage": "Response"}));
    }
    json!({"patterns": patterns})
}

/// Starts the worker that answers paused requests (off the reader thread,
/// which must never wait on a CDP reply).
pub(super) fn start_worker(
    conn: Arc<CdpConnection>,
    filter: Arc<Mutex<Option<RequestFilter>>>,
    cors: Arc<Mutex<Cors>>,
) -> Result<mpsc::Sender<PausedRequest>, DriverError> {
    let (tx, rx) = mpsc::channel::<PausedRequest>();
    std::thread::Builder::new()
        .name("cmux-browser-host-cdp-requests".into())
        .spawn(move || {
            for paused in rx {
                let (method, params) = decide(&filter, &cors, &paused);
                let _ = conn.call(Some(&paused.session), method, params, INTERNAL_TIMEOUT);
            }
        })
        .map_err(|e| DriverError::closed(format!("could not start the request worker: {e}")))?;
    Ok(tx)
}

/// The answer to one paused request: the request filter first (policy,
/// ranges), then HOST-FETCH-CORS for the host's token requests.
fn decide(
    filter: &Mutex<Option<RequestFilter>>,
    cors: &Mutex<Cors>,
    paused: &PausedRequest,
) -> (&'static str, Value) {
    let id = &paused.request_id;
    if let Some(headers) = &paused.response_headers {
        let relaxed = cors.lock().unwrap_or_else(PoisonError::into_inner).on_response(
            &paused.network_id,
            &paused.url,
            headers,
        );
        return match relaxed {
            // CDP refuses headers without the status ("both should be provided").
            Some(headers) => (
                "Fetch.continueResponse",
                json!({"requestId": id, "responseCode": paused.response_status, "responseHeaders": headers}),
            ),
            None => ("Fetch.continueResponse", json!({"requestId": id})),
        };
    }
    let refused = filter
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone()
        .and_then(|f| f(&paused.target, &paused.url));
    if refused.is_some() {
        return ("Fetch.failRequest", json!({"requestId": id, "errorReason": "BlockedByClient"}));
    }
    let action = cors.lock().unwrap_or_else(PoisonError::into_inner).on_request(
        &paused.target,
        &paused.network_id,
        &paused.method,
        &paused.url,
        &paused.headers,
    );
    match action {
        RequestAction::Continue => ("Fetch.continueRequest", json!({"requestId": id})),
        RequestAction::ContinueWith { headers } => {
            ("Fetch.continueRequest", json!({"requestId": id, "headers": headers}))
        }
        RequestAction::Fulfill { status, headers, body } => (
            "Fetch.fulfillRequest",
            json!({"requestId": id, "responseCode": status, "responseHeaders": headers, "body": body}),
        ),
    }
}

impl Inner {
    /// Steps for a session's setup batch while a filter is set: Fetch
    /// interception, and WebSockets blocked (Fetch never sees them, and an
    /// allow list cannot be written as Chromium block patterns).
    pub(super) fn fetch_enable_step(&self) -> Vec<(&'static str, Value)> {
        if self.request_filter.lock().unwrap_or_else(PoisonError::into_inner).is_none() {
            return Vec::new();
        }
        vec![
            ("Fetch.enable", patterns(self.cors_active())),
            ("Network.enable", json!({})),
            ("Network.setBlockedURLs", json!({"urls": ["ws://*", "wss://*"]})),
        ]
    }

    pub(super) fn request_paused(&self, event: &CdpEvent) {
        let Some(session) = event.session_id.clone() else { return };
        let params = &event.params;
        let text = |value: &Value| value.as_str().unwrap_or("").to_owned();
        // The tab the session belongs to (its page or one of its frames).
        let target = self.lock().target_for_session(&session).unwrap_or("").to_owned();
        // A response-stage pause has a status (or an error) and its headers.
        let response = params.get("responseStatusCode").is_some()
            || params.get("responseErrorReason").is_some();
        let _ = self.paused.lock().unwrap_or_else(PoisonError::into_inner).send(PausedRequest {
            session,
            request_id: text(&params["requestId"]),
            target,
            url: text(&params["request"]["url"]),
            method: text(&params["request"]["method"]),
            headers: params["request"].get("headers").cloned().unwrap_or(json!({})),
            network_id: text(&params["networkId"]),
            response_status: params.get("responseStatusCode").cloned().unwrap_or(json!(200)),
            response_headers: response.then(|| {
                params.get("responseHeaders").and_then(Value::as_array).cloned().unwrap_or_default()
            }),
        });
    }

    pub(super) fn cors_active(&self) -> bool {
        self.cors.lock().unwrap_or_else(PoisonError::into_inner).active()
    }

    /// Re-applies the interception patterns to every session (a host fetch
    /// started or ended: response-stage pauses on or off).
    pub(super) fn refresh_interception(&self) {
        if self.request_filter.lock().unwrap_or_else(PoisonError::into_inner).is_none() {
            return;
        }
        let sessions: Vec<String> = self.lock().sessions.keys().cloned().collect();
        let patterns = patterns(self.cors_active());
        for session in sessions {
            let _ =
                self.conn.call(Some(&session), "Fetch.enable", patterns.clone(), INTERNAL_TIMEOUT);
        }
    }

    /// Installs or removes the filter and turns interception on or off in
    /// every attached session (tabs and their out-of-process frames).
    pub(super) fn set_request_filter(&self, filter: Option<RequestFilter>) {
        let enable = filter.is_some();
        *self.request_filter.lock().unwrap_or_else(PoisonError::into_inner) = filter;
        let sessions: Vec<String> = self.lock().sessions.keys().cloned().collect();
        for session in sessions {
            let steps = if enable {
                self.fetch_enable_step()
            } else {
                vec![("Fetch.disable", json!({})), ("Network.setBlockedURLs", json!({"urls": []}))]
            };
            let _ = self.conn.call_batch(Some(&session), steps, INTERNAL_TIMEOUT);
        }
    }
}
