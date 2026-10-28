//! Unix socket path rules shared by every cmux crate.
//!
//! A filesystem Unix socket path must fit `sockaddr_un.sun_path` with its
//! trailing NUL: 104 bytes on macOS, 108 on Linux. A path that does not fit
//! makes `bind` and `connect` fail with an error that names neither the path
//! nor the limit. [`check_path`] runs first and says both.
//!
//! Tests must not put sockets under `$TMPDIR`: on macOS it is a
//! `/var/folders/...` path of about 50 bytes. [`short_test_dir`] (feature
//! `test-support`) gives a short directory under the canonical `/tmp`.

// The crash ratchet keeps this crate at zero production panics
// (plans/cmux-next/crash-elimination.md section 6).
#![cfg_attr(
    not(test),
    deny(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::unreachable,
        clippy::todo,
        clippy::unimplemented,
        clippy::exit
    )
)]
#![forbid(unsafe_code)]

use std::io;
use std::path::Path;

/// The size of `sun_path`, including the trailing NUL.
#[cfg(unix)]
pub const SUN_PATH_CAPACITY: usize =
    std::mem::size_of::<libc::sockaddr_un>() - std::mem::offset_of!(libc::sockaddr_un, sun_path);

/// The longest socket path in bytes, without the trailing NUL.
#[cfg(unix)]
pub const MAX_PATH_BYTES: usize = SUN_PATH_CAPACITY - 1;

/// True when `path` fits `sun_path`.
#[cfg(unix)]
pub fn fits(path: &Path) -> bool {
    use std::os::unix::ffi::OsStrExt;
    path.as_os_str().as_bytes().len() <= MAX_PATH_BYTES
}

/// `Ok` when `path` fits `sun_path`; otherwise an `InvalidInput` error that
/// names the path, its length and the limit. Call it before `bind` and
/// `connect` on a path that came from configuration or arguments.
#[cfg(unix)]
pub fn check_path(path: &Path) -> io::Result<()> {
    use std::os::unix::ffi::OsStrExt;
    let length = path.as_os_str().as_bytes().len();
    if length <= MAX_PATH_BYTES {
        return Ok(());
    }
    Err(io::Error::new(
        io::ErrorKind::InvalidInput,
        format!(
            "socket path is {length} bytes, longer than the {MAX_PATH_BYTES}-byte Unix socket limit; use a shorter path: {}",
            path.display()
        ),
    ))
}

/// `UnixListener::bind` after [`check_path`]: a path longer than sun_path
/// fails with the path and the limit, never a bare bind error.
#[cfg(unix)]
pub fn bind(path: &Path) -> io::Result<std::os::unix::net::UnixListener> {
    check_path(path)?;
    std::os::unix::net::UnixListener::bind(path)
}

/// Binds `path` so that the socket is never reachable with a wider mode than
/// owner read and write (0600): the socket is bound in a new owner-only
/// (0700) directory beside `path`, set to 0600 there, and then renamed onto
/// `path` (which replaces a stale socket file there). A socket bound in place
/// and then chmod-ed has the umask's mode until the chmod, and a peer can
/// connect in that window. The caller checks that no live server owns `path`
/// first.
#[cfg(unix)]
pub fn bind_private(path: &Path) -> io::Result<std::os::unix::net::UnixListener> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    check_path(path)?;
    let parent = path.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or(Path::new("."));
    let name = path.file_name().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("no socket file name in {}", path.display()),
        )
    })?;
    // A short sibling name, so the staged path fits when `path` does.
    let staging = parent.join(format!(".s{:x}", std::process::id() ^ unique()));
    std::fs::DirBuilder::new().mode(0o700).create(&staging)?;
    let staged = staging.join(name);
    let result = (|| {
        check_path(&staged)?;
        let listener = std::os::unix::net::UnixListener::bind(&staged)?;
        std::fs::set_permissions(&staged, std::fs::Permissions::from_mode(0o600))?;
        std::fs::rename(&staged, path)?;
        Ok(listener)
    })();
    let _ = std::fs::remove_file(&staged);
    let _ = std::fs::remove_dir(&staging);
    result
}

/// A per-call number for staging names (time and a counter).
#[cfg(unix)]
fn unique() -> u32 {
    use std::sync::atomic::{AtomicU32, Ordering};
    static NEXT: AtomicU32 = AtomicU32::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.subsec_nanos());
    nanos ^ NEXT.fetch_add(1, Ordering::Relaxed).rotate_left(16)
}

/// `UnixStream::connect` after [`check_path`].
#[cfg(unix)]
pub fn connect(path: &Path) -> io::Result<std::os::unix::net::UnixStream> {
    check_path(path)?;
    std::os::unix::net::UnixStream::connect(path)
}

/// Non-Unix platforms have no `sun_path`; every path is accepted.
#[cfg(not(unix))]
pub fn check_path(_path: &Path) -> io::Result<()> {
    Ok(())
}

/// The guard [`short_test_dir`] returns.
#[cfg(feature = "test-support")]
pub use tempfile::TempDir as TestDir;

/// A new directory for test sockets under the canonical `/tmp`
/// (`/private/tmp` on macOS, so symlinked-directory checks accept it), named
/// `<prefix><random>`, whatever `$TMPDIR` is. The directory and everything in
/// it are removed when the guard drops. `prefix` is cut to 8 characters.
///
/// Test support only: every dependent enables `test-support` from
/// `[dev-dependencies]`, so no production build contains this function. A
/// test that cannot make its socket directory fails here.
#[cfg(feature = "test-support")]
#[allow(
    clippy::expect_used,
    reason = "test-support only: no production build contains this function"
)]
pub fn short_test_dir(prefix: &str) -> TestDir {
    let prefix: String = prefix.chars().take(8).collect();
    let root = if cfg!(unix) {
        std::fs::canonicalize("/tmp").unwrap_or_else(|_| std::env::temp_dir())
    } else {
        std::env::temp_dir()
    };
    tempfile::Builder::new()
        .prefix(&prefix)
        .tempdir_in(root)
        // crash-allow: test-support only (dev-dependencies); a test without its socket directory must fail
        .expect("create a short test socket directory")
}
