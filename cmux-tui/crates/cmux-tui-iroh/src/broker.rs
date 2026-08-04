//! HTTP client for the cmux trust broker and relay-token routes.
//!
//! Every authenticated call presents the native Stack credential pair
//! (`Authorization: Bearer` + `X-Stack-Refresh-Token`). On a 401 the client
//! refreshes the access token against the Stack API once and retries; the
//! refreshed token is persisted by the caller via [`BrokerClient::credential`].

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Duration;

use anyhow::{Context, bail};
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use ed25519_dalek::Signer as _;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::identity::{Credential, Identity, save_credential};
use crate::timefmt::{parse_expiry, unix_seconds_now};

pub const DEFAULT_BROKER_URL: &str = "https://cmux.dev";
const DEFAULT_STACK_BASE: &str = "https://api.stack-auth.com";
const DEFAULT_STACK_PROJECT_ID: &str = "454ecd03-1db2-4050-845e-4ce5b0cd9895";
const DEFAULT_STACK_PUBLISHABLE_KEY: &str = "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g";
const REGISTRATION_TRANSCRIPT_PREFIX: &str = "cmux/iroh/device-registration/v1";
/// Reuse a cached relay token only while it has this much life left.
const RELAY_TOKEN_MIN_REMAINING_SECONDS: i64 = 90;

pub struct BrokerConfig {
    pub base_url: String,
    pub stack_base: String,
    pub stack_project_id: String,
    pub stack_publishable_key: String,
}

impl BrokerConfig {
    pub fn resolve(base_url_flag: Option<&str>) -> Self {
        let env = |name: &str| std::env::var(name).ok().filter(|value| !value.is_empty());
        Self {
            base_url: base_url_flag
                .map(str::to_string)
                .or_else(|| env("CMUX_TUI_IROH_BROKER"))
                .unwrap_or_else(|| DEFAULT_BROKER_URL.to_string())
                .trim_end_matches('/')
                .to_string(),
            stack_base: env("CMUX_TUI_IROH_STACK_BASE")
                .unwrap_or_else(|| DEFAULT_STACK_BASE.to_string()),
            stack_project_id: env("CMUX_TUI_IROH_STACK_PROJECT")
                .unwrap_or_else(|| DEFAULT_STACK_PROJECT_ID.to_string()),
            stack_publishable_key: env("CMUX_TUI_IROH_STACK_PCK")
                .unwrap_or_else(|| DEFAULT_STACK_PUBLISHABLE_KEY.to_string()),
        }
    }
}

pub struct BrokerClient {
    http: reqwest::Client,
    config: BrokerConfig,
    credential: Mutex<Credential>,
    state_root: PathBuf,
}

#[derive(Debug, Clone, Deserialize)]
pub struct DiscoveredBinding {
    pub binding_id: String,
    pub device_id: String,
    pub tag: String,
    pub platform: String,
    #[serde(default)]
    pub display_name: Option<String>,
    pub endpoint_id: String,
    pub pairing_enabled: bool,
}

#[derive(Debug, Clone)]
pub struct Discovery {
    pub revision: u64,
    pub bindings: Vec<DiscoveredBinding>,
    pub grant_verification_keys: Value,
}

#[derive(Debug, Clone)]
pub struct RelayToken {
    pub token: String,
    pub expires_at_unix: i64,
}

#[derive(Debug, Clone)]
pub struct Registration {
    pub binding_id: String,
    /// A relay credential bootstrapped by the register response, when issued.
    pub relay_token: Option<RelayToken>,
    pub discovery: Option<Discovery>,
}

impl BrokerClient {
    pub fn new(
        config: BrokerConfig,
        credential: Credential,
        state_root: PathBuf,
    ) -> anyhow::Result<Self> {
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .context("building http client")?;
        Ok(Self { http, config, credential: Mutex::new(credential), state_root })
    }

    /// Exchanges a one-use enrollment token for a Stack session credential.
    /// This is the only unauthenticated broker call.
    pub async fn enroll(
        http: &reqwest::Client,
        config: &BrokerConfig,
        enrollment_token: &str,
    ) -> anyhow::Result<Credential> {
        let response = http
            .post(format!("{}/api/devices/iroh/enroll", config.base_url))
            .json(&json!({ "token": enrollment_token }))
            .send()
            .await
            .context("enroll request failed")?;
        let status = response.status();
        let body: Value = response.json().await.context("enroll response was not JSON")?;
        if !status.is_success() {
            bail!("enrollment rejected ({status}): {}", compact_error(&body));
        }
        let access_token = body
            .get("accessToken")
            .and_then(Value::as_str)
            .context("enroll response missing accessToken")?;
        let refresh_token = body
            .get("refreshToken")
            .and_then(Value::as_str)
            .context("enroll response missing refreshToken")?;
        Ok(Credential {
            version: 1,
            access_token: access_token.to_string(),
            refresh_token: refresh_token.to_string(),
        })
    }

    /// Registers (or heartbeats) this identity's binding slot.
    pub async fn register(
        &self,
        identity: &Identity,
        pairing_enabled: bool,
    ) -> anyhow::Result<Registration> {
        let endpoint_id = identity.endpoint_id_hex()?;
        let payload = json!({
            "route_contract_version": 1,
            "deviceId": identity.device_id,
            "appInstanceId": identity.app_instance_id,
            "tag": identity.tag,
            "platform": device_platform(),
            "displayName": format!("cmux-tui {}", identity.tag),
            "endpointId": endpoint_id,
            "identityGeneration": 1,
            "pairingEnabled": pairing_enabled,
            "capabilities": ["cmux.tui.v10"],
            "pathHints": [],
        });
        let payload_bytes = serde_json::to_vec(&payload)?;
        let payload_sha256 = hex(&Sha256::digest(&payload_bytes));

        let challenge = self
            .authed_post(
                "/api/devices/iroh/challenge",
                json!({
                    "deviceId": identity.device_id,
                    "appInstanceId": identity.app_instance_id,
                    "tag": identity.tag,
                    "endpointId": endpoint_id,
                    "identityGeneration": 1,
                    "payloadSha256": payload_sha256,
                }),
            )
            .await
            .context("challenge mint failed")?;
        let challenge_id = challenge
            .get("challenge_id")
            .and_then(Value::as_str)
            .context("challenge response missing challenge_id")?;
        let nonce = challenge
            .get("nonce")
            .and_then(Value::as_str)
            .context("challenge response missing nonce")?;

        let transcript =
            format!("{REGISTRATION_TRANSCRIPT_PREFIX}\n{challenge_id}\n{nonce}\n{payload_sha256}");
        let signature = identity.signing_key()?.sign(transcript.as_bytes());
        let registered = self
            .authed_post(
                "/api/devices/iroh/register",
                json!({
                    "challengeId": challenge_id,
                    "nonce": nonce,
                    "payload": URL_SAFE_NO_PAD.encode(&payload_bytes),
                    "signature": URL_SAFE_NO_PAD.encode(signature.to_bytes()),
                }),
            )
            .await
            .context("registration failed")?;

        let binding_id = registered
            .pointer("/binding/binding_id")
            .and_then(Value::as_str)
            .context("register response missing binding.binding_id")?
            .to_string();
        let relay_token =
            registered.pointer("/relay/status").and_then(Value::as_str).and_then(|status| {
                if status != "issued" {
                    return None;
                }
                let token = registered.pointer("/relay/token")?.as_str()?.to_string();
                let expires_at_unix = parse_expiry(registered.pointer("/relay/expires_at")?)?;
                Some(RelayToken { token, expires_at_unix })
            });
        let discovery = registered.get("discovery").and_then(|value| parse_discovery(value).ok());
        Ok(Registration { binding_id, relay_token, discovery })
    }

    pub async fn discover(&self) -> anyhow::Result<Discovery> {
        let value = self.authed_get("/api/devices/iroh").await.context("discovery failed")?;
        parse_discovery(&value)
    }

    /// Mints a pair grant naming this client as initiator.
    pub async fn pair_grant(
        &self,
        initiator_binding_id: &str,
        acceptor_binding_id: &str,
    ) -> anyhow::Result<String> {
        let value = self
            .authed_post(
                "/api/devices/iroh/pair-grants",
                json!({
                    "initiatorBindingId": initiator_binding_id,
                    "acceptorBindingId": acceptor_binding_id,
                }),
            )
            .await
            .context("pair grant mint failed")?;
        Ok(value
            .get("grant")
            .and_then(Value::as_str)
            .context("pair grant response missing grant")?
            .to_string())
    }

    /// Mints (or reuses from `cached`) a fleet relay token for this endpoint.
    pub async fn relay_token(
        &self,
        endpoint_id: &str,
        cached: Option<RelayToken>,
    ) -> anyhow::Result<RelayToken> {
        if let Some(cached) = cached
            && cached.expires_at_unix - unix_seconds_now() > RELAY_TOKEN_MIN_REMAINING_SECONDS
        {
            return Ok(cached);
        }
        let value = self
            .authed_post("/api/relay/token", json!({ "endpointId": endpoint_id }))
            .await
            .context("relay token mint failed")?;
        if let Some(credentials) = value.get("relayCredentials").and_then(Value::as_array) {
            let first = credentials.first().context("relay token response has no credentials")?;
            let token = first
                .get("token")
                .and_then(Value::as_str)
                .context("relay credential missing token")?
                .to_string();
            let expires_at_unix = first
                .get("expiresAt")
                .and_then(parse_expiry)
                .context("relay credential missing expiresAt")?;
            return Ok(RelayToken { token, expires_at_unix });
        }
        let token = value
            .get("token")
            .and_then(Value::as_str)
            .context("relay token response missing token")?
            .to_string();
        let expires_at_unix = value
            .get("expiresAt")
            .and_then(parse_expiry)
            .context("relay token response missing expiresAt")?;
        Ok(RelayToken { token, expires_at_unix })
    }

    async fn authed_post(&self, path: &str, body: Value) -> anyhow::Result<Value> {
        self.authed(reqwest::Method::POST, path, Some(body)).await
    }

    async fn authed_get(&self, path: &str) -> anyhow::Result<Value> {
        self.authed(reqwest::Method::GET, path, None).await
    }

    async fn authed(
        &self,
        method: reqwest::Method,
        path: &str,
        body: Option<Value>,
    ) -> anyhow::Result<Value> {
        for attempt in 0..2 {
            let (access, refresh) = {
                let credential = self.credential.lock().expect("credential lock");
                (credential.access_token.clone(), credential.refresh_token.clone())
            };
            let mut request = self
                .http
                .request(method.clone(), format!("{}{}", self.config.base_url, path))
                .bearer_auth(&access)
                .header("x-stack-refresh-token", &refresh);
            if let Some(body) = &body {
                request = request.json(body);
            }
            let response =
                request.send().await.with_context(|| format!("{path} request failed"))?;
            let status = response.status();
            if status == reqwest::StatusCode::UNAUTHORIZED && attempt == 0 {
                self.refresh_access_token().await.context("stack token refresh failed")?;
                continue;
            }
            let bytes = response.bytes().await.with_context(|| format!("{path} read failed"))?;
            let value: Value = serde_json::from_slice(&bytes)
                .with_context(|| format!("{path} returned non-JSON ({status})"))?;
            if !status.is_success() {
                bail!("{path} failed ({status}): {}", compact_error(&value));
            }
            return Ok(value);
        }
        unreachable!("authed loop always returns or bails");
    }

    /// Refreshes the Stack access token from the refresh token and persists
    /// the updated credential so restarts keep the newer token.
    async fn refresh_access_token(&self) -> anyhow::Result<()> {
        let refresh = {
            let credential = self.credential.lock().expect("credential lock");
            credential.refresh_token.clone()
        };
        let response = self
            .http
            .post(format!("{}/api/v1/auth/sessions/current/refresh", self.config.stack_base))
            .header("x-stack-project-id", &self.config.stack_project_id)
            .header("x-stack-publishable-client-key", &self.config.stack_publishable_key)
            .header("x-stack-access-type", "client")
            .header("x-stack-refresh-token", &refresh)
            .send()
            .await
            .context("stack refresh request failed")?;
        let status = response.status();
        let value: Value = response.json().await.context("stack refresh response not JSON")?;
        if !status.is_success() {
            bail!("stack refresh failed ({status}): {}", compact_error(&value));
        }
        let access = value
            .get("access_token")
            .and_then(Value::as_str)
            .context("stack refresh response missing access_token")?;
        let updated = {
            let mut credential = self.credential.lock().expect("credential lock");
            credential.access_token = access.to_string();
            credential.clone()
        };
        save_credential(&self.state_root, &updated)?;
        Ok(())
    }
}

fn parse_discovery(value: &Value) -> anyhow::Result<Discovery> {
    let revision =
        value.get("revision").and_then(Value::as_u64).context("discovery missing revision")?;
    let bindings: Vec<DiscoveredBinding> = serde_json::from_value(
        value.get("bindings").cloned().context("discovery missing bindings")?,
    )
    .context("parsing discovery bindings")?;
    let grant_verification_keys = value
        .get("grant_verification_keys")
        .cloned()
        .context("discovery missing grant_verification_keys")?;
    Ok(Discovery { revision, bindings, grant_verification_keys })
}

pub fn device_platform() -> &'static str {
    if cfg!(target_os = "macos") { "mac" } else { "linux" }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Bounded, log-safe rendering of a broker error body.
fn compact_error(value: &Value) -> String {
    let text = value
        .get("code")
        .or_else(|| value.get("error"))
        .map(Value::to_string)
        .unwrap_or_else(|| value.to_string());
    text.chars().take(200).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_discovery_payload() {
        let value = json!({
            "route_contract_version": 1,
            "revision": 7,
            "bindings": [{
                "binding_id": "b1",
                "device_id": "d1",
                "app_instance_id": "a1",
                "tag": "boxa",
                "platform": "linux",
                "display_name": "cmux-tui boxa",
                "endpoint_id": "aa".repeat(32),
                "identity_generation": 1,
                "pairing_enabled": true,
                "capabilities": ["cmux.tui.v10"],
                "path_hints": [],
                "last_seen_at": "2026-08-03T00:00:00.000Z"
            }],
            "relay_fleet": ["https://usw1.relay.cmux.dev/"],
            "lan_rendezvous": {"generation": 1, "key": "k"},
            "grant_verification_keys": {"version": 1, "current_kid": "k1", "keys": []}
        });
        let discovery = parse_discovery(&value).unwrap();
        assert_eq!(discovery.revision, 7);
        assert_eq!(discovery.bindings.len(), 1);
        assert_eq!(discovery.bindings[0].platform, "linux");
        assert!(discovery.bindings[0].pairing_enabled);
    }
}
