//! Private files of the pairing folder. The folder and `<state>` must be
//! real directories (not symlinks) owned by this user with no group or
//! other bits (`access::check`), and every file is opened with
//! `O_NOFOLLOW` and checked on the open handle (type, owner, mode), so a
//! path swapped between a check and an open is never read.

use std::fs::{File, OpenOptions};
use std::io::{self, Read};
use std::path::Path;

use cmux_server_core::HostPath;
#[cfg(unix)]
use cmux_server_core::access::{Access, PathAccess, PosixOwner};

use crate::error::{Error, Result};

/// Refuses `dir` unless it is a directory, not a symlink, owned by this
/// user, mode 0700 or narrower.
pub fn check_dir(dir: &HostPath) -> Result<()> {
    #[cfg(unix)]
    {
        let policy = PathAccess {
            path: dir.clone(),
            access: Access::Posix { owner: PosixOwner::CurrentUser, group: None, mode: 0o700 },
            no_symlink: true,
        };
        if !crate::access::check(&policy)? {
            return Err(Error::internal(format!("{} disappeared", dir.as_str())));
        }
    }
    #[cfg(not(unix))]
    let _ = dir;
    Ok(())
}

fn options() -> OpenOptions {
    let mut options = OpenOptions::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    options
}

fn refuse_symlink(path: &Path, e: io::Error) -> Error {
    #[cfg(unix)]
    if e.raw_os_error() == Some(libc::ELOOP) {
        return Error::rejected(format!("{} is a symlink; refusing", path.display()));
    }
    Error::io(path.display(), e)
}

/// Checks an open handle: a regular file of this user, no group or other
/// bits.
fn check_handle(path: &Path, file: &File) -> Result<()> {
    let meta = file.metadata().map_err(|e| Error::io(path.display(), e))?;
    if !meta.is_file() {
        return Err(Error::rejected(format!("{} is not a regular file", path.display())));
    }
    #[cfg(unix)]
    {
        let mode = crate::fsx::mode_of(&meta);
        if crate::sys::owner_uid(&meta) != crate::sys::euid() {
            return Err(Error::rejected(format!(
                "{} is owned by another user; refusing",
                path.display()
            )));
        }
        if mode & 0o077 != 0 {
            return Err(Error::rejected(format!(
                "{} is readable by others (mode {mode:o}); remove it or chmod 600",
                path.display()
            )));
        }
    }
    Ok(())
}

/// Reads a private file; `None` when it is missing.
pub fn read(path: &Path) -> Result<Option<Vec<u8>>> {
    let mut file = match options().read(true).open(path) {
        Ok(file) => file,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(refuse_symlink(path, e)),
    };
    check_handle(path, &file)?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).map_err(|e| Error::io(path.display(), e))?;
    Ok(Some(bytes))
}

/// Opens (or creates, 0600) the lock file without following a symlink.
pub fn open_lock(path: &Path) -> Result<File> {
    let mut options = options();
    options.create(true).truncate(false).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let file = options.open(path).map_err(|e| refuse_symlink(path, e))?;
    check_handle(path, &file)?;
    Ok(file)
}
