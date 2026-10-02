//! One app host process: spawn with fd 3, write [`ToHost`] lines, read
//! [`FromHost`] lines on a reader thread that blocks on the socket, and
//! report the exit once the socket closes and the child is reaped.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;

use cmux_app_host::protocol::MAX_LINE_BYTES;
use cmux_app_host::{FromHost, ToHost};

/// How a host process ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Exit {
    pub code: Option<i32>,
    pub signal: Option<i32>,
}

impl Exit {
    pub fn describe(&self) -> String {
        match (self.code, self.signal) {
            (Some(0), _) => "exited".into(),
            (Some(65), _) => "protocol error".into(),
            (Some(70), _) => "app limit or engine failure".into(),
            (Some(77), _) => "sandbox could not be applied".into(),
            (Some(code), _) => format!("exit {code}"),
            (None, Some(signal)) => format!("signal {signal}"),
            (None, None) => "unknown exit".into(),
        }
    }
}

pub struct HostProcess {
    writer: Mutex<UnixStream>,
}

/// The host binary: `CMUX_APP_HOST_BIN`, else `cmux-app-host` next to the
/// daemon executable. `None` when neither exists (the capability is then not
/// advertised).
pub fn resolve_binary() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("CMUX_APP_HOST_BIN").map(PathBuf::from) {
        return path.is_file().then_some(path);
    }
    let path = std::env::current_exe().ok()?.parent()?.join("cmux-app-host");
    path.is_file().then_some(path)
}

impl HostProcess {
    /// Spawns the host with a clean environment and only fd 3 open beyond
    /// the null stdio. `on_message` runs on the reader thread for every line;
    /// `on_exit` runs once after the socket closed and the child was reaped.
    pub fn spawn(
        binary: &Path,
        args: &[String],
        name: &str,
        on_message: impl Fn(FromHost) + Send + 'static,
        on_exit: impl FnOnce(Exit) + Send + 'static,
    ) -> std::io::Result<Self> {
        let (ours, theirs) = UnixStream::pair()?;
        let fd = theirs.as_raw_fd();
        let mut command = Command::new(binary);
        command
            .args(args)
            .env_clear()
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        // SAFETY: only async-signal-safe calls between fork and exec. dup2
        // onto 3 clears close-on-exec for the child's copy.
        unsafe {
            command.pre_exec(move || {
                if libc::dup2(fd, 3) == 3 { Ok(()) } else { Err(std::io::Error::last_os_error()) }
            });
        }
        let mut child = command.spawn()?;
        drop(theirs);
        let pid = child.id();
        let reader = ours.try_clone()?;
        std::thread::Builder::new().name(format!("cmux-app-host:{name}")).spawn(move || {
            let mut lines = BufReader::new(reader);
            let mut line = Vec::new();
            loop {
                line.clear();
                match lines.by_ref().take(MAX_LINE_BYTES as u64 + 1).read_until(b'\n', &mut line) {
                    Ok(0) | Err(_) => break,
                    Ok(_) if line.last() != Some(&b'\n') => break,
                    Ok(_) => match serde_json::from_slice::<FromHost>(&line) {
                        Ok(message) => on_message(message),
                        Err(_) => break,
                    },
                }
            }
            // A malformed or oversized line, or the socket closed: end the process.
            // SAFETY: signalling our own child by pid; it is not reaped yet, so the pid is still ours.
            unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
            let status = child.wait();
            let exit = match status {
                Ok(status) => Exit { code: status.code(), signal: status.signal() },
                Err(_) => Exit { code: None, signal: None },
            };
            on_exit(exit);
        })?;
        Ok(Self { writer: Mutex::new(ours) })
    }

    pub fn send(&self, message: &ToHost) -> std::io::Result<()> {
        let mut line = serde_json::to_vec(message).map_err(std::io::Error::other)?;
        line.push(b'\n');
        let mut writer = self.writer.lock().unwrap();
        writer.write_all(&line)
    }

    /// Asks the host to exit; the reader thread reports the exit.
    pub fn shutdown(&self) {
        if self.send(&ToHost::Shutdown).is_err() {
            self.kill();
        }
        let _ = self.writer.lock().unwrap().shutdown(std::net::Shutdown::Write);
    }

    pub fn kill(&self) {
        let _ = self.writer.lock().unwrap().shutdown(std::net::Shutdown::Both);
    }
}
