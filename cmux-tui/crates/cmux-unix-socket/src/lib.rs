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

/// Private Unix socket descriptor transfers.
#[cfg(unix)]
pub mod descriptor;

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
/// `<prefix><random>`, whatever `$TMPDIR` is, and owner-only (mode 700) whatever
/// the caller's umask is. The directory and everything in
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
    let mut builder = tempfile::Builder::new();
    builder.prefix(&prefix);
    // Owner-only whatever the caller's umask: the stores and daemons under test refuse a folder
    // that group or others may write.
    #[cfg(unix)]
    builder.permissions(std::os::unix::fs::PermissionsExt::from_mode(0o700));
    builder
        .tempdir_in(root)
        // crash-allow: test-support only (dev-dependencies); a test without its socket directory must fail
        .expect("create a short test socket directory")
}

#[cfg(all(test, unix, feature = "test-support"))]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn a_test_directory_is_owner_only() {
        let directory = super::short_test_dir("private-");
        let mode = std::fs::metadata(directory.path()).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o700, "mode {mode:o}");
    }

    /// A caller's umask of 002 (a lane VM's default) made every test directory group-writable,
    /// and the stores and daemons that refuse such a folder failed their tests for that alone.
    #[test]
    fn a_callers_group_writable_umask_does_not_reach_a_test_directory() {
        let exe = std::env::current_exe().unwrap();
        let status = std::process::Command::new("/bin/sh")
            .args(["-c", r#"umask 002; exec "$0" "$@""#])
            .arg(&exe)
            .args(["--exact", "tests::a_test_directory_is_owner_only"])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap();
        assert!(status.success(), "the directory was not owner-only under umask 002: {status}");
    }
}
