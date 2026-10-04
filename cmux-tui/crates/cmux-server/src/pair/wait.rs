//! `GET /v1/pair/wait` (server.md 6.2 step 1): one WebSocket with the
//! subprotocols `cmux.pair.v1` and `collect.<secret>`. The PairingDO pushes
//! `{t:"pending"}`, then `{t:"paired", host, team, user, install, …}` or
//! `{t:"refused"}` with close code 4403; expiry closes with 4408. Nothing
//! polls: the client blocks on reads bounded by one total deadline, and a
//! frame or message larger than 64 KiB ends the wait.

use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::sync::Arc;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use serde_json::{Map, Value};
use tungstenite::client::IntoClientRequest;
use tungstenite::http::HeaderValue;
use tungstenite::protocol::WebSocketConfig;
use tungstenite::{Message, WebSocket};

use super::ApiTarget;
use crate::error::{Error, Result};

pub const SUBPROTOCOL: &str = "cmux.pair.v1";
/// Close code for a refused approval.
pub const CLOSE_REFUSED: u16 = 4403;
/// Close code for an expired code.
pub const CLOSE_EXPIRED: u16 = 4408;

/// What the PairingDO pushed on success: the result object without `t`.
pub type Paired = Map<String, Value>;

/// Each frame and each message is at most this large; the PairingDO
/// sends small JSON objects.
pub const MAX_FRAME: usize = 64 * 1024;

enum Inner {
    Plain(TcpStream),
    Tls(Box<rustls::StreamOwned<rustls::ClientConnection, TcpStream>>),
}

/// The socket with one total deadline: every read and write gets the time
/// that is left as its socket timeout, and none starts after the deadline,
/// so a slow drip of bytes cannot extend the wait.
struct Stream {
    inner: Inner,
    deadline: Instant,
}

impl Stream {
    fn arm(&self) -> io::Result<()> {
        let left = self
            .deadline
            .checked_duration_since(Instant::now())
            .filter(|d| !d.is_zero())
            .ok_or_else(|| io::Error::from(io::ErrorKind::TimedOut))?;
        let tcp = match &self.inner {
            Inner::Plain(s) => s,
            Inner::Tls(s) => &s.sock,
        };
        tcp.set_read_timeout(Some(left))?;
        tcp.set_write_timeout(Some(left))
    }
}

impl Read for Stream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.arm()?;
        match &mut self.inner {
            Inner::Plain(s) => s.read(buf),
            Inner::Tls(s) => s.read(buf),
        }
    }
}

impl Write for Stream {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.arm()?;
        match &mut self.inner {
            Inner::Plain(s) => s.write(buf),
            Inner::Tls(s) => s.write(buf),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        self.arm()?;
        match &mut self.inner {
            Inner::Plain(s) => s.flush(),
            Inner::Tls(s) => s.flush(),
        }
    }
}

fn timed_out() -> Error {
    Error::unreachable(
        "timed out waiting for approval; the code may still be approved until it expires",
    )
}

fn remaining(deadline: Instant) -> Result<Duration> {
    deadline.checked_duration_since(Instant::now()).filter(|d| !d.is_zero()).ok_or_else(timed_out)
}

fn is_timeout(e: &io::Error) -> bool {
    matches!(e.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut)
}

/// Resolves on a helper thread so the deadline also bounds DNS (the
/// system resolver has no timeout parameter). A resolver that hangs past
/// the deadline leaves that thread to finish on its own.
fn resolve(host: &str, port: u16, deadline: Instant) -> Result<Vec<SocketAddr>> {
    let (tx, rx) = mpsc::channel();
    let name = host.to_owned();
    std::thread::spawn(move || {
        let _ = tx.send((name.as_str(), port).to_socket_addrs().map(Iterator::collect));
    });
    match rx.recv_timeout(remaining(deadline)?) {
        Ok(Ok(addrs)) => Ok(addrs),
        Ok(Err(e)) => Err(Error::unreachable(format!("resolve {host}: {e}"))),
        Err(_) => Err(timed_out()),
    }
}

fn connect(api: &ApiTarget, deadline: Instant) -> Result<Stream> {
    let (tls, host, port) = api.endpoint()?;
    let addrs = resolve(&host, port, deadline)?;
    let mut last = None;
    let mut tcp = None;
    for addr in addrs {
        match TcpStream::connect_timeout(&addr, remaining(deadline)?.min(Duration::from_secs(20))) {
            Ok(s) => {
                tcp = Some(s);
                break;
            }
            Err(e) => last = Some(e),
        }
    }
    let tcp = tcp.ok_or_else(|| {
        Error::unreachable(format!(
            "connect {host}:{port}: {}",
            last.map_or_else(|| "no address".to_owned(), |e| e.to_string())
        ))
    })?;
    if !tls {
        return Ok(Stream { inner: Inner::Plain(tcp), deadline });
    }
    let _ = rustls::crypto::ring::default_provider().install_default();
    use rustls_platform_verifier::ConfigVerifierExt;
    let config = rustls::ClientConfig::with_platform_verifier()
        .map_err(|e| Error::internal(format!("TLS setup: {e}")))?;
    let name = rustls::pki_types::ServerName::try_from(host.clone())
        .map_err(|_| Error::usage(format!("invalid API host {host}")))?;
    let conn = rustls::ClientConnection::new(Arc::new(config), name)
        .map_err(|e| Error::internal(format!("TLS setup: {e}")))?;
    Ok(Stream { inner: Inner::Tls(Box::new(rustls::StreamOwned::new(conn, tcp))), deadline })
}

/// How a wait ended, other than a timeout or a transport error.
#[derive(Debug)]
pub enum End {
    Paired(Paired),
    /// `{t:"refused"}` or close 4403: the code is spent.
    Refused,
    /// Close 4408, or the Worker no longer knows the code: it is spent.
    Expired,
}

/// Opens the wait socket for `code` and blocks until the PairingDO ends
/// it. Reaching `deadline` first is an `Unreachable` error (exit 5).
pub fn wait(api: &ApiTarget, code: &str, secret: &str, deadline: Instant) -> Result<End> {
    let stream = connect(api, deadline)?;
    let url = api.ws_url(&format!("/v1/pair/wait?code={code}"))?;
    let mut request =
        url.as_str().into_client_request().map_err(|e| Error::internal(format!("{e}")))?;
    let protocols = HeaderValue::from_str(&format!("{SUBPROTOCOL}, collect.{secret}"))
        .map_err(|_| Error::internal("collect secret is not a header value"))?;
    request.headers_mut().insert("Sec-WebSocket-Protocol", protocols);
    let config = WebSocketConfig::default()
        .max_frame_size(Some(MAX_FRAME))
        .max_message_size(Some(MAX_FRAME));
    let mut socket = match tungstenite::client::client_with_config(request, stream, Some(config)) {
        Ok((socket, _)) => socket,
        Err(tungstenite::HandshakeError::Failure(tungstenite::Error::Http(r)))
            if r.status().as_u16() == 404 =>
        {
            return Ok(End::Expired);
        }
        Err(tungstenite::HandshakeError::Failure(tungstenite::Error::Io(e))) if is_timeout(&e) => {
            return Err(timed_out());
        }
        Err(tungstenite::HandshakeError::Failure(tungstenite::Error::Http(r))) => {
            return Err(Error::unreachable(format!("pair wait refused ({})", r.status())));
        }
        Err(tungstenite::HandshakeError::Failure(e)) => {
            return Err(Error::unreachable(format!("pair wait: {e}")));
        }
        Err(tungstenite::HandshakeError::Interrupted(_)) => return Err(timed_out()),
    };
    read_result(&mut socket)
}

fn read_result(socket: &mut WebSocket<Stream>) -> Result<End> {
    loop {
        let message = match socket.read() {
            Ok(message) => message,
            Err(tungstenite::Error::Io(e)) if is_timeout(&e) => return Err(timed_out()),
            Err(tungstenite::Error::ConnectionClosed | tungstenite::Error::AlreadyClosed) => {
                return Err(Error::unreachable("the API closed the wait without a result"));
            }
            Err(e) => return Err(Error::unreachable(format!("pair wait: {e}"))),
        };
        match message {
            Message::Text(text) => {
                let Ok(Value::Object(mut frame)) = serde_json::from_str::<Value>(text.as_str())
                else {
                    continue;
                };
                match frame.remove("t").as_ref().and_then(Value::as_str) {
                    Some("paired") => {
                        let _ = socket.close(None);
                        return Ok(End::Paired(frame));
                    }
                    Some("refused") => return Ok(End::Refused),
                    _ => {}
                }
            }
            Message::Close(frame) => {
                return match frame.map(|f| u16::from(f.code)) {
                    Some(CLOSE_REFUSED) => Ok(End::Refused),
                    Some(CLOSE_EXPIRED) => Ok(End::Expired),
                    _ => Err(Error::unreachable("the API closed the wait without a result")),
                };
            }
            _ => {}
        }
    }
}
