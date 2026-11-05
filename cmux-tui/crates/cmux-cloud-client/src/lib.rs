//! NEXT Cloud's one Rust client (cmuxterm-hq `plans/cloud/ARCHITECTURE-2026-11.md`
//! T2). The cmux CLI, acpmux and the first-party Cloud app server call
//! cmux-platform through it, so no caller writes its own HTTP, its own types
//! or its own retry rules for Cloud (Leo, 2026-11-04: "and moving off swift
//! into rust for next's cloud").
//!
//! - [`Client`] and [`types`] are generated from cmux-platform's
//!   `openapi.json` by `cmux-vm-codegen` (`scripts/update-spec.sh` takes a
//!   newer spec; `scripts/regenerate.sh` reruns the generator, which CI checks).
//!   Only the groups `tags.txt` names are generated. A route NEXT needs that the
//!   spec lacks is a cmux-platform issue (cmux-platform#825), never a type
//!   written here.
//! - [`ops`] sends the `cmux.wire/1` ops (`POST /v1/ops`, `POST /v1/read`)
//!   typed by `cmux-cloud-wire`, the op catalog half of the contract.
//! - [`ApiError`] reads every refusal the same way (the HTTP status and the
//!   `{_tag, code, message}` body cmux-platform's errors carry).
//! - [`backend`] names each environment's platform origin and owner API.
//! - [`client_key`] makes the idempotency key a create or a retried mutation
//!   carries, so a retry after a lost answer never makes a second machine.

#[allow(
    clippy::all,
    clippy::pedantic,
    unused_imports,
    unused_mut,
    unused_qualifications,
    dead_code,
    missing_docs
)]
mod generated;

pub mod backend;
mod error;
pub mod ops;

pub use error::ApiError;
pub use generated::*;

/// The header that names the team a person's session acts for. Install and
/// `cmm_` machine credentials already belong to one team.
pub const TEAM_HEADER: &str = "x-cmux-team";

const CONNECT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(15);
const REQUEST_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(120);

/// Why a client could not be built.
#[derive(Debug)]
pub enum BuildError {
    /// The bearer contains bytes that are not allowed in an HTTP header.
    InvalidBearer,
    /// The team id contains bytes that are not allowed in an HTTP header.
    InvalidTeam,
    /// The base URL is not an absolute http or https URL.
    InvalidBaseUrl(String),
    /// The HTTP client could not be constructed.
    Http(reqwest::Error),
}

impl std::fmt::Display for BuildError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidBearer => f.write_str("the credential is not a valid HTTP header value"),
            Self::InvalidTeam => f.write_str("the team id is not a valid HTTP header value"),
            Self::InvalidBaseUrl(url) => {
                write!(f, "the base URL {url:?} is not an absolute http or https URL")
            }
            Self::Http(e) => write!(f, "could not build the HTTP client: {e}"),
        }
    }
}

impl std::error::Error for BuildError {}

/// Callers bring their own rustls provider (the cmux CLI and acpmux install
/// ring at start), as every reqwest client in this workspace does.
///
/// A client for `base_url` that sends `Authorization: Bearer <bearer>`
/// (marked sensitive, so it never shows in debug output) and, with `team`,
/// [`TEAM_HEADER`] on every request. Pass `None` for the generated methods'
/// own team arguments; this client already sends it. Redirects are never
/// followed, so the bearer cannot be forwarded to another origin.
pub fn client(
    base_url: &str,
    bearer: &str,
    team: Option<&str>,
    user_agent: &str,
) -> Result<Client, BuildError> {
    client_for(base_url, Some(bearer), team, user_agent, REQUEST_TIMEOUT)
}

/// A client with no credential, for the routes that take none (health,
/// client config, join-token redeem, the install challenge).
pub fn anonymous_client(base_url: &str, user_agent: &str) -> Result<Client, BuildError> {
    client_for(base_url, None, None, user_agent, REQUEST_TIMEOUT)
}

/// [`client`] or [`anonymous_client`] with a deadline of its own for each
/// request (acpmux's join answers in 10 s or reports the hub down).
pub fn client_for(
    base_url: &str,
    bearer: Option<&str>,
    team: Option<&str>,
    user_agent: &str,
    timeout: std::time::Duration,
) -> Result<Client, BuildError> {
    let (base_url, http) = http(base_url, bearer, team, user_agent, timeout)?;
    Ok(Client::new_with_client(&base_url, http))
}

/// The `reqwest::Client` [`client`] wraps, for [`ops`] and for the routes
/// cmux-platform does not describe yet (cmux-platform#825).
pub fn http(
    base_url: &str,
    bearer: Option<&str>,
    team: Option<&str>,
    user_agent: &str,
    timeout: std::time::Duration,
) -> Result<(String, reqwest::Client), BuildError> {
    let base_url = base_url.trim_end_matches('/');
    match reqwest::Url::parse(base_url) {
        Ok(url) if matches!(url.scheme(), "http" | "https") && url.has_host() => {}
        _ => return Err(BuildError::InvalidBaseUrl(base_url.to_owned())),
    }
    let mut headers = reqwest::header::HeaderMap::new();
    if let Some(bearer) = bearer {
        let mut auth = reqwest::header::HeaderValue::try_from(format!("Bearer {bearer}"))
            .map_err(|_| BuildError::InvalidBearer)?;
        auth.set_sensitive(true);
        headers.insert(reqwest::header::AUTHORIZATION, auth);
    }
    if let Some(team) = team {
        let value =
            reqwest::header::HeaderValue::try_from(team).map_err(|_| BuildError::InvalidTeam)?;
        headers.insert(reqwest::header::HeaderName::from_static(TEAM_HEADER), value);
    }
    let http = reqwest::Client::builder()
        .default_headers(headers)
        .user_agent(user_agent)
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(CONNECT_TIMEOUT.min(timeout))
        .timeout(timeout)
        .build()
        .map_err(BuildError::Http)?;
    Ok((base_url.to_owned(), http))
}

/// A fresh idempotency key (`ck_` and 32 hex digits from the OS's random
/// source). Make one per intent and send the same one on every retry of it.
pub fn client_key() -> String {
    let mut bytes = [0u8; 16];
    // The OS random source does not fail on the platforms cmux runs on; a
    // failure would leave zeros, which a later key would collide with, so
    // fall back to the clock and the process id as well.
    if getrandom::fill(&mut bytes).is_err() {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos());
        bytes[..8].copy_from_slice(&(nanos as u64).to_le_bytes());
        bytes[8..12].copy_from_slice(&std::process::id().to_le_bytes());
    }
    let mut key = String::with_capacity(35);
    key.push_str("ck_");
    for byte in bytes {
        key.push_str(&format!("{byte:02x}"));
    }
    key
}

/// Installs ring as the process's rustls provider, for tests.
#[cfg(test)]
pub(crate) fn test_tls() {
    let _ = rustls::crypto::ring::default_provider().install_default();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn client_keys_are_distinct_and_shaped() {
        let (a, b) = (client_key(), client_key());
        assert_ne!(a, b);
        assert_eq!(a.len(), 35);
        assert!(a.starts_with("ck_"));
        assert!(a[3..].chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn a_base_url_must_be_absolute_http() {
        test_tls();
        for bad in ["cloud-api.cmux.dev", "ftp://x", "/v1", ""] {
            assert!(matches!(anonymous_client(bad, "t"), Err(BuildError::InvalidBaseUrl(_))));
        }
        assert_eq!(
            anonymous_client("https://cloud-api.cmux.dev/", "t").unwrap().baseurl(),
            "https://cloud-api.cmux.dev"
        );
    }

    #[test]
    fn a_bearer_with_a_newline_is_refused() {
        test_tls();
        assert!(matches!(
            client("https://x.example", "a\nb", None, "t"),
            Err(BuildError::InvalidBearer)
        ));
        assert!(matches!(
            client("https://x.example", "ok", Some("t\r"), "t"),
            Err(BuildError::InvalidTeam)
        ));
    }
}
