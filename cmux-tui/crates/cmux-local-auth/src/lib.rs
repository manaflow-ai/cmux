//! The handshake rule every cmux localhost listener applies before its
//! protocol starts (plans/cmux-next/identity.md section 4; spec
//! identity-and-permissions.md section 3, "Localhost HTTP rule"):
//!
//! 1. `Host` names a loopback host (or a name the listener adds, such as its
//!    tailnet name), so a DNS-rebound name is refused.
//! 2. `Origin` is absent (not a browser) or one of the listener's own origins
//!    (or one it adds). `null` is always refused: sandboxed frames on any web
//!    page send it.
//! 3. A token is mandatory and compared in constant time.
//!
//! Pure: no I/O, no allocation on the accept path beyond normalization.

use subtle::ConstantTimeEq;

/// Why a handshake was refused. Every refusal is an HTTP 403 (a 401 for a
/// missing or wrong token) sent before any protocol byte.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    /// No `Host` header, or more than one.
    MissingHost,
    /// `Host` is not a loopback host or a host the listener added.
    ForeignHost,
    /// More than one `Origin` header.
    AmbiguousOrigin,
    /// `Origin: null`.
    NullOrigin,
    /// `Origin` is not one of the listener's origins.
    ForeignOrigin,
    /// No token was presented.
    MissingToken,
    /// The token does not match.
    WrongToken,
}

impl Refusal {
    /// The HTTP status for this refusal.
    pub fn status(self) -> u16 {
        match self {
            Self::MissingToken | Self::WrongToken => 401,
            _ => 403,
        }
    }

    /// A stable snake_case reason for logs and response bodies. It never
    /// contains the presented value.
    pub fn reason(self) -> &'static str {
        match self {
            Self::MissingHost => "missing_host",
            Self::ForeignHost => "foreign_host",
            Self::AmbiguousOrigin => "ambiguous_origin",
            Self::NullOrigin => "null_origin",
            Self::ForeignOrigin => "foreign_origin",
            Self::MissingToken => "missing_token",
            Self::WrongToken => "wrong_token",
        }
    }
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.reason())
    }
}

impl std::error::Error for Refusal {}

/// The Origin and Host rule of one listener.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ListenerPolicy {
    port: u16,
    check_host: bool,
    extra_hosts: Vec<String>,
    extra_origins: Vec<String>,
}

impl ListenerPolicy {
    /// A listener bound on `port` of a loopback address. Its own origins are
    /// `http://127.0.0.1:<port>`, `http://localhost:<port>` and
    /// `http://[::1]:<port>`.
    pub fn loopback(port: u16) -> Self {
        Self { port, check_host: true, extra_hosts: Vec::new(), extra_origins: Vec::new() }
    }

    /// The policy for a listener bound on `address`. A loopback bind gets
    /// [`ListenerPolicy::loopback`]. A non-loopback bind (an explicit opt-in
    /// such as an acpmux peer listener or tailnet mode) is reached by names
    /// the daemon cannot list, so it skips the `Host` rule; its token and
    /// `Origin` rules still apply, and its only browser origins are the
    /// loopback ones.
    pub fn for_bind(address: std::net::SocketAddr) -> Self {
        let mut policy = Self::loopback(address.port());
        policy.check_host = address.ip().is_loopback();
        policy
    }

    /// Also accept `host` (a name or address, without port) in `Host`, and
    /// `http://<host>:<port>` as an origin. For tailnet mode.
    pub fn with_host(mut self, host: &str) -> Self {
        let host = normalize_host_name(host);
        if !host.is_empty() && !self.extra_hosts.contains(&host) {
            self.extra_hosts.push(host);
        }
        self
    }

    /// Also accept `origin` (`scheme://host[:port]`, compared after
    /// [`parse_origin`] normalization). A value that does not parse, and
    /// `null`, are ignored; callers that take origins from users validate
    /// them with [`parse_origin`] first and report the error.
    pub fn with_origin(mut self, origin: &str) -> Self {
        if let Some(origin) = parse_origin(origin)
            && !self.extra_origins.contains(&origin)
        {
            self.extra_origins.push(origin);
        }
        self
    }

    /// The port this policy was built for.
    pub fn port(&self) -> u16 {
        self.port
    }

    /// Check the `Host` and `Origin` header values of one request (every
    /// value of each header, in order).
    pub fn check(&self, hosts: &[&str], origins: &[&str]) -> Result<(), Refusal> {
        let [host] = hosts else { return Err(Refusal::MissingHost) };
        if self.check_host && !self.host_allowed(host) {
            return Err(Refusal::ForeignHost);
        }
        match origins {
            [] => Ok(()),
            [origin] => self.origin_allowed(origin),
            _ => Err(Refusal::AmbiguousOrigin),
        }
    }

    fn host_allowed(&self, value: &str) -> bool {
        let Some(name) = host_without_port(value.trim()) else { return false };
        let name = normalize_host_name(name);
        is_loopback_name(&name) || self.extra_hosts.contains(&name)
    }

    fn origin_allowed(&self, value: &str) -> Result<(), Refusal> {
        if value.trim().eq_ignore_ascii_case("null") {
            return Err(Refusal::NullOrigin);
        }
        let Some(origin) = parse_origin(value) else { return Err(Refusal::ForeignOrigin) };
        if self.extra_origins.contains(&origin) {
            return Ok(());
        }
        let Some(rest) = origin.strip_prefix("http://") else {
            return Err(Refusal::ForeignOrigin);
        };
        // `parse_origin` already validated `rest`.
        let (name, port) = match split_host_port(rest) {
            Some(parts) => parts,
            None => return Err(Refusal::ForeignOrigin),
        };
        let port = port.unwrap_or(80);
        let name = normalize_host_name(name);
        let own_name = is_loopback_name(&name) || self.extra_hosts.contains(&name);
        if own_name && port == self.port { Ok(()) } else { Err(Refusal::ForeignOrigin) }
    }
}

/// Constant-time token comparison. An empty expected token never matches,
/// so a listener cannot run "open" by configuring an empty string.
pub fn tokens_match(provided: &str, expected: &str) -> bool {
    if expected.is_empty() {
        return false;
    }
    bool::from(provided.as_bytes().ct_eq(expected.as_bytes()))
}

/// Check a presented token against the listener's token.
pub fn check_token(provided: Option<&str>, expected: &str) -> Result<(), Refusal> {
    match provided {
        None => Err(Refusal::MissingToken),
        Some("") => Err(Refusal::MissingToken),
        Some(provided) if tokens_match(provided, expected) => Ok(()),
        Some(_) => Err(Refusal::WrongToken),
    }
}

/// The token of an `Authorization: Bearer <token>` value.
pub fn bearer_token(authorization: &str) -> Option<&str> {
    let value = authorization.trim();
    let (scheme, token) = value.split_once(' ')?;
    if !scheme.eq_ignore_ascii_case("bearer") {
        return None;
    }
    let token = token.trim();
    (!token.is_empty()).then_some(token)
}

/// The value of the first `token=` item of a URL query (no percent-decoding:
/// cmux tokens are base64url or hex).
pub fn query_token(query: &str) -> Option<&str> {
    query.split('&').find_map(|item| item.strip_prefix("token=")).filter(|token| !token.is_empty())
}

fn is_loopback_name(name: &str) -> bool {
    matches!(name, "localhost" | "127.0.0.1" | "::1")
}

/// Lowercase, without a trailing dot and without IPv6 brackets.
fn normalize_host_name(name: &str) -> String {
    let name = name.trim().trim_end_matches('.');
    let name = name.strip_prefix('[').and_then(|name| name.strip_suffix(']')).unwrap_or(name);
    name.to_ascii_lowercase()
}

/// The normalized form of an origin `scheme://host[:port]`: lowercase, no
/// trailing slash, no default port (80 for http and ws, 443 for https and
/// wss), IPv6 in brackets. None for `null`, a missing scheme, a path,
/// userinfo or a bad port. `file://` (no host) is kept as is; the policy
/// never accepts it unless a listener adds it.
pub fn parse_origin(origin: &str) -> Option<String> {
    let origin = origin.trim().to_ascii_lowercase();
    let (scheme, rest) = origin.split_once("://")?;
    let rest = rest.strip_suffix('/').unwrap_or(rest);
    if scheme.is_empty()
        || !scheme.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"+-.".contains(&byte))
    {
        return None;
    }
    if rest.is_empty() {
        return (scheme == "file").then(|| "file://".to_owned());
    }
    let (name, port) = split_host_port(rest)?;
    let name = name.trim_end_matches('.');
    if name.is_empty() {
        return None;
    }
    let default = match scheme {
        "http" | "ws" => Some(80),
        "https" | "wss" => Some(443),
        _ => None,
    };
    Some(match port {
        Some(port) if Some(port) != default => format!("{scheme}://{name}:{port}"),
        _ => format!("{scheme}://{name}"),
    })
}

/// The host part of a `Host` value (`name`, `name:port`, `[v6]`, `[v6]:port`).
/// None when the value is malformed.
fn host_without_port(value: &str) -> Option<&str> {
    split_host_port(value).map(|(name, _)| name)
}

fn split_host_port(value: &str) -> Option<(&str, Option<u16>)> {
    if value.is_empty() || value.contains(['/', '@', ' ', '\t']) {
        return None;
    }
    if let Some(rest) = value.strip_prefix('[') {
        let (address, after) = rest.split_once(']')?;
        let name = &value[..address.len() + 2];
        return match after {
            "" => Some((name, None)),
            port => Some((name, Some(port.strip_prefix(':')?.parse().ok()?))),
        };
    }
    match value.rsplit_once(':') {
        // A bare IPv6 address without brackets is not a valid Host value.
        Some((name, _)) if name.contains(':') => None,
        Some((name, port)) => Some((name, Some(port.parse().ok()?))),
        None => Some((value, None)),
    }
}

#[cfg(test)]
mod tests;
