//! Descriptor-pinned reads for owner-only secret files.

use std::io;
use std::path::Path;

use zeroize::Zeroizing;

/// Read at most `maximum_bytes` from an owner-only regular file.
///
/// The path is opened once without following its final symlink. Validation and
/// reading both use that descriptor, so a pathname swap cannot redirect the
/// read after validation.
#[cfg(unix)]
pub fn read_owner_only(path: &Path, maximum_bytes: usize) -> io::Result<Zeroizing<Vec<u8>>> {
    use std::fs::OpenOptions;
    use std::io::Read;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};

    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.file_type().is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "secret path is not a regular file",
        ));
    }
    if metadata.uid() != unsafe { libc::geteuid() } {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "secret file is not owned by the current user",
        ));
    }
    if metadata.permissions().mode() & 0o077 != 0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "secret file has group or other permissions",
        ));
    }
    if metadata.len() > maximum_bytes as u64 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "secret file is too large"));
    }

    let read_limit = maximum_bytes
        .checked_add(1)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid secret size limit"))?;
    let mut bytes = Zeroizing::new(Vec::with_capacity(read_limit.min(4096)));
    file.by_ref().take(read_limit as u64).read_to_end(&mut bytes)?;
    if bytes.len() > maximum_bytes {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "secret file is too large"));
    }
    Ok(bytes)
}

/// Read an owner-only secret file and require UTF-8 without copying its bytes.
#[cfg(unix)]
pub fn read_owner_only_string(path: &Path, maximum_bytes: usize) -> io::Result<Zeroizing<String>> {
    let mut bytes = read_owner_only(path, maximum_bytes)?;
    let bytes = std::mem::take(&mut *bytes);
    String::from_utf8(bytes).map(Zeroizing::new).map_err(|error| {
        let _invalid_bytes = Zeroizing::new(error.into_bytes());
        io::Error::new(io::ErrorKind::InvalidData, "secret file is not valid UTF-8")
    })
}

#[cfg(not(unix))]
pub fn read_owner_only(_: &Path, _: usize) -> io::Result<Zeroizing<Vec<u8>>> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "owner-only secret files require Unix"))
}

#[cfg(not(unix))]
pub fn read_owner_only_string(_: &Path, _: usize) -> io::Result<Zeroizing<String>> {
    Err(io::Error::new(io::ErrorKind::Unsupported, "owner-only secret files require Unix"))
}
