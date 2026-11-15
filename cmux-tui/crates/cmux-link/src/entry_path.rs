//! Where the session daemon's remote entry listens: a separate socket next
//! to the session's local socket. The link connects only to this path; it
//! never connects to the local socket, which carries local-admin trust.

use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

/// The directory, next to the session sockets, that holds remote entry
/// sockets. Session sockets are `<dir>/<name>.sock` files, so no session
/// name can produce a path inside it.
pub const ENTRY_DIR: &str = "link-entry";

/// The first line the remote entry writes to a verified link, before it
/// reads the stamp. The link splices a peer stream only after it reads
/// exactly this line, so a socket that is not a remote entry (a session's
/// local admin socket) never receives a peer's bytes.
pub const ENTRY_BANNER: &str = r#"{"remote_entry":1}"#;

/// The remote entry socket for the session listening on `session_socket`:
/// `<dir>/link-entry/<stem>.sock`, or `<dir>/link-entry/<hash>.sock` when
/// that would not fit a Unix socket path. Never a session socket.
pub fn remote_entry_socket_path(session_socket: &Path) -> PathBuf {
    let directory = session_socket.parent().unwrap_or_else(|| Path::new(".")).join(ENTRY_DIR);
    let stem = session_socket
        .file_stem()
        .map(|stem| stem.to_string_lossy().into_owned())
        .unwrap_or_default();
    let preferred = directory.join(format!("{stem}.sock"));
    if fits(&preferred) {
        return preferred;
    }
    let digest = Sha256::digest(session_socket.as_os_str().as_encoded_bytes());
    let short: String = digest.iter().take(8).map(|byte| format!("{byte:02x}")).collect();
    directory.join(format!("{short}.sock"))
}

/// True when `path` fits the smallest `sun_path` we support (macOS, 104
/// bytes with the NUL).
fn fits(path: &Path) -> bool {
    path.as_os_str().as_encoded_bytes().len() <= 103
}

#[cfg(test)]
mod tests;
