//! Where the session daemon's remote entry listens: a separate socket next
//! to the session's local socket. The link connects only to this path; it
//! never connects to the local socket, which carries local-admin trust.

use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

/// The suffix that names a remote entry socket.
pub const ENTRY_SUFFIX: &str = ".link.sock";

/// The remote entry socket for the session listening on `session_socket`:
/// `<dir>/<stem>.link.sock`, or `<dir>/<hash>.link.sock` when that would not
/// fit a Unix socket path. Never equal to `session_socket`.
pub fn remote_entry_socket_path(session_socket: &Path) -> PathBuf {
    let directory = session_socket.parent().unwrap_or_else(|| Path::new("."));
    let stem = session_socket
        .file_stem()
        .map(|stem| stem.to_string_lossy().into_owned())
        .unwrap_or_default();
    let preferred = directory.join(format!("{stem}{ENTRY_SUFFIX}"));
    if fits(&preferred) {
        return preferred;
    }
    let digest = Sha256::digest(session_socket.as_os_str().as_encoded_bytes());
    let short: String = digest.iter().take(8).map(|byte| format!("{byte:02x}")).collect();
    directory.join(format!("{short}{ENTRY_SUFFIX}"))
}

/// True when `path` fits the smallest `sun_path` we support (macOS, 104
/// bytes with the NUL).
fn fits(path: &Path) -> bool {
    path.as_os_str().as_encoded_bytes().len() <= 103
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_entry_sits_next_to_the_session_socket_and_never_on_it() {
        let session = Path::new("/tmp/cmux-501/main.sock");
        let entry = remote_entry_socket_path(session);
        assert_eq!(entry, Path::new("/tmp/cmux-501/main.link.sock"));
        assert_ne!(entry, session);
    }

    #[test]
    fn a_long_session_path_gets_a_short_hashed_entry_in_the_same_directory() {
        let directory = format!("/tmp/{}", "d".repeat(70));
        let session = PathBuf::from(format!("{directory}/{}.sock", "s".repeat(30)));
        let entry = remote_entry_socket_path(&session);
        assert!(fits(&entry), "{}", entry.display());
        assert_eq!(entry.parent(), session.parent());
        assert!(entry.to_string_lossy().ends_with(ENTRY_SUFFIX));
    }
}
