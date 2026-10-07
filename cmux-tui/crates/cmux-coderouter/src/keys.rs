//! Client API keys.
//!
//! A key is `crl_<key id: 16 hex>_<secret: 64 hex>`. The ring keeps only
//! HMAC-SHA256(install secret, key id || secret) per key id, never the
//! secret, so a dump of the ring cannot be replayed. The install secret is
//! the one per-install value (the Keychain holds it; see
//! plans/cmux-next/local-coderouter.md). Each key carries a scope: the
//! harness it was minted for, the API families it may call, an optional
//! session and an optional expiry. Rotation is revoke plus mint.

use crate::secret::Secret;
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use std::{collections::BTreeMap, collections::BTreeSet, fmt};
use zeroize::Zeroize;

type HmacSha256 = Hmac<Sha256>;

/// The prefix of every local CodeRouter key.
pub const KEY_PREFIX: &str = "crl_";
const ID_BYTES: usize = 8;
const SECRET_BYTES: usize = 32;

/// The wire API a request uses.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApiFamily {
    /// Anthropic Messages (`/v1/messages`, `/v1/messages/count_tokens`).
    AnthropicMessages,
    /// OpenAI Responses (`/v1/responses`).
    OpenAiResponses,
}

impl ApiFamily {
    /// The family of a request path, or `None` for a path the router does
    /// not serve.
    pub fn for_path(path: &str) -> Option<Self> {
        match path {
            "/v1/messages" | "/v1/messages/count_tokens" => Some(Self::AnthropicMessages),
            "/v1/responses" => Some(Self::OpenAiResponses),
            _ => None,
        }
    }
}

/// What one key may do.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct KeyScope {
    /// The harness profile id the key was minted for (`claude`, `codex`, ...).
    pub harness: String,
    /// The acpmux session the key belongs to, when it is per session.
    pub session: Option<String>,
    /// The API families the key may call.
    pub families: BTreeSet<ApiFamily>,
    /// Unix seconds after which the key is refused.
    pub expires_at: Option<u64>,
}

/// The public id of a key (the part before the secret).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct KeyId([u8; ID_BYTES]);

impl fmt::Display for KeyId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&hex(&self.0))
    }
}

/// Why a presented key was refused. The presented value never appears in
/// the error.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyError {
    /// Not of the `crl_<id>_<secret>` form.
    Malformed,
    /// No live key has this id (never minted, or revoked).
    Unknown,
    /// The id is known and the secret does not match.
    Mismatch,
    /// The key is past its expiry.
    Expired,
}

struct Record {
    digest: [u8; 32],
    scope: KeyScope,
}

/// The live keys of one install.
pub struct KeyRing {
    install_secret: Secret<[u8; 32]>,
    keys: BTreeMap<KeyId, Record>,
}

impl fmt::Debug for KeyRing {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_struct("KeyRing").field("keys", &self.keys.len()).finish_non_exhaustive()
    }
}

impl KeyRing {
    /// A ring for `install_secret`. An all-zero secret is refused, so a
    /// default-initialized value cannot run the router.
    pub fn new(install_secret: Secret<[u8; 32]>) -> Result<Self, &'static str> {
        if install_secret.expose().iter().all(|byte| *byte == 0) {
            return Err("install secret is all zero");
        }
        Ok(Self { install_secret, keys: BTreeMap::new() })
    }

    /// A ring with a fresh random install secret (tests, and a router run
    /// without a Keychain store).
    pub fn generate() -> Result<Self, getrandom::Error> {
        let mut secret = [0u8; 32];
        getrandom::fill(&mut secret)?;
        let secret = Secret::new(secret);
        Self::new(secret).map_err(|_| getrandom::Error::UNSUPPORTED)
    }

    /// Mint a key for `scope`. The clear key is returned once.
    pub fn mint(&mut self, scope: KeyScope) -> Result<(KeyId, Secret<String>), getrandom::Error> {
        let mut id = [0u8; ID_BYTES];
        getrandom::fill(&mut id)?;
        let id = KeyId(id);
        let mut raw = [0u8; SECRET_BYTES];
        getrandom::fill(&mut raw)?;
        let secret = Secret::new(raw);
        raw.zeroize();
        let digest = self.digest(id, secret.expose()).ok_or(getrandom::Error::UNSUPPORTED)?;
        self.keys.insert(id, Record { digest, scope });
        let clear = Secret::new(format!("{KEY_PREFIX}{id}_{}", hex(secret.expose())));
        Ok((id, clear))
    }

    /// Revoke a key. Returns whether it was live.
    pub fn revoke(&mut self, id: KeyId) -> bool {
        self.keys.remove(&id).is_some()
    }

    /// Revoke `id` and mint a new key with the same scope.
    pub fn rotate(
        &mut self,
        id: KeyId,
    ) -> Option<Result<(KeyId, Secret<String>), getrandom::Error>> {
        let record = self.keys.remove(&id)?;
        Some(self.mint(record.scope))
    }

    /// The live key ids and scopes (no secrets).
    pub fn list(&self) -> Vec<(KeyId, KeyScope)> {
        self.keys.iter().map(|(id, record)| (*id, record.scope.clone())).collect()
    }

    /// Check a presented key at `now` (unix seconds).
    pub fn validate(&self, presented: &str, now: u64) -> Result<(KeyId, &KeyScope), KeyError> {
        let (id, secret) = parse(presented).ok_or(KeyError::Malformed)?;
        let record = self.keys.get(&id).ok_or(KeyError::Unknown)?;
        let mut mac = self.mac(id).ok_or(KeyError::Mismatch)?;
        mac.update(secret.expose());
        mac.verify_slice(&record.digest).map_err(|_| KeyError::Mismatch)?;
        if record.scope.expires_at.is_some_and(|expiry| now >= expiry) {
            return Err(KeyError::Expired);
        }
        Ok((id, &record.scope))
    }

    fn mac(&self, id: KeyId) -> Option<HmacSha256> {
        // HMAC accepts a key of any length; `None` is unreachable in practice.
        let mut mac = <HmacSha256 as Mac>::new_from_slice(self.install_secret.expose()).ok()?;
        mac.update(&id.0);
        Some(mac)
    }

    fn digest(&self, id: KeyId, secret: &[u8]) -> Option<[u8; 32]> {
        let mut mac = self.mac(id)?;
        mac.update(secret);
        Some(mac.finalize().into_bytes().into())
    }
}

fn parse(presented: &str) -> Option<(KeyId, Secret<[u8; SECRET_BYTES]>)> {
    let rest = presented.strip_prefix(KEY_PREFIX)?;
    let (id_hex, secret_hex) = rest.split_once('_')?;
    let mut id = [0u8; ID_BYTES];
    unhex(id_hex, &mut id)?;
    let mut raw = [0u8; SECRET_BYTES];
    let parsed = unhex(secret_hex, &mut raw);
    let secret = Secret::new(raw);
    raw.zeroize();
    parsed?;
    Some((KeyId(id), secret))
}

fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(char::from(DIGITS[usize::from(byte >> 4)]));
        out.push(char::from(DIGITS[usize::from(byte & 0x0f)]));
    }
    out
}

fn unhex(text: &str, out: &mut [u8]) -> Option<()> {
    let text = text.as_bytes();
    if text.len() != out.len() * 2 {
        return None;
    }
    for (slot, pair) in out.iter_mut().zip(text.chunks_exact(2)) {
        *slot = (nibble(pair[0])? << 4) | nibble(pair[1])?;
    }
    Some(())
}

fn nibble(digit: u8) -> Option<u8> {
    match digit {
        b'0'..=b'9' => Some(digit - b'0'),
        b'a'..=b'f' => Some(digit - b'a' + 10),
        _ => None,
    }
}
