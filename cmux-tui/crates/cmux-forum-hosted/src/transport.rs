//! The one I/O seam: a request goes out, a response (any status) comes back.

use std::fmt;
use std::future::Future;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Method {
    Get,
    Post,
    Patch,
}

impl Method {
    pub fn as_str(self) -> &'static str {
        match self {
            Method::Get => "GET",
            Method::Post => "POST",
            Method::Patch => "PATCH",
        }
    }
}

/// A request relative to the base URL. `path_and_query` starts with `/v1/forum/`.
#[derive(Clone, PartialEq, Eq)]
pub struct Request {
    pub method: Method,
    pub path_and_query: String,
    /// Lowercase names.
    pub headers: Vec<(String, String)>,
    pub body: Option<Vec<u8>>,
}

impl Request {
    /// The first value of a header, by case-insensitive name.
    pub fn header(&self, name: &str) -> Option<&str> {
        find_header(&self.headers, name)
    }
}

/// Redacts `authorization`, so a logged request never shows a credential.
impl fmt::Debug for Request {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let headers: Vec<(&str, &str)> = self
            .headers
            .iter()
            .map(|(k, v)| {
                let v =
                    if k.eq_ignore_ascii_case("authorization") { "<redacted>" } else { v.as_str() };
                (k.as_str(), v)
            })
            .collect();
        f.debug_struct("Request")
            .field("method", &self.method)
            .field("path_and_query", &self.path_and_query)
            .field("headers", &headers)
            .field("body_len", &self.body.as_ref().map(Vec::len))
            .finish()
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Response {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Response {
    /// The first value of a header, by case-insensitive name.
    pub fn header(&self, name: &str) -> Option<&str> {
        find_header(&self.headers, name)
    }
}

fn find_header<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers.iter().find(|(k, _)| k.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_str())
}

/// The request never got an HTTP answer (connect, TLS, timeout).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TransportError {
    pub message: String,
}

impl TransportError {
    pub fn new(message: impl Into<String>) -> Self {
        Self { message: message.into() }
    }
}

impl fmt::Display for TransportError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for TransportError {}

/// Sends one request. Every HTTP status is a `Response`; only a failure to get one is an error.
pub trait Transport: Send + Sync {
    fn send(
        &self,
        request: Request,
    ) -> impl Future<Output = Result<Response, TransportError>> + Send;
}

/// The reqwest transport. The caller builds the `reqwest::Client` (and installs the TLS provider).
#[cfg(feature = "http")]
#[derive(Clone, Debug)]
pub struct HttpTransport {
    base_url: String,
    client: reqwest::Client,
}

#[cfg(feature = "http")]
impl HttpTransport {
    pub fn new(base_url: impl Into<String>, client: reqwest::Client) -> Self {
        Self { base_url: base_url.into().trim_end_matches('/').to_owned(), client }
    }
}

#[cfg(feature = "http")]
impl Transport for HttpTransport {
    async fn send(&self, request: Request) -> Result<Response, TransportError> {
        let method = match request.method {
            Method::Get => reqwest::Method::GET,
            Method::Post => reqwest::Method::POST,
            Method::Patch => reqwest::Method::PATCH,
        };
        let url = format!("{}{}", self.base_url, request.path_and_query);
        let mut builder = self.client.request(method, url);
        for (k, v) in &request.headers {
            builder = builder.header(k.as_str(), v.as_str());
        }
        if let Some(body) = request.body {
            builder = builder.body(body);
        }
        // reqwest's error text names the URL, never the headers.
        let resp = builder.send().await.map_err(|e| TransportError::new(e.to_string()))?;
        let status = resp.status().as_u16();
        let headers = resp
            .headers()
            .iter()
            .filter_map(|(k, v)| Some((k.as_str().to_owned(), v.to_str().ok()?.to_owned())))
            .collect();
        let body = resp.bytes().await.map_err(|e| TransportError::new(e.to_string()))?.to_vec();
        Ok(Response { status, headers, body })
    }
}
