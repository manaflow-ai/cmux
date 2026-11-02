//! The headless key file: the identity as JSON in a file only its owner can
//! read (`assurance: "file"`, the lowest). It is created with mode 0600 in
//! one step and a file other users can read is never loaded.

use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};

use zeroize::Zeroizing;

use super::{
    Assurance, DeviceIdentity, IdentityError, KeyStore, Platform, SoftwareKeys,
    StoredSoftwareIdentity, new_device_id,
};

/// The identity in `<dir>/device-identity.json`.
#[derive(Debug, Clone)]
pub struct FileKeyStore {
    path: PathBuf,
    platform: Platform,
}

impl FileKeyStore {
    pub const FILE_NAME: &'static str = "device-identity.json";

    /// The key file in `dir`, registering as `platform`.
    pub fn new(dir: impl AsRef<Path>, platform: Platform) -> FileKeyStore {
        FileKeyStore { path: dir.as_ref().join(Self::FILE_NAME), platform }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    fn load(&self) -> Result<Option<DeviceIdentity>, IdentityError> {
        let metadata = match fs::symlink_metadata(&self.path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(io_error(&self.path, &error)),
        };
        if !metadata.file_type().is_file() {
            return Err(IdentityError::Corrupt(format!(
                "{} is not a regular file",
                self.path.display()
            )));
        }
        check_private(&self.path, &metadata)?;
        let text = Zeroizing::new(
            fs::read_to_string(&self.path).map_err(|error| io_error(&self.path, &error))?,
        );
        let stored: StoredSoftwareIdentity = serde_json::from_str(&text)
            .map_err(|error| IdentityError::Corrupt(error.to_string()))?;
        SoftwareKeys::identity_from_stored(&stored, self.platform, Assurance::File).map(Some)
    }

    fn create(&self) -> Result<DeviceIdentity, IdentityError> {
        let dir = self.path.parent().unwrap_or_else(|| Path::new("."));
        create_private_dir(dir)?;
        let keys = SoftwareKeys::generate(Assurance::File)?;
        let id = new_device_id();
        let text = Zeroizing::new(
            serde_json::to_string(&keys.to_stored(&id))
                .map_err(|error| IdentityError::Corrupt(error.to_string()))?,
        );
        // Written in full under a temporary name, then linked in place: the
        // link fails when another process created the file first, and a reader
        // never sees a partial file.
        let temp = dir.join(format!(".{}.{}.tmp", Self::FILE_NAME, uuid::Uuid::new_v4().simple()));
        let result = (|| {
            let mut file = create_private_file(&temp)?;
            file.write_all(text.as_bytes())?;
            file.sync_all()?;
            drop(file);
            fs::hard_link(&temp, &self.path)
        })();
        let _ = fs::remove_file(&temp);
        match result {
            Ok(()) => Ok(DeviceIdentity::new(id, self.platform, std::sync::Arc::new(keys))),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => self
                .load()?
                .ok_or_else(|| IdentityError::Io("the key file vanished while loading".into())),
            Err(error) => Err(io_error(&self.path, &error)),
        }
    }
}

impl KeyStore for FileKeyStore {
    fn load_or_create(&self) -> Result<DeviceIdentity, IdentityError> {
        match self.load()? {
            Some(identity) => Ok(identity),
            None => self.create(),
        }
    }

    fn reset(&self) -> Result<(), IdentityError> {
        match fs::remove_file(&self.path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(io_error(&self.path, &error)),
        }
    }
}

fn io_error(path: &Path, error: &std::io::Error) -> IdentityError {
    IdentityError::Io(format!("{}: {error}", path.display()))
}

#[cfg(unix)]
fn check_private(path: &Path, metadata: &fs::Metadata) -> Result<(), IdentityError> {
    use std::os::unix::fs::MetadataExt as _;
    let mode = metadata.mode() & 0o7777;
    if mode & 0o077 != 0 {
        return Err(IdentityError::InsecureKeyFile { path: path.display().to_string(), mode });
    }
    // SAFETY: getuid has no preconditions and cannot fail.
    let uid = unsafe { libc::getuid() };
    if metadata.uid() != uid {
        return Err(IdentityError::InsecureKeyFile { path: path.display().to_string(), mode });
    }
    Ok(())
}

#[cfg(not(unix))]
fn check_private(_path: &Path, _metadata: &fs::Metadata) -> Result<(), IdentityError> {
    // Windows: the file inherits the per-user profile directory's ACL.
    Ok(())
}

#[cfg(unix)]
fn create_private_file(path: &Path) -> Result<fs::File, std::io::Error> {
    use std::os::unix::fs::OpenOptionsExt as _;
    fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(path)
}

#[cfg(not(unix))]
fn create_private_file(path: &Path) -> Result<fs::File, std::io::Error> {
    fs::OpenOptions::new().write(true).create_new(true).open(path)
}

#[cfg(unix)]
fn create_private_dir(dir: &Path) -> Result<(), IdentityError> {
    use std::os::unix::fs::DirBuilderExt as _;
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
        .map_err(|error| io_error(dir, &error))
}

#[cfg(not(unix))]
fn create_private_dir(dir: &Path) -> Result<(), IdentityError> {
    fs::create_dir_all(dir).map_err(|error| io_error(dir, &error))
}
