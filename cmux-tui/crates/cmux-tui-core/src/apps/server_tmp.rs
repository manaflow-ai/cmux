//! The temporary directory of an app's server, which is also the folder of
//! its local sockets (`socket_dir` of `cmux.host.link.get`; cx-wmd8x).
//!
//! A unix socket path is at most 104 bytes on macOS (`sun_path`, with its
//! NUL). The Cloud app's link socket is `<socket_dir>/cmux-link-<12 hex>.sock`
//! (27 bytes after the folder), so the Cloud server refuses a `socket_dir`
//! longer than [`MAX_SOCKET_DIR`] (first-party-apps/cloud/server/src/link/
//! config.rs). The old `<state>/apps-tmp/<namespace>` under
//! `~/Library/Application Support` is 99 to 116 bytes on macOS, so:
//!
//! - macOS: `<per-user temp dir>/cmux-apps/<12 hex>`. The per-user temp dir
//!   comes from `confstr(_CS_DARWIN_USER_TEMP_DIR)` only (never `$TMPDIR`)
//!   and must have the system's shape `/var/folders/<2>/<id>/T/` (the id 20
//!   to 40 characters; 30 on every Mac measured, a 49-byte root and a 71-byte
//!   folder). Anything else refuses, and so does a folder over
//!   [`MAX_SOCKET_DIR`] (with its length).
//! - Other unix: the old path when it fits; else `$XDG_RUNTIME_DIR/cmux-apps/
//!   <12 hex>` when that runtime dir is the user's own 0700 folder; else a
//!   refusal.
//!
//! The 12 hex are the first 6 bytes of sha256(`<state base>\0<namespace>`):
//! one folder per daemon instance and app.
//!
//! The folder is a trust boundary (other processes of the user must not put a
//! socket or a file where the app's server takes it as its own). On every use
//! the folder and its parent must be real directories (not symlinks, read
//! with lstat), owned by this uid, with no group or other access; anything
//! else refuses. Nothing is chmod-repaired or reused after a failed check.

use std::os::unix::fs::{DirBuilderExt, MetadataExt};
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

/// `sun_path` is 104 bytes on macOS; the link socket adds 27 after the folder.
pub(super) const MAX_SOCKET_DIR: usize = 104 - 1 - 27;

/// The per-user id of the macOS temp dir: 30 characters on every Mac measured
/// (macOS 26, 27); a range, so a different length the system may use never
/// refuses every Mac again (cx-wmd8x shipped an exact 28). The runtime
/// [`MAX_SOCKET_DIR`] check bounds the result.
#[cfg(target_os = "macos")]
const DARWIN_ID_LEN: std::ops::RangeInclusive<usize> = 20..=40;

fn short_name(base: &Path, namespace: &str) -> String {
    use std::os::unix::ffi::OsStrExt;
    let mut seed = base.as_os_str().as_bytes().to_vec();
    seed.push(0);
    seed.extend_from_slice(namespace.as_bytes());
    Sha256::digest(&seed).iter().take(6).map(|b| format!("{b:02x}")).collect()
}

fn fits(path: &Path) -> Result<(), String> {
    let len = path.as_os_str().len();
    if len > MAX_SOCKET_DIR {
        return Err(format!(
            "the app socket folder {} is {len} bytes; at most {MAX_SOCKET_DIR} fit a socket path",
            path.display()
        ));
    }
    Ok(())
}

/// The per-user temp dir from `confstr(_CS_DARWIN_USER_TEMP_DIR)`, checked
/// against the system's shape.
#[cfg(target_os = "macos")]
fn darwin_user_temp() -> Result<PathBuf, String> {
    let mut buf = [0u8; 1024];
    // SAFETY: confstr writes at most buf.len() bytes, NUL included, into our buffer.
    let n = unsafe {
        libc::confstr(libc::_CS_DARWIN_USER_TEMP_DIR, buf.as_mut_ptr().cast(), buf.len())
    };
    if n == 0 || n > buf.len() {
        return Err("the per-user temp dir is not available (confstr)".into());
    }
    let text = std::str::from_utf8(&buf[..n - 1])
        .map_err(|_| "the per-user temp dir is not UTF-8".to_string())?;
    let parts: Vec<&str> = text.split('/').collect();
    let id_char = |c: char| c.is_ascii_alphanumeric() || c == '_' || c == '+' || c == '-';
    let shaped = parts.len() == 7
        && parts[0].is_empty()
        && parts[1] == "var"
        && parts[2] == "folders"
        && parts[3].len() == 2
        && DARWIN_ID_LEN.contains(&parts[4].len())
        && parts[5] == "T"
        && parts[6].is_empty()
        && parts[3].chars().chain(parts[4].chars()).all(id_char);
    if !shaped {
        return Err(format!(
            "the per-user temp dir {text:?} does not have the system's shape; no app socket folder"
        ));
    }
    Ok(PathBuf::from(text.trim_end_matches('/')))
}

/// The app server's temporary (and socket) folder for `namespace`, whose
/// old location under the daemon state base `base` is `<base>/apps-tmp/<ns>`.
pub(super) fn server_tmp_dir(base: &Path, namespace: &str) -> Result<PathBuf, String> {
    #[cfg(target_os = "macos")]
    {
        let root = darwin_user_temp()?;
        private_dir(&root, "the per-user temp dir")?;
        let dir = root.join("cmux-apps").join(short_name(base, namespace));
        fits(&dir)?;
        Ok(dir)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let old = base.join("apps-tmp").join(namespace);
        if fits(&old).is_ok() {
            return Ok(old);
        }
        let runtime =
            std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).filter(|p| p.is_absolute());
        let Some(runtime) = runtime else {
            return fits(&old).map(|()| old);
        };
        private_dir(&runtime, "the runtime dir")?;
        let dir = runtime.join("cmux-apps").join(short_name(base, namespace));
        fits(&dir)?;
        Ok(dir)
    }
}

/// `path` is a real directory (lstat: not a symlink) owned by this uid, with
/// no group or other access.
pub(super) fn private_dir(path: &Path, what: &str) -> Result<(), String> {
    let meta =
        std::fs::symlink_metadata(path).map_err(|e| format!("{what} {}: {e}", path.display()))?;
    if meta.file_type().is_symlink() || !meta.is_dir() {
        return Err(format!("{what} {} is not a real directory", path.display()));
    }
    // SAFETY: geteuid has no preconditions.
    let uid = unsafe { libc::geteuid() };
    if meta.uid() != uid {
        return Err(format!("{what} {} belongs to another user", path.display()));
    }
    if meta.mode() & 0o077 != 0 {
        return Err(format!(
            "{what} {} is open to other users (mode {:o})",
            path.display(),
            meta.mode() & 0o777
        ));
    }
    Ok(())
}

/// Checks an existing folder and its parent (`cmux.host.link.get`).
pub(super) fn check_server_tmp(dir: &Path) -> Result<(), String> {
    let parent = dir
        .parent()
        .ok_or_else(|| format!("the app socket folder {} has no parent", dir.display()))?;
    private_dir(parent, "the app socket folders' parent")?;
    private_dir(dir, "the app socket folder")
}

/// At server start: the parent made (0700) or checked, an existing folder
/// checked before it is emptied, then a fresh 0700 folder, checked again.
pub(super) fn fresh_server_tmp(dir: &Path) -> Result<(), String> {
    let parent = dir
        .parent()
        .ok_or_else(|| format!("the app socket folder {} has no parent", dir.display()))?;
    match std::fs::symlink_metadata(parent) {
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            std::fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(parent)
                .map_err(|e| format!("app socket folders' parent {}: {e}", parent.display()))?;
        }
        Err(e) => return Err(format!("app socket folders' parent {}: {e}", parent.display())),
    }
    private_dir(parent, "the app socket folders' parent")?;
    match std::fs::symlink_metadata(dir) {
        Ok(_) => {
            // Never empty a folder another user or a symlink put there.
            private_dir(dir, "the app socket folder")?;
            std::fs::remove_dir_all(dir)
                .map_err(|e| format!("app socket folder {}: {e}", dir.display()))?;
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(format!("app socket folder {}: {e}", dir.display())),
    }
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(dir)
        .map_err(|e| format!("app socket folder {}: {e}", dir.display()))?;
    private_dir(dir, "the app socket folder")
}

/// When the server ends or the app goes: the folder goes, only if it is ours.
pub(super) fn remove_server_tmp(dir: &Path) {
    if private_dir(dir, "the app socket folder").is_ok() {
        let _ = std::fs::remove_dir_all(dir);
    }
}

/// The real per-user temp dir of this Mac (confstr) has the expected shape, and
/// its app socket folder fits the link socket (cx-wmd8x: the shape check once
/// refused every Mac and no test ran on one).
#[cfg(all(test, target_os = "macos"))]
mod macos_tests {
    #[test]
    fn this_macs_temp_dir_gives_a_socket_folder_that_fits() {
        let root =
            super::darwin_user_temp().expect("this Mac's confstr temp dir has the system's shape");
        let dir = super::server_tmp_dir(std::path::Path::new("/tmp/state"), "cmux.linked")
            .expect("this Mac's app socket folder fits");
        assert!(dir.starts_with(&root), "{}", dir.display());
        assert!(dir.as_os_str().len() <= super::MAX_SOCKET_DIR, "{}", dir.display());
        println!("socket folder {} ({} bytes)", dir.display(), dir.as_os_str().len());
    }
}
