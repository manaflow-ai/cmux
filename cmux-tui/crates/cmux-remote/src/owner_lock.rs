use std::fs::{File, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};

use fs4::FileExt;

#[derive(Debug)]
pub(crate) struct OwnerFileLock {
    file: File,
}

impl OwnerFileLock {
    pub(crate) fn acquire(path: &Path) -> io::Result<Self> {
        let file = open_private_lock(path)?;
        FileExt::lock(&file)?;
        Ok(Self { file })
    }

    pub(crate) fn try_acquire(path: &Path) -> io::Result<Self> {
        let file = open_private_lock(path)?;
        FileExt::try_lock(&file).map_err(io::Error::from)?;
        Ok(Self { file })
    }

    pub(crate) async fn acquire_async(path: PathBuf) -> io::Result<Self> {
        tokio::task::spawn_blocking(move || Self::acquire(&path))
            .await
            .map_err(|error| io::Error::other(format!("owner-file lock task failed: {error}")))?
    }
}

impl Drop for OwnerFileLock {
    fn drop(&mut self) {
        let _ = FileExt::unlock(&self.file);
    }
}

pub(crate) fn sibling_lock_path(path: &Path) -> io::Result<PathBuf> {
    let file_name = path.file_name().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "lock target has no file name")
    })?;
    let mut lock_name = file_name.to_os_string();
    lock_name.push(".lock");
    Ok(path.with_file_name(lock_name))
}

fn open_private_lock(path: &Path) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;

        options.mode(0o600).custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    }
    let file = options.open(path)?;
    validate_private_lock(path, &file)?;
    Ok(file)
}

#[cfg(unix)]
fn validate_private_lock(path: &Path, file: &File) -> io::Result<()> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("lock {} is not a regular file", path.display()),
        ));
    }
    if metadata.uid() != unsafe { libc::geteuid() } {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("lock {} is not owned by the effective user", path.display()),
        ));
    }
    if metadata.permissions().mode() & 0o077 != 0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("lock {} is accessible by another user", path.display()),
        ));
    }
    if metadata.nlink() != 1 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("lock {} has unexpected hard links", path.display()),
        ));
    }
    Ok(())
}

#[cfg(windows)]
fn validate_private_lock(path: &Path, file: &File) -> io::Result<()> {
    if !file.metadata()?.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("lock {} is not a regular file", path.display()),
        ));
    }
    Ok(())
}
