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
    /// Moved into a zeroizing buffer by [`CloudSession::new`].
    pub access_token: String,
    /// Token expiry, Unix milliseconds.
    pub expires_at: u64,
    #[serde(default)]
    pub client_version: Option<String>,
}

impl fmt::Debug for SessionParams {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SessionParams")
            .field("api_base_url", &self.api_base_url)
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
}

impl fmt::Debug for CloudSession {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CloudSession")
            .field("origin", &self.origin)
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
    let host = url.host_str().ok_or_else(|| bad("has no host"))?;
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

/// The `agt` claim (a chief id, `agent_...`) of a JWT-shaped token; `None`
/// for a person's session token. Like `sub`, unverified here.
pub(crate) fn token_agent(token: &str) -> Option<String> {
    token_claim(token, "agt").filter(|agent| super::contract::valid_agent_id(agent))
}

fn token_claim(token: &str, name: &str) -> Option<String> {
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
        Ok(Self {
            origin,
            token,
            expires_at: params.expires_at,
            client_version: params.client_version,
            generation,
            account,
            agent,
        })
    }

    pub(crate) fn origin(&self) -> &str {
        &self.origin
    }

    pub(crate) fn bearer(&self) -> &str {
        &self.token
    }

    pub(crate) fn is_expired(&self, now_ms: u64) -> bool {
        now_ms >= self.expires_at
    }

    pub(crate) fn is_expiring(&self, now_ms: u64) -> bool {
        now_ms.saturating_add(EXPIRING_LEAD_MS) >= self.expires_at
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
