//! One terminal on the holder, and the local-runtime launch the daemon
//! parses it on.

use std::io::{self, Write};
use std::os::fd::{AsRawFd, OwnedFd};
use std::sync::Arc;

use cmux_holder::ExitStatus;
use cmux_pty::ChildKiller;

use super::sink::{SinkEnd, SnapshottingReader};
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
    /// A VT replay of the daemon's parsed screen, handed to a new holder
    /// after a holder crash as the terminal's prologue.
    pub(super) replay: std::sync::Mutex<Option<Replay>>,
}

/// Builds a terminal's VT replay of at most the given bytes, empty when it
/// does not fit (its surface registers it).
pub(crate) type Replay = Box<dyn Fn(usize) -> Vec<u8> + Send + Sync>;

/// The largest prologue handed to a new holder with the master: it must
/// fit one ADOPT frame (1 MiB) with room to spare.
pub(super) const ADOPT_PROLOGUE_MAX_BYTES: usize = 768 * 1024;
/// The largest screen snapshot sent while the terminal runs: the screen,
/// its modes and the newest history that fits. It goes over the shared
/// link once per burst of output, so it stays small.
pub(super) const SNAPSHOT_MAX_BYTES: usize = 128 * 1024;

impl HolderTerminal {
    /// The daemon exits and leaves the shell to the holder: the reader and
    /// the wait end without recording an end, and the holder hears DETACH
    /// (the link's end is no strike against the terminal's stream).
    pub(crate) fn detach(&self) {
        self.sink.detach();
        self.service.detach(self.chan);
        self.service.untrack(self.chan);
    }

    /// How to replay the screen for a new holder (the surface sets it).
    pub(crate) fn set_replay(&self, replay: Replay) {
        *self.replay.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(replay);
    }

    /// The screen replay (at most `max_bytes`); empty when none is known
    /// or it does not fit.
    pub(super) fn prologue(&self, max_bytes: usize) -> Vec<u8> {
        self.replay
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .as_ref()
            .map(|replay| replay(max_bytes))
            .unwrap_or_default()
    }

    pub(crate) fn is_detached(&self) -> bool {
        self.sink.is_detached()
    }

    /// Hang up the shell (an explicit close). Runs under the surface's
    /// runtime lock, so it only writes to a link that is already open:
    /// it never connects, starts a holder or re-adopts (which takes
    /// terminal locks). Without an open link (the holder died and its
    /// restart has not finished) the CLOSE waits for the next link and the
    /// daemon hangs up the shell's groups itself: same user, and it keeps
    /// the master.
    fn hang_up(&self) {
        if self.service.close(self.chan, 2000).is_err() {
            for signal in [libc::SIGHUP, libc::SIGTERM] {
                cmux_holder::pty::signal_terminal(self.pid, self.custody.as_raw_fd(), None, signal);
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
    let writer = Box::new(WaitingWriter {
        inner: master.take_writer()?,
        master: terminal.custody.try_clone()?,
    });
    let waited = terminal.clone();
    let snapshotted = Arc::downgrade(terminal);
    let reader = SnapshottingReader {
        sink: terminal.sink.clone(),
        snapshot: Box::new(move |base| {
            let Some(terminal) = snapshotted.upgrade() else { return };
            let replay = terminal.prologue(SNAPSHOT_MAX_BYTES);
            if !replay.is_empty() {
                terminal.service.snapshot(terminal.chan, base, &replay);
            }
        }),
    };
    Ok(LocalLaunch {
        master,
        reader: Box::new(reader),
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

/// The surface's input writer on the custody master. The holder reads that
/// master non-blocking, and `O_NONBLOCK` belongs to the open file
/// description every dup shares, so a write the PTY's input queue (about 1
/// KiB on macOS) cannot take returns `WouldBlock`. This writer then waits
/// for room, as a write on a blocking master does: a paste or a burst of
/// mouse reports is never cut.
struct WaitingWriter {
    inner: Box<dyn Write + Send>,
    /// A dup of the master to wait on.
    master: OwnedFd,
}

impl Write for WaitingWriter {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        loop {
            match self.inner.write(buffer) {
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    wait_writable(self.master.as_raw_fd())?;
                }
                result => return result,
            }
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        loop {
            match self.inner.flush() {
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    wait_writable(self.master.as_raw_fd())?;
                }
                result => return result,
            }
        }
    }
}

/// Block until the master takes input again. A master whose terminal ended
/// is an error rather than a wait that never ends.
fn wait_writable(master: std::os::fd::RawFd) -> io::Result<()> {
    loop {
        let mut poll_fd = libc::pollfd { fd: master, events: libc::POLLOUT, revents: 0 };
        // SAFETY: polls one live pollfd; -1 waits like a blocking write.
        let ready = unsafe { libc::poll(&mut poll_fd, 1, -1) };
        if ready < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if poll_fd.revents & libc::POLLOUT == 0
            && poll_fd.revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0
        {
            return Err(io::Error::new(io::ErrorKind::BrokenPipe, "the terminal's PTY closed"));
        }
        return Ok(());
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

#[cfg(test)]
mod tests {
    use std::io::Read;
    use std::os::fd::FromRawFd;

    use super::*;

    /// A raw PTY pair whose master is non-blocking, as the holder leaves it.
    fn nonblocking_pty() -> (OwnedFd, std::fs::File) {
        let (mut master, mut slave) = (-1, -1);
        // SAFETY: out-pointers to live locals; default termios and size.
        let opened = unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        assert_eq!(opened, 0, "openpty: {}", io::Error::last_os_error());
        // SAFETY: openpty returned two fresh descriptors this test owns.
        let (master, slave) =
            unsafe { (OwnedFd::from_raw_fd(master), OwnedFd::from_raw_fd(slave)) };
        // SAFETY: termios calls on the slave this test owns; fcntl on its master.
        unsafe {
            let mut termios: libc::termios = std::mem::zeroed();
            assert_eq!(libc::tcgetattr(slave.as_raw_fd(), &mut termios), 0);
            libc::cfmakeraw(&mut termios);
            assert_eq!(libc::tcsetattr(slave.as_raw_fd(), libc::TCSANOW, &termios), 0);
            let flags = libc::fcntl(master.as_raw_fd(), libc::F_GETFL);
            libc::fcntl(master.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK);
        }
        (master, std::fs::File::from(slave))
    }

    #[test]
    fn a_paste_bigger_than_the_input_queue_waits_for_a_slow_program() {
        let (master, mut slave) = nonblocking_pty();
        let paste: Vec<u8> = (0..64 * 1024).map(|index| b'a' + (index % 26) as u8).collect();
        let expected = paste.clone();
        // The program reads nothing for a while, then everything.
        let program = std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(300));
            let mut got = vec![0u8; expected.len()];
            slave.read_exact(&mut got).unwrap();
            got == expected
        });
        let pty = cmux_pty::adopt_master(master.try_clone().unwrap()).unwrap();
        let mut writer = WaitingWriter { inner: pty.take_writer().unwrap(), master };
        writer.write_all(&paste).expect("the paste waits for room instead of failing");
        writer.flush().unwrap();
        assert!(program.join().unwrap(), "the program got every byte, in order");
    }
}
