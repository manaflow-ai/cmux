//! The check a serve's socket passes once its ready line names it, before
//! `carrier supervise` hands it out: a carrier socket (`cmux-link-<12
//! hex>.sock`) of this user, in a directory only this user can enter (mode
//! 0700), on a path no other user can change: every ancestor is owned by
//! root or this user, and one that others can write keeps the sticky bit
//! (`/private/tmp`). Nobody else can then replace the socket between the
//! check and the connect. The app's `CloudLinkSocketPolicy`, ported with the
//! serve lifecycle.

use std::os::unix::fs::{FileTypeExt as _, MetadataExt as _, PermissionsExt as _};
use std::path::Path;

use super::serve_machine::LinkError;

/// `sun_path` holds 104 bytes on macOS with the terminating NUL.
const MAX_PATH_BYTES: usize = 103;
const STICKY: u32 = 0o1000;

/// `Ok` when `path` passes for this process's user.
pub(crate) fn check(path: &str) -> Result<(), LinkError> {
    // SAFETY: getuid has no preconditions and cannot fail.
    check_as(path, unsafe { libc::getuid() })
}

fn unsafe_socket(why: &str) -> LinkError {
    LinkError::UnsafeSocket(why.to_owned())
}

/// [`check`] for `uid`.
pub(crate) fn check_as(path: &str, uid: u32) -> Result<(), LinkError> {
    if !path.starts_with('/') {
        return Err(unsafe_socket("not an absolute path"));
    }
    if path.contains('\0') {
        return Err(unsafe_socket("path has a NUL byte"));
    }
    if path.len() > MAX_PATH_BYTES {
        return Err(unsafe_socket("path too long"));
    }
    let components: Vec<&str> = path.split('/').skip(1).collect();
    if components.iter().any(|c| c.is_empty() || *c == "." || *c == "..") {
        return Err(unsafe_socket("not a carrier socket path"));
    }
    let Some((name, parents)) = components.split_last() else {
        return Err(unsafe_socket("not a carrier socket path"));
    };
    if !is_carrier_name(name) {
        return Err(unsafe_socket("not a carrier socket path"));
    }
    let directory =
        if parents.is_empty() { "/".to_owned() } else { format!("/{}", parents.join("/")) };
    // Every ancestor as written (symbolic links included) and as resolved is
    // owned by root or this user and, when others can write it, sticky.
    let real = std::fs::canonicalize(&directory).map_err(|_| unsafe_socket("no directory"))?;
    check_ancestors(&directory, uid)?;
    check_ancestors(&real.to_string_lossy(), uid)?;
    let dir = std::fs::symlink_metadata(&directory).map_err(|_| unsafe_socket("no directory"))?;
    if !dir.file_type().is_dir() {
        return Err(unsafe_socket("directory is not a directory"));
    }
    if dir.uid() != uid {
        return Err(unsafe_socket("directory has another owner"));
    }
    if dir.permissions().mode() & 0o077 != 0 {
        return Err(LinkError::OpenDirectory { path: directory, parent: false });
    }
    let socket = std::fs::symlink_metadata(path).map_err(|_| unsafe_socket("no socket"))?;
    if !socket.file_type().is_socket() {
        return Err(unsafe_socket("not a socket"));
    }
    if socket.uid() != uid {
        return Err(unsafe_socket("socket has another owner"));
    }
    Ok(())
}

/// Each proper ancestor of `directory`, from `/` down, without the directory
/// itself.
fn check_ancestors(directory: &str, uid: u32) -> Result<(), LinkError> {
    let parts: Vec<&str> = directory.split('/').filter(|part| !part.is_empty()).collect();
    let Some((_, ancestors)) = parts.split_last() else {
        return Ok(());
    };
    let mut prefix = String::new();
    for part in ancestors {
        prefix.push('/');
        prefix.push_str(part);
        let info = std::fs::symlink_metadata(Path::new(&prefix))
            .map_err(|_| unsafe_socket("no directory"))?;
        if info.uid() != 0 && info.uid() != uid {
            return Err(unsafe_socket("a parent has another owner"));
        }
        let mode = info.permissions().mode();
        if info.file_type().is_dir() && mode & 0o022 != 0 && mode & STICKY == 0 {
            return Err(LinkError::OpenDirectory { path: prefix, parent: true });
        }
    }
    Ok(())
}

/// `cmux-link-` + 12 lowercase hex digits + `.sock`.
pub(crate) fn is_carrier_name(name: &str) -> bool {
    let Some(hex) = name.strip_prefix("cmux-link-").and_then(|rest| rest.strip_suffix(".sock"))
    else {
        return false;
    };
    hex.len() == 12 && hex.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

#[cfg(test)]
#[path = "serve_policy_tests.rs"]
mod tests;
