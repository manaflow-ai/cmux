//! The `net.fetch` egress gate. The app host has no network (OS sandbox);
//! every request goes through here: only `https` to hosts the app holds a
//! `net:` grant for, never while sandboxed, credentials headers stripped,
//! no automatic redirects (a redirect could leave the granted host), bounded
//! bodies and time.

use std::collections::BTreeSet;
use std::time::Duration;

use serde_json::{Value, json};

pub const MAX_REQUEST_BODY: usize = 1024 * 1024;
pub const MAX_RESPONSE_BODY: usize = 4 * 1024 * 1024;
pub const TIMEOUT: Duration = Duration::from_secs(30);
/// Request headers the gate drops: an app never forwards ambient credentials.
const STRIPPED: &[&str] = &["authorization", "cookie", "proxy-authorization", "host"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FetchRequest {
    pub url: String,
    pub method: String,
    pub headers: Vec<(String, String)>,
    pub body: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FetchResponse {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EgressError {
    pub code: &'static str,
    pub message: String,
}

impl EgressError {
    fn denied(message: impl Into<String>) -> Self {
        Self { code: "scope.missing", message: message.into() }
    }

    fn invalid(message: impl Into<String>) -> Self {
        Self { code: "validation.invalid", message: message.into() }
    }
}

/// Performs a request the gate already admitted.
pub trait Fetcher: Send + Sync {
    fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, EgressError>;
}

/// Checks `params` against the grants and returns the request to send.
pub fn admit(
    params: &Value,
    grants: &BTreeSet<String>,
    sandboxed: bool,
) -> Result<FetchRequest, EgressError> {
    if sandboxed {
        return Err(EgressError::denied("the app runs sandboxed: no network"));
    }
    let raw = params
        .get("url")
        .and_then(Value::as_str)
        .ok_or_else(|| EgressError::invalid("url must be a string"))?;
    let url = url::Url::parse(raw).map_err(|e| EgressError::invalid(format!("url: {e}")))?;
    if url.scheme() != "https" {
        return Err(EgressError::denied("only https requests are allowed"));
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err(EgressError::denied("urls with credentials are not allowed"));
    }
    let host =
        url.host_str().ok_or_else(|| EgressError::invalid("url has no host"))?.to_ascii_lowercase();
    if !host_granted(&host, grants) {
        return Err(EgressError::denied(format!("the app holds no net:{host} grant")));
    }
    let method = params.get("method").and_then(Value::as_str).unwrap_or("GET").to_ascii_uppercase();
    if !matches!(method.as_str(), "GET" | "HEAD" | "POST" | "PUT" | "PATCH" | "DELETE" | "OPTIONS")
    {
        return Err(EgressError::invalid(format!("method {method} is not allowed")));
    }
    let headers = params
        .get("headers")
        .and_then(Value::as_object)
        .into_iter()
        .flatten()
        .filter(|(name, _)| !STRIPPED.contains(&name.to_ascii_lowercase().as_str()))
        .filter_map(|(name, value)| value.as_str().map(|v| (name.clone(), v.to_string())))
        .collect();
    let body = params.get("body").and_then(Value::as_str).map(str::to_string);
    if body.as_ref().is_some_and(|b| b.len() > MAX_REQUEST_BODY) {
        return Err(EgressError {
            code: "app.limit",
            message: "request body is larger than 1 MiB".into(),
        });
    }
    Ok(FetchRequest { url: url.to_string(), method, headers, body })
}

/// `net:<host>` matches exactly; `net:*.<domain>` matches subdomains of it.
pub fn host_granted(host: &str, grants: &BTreeSet<String>) -> bool {
    grants.iter().filter_map(|g| g.strip_prefix("net:")).any(|pattern| {
        match pattern.strip_prefix("*.") {
            Some(domain) => {
                host.len() > domain.len() + 1
                    && host.ends_with(domain)
                    && host.as_bytes()[host.len() - domain.len() - 1] == b'.'
            }
            None => host == pattern,
        }
    })
}

pub fn response_json(response: FetchResponse) -> Value {
    let headers: serde_json::Map<String, Value> =
        response.headers.into_iter().map(|(k, v)| (k, Value::String(v))).collect();
    json!({ "value": { "status": response.status, "headers": headers, "body": response.body } })
}

/// The production fetcher: one current-thread runtime per request, on the
/// calling worker thread (net.fetch never runs on a connection thread).
#[cfg(unix)]
pub struct HttpFetcher;

#[cfg(unix)]
impl Fetcher for HttpFetcher {
    fn fetch(&self, request: FetchRequest) -> Result<FetchResponse, EgressError> {
        let failed = |e: &dyn std::fmt::Display| EgressError {
            code: "operation.failed",
            message: e.to_string(),
        };
        let _ = rustls::crypto::ring::default_provider().install_default();
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| failed(&e))?;
        runtime.block_on(async move {
            let client = reqwest::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .timeout(TIMEOUT)
                .build()
                .map_err(|e| failed(&e))?;
            let method =
                reqwest::Method::from_bytes(request.method.as_bytes()).map_err(|e| failed(&e))?;
            let mut builder = client.request(method, &request.url);
            for (name, value) in &request.headers {
                builder = builder.header(name, value);
            }
            if let Some(body) = request.body {
                builder = builder.body(body);
            }
            let mut response = builder.send().await.map_err(|e| failed(&e))?;
            let status = response.status().as_u16();
            let headers = response
                .headers()
                .iter()
                .filter(|(name, _)| name.as_str() != "set-cookie")
                .filter_map(|(name, value)| {
                    value.to_str().ok().map(|v| (name.to_string(), v.to_string()))
                })
                .collect();
            let mut body = Vec::new();
            while let Some(chunk) = response.chunk().await.map_err(|e| failed(&e))? {
                if body.len() + chunk.len() > MAX_RESPONSE_BODY {
                    return Err(EgressError {
                        code: "app.limit",
                        message: "response body is larger than 4 MiB".into(),
                    });
                }
                body.extend_from_slice(&chunk);
            }
            Ok(FetchResponse { status, headers, body: String::from_utf8_lossy(&body).into_owned() })
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn grants(list: &[&str]) -> BTreeSet<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn only_granted_https_hosts_pass_and_credentials_are_stripped() {
        let g = grants(&["net:api.github.com", "net:*.example.com"]);
        let ok = admit(&json!({ "url": "https://api.github.com/x", "headers": { "Authorization": "t", "Cookie": "c", "Accept": "a" } }), &g, false).unwrap();
        assert_eq!(ok.headers, vec![("Accept".to_string(), "a".to_string())]);
        assert!(admit(&json!({ "url": "https://a.b.example.com/" }), &g, false).is_ok());
        assert_eq!(
            admit(&json!({ "url": "https://example.com/" }), &g, false).unwrap_err().code,
            "scope.missing"
        );
        assert_eq!(
            admit(&json!({ "url": "https://evilexample.com/" }), &g, false).unwrap_err().code,
            "scope.missing"
        );
        assert_eq!(
            admit(&json!({ "url": "http://api.github.com/" }), &g, false).unwrap_err().code,
            "scope.missing"
        );
        assert_eq!(
            admit(&json!({ "url": "https://user:pw@api.github.com/" }), &g, false)
                .unwrap_err()
                .code,
            "scope.missing"
        );
        assert_eq!(
            admit(&json!({ "url": "https://other.org/" }), &g, false).unwrap_err().code,
            "scope.missing"
        );
    }

    #[test]
    fn sandboxed_apps_never_reach_the_network() {
        let g = grants(&["net:api.github.com"]);
        assert_eq!(
            admit(&json!({ "url": "https://api.github.com/" }), &g, true).unwrap_err().code,
            "scope.missing"
        );
    }
}
