//! Where a Windows terminal host listens (EndpointPolicy): one owner-only
//! directory per user under the per-user temp folder,
//! `%TEMP%\cmux-th-<USERNAME>\<terminal_hex>.sock`, made and checked by
//! `cmux::local_socket` (`listen`: owner-only protected DACL, the socket
//! file's owner set to the token user; `connect_same_user`: that owner is
//! ours). Unix uses `/tmp/cmux-th-<uid>/<terminal_hex>.sock`.

use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The B1 seam (`terminal_host_runtime/sys.rs`): `uds_windows::UnixStream`
/// on Windows, the type `cmux::local_socket` returns.
pub(crate) use super::super::HostStream;
pub use cmux::local_socket::Listener as HostListener;

/// The endpoint directory for `user` under `temp`.
pub fn endpoint_dir_in(temp: &Path, user: &str) -> PathBuf {
    temp.join(format!("cmux-th-{}", sanitize(user)))
}

/// This user's endpoint directory.
pub fn endpoint_dir() -> PathBuf {
    endpoint_dir_in(
        &std::env::temp_dir(),
        &std::env::var("USERNAME").unwrap_or_else(|_| "user".into()),
    )
}

/// The socket of terminal `terminal_hex` (32 lowercase hex digits).
pub fn endpoint_path_in(dir: &Path, terminal_hex: &str) -> Option<PathBuf> {
    is_terminal_hex(terminal_hex).then(|| dir.join(format!("{terminal_hex}.sock")))
}

/// Whether a record's endpoint is exactly where this user's host for
/// `terminal_hex` listens (record validation; a record naming any other
/// path is refused).
pub fn endpoint_matches(dir: &Path, terminal_hex: &str, endpoint: &Path) -> bool {
    endpoint_path_in(dir, terminal_hex).is_some_and(|want| same_path(&want, endpoint))
}

/// The host side: binds terminal `terminal_hex`'s socket in `dir`, made or
/// checked owner-only by `cmux::local_socket::listen`, with our token user
/// as the socket file's owner; its `accept` refuses another user, below
/// Medium integrity and AppContainer peers. A leftover socket file of ours
/// (a host that died) is removed first; one owned by anyone else is refused.
pub fn bind(dir: &Path, terminal_hex: &str) -> io::Result<(PathBuf, HostListener)> {
    let path = endpoint_path_in(dir, terminal_hex).ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, format!("not a terminal id: {terminal_hex}"))
    })?;
    if path.exists() {
        let me = cmux::local_socket::win::current_identity()?;
        let owner = cmux::local_socket::win::owner_of(&path)?;
        cmux::local_socket::owner_allowed(&owner, &me.user_sid).map_err(|refusal| {
            io::Error::new(
                io::ErrorKind::PermissionDenied,
                format!("{refusal}: {}", path.display()),
            )
        })?;
        std::fs::remove_file(&path)?;
    }
    let listener = cmux::local_socket::listen(&path)?;
    Ok((path, listener))
}

/// The daemon side: connects to a record's endpoint only when it is exactly
/// this user's endpoint for `terminal_hex` and the socket file's owner is our
/// token user (`connect_same_user`), retrying a host still starting until
/// `timeout`.
pub fn connect_record(
    dir: &Path,
    terminal_hex: &str,
    endpoint: &Path,
    timeout: Duration,
) -> io::Result<HostStream> {
    if !endpoint_matches(dir, terminal_hex, endpoint) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "host endpoint {} is not this user's endpoint for {terminal_hex}",
                endpoint.display()
            ),
        ));
    }
    cmux::local_socket::connect_with_deadline(endpoint, timeout, Duration::from_millis(25), || {
        Ok(())
    })
}

fn is_terminal_hex(value: &str) -> bool {
    value.len() == 32 && value.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// A user name as one path component: no separators, no `..`, no drive
/// colon; anything else is kept (Windows names are case-insensitive).
fn sanitize(user: &str) -> String {
    let cleaned: String = user
        .chars()
        .map(|c| if matches!(c, '\\' | '/' | ':' | '.' | '\0') { '_' } else { c })
        .collect();
    if cleaned.is_empty() { "user".into() } else { cleaned }
}

/// Windows paths compare case-insensitively, with either separator.
fn same_path(a: &Path, b: &Path) -> bool {
    let norm = |p: &Path| p.to_string_lossy().replace('/', "\\").to_lowercase();
    norm(a) == norm(b)
}
