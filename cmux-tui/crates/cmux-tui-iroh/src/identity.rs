//! Device identity, credential, and broker-cache persistence in the state root.
//!
//! Layout, all owner-only under `<state root>/device/`:
//! - `iroh-identity.json`: Ed25519 endpoint seed, deviceId, appInstanceId, tag.
//! - `iroh-credential.json`: Stack session pair from enrollment.
//! - `iroh-broker-cache.json`: grant verification keys + relay token cache.
//!
//! The identity file is the container's registration authority: reboots load
//! the same (deviceId, tag) and endpoint key, so the broker treats each
//! re-registration as a heartbeat on the same slot.

use std::path::{Path, PathBuf};

use anyhow::{Context, bail};
use serde::{Deserialize, Serialize};

use crate::files::{read_private, write_private_atomic};

pub const IDENTITY_FILE: &str = "iroh-identity.json";
pub const CREDENTIAL_FILE: &str = "iroh-credential.json";
pub const BROKER_CACHE_FILE: &str = "iroh-broker-cache.json";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Identity {
    pub version: u32,
    pub secret_key_hex: String,
    pub device_id: String,
    pub app_instance_id: String,
    pub tag: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub binding_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Credential {
    pub version: u32,
    pub access_token: String,
    pub refresh_token: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct BrokerCache {
    #[serde(default)]
    pub grant_verification_keys: Option<serde_json::Value>,
    #[serde(default)]
    pub relay_token: Option<String>,
    #[serde(default)]
    pub relay_token_expires_at: Option<i64>,
}

/// Resolves the cmux-tui workspace state root with the same precedence the
/// mux server uses (`platform::workspace_state_dir`): explicit override, then
/// `CMUX_TUI_STATE_DIR`, then the platform state directory.
pub fn state_root(explicit: Option<&Path>) -> anyhow::Result<PathBuf> {
    if let Some(path) = explicit {
        return Ok(path.to_path_buf());
    }
    if let Ok(env_root) = std::env::var("CMUX_TUI_STATE_DIR")
        && !env_root.is_empty()
    {
        return Ok(PathBuf::from(env_root));
    }
    let home = std::env::var("HOME").context("HOME is not set")?;
    #[cfg(target_os = "macos")]
    {
        Ok(PathBuf::from(home).join("Library/Application Support/cmux-tui/sessions"))
    }
    #[cfg(not(target_os = "macos"))]
    {
        let base = match std::env::var("XDG_STATE_HOME") {
            Ok(value) if !value.is_empty() => PathBuf::from(value),
            _ => PathBuf::from(home).join(".local/state"),
        };
        Ok(base.join("cmux-tui/sessions"))
    }
}

pub fn device_dir(state_root: &Path) -> PathBuf {
    state_root.join("device")
}

pub fn load_identity(state_root: &Path) -> anyhow::Result<Option<Identity>> {
    load_json(&device_dir(state_root).join(IDENTITY_FILE))
}

pub fn save_identity(state_root: &Path, identity: &Identity) -> anyhow::Result<()> {
    save_json(&device_dir(state_root).join(IDENTITY_FILE), identity)
}

pub fn load_credential(state_root: &Path) -> anyhow::Result<Option<Credential>> {
    load_json(&device_dir(state_root).join(CREDENTIAL_FILE))
}

pub fn save_credential(state_root: &Path, credential: &Credential) -> anyhow::Result<()> {
    save_json(&device_dir(state_root).join(CREDENTIAL_FILE), credential)
}

pub fn load_broker_cache(state_root: &Path) -> anyhow::Result<BrokerCache> {
    Ok(load_json(&device_dir(state_root).join(BROKER_CACHE_FILE))?.unwrap_or_default())
}

pub fn save_broker_cache(state_root: &Path, cache: &BrokerCache) -> anyhow::Result<()> {
    save_json(&device_dir(state_root).join(BROKER_CACHE_FILE), cache)
}

/// Loads the identity or mints one with a fresh endpoint key and device UUID.
pub fn load_or_mint_identity(state_root: &Path, tag: Option<&str>) -> anyhow::Result<Identity> {
    if let Some(existing) = load_identity(state_root)? {
        if let Some(requested) = tag
            && requested != existing.tag
        {
            bail!(
                "identity already registered with tag {:?}; refusing to change it to {:?} \
                     (a tag change would claim a different broker slot; revoke and re-enroll instead)",
                existing.tag,
                requested
            );
        }
        return Ok(existing);
    }
    let tag = tag.context("no identity exists yet; --tag is required on first enrollment")?;
    validate_tag(tag)?;
    let secret = iroh::SecretKey::generate();
    let secret_key_hex: String =
        secret.to_bytes().iter().map(|byte| format!("{byte:02x}")).collect();
    let identity = Identity {
        version: 1,
        secret_key_hex,
        device_id: random_uuid()?,
        app_instance_id: random_uuid()?,
        tag: tag.to_string(),
        binding_id: None,
    };
    save_identity(state_root, &identity)?;
    Ok(identity)
}

impl Identity {
    pub fn secret_key(&self) -> anyhow::Result<iroh::SecretKey> {
        let bytes = decode_hex_32(&self.secret_key_hex).context("identity secret key")?;
        Ok(iroh::SecretKey::from_bytes(&bytes))
    }

    pub fn signing_key(&self) -> anyhow::Result<ed25519_dalek::SigningKey> {
        let bytes = decode_hex_32(&self.secret_key_hex).context("identity secret key")?;
        Ok(ed25519_dalek::SigningKey::from_bytes(&bytes))
    }

    /// The canonical lowercase-hex EndpointID (the raw Ed25519 public key).
    pub fn endpoint_id_hex(&self) -> anyhow::Result<String> {
        let verifying = self.signing_key()?.verifying_key();
        Ok(verifying.as_bytes().iter().map(|byte| format!("{byte:02x}")).collect())
    }
}

pub fn validate_tag(tag: &str) -> anyhow::Result<()> {
    let valid = !tag.is_empty()
        && tag.len() <= 64
        && tag
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'));
    if !valid {
        bail!("tag must be 1-64 characters of [A-Za-z0-9._-]");
    }
    Ok(())
}

pub fn decode_hex_32(hex: &str) -> anyhow::Result<[u8; 32]> {
    let trimmed = hex.trim();
    if trimmed.len() != 64 {
        bail!("expected 64 hex characters");
    }
    let mut bytes = [0u8; 32];
    for (index, chunk) in trimmed.as_bytes().chunks(2).enumerate() {
        let text = std::str::from_utf8(chunk)?;
        bytes[index] = u8::from_str_radix(text, 16).context("invalid hex")?;
    }
    Ok(bytes)
}

pub fn random_uuid() -> anyhow::Result<String> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).map_err(|error| anyhow::anyhow!("getrandom failed: {error}"))?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    Ok(format!("{}-{}-{}-{}-{}", &hex[0..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..32]))
}

fn load_json<T: serde::de::DeserializeOwned>(path: &Path) -> anyhow::Result<Option<T>> {
    match read_private(path)? {
        Some(contents) => {
            let value = serde_json::from_slice(&contents)
                .with_context(|| format!("parsing {}", path.display()))?;
            Ok(Some(value))
        }
        None => Ok(None),
    }
}

fn save_json<T: Serialize>(path: &Path, value: &T) -> anyhow::Result<()> {
    let mut contents = serde_json::to_vec_pretty(value)?;
    contents.push(b'\n');
    write_private_atomic(path, &contents)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mints_identity_once_and_reloads_it() {
        let dir = tempfile::tempdir().unwrap();
        let minted = load_or_mint_identity(dir.path(), Some("boxa")).unwrap();
        let reloaded = load_or_mint_identity(dir.path(), None).unwrap();
        assert_eq!(minted.secret_key_hex, reloaded.secret_key_hex);
        assert_eq!(minted.device_id, reloaded.device_id);
        assert_eq!(reloaded.tag, "boxa");
        assert_eq!(minted.endpoint_id_hex().unwrap().len(), 64);
    }

    #[test]
    fn refuses_tag_change_on_existing_identity() {
        let dir = tempfile::tempdir().unwrap();
        load_or_mint_identity(dir.path(), Some("boxa")).unwrap();
        let error = load_or_mint_identity(dir.path(), Some("boxb")).unwrap_err();
        assert!(error.to_string().contains("refusing to change"));
    }

    #[test]
    fn endpoint_id_matches_iroh_public_key() {
        let dir = tempfile::tempdir().unwrap();
        let identity = load_or_mint_identity(dir.path(), Some("boxa")).unwrap();
        let iroh_public = identity.secret_key().unwrap().public();
        assert_eq!(identity.endpoint_id_hex().unwrap(), iroh_public.to_string());
    }

    #[test]
    fn uuids_are_v4_shaped() {
        let uuid = random_uuid().unwrap();
        assert_eq!(uuid.len(), 36);
        assert_eq!(&uuid[14..15], "4");
    }
}
