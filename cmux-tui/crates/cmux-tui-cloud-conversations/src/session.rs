//! The cloud session lease (home-cloud-proxy.md section 2): the app's Stack
//! access token, held in daemon memory only. Never written to disk, logged
//! or returned; zeroized when replaced or dropped.

use std::fmt;

use serde::Deserialize;
use zeroize::Zeroizing;

use super::CloudError;

/// `expiring` is announced this long before the lease expires.
pub(crate) const EXPIRING_LEAD_MS: u64 = 120_000;
const MAX_TOKEN_CHARS: usize = 8192;
const MAX_VERSION_CHARS: usize = 64;
const MAX_ACCOUNT_CHARS: usize = 256;

/// `cloud-session-set` params.
#[derive(Deserialize)]
pub struct SessionParams {
    pub api_base_url: String,
    /// How the daemon authenticates to `api_base_url`: absent or `"bearer"`
    /// (a cmux Cloud Stack token), or `"tailscale"` (a self-hosted chat
    /// server on the tailnet that identifies the caller by Tailscale: no
    /// token, no expiry, plans/cmux-next/dm-group-chat-DESIGN.md 4.5).
    #[serde(default)]
    pub auth: Option<String>,
    /// Moved into a zeroizing buffer by [`CloudSession::new`]. Required for
    /// a bearer lease; absent (or empty) for a tailscale lease.
    #[serde(default)]
    pub access_token: String,
    /// Token expiry, Unix milliseconds. Required for a bearer lease; ignored
    /// for a tailscale lease.
    #[serde(default)]
    pub expires_at: u64,
    #[serde(default)]
    pub client_version: Option<String>,
}

/// How a lease authenticates to its origin.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum LeaseAuth {
    /// `authorization: Bearer <token>` (cmux Cloud).
    Bearer,
    /// No header: a self-hosted server identifies the peer by Tailscale.
    Tailscale,
}

impl SessionParams {
    pub(crate) fn lease_auth(&self) -> Result<LeaseAuth, CloudError> {
        match self.auth.as_deref() {
            None | Some("bearer") => Ok(LeaseAuth::Bearer),
            Some("tailscale") => Ok(LeaseAuth::Tailscale),
            Some(other) => Err(CloudError::BadRequest(format!(
                "auth must be \"bearer\" or \"tailscale\", not {other:?}"
            ))),
        }
    }
}

impl fmt::Debug for SessionParams {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SessionParams")
            .field("api_base_url", &self.api_base_url)
            .field("auth", &self.auth)
            .field("access_token", &"[redacted]")
            .field("expires_at", &self.expires_at)
            .field("client_version", &self.client_version)
            .finish()
    }
}

/// One validated lease. `generation` increases with every replacement, so an
/// upstream socket can tell that its token changed.
#[derive(Clone)]
pub(crate) struct CloudSession {
    origin: String,
    pub(crate) auth: LeaseAuth,
    /// Empty for a tailscale lease.
    token: Zeroizing<String>,
    pub(crate) expires_at: u64,
    pub(crate) client_version: Option<String>,
    pub(crate) generation: u64,
    /// The cloud user id (JWT `sub`) of the token, read without verifying
    /// the signature: it only tags events with their account, and the Worker
    /// verifies the token on every request. `None` when the token has no
    /// readable `sub`.
    pub(crate) account: Option<String>,
    /// The chief id (JWT `agt`) when the lease is a chief token: the only
    /// source of the MuxDO stream and ack target (`cloud-mux-*`), never a
    /// request field. Read without verifying the signature; the Worker
    /// verifies the token and MuxDO refuses any other chief.
    pub(crate) agent: Option<String>,
    /// The Stack project (JWT `aud`) of a person's session token, read
    /// without verifying the signature: with `account` it names the
    /// person's Worker user id (`cloud-session-status` `participant`), a
    /// label for the person's own clients, never an authorization.
    pub(crate) audience: Option<String>,
}

impl fmt::Debug for CloudSession {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CloudSession")
            .field("origin", &self.origin)
            .field("auth", &self.auth)
            .field("token", &"[redacted]")
            .field("expires_at", &self.expires_at)
            .field("generation", &self.generation)
            .field("account", &self.account)
            .field("agent", &self.agent)
            .finish()
    }
}

fn visible_ascii(value: &str) -> bool {
    value.bytes().all(|byte| byte.is_ascii_graphic())
}

/// The normalized origin of `raw`: `https://host[:port]`, or `http://` with a
/// loopback host. No path, query, fragment or user info.
pub(crate) fn validate_api_base_url(raw: &str) -> Result<String, CloudError> {
    let bad = |detail: &str| CloudError::BadRequest(format!("api_base_url {detail}"));
    let url = url::Url::parse(raw).map_err(|_| bad("is not a URL"))?;
    url.host_str().ok_or_else(|| bad("has no host"))?;
    let loopback = match url.host() {
        Some(url::Host::Domain(domain)) => domain.eq_ignore_ascii_case("localhost"),
        Some(url::Host::Ipv4(address)) => address.is_loopback(),
        Some(url::Host::Ipv6(address)) => address.is_loopback(),
        None => false,
    };
    match url.scheme() {
        "https" => {}
        "http" if loopback => {}
        _ => return Err(bad("must be https (http only for a loopback host)")),
    }
    origin_of(&url)
}

/// Whether `host` is on a tailnet: a MagicDNS `*.ts.net` name, or a
/// Tailscale address (IPv4 100.64.0.0/10, IPv6 fd7a:115c:a1e0::/48).
fn is_tailnet_host(host: &url::Host<&str>) -> bool {
    match host {
        url::Host::Domain(domain) => {
            let domain = domain.trim_end_matches('.').to_ascii_lowercase();
            domain.strip_suffix(".ts.net").is_some_and(|name| {
                !name.is_empty() && name.split('.').all(|label| !label.is_empty())
            })
        }
        url::Host::Ipv4(address) => {
            let [first, second, ..] = address.octets();
            first == 100 && (second & 0xc0) == 0x40
        }
        url::Host::Ipv6(address) => {
            let segments = address.segments();
            segments[0] == 0xfd7a && segments[1] == 0x115c && segments[2] == 0xa1e0
        }
    }
}

/// The normalized origin of a self-hosted chat server (`auth: "tailscale"`):
/// `http` or `https` on a tailnet host only (`is_tailnet_host`), else
/// `unknown_api_origin`. No path, query, fragment or user info.
pub(crate) fn validate_tailnet_origin(raw: &str) -> Result<String, CloudError> {
    let bad = |detail: &str| CloudError::BadRequest(format!("api_base_url {detail}"));
    let url = url::Url::parse(raw).map_err(|_| bad("is not a URL"))?;
    if !matches!(url.scheme(), "http" | "https") {
        return Err(bad("must be http or https"));
    }
    let host = url.host().ok_or_else(|| bad("has no host"))?;
    let origin = origin_of(&url)?;
    if !is_tailnet_host(&host) {
        return Err(CloudError::Rejected {
            code: "unknown_api_origin".into(),
            message: format!(
                "api_base_url {origin} is not a tailnet origin (*.ts.net, 100.64.0.0/10 or fd7a:115c:a1e0::/48)"
            ),
            retryable: false,
        });
    }
    Ok(origin)
}

/// `scheme://host[:port]` of `url`, refusing user info, a path, a query or a fragment.
fn origin_of(url: &url::Url) -> Result<String, CloudError> {
    let bad = |detail: &str| CloudError::BadRequest(format!("api_base_url {detail}"));
    let host = url.host_str().ok_or_else(|| bad("has no host"))?;
    if !url.username().is_empty() || url.password().is_some() {
        return Err(bad("must not carry user info"));
    }
    if !(url.path() == "/" || url.path().is_empty()) || url.query().is_some() {
        return Err(bad("must be an origin without a path or query"));
    }
    if url.fragment().is_some() {
        return Err(bad("must not carry a fragment"));
    }
    let host = if matches!(url.host(), Some(url::Host::Ipv6(_))) && !host.starts_with('[') {
        format!("[{host}]")
    } else {
        host.to_string()
    };
    Ok(match url.port() {
        Some(port) => format!("{}://{host}:{port}", url.scheme()),
        None => format!("{}://{host}", url.scheme()),
    })
}

/// The cmux Cloud API origins a lease from a connection that is not the
/// verified cmux app may name (cmux#13742 review P2-2): production, staging,
/// the development and staging Workers, loopback, and the origins an
/// operator lists in `CMUX_CLOUD_API_ORIGINS` (comma separated) for the
/// daemon (`ServiceOptions::api_origins`). The app chooses its own origin (a
/// debug build may override it).
const KNOWN_API_ORIGINS: &[&str] = &[
    "https://cloud-api.cmux.dev",
    "https://cloud-api-staging.cmux.dev",
    "https://cmux-api-development.debussy.workers.dev",
    "https://cmux-api-staging.debussy.workers.dev",
];

pub(crate) fn check_known_origin(raw: &str, extra: &[String]) -> Result<(), CloudError> {
    let origin = validate_api_base_url(raw)?;
    let loopback = url::Url::parse(&origin).ok().is_some_and(|url| match url.host() {
        Some(url::Host::Domain(domain)) => domain.eq_ignore_ascii_case("localhost"),
        Some(url::Host::Ipv4(address)) => address.is_loopback(),
        Some(url::Host::Ipv6(address)) => address.is_loopback(),
        None => false,
    });
    if loopback
        || KNOWN_API_ORIGINS.contains(&origin.as_str())
        || extra
            .iter()
            .filter_map(|entry| validate_api_base_url(entry).ok())
            .any(|known| known == origin)
    {
        return Ok(());
    }
    Err(CloudError::Rejected {
        code: "unknown_api_origin".into(),
        message: format!("api_base_url {origin} is not a known cmux Cloud origin"),
        retryable: false,
    })
}

/// The `agt` claim (a chief id, `agent_...`) of a JWT-shaped token; `None`
/// for a person's session token. Like `sub`, unverified here.
pub(crate) fn token_agent(token: &str) -> Option<String> {
    token_claim(token, "agt").filter(|agent| super::contract::valid_agent_id(agent))
}

pub(crate) fn token_claim(token: &str, name: &str) -> Option<String> {
    use base64::Engine;
    let mut parts = token.split('.');
    let (_header, payload, _signature) = (parts.next()?, parts.next()?, parts.next()?);
    if parts.next().is_some() {
        return None;
    }
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(payload).ok()?;
    let claims: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
    claims.get(name)?.as_str().map(str::to_string)
}

/// The `sub` claim of a JWT-shaped token (`header.payload.signature`, each
/// part base64url without padding). The signature is not checked: the value
/// only tags events with an account (home-cloud-proxy.md section 5), never
/// authorizes anything.
pub(crate) fn token_account(token: &str) -> Option<String> {
    use base64::Engine;
    let mut parts = token.split('.');
    let (_header, payload, _signature) = (parts.next()?, parts.next()?, parts.next()?);
    if parts.next().is_some() {
        return None;
    }
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(payload).ok()?;
    let claims: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
    let sub = claims.get("sub")?.as_str()?;
    (!sub.is_empty() && sub.len() <= MAX_ACCOUNT_CHARS && visible_ascii(sub))
        .then(|| sub.to_string())
}

impl CloudSession {
    pub(crate) fn new(params: SessionParams, generation: u64) -> Result<Self, CloudError> {
        let auth = params.lease_auth()?;
        if auth == LeaseAuth::Tailscale {
            if !params.access_token.is_empty() {
                return Err(CloudError::BadRequest(
                    "a tailscale lease carries no access_token".into(),
                ));
            }
            if let Some(version) = &params.client_version
                && (version.is_empty()
                    || version.len() > MAX_VERSION_CHARS
                    || !visible_ascii(version))
            {
                return Err(CloudError::BadRequest(format!(
                    "client_version must be 1-{MAX_VERSION_CHARS} visible ASCII characters"
                )));
            }
            return Ok(Self {
                origin: validate_tailnet_origin(&params.api_base_url)?,
                auth,
                token: Zeroizing::new(String::new()),
                // Never expires: is_expired and is_expiring are false for it.
                expires_at: u64::MAX,
                client_version: params.client_version,
                generation,
                // Learned from the server (`cloud-selfhost-info`).
                account: None,
                agent: None,
                audience: None,
            });
        }
        let origin = validate_api_base_url(&params.api_base_url)?;
        let token = Zeroizing::new(params.access_token);
        if token.is_empty() || token.len() > MAX_TOKEN_CHARS || !visible_ascii(&token) {
            return Err(CloudError::BadRequest(format!(
                "access_token must be 1-{MAX_TOKEN_CHARS} visible ASCII characters"
            )));
        }
        if params.expires_at == 0 {
            return Err(CloudError::BadRequest("expires_at must be Unix milliseconds".into()));
        }
        if let Some(version) = &params.client_version
            && (version.is_empty() || version.len() > MAX_VERSION_CHARS || !visible_ascii(version))
        {
            return Err(CloudError::BadRequest(format!(
                "client_version must be 1-{MAX_VERSION_CHARS} visible ASCII characters"
            )));
        }
        let account = token_account(&token);
        let agent = token_agent(&token);
        let audience = token_claim(&token, "aud")
            .filter(|aud| !aud.is_empty() && aud.len() <= MAX_ACCOUNT_CHARS && visible_ascii(aud));
        Ok(Self {
            origin,
            auth,
            token,
            expires_at: params.expires_at,
            client_version: params.client_version,
            generation,
            account,
            agent,
            audience,
        })
    }

    pub(crate) fn origin(&self) -> &str {
        &self.origin
    }

    /// The token for `authorization: Bearer`; none for a tailscale lease.
    pub(crate) fn bearer(&self) -> Option<&str> {
        (self.auth == LeaseAuth::Bearer).then_some(self.token.as_str())
    }

    /// A self-hosted server on the tailnet (`auth: "tailscale"`).
    pub(crate) fn is_tailscale(&self) -> bool {
        self.auth == LeaseAuth::Tailscale
    }

    pub(crate) fn is_expired(&self, now_ms: u64) -> bool {
        !self.is_tailscale() && now_ms >= self.expires_at
    }

    pub(crate) fn is_expiring(&self, now_ms: u64) -> bool {
        !self.is_tailscale() && now_ms.saturating_add(EXPIRING_LEAD_MS) >= self.expires_at
    }

    /// The `cloud-session-set` / `cloud-session-status` fields of an active
    /// lease: a bearer lease names its expiry, a tailscale lease its auth.
    pub(crate) fn status(&self, state: &str) -> serde_json::Value {
        if self.is_tailscale() {
            serde_json::json!({"state": state, "api_base_url": self.origin, "auth": "tailscale"})
        } else {
            serde_json::json!({"state": state, "api_base_url": self.origin, "expires_at": self.expires_at})
        }
    }

    pub(crate) fn http_url(&self, path: &str) -> String {
        format!("{}{path}", self.origin)
    }

    pub(crate) fn ws_url(&self, path: &str) -> String {
        let origin = if let Some(rest) = self.origin.strip_prefix("https://") {
            format!("wss://{rest}")
        } else if let Some(rest) = self.origin.strip_prefix("http://") {
            format!("ws://{rest}")
        } else {
            self.origin.clone()
        };
        format!("{origin}{path}")
    }
}
