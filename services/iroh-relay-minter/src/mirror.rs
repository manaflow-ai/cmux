//! A second home for `relay.request.v1` while the Cloudflare trust broker is down.
//!
//! The Worker re-reads the device record in its Durable Object on every relay
//! mint, which is how it enforces revocation. This mirror cannot read that store,
//! so it trusts the caller's still-valid 1 h v2 API ticket instead (Leo's TBD
//! d-645f8cf975, answer A: "Trust the 1 h ticket, default-off"). A device revoked
//! during an outage can keep minting relay credentials until its ticket expires,
//! so every credential here expires no later than the ticket that bought it.
//!
//! Off unless `CMUX_RELAY_MIRROR_ENABLED=1`. With the flag unset the route
//! answers 404 and reads no other configuration.

use std::{collections::BTreeMap, env, time::SystemTime};

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use hmac::Mac;
use http_body::Body;
use hyper::{
    Method, Request, Response, StatusCode,
    body::Bytes,
    header::{AUTHORIZATION, HeaderMap},
};
use iroh::SecretKey;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use vercel_runtime::ResponseBody;
use zeroize::Zeroizing;

use super::{
    ConfigurationError, HmacSha256, bounded_env, error_response, json_response, read_bounded_body,
    single_header, unix_seconds,
};

pub const MIRROR_PATH: &str = "/api/relay-credentials";
/// Same as the Worker's `API_TICKET_SECONDS`.
pub const API_TICKET_SECONDS: u64 = 60 * 60;
/// Same as the Worker's `RELAY_CREDENTIAL_SECONDS`; capped by the ticket's expiry.
pub const RELAY_CREDENTIAL_SECONDS: u64 = 30 * 60;

// The deployed relays' offline admission contract (workers/iroh-v2/src/relay.ts).
const RELAY_TOKEN_ISSUER: &str = "cmux";
const RELAY_TOKEN_AUDIENCE: &str = "cmux-relay";
const TICKET_AUDIENCE: &str = "cmux-iroh-api-v2";
const TICKET_SCHEME: &str = "IrohTicket ";
const MAX_TICKET_BYTES: usize = 8_192;
const CLOCK_SKEW_SECONDS: u64 = 30;
const REFRESH_LEAD_SECONDS: u64 = 300;

const ENABLED_ENV: &str = "CMUX_RELAY_MIRROR_ENABLED";
const ENVIRONMENT_ENV: &str = "CMUX_RELAY_MIRROR_ENVIRONMENT";
const PROJECT_ENV: &str = "CMUX_RELAY_MIRROR_PROJECT_ID";
const TICKET_KEYS_ENV: &str = "CMUX_RELAY_MIRROR_TICKET_KEYS";
const RELAY_URLS_ENV: &str = "CMUX_RELAY_MIRROR_RELAY_URLS";
const RELAY_KEY_ID_ENV: &str = "CMUX_RELAY_MIRROR_RELAY_KEY_ID";
const RELAY_SIGNING_KEY_ENV: &str = "CMUX_RELAY_MIRROR_RELAY_SIGNING_KEY";

/// PKCS#8 v1 prefix of a bare Ed25519 private key; the 32-byte seed follows.
const ED25519_PKCS8_PREFIX: [u8; 16] = [
    0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
];

pub struct MirrorConfig {
    environment: String,
    project_id: String,
    ticket_keys: BTreeMap<String, Zeroizing<Vec<u8>>>,
    relay_urls: Vec<String>,
    relay_key_id: String,
    relay_signing_key: SecretKey,
}

impl MirrorConfig {
    /// `Ok(None)` while the mirror is off, which is the default.
    pub fn from_env() -> Result<Option<Self>, ConfigurationError> {
        if !matches!(env::var(ENABLED_ENV).as_deref(), Ok("1")) {
            return Ok(None);
        }
        let ticket_keys: BTreeMap<String, String> =
            serde_json::from_str(Zeroizing::new(bounded_env(TICKET_KEYS_ENV, 8_192)?).as_str())
                .map_err(|_| ConfigurationError)?;
        let relay_urls: Vec<String> = serde_json::from_str(&bounded_env(RELAY_URLS_ENV, 32_768)?)
            .map_err(|_| ConfigurationError)?;
        let signing_pem = Zeroizing::new(bounded_env(RELAY_SIGNING_KEY_ENV, 4_096)?);
        Self::new(
            bounded_env(ENVIRONMENT_ENV, 128)?,
            bounded_env(PROJECT_ENV, 128)?,
            ticket_keys,
            relay_urls,
            bounded_env(RELAY_KEY_ID_ENV, 128)?,
            parse_ed25519_pkcs8_pem(signing_pem.as_str())?,
        )
        .map(Some)
    }

    fn new(
        environment: String,
        project_id: String,
        ticket_keys: BTreeMap<String, String>,
        relay_urls: Vec<String>,
        relay_key_id: String,
        relay_signing_key: SecretKey,
    ) -> Result<Self, ConfigurationError> {
        if !is_identifier(&environment)
            || !is_identifier(&project_id)
            || !is_identifier(&relay_key_id)
        {
            return Err(ConfigurationError);
        }
        if ticket_keys.is_empty() || relay_urls.is_empty() || relay_urls.len() > 16 {
            return Err(ConfigurationError);
        }
        let mut keys = BTreeMap::new();
        for (key_id, secret) in ticket_keys {
            let secret = Zeroizing::new(secret);
            if !is_identifier(&key_id) {
                return Err(ConfigurationError);
            }
            let bytes = decode_canonical_base64url(&secret).ok_or(ConfigurationError)?;
            if bytes.len() < 32 {
                return Err(ConfigurationError);
            }
            keys.insert(key_id, Zeroizing::new(bytes));
        }
        if !relay_urls.iter().all(|url| is_relay_url(url)) {
            return Err(ConfigurationError);
        }
        let mut seen = std::collections::BTreeSet::new();
        let relay_urls = relay_urls
            .into_iter()
            .filter(|url| seen.insert(url.clone()))
            .collect();
        Ok(Self {
            environment,
            project_id,
            ticket_keys: keys,
            relay_urls,
            relay_key_id,
            relay_signing_key,
        })
    }
}

/// Serves `POST /api/relay-credentials`. `config` is `None` while the mirror is off.
pub async fn handle_mirror_request<B>(
    request: Request<B>,
    config: Option<&MirrorConfig>,
    now: SystemTime,
) -> Response<ResponseBody>
where
    B: Body<Data = Bytes> + Unpin,
{
    let Some(config) = config else {
        return error_response(StatusCode::NOT_FOUND, "not_found");
    };
    match process(request, config, now).await {
        Ok(result) => json_response(StatusCode::OK, &result),
        Err(failure) => error_response(failure.status(), failure.code()),
    }
}

async fn process<B>(
    request: Request<B>,
    config: &MirrorConfig,
    now: SystemTime,
) -> Result<RelayResult, MirrorFailure>
where
    B: Body<Data = Bytes> + Unpin,
{
    if request.method() != Method::POST {
        return Err(MirrorFailure::Method);
    }
    if request.uri().path() != MIRROR_PATH || request.uri().query().is_some() {
        return Err(MirrorFailure::Path);
    }
    let ticket = ticket_from_headers(request.headers())?.to_owned();
    // The ticket carries the whole request; a body would be ignored, so refuse one.
    let body = read_bounded_body(request.into_body())
        .await
        .map_err(|_| MirrorFailure::InvalidBody)?;
    if !body.is_empty() {
        return Err(MirrorFailure::InvalidBody);
    }
    let now = unix_seconds(now).ok_or(MirrorFailure::Internal)?;
    let claims = verify_ticket(&ticket, config, now)?;
    issue_credentials(config, &claims, now)
}

fn ticket_from_headers(headers: &HeaderMap) -> Result<&str, MirrorFailure> {
    let header = single_header(headers, &AUTHORIZATION).ok_or(MirrorFailure::Unauthorized)?;
    let ticket = header
        .strip_prefix(TICKET_SCHEME)
        .ok_or(MirrorFailure::Unauthorized)?;
    if ticket.is_empty() || ticket.len() > MAX_TICKET_BYTES {
        return Err(MirrorFailure::Unauthorized);
    }
    Ok(ticket)
}

/// Mirrors `verifyTicket` in workers/iroh-v2/src/crypto.ts.
fn verify_ticket(
    ticket: &str,
    config: &MirrorConfig,
    now: u64,
) -> Result<TicketClaims, MirrorFailure> {
    let mut parts = ticket.split('.');
    let (Some(body), Some(signature), None) = (parts.next(), parts.next(), parts.next()) else {
        return Err(MirrorFailure::Unauthorized);
    };
    if body.is_empty() || signature.is_empty() {
        return Err(MirrorFailure::Unauthorized);
    }
    let claims_bytes = decode_canonical_base64url(body).ok_or(MirrorFailure::Unauthorized)?;
    let signature = decode_canonical_base64url(signature).ok_or(MirrorFailure::Unauthorized)?;
    let claims: TicketClaims =
        serde_json::from_slice(&claims_bytes).map_err(|_| MirrorFailure::Unauthorized)?;
    if claims.version != 2 || claims.audience != TICKET_AUDIENCE || !claims.is_well_formed() {
        return Err(MirrorFailure::Unauthorized);
    }
    let key = config
        .ticket_keys
        .get(&claims.key_id)
        .ok_or(MirrorFailure::Unauthorized)?;
    let mut mac = HmacSha256::new_from_slice(key).map_err(|_| MirrorFailure::Internal)?;
    mac.update(body.as_bytes());
    mac.verify_slice(&signature)
        .map_err(|_| MirrorFailure::Unauthorized)?;
    if claims.identity.environment != config.environment
        || claims.identity.project_id != config.project_id
    {
        return Err(MirrorFailure::EnvironmentMismatch);
    }
    if claims.issued_at > now.saturating_add(CLOCK_SKEW_SECONDS)
        || claims.expires_at.checked_sub(claims.issued_at) != Some(API_TICKET_SECONDS)
    {
        return Err(MirrorFailure::Unauthorized);
    }
    if claims.expires_at <= now {
        return Err(MirrorFailure::TicketExpired);
    }
    Ok(claims)
}

/// Mirrors `RelayIssuer.issue` in workers/iroh-v2/src/relay.ts, with the expiry
/// capped at the ticket's so revocation lags by at most the ticket's remaining life.
fn issue_credentials(
    config: &MirrorConfig,
    claims: &TicketClaims,
    now: u64,
) -> Result<RelayResult, MirrorFailure> {
    let expires_at = now
        .saturating_add(RELAY_CREDENTIAL_SECONDS)
        .min(claims.expires_at);
    let identity = &claims.identity;
    let subject = hex::encode(Sha256::digest(
        canonical_object(&[
            ("environment", json_string(&identity.environment)?),
            ("projectId", json_string(&identity.project_id)?),
            ("userId", json_string(&identity.user_id)?),
        ])
        .as_bytes(),
    ));
    let header = canonical_object(&[
        ("alg", json_string("EdDSA")?),
        ("kid", json_string(&config.relay_key_id)?),
        ("typ", json_string("JWT")?),
    ]);
    let body = canonical_object(&[
        ("aud", json_string(RELAY_TOKEN_AUDIENCE)?),
        ("endpoint_id", json_string(&claims.endpoint_id)?),
        ("environment", json_string(&identity.environment)?),
        ("exp", expires_at.to_string()),
        ("iat", now.to_string()),
        (
            "identity_generation",
            claims.identity_generation.to_string(),
        ),
        ("iss", json_string(RELAY_TOKEN_ISSUER)?),
        ("project_id", json_string(&identity.project_id)?),
        ("sub", json_string(&subject)?),
        ("team_id", json_string(&identity.team_id)?),
    ]);
    let signing_input = format!(
        "{}.{}",
        URL_SAFE_NO_PAD.encode(header),
        URL_SAFE_NO_PAD.encode(body)
    );
    let signature = config.relay_signing_key.sign(signing_input.as_bytes());
    let token = format!(
        "{signing_input}.{}",
        URL_SAFE_NO_PAD.encode(signature.to_bytes())
    );
    let refresh_after = expires_at.saturating_sub(REFRESH_LEAD_SECONDS).max(now);
    Ok(RelayResult {
        schema_id: "relay.result.v1",
        credentials: config
            .relay_urls
            .iter()
            .map(|relay_url| RelayCredential {
                relay_url: relay_url.clone(),
                token: token.clone(),
                expires_at,
                refresh_after,
            })
            .collect(),
    })
}

/// `canonicalJSON` for an object whose keys the caller lists in sorted order.
fn canonical_object(entries: &[(&str, String)]) -> String {
    debug_assert!(entries.windows(2).all(|pair| pair[0].0 < pair[1].0));
    let fields: Vec<String> = entries
        .iter()
        .map(|(key, value)| format!("\"{key}\":{value}"))
        .collect();
    format!("{{{}}}", fields.join(","))
}

fn json_string(value: &str) -> Result<String, MirrorFailure> {
    serde_json::to_string(value).map_err(|_| MirrorFailure::Internal)
}

fn decode_canonical_base64url(value: &str) -> Option<Vec<u8>> {
    if value.is_empty()
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
    {
        return None;
    }
    let bytes = URL_SAFE_NO_PAD.decode(value.as_bytes()).ok()?;
    (URL_SAFE_NO_PAD.encode(&bytes) == value).then_some(bytes)
}

fn parse_ed25519_pkcs8_pem(pem: &str) -> Result<SecretKey, ConfigurationError> {
    let inner = pem
        .trim()
        .strip_prefix("-----BEGIN PRIVATE KEY-----")
        .and_then(|rest| rest.strip_suffix("-----END PRIVATE KEY-----"))
        .ok_or(ConfigurationError)?;
    let compact: Zeroizing<String> =
        Zeroizing::new(inner.chars().filter(|c| !c.is_whitespace()).collect());
    let der = Zeroizing::new(
        base64::engine::general_purpose::STANDARD
            .decode(compact.as_bytes())
            .map_err(|_| ConfigurationError)?,
    );
    if der.len() != ED25519_PKCS8_PREFIX.len() + 32 || der[..16] != ED25519_PKCS8_PREFIX {
        return Err(ConfigurationError);
    }
    let seed: Zeroizing<[u8; 32]> =
        Zeroizing::new(der[16..].try_into().map_err(|_| ConfigurationError)?);
    Ok(SecretKey::from_bytes(&seed))
}

fn is_identifier(value: &str) -> bool {
    !value.is_empty() && value.chars().count() <= 128
}

fn is_relay_url(value: &str) -> bool {
    value.len() <= 2048
        && value
            .strip_prefix("https://")
            .is_some_and(|rest| !rest.is_empty() && !rest.contains(['@', '?', '#', ' ']))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TicketClaims {
    version: u64,
    audience: String,
    identity: TicketIdentity,
    endpoint_id: String,
    identity_generation: u64,
    issued_at: u64,
    expires_at: u64,
    key_id: String,
}

impl TicketClaims {
    fn is_well_formed(&self) -> bool {
        let identity = &self.identity;
        [
            &identity.environment,
            &identity.project_id,
            &identity.team_id,
            &identity.user_id,
            &identity.device_id,
            &self.key_id,
        ]
        .into_iter()
        .all(|value| is_identifier(value))
            && (1..=255).contains(&identity.app_namespace.chars().count())
            && (1..=64).contains(&identity.build_tag.chars().count())
            && self.endpoint_id.len() == 64
            && self
                .endpoint_id
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TicketIdentity {
    environment: String,
    project_id: String,
    team_id: String,
    user_id: String,
    device_id: String,
    app_namespace: String,
    build_tag: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RelayResult {
    schema_id: &'static str,
    credentials: Vec<RelayCredential>,
}

#[derive(Serialize)]
struct RelayCredential {
    #[serde(rename = "relayURL")]
    relay_url: String,
    token: String,
    #[serde(rename = "expiresAt")]
    expires_at: u64,
    #[serde(rename = "refreshAfter")]
    refresh_after: u64,
}

#[derive(Clone, Copy, Debug)]
enum MirrorFailure {
    Method,
    Path,
    Unauthorized,
    TicketExpired,
    EnvironmentMismatch,
    InvalidBody,
    Internal,
}

impl MirrorFailure {
    const fn status(self) -> StatusCode {
        match self {
            Self::Method => StatusCode::METHOD_NOT_ALLOWED,
            Self::Path => StatusCode::NOT_FOUND,
            Self::Unauthorized | Self::TicketExpired => StatusCode::UNAUTHORIZED,
            Self::EnvironmentMismatch => StatusCode::FORBIDDEN,
            Self::InvalidBody => StatusCode::BAD_REQUEST,
            Self::Internal => StatusCode::INTERNAL_SERVER_ERROR,
        }
    }

    const fn code(self) -> &'static str {
        match self {
            Self::Method => "method_not_allowed",
            Self::Path => "not_found",
            Self::Unauthorized => "unauthorized",
            Self::TicketExpired => "ticket_expired",
            Self::EnvironmentMismatch => "environment_mismatch",
            Self::InvalidBody => "invalid_body",
            Self::Internal => "internal_error",
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, UNIX_EPOCH};

    use http_body_util::{BodyExt as _, Full};
    use serde_json::Value;

    use super::*;

    const NOW: u64 = 1_800_000_000;
    const TICKET_KEY: [u8; 32] = [0x5a; 32];
    const RELAY_SEED: [u8; 32] = [0x33; 32];
    const ENDPOINT: &str = "aa00000000000000000000000000000000000000000000000000000000000001";

    fn config() -> MirrorConfig {
        MirrorConfig::new(
            "production".into(),
            "project-1".into(),
            BTreeMap::from([("k1".to_owned(), URL_SAFE_NO_PAD.encode(TICKET_KEY))]),
            vec![
                "https://relay-a.cmux.dev".into(),
                "https://relay-b.cmux.dev".into(),
                "https://relay-a.cmux.dev".into(),
            ],
            "relay-key-1".into(),
            SecretKey::from_bytes(&RELAY_SEED),
        )
        .expect("test config is valid")
    }

    /// Builds a ticket the way `issueTicket` in crypto.ts does.
    fn ticket(issued_at: u64, key: &[u8], environment: &str) -> String {
        let claims = format!(
            "{{\"audience\":\"cmux-iroh-api-v2\",\"endpointId\":\"{ENDPOINT}\",\"expiresAt\":{},\
             \"identity\":{{\"appNamespace\":\"com.cmux.app\",\"buildTag\":\"nightly\",\"deviceId\":\"d1\",\
             \"environment\":\"{environment}\",\"projectId\":\"project-1\",\"teamId\":\"t1\",\"userId\":\"u1\"}},\
             \"identityGeneration\":7,\"issuedAt\":{issued_at},\"keyId\":\"k1\",\"version\":2}}",
            issued_at + API_TICKET_SECONDS
        );
        let body = URL_SAFE_NO_PAD.encode(claims);
        let mut mac = HmacSha256::new_from_slice(key).expect("key");
        mac.update(body.as_bytes());
        format!(
            "{body}.{}",
            URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes())
        )
    }

    fn request(ticket: &str) -> Request<Full<Bytes>> {
        Request::builder()
            .method(Method::POST)
            .uri(MIRROR_PATH)
            .header(AUTHORIZATION, format!("IrohTicket {ticket}"))
            .body(Full::new(Bytes::new()))
            .expect("request")
    }

    fn at(seconds: u64) -> SystemTime {
        UNIX_EPOCH + Duration::from_secs(seconds)
    }

    async fn call(
        request: Request<Full<Bytes>>,
        config: Option<&MirrorConfig>,
        now: u64,
    ) -> (StatusCode, Value) {
        let response = handle_mirror_request(request, config, at(now)).await;
        let status = response.status();
        let bytes = response
            .into_body()
            .collect()
            .await
            .expect("body")
            .to_bytes();
        (status, serde_json::from_slice(&bytes).expect("json"))
    }

    #[tokio::test]
    async fn a_valid_ticket_mints_signed_relay_credentials_capped_at_the_ticket() {
        let config = config();
        // Issued 50 minutes ago: 10 minutes of ticket left, less than the 30-minute credential.
        let issued_at = NOW - 50 * 60;
        let (status, value) = call(
            request(&ticket(issued_at, &TICKET_KEY, "production")),
            Some(&config),
            NOW,
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{value}");
        assert_eq!(value["schemaId"], "relay.result.v1");
        let credentials = value["credentials"].as_array().expect("credentials");
        assert_eq!(credentials.len(), 2, "duplicate relay URLs collapse");
        let ticket_expiry = issued_at + API_TICKET_SECONDS;
        assert_eq!(credentials[0]["relayURL"], "https://relay-a.cmux.dev");
        assert_eq!(credentials[0]["expiresAt"], ticket_expiry);
        assert_eq!(credentials[0]["refreshAfter"], ticket_expiry - 300);

        let token = credentials[0]["token"].as_str().expect("token");
        let mut parts = token.split('.');
        let (header, body, signature) = (
            parts.next().expect("header"),
            parts.next().expect("body"),
            parts.next().expect("signature"),
        );
        let signature: [u8; 64] = URL_SAFE_NO_PAD
            .decode(signature)
            .expect("b64")
            .try_into()
            .expect("64 bytes");
        SecretKey::from_bytes(&RELAY_SEED)
            .public()
            .verify(
                format!("{header}.{body}").as_bytes(),
                &iroh::Signature::from_bytes(&signature),
            )
            .expect("relay public key verifies the credential");
        let header: Value =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(header).expect("b64")).expect("json");
        assert_eq!(
            header,
            serde_json::json!({"alg": "EdDSA", "kid": "relay-key-1", "typ": "JWT"})
        );
        let body_bytes = URL_SAFE_NO_PAD.decode(body).expect("b64");
        let claims: Value = serde_json::from_slice(&body_bytes).expect("json");
        let subject = hex::encode(Sha256::digest(
            br#"{"environment":"production","projectId":"project-1","userId":"u1"}"#,
        ));
        assert_eq!(
            claims,
            serde_json::json!({
                "aud": "cmux-relay", "endpoint_id": ENDPOINT, "environment": "production",
                "exp": ticket_expiry, "iat": NOW, "identity_generation": 7, "iss": "cmux",
                "project_id": "project-1", "sub": subject, "team_id": "t1",
            })
        );
        assert!(
            std::str::from_utf8(&body_bytes)
                .expect("utf8")
                .starts_with("{\"aud\":"),
            "claims are canonical (sorted) JSON like the Worker's"
        );
    }

    #[tokio::test]
    async fn a_fresh_ticket_gets_the_full_thirty_minute_credential() {
        let config = config();
        let (status, value) = call(
            request(&ticket(NOW - 60, &TICKET_KEY, "production")),
            Some(&config),
            NOW,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(
            value["credentials"][0]["expiresAt"],
            NOW + RELAY_CREDENTIAL_SECONDS
        );
    }

    #[tokio::test]
    async fn an_expired_ticket_is_refused() {
        let config = config();
        let issued_at = NOW - API_TICKET_SECONDS;
        let (status, value) = call(
            request(&ticket(issued_at, &TICKET_KEY, "production")),
            Some(&config),
            NOW,
        )
        .await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        assert_eq!(value["error"], "ticket_expired");
    }

    #[tokio::test]
    async fn a_bad_signature_is_refused() {
        let config = config();
        let (status, value) = call(
            request(&ticket(NOW, &[0x5b; 32], "production")),
            Some(&config),
            NOW,
        )
        .await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        assert_eq!(value["error"], "unauthorized");

        // A valid signature over different claims is refused too.
        let good = ticket(NOW, &TICKET_KEY, "production");
        let other = ticket(NOW - 1, &TICKET_KEY, "production");
        let spliced = format!(
            "{}.{}",
            other.split('.').next().expect("body"),
            good.split('.').nth(1).expect("sig")
        );
        let (status, _) = call(request(&spliced), Some(&config), NOW).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn the_mirror_is_off_unless_enabled() {
        let (status, value) =
            call(request(&ticket(NOW, &TICKET_KEY, "production")), None, NOW).await;
        assert_eq!(status, StatusCode::NOT_FOUND);
        assert_eq!(value["error"], "not_found");
        // The default: with the flag unset, from_env reads nothing else.
        assert!(!matches!(env::var(ENABLED_ENV).as_deref(), Ok("1")));
        assert!(
            MirrorConfig::from_env()
                .expect("off is not an error")
                .is_none()
        );
    }

    #[tokio::test]
    async fn refuses_other_environments_schemes_bodies_and_routes() {
        let config = config();
        let (status, value) = call(
            request(&ticket(NOW, &TICKET_KEY, "staging")),
            Some(&config),
            NOW,
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN);
        assert_eq!(value["error"], "environment_mismatch");

        let token = ticket(NOW, &TICKET_KEY, "production");
        let bearer = Request::builder()
            .method(Method::POST)
            .uri(MIRROR_PATH)
            .header(AUTHORIZATION, format!("Bearer {token}"))
            .body(Full::new(Bytes::new()))
            .expect("request");
        assert_eq!(
            call(bearer, Some(&config), NOW).await.0,
            StatusCode::UNAUTHORIZED
        );

        let with_body = Request::builder()
            .method(Method::POST)
            .uri(MIRROR_PATH)
            .header(AUTHORIZATION, format!("IrohTicket {token}"))
            .body(Full::new(Bytes::from_static(b"{}")))
            .expect("request");
        assert_eq!(
            call(with_body, Some(&config), NOW).await.0,
            StatusCode::BAD_REQUEST
        );

        let wrong_path = Request::builder()
            .method(Method::POST)
            .uri("/api/relay-token")
            .header(AUTHORIZATION, format!("IrohTicket {token}"))
            .body(Full::new(Bytes::new()))
            .expect("request");
        assert_eq!(
            call(wrong_path, Some(&config), NOW).await.0,
            StatusCode::NOT_FOUND
        );

        // A ticket issued too far in the future is refused.
        let future = ticket(NOW + 60, &TICKET_KEY, "production");
        assert_eq!(
            call(request(&future), Some(&config), NOW).await.0,
            StatusCode::UNAUTHORIZED
        );
    }

    #[test]
    fn parses_only_a_bare_ed25519_pkcs8_pem() {
        let mut der = ED25519_PKCS8_PREFIX.to_vec();
        der.extend_from_slice(&RELAY_SEED);
        let pem = format!(
            "-----BEGIN PRIVATE KEY-----\n{}\n-----END PRIVATE KEY-----\n",
            base64::engine::general_purpose::STANDARD.encode(&der)
        );
        let key = parse_ed25519_pkcs8_pem(&pem).expect("pem parses");
        assert_eq!(key.to_bytes(), RELAY_SEED);
        der[2] = 0x03;
        let bad = format!(
            "-----BEGIN PRIVATE KEY-----\n{}\n-----END PRIVATE KEY-----",
            base64::engine::general_purpose::STANDARD.encode(&der)
        );
        assert!(parse_ed25519_pkcs8_pem(&bad).is_err());
    }
}
