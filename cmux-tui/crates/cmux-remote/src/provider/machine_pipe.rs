//! A route's bytes through this person's own carrier to another of their machines
//! (`cmux remote exec|cp|connect --via-machine M`): no inbound port, no ssh, no tailnet.
//!
//! The dialer connects to this machine's acpmux socket and asks, as the connection's first line,
//! for a pipe to machine M's cmux-tui remote daemon (`_acpmux/remote.pipe`, acpmux
//! `cmux_tui_service.rs`). acpmux dials M over its hub carrier, naming that service; M bridges
//! the circuit to its daemon's loopback listener only when its owner named that daemon and
//! granted control. After the one reply line the socket carries the circuit's bytes, and the
//! WebSocket upgrade and the cmux Noise handshake run above it as over TCP: the route still
//! names the daemon (`ws://127.0.0.1:PORT/...` on M), and only a device M's daemon enrolled gets
//! in.

use std::path::PathBuf;

use async_trait::async_trait;
use serde_json::{Value, json};
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio::net::UnixStream;

use super::dial::{DialedStream, Dialer};
use crate::link::LinkError;

/// The acpmux method whose request, as a connection's first line, makes it a pipe.
pub const MACHINE_PIPE_METHOD: &str = "_acpmux/remote.pipe";
/// The longest reply line read before the pipe's bytes.
const MAX_REPLY_BYTES: usize = 16 * 1024;

/// Dials a loopback route on `machine` through the acpmux daemon at `socket`.
#[derive(Debug, Clone)]
pub struct MachinePipeDialer {
    socket: PathBuf,
    machine: String,
}

impl MachinePipeDialer {
    /// `machine`: an acpmux peer name or the machine's node key (`wgPublicKey`).
    pub fn new(socket: PathBuf, machine: String) -> Self {
        Self { socket, machine }
    }
}

/// Whether `host` names this machine's loopback, the only place the far end bridges to.
fn loopback_host(host: &str) -> bool {
    let bare = host.strip_prefix('[').and_then(|rest| rest.strip_suffix(']')).unwrap_or(host);
    bare.eq_ignore_ascii_case("localhost")
        || bare.parse::<std::net::IpAddr>().is_ok_and(|ip| ip.is_loopback())
}

/// The pipe request line for `machine`'s daemon on `port`.
pub fn machine_pipe_request(machine: &str, port: u16) -> String {
    let request = json!({
        "jsonrpc": "2.0", "id": 1, "method": MACHINE_PIPE_METHOD,
        "params": {"machine": machine, "port": port},
    });
    format!("{request}\n")
}

/// The reply line read back: Ok when the pipe is open, else the daemon's error and reason.
pub fn machine_pipe_reply(line: &[u8]) -> Result<(), LinkError> {
    let reply: Value = serde_json::from_slice(line)
        .map_err(|_| LinkError::Protocol("acpmux sent no pipe reply".into()))?;
    if reply.get("result").is_some() {
        return Ok(());
    }
    let error = reply.get("error").cloned().unwrap_or(Value::Null);
    let message = error.get("message").and_then(Value::as_str).unwrap_or("the pipe was refused");
    let reason = error.pointer("/data/reason").and_then(Value::as_str);
    Err(LinkError::Transport(match reason {
        Some(reason) => format!("{message} ({reason})"),
        None => message.to_owned(),
    }))
}

#[async_trait]
impl Dialer for MachinePipeDialer {
    fn name(&self) -> &'static str {
        "machine"
    }

    async fn dial(&self, host: &str, port: u16) -> Result<DialedStream, LinkError> {
        if !loopback_host(host) {
            return Err(LinkError::Transport(format!(
                "a route through another machine names that machine's loopback daemon \
                 (ws://127.0.0.1:PORT), not {host}"
            )));
        }
        let mut stream = UnixStream::connect(&self.socket).await.map_err(|error| {
            LinkError::Transport(format!(
                "acpmux is not running at {}: {error}",
                self.socket.display()
            ))
        })?;
        stream
            .write_all(machine_pipe_request(&self.machine, port).as_bytes())
            .await
            .map_err(|error| LinkError::Transport(error.to_string()))?;
        // One byte at a time: nothing past the newline may be read, it is the daemon's.
        let mut line = Vec::new();
        loop {
            let byte = stream.read_u8().await.map_err(|_| {
                LinkError::Transport("acpmux closed the pipe before answering".into())
            })?;
            if byte == b'\n' {
                break;
            }
            if line.len() == MAX_REPLY_BYTES {
                return Err(LinkError::Protocol("acpmux's pipe reply is too long".into()));
            }
            line.push(byte);
        }
        machine_pipe_reply(&line)?;
        Ok(Box::new(stream))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncBufReadExt as _;

    #[test]
    fn only_loopback_routes_go_through_a_machine() {
        for host in ["127.0.0.1", "[::1]", "::1", "localhost", "127.0.0.2"] {
            assert!(loopback_host(host), "{host}");
        }
        for host in ["10.0.0.1", "example.com", "[fd7a::10]"] {
            assert!(!loopback_host(host), "{host}");
        }
    }

    #[test]
    fn a_refusal_says_why() {
        let refused = br#"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"this machine's owner has not granted control from elsewhere (consent_required)","data":{"reason":"machine.unreachable"}}}"#;
        let error = machine_pipe_reply(refused).unwrap_err().to_string();
        assert!(
            error.contains("consent_required") && error.contains("machine.unreachable"),
            "{error}"
        );
        assert!(machine_pipe_reply(br#"{"jsonrpc":"2.0","id":1,"result":{"via":"hub"}}"#).is_ok());
        assert!(machine_pipe_reply(b"not json").is_err());
    }

    /// The dialer asks once, reads exactly the reply line, and hands back the rest of the
    /// connection: the first byte after the reply is the pipe's.
    #[tokio::test]
    async fn the_dial_returns_the_connection_after_the_reply_line() {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("acpmux.sock");
        let listener = tokio::net::UnixListener::bind(&socket).unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut stream = tokio::io::BufReader::new(stream);
            let mut request = String::new();
            stream.read_line(&mut request).await.unwrap();
            let mut stream = stream.into_inner();
            stream
                .write_all(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"via\":\"hub\"}}\nX")
                .await
                .unwrap();
            let mut echo = [0u8; 4];
            stream.read_exact(&mut echo).await.unwrap();
            stream.write_all(&echo).await.unwrap();
            request
        });
        let dialer = MachinePipeDialer::new(socket, "mac".into());
        let mut stream = dialer.dial("127.0.0.1", 7781).await.unwrap();
        let mut first = [0u8; 1];
        stream.read_exact(&mut first).await.unwrap();
        assert_eq!(&first, b"X");
        stream.write_all(b"ping").await.unwrap();
        let mut echo = [0u8; 4];
        stream.read_exact(&mut echo).await.unwrap();
        assert_eq!(&echo, b"ping");
        let request: Value = serde_json::from_str(&server.await.unwrap()).unwrap();
        assert_eq!(request["method"], MACHINE_PIPE_METHOD);
        assert_eq!(request["params"], json!({"machine": "mac", "port": 7781}));
        assert!(dialer.dial("10.0.0.1", 7781).await.is_err());
    }
}
