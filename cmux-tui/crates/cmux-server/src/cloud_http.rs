//! Bounded JSON HTTP for the Cloud machine agent. Synchronous callers run off
//! async executors; an owned runtime cancels requests and bodies on expiry.

use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

use serde_json::Value;
use tokio::sync::watch;

use crate::store::fetch::check_url;

#[path = "cloud_http_deadline.rs"]
mod deadline;
pub use deadline::RequestDeadline;
#[path = "cloud_http_transport.rs"]
mod transport;
use transport::Transport;

/// A bounded Cloud response: its status, its `Retry-After` (at most 64
/// bytes, as sent) and its body (at most 1 MiB).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Response {
    pub status: u16,
    pub retry_after: Option<String>,
    pub bytes: Vec<u8>,
}

pub struct JsonPoster {
    transport: Mutex<Option<Transport>>,
    allow_http: bool,
    network: watch::Receiver<u64>,
}

/// Counts the machine's address changes; see [`network_changed`].
static NETWORK: LazyLock<watch::Sender<u64>> = LazyLock::new(|| watch::Sender::new(0));

/// The machine's addresses changed (a late network attach, a resume onto another host). A connection opened before
/// can be dead with nothing saying so, and a request on it hangs to its 20 s bound. Every poster's request in flight
/// fails at once, so its caller retries, and every pooled connection is dropped before its next request.
pub fn network_changed() {
    NETWORK.send_modify(|changes| *changes += 1);
}

/// How many times the addresses changed so far: an attempt that failed after the count moved failed on the change,
/// and its retry can go at once.
pub fn network_changes() -> u64 {
    *NETWORK.borrow()
}

#[cfg(test)]
#[path = "cloud_http_tests.rs"]
mod tests;

#[cfg(all(test, any(target_os = "linux", target_vendor = "apple")))]
#[path = "cloud_http_elapsed_tests.rs"]
mod elapsed_tests;

impl JsonPoster {
    pub fn new() -> Result<JsonPoster, String> {
        JsonPoster::build(false)
    }

    /// Also accepts `http://`. Tests only.
    pub fn allowing_http() -> Result<JsonPoster, String> {
        JsonPoster::build(true)
    }

    fn build(allow_http: bool) -> Result<JsonPoster, String> {
        JsonPoster::watching(allow_http, NETWORK.subscribe())
    }

    /// Watches `network` instead of the machine's address changes. Tests only.
    #[cfg(test)]
    pub(crate) fn allowing_http_on(network: &watch::Sender<u64>) -> Result<JsonPoster, String> {
        JsonPoster::watching(true, network.subscribe())
    }

    /// A poster like this one with a pool of its own: a request on it never
    /// queues behind one in flight on this poster.
    pub fn twin(&self) -> Result<JsonPoster, String> {
        JsonPoster::watching(self.allow_http, self.network.clone())
    }

    fn watching(allow_http: bool, network: watch::Receiver<u64>) -> Result<JsonPoster, String> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let epoch = *network.borrow();
        let transport = Transport::new(allow_http, epoch)?;
        Ok(JsonPoster { transport: Mutex::new(Some(transport)), allow_http, network })
    }

    /// An authenticated JSON GET with POST's HTTPS, size and 20 s bounds; a
    /// body that is not JSON reads as `{}`. Unlike
    /// [`JsonPoster::request_with_deadline`], this may carry a bearer: it is
    /// for the authenticated platform API, not policy or keyset reads.
    pub fn get(&self, url: &str, bearer: Option<&str>) -> Result<(u16, Value), String> {
        self.send("GET", url, None, bearer)
    }

    /// One authenticated platform API request with `method` (`GET`, `PUT`,
    /// ...) and an optional JSON body, under GET's bounds and as
    /// [`JsonPoster::post`] answers it.
    pub fn send(
        &self,
        method: &str,
        url: &str,
        body: Option<&Value>,
        bearer: Option<&str>,
    ) -> Result<(u16, Value), String> {
        check_url(url, self.allow_http).map_err(|e| e.to_string())?;
        let verb = reqwest::Method::from_bytes(method.as_bytes())
            .map_err(|_| format!("bad method {method}"))?;
        let deadline = RequestDeadline::from_active(Instant::now() + Duration::from_secs(20))
            .ok_or("Cloud request unavailable")?;
        let Response { status, bytes, .. } =
            self.transport_request(verb, url, body, bearer, &deadline)?;
        let parsed =
            serde_json::from_slice(&bytes).unwrap_or_else(|_| Value::Object(Default::default()));
        Ok((status, parsed))
    }

    /// `(status, body)`; a body that is not JSON reads as `{}`.
    pub fn post(
        &self,
        url: &str,
        body: &Value,
        bearer: Option<&str>,
    ) -> Result<(u16, Value), String> {
        let (status, bytes) =
            self.request_until(url, Some(body), bearer, Instant::now() + Duration::from_secs(20))?;
        let parsed =
            serde_json::from_slice(&bytes).unwrap_or_else(|_| Value::Object(Default::default()));
        Ok((status, parsed))
    }

    /// An authenticated POST without a request body. The carrier-ticket
    /// route distinguishes no body from the JSON object `{}`.
    pub fn post_empty(&self, url: &str, bearer: Option<&str>) -> Result<(u16, Value), String> {
        self.send("POST", url, None, bearer)
    }

    /// One original budget through authentication, policy and keyset reads.
    /// GETs never carry credentials. Errors contain neither URLs nor bodies.
    pub fn request_with_deadline(
        &self,
        url: &str,
        body: Option<&Value>,
        bearer: Option<&str>,
        deadline: &RequestDeadline,
    ) -> Result<(u16, Vec<u8>), String> {
        self.request_with_deadline_headers(url, body, bearer, deadline)
            .map(|response| (response.status, response.bytes))
    }

    /// [`Self::request_with_deadline`], with the response's `Retry-After`.
    pub fn request_with_deadline_headers(
        &self,
        url: &str,
        body: Option<&Value>,
        bearer: Option<&str>,
        deadline: &RequestDeadline,
    ) -> Result<Response, String> {
        check_url(url, self.allow_http).map_err(|_| "Cloud request unavailable")?;
        deadline.remaining().ok_or("Cloud request unavailable")?;
        if body.is_none() && bearer.is_some() {
            return Err("Cloud request unavailable".into());
        }
        let method = if body.is_some() { reqwest::Method::POST } else { reqwest::Method::GET };
        self.transport_request(method, url, body, bearer, deadline)
    }

    fn transport_request(
        &self,
        method: reqwest::Method,
        url: &str,
        body: Option<&Value>,
        bearer: Option<&str>,
        deadline: &RequestDeadline,
    ) -> Result<Response, String> {
        // This synchronous owner is serial. Contention cannot queue a request
        // beyond its original budget.
        let mut slot = self.transport.try_lock().map_err(|_| "Cloud transport unavailable")?;
        let mut network = self.network.clone();
        let epoch = *network.borrow_and_update();
        // A pool from before the latest address change may hold a dead connection.
        if slot.as_ref().is_some_and(|transport| transport.epoch() != epoch)
            && let Some(stale) = slot.take()
        {
            stale.stop();
        }
        if slot.is_none() {
            *slot = Some(Transport::new(self.allow_http, epoch)?);
        }
        let result = slot.as_ref().ok_or("Cloud transport unavailable")?.request(
            method,
            url,
            body,
            bearer,
            deadline,
            &mut network,
        );
        if result.is_err()
            && let Some(transport) = slot.take()
        {
            // Dropping only the request future can leave a suspended connection
            // driver in this current-thread runtime. Stop it before returning.
            transport.stop();
        }
        result
    }

    /// Drops the pooled connection, so the next request dials a fresh one. After a pause the pool's connection is
    /// dead and nothing says so: a request on it would hang to its 20 s bound. A request in flight keeps its
    /// transport, and drops it itself if it fails.
    pub fn reset(&self) {
        if let Ok(mut slot) = self.transport.try_lock()
            && let Some(transport) = slot.take()
        {
            transport.stop();
        }
    }

    /// Compatibility for callers with an active-clock absolute deadline.
    pub fn request_until(
        &self,
        url: &str,
        body: Option<&Value>,
        bearer: Option<&str>,
        deadline: Instant,
    ) -> Result<(u16, Vec<u8>), String> {
        let deadline = RequestDeadline::from_active(deadline).ok_or("Cloud request unavailable")?;
        self.request_with_deadline(url, body, bearer, &deadline)
    }
}

impl Drop for JsonPoster {
    fn drop(&mut self) {
        let slot = self.transport.get_mut().unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(transport) = slot.take() {
            transport.stop();
        }
    }
}
