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
    let (base_url, http) = authenticated_http(base_url, api_key, team_id, user_agent)?;
    Ok(Client::new_with_client(&base_url, http))
}

/// [`authenticated_client`] for the [`raw`] client.
pub fn authenticated_raw_client(
    base_url: &str,
    api_key: &str,
    team_id: Option<&str>,
    user_agent: &str,
) -> Result<raw::Client, ClientBuildError> {
    let (base_url, http) = authenticated_http(base_url, api_key, team_id, user_agent)?;
    Ok(raw::Client::new_with_client(&base_url, http))
}

fn authenticated_http(
    base_url: &str,
    api_key: &str,
    team_id: Option<&str>,
    user_agent: &str,
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
    let http = reqwest::Client::builder()
        .default_headers(headers)
        .user_agent(user_agent)
        .connect_timeout(std::time::Duration::from_secs(15))
        .timeout(std::time::Duration::from_secs(120))
        .build()
        .map_err(ClientBuildError::Http)?;
    Ok((base_url.to_owned(), http))
}
