//! Local launch credentials (plans/cmux-next/identity.md section 2).
//!
//! `cmuxlc1.<kid>.<claims>.<mac>`, where `claims` is base64url JSON and
//! `mac` = base64url(HMAC-SHA256(key[kid], "cmuxlc1.<kid>.<claims>")).
//! Pure: the session host owns the keys and the liveness check. Uses only
//! HMAC-SHA256 from RustCrypto, no platform crypto.

use std::collections::BTreeMap;

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;

const PREFIX: &str = "cmuxlc1";
/// Upper bound on a credential string; longer input is malformed.
pub const MAX_CREDENTIAL_BYTES: usize = 2048;
const KEY_BYTES: usize = 32;

/// What a launch credential says. Exactly one of `terminal` and
/// `acp_session` is set.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Claims {
    pub v: u8,
    pub host: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub terminal: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub acp_session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    pub iat: u64,
}

impl Claims {
    fn valid_shape(&self) -> bool {
        self.v == 1
            && !self.host.is_empty()
            && (self.terminal.is_some() != self.acp_session.is_some())
            && self.terminal.as_deref().is_none_or(|id| !id.is_empty())
            && self.acp_session.as_deref().is_none_or(|id| !id.is_empty())
            && self.agent.as_deref().is_none_or(|id| !id.is_empty())
    }
}

/// Why a credential did not verify.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VerifyError {
    /// Not a cmuxlc1 credential, or its claims do not parse.
    Malformed,
    /// Its key id is not known (dropped by rotation). Not an attack: the
    /// caller falls back as if no credential was sent.
    UnknownKey,
    /// The MAC does not match: tampered or forged.
    BadMac,
}

/// The launch keys: a current key id and the keys that still verify.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LaunchKeys {
    pub current: String,
    /// kid -> base64url key bytes.
    pub keys: BTreeMap<String, String>,
}

impl std::fmt::Debug for LaunchKeys {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("LaunchKeys")
            .field("current", &self.current)
            .field("kids", &self.keys.keys().collect::<Vec<_>>())
            .finish()
    }
}

impl LaunchKeys {
    /// Keys with one current key made from `random` (32 bytes) under `kid`.
    pub fn new(kid: &str, random: [u8; KEY_BYTES]) -> Self {
        let mut keys = BTreeMap::new();
        keys.insert(kid.to_owned(), URL_SAFE_NO_PAD.encode(random));
        Self { current: kid.to_owned(), keys }
    }

    /// Make `kid` current and keep only the previous current key besides it.
    pub fn rotate(&mut self, kid: &str, random: [u8; KEY_BYTES]) {
        let previous = self.current.clone();
        self.keys.retain(|existing, _| *existing == previous);
        self.keys.insert(kid.to_owned(), URL_SAFE_NO_PAD.encode(random));
        self.current = kid.to_owned();
    }

    /// Whether every key decodes to 32 bytes and the current key exists.
    pub fn is_valid(&self) -> bool {
        valid_kid(&self.current)
            && self.keys.contains_key(&self.current)
            && self.keys.iter().all(|(kid, _)| valid_kid(kid))
            && self.keys.values().all(|key| self.decode(key).is_some())
    }

    fn decode(&self, key: &str) -> Option<[u8; KEY_BYTES]> {
        URL_SAFE_NO_PAD.decode(key).ok()?.try_into().ok()
    }

    fn key(&self, kid: &str) -> Option<[u8; KEY_BYTES]> {
        self.keys.get(kid).and_then(|key| self.decode(key))
    }

    /// Mint a credential with the current key. None when the claims have
    /// the wrong shape or the current key is missing or malformed.
    pub fn mint(&self, claims: &Claims) -> Option<String> {
        if !claims.valid_shape() {
            return None;
        }
        let key = self.key(&self.current)?;
        let body = URL_SAFE_NO_PAD.encode(serde_json::to_vec(claims).ok()?);
        let signed = format!("{PREFIX}.{}.{body}", self.current);
        let mac = URL_SAFE_NO_PAD.encode(mac(&key, signed.as_bytes()).finalize().into_bytes());
        Some(format!("{signed}.{mac}"))
    }

    /// Verify the MAC and decode the claims. Liveness (the terminal or ACP
    /// session still exists, `host` is this session) is the caller's check.
    pub fn verify(&self, credential: &str) -> Result<Claims, VerifyError> {
        if credential.len() > MAX_CREDENTIAL_BYTES {
            return Err(VerifyError::Malformed);
        }
        let mut parts = credential.split('.');
        let (Some(prefix), Some(kid), Some(body), Some(tag), None) =
            (parts.next(), parts.next(), parts.next(), parts.next(), parts.next())
        else {
            return Err(VerifyError::Malformed);
        };
        if prefix != PREFIX || !valid_kid(kid) {
            return Err(VerifyError::Malformed);
        }
        let tag = URL_SAFE_NO_PAD.decode(tag).map_err(|_| VerifyError::Malformed)?;
        let Some(key) = self.key(kid) else { return Err(VerifyError::UnknownKey) };
        let signed_len = PREFIX.len() + 1 + kid.len() + 1 + body.len();
        mac(&key, &credential.as_bytes()[..signed_len])
            .verify_slice(&tag)
            .map_err(|_| VerifyError::BadMac)?;
        let json = URL_SAFE_NO_PAD.decode(body).map_err(|_| VerifyError::Malformed)?;
        let claims: Claims = serde_json::from_slice(&json).map_err(|_| VerifyError::Malformed)?;
        if !claims.valid_shape() {
            return Err(VerifyError::Malformed);
        }
        Ok(claims)
    }
}

fn mac(key: &[u8; KEY_BYTES], data: &[u8]) -> Hmac<Sha256> {
    let mut mac = Hmac::<Sha256>::new_from_slice(key).expect("HMAC takes any key length");
    mac.update(data);
    mac
}

fn valid_kid(kid: &str) -> bool {
    !kid.is_empty()
        && kid.len() <= 32
        && kid.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
}

#[cfg(test)]
#[path = "launch_credential_tests.rs"]
mod tests;
