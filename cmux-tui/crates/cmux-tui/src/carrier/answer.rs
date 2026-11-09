//! The carrier answer from cmux-platform (`POST /v1/cloud/machines/{id}/carrier`,
//! cmux-platform#924 and #926): `{ok, value: {relay, slot, ticket,
//! expires_at, grant?, daemon_key?}}`, and where it comes from. A dial needs
//! `daemon_key`; a ticket-only refresh does not read it.
//!
//! A body with `noise_key` (base64url of the device's 32-byte Noise key)
//! asks for a grant naming that key as well as the Connect ticket; an empty
//! body asks for a ticket only. A grant is single-use, so each
//! connect attempt asks again. Tickets and grants are never logged.
//!
//! The first connect can skip that ask: a create's (or spare claim's) answer
//! carries the same value as `carrier` (cmux-platform #946), handed to the
//! dial as [`Prefetched`].

use std::path::PathBuf;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde_json::{Value, json};
use url::Url;
use zeroize::Zeroizing;

use super::contract::Vmk;

/// The longest ticket accepted (cmux-remote's relay credential bound).
const MAX_SECRET_BYTES: usize = 4096;
/// One fetch's HTTP deadline (also bounded by the dial's own deadline).
pub(super) const FETCH_TIMEOUT: Duration = Duration::from_secs(20);
/// A cached ticket is reused until this long before it expires.
const TICKET_MARGIN_SECS: u64 = 30;
/// The team selector cmux-platform reads (`TeamSelect.ts` `TEAM_HEADER`).
const TEAM_HEADER: &str = "x-cmux-team";

/// One checked carrier answer.
#[derive(Clone)]
pub(super) struct CarrierAnswer {
    /// `relay+do://<host>` (or `relay+ws://` to this machine, for a local relay).
    pub relay: Url,
    pub slot: String,
    pub ticket: Zeroizing<String>,
    /// Unix seconds.
    pub expires_at: u64,
    pub grant: Option<Zeroizing<String>>,
    /// The machine daemon's Noise static key: 32 canonical base64url bytes,
    /// else None (missing or malformed). A dial refuses to handshake without it.
    pub daemon_key: Option<[u8; 32]>,
    /// The grant's `vmk` claim, `None` when the grant has none (or none
    /// that is `owner` or `team`).
    pub vmk: Option<Vmk>,
}

impl std::fmt::Debug for CarrierAnswer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CarrierAnswer")
            .field("relay", &self.relay.as_str())
            .field("expires_at", &self.expires_at)
            .field("grant", &self.grant.is_some())
            .field("daemon_key", &self.daemon_key.is_some())
            .field("vmk", &self.vmk)
            .finish_non_exhaustive()
    }
}

/// Why a fetch failed. The detail never holds a credential.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct SourceError {
    pub retryable: bool,
    pub detail: String,
}

impl SourceError {
    fn retry(detail: impl Into<String>) -> Self {
        Self { retryable: true, detail: detail.into() }
    }

    fn fatal(detail: impl Into<String>) -> Self {
        Self { retryable: false, detail: detail.into() }
    }
}

/// base64url (no padding) of a 32-byte key, as the platform spells it.
pub(super) fn key_text(key: &[u8; 32]) -> String {
    URL_SAFE_NO_PAD.encode(key)
}

fn key_bytes(text: &str) -> Option<[u8; 32]> {
    let bytes = URL_SAFE_NO_PAD.decode(text).ok()?;
    let key: [u8; 32] = bytes.try_into().ok()?;
    (key_text(&key) == text).then_some(key)
}

fn secret(value: &Value, name: &str) -> Result<Zeroizing<String>, String> {
    secret_up_to(value, name, MAX_SECRET_BYTES)
}

/// [`secret`] up to `max` bytes: a grant may be as long as the session
/// daemon reads (`cmux_link::carrier_grant::MAX_GRANT_BYTES`).
fn secret_up_to(value: &Value, name: &str, max: usize) -> Result<Zeroizing<String>, String> {
    let text = value.get(name).and_then(Value::as_str).ok_or(format!("{name} is missing"))?;
    if text.is_empty() || text.len() > max || !text.bytes().all(|b| (0x21..=0x7e).contains(&b)) {
        return Err(format!("{name} is not 1 to {max} visible ASCII bytes"));
    }
    Ok(Zeroizing::new(text.to_owned()))
}

/// The relay route a carrier dials: `relay+do://<host>`, or `relay+ws://`
/// only to this machine (a local relay in development and tests).
fn relay_route(text: &str) -> Result<Url, String> {
    let url = Url::parse(text).map_err(|_| "relay is not a URL".to_owned())?;
    let local = matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"));
    let bare = url.username().is_empty()
        && url.password().is_none()
        && url.query().is_none()
        && url.fragment().is_none()
        && matches!(url.path(), "" | "/");
    match url.scheme() {
        "relay+do" if bare && url.host_str().is_some() => Ok(url),
        "relay+ws" if bare && local => Ok(url),
        _ => Err("relay is not a relay+do:// origin".into()),
    }
}

/// The `vmk` claim of a compact grant (`header.claims.signature`, base64url
/// JSON claims). Unverified: it only reports what the platform signed.
pub(super) fn grant_vmk(grant: &str) -> Option<Vmk> {
    let mut parts = grant.split('.');
    let claims = match (parts.next(), parts.next(), parts.next(), parts.next()) {
        (Some(_), Some(claims), Some(_), None) => claims,
        _ => return None,
    };
    let claims: Value = serde_json::from_slice(&URL_SAFE_NO_PAD.decode(claims).ok()?).ok()?;
    Vmk::parse(claims.get("vmk")?.as_str()?)
}

/// Checks the answer's `value`.
pub(super) fn parse_answer(value: &Value) -> Result<CarrierAnswer, String> {
    let relay = relay_route(value.get("relay").and_then(Value::as_str).ok_or("relay is missing")?)?;
    let slot = value.get("slot").and_then(Value::as_str).ok_or("slot is missing")?;
    if slot.is_empty()
        || slot.len() > 128
        || !slot.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    {
        return Err("slot is not 1 to 128 base64url characters".into());
    }
    let ticket = secret(value, "ticket")?;
    let expires_at =
        value.get("expires_at").and_then(Value::as_u64).ok_or("expires_at is missing")?;
    let grant = match value.get("grant") {
        None | Some(Value::Null) => None,
        Some(_) => Some(secret_up_to(value, "grant", cmux_link::carrier_grant::MAX_GRANT_BYTES)?),
    };
    let daemon_key = value.get("daemon_key").and_then(Value::as_str).and_then(key_bytes);
    let vmk = grant.as_deref().and_then(|g| grant_vmk(g));
    Ok(CarrierAnswer { relay, slot: slot.to_owned(), ticket, expires_at, grant, daemon_key, vmk })
}

/// Reads one HTTP answer: `{ok: true, value}` is the carrier; anything else
/// is a refusal, retryable on 408, 429 and 5xx (and `owner.unreachable`).
pub(super) fn read_reply(status: u16, body: &Value) -> Result<CarrierAnswer, SourceError> {
    if (200..300).contains(&status) && body.get("ok").and_then(Value::as_bool) == Some(true) {
        return parse_answer(body.get("value").unwrap_or(&Value::Null))
            .map_err(|why| SourceError::fatal(format!("the carrier answer is not valid: {why}")));
    }
    let error = body.get("error");
    let code = error.and_then(|e| e.get("code")).and_then(Value::as_str).unwrap_or("http");
    let message = error.and_then(|e| e.get("message")).and_then(Value::as_str).unwrap_or("");
    let detail = format!("cmux-platform answered {status} {code}: {message}");
    let retryable = matches!(status, 408 | 429 | 500..=599) || code == "owner.unreachable";
    Err(SourceError { retryable, detail })
}

/// Where carrier answers come from.
#[async_trait]
pub(super) trait CarrierSource: Send + Sync {
    /// A Connect ticket for `machine`, and a grant naming `noise_key` when given.
    async fn fetch(
        &self,
        machine: &str,
        noise_key: Option<&[u8; 32]>,
    ) -> Result<CarrierAnswer, SourceError>;
}

/// The person's credential: re-read from the file on every fetch (it may be
/// renewed), or one value from the environment.
#[derive(Clone)]
pub(super) enum Credential {
    File(PathBuf),
    Value(Zeroizing<String>),
}

impl Credential {
    fn current(&self) -> Result<Zeroizing<String>, SourceError> {
        let text = match self {
            Self::Value(value) => value.clone(),
            Self::File(path) => Zeroizing::new(std::fs::read_to_string(path).map_err(|e| {
                SourceError::fatal(format!(
                    "the credential file could not be read ({:?})",
                    e.kind()
                ))
            })?),
        };
        let trimmed = text.trim();
        if trimmed.is_empty() {
            return Err(SourceError::fatal("the cmux credential is empty"));
        }
        Ok(Zeroizing::new(trimmed.to_owned()))
    }
}

/// cmux-platform over HTTPS with the person's credential.
pub(super) struct HttpSource {
    api: String,
    credential: Credential,
    /// A credential handed over later (`carrier serve`'s stdin), used in
    /// place of `credential` from then on.
    replaced: Mutex<Option<Zeroizing<String>>>,
    /// Sent as `x-cmux-team` when set (a machine of a shared team).
    team: Option<String>,
    client: reqwest::Client,
}

impl HttpSource {
    /// `api` is an origin checked by `secure_origin`.
    pub(super) fn new(
        api: String,
        credential: Credential,
        team: Option<String>,
    ) -> Result<Self, String> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(FETCH_TIMEOUT)
            .user_agent(concat!("cmux/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|_| "the HTTP client is unavailable".to_owned())?;
        Ok(Self { api, credential, replaced: Mutex::new(None), team, client })
    }

    /// Every later fetch uses `token`.
    pub(super) fn replace_credential(&self, token: Zeroizing<String>) {
        *self.replaced.lock().unwrap_or_else(PoisonError::into_inner) = Some(token);
    }

    fn current(&self) -> Result<Zeroizing<String>, SourceError> {
        let replaced = self.replaced.lock().unwrap_or_else(PoisonError::into_inner).clone();
        match replaced {
            Some(token) => Ok(token),
            None => self.credential.current(),
        }
    }

    /// POSTs `body` to `path` on the platform with the person's credential
    /// (and the team header): the status and the JSON body (`Null` when the
    /// body is not JSON). No answer at all is a retry.
    pub(super) async fn post(&self, path: &str, body: &Value) -> Result<(u16, Value), SourceError> {
        let credential = self.current()?;
        let mut request = self
            .client
            .post(format!("{}{path}", self.api))
            .bearer_auth(credential.as_str())
            .json(body);
        if let Some(team) = &self.team {
            request = request.header(TEAM_HEADER, team);
        }
        let response =
            request.send().await.map_err(|_| SourceError::retry("cmux-platform did not answer"))?;
        let status = response.status().as_u16();
        Ok((status, response.json().await.unwrap_or(Value::Null)))
    }

    /// Who the current credential names, read afresh (a stdin token, else
    /// the token file re-read now, else the environment's): `sub:<sub>` for
    /// a JWT with a `sub` ([`token_subject`]), else `token:<sha-256 hex>` of
    /// the whole credential, so two opaque credentials never count as one
    /// person. `None` when there is no readable credential.
    pub(super) fn identity(&self) -> Option<String> {
        let token = self.current().ok()?;
        Some(match token_subject(&token) {
            Some(sub) => format!("sub:{sub}"),
            None => {
                use sha2::Digest as _;
                let digest = sha2::Sha256::digest(token.as_bytes());
                let hex: String = digest.iter().map(|byte| format!("{byte:02x}")).collect();
                format!("token:{hex}")
            }
        })
    }
}

/// The `sub` claim of a JWT credential, read without checking its
/// signature (the platform checks the credential; this only tells whether a
/// refreshed credential is the same person's). `None` for anything that is
/// not a JWT with a string `sub`: a JWT has exactly three segments and its
/// first is a JSON header naming an `alg`, so an opaque dotted credential
/// whose middle segment happens to decode never borrows a `sub`.
pub(super) fn token_subject(token: &str) -> Option<String> {
    let mut segments = token.split('.');
    let (Some(header), Some(payload), Some(_), None) =
        (segments.next(), segments.next(), segments.next(), segments.next())
    else {
        return None;
    };
    let decode = |segment: &str| -> Option<Value> {
        let bytes = Zeroizing::new(URL_SAFE_NO_PAD.decode(segment.trim_end_matches('=')).ok()?);
        serde_json::from_slice(&bytes).ok()
    };
    decode(header)?.get("alg")?.as_str()?;
    let claims = decode(payload)?;
    claims.get("sub")?.as_str().filter(|sub| !sub.is_empty()).map(str::to_owned)
}

#[async_trait]
impl CarrierSource for HttpSource {
    async fn fetch(
        &self,
        machine: &str,
        noise_key: Option<&[u8; 32]>,
    ) -> Result<CarrierAnswer, SourceError> {
        let body = match noise_key {
            Some(key) => json!({ "noise_key": key_text(key) }),
            None => json!({}),
        };
        let (status, body) =
            self.post(&format!("/v1/cloud/machines/{machine}/carrier"), &body).await?;
        read_reply(status, &body)
    }
}

fn now_unix() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs())
}

/// The relay credential for each control connect and allocation: one
/// ticket reused until [`TICKET_MARGIN_SECS`] before it expires, then a
/// fresh ticket-only fetch (no grant is minted for a ticket).
pub(super) struct TicketCache {
    source: Arc<dyn CarrierSource>,
    machine: String,
    held: Mutex<Option<(Zeroizing<String>, u64)>>,
}

impl TicketCache {
    pub(super) fn new(
        source: Arc<dyn CarrierSource>,
        machine: String,
        first: &CarrierAnswer,
    ) -> Arc<Self> {
        Arc::new(Self {
            source,
            machine,
            held: Mutex::new(Some((first.ticket.clone(), first.expires_at))),
        })
    }

    /// A ticket that is good for at least the margin at `now` (Unix seconds).
    pub(super) fn usable(expires_at: u64, now: u64) -> bool {
        now.saturating_add(TICKET_MARGIN_SECS) < expires_at
    }

    pub(super) async fn ticket(&self) -> Result<String, ()> {
        if let Some((ticket, expires_at)) =
            self.held.lock().unwrap_or_else(PoisonError::into_inner).as_ref()
            && Self::usable(*expires_at, now_unix())
        {
            return Ok(ticket.to_string());
        }
        let answer = self.source.fetch(&self.machine, None).await.map_err(|_| ())?;
        let ticket = answer.ticket.to_string();
        *self.held.lock().unwrap_or_else(PoisonError::into_inner) =
            Some((answer.ticket, answer.expires_at));
        Ok(ticket)
    }
}

/// A carrier answer handed over ahead of the first connect: the `carrier` of
/// a create's or spare claim's answer (`dial --answer-fd`, or serve's
/// `{"carrier_answer":…}` stdin line). One connect attempt takes it; every
/// later attempt asks the platform as before.
///
/// In `serve` ([`Self::for_identity`]) an answer is bound to whoever the
/// current credential named when it arrived, and only a take while that
/// credential is still current gets it: an answer handed over for one
/// person is never used for another's dial.
#[derive(Default)]
pub(super) struct Prefetched {
    held: Mutex<Option<(CarrierAnswer, Option<String>)>>,
    identity: Option<Arc<dyn Fn() -> Option<String> + Send + Sync>>,
}

impl Prefetched {
    pub(super) fn new(answer: Option<CarrierAnswer>) -> Self {
        Self { held: Mutex::new(answer.map(|answer| (answer, None))), identity: None }
    }

    /// Answers bound to the identity `identity` reads at each put and take.
    pub(super) fn for_identity(identity: Arc<dyn Fn() -> Option<String> + Send + Sync>) -> Self {
        Self { held: Mutex::new(None), identity: Some(identity) }
    }

    /// Holds `answer` for the next attempt, in place of any held one.
    pub(super) fn put(&self, answer: CarrierAnswer) {
        let owner = self.identity.as_ref().and_then(|identity| identity());
        *self.held.lock().unwrap_or_else(PoisonError::into_inner) = Some((answer, owner));
    }

    /// The held answer, once, while its ticket is good for at least the
    /// ticket margin at `now` (Unix seconds) and it has a grant. A stale or
    /// grantless one is dropped, and the attempt asks the platform. So is
    /// one bound to an identity that is not the current one (or to none).
    pub(super) fn take(&self, now: u64) -> Option<CarrierAnswer> {
        let (answer, owner) = self.held.lock().unwrap_or_else(PoisonError::into_inner).take()?;
        if let Some(identity) = &self.identity
            && (owner.is_none() || identity() != owner)
        {
            return None;
        }
        (answer.grant.is_some() && TicketCache::usable(answer.expires_at, now)).then_some(answer)
    }

    /// [`Self::take`] at the current time.
    pub(super) fn take_now(&self) -> Option<CarrierAnswer> {
        self.take(now_unix())
    }
}
