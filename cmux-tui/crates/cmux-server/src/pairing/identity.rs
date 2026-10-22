//! One private, locked enrollment record. Public status never serializes it.

use std::fs::{OpenOptions, TryLockError};
use std::io::Read;
use std::path::{Path, PathBuf};

use base64::Engine as _;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use cmux_server_core::install_key::{InstallKey, SystemRandom};
use cmux_server_core::pairing::enrollment::Paired;
use cmux_server_core::pairing::native::{Grant, Registration};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use zeroize::{Zeroize, Zeroizing};

use crate::error::{Error, Result};
use crate::fsx;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Identity {
    pub schema: u32,
    pub api: String,
    pub public_jwk: Value,
    protected_keys: String,
    protection: String,
    pub paired: Option<Paired>,
    pub attempt: Option<Attempt>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub native: Option<NativeState>,
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case", deny_unknown_fields)]
pub(super) enum NativeState {
    Pending { response: String, received_at: u64 },
    Registered { registration: Registration },
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Keys {
    pkcs8: String,
    wg: String,
}

impl Drop for Keys {
    fn drop(&mut self) {
        self.pkcs8.zeroize();
        self.wg.zeroize();
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Attempt {
    pub started_at: u64,
    pub intent: Option<String>,
    pub response: Option<String>,
    pub expires_at: Option<u64>,
}

impl Identity {
    pub fn new(api: &str) -> Result<Self> {
        let key = InstallKey::generate(&SystemRandom::new()).map_err(|_| invalid())?;
        let keys = Keys {
            pkcs8: key.pkcs8_base64url(),
            wg: STANDARD.encode(crate::host::random::<32>()?),
        };
        let bytes = Zeroizing::new(serde_json::to_vec(&keys).map_err(|_| invalid())?);
        let (protection, protected) = super::protect::seal(&bytes)?;
        Ok(Self {
            schema: 1,
            api: api.into(),
            public_jwk: key.public_jwk(),
            protection: protection.into(),
            protected_keys: URL_SAFE_NO_PAD.encode(protected),
            paired: None,
            attempt: None,
            native: None,
        })
    }

    fn keys(&self) -> Result<Keys> {
        let ciphertext = URL_SAFE_NO_PAD.decode(&self.protected_keys).map_err(|_| invalid())?;
        let plaintext = Zeroizing::new(super::protect::open(&self.protection, &ciphertext)?);
        serde_json::from_slice(&plaintext).map_err(|_| invalid())
    }

    pub fn signing_key(&self) -> Result<InstallKey> {
        let key = InstallKey::from_pkcs8_base64url(&self.keys()?.pkcs8, &SystemRandom::new())
            .map_err(|_| invalid())?;
        if key.public_jwk() != self.public_jwk {
            return Err(invalid());
        }
        Ok(key)
    }

    pub(super) fn wg_private(&self) -> Result<Zeroizing<[u8; 32]>> {
        let bytes: [u8; 32] = STANDARD
            .decode(&self.keys()?.wg)
            .map_err(|_| invalid())?
            .try_into()
            .map_err(|_| invalid())?;
        Ok(Zeroizing::new(bytes))
    }

    pub fn wg_public(&self) -> Result<String> {
        let secret = x25519_dalek::StaticSecret::from(*self.wg_private()?);
        Ok(STANDARD.encode(x25519_dalek::PublicKey::from(&secret).as_bytes()))
    }

    pub fn begin_response(&self) -> Result<Option<Value>> {
        let Some(encoded) = self.attempt.as_ref().and_then(|a| a.response.as_ref()) else {
            return Ok(None);
        };
        let bytes = URL_SAFE_NO_PAD.decode(encoded).map_err(|_| invalid())?;
        let plaintext = Zeroizing::new(super::protect::open(&self.protection, &bytes)?);
        serde_json::from_slice(&plaintext).map(Some).map_err(|_| invalid())
    }

    pub fn save_response(&mut self, response: &Value) -> Result<()> {
        let plaintext = Zeroizing::new(serde_json::to_vec(response).map_err(|_| invalid())?);
        let (protection, bytes) = super::protect::seal(&plaintext)?;
        if protection != self.protection {
            return Err(invalid());
        }
        self.attempt.as_mut().ok_or_else(invalid)?.response = Some(URL_SAFE_NO_PAD.encode(bytes));
        self.attempt.as_mut().ok_or_else(invalid)?.expires_at = response["expires_at"].as_u64();
        Ok(())
    }

    pub fn save_native(&mut self, grant: &Grant, received_at: u64) -> Result<()> {
        let private = grant.private_record().map_err(|_| invalid())?;
        let bytes = Zeroizing::new(serde_json::to_vec(&private).map_err(|_| invalid())?);
        let (protection, sealed) = super::protect::seal(&bytes)?;
        if protection != self.protection {
            return Err(invalid());
        }
        self.schema = 2;
        self.native =
            Some(NativeState::Pending { response: URL_SAFE_NO_PAD.encode(sealed), received_at });
        Ok(())
    }
    pub fn native_grant(&self) -> Result<Option<Grant>> {
        let Some(NativeState::Pending { response, .. }) = &self.native else { return Ok(None) };
        let bytes = URL_SAFE_NO_PAD.decode(response).map_err(|_| invalid())?;
        let plain = Zeroizing::new(super::protect::open(&self.protection, &bytes)?);
        let value = serde_json::from_slice(&plain).map_err(|_| invalid())?;
        Grant::parse(&value).map(Some).map_err(|_| invalid())
    }
}

fn invalid() -> Error {
    Error::verification("server.pair.invalid_identity")
}

pub(super) struct Store {
    path: PathBuf,
    _lock: fsx::FileLock,
}

fn check_private(meta: &std::fs::Metadata, directory: bool) -> Result<()> {
    if meta.file_type().is_symlink()
        || (directory && !meta.is_dir())
        || (!directory && !meta.is_file())
    {
        return Err(invalid());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if meta.uid() != crate::sys::euid() || meta.mode() & 0o077 != 0 {
            return Err(invalid());
        }
    }
    Ok(())
}

pub(super) fn read(path: &Path) -> Result<Option<Identity>> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x0020_0000);
    }
    let file = match options.open(path) {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err(invalid()),
    };
    check_private(&file.metadata().map_err(|_| invalid())?, false)?;
    let mut bytes = Vec::new();
    file.take(64 * 1024 + 1).read_to_end(&mut bytes).map_err(|_| invalid())?;
    if bytes.len() > 64 * 1024 {
        return Err(invalid());
    }
    let identity: Identity = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
    if !matches!(identity.schema, 1 | 2)
        || (identity.schema == 1 && identity.native.is_some())
        || (identity.schema == 2 && identity.native.is_none())
    {
        return Err(invalid());
    }
    if super::api_origin(&identity.api).map_err(|_| invalid())? != identity.api
        || !super::protect::supported(&identity.protection)
        || cmux_server_core::pairing::enrollment::jwk_thumbprint(&identity.public_jwk).is_err()
        || (identity.paired.is_some() && identity.attempt.is_some())
        || (identity.native.is_some() && (identity.paired.is_none() || identity.attempt.is_some()))
        || identity.attempt.as_ref().is_some_and(|a| a.response.is_some() != a.expires_at.is_some())
    {
        return Err(invalid());
    }
    if let Some(paired) = &identity.paired {
        paired.validate().map_err(|_| invalid())?;
    }
    super::native::validate(&identity)?;
    Ok(Some(identity))
}

impl Store {
    pub fn acquire(path: &Path) -> Result<Self> {
        let parent = path.parent().ok_or_else(invalid)?;
        fsx::ensure_dir(parent, 0o700)?;
        let meta = std::fs::symlink_metadata(parent).map_err(|_| invalid())?;
        check_private(&meta, true)?;
        let mut options = OpenOptions::new();
        options.write(true).create(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600).custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
        }
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            options.custom_flags(0x0020_0000);
        }
        let file = options.open(parent.join(".pair.lock")).map_err(|_| invalid())?;
        check_private(&file.metadata().map_err(|_| invalid())?, false)?;
        match fsx::FileLock::try_acquire(file) {
            Ok(lock) => Ok(Self { path: path.into(), _lock: lock }),
            Err(TryLockError::WouldBlock) => Err(Error::unreachable("server.pair.busy")),
            Err(_) => Err(invalid()),
        }
    }

    pub fn read(&self) -> Result<Option<Identity>> {
        read(&self.path)
    }
    pub fn save(&self, identity: &Identity) -> Result<()> {
        let bytes = serde_json::to_vec(identity).map_err(|_| invalid())?;
        fsx::atomic_write(&self.path, &bytes, 0o600)
    }
}

#[cfg(all(test, unix))]
#[path = "identity_tests.rs"]
mod tests;
