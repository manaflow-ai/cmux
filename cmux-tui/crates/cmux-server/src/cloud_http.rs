//! Bounded JSON HTTP for the Cloud machine agent. Synchronous callers run off
//! async executors; an owned runtime cancels requests and bodies on expiry.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::store::fetch::check_url;

#[path = "cloud_http_deadline.rs"]
mod deadline;
pub use deadline::RequestDeadline;
#[path = "cloud_http_transport.rs"]
mod transport;
use transport::Transport;

pub struct JsonPoster {
    transport: Mutex<Option<Transport>>,
    allow_http: bool,
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
        let _ = rustls::crypto::ring::default_provider().install_default();
        Ok(JsonPoster { transport: Mutex::new(Some(Transport::new(allow_http)?)), allow_http })
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
        let (status, bytes) = self.transport_request(verb, url, body, bearer, &deadline)?;
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

    /// One original budget through authentication, policy and keyset reads.
    /// GETs never carry credentials. Errors contain neither URLs nor bodies.
    pub fn request_with_deadline(
        &self,
        url: &str,
        body: Option<&Value>,
        bearer: Option<&str>,
        deadline: &RequestDeadline,
    ) -> Result<(u16, Vec<u8>), String> {
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
    ) -> Result<(u16, Vec<u8>), String> {
        // This synchronous owner is serial. Contention cannot queue a request
        // beyond its original budget.
        let mut slot = self.transport.try_lock().map_err(|_| "Cloud transport unavailable")?;
        if slot.is_none() {
            *slot = Some(Transport::new(self.allow_http)?);
        }
        let result = slot
            .as_ref()
            .ok_or("Cloud transport unavailable")?
            .request(method, url, body, bearer, deadline);
        if result.is_err()
            && let Some(transport) = slot.take()
        {
            // Dropping only the request future can leave a suspended connection
            // driver in this current-thread runtime. Stop it before returning.
            transport.stop();
        }
        result
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
