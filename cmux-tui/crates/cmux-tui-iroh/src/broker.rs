use std::collections::HashSet;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, bail, ensure};
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use iroh::SecretKey;
use reqwest::{Client, Method, StatusCode};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;
use sha2::{Digest as _, Sha256};
use url::Url;
use uuid::Uuid;

use crate::identity::{BrokerCredential, EndpointMetadata};

const MAX_RESPONSE_BYTES: usize = 1024 * 1024;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
const DISCOVERY_PAGE_SIZE: usize = 128;
const MAX_DISCOVERY_PAGES: usize = 32;
const MAX_DISCOVERY_BINDINGS: usize = 4096;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Platform {
    Mac,
    Ios,
    Linux,
}

impl Platform {
    pub fn current_frontend() -> Result<Self> {
        if cfg!(target_os = "macos") {
            Ok(Self::Mac)
        } else if cfg!(target_os = "linux") {
            Ok(Self::Linux)
        } else {
            bail!("the Stage 1 iroh provider supports macOS and Linux")
        }
    }
}

#[derive(Clone)]
pub struct BrokerClient {
    base_url: Url,
    http: Client,
}

impl std::fmt::Debug for BrokerClient {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("BrokerClient").field("base_url", &self.base_url).finish()
    }
}

impl BrokerClient {
    pub fn new(base_url: Url) -> Result<Self> {
        validate_base_url(&base_url)?;
        let http = Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(REQUEST_TIMEOUT)
            .build()
            .context("cannot construct broker HTTP client")?;
        Ok(Self { base_url, http })
    }

    pub fn base_url(&self) -> &Url {
        &self.base_url
    }

    pub async fn enroll(&self, token: &str) -> Result<EnrollmentCredential> {
        ensure!(safe_secret(token), "provisioning token is invalid");
        self.send_json(
            Method::POST,
            "api/devices/iroh/enroll",
            None,
            Some(&EnrollmentRequest { token }),
            &[],
        )
        .await
    }

    pub async fn relay_access(
        &self,
        credential: &BrokerCredential,
        endpoint_id: &str,
    ) -> Result<RelayAccessResponse> {
        ensure!(canonical_endpoint_id(endpoint_id), "local EndpointID is invalid");
        self.send_json(
            Method::POST,
            "api/relay/token",
            Some(credential),
            Some(&EndpointRequest { endpoint_id }),
            &[],
        )
        .await
    }

    pub async fn register_endpoint(
        &self,
        credential: &BrokerCredential,
        secret_key: &SecretKey,
        metadata: &EndpointMetadata,
        platform: Platform,
        display_name: Option<&str>,
        pairing_enabled: bool,
    ) -> Result<Binding> {
        if let Some(display_name) = display_name {
            validate_display_name(display_name)?;
        }
        let endpoint_id = secret_key.public().to_string();
        let payload = RegistrationPayload {
            route_contract_version: 1,
            device_id: metadata.device_id,
            app_instance_id: metadata.app_instance_id,
            tag: &metadata.tag,
            platform,
            display_name,
            endpoint_id: &endpoint_id,
            identity_generation: metadata.identity_generation,
            pairing_enabled,
            capabilities: if platform == Platform::Linux {
                vec!["cmux.tui.attach"]
            } else {
                Vec::new()
            },
            path_hints: Vec::new(),
        };
        let payload_bytes = serde_json::to_vec(&payload).context("cannot encode registration")?;
        ensure!(payload_bytes.len() <= 32 * 1024, "registration payload is too large");
        let payload_sha256 = hex_sha256(&payload_bytes);
        let challenge: ChallengeResponse = self
            .send_json(
                Method::POST,
                "api/devices/iroh/challenge",
                Some(credential),
                Some(&ChallengeRequest {
                    device_id: metadata.device_id,
                    app_instance_id: metadata.app_instance_id,
                    tag: &metadata.tag,
                    endpoint_id: &endpoint_id,
                    identity_generation: metadata.identity_generation,
                    payload_sha256: &payload_sha256,
                }),
                &[],
            )
            .await?;
        ensure!(canonical_uuid(&challenge.challenge_id), "broker challenge ID is invalid");
        ensure!(canonical_base64url(&challenge.nonce, 32), "broker challenge nonce is invalid");
        let transcript = format!(
            "cmux/iroh/device-registration/v1\n{}\n{}\n{}",
            challenge.challenge_id, challenge.nonce, payload_sha256
        );
        let signature = URL_SAFE_NO_PAD.encode(secret_key.sign(transcript.as_bytes()).to_bytes());
        let response: RegistrationResponse = self
            .send_json(
                Method::POST,
                "api/devices/iroh/register",
                Some(credential),
                Some(&RegisterRequest {
                    challenge_id: &challenge.challenge_id,
                    nonce: &challenge.nonce,
                    payload: &URL_SAFE_NO_PAD.encode(payload_bytes),
                    signature: &signature,
                }),
                &[],
            )
            .await?;
        response.binding.validate()?;
        ensure!(response.binding.device_id == metadata.device_id, "broker changed device ID");
        ensure!(
            response.binding.app_instance_id == metadata.app_instance_id,
            "broker changed app instance ID"
        );
        ensure!(response.binding.tag == metadata.tag, "broker changed registration tag");
        ensure!(response.binding.endpoint_id == endpoint_id, "broker changed EndpointID");
        ensure!(
            response.binding.identity_generation == metadata.identity_generation,
            "broker changed identity generation"
        );
        ensure!(response.binding.platform == platform, "broker changed endpoint platform");
        Ok(response.binding)
    }

    pub async fn discover(&self, credential: &BrokerCredential) -> Result<DiscoverySnapshot> {
        let mut cursor: Option<String> = None;
        let mut cursors = HashSet::new();
        let mut binding_ids = HashSet::new();
        let mut bindings = Vec::new();
        let mut first: Option<DiscoverySnapshot> = None;

        for _ in 0..MAX_DISCOVERY_PAGES {
            let page_size = DISCOVERY_PAGE_SIZE.to_string();
            let mut query = vec![("page_size", page_size.as_str())];
            if let Some(cursor) = cursor.as_deref() {
                query.push(("cursor", cursor));
            }
            let page: DiscoveryPage = self
                .send_json::<(), _>(Method::GET, "api/devices/iroh", Some(credential), None, &query)
                .await?;
            let snapshot = page.discovery;
            snapshot.validate()?;
            if let Some(first) = &first {
                ensure!(snapshot.same_header(first), "broker discovery changed between pages");
            } else {
                first = Some(snapshot.clone_without_bindings());
            }
            for binding in snapshot.bindings {
                binding.validate()?;
                ensure!(binding_ids.insert(binding.binding_id), "duplicate broker binding");
                ensure!(bindings.len() < MAX_DISCOVERY_BINDINGS, "too many broker bindings");
                bindings.push(binding);
            }
            match page.next_cursor {
                Some(next) => {
                    ensure!(!next.is_empty() && next.len() <= 4096, "invalid discovery cursor");
                    ensure!(cursors.insert(next.clone()), "repeated discovery cursor");
                    cursor = Some(next);
                }
                None => {
                    let mut complete = first.context("broker returned no discovery snapshot")?;
                    complete.bindings = bindings;
                    return Ok(complete);
                }
            }
        }
        bail!("broker discovery exceeded the page limit")
    }

    pub async fn issue_pair_grant(
        &self,
        credential: &BrokerCredential,
        initiator_binding_id: Uuid,
        acceptor_binding_id: Uuid,
    ) -> Result<PairGrantResponse> {
        ensure!(initiator_binding_id != acceptor_binding_id, "grant peers must differ");
        let response: PairGrantResponse = self
            .send_json(
                Method::POST,
                "api/devices/iroh/pair-grants",
                Some(credential),
                Some(&PairGrantRequest { initiator_binding_id, acceptor_binding_id }),
                &[],
            )
            .await?;
        ensure!(response.grant.len() <= 32 * 1024, "pair grant is too large");
        ensure!(response.grant.split('.').count() == 3, "pair grant is malformed");
        Ok(response)
    }

    async fn send_json<B: Serialize + ?Sized, R: DeserializeOwned>(
        &self,
        method: Method,
        path: &str,
        credential: Option<&BrokerCredential>,
        body: Option<&B>,
        query: &[(&str, &str)],
    ) -> Result<R> {
        let mut url = self.base_url.join(path).context("cannot build broker URL")?;
        if !query.is_empty() {
            url.query_pairs_mut().extend_pairs(query.iter().copied());
        }
        let mut request =
            self.http.request(method, url.clone()).header("accept", "application/json");
        if let Some(credential) = credential {
            request = request
                .bearer_auth(&credential.access_token)
                .header("x-stack-refresh-token", &credential.refresh_token);
        }
        if let Some(body) = body {
            request = request.json(body);
        }
        let mut response = request.send().await.context("broker request failed")?;
        ensure!(response.url() == &url, "broker changed response URL");
        if let Some(length) = response.content_length() {
            ensure!(length <= MAX_RESPONSE_BYTES as u64, "broker response is too large");
        }
        let status = response.status();
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.context("cannot read broker response")? {
            ensure!(
                bytes.len() + chunk.len() <= MAX_RESPONSE_BYTES,
                "broker response is too large"
            );
            bytes.extend_from_slice(&chunk);
        }
        if !status.is_success() {
            let code = serde_json::from_slice::<ErrorResponse>(&bytes)
                .ok()
                .map(|error| error.error)
                .filter(|code| safe_error_code(code));
            return Err(broker_rejection(status, code.as_deref()));
        }
        serde_json::from_slice(&bytes).context("broker returned invalid JSON")
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EnrollmentCredential {
    pub access_token: String,
    pub refresh_token: String,
}

#[derive(Serialize)]
struct EnrollmentRequest<'a> {
    token: &'a str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct EndpointRequest<'a> {
    endpoint_id: &'a str,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RelayCredential {
    pub relay_url: String,
    pub token: String,
    pub expires_at: i64,
    pub refresh_after: i64,
    pub ttl_seconds: i64,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RelayAccessResponse {
    pub endpoint_id: String,
    #[serde(default)]
    pub relay_credentials: Vec<RelayCredential>,
    pub policy: String,
    pub preference: Value,
    pub preference_revision: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RegistrationPayload<'a> {
    route_contract_version: u32,
    device_id: Uuid,
    app_instance_id: Uuid,
    tag: &'a str,
    platform: Platform,
    #[serde(skip_serializing_if = "Option::is_none")]
    display_name: Option<&'a str>,
    endpoint_id: &'a str,
    identity_generation: u32,
    pairing_enabled: bool,
    capabilities: Vec<&'static str>,
    path_hints: Vec<Value>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ChallengeRequest<'a> {
    device_id: Uuid,
    app_instance_id: Uuid,
    tag: &'a str,
    endpoint_id: &'a str,
    identity_generation: u32,
    payload_sha256: &'a str,
}

#[derive(Deserialize)]
struct ChallengeResponse {
    challenge_id: String,
    nonce: String,
    #[allow(dead_code)]
    expires_at: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RegisterRequest<'a> {
    challenge_id: &'a str,
    nonce: &'a str,
    payload: &'a str,
    signature: &'a str,
}

#[derive(Deserialize)]
struct RegistrationResponse {
    binding: Binding,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Binding {
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    pub binding_id: Uuid,
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    pub device_id: Uuid,
    #[serde(deserialize_with = "deserialize_canonical_uuid")]
    pub app_instance_id: Uuid,
    pub tag: String,
    pub platform: Platform,
    pub display_name: Option<String>,
    pub endpoint_id: String,
    pub identity_generation: u32,
    pub pairing_enabled: bool,
    pub capabilities: Vec<String>,
    #[serde(default)]
    pub path_hints: Vec<Value>,
    pub last_seen_at: String,
}

impl Binding {
    pub fn validate(&self) -> Result<()> {
        ensure!(canonical_endpoint_id(&self.endpoint_id), "broker binding EndpointID is invalid");
        ensure!(self.identity_generation > 0, "broker binding generation is invalid");
        ensure!(safe_token(&self.tag), "broker binding tag is invalid");
        ensure!(self.capabilities.len() <= 32, "broker binding has too many capabilities");
        ensure!(
            self.capabilities.iter().all(|value| safe_token(value)),
            "broker binding capability is invalid"
        );
        ensure!(self.path_hints.len() <= 16, "broker binding has too many path hints");
        if let Some(display_name) = self.display_name.as_deref() {
            validate_display_name(display_name)?;
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct GrantVerificationKey {
    pub kid: String,
    pub alg: String,
    pub spki_der_base64: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct GrantVerificationKeySet {
    pub version: u32,
    pub current_kid: String,
    pub keys: Vec<GrantVerificationKey>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DiscoverySnapshot {
    pub route_contract_version: u32,
    pub revision: u64,
    pub bindings: Vec<Binding>,
    pub relay_fleet: Vec<String>,
    pub lan_rendezvous: Value,
    pub grant_verification_keys: GrantVerificationKeySet,
}

impl DiscoverySnapshot {
    pub fn validate(&self) -> Result<()> {
        ensure!(self.route_contract_version == 1, "unsupported broker route contract");
        ensure!(self.revision > 0, "broker discovery revision is invalid");
        ensure!((1..=16).contains(&self.relay_fleet.len()), "broker relay fleet is invalid");
        let mut relays = HashSet::new();
        for relay in &self.relay_fleet {
            validate_root_https_url(relay)?;
            ensure!(relays.insert(relay), "duplicate broker relay");
        }
        ensure!(self.grant_verification_keys.version == 1, "unsupported grant key set");
        ensure!(
            (1..=2).contains(&self.grant_verification_keys.keys.len()),
            "broker grant key set is invalid"
        );
        ensure!(
            self.grant_verification_keys
                .keys
                .iter()
                .any(|key| key.kid == self.grant_verification_keys.current_kid),
            "broker current grant key is absent"
        );
        Ok(())
    }

    fn same_header(&self, other: &Self) -> bool {
        self.route_contract_version == other.route_contract_version
            && self.revision == other.revision
            && self.relay_fleet == other.relay_fleet
            && self.lan_rendezvous == other.lan_rendezvous
            && self.grant_verification_keys == other.grant_verification_keys
    }

    fn clone_without_bindings(&self) -> Self {
        let mut clone = self.clone();
        clone.bindings.clear();
        clone
    }
}

#[derive(Deserialize)]
struct DiscoveryPage {
    #[serde(flatten)]
    discovery: DiscoverySnapshot,
    next_cursor: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PairGrantRequest {
    initiator_binding_id: Uuid,
    acceptor_binding_id: Uuid,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PairGrantResponse {
    pub grant: String,
    pub expires_at: String,
}

#[derive(Deserialize)]
struct ErrorResponse {
    error: String,
}

fn broker_rejection(status: StatusCode, code: Option<&str>) -> anyhow::Error {
    match code {
        Some(code) => anyhow::anyhow!("broker rejected request with HTTP {status}: {code}"),
        None => anyhow::anyhow!("broker rejected request with HTTP {status}"),
    }
}

fn validate_base_url(url: &Url) -> Result<()> {
    ensure!(url.username().is_empty() && url.password().is_none(), "broker URL has user info");
    ensure!(url.query().is_none() && url.fragment().is_none(), "broker URL has query data");
    let allowed = url.scheme() == "https"
        || (url.scheme() == "http"
            && url
                .host_str()
                .is_some_and(|host| matches!(host, "localhost" | "127.0.0.1" | "::1")));
    ensure!(allowed, "broker URL must use HTTPS or loopback HTTP");
    Ok(())
}

pub fn validate_root_https_url(value: &str) -> Result<()> {
    let parsed = Url::parse(value).context("invalid relay URL")?;
    ensure!(parsed.scheme() == "https", "relay URL must use HTTPS");
    ensure!(parsed.username().is_empty() && parsed.password().is_none(), "relay URL has user info");
    ensure!(parsed.port().is_none(), "relay URL has a port");
    ensure!(parsed.query().is_none() && parsed.fragment().is_none(), "relay URL has query data");
    ensure!(parsed.path() == "/", "relay URL is not a root URL");
    let host = parsed.host_str().context("relay URL has no host")?;
    ensure!(host == host.to_ascii_lowercase(), "relay host is not lowercase");
    ensure!(parsed.as_str() == value, "relay URL is not canonical");
    Ok(())
}

pub fn canonical_endpoint_id(value: &str) -> bool {
    value.len() == 64
        && value.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

pub fn canonical_uuid(value: &str) -> bool {
    Uuid::parse_str(value).is_ok_and(|uuid| uuid.to_string() == value)
}

pub fn deserialize_canonical_uuid<'de, D>(deserializer: D) -> std::result::Result<Uuid, D::Error>
where
    D: Deserializer<'de>,
{
    let value = String::deserialize(deserializer)?;
    ensure_canonical_uuid(&value).map_err(serde::de::Error::custom)
}

fn ensure_canonical_uuid(value: &str) -> Result<Uuid> {
    let uuid = Uuid::parse_str(value).context("UUID is invalid")?;
    ensure!(uuid.to_string() == value, "UUID is not canonical");
    Ok(uuid)
}

pub fn unix_time() -> Result<u64> {
    Ok(SystemTime::now().duration_since(UNIX_EPOCH).context("system clock is invalid")?.as_secs())
}

fn hex_sha256(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut result = String::with_capacity(64);
    for byte in digest {
        use std::fmt::Write as _;
        write!(&mut result, "{byte:02x}").expect("writing to String cannot fail");
    }
    result
}

fn canonical_base64url(value: &str, expected_bytes: usize) -> bool {
    URL_SAFE_NO_PAD
        .decode(value)
        .is_ok_and(|bytes| bytes.len() == expected_bytes && URL_SAFE_NO_PAD.encode(bytes) == value)
}

fn safe_secret(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 16 * 1024
        && !value.bytes().any(|byte| byte.is_ascii_control())
}

fn safe_token(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b':' | b'_'))
}

fn safe_error_code(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
}

fn validate_display_name(value: &str) -> Result<()> {
    ensure!(!value.is_empty() && value.chars().count() <= 128, "display name is invalid");
    ensure!(!value.chars().any(char::is_control), "display name contains a control byte");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn broker_url_rejects_non_loopback_cleartext() {
        assert!(BrokerClient::new(Url::parse("http://example.com/").unwrap()).is_err());
        assert!(BrokerClient::new(Url::parse("http://127.0.0.1:3000/").unwrap()).is_ok());
        assert!(BrokerClient::new(Url::parse("https://example.com/").unwrap()).is_ok());
    }

    #[test]
    fn relay_urls_are_canonical_roots() {
        assert!(validate_root_https_url("https://relay.example.com/").is_ok());
        assert!(validate_root_https_url("http://relay.example.com/").is_err());
        assert!(validate_root_https_url("https://relay.example.com/path").is_err());
        assert!(validate_root_https_url("https://Relay.example.com/").is_err());
    }
}
