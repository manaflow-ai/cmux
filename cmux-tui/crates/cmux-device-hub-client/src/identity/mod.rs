//! Device identity (PROTOCOL.md, "Identity"): a P-256 signing key and a P-256
//! agreement key, a lowercase UUID device id persisted with them, the platform
//! and where the keys live (`assurance`).

mod file;
mod software;

#[cfg(target_os = "linux")]
mod secret_service;

#[cfg(windows)]
mod cng;

use std::fmt;
use std::sync::Arc;

use base64::Engine as _;
use serde::{Deserialize, Serialize};

pub use file::FileKeyStore;
pub use software::{SoftwareKeys, StoredSoftwareIdentity};

#[cfg(target_os = "linux")]
pub use secret_service::{LinuxKeyStore, SecretServiceKeyStore};

#[cfg(windows)]
pub use cng::CngKeyStore;

/// The device's platform, as the hub names it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Platform {
    Macos,
    Ios,
    Windows,
    Linux,
    /// A platform this build does not know. Never an approver.
    #[serde(other)]
    Unknown,
}

impl Platform {
    /// The platform cmux-tui registers as on this machine: `windows` on
    /// Windows, `linux` everywhere else (macOS runs the Swift client; this
    /// crate builds there only for its tests).
    pub fn host() -> Platform {
        if cfg!(windows) { Platform::Windows } else { Platform::Linux }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Platform::Macos => "macos",
            Platform::Ios => "ios",
            Platform::Windows => "windows",
            Platform::Linux => "linux",
            Platform::Unknown => "unknown",
        }
    }

    /// Whether a device of this platform may answer Computer Use approvals:
    /// only `macos` and `ios` have a protected collector.
    pub fn is_approver(self) -> bool {
        matches!(self, Platform::Macos | Platform::Ios)
    }
}

/// Where a device's keys live, highest first.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Assurance {
    /// Secure Enclave, a TPM-backed CNG key.
    Hardware,
    /// The Linux Secret Service, a Windows software CNG key.
    Keystore,
    /// A 0600 key file on a headless box.
    File,
    #[serde(other)]
    Unknown,
}

impl Assurance {
    pub fn as_str(self) -> &'static str {
        match self {
            Assurance::Hardware => "hardware",
            Assurance::Keystore => "keystore",
            Assurance::File => "file",
            Assurance::Unknown => "unknown",
        }
    }
}

/// A key store failure.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IdentityError {
    /// The store cannot be used on this machine (no D-Bus session, no TPM and
    /// no software provider): the caller may choose another store.
    Unavailable(String),
    /// The key file is readable by other users; it is not loaded.
    InsecureKeyFile {
        path: String,
        mode: u32,
    },
    /// The stored identity is malformed.
    Corrupt(String),
    Io(String),
    Crypto(String),
}

impl fmt::Display for IdentityError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            IdentityError::Unavailable(detail) => write!(f, "key store unavailable: {detail}"),
            IdentityError::InsecureKeyFile { path, mode } => {
                write!(
                    f,
                    "refusing key file {path}: mode {mode:o} is readable by others (want 0600)"
                )
            }
            IdentityError::Corrupt(detail) => {
                write!(f, "stored device identity is malformed: {detail}")
            }
            IdentityError::Io(detail) => write!(f, "key store I/O: {detail}"),
            IdentityError::Crypto(detail) => write!(f, "device key: {detail}"),
        }
    }
}

impl std::error::Error for IdentityError {}

/// A device's two private keys, wherever they live.
pub trait DeviceKeys: Send + Sync {
    /// The signing public key, X9.63 uncompressed (65 bytes).
    fn signing_public_key(&self) -> [u8; 65];
    /// The agreement public key, X9.63 uncompressed (65 bytes).
    fn agreement_public_key(&self) -> [u8; 65];
    /// ECDSA-P256-SHA256 over `message`, raw r||s. High-S is allowed.
    fn sign(&self, message: &[u8]) -> Result<[u8; 64], IdentityError>;
    fn assurance(&self) -> Assurance;
}

/// Loads this device's identity, creating it the first time.
pub trait KeyStore: Send + Sync {
    fn load_or_create(&self) -> Result<DeviceIdentity, IdentityError>;
    /// Forgets the identity and its keys. The next `load_or_create` makes a
    /// new device id (the hub never re-registers a removed id).
    fn reset(&self) -> Result<(), IdentityError>;
}

/// A registered or registrable device: its id, platform and keys.
#[derive(Clone)]
pub struct DeviceIdentity {
    id: String,
    platform: Platform,
    keys: Arc<dyn DeviceKeys>,
}

impl fmt::Debug for DeviceIdentity {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("DeviceIdentity")
            .field("id", &self.id)
            .field("platform", &self.platform)
            .field("assurance", &self.keys.assurance())
            .finish_non_exhaustive()
    }
}

impl DeviceIdentity {
    /// `id` is lowercased (the hub's `X-Device-Id` is lowercase).
    pub fn new(
        id: impl Into<String>,
        platform: Platform,
        keys: Arc<dyn DeviceKeys>,
    ) -> DeviceIdentity {
        DeviceIdentity { id: id.into().to_ascii_lowercase(), platform, keys }
    }

    pub fn id(&self) -> &str {
        &self.id
    }

    pub fn platform(&self) -> Platform {
        self.platform
    }

    pub fn assurance(&self) -> Assurance {
        self.keys.assurance()
    }

    pub fn keys(&self) -> &Arc<dyn DeviceKeys> {
        &self.keys
    }

    /// The signing key as base64 of its X9.63 point.
    pub fn signing_key_base64(&self) -> String {
        base64::engine::general_purpose::STANDARD.encode(self.keys.signing_public_key())
    }

    /// The agreement key as base64 of its X9.63 point.
    pub fn agreement_key_base64(&self) -> String {
        base64::engine::general_purpose::STANDARD.encode(self.keys.agreement_public_key())
    }

    /// Signs `message` and returns base64 raw r||s.
    pub fn sign_base64(&self, message: &[u8]) -> Result<String, IdentityError> {
        Ok(base64::engine::general_purpose::STANDARD.encode(self.keys.sign(message)?))
    }
}

/// A new lowercase UUID device id.
pub fn new_device_id() -> String {
    uuid::Uuid::new_v4().hyphenated().to_string()
}

/// Whether `id` is a lowercase hyphenated UUID.
pub(crate) fn is_device_id(id: &str) -> bool {
    uuid::Uuid::parse_str(id).is_ok_and(|parsed| parsed.hyphenated().to_string() == id)
}
