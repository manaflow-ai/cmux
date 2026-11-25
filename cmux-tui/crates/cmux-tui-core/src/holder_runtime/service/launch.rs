//! The start of a terminal holder for the daemon's holder service: the
//! standalone `cmux-holder` or the holder built into the host executable,
//! its token and its `ready`.

use cmux_process::Stdio;
use std::io::{self, Write};
use std::path::PathBuf;
use std::sync::atomic::Ordering;

use super::HolderService;

impl HolderService {
    /// Start a holder and wait until it listens: the standalone
    /// `cmux-holder` (std and libc only, its own content-addressed copy on
    /// macOS, `crate::host_exe::holder_executable`) when the daemon has one
    /// that speaks its wire, else the holder built into the host executable
    /// (`cmux-tui-host __holder`).
    pub(super) fn launch(&self) -> io::Result<()> {
        let configure =
            |command: &mut cmux_process::Command| {
                command
                    .arg("--socket")
                    .arg(&self.socket)
                    // Every shell gets back the open-file limit cmux started
                    // with; the holder keeps the daemon's raised one.
                    .envs(
                        cmux_pty::original_open_file_limit()
                            .map(|soft| (cmux_holder::NOFILE_SOFT_ENV, soft.to_string())),
                    )
                    // A DEV build's, debug build's or test's grace, as its hosts
                    // get: the holder ends its terminals once no daemon came back.
                    .envs(crate::terminal_host_runtime::spawned_orphan_grace().map(|grace| {
                        (cmux_holder::ORPHAN_GRACE_ENV, grace.as_millis().to_string())
                    }))
                    .stdin(Stdio::piped())
                    .stdout(Stdio::piped())
                    .stderr(Stdio::null());
            };
        if !self.standalone_failed.load(Ordering::Acquire)
            && let Some(path) = standalone_holder()
        {
            let mut command = cmux_process::Command::new(&path);
            command.arg0(crate::host_exe::HOLDER_NAME);
            configure(&mut command);
            // Not to a file `CMUX_TUI_HOLDER_EXE` names: that is a test's
            // stand-in for an older holder, which refuses arguments it
            // does not know.
            if std::env::var_os(crate::host_exe::HOLDER_ENV).is_none_or(|value| value.is_empty()) {
                command.args(crate::terminal_host_runtime::host_owner_args());
            }
            let started = command.spawn().and_then(|child| self.handshake(child));
            match started {
                Ok(()) => return Ok(()),
                // It lost a race to another holder of this session, which
                // listens now: connect to that one.
                Err(_) if std::os::unix::net::UnixStream::connect(&self.socket).is_ok() => {
                    return Ok(());
                }
                Err(error) => {
                    // A standalone holder that answers `--version` but does
                    // not start (a startup error, a crash in serve, a hang
                    // before `ready`, a macOS major it fails on) must not
                    // cost every holder terminal: this daemon runs the
                    // built-in holder from now on.
                    eprintln!(
                        "cmux-tui: the terminal holder {} did not start ({error}); \
                         using the built-in holder",
                        path.display()
                    );
                    self.standalone_failed.store(true, Ordering::Release);
                }
            }
        }
        let child = crate::host_exe::spawn_host_isolated(|command| {
            command.arg("__holder");
            configure(command);
            command.args(crate::terminal_host_runtime::host_owner_args());
        })?;
        self.handshake(child)
    }

    /// Hand a just-started holder its token and wait for its `ready`. A
    /// holder that answers anything else, or nothing in time, is killed and
    /// reaped; one that is ready is reaped whenever it exits while this
    /// daemon runs.
    fn handshake(&self, mut child: cmux_process::Child) -> io::Result<()> {
        match first_line(&mut child, &self.token) {
            Ok(line) if line.trim() == "ready" => {}
            answer => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(match answer {
                    Ok(line) => {
                        io::Error::other(format!("the terminal holder did not start: {line:?}"))
                    }
                    Err(error) => error,
                });
            }
        }
        // Reaped here while this daemon runs; it outlives the daemon (that is what keeps
        // terminals across a restart), also when the reaper thread cannot start.
        child.detach("the terminal holder outlives this daemon so its terminals survive a restart");
        let _ = std::thread::Builder::new().name("holder-reaper".into()).spawn(move || {
            let _ = child.wait();
        });
        Ok(())
    }
}

/// Write `token` to a just-started holder's stdin and read the first line
/// it prints (`ready` once it listens), waiting at most
/// [`cmux_holder::client::READY_TIMEOUT`]: a holder that hangs before it
/// (and does not exit) must not hold the `connecting` lock, and with it
/// every terminal create and holder restart, for ever.
fn first_line(child: &mut cmux_process::Child, token: &[u8; 32]) -> io::Result<String> {
    let hex: String = token.iter().map(|byte| format!("{byte:02x}")).collect();
    let mut stdin = child.stdin.take().ok_or_else(|| io::Error::other("no holder stdin"))?;
    stdin.write_all(format!("{hex}\n").as_bytes())?;
    drop(stdin);
    let mut stdout = child.stdout.take().ok_or_else(|| io::Error::other("no holder stdout"))?;
    cmux_holder::client::first_line_within(&mut stdout, cmux_holder::client::READY_TIMEOUT)
}

/// The standalone holder this daemon starts, when it has one whose wire
/// range it speaks (`cmux-holder --version`).
pub(crate) fn standalone_holder() -> Option<PathBuf> {
    crate::host_exe::holder_executable(&|answer| {
        cmux_holder::parse_version_line(answer).is_some_and(|(min, max)| {
            min <= cmux_holder::wire::VERSION && max >= cmux_holder::wire::MIN_VERSION
        })
    })
}

/// Make the standalone holder's copy and run its `--version` on a
/// background thread, so the first terminal of a session does not pay for
/// the copy, its hash and its first exec. Only with the holder model on.
/// A daemon calls it when it starts serving (unit tests start none).
#[cfg(not(test))]
pub(crate) fn prepare_in_background() {
    if !super::super::enabled() {
        return;
    }
    let _ = std::thread::Builder::new().name("cmux-holder-exe".into()).spawn(|| {
        let _ = standalone_holder();
    });
}
