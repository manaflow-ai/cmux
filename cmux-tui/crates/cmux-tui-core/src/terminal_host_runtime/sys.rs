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

    /// A host process started ahead of its terminal: the process and its
    /// bootstrap pipes (the launch code uses them only through Read and
    /// Write). Spawning one fails until `sys/windows.rs`.
    pub(crate) struct StandbyTerminalHost {
        pub(crate) process: super::super::shared::attachment::SpawnedHostProcess,
        pub(crate) stdin: io::PipeWriter,
        pub(crate) stdout: io::PipeReader,
        pub(crate) host_pid: u32,
    }

    impl StandbyTerminalHost {
        pub(crate) fn spawn() -> anyhow::Result<Self> {
            Err(unsupported().into())
        }
    }

    /// No endpoint is ever named on Windows yet (`FileOwner` has no value).
    pub(crate) fn endpoint_dir(owner: FileOwner) -> PathBuf {
        match owner {}
    }

    pub(crate) fn reserve_terminal_host_publication(
        _root: &Path,
    ) -> anyhow::Result<TerminalHostPublicationLock> {
        Err(unsupported().into())
    }

    /// The endpoint listener. Binding fails until `sys/windows.rs`, so no
    /// value exists yet.
    pub(crate) enum HostListener {}

    impl HostListener {
        pub(crate) fn bind(_endpoint: &Path) -> anyhow::Result<Self> {
            Err(unsupported().into())
        }

        pub(crate) fn accept(&self) -> io::Result<HostStream> {
            match *self {}
        }

        pub(crate) fn wait(
            &self,
            _waker: &AcceptWaker,
            _timeout: Option<std::time::Duration>,
        ) -> io::Result<bool> {
            match *self {}
        }
    }

    /// The publication lock of a host record root. Taking it fails until
    /// `sys/windows.rs`.
    pub(crate) enum TerminalHostPublicationLock {}

    pub(crate) fn acquire_terminal_host_publication_lock(
        _root: &Path,
    ) -> anyhow::Result<TerminalHostPublicationLock> {
        Err(unsupported().into())
    }

    /// Launch and adoption over the private bootstrap pipe. Windows v1 has
    /// no adoption; starting a host fails until `sys/windows.rs`.
    pub(crate) mod adopt_launch {
        use std::sync::Arc;

        use super::unsupported;
        use crate::terminal_host::BootstrappedHost;
        use crate::terminal_host_protocol::Frame;
        use crate::terminal_host_runtime::shared::codec::HostLaunch;
        use crate::terminal_host_runtime::shared::host_shared::HostShared;

        #[derive(Clone, Copy)]
        pub(crate) enum AdoptFd {}
        pub(crate) enum AdoptSpec {}
        pub(crate) enum PtyOwnershipLock {}

        pub(crate) fn adopt_pty_fd(_args: &[String]) -> anyhow::Result<Option<AdoptFd>> {
            Err(unsupported().into())
        }

        pub(crate) fn max_payload(_adopt_fd: Option<AdoptFd>) -> usize {
            0
        }

        pub(crate) fn decode(
            _frame: &Frame,
            _adopt_fd: Option<AdoptFd>,
            _bootstrapped: &mut BootstrappedHost,
        ) -> anyhow::Result<(HostLaunch, Option<AdoptSpec>)> {
            Err(unsupported().into())
        }

        pub(crate) fn start(
            _launch: &HostLaunch,
            _adopt: Option<AdoptSpec>,
            _bootstrapped: &BootstrappedHost,
        ) -> anyhow::Result<(Arc<HostShared>, PtyOwnershipLock)> {
            Err(unsupported().into())
        }
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

    /// The host's child. Windows children arrive with `sys/windows.rs`.
    pub(crate) enum HostChild {}

    impl HostChild {
        pub(crate) fn process_id(&self) -> Option<u32> {
            match *self {}
        }

        pub(crate) fn clone_killer(&self) -> Box<dyn cmux_pty::ChildKiller + Send + Sync> {
            match *self {}
        }

        pub(crate) fn adopted_session(&self) -> Option<SessionId> {
            match *self {}
        }

        pub(crate) fn wait_exit_observed(&self) -> bool {
            match *self {}
        }

        pub(crate) fn wait_and_disarm(&mut self) -> crate::terminal_host_protocol::TerminalExit {
            match *self {}
        }
    }

    /// The PTY handle the reader waits on. None exists until
    /// `sys/windows.rs`.
    #[derive(Clone, Copy)]
    pub(crate) enum PtyPollHandle {}

    pub(crate) fn pty_poll_handle(
        _master: &dyn cmux_pty::MasterPty,
    ) -> anyhow::Result<PtyPollHandle> {
        Err(unsupported().into())
    }

    pub(crate) fn wait_for_pty_readable_or_forced_drain(
        pty: PtyPollHandle,
        _drain_waiter: &mut HostStream,
        _force_drain: &std::sync::atomic::AtomicBool,
        _forced_at: &mut Option<std::time::Instant>,
    ) -> io::Result<bool> {
        match pty {}
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

        pub(crate) fn wait_readable(&self, _timeout: std::time::Duration) -> io::Result<bool> {
            Err(unsupported())
        }
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

    pub(crate) fn kill_process_group(_pid: u32) -> anyhow::Result<bool> {
        Err(unsupported().into())
    }

    pub(crate) fn lease_was_free(_file: &File) -> bool {
        false
    }

    pub(crate) fn wait_lease_exclusive(_file: &File) -> io::Result<()> {
        Err(unsupported())
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
