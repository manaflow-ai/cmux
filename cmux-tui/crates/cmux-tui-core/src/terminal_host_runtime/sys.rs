//! Platform seams of the terminal-host runtime (cx-ko2e). Shared code names
//! these instead of a Unix type; each platform supplies the type behind it.

/// The host connection socket: the std Unix stream on Unix, and the same
/// AF_UNIX stream through uds_windows on Windows (the transport
/// `platform::transport` already uses there). Same API on both: clone,
/// shutdown, read/write timeouts.
#[cfg(unix)]
pub(crate) type HostStream = std::os::unix::net::UnixStream;
#[cfg(windows)]
pub(crate) type HostStream = uds_windows::UnixStream;

/// The owner's copy of a host's PTY master (`unix/pty_custody.rs`). Windows
/// v1 hosts never hand over PTY custody (`supports_pty_custody: false`), so
/// no value of this type exists there.
#[cfg(unix)]
pub(crate) use super::unix::PtyCustody;
#[cfg(windows)]
pub(crate) enum PtyCustody {}

// Host and exit records: the Unix code owns them until the records group
// moves behind the PrivateFs seam (cx-ko2e table B). On Windows these are
// stubs until `sys/windows.rs` lands.
#[cfg(unix)]
pub(crate) use super::unix::{
    acknowledge_terminal_host_exit_record, terminal_host_exit_record, write_record,
};

#[cfg(windows)]
pub(crate) fn write_record(
    _path: &std::path::Path,
    _record: &super::TerminalHostRecord,
) -> anyhow::Result<()> {
    anyhow::bail!("terminal-host records are not implemented on this platform")
}

#[cfg(windows)]
pub(crate) fn terminal_host_exit_record(
    _host_record_path: &std::path::Path,
) -> anyhow::Result<Option<(std::path::PathBuf, super::TerminalHostExitRecord)>> {
    anyhow::bail!("terminal-host exit records are not implemented on this platform")
}

#[cfg(windows)]
pub(crate) fn acknowledge_terminal_host_exit_record(
    _record_path: &std::path::Path,
    _expected: &super::TerminalHostExitRecord,
) -> anyhow::Result<bool> {
    anyhow::bail!("terminal-host exit records are not implemented on this platform")
}

/// Connect to a host endpoint. Hosts run as this user, so a listener
/// owned by anyone else never receives the owner capability.
#[cfg(unix)]
pub(crate) fn connect_with_retry(path: &std::path::Path) -> anyhow::Result<HostStream> {
    use std::time::Instant;

    use super::{HOST_CONNECT_RETRY_INTERVAL, HOST_CONNECT_RETRY_WINDOW};

    let deadline = Instant::now() + HOST_CONNECT_RETRY_WINDOW;
    loop {
        match HostStream::connect(path) {
            Ok(stream) => {
                crate::platform::require_unix_peer_uid(&stream, crate::platform::effective_uid())?;
                return Ok(stream);
            }
            Err(error) => {
                let now = Instant::now();
                if now >= deadline {
                    return Err(error.into());
                }
                std::thread::sleep(HOST_CONNECT_RETRY_INTERVAL.min(deadline - now));
            }
        }
    }
}

/// Windows: a same-user connect (`local_socket::connect_same_user`) arrives
/// with `sys/windows.rs`.
#[cfg(windows)]
pub(crate) fn connect_with_retry(_path: &std::path::Path) -> anyhow::Result<HostStream> {
    anyhow::bail!("terminal-host connections are not implemented on this platform")
}
