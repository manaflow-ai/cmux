//! Request interception: the host's domain policy applied to every request
//! a page makes (script navigation, links, popups, redirects, fetch, every
//! subresource), before it is sent, through CDP `Fetch`.

use super::connection::{CdpConnection, CdpEvent};
use super::driver::{INTERNAL_TIMEOUT, Inner};
use crate::driver::RequestFilter;
use crate::protocol::DriverError;
use serde_json::{Value, json};
use std::sync::{Arc, Mutex, PoisonError, mpsc};

/// Every request, at the request stage.
fn patterns() -> Value {
    json!({"patterns": [{"urlPattern": "*", "requestStage": "Request"}]})
}

/// Starts the worker that answers paused requests (off the reader thread,
/// which must never wait on a CDP reply).
pub(super) fn start_worker(
    conn: Arc<CdpConnection>,
    filter: Arc<Mutex<Option<RequestFilter>>>,
) -> Result<mpsc::Sender<(String, String, String)>, DriverError> {
    let (tx, rx) = mpsc::channel::<(String, String, String)>();
    std::thread::Builder::new()
        .name("cmux-browser-host-cdp-requests".into())
        .spawn(move || {
            for (session, request_id, url) in rx {
                let decision = filter
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .clone()
                    .and_then(|f| f(&url));
                let (method, params) = match decision {
                    Some(_) => (
                        "Fetch.failRequest",
                        json!({"requestId": request_id, "errorReason": "BlockedByClient"}),
                    ),
                    None => ("Fetch.continueRequest", json!({"requestId": request_id})),
                };
                let _ = conn.call(Some(&session), method, params, INTERNAL_TIMEOUT);
            }
        })
        .map_err(|e| DriverError::closed(format!("could not start the request worker: {e}")))?;
    Ok(tx)
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
            ("Fetch.enable", patterns()),
            ("Network.enable", json!({})),
            ("Network.setBlockedURLs", json!({"urls": ["ws://*", "wss://*"]})),
        ]
    }

    pub(super) fn request_paused(&self, event: &CdpEvent) {
        let Some(session) = event.session_id.clone() else { return };
        let request_id = event.params["requestId"].as_str().unwrap_or("").to_owned();
        let url = event.params["request"]["url"].as_str().unwrap_or("").to_owned();
        let _ = self
            .paused
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .send((session, request_id, url));
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
