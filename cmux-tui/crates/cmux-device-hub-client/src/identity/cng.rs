//! Windows: persisted CNG keys. The Microsoft Platform Crypto Provider keeps
//! them in the TPM (`assurance: "hardware"`); a machine without one uses the
//! Microsoft Software Key Storage Provider (`assurance: "keystore"`). The keys
//! never leave the provider: signing is `NCryptSignHash`, whose ECDSA output is
//! raw r||s. The device id and the provider are kept in `<dir>/cng-identity.json`.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use windows::Win32::Security::Cryptography::{
    BCRYPT_ECCKEY_BLOB, BCRYPT_ECCPUBLIC_BLOB, CERT_KEY_SPEC, MS_KEY_STORAGE_PROVIDER,
    MS_PLATFORM_CRYPTO_PROVIDER, NCRYPT_ECDH_P256_ALGORITHM, NCRYPT_ECDSA_P256_ALGORITHM,
    NCRYPT_FLAGS, NCRYPT_HANDLE, NCRYPT_KEY_HANDLE, NCRYPT_PROV_HANDLE, NCRYPT_SILENT_FLAG,
    NCryptCreatePersistedKey, NCryptDeleteKey, NCryptExportKey, NCryptFinalizeKey,
    NCryptFreeObject, NCryptOpenKey, NCryptOpenStorageProvider, NCryptSignHash,
};
use windows::core::{HSTRING, PCWSTR};

use super::{
    Assurance, DeviceIdentity, DeviceKeys, IdentityError, KeyStore, Platform, is_device_id,
    new_device_id,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
enum Provider {
    /// The TPM.
    Platform,
    /// Software keys under the user's profile.
    Software,
}

impl Provider {
    fn name(self) -> PCWSTR {
        match self {
            Provider::Platform => MS_PLATFORM_CRYPTO_PROVIDER,
            Provider::Software => MS_KEY_STORAGE_PROVIDER,
        }
    }

    fn assurance(self) -> Assurance {
        match self {
            Provider::Platform => Assurance::Hardware,
            Provider::Software => Assurance::Keystore,
        }
    }
}

#[derive(Serialize, Deserialize)]
struct Metadata {
    v: u32,
    id: String,
    provider: Provider,
}

/// An owned NCrypt handle, freed on drop.
struct Handle(usize);

impl Handle {
    fn provider(&self) -> NCRYPT_PROV_HANDLE {
        NCRYPT_PROV_HANDLE(self.0)
    }

    fn key(&self) -> NCRYPT_KEY_HANDLE {
        NCRYPT_KEY_HANDLE(self.0)
    }
}

impl Drop for Handle {
    fn drop(&mut self) {
        // SAFETY: the handle came from NCrypt and is freed once, here.
        let _ = unsafe { NCryptFreeObject(NCRYPT_HANDLE(self.0)) };
    }
}

// SAFETY: NCrypt key handles may be used from any thread; NCrypt serializes
// access to a key internally.
unsafe impl Send for Handle {}
// SAFETY: as above; every use goes through NCrypt calls that take the handle by value.
unsafe impl Sync for Handle {}

fn crypto_error(what: &str, error: windows::core::Error) -> IdentityError {
    IdentityError::Crypto(format!("{what}: {error}"))
}

fn open_provider(provider: Provider) -> Result<Handle, IdentityError> {
    let mut handle = NCRYPT_PROV_HANDLE::default();
    // SAFETY: `handle` is a valid out pointer; the provider name is a static string.
    unsafe { NCryptOpenStorageProvider(&mut handle, provider.name(), 0) }
        .map_err(|error| IdentityError::Unavailable(format!("CNG provider: {error}")))?;
    Ok(Handle(handle.0))
}

fn open_key(provider: &Handle, name: &str) -> Result<Option<Handle>, IdentityError> {
    let mut key = NCRYPT_KEY_HANDLE::default();
    let name = HSTRING::from(name);
    // SAFETY: valid provider handle and out pointer; `name` outlives the call.
    match unsafe {
        NCryptOpenKey(provider.provider(), &mut key, &name, CERT_KEY_SPEC(0), NCRYPT_SILENT_FLAG)
    } {
        Ok(()) => Ok(Some(Handle(key.0))),
        Err(error) if is_missing_key(&error) => Ok(None),
        Err(error) => Err(crypto_error("open key", error)),
    }
}

/// NTE_BAD_KEYSET or NTE_NO_KEY: the named key does not exist.
fn is_missing_key(error: &windows::core::Error) -> bool {
    let code = error.code().0 as u32;
    code == 0x8009_0016 || code == 0x8009_000d
}

fn create_key(provider: &Handle, name: &str, algorithm: PCWSTR) -> Result<Handle, IdentityError> {
    let mut key = NCRYPT_KEY_HANDLE::default();
    let name = HSTRING::from(name);
    // SAFETY: valid provider handle and out pointer; `name` outlives the call.
    unsafe {
        NCryptCreatePersistedKey(
            provider.provider(),
            &mut key,
            algorithm,
            &name,
            CERT_KEY_SPEC(0),
            NCRYPT_FLAGS(0),
        )
    }
    .map_err(|error| crypto_error("create key", error))?;
    let key = Handle(key.0);
    // SAFETY: a key handle just created and not yet finalized.
    unsafe { NCryptFinalizeKey(key.key(), NCRYPT_SILENT_FLAG) }
        .map_err(|error| crypto_error("finalize key", error))?;
    Ok(key)
}

fn delete_key(provider: &Handle, name: &str) -> Result<(), IdentityError> {
    if let Some(key) = open_key(provider, name)? {
        // SAFETY: NCryptDeleteKey frees the handle itself, so it is not dropped again.
        let result = unsafe { NCryptDeleteKey(key.key(), 0) };
        std::mem::forget(key);
        result.map_err(|error| crypto_error("delete key", error))?;
    }
    Ok(())
}

/// The key's public point as X9.63 uncompressed.
fn export_public(key: &Handle) -> Result<[u8; 65], IdentityError> {
    let mut length = 0u32;
    // SAFETY: size query with no output buffer.
    unsafe {
        NCryptExportKey(
            key.key(),
            None,
            BCRYPT_ECCPUBLIC_BLOB,
            None,
            None,
            &mut length,
            NCRYPT_FLAGS(0),
        )
    }
    .map_err(|error| crypto_error("export public key", error))?;
    let mut blob = vec![0u8; length as usize];
    // SAFETY: `blob` has the size NCrypt asked for.
    unsafe {
        NCryptExportKey(
            key.key(),
            None,
            BCRYPT_ECCPUBLIC_BLOB,
            None,
            Some(&mut blob),
            &mut length,
            NCRYPT_FLAGS(0),
        )
    }
    .map_err(|error| crypto_error("export public key", error))?;
    let header = size_of::<BCRYPT_ECCKEY_BLOB>();
    if blob.len() < header + 64 {
        return Err(IdentityError::Crypto("short CNG public key blob".into()));
    }
    let coordinate = u32::from_le_bytes([blob[4], blob[5], blob[6], blob[7]]) as usize;
    if coordinate != 32 || blob.len() < header + 64 {
        return Err(IdentityError::Crypto("the CNG key is not P-256".into()));
    }
    let mut point = [0u8; 65];
    point[0] = 0x04;
    point[1..].copy_from_slice(&blob[header..header + 64]);
    Ok(point)
}

struct CngKeys {
    signing: Handle,
    signing_public: [u8; 65],
    agreement_public: [u8; 65],
    provider: Provider,
    // The agreement key stays open so the provider keeps it loaded.
    _agreement: Handle,
}

impl DeviceKeys for CngKeys {
    fn signing_public_key(&self) -> [u8; 65] {
        self.signing_public
    }

    fn agreement_public_key(&self) -> [u8; 65] {
        self.agreement_public
    }

    fn sign(&self, message: &[u8]) -> Result<[u8; 64], IdentityError> {
        let digest = Sha256::digest(message);
        let mut signature = [0u8; 64];
        let mut length = 0u32;
        // SAFETY: valid key handle; `digest` and `signature` are live buffers of the given sizes.
        unsafe {
            NCryptSignHash(
                self.signing.key(),
                None,
                digest.as_slice(),
                Some(&mut signature),
                &mut length,
                NCRYPT_SILENT_FLAG,
            )
        }
        .map_err(|error| crypto_error("sign", error))?;
        if length != 64 {
            return Err(IdentityError::Crypto(format!("CNG signature is {length} bytes")));
        }
        Ok(signature)
    }

    fn assurance(&self) -> Assurance {
        self.provider.assurance()
    }
}

/// The CNG store. Key names are `cmux-device-hub-<profile>-<id>-signing` and
/// `...-agreement`.
#[derive(Debug, Clone)]
pub struct CngKeyStore {
    dir: PathBuf,
    profile: String,
}

impl CngKeyStore {
    const METADATA_FILE: &'static str = "cng-identity.json";

    pub fn new(dir: impl AsRef<Path>, profile: impl Into<String>) -> CngKeyStore {
        CngKeyStore { dir: dir.as_ref().to_owned(), profile: profile.into() }
    }

    fn metadata_path(&self) -> PathBuf {
        self.dir.join(Self::METADATA_FILE)
    }

    fn key_name(&self, id: &str, role: &str) -> String {
        format!("cmux-device-hub-{}-{id}-{role}", self.profile)
    }

    fn read_metadata(&self) -> Result<Option<Metadata>, IdentityError> {
        let path = self.metadata_path();
        match fs::read_to_string(&path) {
            Ok(text) => {
                let metadata: Metadata = serde_json::from_str(&text)
                    .map_err(|error| IdentityError::Corrupt(error.to_string()))?;
                if metadata.v != 1 || !is_device_id(&metadata.id) {
                    return Err(IdentityError::Corrupt(format!("{} is malformed", path.display())));
                }
                Ok(Some(metadata))
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(IdentityError::Io(format!("{}: {error}", path.display()))),
        }
    }

    fn open(&self, metadata: &Metadata) -> Result<DeviceIdentity, IdentityError> {
        let provider = open_provider(metadata.provider)?;
        let signing =
            open_key(&provider, &self.key_name(&metadata.id, "signing"))?.ok_or_else(|| {
                IdentityError::Corrupt("the signing key is missing from the provider".into())
            })?;
        let agreement = open_key(&provider, &self.key_name(&metadata.id, "agreement"))?
            .ok_or_else(|| {
                IdentityError::Corrupt("the agreement key is missing from the provider".into())
            })?;
        let keys = CngKeys {
            signing_public: export_public(&signing)?,
            agreement_public: export_public(&agreement)?,
            signing,
            _agreement: agreement,
            provider: metadata.provider,
        };
        Ok(DeviceIdentity::new(metadata.id.clone(), Platform::Windows, Arc::new(keys)))
    }

    fn create_in(&self, provider_kind: Provider, id: &str) -> Result<(), IdentityError> {
        let provider = open_provider(provider_kind)?;
        create_key(&provider, &self.key_name(id, "signing"), NCRYPT_ECDSA_P256_ALGORITHM)?;
        if let Err(error) =
            create_key(&provider, &self.key_name(id, "agreement"), NCRYPT_ECDH_P256_ALGORITHM)
        {
            let _ = delete_key(&provider, &self.key_name(id, "signing"));
            return Err(error);
        }
        Ok(())
    }
}

impl KeyStore for CngKeyStore {
    fn load_or_create(&self) -> Result<DeviceIdentity, IdentityError> {
        if let Some(metadata) = self.read_metadata()? {
            return self.open(&metadata);
        }
        let id = new_device_id();
        let provider = match self.create_in(Provider::Platform, &id) {
            Ok(()) => Provider::Platform,
            Err(_) => {
                self.create_in(Provider::Software, &id)?;
                Provider::Software
            }
        };
        let metadata = Metadata { v: 1, id, provider };
        fs::create_dir_all(&self.dir).map_err(|error| IdentityError::Io(error.to_string()))?;
        let text = serde_json::to_string(&metadata)
            .map_err(|error| IdentityError::Corrupt(error.to_string()))?;
        fs::write(self.metadata_path(), text)
            .map_err(|error| IdentityError::Io(error.to_string()))?;
        self.open(&metadata)
    }

    fn reset(&self) -> Result<(), IdentityError> {
        let Some(metadata) = self.read_metadata()? else {
            return Ok(());
        };
        let provider = open_provider(metadata.provider)?;
        delete_key(&provider, &self.key_name(&metadata.id, "signing"))?;
        delete_key(&provider, &self.key_name(&metadata.id, "agreement"))?;
        fs::remove_file(self.metadata_path()).map_err(|error| IdentityError::Io(error.to_string()))
    }
}
