//! One `agent-transfer-*` client connection to a daemon's socket: request
//! lines in, answers matched by `id` (spec/commands.md, "Agent chat
//! transfer"). A refusal the daemon answered is told apart from an answer
//! that never came, since only the first says what happened there.

use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

use cmux_json::JsonSet as _;
use serde_json::{Value, json};

/// Most calls; the daemon gives acpmux 15 s.
pub(super) const CALL_TIMEOUT: Duration = Duration::from_secs(45);
/// A begin may stop a running turn (the daemon waits 30 s).
pub(super) const BEGIN_TIMEOUT: Duration = Duration::from_secs(60);
/// A finish imports the chat (the daemon waits 60 s).
pub(super) const FINISH_TIMEOUT: Duration = Duration::from_secs(90);

/// Why a call has no answer to use.
#[derive(Debug)]
pub(super) enum CallError {
    /// The daemon answered `ok: false` (with its `error_details`, `Null`
    /// without).
    Refused { code: String, message: String, details: Value },
    /// No answer: the socket could not be reached, it closed, or the
    /// answer did not come in time. What the daemon did is unknown.
    Lost(String),
}

impl CallError {
    pub(super) fn code(&self) -> Option<&str> {
        match self {
            Self::Refused { code, .. } => Some(code),
            Self::Lost(_) => None,
        }
    }

    pub(super) fn message(&self) -> &str {
        match self {
            Self::Refused { message, .. } | Self::Lost(message) => message,
        }
    }
}

/// One connection to a daemon.
pub(super) struct Daemon {
    reader: BufReader<UnixStream>,
    next_id: u64,
}

impl Daemon {
    pub(super) fn connect(socket: &Path) -> Result<Self, CallError> {
        let stream = UnixStream::connect(socket)
            .map_err(|e| CallError::Lost(format!("cannot connect to {}: {e}", socket.display())))?;
        Ok(Self { reader: BufReader::new(stream), next_id: 1 })
    }

    /// The pid of the process listening at the other end, when the system says.
    pub(super) fn peer_pid(&self) -> Option<u32> {
        use std::os::fd::AsRawFd as _;
        cmux_link::caller::peer_pid(self.reader.get_ref().as_raw_fd()).ok().flatten()
    }

    /// Sends `cmd` with `params` and returns the answer's `data`.
    pub(super) fn call(
        &mut self,
        cmd: &str,
        mut params: Value,
        timeout: Duration,
    ) -> Result<Value, CallError> {
        let lost = |e: std::io::Error| CallError::Lost(format!("{cmd}: {e}"));
        let id = self.next_id;
        self.next_id += 1;
        params.set("id", json!(id));
        params.set("cmd", json!(cmd));
        let mut line = params.to_string();
        line.push('\n');
        let stream = self.reader.get_mut();
        stream.set_read_timeout(Some(timeout)).map_err(lost)?;
        stream.set_write_timeout(Some(timeout)).map_err(lost)?;
        stream.write_all(line.as_bytes()).map_err(lost)?;
        loop {
            let mut answer = String::new();
            if self.reader.read_line(&mut answer).map_err(lost)? == 0 {
                return Err(CallError::Lost(format!("{cmd}: the daemon closed the connection")));
            }
            let Ok(answer) = serde_json::from_str::<Value>(&answer) else {
                return Err(CallError::Lost(format!("{cmd}: the answer is not JSON")));
            };
            // Events and other answers on the same connection are not ours.
            if answer["id"] != json!(id) {
                continue;
            }
            if answer["ok"] == json!(true) {
                return Ok(answer["data"].clone());
            }
            return Err(CallError::Refused {
                code: answer["error_code"].as_str().unwrap_or("agent_transfer.unknown").to_owned(),
                message: answer["error"].as_str().unwrap_or_default().to_owned(),
                details: answer["error_details"].clone(),
            });
        }
    }
}

/// Calls `cmd` once on a new connection to `socket`.
pub(super) fn call_once(
    socket: &Path,
    cmd: &str,
    params: Value,
    timeout: Duration,
) -> Result<Value, CallError> {
    Daemon::connect(socket)?.call(cmd, params, timeout)
}
