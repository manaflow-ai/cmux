//! Linux: the identity in the Secret Service (GNOME Keyring, KWallet) over
//! D-Bus (`assurance: "keystore"`), and the choice between it and the key
//! file for a headless box.

use std::fs;
use std::path::{Path, PathBuf};

use zeroize::Zeroizing;

use super::{
    Assurance, DeviceIdentity, FileKeyStore, IdentityError, KeyStore, Platform, SoftwareKeys,
    StoredSoftwareIdentity, new_device_id,
};

/// The identity as one Secret Service item: service `cmux-device-hub`, the
/// account `profile`. The secret is the stored identity's JSON.
#[derive(Debug, Clone)]
pub struct SecretServiceKeyStore {
    service: String,
    profile: String,
}

impl SecretServiceKeyStore {
    pub const SERVICE: &'static str = "cmux-device-hub";

    pub fn new(profile: impl Into<String>) -> SecretServiceKeyStore {
        SecretServiceKeyStore { service: Self::SERVICE.to_owned(), profile: profile.into() }
    }

    fn entry(&self) -> Result<keyring::Entry, IdentityError> {
        keyring::Entry::new(&self.service, &self.profile).map_err(map_error)
    }

    /// The stored identity, `None` when there is no item.
    fn read(&self) -> Result<Option<DeviceIdentity>, IdentityError> {
        match self.entry()?.get_password() {
            Ok(secret) => {
                let secret = Zeroizing::new(secret);
                let stored: StoredSoftwareIdentity = serde_json::from_str(&secret)
                    .map_err(|error| IdentityError::Corrupt(error.to_string()))?;
                SoftwareKeys::identity_from_stored(&stored, Platform::Linux, Assurance::Keystore)
                    .map(Some)
            }
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(error) => Err(map_error(error)),
        }
    }
}

impl KeyStore for SecretServiceKeyStore {
    fn load_or_create(&self) -> Result<DeviceIdentity, IdentityError> {
        if let Some(identity) = self.read()? {
            return Ok(identity);
        }
        let keys = SoftwareKeys::generate(Assurance::Keystore)?;
        let id = new_device_id();
        let secret = Zeroizing::new(
            serde_json::to_string(&keys.to_stored(&id))
                .map_err(|error| IdentityError::Corrupt(error.to_string()))?,
        );
        self.entry()?.set_password(&secret).map_err(map_error)?;
        // Read back: what the keyring holds is the identity, also when another
        // process stored one at the same moment.
        self.read()?.ok_or_else(|| {
            IdentityError::Unavailable("the Secret Service did not keep the item".into())
        })
    }

    fn reset(&self) -> Result<(), IdentityError> {
        match self.entry()?.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(error) => Err(map_error(error)),
        }
    }
}

fn map_error(error: keyring::Error) -> IdentityError {
    match error {
        keyring::Error::PlatformFailure(_) | keyring::Error::NoStorageAccess(_) => {
            IdentityError::Unavailable(error.to_string())
        }
        other => IdentityError::Io(other.to_string()),
    }
}

/// Linux's store: the Secret Service when the session has one, else the key
/// file. The first identity's store is remembered in `<dir>/key-store` and
/// used from then on, so a keyring that is briefly unavailable never makes
/// a second device id.
#[derive(Debug, Clone)]
pub struct LinuxKeyStore {
    dir: PathBuf,
    secret_service: SecretServiceKeyStore,
    file: FileKeyStore,
}

impl LinuxKeyStore {
    const CHOICE_FILE: &'static str = "key-store";

    pub fn new(dir: impl AsRef<Path>, profile: impl Into<String>) -> LinuxKeyStore {
        LinuxKeyStore {
            dir: dir.as_ref().to_owned(),
            secret_service: SecretServiceKeyStore::new(profile),
            file: FileKeyStore::new(dir, Platform::Linux),
        }
    }

    fn choice(&self) -> Result<Option<String>, IdentityError> {
        let path = self.dir.join(Self::CHOICE_FILE);
        match fs::read_to_string(&path) {
            Ok(text) => Ok(Some(text.trim().to_owned())),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(IdentityError::Io(format!("{}: {error}", path.display()))),
        }
    }

    fn remember(&self, choice: &str) -> Result<(), IdentityError> {
        fs::create_dir_all(&self.dir).map_err(|error| IdentityError::Io(error.to_string()))?;
        fs::write(self.dir.join(Self::CHOICE_FILE), choice)
            .map_err(|error| IdentityError::Io(error.to_string()))
    }
}

impl KeyStore for LinuxKeyStore {
    fn load_or_create(&self) -> Result<DeviceIdentity, IdentityError> {
        match self.choice()?.as_deref() {
            Some("secret-service") => return self.secret_service.load_or_create(),
            Some("file") => return self.file.load_or_create(),
            Some(other) => {
                return Err(IdentityError::Corrupt(format!("unknown key store {other:?}")));
            }
            None => {}
        }
        match self.secret_service.load_or_create() {
            Ok(identity) => {
                self.remember("secret-service")?;
                Ok(identity)
            }
            Err(IdentityError::Unavailable(_)) => {
                let identity = self.file.load_or_create()?;
                self.remember("file")?;
                Ok(identity)
            }
            Err(error) => Err(error),
        }
    }

    fn reset(&self) -> Result<(), IdentityError> {
        match self.choice()?.as_deref() {
            Some("secret-service") => self.secret_service.reset()?,
            Some("file") => self.file.reset()?,
            _ => {}
        }
        match fs::remove_file(self.dir.join(Self::CHOICE_FILE)) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(IdentityError::Io(error.to_string())),
        }
    }
}
