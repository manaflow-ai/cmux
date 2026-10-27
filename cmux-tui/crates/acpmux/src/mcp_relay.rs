//! The stdio MCP server a harness runs for an agent tool server the daemon
//! serves itself (p07-memory-092, `subsession_mcp::DaemonTools`). It opens
//! the daemon socket, names the server and proves the session with its
//! caller token in one first `initialize` (`server/agent_mcp.rs`), then
//! copies lines both ways: the agent's MCP lines go to the daemon unread,
//! the daemon's answers come back unread. Chrome's Mojo pipes carry a
//! renderer's messages to the browser the same way: the endpoint only moves
//! bytes, the browser binds and checks (`mojo/core/channel_posix.cc`).
//!
//! Two programs run it. `acpmux-mcp-relay` (`mcp_relay_main.rs`) links only
//! this file, std and serde_json: no tokio and none of acpmux's relocated
//! tables, so it stays under 1 MB where each stdio server it replaces was
//! 4.6 to 4.7 MB. `acpmux __mcp-relay` is the same code inside acpmux
//! (`cli/entry.rs`, before any tokio runtime), for an install that ships no
//! `acpmux-mcp-relay` beside acpmux (`agent_tools.rs` picks).
//!
//! A daemon that went away (an update, a restart) is dialed again on the
//! agent's next line, as the stdio servers connected anew for each call; a
//! request no daemon takes gets its JSON-RPC error reply.
//!
//! This file uses nothing else of acpmux: the names it shares with the
//! daemon are defined here and checked against acpmux's in its tests.

use serde_json::{Value, json};

/// The acpmux argument that selects the relay mode.
pub const RELAY_ARG: &str = "__mcp-relay";
/// The relay program installed beside acpmux.
pub const RELAY_PROGRAM: &str = "acpmux-mcp-relay";
/// The relay's env: which daemon tool server it is (`DaemonTools::server_name`).
pub const SERVER_ENV: &str = "ACPMUX_MCP_SERVER";
/// The session it acts for (`subsession_mcp::SESSION_ENV`).
pub const SESSION_ENV: &str = "ACPMUX_SESSION_ID";
/// Its caller token (`hub/person.rs` (a), `CALLER_TOKEN_ENV`).
pub const TOKEN_ENV: &str = "ACPMUX_SESSION_TOKEN";
/// The socket of the daemon that issued the token, the only one it goes to
/// (`CALLER_SOCKET_ENV`, `client.rs`).
pub const SOCKET_ENV: &str = "ACPMUX_SESSION_TOKEN_SOCKET";
/// `_meta.acpmux` field of the first `initialize`: the caller (`CALLER_FIELD`).
pub const CALLER_FIELD: &str = "callerSession";
/// `_meta.acpmux` field of the first `initialize`: the agent tool server.
pub const SERVER_FIELD: &str = "mcpServer";
/// The handshake's own request id: the agent's ids are numbers or its own strings.
const HELLO_ID: &str = "acpmux-mcp-relay";

/// The `_meta` of the first `initialize` that makes a daemon connection
/// `server` for `session`, proven by its caller token `token`.
pub fn hello_meta(server: &str, session: &str, token: &str) -> Value {
    let mut acpmux = serde_json::Map::new();
    acpmux.insert(CALLER_FIELD.to_owned(), json!({"sessionId": session, "token": token}));
    acpmux.insert(SERVER_FIELD.to_owned(), json!(server));
    json!({"acpmux": acpmux})
}

/// The handshake line: an `initialize` with [`hello_meta`].
pub fn hello_line(server: &str, session: &str, token: &str) -> String {
    let hello = json!({"jsonrpc": "2.0", "id": HELLO_ID, "method": "initialize",
        "params": {"protocolVersion": "2025-06-18", "_meta": hello_meta(server, session, token)}});
    let mut line = hello.to_string();
    line.push('\n');
    line
}

/// What the relay could not do; said on stderr, where the harness logs it.
#[derive(Debug)]
pub enum RelayError {
    MissingEnv(&'static str),
    Connect(std::path::PathBuf, std::io::Error),
    Io(std::io::Error),
    /// The daemon refused the handshake (a token that proves no session).
    Refused(String),
}

impl std::fmt::Display for RelayError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::MissingEnv(key) => write!(f, "{key} is not set"),
            Self::Connect(path, e) => {
                write!(f, "cannot reach the daemon at {}: {e}", path.display())
            }
            Self::Io(e) => write!(f, "{e}"),
            Self::Refused(why) => write!(f, "the daemon refused: {why}"),
        }
    }
}

impl std::error::Error for RelayError {}

impl From<std::io::Error> for RelayError {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e)
    }
}

/// The error reply to a request line no daemon took; a notification gets none.
fn unreachable_reply(line: &[u8]) -> Option<String> {
    let request: Value = serde_json::from_slice(line).ok()?;
    let id = request.get("id")?.clone();
    let message = "the acpmux daemon is not running; cmux starts it again";
    let mut reply =
        json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32000, "message": message}})
            .to_string();
    reply.push('\n');
    Some(reply)
}

/// The daemon's lines to the agent, each whole and flushed, so an answer
/// never waits in a buffer or interleaves with another.
fn copy_lines(
    from: &mut impl std::io::BufRead,
    to: &mut impl std::io::Write,
) -> std::io::Result<()> {
    let mut line = Vec::new();
    loop {
        line.clear();
        if from.read_until(b'\n', &mut line)? == 0 {
            return Ok(());
        }
        to.write_all(&line)?;
        to.flush()?;
    }
}

#[cfg(unix)]
pub use relay::main;

#[cfg(unix)]
mod relay {
    use super::*;
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixStream;
    use std::path::PathBuf;

    /// Where the relay dials and what it says first.
    struct Dial {
        socket: PathBuf,
        hello: String,
    }

    impl Dial {
        fn from_env() -> Result<Self, RelayError> {
            let var = |key: &'static str| {
                let value = std::env::var(key).ok().filter(|v| !v.is_empty());
                value.ok_or(RelayError::MissingEnv(key))
            };
            let hello = hello_line(&var(SERVER_ENV)?, &var(SESSION_ENV)?, &var(TOKEN_ENV)?);
            Ok(Self { socket: PathBuf::from(var(SOCKET_ENV)?), hello })
        }

        /// A proven connection: the handshake answered, its answers copied to
        /// stdout by a thread of their own until the daemon closes it.
        fn connect(&self) -> Result<UnixStream, RelayError> {
            let stream = UnixStream::connect(&self.socket)
                .map_err(|e| RelayError::Connect(self.socket.clone(), e))?;
            let mut writer = stream.try_clone()?;
            writer.write_all(self.hello.as_bytes())?;
            let mut reader = BufReader::new(stream);
            let mut reply = String::new();
            reader.read_line(&mut reply)?;
            let reply: Value = serde_json::from_str(&reply)
                .map_err(|_| RelayError::Refused("the daemon closed the connection".to_owned()))?;
            if let Some(error) = reply.get("error") {
                let why = error["message"].as_str().unwrap_or("no reason given");
                return Err(RelayError::Refused(why.to_owned()));
            }
            std::thread::Builder::new().name("mcp-relay-out".to_owned()).spawn(move || {
                let _ = copy_lines(&mut reader, &mut std::io::stdout());
            })?;
            Ok(writer)
        }
    }

    /// Runs the relay on stdin and stdout until the agent closes its pipe.
    pub fn main() -> Result<(), RelayError> {
        // A daemon that went away fails the write (EPIPE), never the process.
        // SAFETY: setting a signal disposition has no preconditions.
        unsafe { libc::signal(libc::SIGPIPE, libc::SIG_IGN) };
        let dial = Dial::from_env()?;
        let mut daemon = Some(dial.connect()?);
        let mut input = std::io::stdin().lock();
        let mut line = Vec::new();
        loop {
            line.clear();
            if input.read_until(b'\n', &mut line)? == 0 {
                return Ok(());
            }
            if daemon.as_mut().is_some_and(|d| d.write_all(&line).is_ok()) {
                continue;
            }
            daemon = dial.connect().ok();
            if daemon.as_mut().is_some_and(|d| d.write_all(&line).is_ok()) {
                continue;
            }
            daemon = None;
            if let Some(reply) = unreachable_reply(&line) {
                std::io::stdout().lock().write_all(reply.as_bytes())?;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_hello_names_the_server_and_carries_the_caller() {
        let line = hello_line("cmux-subsessions", "s-1", "abc");
        assert!(line.ends_with('\n'));
        let hello: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(hello["method"], "initialize");
        assert_eq!(hello["id"], HELLO_ID);
        let meta = &hello["params"]["_meta"]["acpmux"];
        assert_eq!(meta["callerSession"], json!({"sessionId": "s-1", "token": "abc"}));
        assert_eq!(meta["mcpServer"], "cmux-subsessions");
    }

    #[test]
    fn copy_lines_moves_every_byte() {
        let input = b"{\"id\":1}\n{\"id\":2}\n".repeat(5000);
        let mut out = Vec::new();
        copy_lines(&mut &input[..], &mut out).unwrap();
        assert_eq!(out, input);
    }

    #[test]
    fn a_request_no_daemon_takes_gets_its_error_and_a_notification_none() {
        let request = b"{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\"}\n";
        let reply: Value = serde_json::from_str(&unreachable_reply(request).unwrap()).unwrap();
        assert_eq!(reply["id"], 7);
        assert_eq!(reply["error"]["code"], -32000);
        let note = b"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n";
        assert!(unreachable_reply(note).is_none());
    }
}
