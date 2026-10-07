//! The admission gate every data-plane request passes before any upstream
//! byte is sent.
//!
//! Order (each step refuses without reading the next):
//! 1. Browser signals: any `Origin`, any `Sec-Fetch-*` header, or an
//!    `OPTIONS` method is a web page (or its preflight). 403. The router
//!    never sends CORS headers, so a page can neither read a response nor
//!    pass a preflight; this step also stops "simple" requests that need no
//!    preflight.
//! 2. `Host` is exactly one of `127.0.0.1:<port>`, `localhost:<port>`,
//!    `[::1]:<port>`. Anything else (a DNS-rebound name, another port, no
//!    Host, two Hosts) is 421.
//! 3. A key in `Authorization: Bearer` or `x-api-key` (one value; both only
//!    when equal). Missing is 401, wrong/unknown/expired is 401.
//! 4. The path is a served route (404 otherwise) and the key's scope allows
//!    its API family (403 otherwise).

use crate::keys::{ApiFamily, KeyId, KeyRing, KeyScope};
use http::{HeaderMap, Method, StatusCode};

/// Why a request was refused. `reason` is stable and never contains a
/// presented value.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    /// An `Origin` header was present.
    BrowserOrigin,
    /// A `Sec-Fetch-*` header was present.
    BrowserFetch,
    /// An `OPTIONS` (CORS preflight) request.
    Preflight,
    /// `Host` is missing, repeated, or not this listener.
    ForeignHost,
    /// No key was presented.
    MissingKey,
    /// The presented key is malformed, unknown, wrong or expired.
    BadKey,
    /// The path is not a served route.
    UnknownRoute,
    /// The key's scope does not include this API family.
    ScopeDenied,
}

impl Refusal {
    /// The HTTP status of this refusal.
    pub fn status(self) -> StatusCode {
        match self {
            Self::BrowserOrigin | Self::BrowserFetch | Self::Preflight | Self::ScopeDenied => {
                StatusCode::FORBIDDEN
            }
            Self::ForeignHost => StatusCode::MISDIRECTED_REQUEST,
            Self::MissingKey | Self::BadKey => StatusCode::UNAUTHORIZED,
            Self::UnknownRoute => StatusCode::NOT_FOUND,
        }
    }

    /// A stable snake_case reason.
    pub fn reason(self) -> &'static str {
        match self {
            Self::BrowserOrigin => "browser_origin",
            Self::BrowserFetch => "browser_fetch",
            Self::Preflight => "preflight",
            Self::ForeignHost => "foreign_host",
            Self::MissingKey => "missing_key",
            Self::BadKey => "bad_key",
            Self::UnknownRoute => "unknown_route",
            Self::ScopeDenied => "scope_denied",
        }
    }
}

/// An admitted request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Admitted {
    /// The key that admitted it.
    pub key: KeyId,
    /// The API family of the route.
    pub family: ApiFamily,
    /// The key's scope.
    pub scope: KeyScope,
}

/// Run the gate for one request on a listener bound to `port`.
pub fn admit(
    method: &Method,
    path: &str,
    headers: &HeaderMap,
    port: u16,
    keys: &KeyRing,
    now: u64,
) -> Result<Admitted, Refusal> {
    if headers.contains_key(http::header::ORIGIN) {
        return Err(Refusal::BrowserOrigin);
    }
    if headers.keys().any(|name| name.as_str().starts_with("sec-fetch-")) {
        return Err(Refusal::BrowserFetch);
    }
    if method == Method::OPTIONS {
        return Err(Refusal::Preflight);
    }
    check_host(headers, port)?;
    let presented = presented_key(headers)?;
    let (key, scope) = keys.validate(presented, now).map_err(|_| Refusal::BadKey)?;
    let family = ApiFamily::for_path(path).ok_or(Refusal::UnknownRoute)?;
    if method != Method::POST {
        return Err(Refusal::UnknownRoute);
    }
    if !scope.families.contains(&family) {
        return Err(Refusal::ScopeDenied);
    }
    Ok(Admitted { key, family, scope: scope.clone() })
}

fn check_host(headers: &HeaderMap, port: u16) -> Result<(), Refusal> {
    let mut hosts = headers.get_all(http::header::HOST).iter();
    let (Some(host), None) = (hosts.next(), hosts.next()) else {
        return Err(Refusal::ForeignHost);
    };
    let host = host.to_str().map_err(|_| Refusal::ForeignHost)?.to_ascii_lowercase();
    let allowed = ["127.0.0.1", "localhost", "[::1]"].iter().any(|name| {
        host.strip_prefix(name).and_then(|rest| rest.strip_prefix(':')) == Some(&port.to_string())
    });
    if allowed { Ok(()) } else { Err(Refusal::ForeignHost) }
}

fn presented_key(headers: &HeaderMap) -> Result<&str, Refusal> {
    let single = |name: http::header::HeaderName| -> Result<Option<&str>, Refusal> {
        let mut values = headers.get_all(name).iter();
        match (values.next(), values.next()) {
            (None, _) => Ok(None),
            (Some(value), None) => value.to_str().map(Some).map_err(|_| Refusal::BadKey),
            (Some(_), Some(_)) => Err(Refusal::BadKey),
        }
    };
    let bearer = match single(http::header::AUTHORIZATION)? {
        None => None,
        Some(value) => {
            let (scheme, token) = value.trim().split_once(' ').ok_or(Refusal::BadKey)?;
            if !scheme.eq_ignore_ascii_case("bearer") {
                return Err(Refusal::BadKey);
            }
            Some(token.trim())
        }
    };
    let api_key = single(http::header::HeaderName::from_static("x-api-key"))?.map(str::trim);
    match (bearer, api_key) {
        (None, None) => Err(Refusal::MissingKey),
        (Some(""), None) | (None, Some("")) => Err(Refusal::MissingKey),
        (Some(key), None) | (None, Some(key)) => Ok(key),
        (Some(bearer), Some(api_key)) if bearer == api_key => Ok(bearer),
        (Some(_), Some(_)) => Err(Refusal::BadKey),
    }
}
