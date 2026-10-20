//! JSON POST for the Cloud machine agent (`cmux host run`'s cloud role):
//! bind, auth and `/v1/ops`. HTTPS only, no redirects, 20 s per
//! request, no async runtime of its own (reqwest's blocking client).

use std::io::Read;
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::store::fetch::check_url;

pub struct JsonPoster {
    client: reqwest::blocking::Client,
    allow_http: bool,
}

#[cfg(test)]
#[path = "cloud_http_tests.rs"]
mod tests;

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
        let client = reqwest::blocking::Client::builder()
            .https_only(!allow_http)
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(20))
            .user_agent(concat!("cmux-host/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|e| format!("HTTP client: {e}"))?;
        Ok(JsonPoster { client, allow_http })
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

    /// One request with a shared absolute deadline and a 1 MiB response cap.
    /// GETs never carry credentials. Errors contain neither URLs nor bodies.
    pub fn request_until(
        &self,
        url: &str,
        body: Option<&Value>,
        bearer: Option<&str>,
        deadline: Instant,
    ) -> Result<(u16, Vec<u8>), String> {
        check_url(url, self.allow_http).map_err(|e| e.to_string())?;
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() || (body.is_none() && bearer.is_some()) {
            return Err("Cloud request unavailable".into());
        }
        let mut request = match body {
            Some(body) => self.client.post(url).json(body),
            None => self.client.get(url),
        }
        .timeout(remaining);
        if let Some(token) = bearer {
            request = request.bearer_auth(token);
        }
        let response = request.send().map_err(|_| "Cloud request failed".to_owned())?;
        let status = response.status().as_u16();
        let limit = 1024 * 1024;
        if response.content_length().is_some_and(|n| n > limit) {
            return Err("Cloud response too large".into());
        }
        let mut bytes = Vec::new();
        response
            .take(limit + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| "Cloud response failed".to_owned())?;
        if bytes.len() as u64 > limit || Instant::now() >= deadline {
            return Err("Cloud response unavailable".into());
        }
        Ok((status, bytes))
    }
}
