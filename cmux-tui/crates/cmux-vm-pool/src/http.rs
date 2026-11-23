//! One HTTPS client for the three APIs, with JSON in and out and errors that name the call.

use std::time::Duration;

use serde_json::Value;

/// A failed call: what was called, and why.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CallError(pub String);

impl std::fmt::Display for CallError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for CallError {}

pub type Result<T> = std::result::Result<T, CallError>;

/// Builds the shared client. reqwest rides rustls without a provider of its own: install ring once.
pub fn client() -> Result<reqwest::Client> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(5))
        .timeout(Duration::from_secs(30))
        .pool_max_idle_per_host(64)
        .user_agent("cmux-vm-pool")
        .build()
        .map_err(|e| CallError(format!("http client: {e}")))
}

/// Sends a request with a bearer token and reads the JSON answer (`null` for an empty body).
pub async fn call(
    client: &reqwest::Client,
    method: reqwest::Method,
    url: &str,
    bearer: &str,
    extra: &[(&str, &str)],
    body: Option<&Value>,
) -> Result<Value> {
    let mut request = client.request(method.clone(), url).bearer_auth(bearer);
    for (name, value) in extra {
        request = request.header(*name, *value);
    }
    if let Some(body) = body {
        request = request.json(body);
    } else if method == reqwest::Method::POST {
        request = request.header("content-length", "0");
    }
    let response = request.send().await.map_err(|e| CallError(format!("{method} {url}: {e}")))?;
    let status = response.status();
    let text =
        response.text().await.map_err(|e| CallError(format!("{method} {url}: body: {e}")))?;
    if !status.is_success() {
        let snippet: String = text.chars().take(300).collect();
        return Err(CallError(format!("{method} {url}: HTTP {}: {snippet}", status.as_u16())));
    }
    if text.trim().is_empty() {
        return Ok(Value::Null);
    }
    serde_json::from_str(&text).map_err(|e| CallError(format!("{method} {url}: not JSON: {e}")))
}
