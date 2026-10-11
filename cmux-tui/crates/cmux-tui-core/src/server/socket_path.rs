//! Session socket paths: name validation and the runtime-directory socket
//! each session listens on (moved out of server.rs, behavior unchanged).

use super::*;

/// Validate the component used to identify a local session.
///
/// Session names become socket file names. Keep legacy names that are still a
/// single path component, but reject values that can escape the socket root or
/// carry control and line-separator characters.
pub fn validate_session_name(session: &str) -> anyhow::Result<()> {
    let invalid = session.is_empty()
        || matches!(session, "." | "..")
        || session.chars().any(|character| {
            character == '/'
                || character == '\\'
                || character == '\0'
                || character.is_control()
                || matches!(character, '\u{0085}' | '\u{2028}' | '\u{2029}')
        });
    anyhow::ensure!(
        !invalid,
        "session name must be a non-empty path component without separators or control characters"
    );
    Ok(())
}

/// Default socket path for a session.
pub fn default_socket_path(session: &str) -> PathBuf {
    match try_default_socket_path(session) {
        Ok(path) => path,
        Err(_) => invalid_session_socket_path(session),
    }
}

/// Resolve a session socket path and report invalid input before any path use.
pub fn try_default_socket_path(session: &str) -> anyhow::Result<PathBuf> {
    validate_session_name(session)?;
    Ok(default_socket_path_in_runtime_dir(session, platform::runtime_dir()))
}

/// The socket `session` listens on when its owner runs with `TMPDIR=base`
/// and no `XDG_RUNTIME_DIR` (how the cmux app starts its session).
pub fn try_default_socket_path_in_base(session: &str, base: &Path) -> anyhow::Result<PathBuf> {
    validate_session_name(session)?;
    Ok(default_socket_path_in_runtime_dir(session, platform::runtime_dir_for_base(base)))
}

fn invalid_session_socket_path(session: &str) -> PathBuf {
    let digest = format!("{:x}", Sha256::digest(session.as_bytes()));
    platform::invalid_runtime_dir().join(format!("{digest}.sock"))
}

pub(super) fn default_socket_path_in_runtime_dir(session: &str, runtime_dir: PathBuf) -> PathBuf {
    let file_name = format!("{session}.sock");
    let preferred = runtime_dir.join(&file_name);
    #[cfg(unix)]
    if !unix_socket_path_fits(&preferred) {
        let fallback = platform::fallback_runtime_dir().join(&file_name);
        if unix_socket_path_fits(&fallback) {
            return fallback;
        }
        let digest = format!("{:x}", Sha256::digest(session.as_bytes()));
        let preferred_base = runtime_dir.parent().unwrap_or_else(|| Path::new("/tmp"));
        let hashed =
            platform::hashed_runtime_dir_for_base(preferred_base).join(format!("{digest}.sock"));
        if unix_socket_path_fits(&hashed) {
            return hashed;
        }
        return platform::fallback_hashed_runtime_dir().join(format!("{digest}.sock"));
    }
    preferred
}

#[cfg(unix)]
pub(crate) fn unix_socket_path_fits(path: &Path) -> bool {
    cmux_unix_socket::fits(path)
}
