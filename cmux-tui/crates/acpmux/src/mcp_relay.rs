//! The stdio MCP server a harness runs for an agent tool server the daemon
//! serves itself (`subsession_mcp::DaemonTools`). It opens
//! the daemon socket, names the server and proves the session with its
//! caller token in one first `initialize` (`server/agent_mcp.rs`), then
//! copies lines both ways: the agent's MCP lines go to the daemon unread,
//! the daemon's answers come back unread. Chrome's Mojo pipes carry a
//! renderer's messages to the browser the same way: the endpoint only moves
//! bytes, the browser binds and checks (`mojo/core/channel_posix.cc`).
//!
//! The program is `acpmux-mcp-relay` (`mcp_relay_main.rs`). It links only
//! this file, std and serde: no tokio and none of acpmux's relocated tables,
//! so it stays under 1 MB where each stdio server it replaces was 4.6 to
//! 4.7 MB. An install without it beside acpmux keeps those stdio servers
//! (`agent_tools.rs` picks): inside the cmux multicall binary a relay would
//! cost more than the server it replaces.
//!
//! A daemon that went away (an update, a restart) is dialed again on the
//! agent's next line, as the stdio servers connected anew for each call. A
//! request no daemon takes gets its JSON-RPC error reply, and so does each
//! request a daemon took and then went away without answering (`Open`), as
//! the stdio servers answered an open call when the daemon went away.
//!
//! This file uses nothing else of acpmux: the names it shares with the
//! daemon are defined here and checked against acpmux's in its tests.

use serde_json::{Value, json};

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

/// A JSON-RPC line's `id`, and whether it names a `method` (a request) or
/// not (a reply). Only those two fields are read; the rest is skipped, not
/// built. A notification (no `id`) or a line that is not JSON gives `None`.
fn head(line: &[u8]) -> Option<(Value, bool)> {
    #[derive(serde::Deserialize)]
    struct Head {
        id: Option<Value>,
        method: Option<serde::de::IgnoredAny>,
    }
    let head: Head = serde_json::from_slice(line).ok()?;
    Some((head.id?, head.method.is_some()))
}

/// The id of a request line, which waits for a reply with that id.
fn request_id(line: &[u8]) -> Option<Value> {
    head(line).filter(|(_, request)| *request).map(|(id, _)| id)
}

/// The id of the request a reply line answers.
fn reply_id(line: &[u8]) -> Option<Value> {
    head(line).filter(|(_, request)| !request).map(|(id, _)| id)
}

/// The error reply to request `id` when no daemon answers it: none took
/// it, or the one that took it went away first.
fn unreachable_reply(id: &Value) -> String {
    let message = "the acpmux daemon is not running; cmux starts it again";
    let mut reply =
        json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32000, "message": message}})
            .to_string();
    reply.push('\n');
    reply
}

/// The requests one daemon connection took and has not answered yet.
#[derive(Default)]
struct Pending {
    /// The agent's calls in flight: a few at a time, so a list.
    ids: Vec<Value>,
    /// The connection ended and its requests got their error: it takes no more.
    closed: bool,
}

/// [`Pending`], shared by the agent's reader and the connection's output thread.
#[derive(Clone, Default)]
struct Open(std::sync::Arc<std::sync::Mutex<Pending>>);

impl Open {
    fn with<R>(&self, f: impl FnOnce(&mut Pending) -> R) -> R {
        f(&mut self.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner))
    }

    /// Records `id` before its line is sent; false when the connection already ended.
    fn take(&self, id: &Value) -> bool {
        self.with(|p| {
            if !p.closed {
                p.ids.push(id.clone());
            }
            !p.closed
        })
    }

    /// Drops `id`: its reply passed, or its line was not sent. False when it
    /// was not open, because the end of the connection already answered it.
    fn answered(&self, id: &Value) -> bool {
        self.with(|p| {
            let at = p.ids.iter().position(|open| open == id);
            at.map(|at| p.ids.swap_remove(at)).is_some()
        })
    }

    /// Ends the connection: the requests it still owed.
    fn close(&self) -> Vec<Value> {
        self.with(|p| {
            p.closed = true;
            std::mem::take(&mut p.ids)
        })
    }
}

/// The daemon's lines to the agent, each whole and flushed, so an answer
/// never waits in a buffer or interleaves with another. A reply closes its
/// request in `open`.
fn copy_lines(
    from: &mut impl std::io::BufRead,
    to: &mut impl std::io::Write,
    open: &Open,
) -> std::io::Result<()> {
    let mut line = Vec::new();
    loop {
        line.clear();
        if from.read_until(b'\n', &mut line)? == 0 {
            return Ok(());
        }
        to.write_all(&line)?;
        to.flush()?;
        if let Some(id) = reply_id(&line) {
            open.answered(&id);
        }
    }
}

/// The output side of one daemon connection: its lines to the agent until
/// it ends, then the error reply of every request it took and never answered.
fn drain_connection(
    from: &mut impl std::io::BufRead,
    mut to: impl std::io::Write,
    open: &Open,
) -> std::io::Result<()> {
    let copied = copy_lines(from, &mut to, open);
    for id in open.close() {
        to.write_all(unreachable_reply(&id).as_bytes())?;
    }
    to.flush()?;
    copied
}

#[cfg(unix)]
pub use relay::main;

#[cfg(unix)]
mod relay {
    use super::*;
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixStream;
    use std::path::PathBuf;
    use std::sync::Arc;

    /// Where the relay dials and what it says first.
    struct Dial {
        socket: PathBuf,
        hello: String,
    }

    /// A proven daemon connection: the agent's lines go in through `writer`;
    /// `open` holds the requests it took and has not answered.
    struct Conn {
        writer: UnixStream,
        open: Open,
    }

    /// What became of a line sent on a [`Conn`].
    enum Sent {
        /// The daemon has it, or the connection's end already answered it.
        Taken,
        /// The connection is gone and the line was not sent: dial again.
        Gone,
    }

    impl Conn {
        fn send(&mut self, line: &[u8], id: Option<&Value>) -> Sent {
            if id.is_some_and(|id| !self.open.take(id)) {
                return Sent::Gone;
            }
            if self.writer.write_all(line).is_ok() {
                return Sent::Taken;
            }
            match id {
                // Not sent and still open: the next connection takes it.
                Some(id) if self.open.answered(id) => Sent::Gone,
                // The connection's end already gave it its error reply.
                Some(_) => Sent::Taken,
                None => Sent::Gone,
            }
        }
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
        /// `out` by a thread of their own until the daemon closes it
        /// ([`drain_connection`]).
        fn connect<O>(&self, out: &Arc<O>) -> Result<Conn, RelayError>
        where
            O: Send + Sync + 'static,
            for<'a> &'a O: Write,
        {
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
            let open = Open::default();
            let (owed, out) = (open.clone(), Arc::clone(out));
            // Scoped to this connection: it owns only the read half, and a panic drops it,
            // which ends the relay's connection. cmux_threads directly: this file is also the
            // relay program's root module, linked without the acpmux library.
            cmux_threads::spawn(
                "mcp-relay-out",
                cmux_threads::ThreadQos::UserInitiated,
                move || {
                    let _ = drain_connection(&mut reader, &*out, &owed);
                },
            )?;
            Ok(Conn { writer, open })
        }
    }

    /// Runs the relay on stdin and stdout until the agent closes its pipe.
    pub fn main() -> Result<(), RelayError> {
        // A daemon that went away fails the write (EPIPE), never the process.
        // SAFETY: setting a signal disposition has no preconditions.
        unsafe { libc::signal(libc::SIGPIPE, libc::SIG_IGN) };
        let dial = Dial::from_env()?;
        run(&dial, std::io::stdin().lock(), &Arc::new(std::io::stdout()))
    }

    /// The agent's lines from `input` to the daemon, its answers to `out`.
    fn run<O>(dial: &Dial, mut input: impl BufRead, out: &Arc<O>) -> Result<(), RelayError>
    where
        O: Send + Sync + 'static,
        for<'a> &'a O: Write,
    {
        let mut daemon = Some(dial.connect(out)?);
        let mut line = Vec::new();
        loop {
            line.clear();
            if input.read_until(b'\n', &mut line)? == 0 {
                return Ok(());
            }
            let id = request_id(&line);
            let mut taken = |d: &mut Conn| matches!(d.send(&line, id.as_ref()), Sent::Taken);
            if daemon.as_mut().is_some_and(&mut taken) {
                continue;
            }
            daemon = dial.connect(out).ok();
            if daemon.as_mut().is_some_and(&mut taken) {
                continue;
            }
            daemon = None;
            if let Some(id) = id {
                (&**out).write_all(unreachable_reply(&id).as_bytes())?;
            }
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use std::os::unix::net::UnixListener;
        use std::time::Duration;

        /// A call open through the relay when the daemon goes
        /// away (an update, a crash) gets its error reply, as the stdio
        /// servers gave one, instead of waiting for the harness's MCP timeout.
        #[test]
        fn a_call_the_daemon_took_and_never_answered_gets_its_error_when_it_goes_away() {
            let dir = std::env::temp_dir().join(format!("acpmux-relay-{}", std::process::id()));
            std::fs::create_dir_all(&dir).unwrap();
            let socket = dir.join("d.sock");
            let _ = std::fs::remove_file(&socket);
            let listener = UnixListener::bind(&socket).unwrap();
            // The fake daemon answers the hello, reads one tools/call and exits.
            let daemon = std::thread::spawn(move || {
                let (stream, _) = listener.accept().unwrap();
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut hello = String::new();
                reader.read_line(&mut hello).unwrap();
                let reply = json!({"jsonrpc": "2.0", "id": HELLO_ID, "result": {}});
                (&stream).write_all(format!("{reply}\n").as_bytes()).unwrap();
                let mut call = String::new();
                reader.read_line(&mut call).unwrap();
                call
            });
            let dial = Dial { socket, hello: hello_line("cmux-subsessions", "s-1", "abc") };
            let (agent, relay_out) = UnixStream::pair().unwrap();
            let call = "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"tools/call\",\"params\":{}}\n";
            run(&dial, call.as_bytes(), &Arc::new(relay_out)).unwrap();
            assert_eq!(daemon.join().unwrap(), call, "the daemon took the call");
            agent.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
            let mut reply = String::new();
            BufReader::new(&agent).read_line(&mut reply).expect("a reply to the open call");
            let reply: Value = serde_json::from_str(&reply).unwrap();
            assert_eq!(reply["id"], 42, "{reply}");
            assert_eq!(reply["error"]["code"], -32000, "{reply}");
            let _ = std::fs::remove_dir_all(dir);
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
    fn copy_lines_moves_every_byte_and_closes_answered_requests() {
        let open = Open::default();
        assert!(open.take(&json!(1)) && open.take(&json!("two")));
        let input = b"{\"id\":1,\"result\":{}}\n{\"method\":\"note\"}\n".repeat(5000);
        let mut out = Vec::new();
        copy_lines(&mut &input[..], &mut out, &open).unwrap();
        assert_eq!(out, input);
        assert_eq!(open.close(), [json!("two")], "only the unanswered request stays open");
        assert!(!open.take(&json!(3)), "a closed connection takes no more requests");
    }

    #[test]
    fn a_connection_that_ends_answers_each_request_it_owed() {
        let open = Open::default();
        assert!(open.take(&json!(7)) && open.take(&json!(8)));
        let mut out = Vec::new();
        drain_connection(
            &mut &b"{\"jsonrpc\":\"2.0\",\"id\":8,\"result\":{}}\n"[..],
            &mut out,
            &open,
        )
        .unwrap();
        let lines: Vec<Value> = out
            .split(|b| *b == b'\n')
            .filter(|l| !l.is_empty())
            .map(|l| serde_json::from_slice(l).unwrap())
            .collect();
        assert_eq!(lines.len(), 2, "{lines:?}");
        assert_eq!(lines[0]["id"], 8);
        assert_eq!(lines[1]["id"], 7);
        assert_eq!(lines[1]["error"]["code"], -32000);
        assert!(!open.answered(&json!(7)), "the end already answered it");
    }

    #[test]
    fn only_requests_wait_for_a_reply() {
        let request = b"{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\"}\n";
        assert_eq!(request_id(request), Some(json!(7)));
        assert_eq!(reply_id(request), None);
        let note = b"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n";
        assert_eq!(request_id(note), None);
        let reply = b"{\"jsonrpc\":\"2.0\",\"id\":\"a\",\"result\":{\"big\":[1,2,3]}}\n";
        assert_eq!(reply_id(reply), Some(json!("a")));
        assert_eq!(request_id(reply), None);
        let error: Value = serde_json::from_str(&unreachable_reply(&json!(7))).unwrap();
        assert_eq!(error["id"], 7);
        assert_eq!(error["error"]["code"], -32000);
    }
}
