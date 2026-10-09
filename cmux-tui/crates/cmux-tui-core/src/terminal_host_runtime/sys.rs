//! Platform seams of the terminal-host runtime (cx-ko2e). Shared code names
//! these instead of a Unix type or call; each platform supplies the item
//! behind it. `sys/unix.rs` holds today's Unix code. The Windows items below
//! are fail-closed stubs until `sys/windows.rs` lands (GPUI lane); delete
//! them then.

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
pub(crate) use windows_stubs::*;

#[cfg(windows)]
mod windows_stubs {
    use std::fs::{File, Metadata};
    use std::io;
    use std::path::{Path, PathBuf};

    use super::{HostStream, LeaseProbe, PrivateOpen};

    fn unsupported() -> io::Error {
        io::Error::new(
            io::ErrorKind::Unsupported,
            "terminal hosts are not implemented on this platform",
        )
    }

    /// Windows v1 hosts never hand over PTY custody (`supports_pty_custody:
    /// false`), so no value of this type exists there.
    pub(crate) enum PtyCustody {}

    /// The host's process-lifetime liveness lease. Acquiring one fails
    /// until `sys/windows.rs`, so no value exists yet.
    pub(crate) struct HostLivenessLease {
        pub(crate) file: File,
        pub(crate) path: PathBuf,
    }

    impl HostLivenessLease {
        pub(crate) fn acquire(_path: PathBuf) -> anyhow::Result<Self> {
            Err(unsupported().into())
        }
    }

    /// An adopted session id. Windows v1 adopts no session.
    pub(crate) enum SessionId {}

    /// The accept-loop waker. Creating one fails until `sys/windows.rs`.
    pub(crate) struct AcceptWaker;

    impl AcceptWaker {
        pub(crate) fn new() -> io::Result<Self> {
            Err(unsupported())
        }

        pub(crate) fn wake(&self) {}

        pub(crate) fn drain(&self) {}
    }

    impl super::super::shared::host_shared::HostShared {
        /// Windows: Job Object termination arrives with `sys/windows.rs`.
        pub(crate) fn signal_terminal_process_groups(&self, _signal: super::GroupSignal) {}
    }

    /// No owner is ever read on Windows yet, so no value exists.
    #[derive(Clone, Copy)]
    pub(crate) enum FileOwner {}

    pub(crate) fn file_owner(_path: &Path) -> io::Result<FileOwner> {
        Err(unsupported())
    }

    pub(crate) fn is_private_file(_metadata: &Metadata, owner: FileOwner) -> bool {
        match owner {}
    }

    pub(crate) fn has_single_link(_metadata: &Metadata) -> bool {
        false
    }

    pub(crate) fn canonical_endpoint(owner: FileOwner, _terminal_id: &str) -> PathBuf {
        match owner {}
    }

    pub(crate) fn is_endpoint_file(_metadata: &Metadata) -> bool {
        false
    }

    pub(crate) fn open_private(_path: &Path, _how: PrivateOpen) -> io::Result<File> {
        Err(unsupported())
    }

    pub(crate) fn probe_lease(_file: &File) -> LeaseProbe {
        LeaseProbe::Unknown
    }

    pub(crate) fn process_definitely_gone(_pid: u32) -> bool {
        false
    }

    pub(crate) fn remove_released_pty_lock(
        _record_path: &Path,
        _terminal_id: &str,
        _incarnation: &str,
    ) {
    }

    /// Windows hosts write no signal breadcrumbs yet.
    pub(crate) fn remove_terminal_loss_signals(_record_path: &Path) {}

    pub(crate) fn sync_dir(_dir: &Path) -> io::Result<()> {
        Err(unsupported())
    }

    pub(crate) fn barrier_sync(_file: &File) -> io::Result<()> {
        Err(unsupported())
    }

    pub(crate) fn barrier_sync_dir(_dir: &Path) -> io::Result<()> {
        Err(unsupported())
    }

    pub(crate) fn rename_no_replace(_from: &Path, _to: &Path) -> io::Result<()> {
        Err(unsupported())
    }

    pub(crate) fn prepare_private_dir(_path: &Path) -> anyhow::Result<()> {
        Err(unsupported().into())
    }

    pub(crate) fn prepare_endpoint_dir(_path: &Path) -> anyhow::Result<()> {
        Err(unsupported().into())
    }

    /// A same-user connect (`local_socket::connect_same_user`) arrives with
    /// `sys/windows.rs`.
    pub(crate) fn connect_with_retry(_path: &Path) -> anyhow::Result<HostStream> {
        Err(unsupported().into())
    }
}
