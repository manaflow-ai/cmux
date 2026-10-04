//! `GET /v1/pair/wait` (server.md 6.2 step 1): one WebSocket with the
//! subprotocols `cmux.pair.v1` and `collect.<secret>`. The PairingDO pushes
//! `{t:"pending"}`, then `{t:"paired", host, team, user, install, …}` or
//! `{t:"refused"}` with close code 4403; expiry closes with 4408. Nothing
//! polls: the client blocks on one read whose deadline is the time left.

use std::io::{self, Read, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{Map, Value};
use tungstenite::client::IntoClientRequest;
use tungstenite::http::HeaderValue;
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

enum Stream {
    Plain(TcpStream),
    Tls(Box<rustls::StreamOwned<rustls::ClientConnection, TcpStream>>),
}

impl Stream {
    fn tcp(&self) -> &TcpStream {
        match self {
            Stream::Plain(s) => s,
            Stream::Tls(s) => &s.sock,
        }
    }
}

impl Read for Stream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match self {
            Stream::Plain(s) => s.read(buf),
            Stream::Tls(s) => s.read(buf),
        }
    }
}

impl Write for Stream {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        match self {
            Stream::Plain(s) => s.write(buf),
            Stream::Tls(s) => s.write(buf),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        match self {
            Stream::Plain(s) => s.flush(),
            Stream::Tls(s) => s.flush(),
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

fn connect(api: &ApiTarget, deadline: Instant) -> Result<Stream> {
    let (tls, host, port) = api.endpoint()?;
    let addrs = (host.as_str(), port)
        .to_socket_addrs()
        .map_err(|e| Error::unreachable(format!("resolve {host}: {e}")))?;
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
        return Ok(Stream::Plain(tcp));
    }
    let _ = rustls::crypto::ring::default_provider().install_default();
    use rustls_platform_verifier::ConfigVerifierExt;
    let config = rustls::ClientConfig::with_platform_verifier()
        .map_err(|e| Error::internal(format!("TLS setup: {e}")))?;
    let name = rustls::pki_types::ServerName::try_from(host.clone())
        .map_err(|_| Error::usage(format!("invalid API host {host}")))?;
    let conn = rustls::ClientConnection::new(Arc::new(config), name)
        .map_err(|e| Error::internal(format!("TLS setup: {e}")))?;
    Ok(Stream::Tls(Box::new(rustls::StreamOwned::new(conn, tcp))))
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
    stream
        .tcp()
        .set_read_timeout(Some(remaining(deadline)?))
        .map_err(|e| Error::io("socket", e))?;
    let url = api.ws_url(&format!("/v1/pair/wait?code={code}"))?;
    let mut request =
        url.as_str().into_client_request().map_err(|e| Error::internal(format!("{e}")))?;
    let protocols = HeaderValue::from_str(&format!("{SUBPROTOCOL}, collect.{secret}"))
        .map_err(|_| Error::internal("collect secret is not a header value"))?;
    request.headers_mut().insert("Sec-WebSocket-Protocol", protocols);
    let mut socket = match tungstenite::client(request, stream) {
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
    read_result(&mut socket, deadline)
}

fn read_result(socket: &mut WebSocket<Stream>, deadline: Instant) -> Result<End> {
    loop {
        let left = remaining(deadline)?;
        socket.get_ref().tcp().set_read_timeout(Some(left)).map_err(|e| Error::io("socket", e))?;
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
