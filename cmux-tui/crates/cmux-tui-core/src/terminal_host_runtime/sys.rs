//! Platform seams of the terminal-host runtime (cx-ko2e). Shared code names
//! these instead of a Unix type or call; each platform supplies the item
//! behind it. `sys/unix.rs` holds the Unix code; `sys/windows/` the Windows
//! code (GPUI lane). `windows_stubs` holds what Windows v1 does not have:
//! PTY custody, adopted sessions, signal breadcrumbs.

/// The host connection socket: the std Unix stream on Unix, and the same
/// AF_UNIX stream through uds_windows on Windows (the transport
/// `platform::transport` already uses there). Same API on both: clone,
/// shutdown, read/write timeouts.
#[cfg(unix)]
pub(crate) type HostStream = std::os::unix::net::UnixStream;
#[cfg(windows)]
pub(crate) type HostStream = uds_windows::UnixStream;

/// How `open_private` opens a record file. Creating opens give the file
/// owner-only access; the `NoFollow` kinds refuse a symlink at `path`.
#[derive(Clone, Copy, Debug)]
pub(crate) enum PrivateOpen {
    /// Read and write an existing file (the liveness lease probe).
    ExistingNoFollow,
    /// Create a new file; fail if it exists.
    CreateNew,
    CreateNewNoFollow,
    /// Create or truncate.
    TruncateNoFollow,
}

/// The result of a non-blocking try of a host's exclusive lease.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum LeaseProbe {
    /// Nobody holds it: the host that took it has ended.
    Free,
    /// A live process holds it.
    Held,
    /// The probe failed; no conclusion.
    Unknown,
}

/// A signal to a terminal's process groups (the ProcessTree seam).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum GroupSignal {
    /// A graceful hangup (SIGHUP on Unix).
    Hangup,
    /// An unconditional kill (SIGKILL on Unix).
    Kill,
}

#[cfg(unix)]
mod unix;
#[cfg(unix)]
pub(crate) use unix::*;

#[cfg(windows)]
pub(crate) use windows::host_runtime::{
    HostChild, adopt_launch, pty_poll_handle, wait_for_pty_readable_or_forced_drain,
};
#[cfg(windows)]
pub(crate) use windows::lease::*;
#[cfg(windows)]
pub(crate) use windows::listener::HostListener;
#[cfg(windows)]
pub(crate) use windows::seams::*;
#[cfg(windows)]
pub(crate) use windows::standby::{
    HostProcessStartFailed, SpawnedHostProcess, StandbyTerminalHost, host_bootstrap_streams,
};
#[cfg(windows)]
pub(crate) use windows_stubs::*;

/// The Windows system layer (cx-ko2e, GPUI lane): leases, endpoints, named
/// jobs, the host spawn, the listener and the ConPTY host runtime.
#[cfg(windows)]
pub(crate) mod windows;

#[cfg(windows)]
mod windows_stubs {
    use std::io;
    use std::path::Path;

    use super::HostStream;

    fn unsupported() -> io::Error {
        io::Error::new(
            io::ErrorKind::Unsupported,
            "terminal hosts are not implemented on this platform",
        )
    }

    /// Windows v1 hosts never hand over PTY custody (`supports_pty_custody:
    /// false`), so no value of this type exists there.
    pub(crate) enum PtyCustody {}

    /// Windows v1 hosts never hand over PTY custody, so a custody hello is
    /// refused.
    pub(crate) fn serve_pty_custody(
        _host: &super::super::shared::host_shared::HostShared,
        _stream: HostStream,
        _hello_frame: &super::super::Frame,
        _hello: &super::super::ClientHello,
        _response: &super::super::HostHello,
    ) -> anyhow::Result<()> {
        Err(unsupported().into())
    }

    /// Service-manager stop and signal breadcrumbs. Windows hosts install
    /// none yet.
    pub(crate) mod host_signals {
        use std::path::PathBuf;

        pub(crate) fn on_service_manager_stop(_terminate: Box<dyn Fn() + Send + Sync>) {}

        pub(crate) fn on_orphan_check(_orphaned: Box<dyn Fn() -> bool + Send + Sync>) {}

        pub(crate) fn set_breadcrumb_path(
            _path: PathBuf,
            _terminal_id: String,
            _incarnation: String,
        ) {
        }
    }

    /// Windows v1 hosts advertise no PTY custody in their records.
    pub(crate) const SUPPORTS_PTY_CUSTODY: bool = false;

    /// An adopted session id. Windows v1 adopts no session.
    pub(crate) enum SessionId {}

    pub(crate) fn remove_released_pty_lock(
        _record_path: &Path,
        _terminal_id: &str,
        _incarnation: &str,
    ) {
    }

    /// Windows hosts write no signal breadcrumbs yet.
    pub(crate) fn remove_terminal_loss_signals(_record_path: &Path) {}
}
