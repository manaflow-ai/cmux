//! Where the router's admin socket is: the one rule the router (it binds the
//! socket), acpmux (it starts, adopts and asks the router) and the cmux app
//! (Swift `LocalRouterClient.socketPath(acpmuxHome:uid:)`) share.
//!
//! `<home>/router/router.sock` when that path fits a Unix socket address
//! ([`MAX_SOCKET_PATH_BYTES`]); else `/tmp/acpmux-<uid>/<fnv1a64(home)>-router.sock`,
//! in the private per-user folder where the acpmux daemon socket of a long home
//! also is (cmux-agent-pane-policy `environment::socket_path`). The name is
//! derived from the home path, so every side gets the same path with no file
//! to read. A socket path past the limit cannot be bound or reached: macOS's
//! Network framework traps on one (cx-8iw6m).

use std::path::{Path, PathBuf};

/// The longest Unix socket path every host binds: macOS's `sun_path` (104
/// bytes) less its NUL (cmux-agent-pane-policy `MAX_SOCKET_PATH_BYTES`).
pub const MAX_SOCKET_PATH_BYTES: usize = 103;

/// The router admin socket of the acpmux home `home` (see the module docs).
/// Where the short folder cannot be used (it is not a folder that only this
/// user owns and can enter), the long path stays: binding or reaching it then
/// fails with a clear error instead of a socket in a folder another user controls.
pub fn admin_socket_path(home: &Path) -> PathBuf {
    #[cfg(unix)]
    {
        if let Some(short) = short_admin_socket_path(home) {
            return short;
        }
    }
    home.join("router").join("router.sock")
}

/// [`admin_socket_path`] from async code: the short folder's create and stat
/// run as a `cmux_blocking::spawn_blocking` task (Chrome's `MayBlock()` task,
/// base/task/task_traits.h), never on the thread that runs the caller.
pub(crate) async fn admin_socket_path_async(home: &Path) -> std::io::Result<PathBuf> {
    let home = home.to_owned();
    cmux_blocking::spawn_blocking(move || admin_socket_path(&home))
        .await
        .map_err(std::io::Error::other)
}

/// The short path for a home whose `router/router.sock` is past the limit;
/// None when the preferred path fits or the short folder is not private.
#[cfg(unix)]
fn short_admin_socket_path(home: &Path) -> Option<PathBuf> {
    use std::os::unix::ffi::OsStrExt;
    if home.join("router").join("router.sock").as_os_str().len() <= MAX_SOCKET_PATH_BYTES {
        return None;
    }
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    let dir = PathBuf::from(format!("/tmp/acpmux-{uid}"));
    if !private_dir(&dir, uid) {
        return None;
    }
    let name = format!("{:016x}-router.sock", fnv1a64(home.as_os_str().as_bytes()));
    Some(dir.join(name))
}

/// Create `dir` mode 0700 if missing; true only when it is a real folder
/// owned by `uid` that nobody else can enter (acpmux `config::private_dir`).
/// Blocks on the file system: async code uses [`admin_socket_path_async`].
#[cfg(unix)]
fn private_dir(dir: &Path, uid: u32) -> bool {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt};
    let _ = cmux_threads::checked::fs::create_dir_with(std::fs::DirBuilder::new().mode(0o700), dir);
    match cmux_blocking::fs::symlink_metadata(dir) {
        Ok(m) => m.is_dir() && m.uid() == uid && m.mode() & 0o077 == 0,
        Err(_) => false,
    }
}

/// FNV-1a 64 of the home path's bytes, as the acpmux daemon socket alias.
#[cfg(unix)]
fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    /// A home long enough for the short path: its private folder is made and
    /// checked on the blocking pool, not on the thread driving the runtime
    /// (cmux_blocking's block_on disallows blocking there; a file call left
    /// there panics in debug and counts as stalled).
    #[test]
    fn the_short_path_folder_is_checked_off_the_runtime_thread() {
        let runtime = cmux_blocking::runtime::current_thread().build().unwrap();
        let home = Path::new("/nonexistent-coderouter-home").join("h".repeat(120));
        let stalled = cmux_blocking::counts().stalled;

        let path =
            cmux_blocking::runtime::block_on(&runtime, admin_socket_path_async(&home)).unwrap();

        assert_eq!(cmux_blocking::counts().stalled, stalled);
        assert_eq!(path, admin_socket_path(&home));
        assert!(path.as_os_str().len() <= MAX_SOCKET_PATH_BYTES, "{}", path.display());
    }
}
