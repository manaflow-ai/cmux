//! Connecting to a local server that starts on demand (the browser host).
//!
//! A client connects to the server's socket. When nothing answers it either
//! starts the server itself, in the background and in its own process group,
//! or, when a supervisor owns the socket (a cmux daemon starts that server
//! with secrets the client does not have), it waits for the supervisor's
//! server instead: a server started by the client would take the socket.
//! `cmux-browser-host eval|list|close` and `cmux mcp` (code mode) both reach
//! the browser host through [`connect_or_start`].

use std::ffi::OsString;
use std::io;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// How long a starting server may take before its socket answers.
pub const START_WAIT: Duration = Duration::from_secs(10);

/// What a client does when no server answers on the socket.
#[derive(Debug)]
pub enum WhenAbsent {
    /// Someone else starts the server: wait for it, never start one.
    Wait,
    /// Start this command (stdio closed, own process group), then wait.
    Start(Command),
}

/// Why no connection was made.
#[derive(Debug)]
pub enum OnDemandError {
    /// The server command could not be started.
    Start(io::Error),
    /// Nothing answered on the socket within the wait.
    NoAnswer {
        /// Whether this client started the server.
        started: bool,
    },
}

impl std::fmt::Display for OnDemandError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            OnDemandError::Start(error) => write!(f, "cannot start the server: {error}"),
            OnDemandError::NoAnswer { started: true } => f.write_str("the server did not start"),
            OnDemandError::NoAnswer { started: false } => f.write_str("the server does not answer"),
        }
    }
}

impl std::error::Error for OnDemandError {}

/// Connects to `socket`. When nothing answers, follows `when_absent`, then
/// connects within `within` (a bounded connect retry while the server
/// starts). The started server outlives this process: its own process group
/// keeps a Ctrl-C in the caller's terminal from stopping a server other
/// clients use.
pub fn connect_or_start(
    socket: &Path,
    when_absent: WhenAbsent,
    within: Duration,
) -> Result<UnixStream, OnDemandError> {
    if let Ok(stream) = UnixStream::connect(socket) {
        return Ok(stream);
    }
    let started = match when_absent {
        WhenAbsent::Wait => false,
        WhenAbsent::Start(mut command) => {
            command
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .process_group(0)
                .spawn()
                .map_err(OnDemandError::Start)?;
            true
        }
    };
    let deadline = Instant::now() + within;
    loop {
        if let Ok(stream) = UnixStream::connect(socket) {
            return Ok(stream);
        }
        if Instant::now() >= deadline {
            return Err(OnDemandError::NoAnswer { started });
        }
        // A bounded connect retry while the server starts, not a synchronization.
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Whether a cmux daemon owns `socket`: its terminals name it in
/// `socket_env` next to `CMUX_TUI_SOCKET`. A client there waits for the
/// daemon's server ([`WhenAbsent::Wait`]). `env` reads the environment.
pub fn named_by_daemon(
    socket: &Path,
    socket_env: &str,
    env: impl Fn(&str) -> Option<OsString>,
) -> bool {
    let set = |key: &str| env(key).filter(|value| !value.is_empty());
    set("CMUX_TUI_SOCKET").is_some()
        && set(socket_env).is_some_and(|named| Path::new(&named) == socket)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<OsString> + 'a {
        move |key| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| OsString::from(v))
    }

    #[test]
    fn codemode_parity_only_a_daemon_terminal_names_a_daemon_owned_socket() {
        let socket = Path::new("/run/bh/browser-host.sock");
        let named = [("CMUX_TUI_SOCKET", "/run/d.sock"), ("S", "/run/bh/browser-host.sock")];
        assert!(named_by_daemon(socket, "S", env(&named)));
        let no_daemon = [("S", "/run/bh/browser-host.sock")];
        assert!(!named_by_daemon(socket, "S", env(&no_daemon)), "acpmux names it without a daemon");
        let other = [("CMUX_TUI_SOCKET", "/run/d.sock"), ("S", "/elsewhere.sock")];
        assert!(!named_by_daemon(socket, "S", env(&other)));
        let blank = [("CMUX_TUI_SOCKET", ""), ("S", "/run/bh/browser-host.sock")];
        assert!(!named_by_daemon(socket, "S", env(&blank)));
    }

    #[test]
    fn codemode_parity_waiting_without_a_server_ends_at_the_deadline() {
        let socket = Path::new("/tmp/cmux-on-demand-none/none.sock");
        let error = connect_or_start(socket, WhenAbsent::Wait, Duration::from_millis(60))
            .expect_err("nothing listens");
        assert!(matches!(error, OnDemandError::NoAnswer { started: false }), "{error}");
    }

    #[test]
    fn codemode_parity_a_server_that_cannot_start_is_reported() {
        let socket = Path::new("/tmp/cmux-on-demand-none/none.sock");
        let command = Command::new("/nonexistent/cmux-on-demand-server");
        let error = connect_or_start(socket, WhenAbsent::Start(command), Duration::from_millis(60))
            .expect_err("no such program");
        assert!(matches!(error, OnDemandError::Start(_)), "{error}");
    }
}
