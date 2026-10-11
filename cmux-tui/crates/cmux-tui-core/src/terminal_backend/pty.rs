//! The session host's local runtime over a byte-backend terminal: a
//! portable_pty `MasterPty`, reader, writer and `ChildKiller` whose bytes
//! are the terminal's channel. Parsing, journal, snapshots and attach stay
//! the session host's, exactly as for a PTY child.

use std::io::{self, Read, Write};
use std::sync::{Arc, Mutex};

use cmux_pty::{ChildKiller, MasterPty, PtySize};
use serde_json::{Value, json};

use super::channel::ChannelTable;
use super::terminals::TerminalMeta;
use super::{End, Lost, wire};
use crate::terminal_end::TerminalEnd;
use crate::terminal_host_protocol::{TerminalExit, TerminalExitOutcome};

/// Sends one line to the app's server.
pub(crate) type SendLine = Arc<dyn Fn(Value) + Send + Sync>;

/// One terminal's channel as the runtime sees it.
#[derive(Clone)]
pub(crate) struct BackendSide {
    pub channels: Arc<ChannelTable<TerminalMeta>>,
    pub terminal: String,
    pub send: SendLine,
}

impl std::fmt::Debug for BackendSide {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "BackendSide({})", self.terminal)
    }
}

impl BackendSide {
    fn event(&self, op: &str, data: Value) {
        (self.send)(json!({ "t": "host.event", "op": op, "data": data }));
    }
}

/// The master side: resize goes to the app as a host event.
pub(crate) struct BackendMaster {
    side: BackendSide,
    size: Mutex<PtySize>,
}

impl BackendMaster {
    pub(crate) fn new(side: BackendSide, size: PtySize) -> Self {
        Self { side, size: Mutex::new(size) }
    }
}

impl MasterPty for BackendMaster {
    fn resize(&self, size: PtySize) -> anyhow::Result<()> {
        *self.size.lock().unwrap() = size;
        let cell = |px: u16, cells: u16| (px > 0 && cells > 0).then(|| px / cells);
        self.side.event(
            wire::BACKEND_RESIZE,
            json!({
                "terminal": self.side.terminal, "cols": size.cols, "rows": size.rows,
                "cell_width_px": cell(size.pixel_width, size.cols),
                "cell_height_px": cell(size.pixel_height, size.rows),
            }),
        );
        Ok(())
    }

    fn get_size(&self) -> anyhow::Result<PtySize> {
        Ok(*self.size.lock().unwrap())
    }

    fn try_clone_reader(&self) -> anyhow::Result<Box<dyn Read + Send>> {
        Ok(Box::new(BackendReader(self.side.clone())))
    }

    fn take_writer(&self) -> anyhow::Result<Box<dyn Write + Send>> {
        Ok(Box::new(BackendWriter(self.side.clone())))
    }

    #[cfg(unix)]
    fn process_group_leader(&self) -> Option<libc::pid_t> {
        None
    }

    #[cfg(unix)]
    fn as_raw_fd(&self) -> Option<std::os::fd::RawFd> {
        None
    }

    #[cfg(unix)]
    fn tty_name(&self) -> Option<std::path::PathBuf> {
        None
    }
}

/// Output: blocks until the app sent bytes; credits them once read. End of
/// file after the terminal's last bytes.
struct BackendReader(BackendSide);

impl Read for BackendReader {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let side = &self.0;
        let Ok(bytes) = side.channels.wait_received(&side.terminal, buf.len()) else {
            return Ok(0);
        };
        buf[..bytes.len()].copy_from_slice(&bytes);
        if let Ok(Some(credit)) = side.channels.consumed(&side.terminal, bytes.len() as u64) {
            (side.send)(wire::frame_to_json(&credit));
        }
        Ok(bytes.len())
    }
}

/// Input: data frames within the app's credit (waits for credit, like a
/// full PTY).
struct BackendWriter(BackendSide);

impl Write for BackendWriter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let side = &self.0;
        let send = |frame| (side.send)(wire::frame_to_json(&frame));
        side.channels
            .send_all(&side.terminal, buf, &send)
            .map_err(|e| io::Error::new(io::ErrorKind::BrokenPipe, e.to_string()))?;
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// Kill: the host ends the terminal now and asks the app to close it.
#[derive(Debug, Clone)]
pub(crate) struct BackendKiller(pub BackendSide);

impl ChildKiller for BackendKiller {
    fn kill(&mut self) -> io::Result<()> {
        let side = &self.0;
        if side.channels.close(&side.terminal, End::Lost(Lost::new("closed", true))).is_ok() {
            side.event(wire::BACKEND_CLOSE, json!({ "terminal": side.terminal }));
        }
        Ok(())
    }

    fn clone_killer(&self) -> Box<dyn ChildKiller + Send + Sync> {
        Box::new(self.clone())
    }
}

/// Blocks until the terminal ended; maps the interface end to the session
/// host's terminal end (an exit status ends the process; a lost link is a
/// host loss).
pub(crate) fn wait_end(side: &BackendSide) -> TerminalEnd {
    match side.channels.wait_end(&side.terminal) {
        End::Exit(exit) => {
            let outcome = match (exit.code, exit.signal.as_deref().and_then(signal_number)) {
                (Some(code), _) => TerminalExitOutcome::Exit { code },
                (None, Some(signal)) => {
                    TerminalExitOutcome::Signal { signal, core_dumped: exit.core_dumped }
                }
                (None, None) => {
                    return TerminalEnd::ProcessEnded(TerminalExit::unknown(
                        exit.message.unwrap_or_else(|| "the far end exited".into()),
                    ));
                }
            };
            TerminalEnd::ProcessEnded(TerminalExit::now(outcome))
        }
        End::Lost(lost) => TerminalEnd::host_lost(lost.reason),
    }
}

/// The number of a signal name without `SIG`.
fn signal_number(name: &str) -> Option<i32> {
    Some(match name {
        "HUP" => libc::SIGHUP,
        "INT" => libc::SIGINT,
        "QUIT" => libc::SIGQUIT,
        "ABRT" => libc::SIGABRT,
        "KILL" => libc::SIGKILL,
        "SEGV" => libc::SIGSEGV,
        "PIPE" => libc::SIGPIPE,
        "TERM" => libc::SIGTERM,
        _ => return None,
    })
}
