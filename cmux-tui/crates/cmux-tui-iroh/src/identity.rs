use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail, ensure};
use cmux_remote::identity::{read_owner_only_json, write_owner_only_json};
use cmux_remote::owner_lock::OwnerFileLock;
use cmux_remote::provider::load_or_create_iroh_secret;
use cmux_remote::secure_directory::{DirectoryAccess, ensure_secure_directory};
use iroh::{EndpointId, SecretKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};
use uuid::Uuid;
use zeroize::{Zeroize, ZeroizeOnDrop};

const IDENTITY_SCHEMA_VERSION: u32 = 1;
const CREDENTIAL_SCHEMA_VERSION: u32 = 1;
const MAX_IDENTITY_BYTES: usize = 8 * 1024;
const MAX_CREDENTIAL_BYTES: usize = 32 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct EndpointMetadata {
    pub version: u32,
    #[serde(deserialize_with = "crate::broker::deserialize_canonical_uuid")]
    pub device_id: Uuid,
    #[serde(deserialize_with = "crate::broker::deserialize_canonical_uuid")]
    pub app_instance_id: Uuid,
    pub tag: String,
    pub identity_generation: u32,
}

impl EndpointMetadata {
    fn generate() -> Self {
        Self {
            version: IDENTITY_SCHEMA_VERSION,
            device_id: Uuid::new_v4(),
            app_instance_id: Uuid::new_v4(),
            tag: format!("tui-{}", Uuid::new_v4()),
            identity_generation: 1,
        }
    }

    fn validate(&self) -> Result<()> {
        ensure!(self.version == IDENTITY_SCHEMA_VERSION, "unsupported identity schema");
        ensure!(self.identity_generation > 0, "identity generation must be positive");
        ensure!(safe_token(&self.tag), "identity tag is invalid");
        Ok(())
    }
}

#[derive(Clone, Serialize, Deserialize, Zeroize, ZeroizeOnDrop)]
#[serde(deny_unknown_fields)]
pub struct BrokerCredential {
    version: u32,
    #[zeroize(skip)]
    pub enrolled_at_unix: u64,
    pub access_token: String,
    pub refresh_token: String,
}

impl std::fmt::Debug for BrokerCredential {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("BrokerCredential")
            .field("version", &self.version)
            .field("enrolled_at_unix", &self.enrolled_at_unix)
            .field("access_token", &"[REDACTED]")
            .field("refresh_token", &"[REDACTED]")
            .finish()
    }
}

impl BrokerCredential {
    pub fn new(access_token: String, refresh_token: String, enrolled_at_unix: u64) -> Result<Self> {
        validate_credential_value(&access_token)?;
        validate_credential_value(&refresh_token)?;
        Ok(Self {
            version: CREDENTIAL_SCHEMA_VERSION,
            enrolled_at_unix,
            access_token,
            refresh_token,
        })
    }

    fn validate(&self) -> Result<()> {
        ensure!(self.version == CREDENTIAL_SCHEMA_VERSION, "unsupported credential schema");
        validate_credential_value(&self.access_token)?;
        validate_credential_value(&self.refresh_token)
    }
}

pub struct IdentityStore {
    directory: PathBuf,
    secret_key: SecretKey,
    metadata: EndpointMetadata,
    _lock: OwnerFileLock,
}

impl std::fmt::Debug for IdentityStore {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("IdentityStore")
            .field("directory", &self.directory)
            .field("endpoint", &self.endpoint_id().fmt_short().to_string())
            .field("device_id", &self.metadata.device_id)
            .field("tag", &self.metadata.tag)
            .finish_non_exhaustive()
    }
}

impl IdentityStore {
    pub fn open(state_root: &Path, identity_name: &str) -> Result<Self> {
        ensure!(safe_identity_name(identity_name), "identity name is invalid");
        let directory = state_root.join("iroh-tui").join(identity_name);
        ensure_secure_directory(&directory, DirectoryAccess::ManagedOwnerOnly).with_context(
            || format!("cannot secure iroh state directory {}", directory.display()),
        )?;
        let lock = OwnerFileLock::try_acquire(&directory.join("state.lock"))
            .with_context(|| format!("iroh identity {identity_name:?} is already in use"))?;
        let secret_key = load_or_create_iroh_secret(&directory.join("endpoint.key"))
            .map_err(|error| anyhow::anyhow!(error.to_string()))?;
        let identity_path = directory.join("identity.json");
        let metadata = if identity_path.exists() {
            read_owner_only_json::<EndpointMetadata>(&identity_path, MAX_IDENTITY_BYTES)
                .with_context(|| format!("cannot load {}", identity_path.display()))?
        } else {
            let metadata = EndpointMetadata::generate();
            write_owner_only_json(&identity_path, &metadata)
                .with_context(|| format!("cannot persist {}", identity_path.display()))?;
            metadata
        };
        metadata.validate()?;
        Ok(Self { directory, secret_key, metadata, _lock: lock })
    }

    pub fn directory(&self) -> &Path {
        &self.directory
    }

    pub fn secret_key(&self) -> &SecretKey {
        &self.secret_key
    }

    pub fn endpoint_id(&self) -> EndpointId {
        self.secret_key.public()
    }

    pub fn metadata(&self) -> &EndpointMetadata {
        &self.metadata
    }

    pub fn identity_fingerprint(&self) -> String {
        let mut digest = Sha256::new();
        digest.update(self.endpoint_id().as_bytes());
        digest.update(self.metadata.device_id.as_bytes());
        digest.update(self.metadata.app_instance_id.as_bytes());
        digest.update(self.metadata.tag.as_bytes());
        digest.update(self.metadata.identity_generation.to_be_bytes());
        let digest = digest.finalize();
        let mut value = String::with_capacity(16);
        for byte in &digest[..8] {
            use std::fmt::Write as _;
            write!(&mut value, "{byte:02x}").expect("writing to String cannot fail");
        }
        value
    }

    pub fn load_credential(&self) -> Result<BrokerCredential> {
        let path = self.directory.join("credential.json");
        let credential = read_owner_only_json::<BrokerCredential>(&path, MAX_CREDENTIAL_BYTES)
            .with_context(|| format!("cannot load broker credential {}", path.display()))?;
        credential.validate()?;
        Ok(credential)
    }

    pub fn credential_exists(&self) -> bool {
        self.directory.join("credential.json").exists()
    }

    pub fn save_credential(&self, credential: &BrokerCredential, replace: bool) -> Result<()> {
        credential.validate()?;
        let path = self.directory.join("credential.json");
        if path.exists() && !replace {
            bail!("broker credential already exists; pass --replace-credential to replace it");
        }
        write_owner_only_json(&path, credential)
            .with_context(|| format!("cannot persist broker credential {}", path.display()))
    }
}

fn safe_identity_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

fn safe_token(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b':' | b'_'))
}

fn validate_credential_value(value: &str) -> Result<()> {
    ensure!(!value.is_empty(), "broker credential is empty");
    ensure!(value.len() <= 16 * 1024, "broker credential is too large");
    ensure!(
        !value.bytes().any(|byte| byte.is_ascii_control()),
        "broker credential contains a control byte"
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt as _;

    use super::*;

    #[test]
    fn first_boot_identity_is_stable() {
        let temp = tempfile::tempdir().unwrap();
        let (endpoint, metadata) = {
            let first = IdentityStore::open(temp.path(), "server").unwrap();
            (first.endpoint_id(), first.metadata().clone())
        };
        let second = IdentityStore::open(temp.path(), "server").unwrap();
        assert_eq!(second.endpoint_id(), endpoint);
        assert_eq!(second.metadata(), &metadata);
        assert_eq!(second.identity_fingerprint().len(), 16);
        assert_eq!(
            std::fs::metadata(second.directory()).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(
            std::fs::metadata(second.directory().join("endpoint.key"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }

    #[test]
    fn identity_lock_prevents_key_sharing_between_process_owners() {
        let temp = tempfile::tempdir().unwrap();
        let _first = IdentityStore::open(temp.path(), "server").unwrap();
        let error = IdentityStore::open(temp.path(), "server").unwrap_err();
        assert!(error.to_string().contains("already in use"));
    }

    #[test]
    fn credential_debug_is_redacted_and_replace_is_explicit() {
        let temp = tempfile::tempdir().unwrap();
        let store = IdentityStore::open(temp.path(), "provider").unwrap();
        let credential =
            BrokerCredential::new("access-secret".into(), "refresh-secret".into(), 1).unwrap();
        let debug = format!("{credential:?}");
        assert!(!debug.contains("access-secret"));
        assert!(!debug.contains("refresh-secret"));
        store.save_credential(&credential, false).unwrap();
        assert!(store.save_credential(&credential, false).is_err());
        let loaded = store.load_credential().unwrap();
        assert_eq!(loaded.access_token, "access-secret");
    }
}
