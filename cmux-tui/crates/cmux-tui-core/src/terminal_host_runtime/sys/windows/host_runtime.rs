//! The running half of a Windows terminal host (the `adopt_launch`,
//! `HostChild` and PTY readiness seams, Windows side). Windows v1 has no PTY
//! custody, so a host never adopts: `--bootstrap-stdio` always starts a new
//! ConPTY child through cmux-pty (in its own Job Object,
//! `cmux_pty::windows_jobs`) and runs the shared host runtime on it.
//!
//! ConPTY keeps its output pipe open after the child exits, until the
//! pseudoconsole closes. The host therefore closes the pseudoconsole (drops
//! the master) as soon as it sees the child exit: the PTY reader then reads
//! the final bytes and gets end-of-file, as on Unix, and the exit is
//! published after the drain. The reader blocks in `ReadFile`, so the
//! readiness wait only ends a forced drain whose window has passed.

use std::io;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Instant;

use cmux_pty::{ChildKiller, MasterPty, PtySize};
use windows_sys::Win32::Foundation::{HANDLE, WAIT_OBJECT_0};
use windows_sys::Win32::System::Threading::{INFINITE, WaitForSingleObject};

use super::super::super::shared::host_state::HOST_FORCED_DRAIN_WINDOW;
use super::super::HostStream;
use crate::terminal_host_protocol::{TerminalExit, wait_for_native_child_status_with_reap_result};

/// The ConPTY master, shared by the host runtime and the child watcher,
/// which closes it when the child exits.
type MasterSlot = Arc<Mutex<Option<Box<dyn MasterPty + Send>>>>;

fn lock(slot: &MasterSlot) -> std::sync::MutexGuard<'_, Option<Box<dyn MasterPty + Send>>> {
    slot.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The runtime's view of the master: every call reaches the ConPTY until
/// the child watcher has closed it.
struct ClosableMaster(MasterSlot);

fn closed() -> anyhow::Error {
    anyhow::anyhow!("the terminal's pseudoconsole is closed")
}

impl MasterPty for ClosableMaster {
    fn resize(&self, size: PtySize) -> anyhow::Result<()> {
        lock(&self.0).as_ref().ok_or_else(closed)?.resize(size)
    }

    fn get_size(&self) -> anyhow::Result<PtySize> {
        lock(&self.0).as_ref().ok_or_else(closed)?.get_size()
    }

    fn try_clone_reader(&self) -> anyhow::Result<Box<dyn io::Read + Send>> {
        lock(&self.0).as_ref().ok_or_else(closed)?.try_clone_reader()
    }

    fn take_writer(&self) -> anyhow::Result<Box<dyn io::Write + Send>> {
        lock(&self.0).as_ref().ok_or_else(closed)?.take_writer()
    }
}

/// The host's ConPTY child. Windows hosts never adopt a session.
pub(crate) struct HostChild {
    child: Box<dyn cmux_pty::Child + Send + Sync>,
    master: MasterSlot,
}

impl HostChild {
    /// Close the pseudoconsole: the reader drains and gets end-of-file.
    fn close_pseudoconsole(&self) {
        let master = lock(&self.master).take();
        drop(master);
    }

    pub(crate) fn process_id(&self) -> Option<u32> {
        self.child.process_id()
    }

    pub(crate) fn clone_killer(&self) -> Box<dyn ChildKiller + Send + Sync> {
        self.child.clone_killer()
    }

    pub(crate) fn adopted_session(&self) -> Option<super::super::SessionId> {
        None
    }

    /// Block until the child ended (its process handle stays valid: Windows
    /// has no reaping), then close the pseudoconsole.
    pub(crate) fn wait_exit_observed(&self) -> bool {
        let Some(handle) = self.child.as_raw_handle() else { return false };
        // SAFETY: the child's process handle, owned by `self.child`.
        let ended = unsafe { WaitForSingleObject(handle as HANDLE, INFINITE) } == WAIT_OBJECT_0;
        if ended {
            self.close_pseudoconsole();
        }
        ended
    }

    pub(crate) fn wait_and_disarm(&mut self) -> TerminalExit {
        let (exit, _) = wait_for_native_child_status_with_reap_result(self.child.as_mut());
        self.close_pseudoconsole();
        exit
    }
}

/// The reader reads the ConPTY output pipe with blocking reads; there is no
/// handle to poll.
#[derive(Clone, Copy)]
pub(crate) struct PtyPollHandle;

pub(crate) fn pty_poll_handle(_master: &dyn MasterPty) -> anyhow::Result<PtyPollHandle> {
    Ok(PtyPollHandle)
}

/// Ok(true): read the PTY (the read blocks until bytes or end-of-file).
/// Ok(false) once a forced drain's window has passed.
pub(crate) fn wait_for_pty_readable_or_forced_drain(
    _pty: PtyPollHandle,
    _drain_waiter: &mut HostStream,
    force_drain: &AtomicBool,
    forced_at: &mut Option<Instant>,
) -> io::Result<bool> {
    if force_drain.load(Ordering::Acquire) {
        let started = forced_at.get_or_insert_with(Instant::now);
        if started.elapsed() >= HOST_FORCED_DRAIN_WINDOW {
            return Ok(false);
        }
    }
    Ok(true)
}

/// Launch over the private bootstrap pipes. Windows v1 has no adoption.
pub(crate) mod adopt_launch {
    use std::path::Path;
    use std::sync::{Arc, Mutex};

    use cmux_pty::PtyCommand;

    use super::{ClosableMaster, HostChild};
    use crate::terminal_host::BootstrappedHost;
    use crate::terminal_host_protocol::{Frame, MessageKind};
    use crate::terminal_host_runtime::shared::codec::HostLaunch;
    use crate::terminal_host_runtime::shared::host_shared::HostShared;
    use crate::terminal_host_runtime::shared::host_start::start_host_runtime;
    use crate::terminal_host_runtime::shared::host_state::pty_size;
    use crate::terminal_host_runtime::sys::prepare_private_dir;

    #[derive(Clone, Copy)]
    pub(crate) enum AdoptFd {}
    pub(crate) enum AdoptSpec {}

    /// No PTY ownership lock: without custody no second host can serve an
    /// incarnation's PTY.
    pub(crate) struct PtyOwnershipLock;

    /// `--bootstrap-stdio <bootstrap pipe name>` (the name is opened before
    /// this runs): a new terminal, never an adoption.
    pub(crate) fn adopt_pty_fd(args: &[String]) -> anyhow::Result<Option<AdoptFd>> {
        match args {
            [mode, ..] if mode == "--bootstrap-stdio" => Ok(None),
            _ => anyhow::bail!("hidden mode requires --bootstrap-stdio"),
        }
    }

    /// `Launch` may carry a respawn seed blob on top of the launch budget.
    pub(crate) fn max_payload(_adopt_fd: Option<AdoptFd>) -> usize {
        crate::terminal_host_runtime::MAX_LAUNCH_PAYLOAD
            + size_of::<u32>()
            + crate::terminal_host_runtime::MAX_BLOB
    }

    pub(crate) fn decode(
        frame: &Frame,
        _adopt_fd: Option<AdoptFd>,
        _bootstrapped: &mut BootstrappedHost,
    ) -> anyhow::Result<(HostLaunch, Option<AdoptSpec>)> {
        if frame.kind != MessageKind::Launch {
            anyhow::bail!("expected terminal-host Launch, received {:?}", frame.kind);
        }
        Ok((HostLaunch::decode(&frame.payload)?, None))
    }

    /// Spawn the ConPTY child and start the shared host runtime on it.
    pub(crate) fn start(
        launch: &HostLaunch,
        _adopt: Option<AdoptSpec>,
        bootstrapped: &BootstrappedHost,
    ) -> anyhow::Result<(Arc<HostShared>, PtyOwnershipLock)> {
        if let Some(parent) = Path::new(&launch.record_path).parent() {
            prepare_private_dir(parent)?;
        }
        let cell_pixels = (launch.cell_pixels.0.max(1), launch.cell_pixels.1.max(1));
        let pty = cmux_pty::open(pty_size(launch.cols, launch.rows, cell_pixels)?)?;
        crate::debug_spans::mark("host.pty_opened");
        let program = launch
            .command
            .first()
            .ok_or_else(|| anyhow::anyhow!("terminal-host launch has no command"))?;
        let mut command = PtyCommand::new(program);
        command.args(launch.command[1..].iter().cloned());
        command.env("TERM", &launch.term);
        // The same truecolor guarantee as an in-process terminal; extra_env wins.
        command.env("COLORTERM", "truecolor");
        for (key, value) in &launch.extra_env {
            command.env(key, value);
        }
        if let Some(cwd) = launch.cwd.as_deref() {
            command.cwd(cwd);
        }
        let cmux_pty::SpawnedPty { master, child } = pty.spawn(command)?;
        crate::debug_spans::mark("host.child_spawned");
        let slot = Arc::new(Mutex::new(Some(master)));
        let child = HostChild { child, master: slot.clone() };
        let shared = start_host_runtime(
            launch,
            bootstrapped,
            Box::new(ClosableMaster(slot)),
            child,
            &launch.seed,
        )?;
        Ok((shared, PtyOwnershipLock))
    }
}
