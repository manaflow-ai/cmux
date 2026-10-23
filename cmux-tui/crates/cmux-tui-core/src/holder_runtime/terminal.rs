//! One terminal on the holder, and the local-runtime launch the daemon
//! parses it on.

use std::io;
use std::os::fd::OwnedFd;
use std::sync::Arc;

use cmux_holder::ExitStatus;
use cmux_pty::ChildKiller;

use super::sink::{SinkEnd, SinkReader};
use super::{HolderService, HolderSink};
use crate::surface::spawn::LocalLaunch;
use crate::terminal_end::TerminalEnd;
use crate::terminal_host_protocol::{TerminalExit, TerminalExitOutcome};

/// A shell the holder runs for this daemon.
pub(crate) struct HolderTerminal {
    /// The holder's channel for it.
    pub(crate) chan: u32,
    /// The terminal id the holder lists it under.
    pub(crate) id: [u8; 16],
    /// The shell's pid (leader of its session and process group).
    pub(crate) pid: i32,
    /// The daemon's dup of the PTY master: input, resize, and the copy that
    /// keeps the shell alive if the holder dies.
    pub(crate) custody: OwnedFd,
    pub(crate) sink: Arc<HolderSink>,
    pub(super) service: Arc<HolderService>,
}

impl HolderTerminal {
    /// The daemon exits and leaves the shell to the holder: the reader and
    /// the wait end without recording an end.
    pub(crate) fn detach(&self) {
        self.sink.detach();
        self.service.untrack(self.chan);
    }

    pub(crate) fn is_detached(&self) -> bool {
        self.sink.is_detached()
    }

    /// Hang up the shell (an explicit close). Without a holder link the
    /// daemon signals the group itself: same user, and the shell's pid is
    /// its group's.
    fn hang_up(&self) {
        if self.service.close(self.chan, 2000).is_err() {
            // SAFETY: signals the process group of a shell this daemon owns.
            unsafe {
                libc::killpg(self.pid, libc::SIGHUP);
                libc::killpg(self.pid, libc::SIGKILL);
            }
        }
    }
}

/// The local-runtime launch of `terminal`: output from the holder's stream,
/// input and resize on the custody master, kill through the holder, and the
/// end the holder reports.
pub(crate) fn holder_local_launch(
    terminal: &Arc<HolderTerminal>,
    command: Vec<String>,
    cwd: Option<String>,
) -> anyhow::Result<LocalLaunch> {
    let master = cmux_pty::adopt_master(terminal.custody.try_clone()?)?;
    let writer = master.take_writer()?;
    let waited = terminal.clone();
    Ok(LocalLaunch {
        master,
        reader: Box::new(SinkReader(terminal.sink.clone())),
        writer,
        killer: Box::new(HolderKiller(terminal.clone())),
        wait: Box::new(move || {
            let end = waited.sink.wait_end();
            if end != SinkEnd::Detached {
                // Ended: the holder may forget it.
                let _ = waited.service.close(waited.chan, 0);
                waited.service.untrack(waited.chan);
            }
            terminal_end(end)
        }),
        pid: u32::try_from(terminal.pid).ok(),
        command,
        cwd,
        supports_clear_history_key_fallback: true,
        holder: Some(terminal.clone()),
    })
}

fn terminal_end(end: SinkEnd) -> TerminalEnd {
    match end {
        SinkEnd::Exited(ExitStatus::Exited(code)) => {
            TerminalEnd::ProcessEnded(TerminalExit::now(TerminalExitOutcome::Exit { code }))
        }
        SinkEnd::Exited(ExitStatus::Signaled(signal)) => {
            TerminalEnd::ProcessEnded(TerminalExit::now(TerminalExitOutcome::Signal {
                signal,
                core_dumped: false,
            }))
        }
        SinkEnd::Exited(ExitStatus::Unobserved) => {
            TerminalEnd::ProcessEnded(TerminalExit::unknown(crate::terminal_end::EXIT_UNOBSERVED))
        }
        SinkEnd::Lost => TerminalEnd::host_lost("holder-lost"),
        // Detached for a daemon shutdown: never recorded (exit_state).
        SinkEnd::Detached => TerminalEnd::host_lost("holder-detached"),
    }
}

struct HolderKiller(Arc<HolderTerminal>);

impl ChildKiller for HolderKiller {
    fn kill(&mut self) -> io::Result<()> {
        self.0.hang_up();
        Ok(())
    }

    fn clone_killer(&self) -> Box<dyn ChildKiller + Send + Sync> {
        Box::new(Self(self.0.clone()))
    }
}

impl std::fmt::Debug for HolderKiller {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HolderKiller").field("chan", &self.0.chan).finish()
    }
}
