//! JSON POST for the Cloud machine agent (`cmux host run`'s cloud role):
//! bind, auth and `/v1/ops`. HTTPS only (redirects included), 20 s per
//! request, no async runtime of its own (reqwest's blocking client).

use std::time::Duration;

use serde_json::Value;

use crate::store::fetch::check_url;

pub struct JsonPoster {
    client: reqwest::blocking::Client,
    allow_http: bool,
}

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
        check_url(url, self.allow_http).map_err(|e| e.to_string())?;
        let mut request =
            self.client.post(url).header("content-type", "application/json").body(body.to_string());
        if let Some(token) = bearer {
            request = request.bearer_auth(token);
        }
        let response = request.send().map_err(|e| format!("POST {url}: {e}"))?;
        let status = response.status().as_u16();
        let text = response.text().unwrap_or_default();
        let parsed =
            serde_json::from_str(&text).unwrap_or_else(|_| Value::Object(Default::default()));
        Ok((status, parsed))
    }
}
