//! Rust client for the cmux VM API.
//!
//! [`Client`] and the [`types`] module are generated from the cmux VM OpenAPI
//! document by `cmux-vm-codegen` (see `scripts/regenerate.sh`). [`raw`] is the
//! same client with every success body returned as raw bytes, for callers that
//! must pass a response through unchanged (fields this version does not know
//! included). This file adds only what the document cannot express: the
//! default host and bearer authentication.

#[allow(
    clippy::all,
    clippy::pedantic,
    unused_imports,
    unused_mut,
    dead_code,
    missing_docs
)]
mod generated;

pub use generated::*;

/// The generated client with success bodies as raw bytes ([`ByteStream`]).
/// Request types live in `raw::types`; they match [`types`] field for field.
pub mod raw {
    pub use super::generated_raw::*;
}

#[allow(
    clippy::all,
    clippy::pedantic,
    unused_imports,
    unused_mut,
    dead_code,
    missing_docs
)]
mod generated_raw;

/// The production cmux VM API.
pub const DEFAULT_BASE_URL: &str = "https://vm.cmux.dev";

/// The header that names the team a session token acts for. API keys belong
/// to one team already, so it is optional for them.
pub const TEAM_HEADER: &str = "x-cmux-team-id";

/// Why a client could not be built.
#[derive(Debug)]
pub enum ClientBuildError {
    /// The API key contains bytes that are not allowed in an HTTP header.
    InvalidApiKey,
    /// The team id contains bytes that are not allowed in an HTTP header.
    InvalidTeamId,
    /// The base URL is not an absolute http or https URL.
    InvalidBaseUrl(String),
    /// The HTTP client could not be constructed.
    Http(reqwest::Error),
}

impl std::fmt::Display for ClientBuildError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidApiKey => f.write_str("the API key is not a valid HTTP header value"),
            Self::InvalidTeamId => f.write_str("the team id is not a valid HTTP header value"),
            Self::InvalidBaseUrl(url) => {
                write!(
                    f,
                    "the base URL {url:?} is not an absolute http or https URL"
                )
            }
            Self::Http(e) => write!(f, "could not build the HTTP client: {e}"),
        }
    }
}

impl std::error::Error for ClientBuildError {}

/// How long a request may take. Ordinary JSON calls get a total deadline;
/// file transfers, whose bodies can take far longer than any fixed total, get
/// none and are bounded by a connect timeout and a read-idle timeout instead.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Limits {
    /// Time to open the connection (TCP and TLS).
    pub connect: std::time::Duration,
    /// Deadline from the request's start until its whole response body
    /// arrived; `None` for transfers.
    pub total: Option<std::time::Duration>,
    /// Longest wait for the response headers, and then between two reads of
    /// the response body. Reqwest starts this wait when the request starts, so
    /// it also bounds sending the request body: leave it `None` for uploads
    /// and bound them by their own progress.
    pub read_idle: Option<std::time::Duration>,
}

/// Time to connect, for every client.
pub const CONNECT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(15);
/// The total deadline of an ordinary JSON call.
pub const API_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(120);
/// The longest silence a transfer response may have: before its headers (a
/// commit verifying a large file answers only when done) or between reads.
pub const TRANSFER_READ_IDLE: std::time::Duration = std::time::Duration::from_secs(300);

impl Limits {
    /// Ordinary JSON calls: one bounded total deadline.
    pub const API: Limits = Limits {
        connect: CONNECT_TIMEOUT,
        total: Some(API_TIMEOUT),
        read_idle: None,
    };
    /// Downloads and bodiless calls that may run long (a commit): no total
    /// deadline, a read-idle bound.
    pub const STREAM: Limits = Limits {
        connect: CONNECT_TIMEOUT,
        total: None,
        read_idle: Some(TRANSFER_READ_IDLE),
    };
    /// Uploads: no total deadline and no reqwest read timeout (which would
    /// bound the whole upload); the caller watches the body's progress. TCP
    /// keepalive still notices a dead peer.
    pub const UPLOAD: Limits = Limits {
        connect: CONNECT_TIMEOUT,
        total: None,
        read_idle: None,
    };
}

/// Builds a client that sends `Authorization: Bearer <api_key>` (marked
/// sensitive, so it never appears in debug output) and, when `team_id` is set,
/// [`TEAM_HEADER`] on every request. Pass `None` for the per-operation team
/// header arguments of the generated methods; this client already sends it.
pub fn authenticated_client(
    base_url: &str,
    api_key: &str,
    team_id: Option<&str>,
    user_agent: &str,
) -> Result<Client, ClientBuildError> {
    let (base_url, http) = authenticated_http(base_url, api_key, team_id, user_agent, Limits::API)?;
    Ok(Client::new_with_client(&base_url, http))
}

/// [`authenticated_client`] for the [`raw`] client, with [`Limits::API`].
pub fn authenticated_raw_client(
    base_url: &str,
    api_key: &str,
    team_id: Option<&str>,
    user_agent: &str,
) -> Result<raw::Client, ClientBuildError> {
    authenticated_raw_client_with(base_url, api_key, team_id, user_agent, Limits::API)
}

/// [`authenticated_raw_client`] with explicit [`Limits`]: [`Limits::STREAM`]
/// for downloads and commits, [`Limits::UPLOAD`] for uploads.
pub fn authenticated_raw_client_with(
    base_url: &str,
    api_key: &str,
    team_id: Option<&str>,
    user_agent: &str,
    limits: Limits,
) -> Result<raw::Client, ClientBuildError> {
    let (base_url, http) = authenticated_http(base_url, api_key, team_id, user_agent, limits)?;
    Ok(raw::Client::new_with_client(&base_url, http))
}

/// A signed invitation request carries no account headers and never follows
/// redirects, which could forward its one-time code to another origin.
pub fn unauthenticated_raw_client(
    base_url: &str,
    user_agent: &str,
) -> Result<raw::Client, ClientBuildError> {
    let base_url = base_url.trim_end_matches('/');
    match reqwest::Url::parse(base_url) {
        Ok(url) if matches!(url.scheme(), "http" | "https") && url.has_host() => {}
        _ => return Err(ClientBuildError::InvalidBaseUrl(base_url.to_owned())),
    }
    let http = reqwest::Client::builder()
        .user_agent(user_agent)
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(CONNECT_TIMEOUT)
        .timeout(API_TIMEOUT)
        .build()
        .map_err(ClientBuildError::Http)?;
    Ok(raw::Client::new_with_client(base_url, http))
}

fn authenticated_http(
    base_url: &str,
    api_key: &str,
    team_id: Option<&str>,
    user_agent: &str,
    limits: Limits,
) -> Result<(String, reqwest::Client), ClientBuildError> {
    let base_url = base_url.trim_end_matches('/');
    match reqwest::Url::parse(base_url) {
        Ok(url) if matches!(url.scheme(), "http" | "https") && url.has_host() => {}
        _ => return Err(ClientBuildError::InvalidBaseUrl(base_url.to_owned())),
    }
    let mut auth = reqwest::header::HeaderValue::try_from(format!("Bearer {api_key}"))
        .map_err(|_| ClientBuildError::InvalidApiKey)?;
    auth.set_sensitive(true);
    let mut headers = reqwest::header::HeaderMap::new();
    headers.insert(reqwest::header::AUTHORIZATION, auth);
    if let Some(team_id) = team_id {
        let team = reqwest::header::HeaderValue::try_from(team_id)
            .map_err(|_| ClientBuildError::InvalidTeamId)?;
        headers.insert(reqwest::header::HeaderName::from_static(TEAM_HEADER), team);
    }
    let mut builder = reqwest::Client::builder()
        .default_headers(headers)
        .user_agent(user_agent)
        .connect_timeout(limits.connect)
        .tcp_keepalive(std::time::Duration::from_secs(30));
    if let Some(total) = limits.total {
        builder = builder.timeout(total);
    }
    if let Some(read_idle) = limits.read_idle {
        builder = builder.read_timeout(read_idle);
    }
    let http = builder.build().map_err(ClientBuildError::Http)?;
    Ok((base_url.to_owned(), http))
}
