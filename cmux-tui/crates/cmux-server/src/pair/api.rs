//! `POST /v1/pair/begin` (server.md 6.2 step 1): proof of possession of the
//! install key, no account. The reply carries the code and the collect
//! secret for `/v1/pair/wait`; the secret is never printed or logged.

use std::time::Duration;

use cmux_server_core::pairing::PairingCode;
use serde::{Deserialize, Serialize};

use super::ApiTarget;
use super::identity::{InstallIdentity, PublicJwk, begin_proof_message};
use crate::error::{Error, Result};

/// The facts the approver sees (backend `PairingInfo`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct HostInfo {
    pub name: String,
    /// `macos`, `linux` or `windows`.
    pub platform: String,
    pub os_version: String,
    /// `x86_64` or `aarch64`.
    pub arch: String,
    pub cmux_version: String,
}

#[derive(Serialize)]
struct BeginBody<'a> {
    public_jwk: PublicJwk,
    wg_public_key: String,
    info: &'a HostInfo,
    issued_at: u64,
    signature: String,
}

#[derive(Deserialize)]
struct BeginReply {
    code: String,
    expires_at: u64,
    collect_secret: String,
    thumbprint: String,
    #[serde(default)]
    verification_uri: Option<String>,
}

/// A started pairing.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Begun {
    pub code: PairingCode,
    pub expires_at: u64,
    pub collect_secret: String,
    pub verification_uri: Option<String>,
}

/// The collect secret goes into a header: `<nonce>.<hex mac>`, nothing else.
pub fn valid_collect_secret(secret: &str) -> bool {
    !secret.is_empty()
        && secret.len() <= 256
        && secret.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}

/// Sends the begin request and checks the reply against this key.
pub fn begin(
    api: &ApiTarget,
    identity: &InstallIdentity,
    info: &HostInfo,
    now_ms: u64,
) -> Result<Begun> {
    let thumbprint = identity.thumbprint_b64u();
    let wg_public_key = identity.wg_public_key();
    let proof = begin_proof_message(&api.environment, &thumbprint, &wg_public_key, now_ms);
    let body = BeginBody {
        public_jwk: identity.public_jwk(),
        signature: identity.sign_b64u(proof.as_bytes())?,
        wg_public_key,
        info,
        issued_at: now_ms,
    };
    let url = api.url("/v1/pair/begin")?;
    let _ = rustls::crypto::ring::default_provider().install_default();
    let client = reqwest::blocking::Client::builder()
        .https_only(!api.allow_http)
        .connect_timeout(Duration::from_secs(20))
        .timeout(Duration::from_secs(60))
        .redirect(reqwest::redirect::Policy::none())
        .user_agent(concat!("cmux-server/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|e| Error::internal(format!("HTTP client: {e}")))?;
    let response = client
        .post(&url)
        .json(&body)
        .send()
        .map_err(|e| Error::unreachable(format!("pair begin {url}: {}", e.without_url())))?;
    let status = response.status().as_u16();
    let text = response.text().unwrap_or_default();
    match status {
        200 => {}
        403 => return Err(Error::verification("the API refused the install key proof")),
        429 => return Err(Error::unreachable("pairing is rate limited; try again in a minute")),
        400..=499 => {
            return Err(Error::rejected(format!(
                "pair begin refused ({status}): {}",
                api_error(&text)
            )));
        }
        _ => return Err(Error::unreachable(format!("pair begin failed ({status})"))),
    }
    let reply: BeginReply = serde_json::from_str(&text)
        .map_err(|e| Error::internal(format!("pair begin: unexpected reply: {e}")))?;
    if reply.thumbprint != thumbprint {
        return Err(Error::verification("the API paired a different install key; refusing"));
    }
    let code = PairingCode::normalize(&reply.code)
        .map_err(|_| Error::internal("pair begin: the reply has no valid code"))?;
    if !valid_collect_secret(&reply.collect_secret) {
        return Err(Error::internal("pair begin: the reply has no valid collect secret"));
    }
    Ok(Begun {
        code,
        expires_at: reply.expires_at,
        collect_secret: reply.collect_secret,
        verification_uri: reply.verification_uri,
    })
}

/// The `error` member of an API error body, bounded, else a fixed text.
fn api_error(body: &str) -> String {
    serde_json::from_str::<serde_json::Value>(body)
        .ok()
        .and_then(|v| v.get("error").and_then(|e| e.as_str()).map(str::to_owned))
        .map(|e| e.chars().filter(|c| !c.is_control()).take(200).collect())
        .unwrap_or_else(|| "no detail".to_owned())
}
