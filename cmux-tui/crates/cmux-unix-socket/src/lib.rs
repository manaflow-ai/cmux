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
/// `<prefix><random>`, whatever `$TMPDIR` is. The directory and everything in
/// it are removed when the guard drops. `prefix` is cut to 8 characters.
#[cfg(feature = "test-support")]
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
        .expect("create a short test socket directory")
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn check_path_accepts_the_limit_and_names_a_longer_path() {
        let longest = "x".repeat(MAX_PATH_BYTES);
        assert!(fits(Path::new(&longest)));
        assert!(check_path(Path::new(&longest)).is_ok());
        let too_long = format!("/{}", "y".repeat(MAX_PATH_BYTES));
        let error = check_path(Path::new(&too_long)).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
        let message = error.to_string();
        assert!(message.contains(&too_long), "{message}");
        assert!(message.contains(&format!("{} bytes", MAX_PATH_BYTES + 1)), "{message}");
        assert!(message.contains(&MAX_PATH_BYTES.to_string()), "{message}");
    }
}
